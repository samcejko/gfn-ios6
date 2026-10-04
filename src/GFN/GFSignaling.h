#import <Foundation/Foundation.h>
#import "GFModels.h"

@class GFSignaling;

// All callbacks on the main thread
@protocol GFSignalingDelegate <NSObject>
- (void)signalingDidConnect:(GFSignaling *)signaling;
- (void)signaling:(GFSignaling *)signaling didReceiveOffer:(NSString *)sdp;
- (void)signaling:(GFSignaling *)signaling didReceiveCandidate:(NSDictionary *)candidate;    // candidate, sdpMid, sdpMLineIndex, usernameFragment
- (void)signaling:(GFSignaling *)signaling didClose:(NSString *)reason;
@end

// NVST signaling: the WebSocket the game seat uses to hand us its SDP offer and swap ICE candidates. The server
// side is a tiny peer registry (peer_info / peer_msg / ack / hb messages).
@interface GFSignaling : NSObject

- (instancetype)initWithSession:(GFSession *)session delegate:(id<GFSignalingDelegate>)delegate;
- (void)connect;
- (void)sendAnswer:(NSString *)sdp nvstSDP:(NSString *)nvstSDP;
- (void)sendCandidate:(NSDictionary *)candidate;
- (void)close;

@property (nonatomic, readonly) NSString *connectedHost;

@end
