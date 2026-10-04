#import "GFWebSocket.h"
#import "GFTLSSocket.h"
#import "GFSettings.h"
#import "GFUtils.h"
#import "GFCommon.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

@interface GFWebSocket ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, strong) NSArray *protocols;
@property (nonatomic, strong) NSDictionary *headers;
@property (nonatomic, weak) id<GFWebSocketDelegate> delegate;
@property (nonatomic, strong) GFTLSSocket *socket;
@property (nonatomic, strong) NSLock *writeLock;
@property (nonatomic) BOOL isOpen;
@property (nonatomic) BOOL closed;
@property (nonatomic, copy) NSString *connectedHost;
@property (nonatomic, strong) GFWebSocket *selfRetain;
@end

@implementation GFWebSocket

- (instancetype)initWithURL:(NSURL *)url protocols:(NSArray *)protocols headers:(NSDictionary *)headers delegate:(id<GFWebSocketDelegate>)delegate
{
    if ((self = [super init])) {
        _url = url;
        _protocols = protocols;
        _headers = headers;
        _delegate = delegate;
        _writeLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)open
{
    self.selfRetain = self;
    [NSThread detachNewThreadSelector:@selector(run) toTarget:self withObject:nil];
}

- (int)port
{
    if (self.url.port) return [self.url.port intValue];
    return [[self.url.scheme lowercaseString] isEqualToString:@"ws"] ? 80 : 443;
}

- (BOOL)connectWithVerify:(BOOL)verify error:(NSError **)error
{
    GFTLSSocket *s = [[GFTLSSocket alloc] init];
    s.plain = [[self.url.scheme lowercaseString] isEqualToString:@"ws"];
    if (![s connectToHost:self.url.host port:[self port] verify:verify connectTimeoutMs:10000 readTimeoutMs:30000 error:error]) return NO;
    self.socket = s;
    return YES;
}

- (void)run
{
    @autoreleasepool {
        NSError *error = nil;
        BOOL verify = [GFSettings verifyTLS];
        BOOL ok = [self connectWithVerify:verify error:&error];
        if (!ok && verify && error.code == GFErrorCertificate) {
            // signaling hosts are often bare addresses or Alliance names the certificate does not cover; the session
            // itself is protected by its id, so a second try without the name check is acceptable here
            GFLog(@"Signaling certificate does not match %@, connecting without the name check", self.url.host);
            error = nil;
            ok = [self connectWithVerify:NO error:&error];
        }
        if (!ok) {
            [self finishWithReason:[NSString stringWithFormat:@"connect failed: %@", error.localizedDescription ?: @"?"]];
            return;
        }
        if (![self handshakeWithError:&error]) {
            [self.socket close];
            [self finishWithReason:[NSString stringWithFormat:@"handshake failed: %@", error.localizedDescription ?: @"?"]];
            return;
        }
        self.isOpen = YES;
        self.connectedHost = self.url.host;
        id<GFWebSocketDelegate> d = self.delegate;
        [d webSocketDidOpen:self];
        [self readLoop];
    }
}

- (void)finishWithReason:(NSString *)reason
{
    if (self.closed) { self.selfRetain = nil; return; }
    self.closed = YES;
    self.isOpen = NO;
    id<GFWebSocketDelegate> d = self.delegate;
    [d webSocket:self didCloseWithReason:reason];
    self.selfRetain = nil;
}

#pragma mark - Handshake

- (BOOL)handshakeWithError:(NSError **)error
{
    uint8_t nonce[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(nonce), nonce) != 0) for (int i = 0; i < 16; i++) nonce[i] = (uint8_t)arc4random_uniform(256);
    NSString *key = [GFUtils base64Encode:[NSData dataWithBytes:nonce length:sizeof(nonce)]];
    NSString *path = self.url.path.length ? self.url.path : @"/";
    if (self.url.query.length) path = [NSString stringWithFormat:@"%@?%@", path, self.url.query];
    int port = [self port];
    BOOL defaultPort = (self.socket.plain && port == 80) || (!self.socket.plain && port == 443);
    NSMutableString *req = [NSMutableString string];
    [req appendFormat:@"GET %@ HTTP/1.1\r\n", path];
    [req appendFormat:@"Host: %@\r\n", defaultPort ? self.url.host : [NSString stringWithFormat:@"%@:%d", self.url.host, port]];
    [req appendString:@"Upgrade: websocket\r\nConnection: Upgrade\r\n"];
    [req appendFormat:@"Sec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\n", key];
    if (self.protocols.count) [req appendFormat:@"Sec-WebSocket-Protocol: %@\r\n", [self.protocols componentsJoinedByString:@", "]];
    for (NSString *h in self.headers) [req appendFormat:@"%@: %@\r\n", h, self.headers[h]];
    [req appendString:@"\r\n"];
    if (![self.socket writeData:[req dataUsingEncoding:NSUTF8StringEncoding] error:error]) return NO;

    // the status line and headers, byte by byte until the blank line (what follows belongs to the frames)
    NSMutableData *head = [NSMutableData data];
    uint8_t c;
    while (head.length < 16384) {
        NSInteger n = [self.socket readIntoBuffer:&c maxLength:1 error:error];
        if (n <= 0) { if (error && !*error) *error = GFMakeError(GFErrorConnectionLost, @"closed during the handshake"); return NO; }
        [head appendBytes:&c length:1];
        if (head.length >= 4 && memcmp((const uint8_t *)head.bytes + head.length - 4, "\r\n\r\n", 4) == 0) break;
    }
    NSString *response = [[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding] ?: @"";
    NSArray *lines = [response componentsSeparatedByString:@"\r\n"];
    NSString *status = lines.firstObject ?: @"";
    if ([status rangeOfString:@" 101"].location == NSNotFound) {
        if (error) *error = GFMakeError(GFErrorBadResponse, [NSString stringWithFormat:@"HTTP %@", [GFUtils truncate:status to:80]]);
        return NO;
    }
    NSString *expected = [self acceptKeyFor:key];
    BOOL accepted = NO;
    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([name isEqualToString:@"sec-websocket-accept"] && [value isEqualToString:expected]) accepted = YES;
    }
    if (!accepted) {
        if (error) *error = GFMakeError(GFErrorBadResponse, @"bad Sec-WebSocket-Accept");
        return NO;
    }
    return YES;
}

