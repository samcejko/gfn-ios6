#import "GFPeer.h"
#import "GFCommon.h"
#import "GFUtils.h"
#include "gf_stun.h"
#include "gf_dtls.h"
#include "gf_srtp.h"
#include "gf_rtp.h"
#include "gf_rtcp.h"
#include "gf_sctp.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>

#define MAX_CANDIDATES 16
#define MAX_PENDING_CHECKS 64
#define MAX_SRTP_STREAMS 8
#define INPUT_STREAM 0

typedef struct {
    uint32_t ip;            // host order
    uint16_t port;
    int succeeded;
    int failures;
    uint64_t last_sent;
} ice_candidate;

typedef struct {
    uint8_t tid[12];
    int candidate;
    uint64_t sent_us;
    int used;
} ice_check;

typedef enum { GFPeerStateNew, GFPeerStateChecking, GFPeerStateConnected, GFPeerStateClosed } GFPeerState;

@interface GFPeer ()
@property (nonatomic, strong) GFSession *session;
@property (nonatomic, strong) GFSDPOffer *offer;
@property (nonatomic, weak) id<GFPeerDelegate> delegate;
@property (nonatomic, strong) NSThread *thread;
@property (nonatomic, strong) NSMutableArray *commands;
@property (nonatomic, strong) NSLock *commandLock;
@property (nonatomic, strong) GFInputProtocol *input;
@property (nonatomic, copy) NSString *localUfrag, *localPwd;
@property (nonatomic, strong) NSMutableDictionary *channelLabels;   // @(stream) -> label
@property (nonatomic) BOOL isConnected;
@property (nonatomic) BOOL inputReady;
- (int)sendSelected:(const uint8_t *)data length:(size_t)len;
- (int)dtlsWrite:(const uint8_t *)pkt length:(size_t)len;
- (void)sctpConnected;
- (void)sctpChannelOpened:(uint16_t)stream label:(NSString *)label;
- (void)sctpChannelAcked:(uint16_t)stream;
- (void)sctpMessageOnStream:(uint16_t)stream ppid:(uint32_t)ppid data:(const uint8_t *)data length:(size_t)len;
- (void)sctpClosed:(NSString *)reason;
- (void)videoAccessUnit:(const uint8_t *)au length:(size_t)len timestamp:(uint32_t)ts keyframe:(int)keyframe damaged:(int)damaged;
- (void)dtlsConnected;
- (void)startDTLS;
- (void)sendRTCPWithFeedback:(int)kinds;
- (void)sendNack;
- (void)fail:(NSString *)reason;
- (void)status:(NSString *)text;
- (void)sendInputData:(NSData *)data;
- (uint64_t)sessionMicros;
@end

@implementation GFPeer {
    int _fd;
    int _wake[2];
    volatile BOOL _running;
    GFPeerState _state;
    uint64_t _start_us;
    uint32_t _localIp;
    uint16_t _localPort;
    // ICE
    ice_candidate _cands[MAX_CANDIDATES];
    int _candCount;
    ice_check _checks[MAX_PENDING_CHECKS];
    int _selected;
    uint64_t _tiebreaker;
    uint64_t _nextCheck_us, _iceStart_us, _lastIceResponse_us;
    double _rtt_ms;
    // DTLS / SRTP / SCTP
    gf_dtls *_dtls;
    gf_srtp_session _srtpRx, _srtpTx;
    int _srtpReady;
    gf_srtp_stream _rxStreams[MAX_SRTP_STREAMS];
    gf_sctp *_sctp;
    int _inputOpen;
    // media
    gf_h264_depack _depack;
    uint32_t _ourSsrc, _videoSsrc, _audioSsrc;
    uint32_t _lastSr, _lastSrTime_us;
    uint16_t _highestSeq;
    uint32_t _seqCycles;
    int _haveSeq;
    uint64_t _lastRtcp_us, _lastNack_us, _lastPli_us, _lastStats_us, _lastHeartbeat_us, _lastGamepad_us, _lastVideo_us;
    uint64_t _bytesIn, _bytesInLast, _framesLast, _plis, _nacks, _rtpPackets, _lostLast, _packetsLast;
    uint64_t _audioPackets;
    int _pliWanted;
    // gamepad coalescing
    GFGamepadState _pad;
    int _padDirty;
    GFGamepadState _padSent;
}

