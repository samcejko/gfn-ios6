#import "GFLegacyCollections.h"
#import "GFSignaling.h"
#import "GFWebSocket.h"
#import "GFUtils.h"
#import "GFCommon.h"

static NSString * const GFSignalingUserAgent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

@interface GFSignaling () <GFWebSocketDelegate>
@property (nonatomic, strong) GFSession *session;
@property (nonatomic, weak) id<GFSignalingDelegate> delegate;
@property (nonatomic, strong) GFWebSocket *socket;
@property (nonatomic, copy) NSString *peerName;
@property (nonatomic) uint32_t localPeerId;
@property (nonatomic) uint32_t remotePeerId;
@property (nonatomic) uint32_t ackCounter;
@property (nonatomic, strong) NSTimer *heartbeat;
@property (nonatomic) BOOL closed;
@end

@implementation GFSignaling

- (instancetype)initWithSession:(GFSession *)session delegate:(id<GFSignalingDelegate>)delegate
{
    if ((self = [super init])) {
        _session = session;
        _delegate = delegate;
        _peerName = [NSString stringWithFormat:@"peer-%llu", ((unsigned long long)arc4random() << 32 | arc4random()) % 10000000000ULL];
        _remotePeerId = 1;
    }
    return self;
}

- (NSString *)connectedHost { return self.socket.connectedHost; }

// keep the path the backend gave, append sign_in, replace the query
- (NSURL *)signInURL
{
    NSString *s = [self.session.signalingURL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
    if ([s hasPrefix:@"http://"]) s = [@"ws://" stringByAppendingString:[s substringFromIndex:7]];
    else if ([s hasPrefix:@"https://"]) s = [@"wss://" stringByAppendingString:[s substringFromIndex:8]];
    else if (![s hasPrefix:@"ws://"] && ![s hasPrefix:@"wss://"]) s = [@"wss://" stringByAppendingString:s];
    NSRange q = [s rangeOfString:@"?"];
    if (q.location != NSNotFound) s = [s substringToIndex:q.location];
    if ([s hasSuffix:@"/sign_in"]) s = [s substringToIndex:s.length - @"sign_in".length];
    while ([s hasSuffix:@"/"]) s = [s substringToIndex:s.length - 1];
    s = [NSString stringWithFormat:@"%@/sign_in?peer_id=%@&version=2&peer_role=1&pairing_id=%@", s, self.peerName, [GFUtils urlEncode:self.session.sessionId ?: @""]];
    return [NSURL URLWithString:s];
}

- (void)connect
{
    NSURL *url = [self signInURL];
    GFLog(@"Signaling: connecting to %@", url);
    NSDictionary *headers = @{ @"Origin": @"https://play.geforcenow.com", @"User-Agent": GFSignalingUserAgent };
    self.socket = [[GFWebSocket alloc] initWithURL:url protocols:@[ [@"x-nv-sessionid." stringByAppendingString:self.session.sessionId ?: @""] ]
                                           headers:headers delegate:self];
    [self.socket open];
}

- (void)sendJSON:(NSDictionary *)object
{
    NSData *data = [GFUtils JSONDataFromObject:object];
    if (data) [self.socket sendText:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
}

- (void)sendPeerMessage:(NSString *)message
{
    [self sendJSON:@{ @"peer_msg": @{ @"from": @(self.localPeerId), @"to": @(self.remotePeerId), @"msg": message }, @"ackid": @(++self.ackCounter) }];
}

- (void)sendAnswer:(NSString *)sdp nvstSDP:(NSString *)nvstSDP
{
    NSData *payload = [GFUtils JSONDataFromObject:@{ @"type": @"answer", @"sdp": sdp ?: @"", @"nvstSdp": nvstSDP ?: @"" }];
    [self sendPeerMessage:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]];
    GFLog(@"Signaling: answer sent (%lu + %lu bytes)", (unsigned long)sdp.length, (unsigned long)nvstSDP.length);
}

- (void)sendCandidate:(NSDictionary *)candidate
{
    NSArray *parts = [[candidate objectForKey:@"candidate"] componentsSeparatedByString:@" "];
    if (parts.count > 2 && [[[parts objectAtIndex:2] lowercaseString] isEqualToString:@"tcp"]) return;
    NSData *payload = [GFUtils JSONDataFromObject:candidate];
    [self sendPeerMessage:[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding]];
}

- (void)close
{
    if (self.closed) return;
    self.closed = YES;
    [self.heartbeat invalidate];
    self.heartbeat = nil;
    [self.socket close];
}

#pragma mark - WebSocket

- (void)webSocketDidOpen:(GFWebSocket *)socket
{
    GFLog(@"Signaling: connected");
    [self sendJSON:@{ @"ackid": @(++self.ackCounter),
                      @"peer_info": @{ @"browser": @"Chrome", @"browserVersion": @"131", @"connected": @YES, @"id": @(self.localPeerId),
                                       @"name": self.peerName, @"peerRole": @1, @"resolution": [NSString stringWithFormat:@"%ldx%ld", (long)self.session.width, (long)self.session.height],
                                       @"version": @2 } }];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closed) return;
        self.heartbeat = [NSTimer scheduledTimerWithTimeInterval:5 target:self selector:@selector(sendHeartbeat) userInfo:nil repeats:YES];
        [self.delegate signalingDidConnect:self];
    });
}