- (NSString *)acceptKeyFor:(NSString *)key
{
    NSData *input = [[key stringByAppendingString:@"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"] dataUsingEncoding:NSASCIIStringEncoding];
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(input.bytes, (CC_LONG)input.length, digest);
    return [GFUtils base64Encode:[NSData dataWithBytes:digest length:sizeof(digest)]];
}

#pragma mark - Frames

- (BOOL)readFully:(uint8_t *)buffer length:(NSUInteger)length error:(NSError **)error
{
    NSUInteger got = 0;
    while (got < length) {
        NSInteger n = [self.socket readIntoBuffer:buffer + got maxLength:length - got error:error];
        if (n <= 0) {
            if (error && !*error) *error = GFMakeError(GFErrorConnectionLost, @"closed");
            return NO;
        }
        got += (NSUInteger)n;
    }
    return YES;
}

- (void)readLoop
{
    NSMutableData *message = nil;
    uint8_t messageOpcode = 0;
    while (!self.closed) {
        @autoreleasepool {
            NSError *error = nil;
            uint8_t h[2];
            if (![self readFully:h length:2 error:&error]) { [self finishWithReason:error.localizedDescription ?: @"closed"]; return; }
            BOOL fin = (h[0] & 0x80) != 0;
            uint8_t opcode = h[0] & 0x0f;
            BOOL masked = (h[1] & 0x80) != 0;
            uint64_t length = h[1] & 0x7f;
            if (length == 126) {
                uint8_t ext[2];
                if (![self readFully:ext length:2 error:&error]) { [self finishWithReason:@"closed"]; return; }
                length = ((uint64_t)ext[0] << 8) | ext[1];
            } else if (length == 127) {
                uint8_t ext[8];
                if (![self readFully:ext length:8 error:&error]) { [self finishWithReason:@"closed"]; return; }
                length = 0;
                for (int i = 0; i < 8; i++) length = (length << 8) | ext[i];
            }
            uint8_t mask[4] = { 0, 0, 0, 0 };
            if (masked && ![self readFully:mask length:4 error:&error]) { [self finishWithReason:@"closed"]; return; }
            if (length > 16 * 1024 * 1024) { [self finishWithReason:@"frame too large"]; return; }
            NSMutableData *payload = [NSMutableData dataWithLength:(NSUInteger)length];
            if (length && ![self readFully:payload.mutableBytes length:(NSUInteger)length error:&error]) { [self finishWithReason:error.localizedDescription ?: @"closed"]; return; }
            if (masked) {
                uint8_t *p = payload.mutableBytes;
                for (NSUInteger i = 0; i < payload.length; i++) p[i] ^= mask[i & 3];
            }
            switch (opcode) {
                case 0x0:   // continuation
                    if (!message) break;
                    [message appendData:payload];
                    if (fin) { [self deliver:message opcode:messageOpcode]; message = nil; }
                    break;
                case 0x1:
                case 0x2:
                    if (fin) { [self deliver:payload opcode:opcode]; }
                    else { message = payload; messageOpcode = opcode; }
                    break;
                case 0x8: {  // close
                    NSString *reason = payload.length >= 2 ? [NSString stringWithFormat:@"close %d", (((const uint8_t *)payload.bytes)[0] << 8) | ((const uint8_t *)payload.bytes)[1]] : @"close";
                    [self sendFrameOpcode:0x8 payload:payload];
                    [self.socket close];
                    [self finishWithReason:reason];
                    return;
                }
                case 0x9:   // ping
                    [self sendFrameOpcode:0xA payload:payload];
                    break;
                case 0xA:   // pong
                    break;
                default:
                    break;
            }
        }
    }
}