- (instancetype)initWithSession:(GFSession *)session offer:(GFSDPOffer *)offer delegate:(id<GFPeerDelegate>)delegate
{
    if ((self = [super init])) {
        _session = session;
        _offer = offer;
        _delegate = delegate;
        _commands = [NSMutableArray array];
        _commandLock = [[NSLock alloc] init];
        _input = [[GFInputProtocol alloc] init];
        _channelLabels = [NSMutableDictionary dictionary];
        _fd = -1;
        _wake[0] = _wake[1] = -1;
        _selected = -1;
        _localUfrag = [GFSDP randomICEString:8];
        _localPwd = [GFSDP randomICEString:24];
        _ourSsrc = arc4random() | 1;
        _streamWidth = session.width ?: 1024;
        _streamHeight = session.height ?: 768;
        _streamFps = session.fps ?: 60;
        _maxKbps = 10000;
        _tiebreaker = ((uint64_t)arc4random() << 32) | arc4random();
        gf_h264_init(&_depack);
    }
    return self;
}

- (void)dealloc
{
    gf_h264_free(&_depack);
    if (_dtls) gf_dtls_destroy(_dtls);
    if (_sctp) gf_sctp_destroy(_sctp);
    if (_fd >= 0) close(_fd);
    if (_wake[0] >= 0) close(_wake[0]);
    if (_wake[1] >= 0) close(_wake[1]);
}

#pragma mark - Delegate helpers (main thread)

- (void)status:(NSString *)text
{
    GFLog(@"Peer: %@", text);
    id<GFPeerDelegate> d = self.delegate;
    dispatch_async(dispatch_get_main_queue(), ^{ [d peer:self status:text]; });
}

- (void)fail:(NSString *)reason
{
    if (_state == GFPeerStateClosed) return;
    _state = GFPeerStateClosed;
    _running = NO;
    self.isConnected = NO;
    GFLog(@"Peer: disconnected: %@", reason);
    id<GFPeerDelegate> d = self.delegate;
    dispatch_async(dispatch_get_main_queue(), ^{ [d peer:self didDisconnect:reason]; });
}

#pragma mark - Commands onto the network thread

- (void)perform:(dispatch_block_t)block
{
    [self.commandLock lock];
    [self.commands addObject:[block copy]];
    [self.commandLock unlock];
    if (_wake[1] >= 0) { uint8_t b = 1; write(_wake[1], &b, 1); }
}

- (void)runCommands
{
    [self.commandLock lock];
    NSArray *list = [self.commands copy];
    [self.commands removeAllObjects];
    [self.commandLock unlock];
    for (dispatch_block_t b in list) b();
}

- (void)start
{
    _running = YES;
    self.thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
    self.thread.name = @"gfn6-peer";
    [self.thread start];
}

- (void)close
{
    [self perform:^{ [self shutdown:@"closed"]; }];
}

- (void)shutdown:(NSString *)reason
{
    if (_sctp) gf_sctp_shutdown(_sctp);
    _running = NO;
    _state = GFPeerStateClosed;
    self.isConnected = NO;
    (void)reason;
}

#pragma mark - Setup

static uint32_t local_ip_toward(uint32_t target_ip)
{
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) return 0;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(443);
    a.sin_addr.s_addr = htonl(target_ip ?: 0x08080808u);
    uint32_t ip = 0;
    if (connect(s, (struct sockaddr *)&a, sizeof(a)) == 0) {
        struct sockaddr_in l;
        socklen_t ll = sizeof(l);
        if (getsockname(s, (struct sockaddr *)&l, &ll) == 0) ip = ntohl(l.sin_addr.s_addr);
    }
    close(s);
    return ip;
}

static uint32_t parse_ipv4(NSString *s)
{
    struct in_addr a;
    if (!s.length || inet_aton([s UTF8String], &a) == 0) return 0;
    return ntohl(a.s_addr);
}

- (void)addCandidateIp:(uint32_t)ip port:(uint16_t)port
{
    if (!ip || !port || ip == 0x7f000001u) return;
    for (int i = 0; i < _candCount; i++) if (_cands[i].ip == ip && _cands[i].port == port) return;
    if (_candCount >= MAX_CANDIDATES) return;
    memset(&_cands[_candCount], 0, sizeof(ice_candidate));
    _cands[_candCount].ip = ip;
    _cands[_candCount].port = port;
    _candCount++;
    struct in_addr a = { htonl(ip) };
    GFLog(@"Peer: remote candidate %s:%u", inet_ntoa(a), port);
    _nextCheck_us = 0;      // check it right away
}

- (void)addCandidateString:(NSString *)candidate
{
    NSArray *parts = [candidate componentsSeparatedByString:@" "];
    if (parts.count < 6) return;
    if ([[parts[2] lowercaseString] isEqualToString:@"tcp"]) return;
    uint32_t ip = parse_ipv4(parts[4]);
    if (!ip) {
        NSString *resolved = [GFSDP publicIPFromHost:parts[4]];
        ip = parse_ipv4(resolved);
    }
    [self addCandidateIp:ip port:(uint16_t)[parts[5] integerValue]];
}

