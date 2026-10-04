#import <Foundation/Foundation.h>
#import "GFModels.h"
#import "GFSDP.h"
#import "GFInputProtocol.h"

@class GFPeer;

// All delegate calls arrive on the main thread.
@protocol GFPeerDelegate <NSObject>
- (void)peer:(GFPeer *)peer status:(NSString *)status;                                  // progress text for the overlay
- (void)peer:(GFPeer *)peer didCreateAnswer:(NSString *)sdp nvstSDP:(NSString *)nvstSDP;  // to go out through signaling
- (void)peer:(GFPeer *)peer didGatherCandidate:(NSDictionary *)candidate;
- (void)peerDidConnect:(GFPeer *)peer;                                                  // DTLS is up: media can flow
- (void)peer:(GFPeer *)peer inputReadyWithProtocolVersion:(NSInteger)version;
- (void)peer:(GFPeer *)peer didReceiveControlMessage:(NSDictionary *)message;          // control_channel JSON (timer warnings...)
- (void)peer:(GFPeer *)peer stats:(NSDictionary *)stats;                                // once a second
- (void)peer:(GFPeer *)peer didDisconnect:(NSString *)reason;
@end

// Called on the peer's network thread, as the packets arrive. The buffer is only valid during the call.
typedef void (^GFVideoSink)(const uint8_t *accessUnit, size_t length, uint32_t rtpTimestamp, BOOL keyframe, BOOL damaged);
typedef void (^GFAudioSink)(const uint8_t *payload, size_t length, uint16_t sequence, uint8_t payloadType, uint32_t rtpTimestamp);

// The WebRTC peer for one streaming session: UDP socket, ICE connectivity checks (STUN), DTLS-SRTP, RTP/RTCP for
// the video and audio tracks, SCTP data channels for input. Runs on its own thread.
@interface GFPeer : NSObject

- (instancetype)initWithSession:(GFSession *)session offer:(GFSDPOffer *)offer delegate:(id<GFPeerDelegate>)delegate;

@property (nonatomic, copy) GFVideoSink videoSink;
@property (nonatomic, copy) GFAudioSink audioSink;
@property (nonatomic) NSInteger streamWidth, streamHeight, streamFps, maxKbps;

- (void)start;                                              // makes the certificate and the answer, starts the socket
- (void)addRemoteCandidate:(NSDictionary *)candidate;        // from signaling
- (void)sendGamepad:(GFGamepadState)state;                   // latest state wins; sent 60 times a second while it changes
- (void)sendMouseMoveDX:(int)dx dy:(int)dy;
- (void)sendMouseButton:(int)button pressed:(BOOL)pressed;
- (void)sendMouseWheel:(int)delta;
- (void)sendKey:(GFKeyStroke)key pressed:(BOOL)pressed;
- (void)requestKeyframe;
- (void)close;

@property (nonatomic, readonly) BOOL isConnected;
@property (nonatomic, readonly) BOOL inputReady;

@end