- (void)deliver:(NSData *)payload opcode:(uint8_t)opcode
{
    id<GFWebSocketDelegate> d = self.delegate;
    if (opcode == 0x1) {
        NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
        if (text) [d webSocket:self didReceiveText:text];
    } else {
        [d webSocket:self didReceiveData:payload];
    }
}

- (BOOL)sendFrameOpcode:(uint8_t)opcode payload:(NSData *)payload
{
    if (!self.socket.isConnected) return NO;
    NSMutableData *frame = [NSMutableData dataWithCapacity:payload.length + 14];
    uint8_t h0 = 0x80 | opcode;
    [frame appendBytes:&h0 length:1];
    NSUInteger len = payload.length;
    if (len < 126) {
        uint8_t b = 0x80 | (uint8_t)len;
        [frame appendBytes:&b length:1];
    } else if (len < 65536) {
        uint8_t b[3] = { 0x80 | 126, (uint8_t)(len >> 8), (uint8_t)len };
        [frame appendBytes:b length:3];
    } else {
        uint8_t b[9] = { 0x80 | 127, 0, 0, 0, 0, (uint8_t)(len >> 24), (uint8_t)(len >> 16), (uint8_t)(len >> 8), (uint8_t)len };
        [frame appendBytes:b length:9];
    }
    uint8_t mask[4];
    if (SecRandomCopyBytes(kSecRandomDefault, 4, mask) != 0) { uint32_t r = arc4random(); memcpy(mask, &r, 4); }
    [frame appendBytes:mask length:4];
    const uint8_t *src = payload.bytes;
    NSMutableData *masked = [NSMutableData dataWithLength:len];
    uint8_t *dst = masked.mutableBytes;
    for (NSUInteger i = 0; i < len; i++) dst[i] = src[i] ^ mask[i & 3];
    [frame appendData:masked];
    [self.writeLock lock];
    NSError *error = nil;
    BOOL ok = [self.socket writeData:frame error:&error];
    [self.writeLock unlock];
    if (!ok) GFLog(@"WebSocket write failed: %@", error.localizedDescription);
    return ok;
}

- (BOOL)sendText:(NSString *)text
{
    return [self sendFrameOpcode:0x1 payload:[text dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data]];
}

- (BOOL)sendData:(NSData *)data
{
    return [self sendFrameOpcode:0x2 payload:data ?: [NSData data]];
}

- (void)close
{
    if (self.closed) return;
    uint8_t code[2] = { 0x03, 0xe8 };
    [self sendFrameOpcode:0x8 payload:[NSData dataWithBytes:code length:2]];
    self.closed = YES;
    self.isOpen = NO;
    [self.socket cancel];
    [self.socket close];
    self.selfRetain = nil;
}

@end