- (void)addRemoteCandidate:(NSDictionary *)candidate
{
    NSString *s = candidate[@"candidate"];
    if (!s.length) return;
    [self perform:^{ [self addCandidateString:s]; }];
}

- (BOOL)openSocket
{
    _fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (_fd < 0) return NO;
    int size = 512 * 1024;
    setsockopt(_fd, SOL_SOCKET, SO_RCVBUF, &size, sizeof(size));
    size = 128 * 1024;
    setsockopt(_fd, SOL_SOCKET, SO_SNDBUF, &size, sizeof(size));
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = INADDR_ANY;
    a.sin_port = 0;
    if (bind(_fd, (struct sockaddr *)&a, sizeof(a)) != 0) return NO;
    socklen_t al = sizeof(a);
    getsockname(_fd, (struct sockaddr *)&a, &al);
    _localPort = ntohs(a.sin_port);
    fcntl(_fd, F_SETFL, fcntl(_fd, F_GETFL, 0) | O_NONBLOCK);
    if (pipe(_wake) != 0) return NO;
    fcntl(_wake[0], F_SETFL, fcntl(_wake[0], F_GETFL, 0) | O_NONBLOCK);
    uint32_t serverIp = parse_ipv4([GFSDP publicIPFromHost:self.session.serverIp]);
    _localIp = local_ip_toward(serverIp);
    return YES;
}

- (int)sendTo:(int)candidate data:(const uint8_t *)data length:(size_t)len
{
    if (candidate < 0 || candidate >= _candCount) return -1;
    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(_cands[candidate].port);
    a.sin_addr.s_addr = htonl(_cands[candidate].ip);
    ssize_t n = sendto(_fd, data, len, 0, (struct sockaddr *)&a, sizeof(a));
    return n < 0 ? -1 : (int)n;
}

- (int)sendSelected:(const uint8_t *)data length:(size_t)len
{
    return [self sendTo:_selected data:data length:len];
}

static int dtls_send_cb(void *ctx, const uint8_t *data, size_t len)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    return [p sendSelected:data length:len];
}

static int sctp_send_cb(void *ctx, const uint8_t *pkt, size_t len)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    return [p dtlsWrite:pkt length:len];
}

- (int)dtlsWrite:(const uint8_t *)pkt length:(size_t)len
{
    return _dtls ? gf_dtls_write(_dtls, pkt, len) : -1;
}

#pragma mark - Thread

- (void)threadMain
{
    @autoreleasepool {
        _start_us = GFMonotonicMicros();
        [self status:L(@"Preparing the secure connection…")];
        _dtls = gf_dtls_create();
        if (!_dtls) { [self fail:L(@"Could not create the DTLS certificate.")]; return; }
        if (![self openSocket]) { [self fail:L(@"Could not open the network socket.")]; return; }

        // remote candidates known up front: the offer's and the media host of the session
        for (NSString *c in self.offer.candidates) [self addCandidateString:c];
        if (self.session.mediaPort) {
            uint32_t ip = parse_ipv4([GFSDP publicIPFromHost:self.session.mediaIp]) ?: parse_ipv4([GFSDP publicIPFromHost:self.session.serverIp]);
            [self addCandidateIp:ip port:(uint16_t)self.session.mediaPort];
        }

        NSString *fingerprint = [NSString stringWithUTF8String:gf_dtls_fingerprint(_dtls)];
        NSString *answer = [GFSDP answerForOffer:self.offer iceUfrag:self.localUfrag icePwd:self.localPwd fingerprint:fingerprint videoKbps:self.maxKbps];
        NSString *nvst = [GFSDP nvstSDPForOffer:self.offer iceUfrag:self.localUfrag icePwd:self.localPwd fingerprint:fingerprint
                                          width:self.streamWidth height:self.streamHeight fps:self.streamFps maxKbps:self.maxKbps];
        id<GFPeerDelegate> d = self.delegate;
        dispatch_async(dispatch_get_main_queue(), ^{ [d peer:self didCreateAnswer:answer nvstSDP:nvst]; });
        if (_localIp) {
            struct in_addr a = { htonl(_localIp) };
            NSString *cand = [NSString stringWithFormat:@"candidate:1 1 UDP 2122260223 %s %u typ host", inet_ntoa(a), _localPort];
            NSDictionary *c = @{ @"candidate": cand, @"sdpMid": @"0", @"sdpMLineIndex": @0, @"usernameFragment": self.localUfrag };
            dispatch_async(dispatch_get_main_queue(), ^{ [d peer:self didGatherCandidate:c]; });
        }
        _state = GFPeerStateChecking;
        _iceStart_us = GFMonotonicMicros();
        [self status:L(@"Connecting to the game server…")];
        [self loop];
        if (_sctp) { gf_sctp_destroy(_sctp); _sctp = NULL; }
        if (_fd >= 0) { close(_fd); _fd = -1; }
    }
}