- (void)sendHeartbeat
{
    [self sendJSON:@{ @"hb": @1 }];
}

- (void)webSocket:(GFWebSocket *)socket didReceiveText:(NSString *)text
{
    NSDictionary *parsed = GFDict([GFUtils JSONObjectFromData:[text dataUsingEncoding:NSUTF8StringEncoding]]);
    if (!parsed) return;
    NSDictionary *peerInfo = GFDict([parsed objectForKey:@"peer_info"]);
    if (peerInfo && [GFStr([peerInfo objectForKey:@"name"]) isEqualToString:self.peerName] && [peerInfo objectForKey:@"id"]) self.localPeerId = (uint32_t)GFInt([peerInfo objectForKey:@"id"]);
    if ([parsed objectForKey:@"ackid"]) {
        BOOL ownEcho = peerInfo && GFInt([peerInfo objectForKey:@"id"]) == (NSInteger)self.localPeerId;
        if (!ownEcho) [self sendJSON:@{ @"ack": [parsed objectForKey:@"ackid"] }];
    }
    if ([parsed objectForKey:@"hb"]) { [self sendJSON:@{ @"hb": @1 }]; return; }
    if ([GFStr([parsed objectForKey:@"error"]) isEqualToString:@"peerRemoved"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate signaling:self didClose:@"peerRemoved"]; });
        return;
    }
    NSDictionary *peerMsg = GFDict([parsed objectForKey:@"peer_msg"]);
    if (!peerMsg) return;
    if ([peerMsg objectForKey:@"from"]) self.remotePeerId = (uint32_t)GFInt([peerMsg objectForKey:@"from"]);
    NSString *msg = [GFStr([peerMsg objectForKey:@"msg"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!msg.length) return;
    if ([msg isEqualToString:@"BYE"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate signaling:self didClose:@"BYE"]; });
        return;
    }
    NSDictionary *payload = GFDict([GFUtils JSONObjectFromData:[msg dataUsingEncoding:NSUTF8StringEncoding]]);
    if (!payload) { GFLog(@"Signaling: non-JSON peer message: %@", [GFUtils truncate:msg to:120]); return; }
    if ([GFStr([payload objectForKey:@"type"]) isEqualToString:@"offer"] && GFStr([payload objectForKey:@"sdp"]).length) {
        NSString *sdp = GFStr([payload objectForKey:@"sdp"]);
        GFLog(@"Signaling: offer received (%lu bytes)", (unsigned long)sdp.length);
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate signaling:self didReceiveOffer:sdp]; });
        return;
    }
    NSString *candidate = GFStr([payload objectForKey:@"candidate"]);
    if (candidate.length) {
        NSArray *parts = [candidate componentsSeparatedByString:@" "];
        if (parts.count > 2 && [[[parts objectAtIndex:2] lowercaseString] isEqualToString:@"tcp"]) return;
        NSMutableDictionary *c = [NSMutableDictionary dictionaryWithObject:candidate forKey:@"candidate"];
        if (GFStr([payload objectForKey:@"sdpMid"])) GFLegacyDictionarySet(c, @"sdpMid", GFStr([payload objectForKey:@"sdpMid"]));
        if ([payload objectForKey:@"sdpMLineIndex"]) GFLegacyDictionarySet(c, @"sdpMLineIndex", @(GFInt([payload objectForKey:@"sdpMLineIndex"])));
        if (GFStr([payload objectForKey:@"usernameFragment"])) GFLegacyDictionarySet(c, @"usernameFragment", GFStr([payload objectForKey:@"usernameFragment"]));
        dispatch_async(dispatch_get_main_queue(), ^{ [self.delegate signaling:self didReceiveCandidate:c]; });
    }
}

- (void)webSocket:(GFWebSocket *)socket didReceiveData:(NSData *)data
{
}

- (void)webSocket:(GFWebSocket *)socket didCloseWithReason:(NSString *)reason
{
    GFLog(@"Signaling: closed (%@)", reason);
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.heartbeat invalidate];
        self.heartbeat = nil;
        if (!self.closed) [self.delegate signaling:self didClose:reason];
    });
}

@end