- (void)loop
{
    uint8_t buf[2048];
    while (_running) {
        @autoreleasepool {
            uint64_t now = GFMonotonicMicros();
            uint64_t wait_us = 50000;   // 50 ms at most between housekeeping passes
            if (_dtls && !gf_dtls_is_connected(_dtls)) {
                uint64_t t = gf_dtls_next_timeout(_dtls);
                if (t < wait_us) wait_us = t;
            }
            if (_sctp) {
                uint64_t t = gf_sctp_next_timeout(_sctp);
                if (t != UINT64_MAX) { uint64_t rel = t > now ? t - now : 0; if (rel < wait_us) wait_us = rel; }
            }
            if (_padDirty && _lastGamepad_us + 16000 > now) { uint64_t rel = _lastGamepad_us + 16000 - now; if (rel < wait_us) wait_us = rel; }
            else if (_padDirty) wait_us = 0;
            struct pollfd fds[2] = { { _fd, POLLIN, 0 }, { _wake[0], POLLIN, 0 } };
            int rc = poll(fds, 2, (int)((wait_us + 999) / 1000));
            if (rc > 0 && (fds[1].revents & POLLIN)) {
                uint8_t drain[64];
                while (read(_wake[0], drain, sizeof(drain)) > 0) {}
                [self runCommands];
            }
            if (rc > 0 && (fds[0].revents & POLLIN)) {
                for (int i = 0; i < 64; i++) {
                    struct sockaddr_in from;
                    socklen_t fl = sizeof(from);
                    ssize_t n = recvfrom(_fd, buf, sizeof(buf), 0, (struct sockaddr *)&from, &fl);
                    if (n <= 0) break;
                    [self handlePacket:buf length:(size_t)n fromIp:ntohl(from.sin_addr.s_addr) port:ntohs(from.sin_port)];
                }
            }
            [self housekeeping];
        }
    }
}

#pragma mark - Packets

- (void)handlePacket:(uint8_t *)pkt length:(size_t)len fromIp:(uint32_t)ip port:(uint16_t)port
{
    if (len < 1) return;
    uint8_t b = pkt[0];
    if (b <= 3) { [self handleSTUN:pkt length:len fromIp:ip port:port]; return; }
    if (b >= 20 && b <= 63) { [self handleDTLS:pkt length:len]; return; }
    if (b >= 128 && b <= 191) {
        _bytesIn += len;
        if (!_srtpReady) return;
        uint8_t pt = pkt[1];
        if (pt >= 192 && pt <= 223) [self handleRTCP:pkt length:len];
        else [self handleRTP:pkt length:len];
    }
}

- (void)handleSTUN:(uint8_t *)pkt length:(size_t)len fromIp:(uint32_t)ip port:(uint16_t)port
{
    gf_stun_info info;
    if (gf_stun_parse(pkt, len, NULL, &info) != 0) return;
    uint64_t now = GFMonotonicMicros();
    if (info.type == GF_STUN_BINDING_REQUEST) {
        gf_stun_info checked;
        gf_stun_parse(pkt, len, [self.localPwd UTF8String], &checked);
        if (checked.integrity_ok < 0) return;
        uint8_t out[256];
        size_t n = gf_stun_build_response(out, sizeof(out), info.tid, ip, port, [self.localPwd UTF8String]);
        struct sockaddr_in a;
        memset(&a, 0, sizeof(a));
        a.sin_family = AF_INET;
        a.sin_port = htons(port);
        a.sin_addr.s_addr = htonl(ip);
        if (n) sendto(_fd, out, n, 0, (struct sockaddr *)&a, sizeof(a));
        // a request from an address we did not know: a peer-reflexive candidate worth checking
        int known = 0;
        for (int i = 0; i < _candCount; i++) if (_cands[i].ip == ip && _cands[i].port == port) known = 1;
        if (!known) [self addCandidateIp:ip port:port];
        _lastIceResponse_us = now;
        return;
    }
    if (info.type != GF_STUN_BINDING_SUCCESS && info.type != GF_STUN_BINDING_ERROR) return;
    // one of our checks?
    for (int i = 0; i < MAX_PENDING_CHECKS; i++) {
        ice_check *c = &_checks[i];
        if (!c->used || memcmp(c->tid, info.tid, 12) != 0) continue;
        c->used = 0;
        if (info.type == GF_STUN_BINDING_ERROR) {
            GFLog(@"Peer: STUN error %d from candidate %d", info.error_code, c->candidate);
            if (c->candidate < _candCount) _cands[c->candidate].failures++;
            return;
        }
        gf_stun_info checked;
        gf_stun_parse(pkt, len, [self.offer.icePwd UTF8String], &checked);
        if (checked.integrity_ok < 0) { GFLog(@"Peer: STUN response with a bad integrity"); return; }
        _rtt_ms = (double)(now - c->sent_us) / 1000.0;
        _lastIceResponse_us = now;
        if (c->candidate < _candCount) _cands[c->candidate].succeeded = 1;
        if (_selected < 0 && c->candidate < _candCount) {
            _selected = c->candidate;
            struct in_addr a = { htonl(_cands[_selected].ip) };
            [self status:[NSString stringWithFormat:L(@"Connected to %s, securing the stream…"), inet_ntoa(a)]];
            [self startDTLS];
        }
        return;
    }
}

- (void)startDTLS
{
    gf_dtls_io io = { (__bridge void *)self, dtls_send_cb };
    if (gf_dtls_start(_dtls, &io, [self.offer.fingerprint UTF8String], GFMonotonicMicros()) != 0) {
        [self fail:[NSString stringWithFormat:@"DTLS: %s", gf_dtls_last_error(_dtls)]];
    }
}

- (void)handleDTLS:(uint8_t *)pkt length:(size_t)len
{
    if (!_dtls || _selected < 0) return;
    int rc = gf_dtls_input(_dtls, pkt, len, GFMonotonicMicros());
    if (rc < 0) { [self fail:[NSString stringWithFormat:@"DTLS: %s", gf_dtls_last_error(_dtls)]]; return; }
    if (rc == 1) { [self dtlsConnected]; return; }
    if (gf_dtls_is_connected(_dtls)) {
        uint8_t app[2048];
        int n;
        while ((n = gf_dtls_read(_dtls, app, sizeof(app))) > 0) {
            if (_sctp) gf_sctp_input(_sctp, app, (size_t)n, GFMonotonicMicros());
        }
        if (n < 0) [self fail:[NSString stringWithFormat:@"DTLS: %s", gf_dtls_last_error(_dtls)]];
    }
}

static void sctp_connected_cb(void *ctx)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    [p sctpConnected];
}
static void sctp_channel_open_cb(void *ctx, uint16_t stream, const char *label, const char *protocol)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    [p sctpChannelOpened:stream label:[NSString stringWithUTF8String:label ?: ""]];
}
static void sctp_channel_ack_cb(void *ctx, uint16_t stream)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    [p sctpChannelAcked:stream];
}
static void sctp_message_cb(void *ctx, uint16_t stream, uint32_t ppid, const uint8_t *data, size_t len)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    [p sctpMessageOnStream:stream ppid:ppid data:data length:len];
}
static void sctp_closed_cb(void *ctx, const char *reason)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    [p sctpClosed:[NSString stringWithUTF8String:reason ?: "closed"]];
}

- (void)dtlsConnected
{
    uint8_t ck[16], sk[16], cs[14], ss[14];
    int tag = 10;
    if (gf_dtls_srtp_keys(_dtls, ck, sk, cs, ss, &tag) != 0) { [self fail:@"DTLS: no SRTP keys"]; return; }
    gf_srtp_init(&_srtpRx, sk, ss, tag);      // what the server sends
    gf_srtp_init(&_srtpTx, ck, cs, tag);      // our RTCP
    _srtpReady = 1;
    memset(_rxStreams, 0, sizeof(_rxStreams));
    _state = GFPeerStateConnected;
    self.isConnected = YES;
    [self status:L(@"Secure channel up, waiting for video…")];
    gf_sctp_callbacks cb = { (__bridge void *)self, sctp_send_cb, sctp_connected_cb, sctp_channel_open_cb, sctp_channel_ack_cb, sctp_message_cb, sctp_closed_cb };
    _sctp = gf_sctp_create(5000, (uint16_t)self.offer.sctpPort, &cb, GFMonotonicMicros());
    if (_sctp) gf_sctp_connect(_sctp, GFMonotonicMicros());
    _lastVideo_us = GFMonotonicMicros();
    id<GFPeerDelegate> d = self.delegate;
    dispatch_async(dispatch_get_main_queue(), ^{ [d peerDidConnect:self]; });
    [self sendRTCPWithFeedback:0];
}

- (void)sctpConnected
{
    GFLog(@"Peer: SCTP association up, opening the input channel");
    if (!gf_sctp_open_channel(_sctp, INPUT_STREAM, "input_channel_v1", "", 1, 0, 0)) GFLog(@"Peer: input channel open failed");
}

- (void)sctpChannelOpened:(uint16_t)stream label:(NSString *)label
{
    GFLog(@"Peer: server opened data channel '%@' on stream %u", label, stream);
    self.channelLabels[@(stream)] = label;
}

- (void)sctpChannelAcked:(uint16_t)stream
{
    if (stream == INPUT_STREAM) {
        _inputOpen = 1;
        GFLog(@"Peer: input channel acknowledged");
    }
}

- (void)sctpMessageOnStream:(uint16_t)stream ppid:(uint32_t)ppid data:(const uint8_t *)data length:(size_t)len
{
    NSData *d = [NSData dataWithBytes:data length:len];
    if (stream == INPUT_STREAM) {
        NSInteger version = [GFInputProtocol handshakeVersionFromData:d];
        if (version >= 0 && !self.inputReady) {
            self.input.protocolVersion = MIN(version, 255);
            self.inputReady = YES;
            _inputOpen = 1;
            GFLog(@"Peer: input channel ready (protocol v%ld)", (long)version);
            id<GFPeerDelegate> del = self.delegate;
            dispatch_async(dispatch_get_main_queue(), ^{ [del peer:self inputReadyWithProtocolVersion:version]; });
        }
        return;
    }
    NSString *label = self.channelLabels[@(stream)] ?: @"";
    if ([label isEqualToString:@"control_channel"] || ppid == GF_SCTP_PPID_STRING) {
        NSDictionary *json = GFDict([GFUtils JSONObjectFromData:d]);
        if (json) {
            id<GFPeerDelegate> del = self.delegate;
            dispatch_async(dispatch_get_main_queue(), ^{ [del peer:self didReceiveControlMessage:json]; });
        }
    }
}

- (void)sctpClosed:(NSString *)reason
{
    GFLog(@"Peer: SCTP closed: %@", reason);
    self.inputReady = NO;
    _inputOpen = 0;
}

#pragma mark - Media

static void video_au_cb(void *ctx, const uint8_t *au, size_t len, uint32_t ts, int keyframe, int damaged)
{
    GFPeer *p = (__bridge GFPeer *)ctx;
    [p videoAccessUnit:au length:len timestamp:ts keyframe:keyframe damaged:damaged];
}

- (void)videoAccessUnit:(const uint8_t *)au length:(size_t)len timestamp:(uint32_t)ts keyframe:(int)keyframe damaged:(int)damaged
{
    _lastVideo_us = GFMonotonicMicros();
    if (damaged) _pliWanted = 1;
    GFVideoSink sink = self.videoSink;
    if (sink) sink(au, len, ts, keyframe != 0, damaged != 0);
}

- (gf_srtp_stream *)rxStreamForSsrc:(uint32_t)ssrc
{
    for (int i = 0; i < MAX_SRTP_STREAMS; i++) if (_rxStreams[i].started && _rxStreams[i].ssrc == ssrc) return &_rxStreams[i];
    for (int i = 0; i < MAX_SRTP_STREAMS; i++) if (!_rxStreams[i].started) return &_rxStreams[i];
    return &_rxStreams[0];
}

- (void)handleRTP:(uint8_t *)pkt length:(size_t)len
{
    if (len < 12) return;
    uint32_t ssrc = ((uint32_t)pkt[8] << 24) | ((uint32_t)pkt[9] << 16) | ((uint32_t)pkt[10] << 8) | pkt[11];
    int plain = gf_srtp_unprotect(&_srtpRx, [self rxStreamForSsrc:ssrc], pkt, len);
    if (plain < 0) return;
    gf_rtp_header h;
    if (gf_rtp_parse(pkt, (size_t)plain, &h) != 0) return;
    _rtpPackets++;
    if (h.payload_type == self.offer.h264PayloadType) {
        _videoSsrc = h.ssrc;
        if (!_haveSeq) { _haveSeq = 1; _highestSeq = h.seq; }
        else if ((int16_t)(h.seq - _highestSeq) > 0) { if (h.seq < _highestSeq) _seqCycles++; _highestSeq = h.seq; }
        int gap = gf_h264_push(&_depack, &h, video_au_cb, (__bridge void *)self);
        if (gap > 0) [self sendNack];
    } else if (h.payload_type == self.offer.opusPayloadType || h.payload_type == self.offer.redPayloadType) {
        _audioSsrc = h.ssrc;
        _audioPackets++;
        GFAudioSink sink = self.audioSink;
        if (sink) sink(h.payload, h.payload_len, h.seq, h.payload_type, h.timestamp);
    }
}

- (void)handleRTCP:(uint8_t *)pkt length:(size_t)len
{
    int plain = gf_srtp_unprotect_rtcp(&_srtpRx, pkt, len);
    if (plain < 0) return;
    uint32_t ssrc, ntp;
    if (gf_rtcp_parse_sr(pkt, (size_t)plain, &ssrc, &ntp)) {
        _lastSr = ntp;
        _lastSrTime_us = GFMonotonicMicros();
    }
}

// An RTCP compound packet: RR, then the feedback asked for (bit 1 PLI, bit 2 NACK, bit 4 REMB)
- (void)sendRTCPWithFeedback:(int)kinds
{
    if (!_srtpReady || _selected < 0) return;
    uint8_t buf[512];
    size_t n = 0;
    uint64_t now = GFMonotonicMicros();
    uint8_t fraction = 0;
    uint64_t expected = _depack.packets + _depack.lost;
    uint64_t expectedLast = _packetsLast + _lostLast;
    if (expected > expectedLast) {
        uint64_t lostInterval = _depack.lost - _lostLast;
        fraction = (uint8_t)MIN(255ULL, lostInterval * 256 / (expected - expectedLast));
    }
    _packetsLast = _depack.packets;
    _lostLast = _depack.lost;
    uint32_t dlsr = _lastSr ? (uint32_t)(((now - _lastSrTime_us) * 65536ULL) / 1000000ULL) : 0;
    n += gf_rtcp_build_rr(buf + n, sizeof(buf) - n, _ourSsrc, _videoSsrc, fraction, (int32_t)MIN(_depack.lost, 0x7fffffULL),
                          (_seqCycles << 16) | _highestSeq, 0, _lastSr, dlsr);
    if (kinds & 1) { n += gf_rtcp_build_pli(buf + n, sizeof(buf) - n, _ourSsrc, _videoSsrc); _plis++; }
    if (kinds & 2) {
        uint16_t seqs[64];
        int count = gf_h264_take_missing(&_depack, seqs, 64);
        if (count) { n += gf_rtcp_build_nack(buf + n, sizeof(buf) - n, _ourSsrc, _videoSsrc, seqs, (size_t)count); _nacks++; }
    }
    if (kinds & 4) n += gf_rtcp_build_remb(buf + n, sizeof(buf) - n, _ourSsrc, _videoSsrc, (uint64_t)self.maxKbps * 1000);
    int total = gf_srtp_protect_rtcp(&_srtpTx, buf, n, sizeof(buf));
    if (total > 0) [self sendSelected:buf length:(size_t)total];
    _lastRtcp_us = now;
}

- (void)sendNack
{
    uint64_t now = GFMonotonicMicros();
    if (now - _lastNack_us < 20000) return;
    _lastNack_us = now;
    [self sendRTCPWithFeedback:2];
}

- (void)requestKeyframe
{
    [self perform:^{ _pliWanted = 1; }];
}

#pragma mark - Input

- (void)sendInputData:(NSData *)data
{
    if (!_sctp || !_inputOpen) return;
    gf_sctp_send(_sctp, INPUT_STREAM, GF_SCTP_PPID_BINARY, data.bytes, data.length, 1);
}

- (uint64_t)sessionMicros { return GFMonotonicMicros() - _start_us; }

- (void)sendGamepad:(GFGamepadState)state
{
    [self perform:^{
        if (memcmp(&_pad, &state, sizeof(state)) != 0) { _pad = state; _padDirty = 1; }
    }];
}

- (void)flushGamepadIfDue
{
    uint64_t now = GFMonotonicMicros();
    if (!_inputOpen) return;
    BOOL due = _padDirty && now - _lastGamepad_us >= 16000;
    BOOL keepalive = now - _lastGamepad_us >= 500000 && _lastGamepad_us != 0;
    if (!due && !keepalive) return;
    _padDirty = 0;
    _lastGamepad_us = now;
    _padSent = _pad;
    [self sendInputData:[self.input gamepadState:_pad controller:0 bitmap:1 timestamp:[self sessionMicros]]];
}

- (void)sendMouseMoveDX:(int)dx dy:(int)dy
{
    [self perform:^{ [self sendInputData:[self.input mouseMoveDX:(int16_t)MAX(-4096, MIN(4096, dx)) dy:(int16_t)MAX(-4096, MIN(4096, dy)) timestamp:[self sessionMicros]]]; }];
}

- (void)sendMouseButton:(int)button pressed:(BOOL)pressed
{
    [self perform:^{ [self sendInputData:[self.input mouseButton:(uint8_t)button pressed:pressed timestamp:[self sessionMicros]]]; }];
}

- (void)sendMouseWheel:(int)delta
{
    [self perform:^{ [self sendInputData:[self.input mouseWheel:(int16_t)delta timestamp:[self sessionMicros]]]; }];
}

- (void)sendKey:(GFKeyStroke)key pressed:(BOOL)pressed
{
    [self perform:^{ [self sendInputData:[self.input key:key pressed:pressed timestamp:[self sessionMicros]]]; }];
}

#pragma mark - Housekeeping

- (void)sendChecks
{
    uint64_t now = GFMonotonicMicros();
    NSString *username = [NSString stringWithFormat:@"%@:%@", self.offer.iceUfrag ?: @"", self.localUfrag];
    for (int i = 0; i < _candCount; i++) {
        if (_selected >= 0 && i != _selected) continue;
        int slot = -1;
        for (int k = 0; k < MAX_PENDING_CHECKS; k++) if (!_checks[k].used) { slot = k; break; }
        if (slot < 0) break;
        ice_check *c = &_checks[slot];
        for (int k = 0; k < 12; k++) c->tid[k] = (uint8_t)arc4random_uniform(256);
        c->candidate = i;
        c->sent_us = now;
        c->used = 1;
        uint8_t out[256];
        size_t n = gf_stun_build_request(out, sizeof(out), c->tid, [username UTF8String], [self.offer.icePwd UTF8String], 2122260223u, _tiebreaker, 1);
        if (n) [self sendTo:i data:out length:n];
        _cands[i].last_sent = now;
    }
    // forget checks that never got an answer
    for (int k = 0; k < MAX_PENDING_CHECKS; k++) if (_checks[k].used && now - _checks[k].sent_us > 3000000) _checks[k].used = 0;
}

- (void)housekeeping
{
    uint64_t now = GFMonotonicMicros();
    if (_state == GFPeerStateClosed) return;
    // ICE: checks every 300 ms until a candidate answers, then a keepalive every 2 s (consent and NAT bindings)
    if (_state == GFPeerStateChecking || _state == GFPeerStateConnected) {
        uint64_t interval = _selected < 0 ? 300000 : 2000000;
        if (now >= _nextCheck_us) {
            [self sendChecks];
            _nextCheck_us = now + interval;
        }
        if (_selected < 0 && now - _iceStart_us > 15000000) { [self fail:L(@"The game server did not answer (ICE timed out).")]; return; }
        if (_selected >= 0 && _lastIceResponse_us && now - _lastIceResponse_us > 15000000) { [self fail:L(@"Lost the connection to the game server.")]; return; }
    }
    if (_dtls && _selected >= 0 && !gf_dtls_is_connected(_dtls)) {
        if (gf_dtls_tick(_dtls, now) < 0) { [self fail:[NSString stringWithFormat:@"DTLS: %s", gf_dtls_last_error(_dtls)]]; return; }
        if (gf_dtls_is_connected(_dtls) && !_srtpReady) [self dtlsConnected];
        else if (now - _iceStart_us > 25000000 && !_srtpReady) { [self fail:L(@"The secure handshake with the game server timed out.")]; return; }
    }
    if (_sctp) gf_sctp_tick(_sctp, now);
    if (_srtpReady) {
        if (_pliWanted && now - _lastPli_us > 250000) {
            _pliWanted = 0;
            _lastPli_us = now;
            [self sendRTCPWithFeedback:1];
        }
        if (now - _lastRtcp_us > 1000000) [self sendRTCPWithFeedback:4];
        if (_inputOpen && now - _lastHeartbeat_us > 2000000) {
            _lastHeartbeat_us = now;
            [self sendInputData:[self.input heartbeat]];
        }
        [self flushGamepadIfDue];
        if (_lastVideo_us && now - _lastVideo_us > 4000000 && now - _lastPli_us > 2000000) {
            _lastPli_us = now;
            [self sendRTCPWithFeedback:1];
            GFLog(@"Peer: no video for 4 s, keyframe requested");
        }
    }
    if (now - _lastStats_us > 1000000) {
        double seconds = _lastStats_us ? (double)(now - _lastStats_us) / 1e6 : 1.0;
        _lastStats_us = now;
        uint64_t frames = _depack.frames;
        NSDictionary *stats = @{
            @"fps": @((double)(frames - _framesLast) / seconds),
            @"kbps": @((double)(_bytesIn - _bytesInLast) * 8.0 / seconds / 1000.0),
            @"lost": @(_depack.lost),
            @"frames": @(frames),
            @"dropped": @(_depack.dropped),
            @"rtt": @(_rtt_ms),
            @"pli": @(_plis),
            @"nack": @(_nacks),
            @"audio": @(_audioPackets),
            @"input": @(self.inputReady),
            @"sctpRto": @(_sctp ? gf_sctp_rto_ms(_sctp) : 0),
        };
        _framesLast = frames;
        _bytesInLast = _bytesIn;
        id<GFPeerDelegate> d = self.delegate;
        dispatch_async(dispatch_get_main_queue(), ^{ [d peer:self stats:stats]; });
    }
}

@end
