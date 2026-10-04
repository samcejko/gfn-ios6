#import <Foundation/Foundation.h>
#import "GFModels.h"

typedef void (^GFSessionBlock)(GFSession *session, NSError *error);

// CloudMatch - NVIDIA's session broker: asks for a seat for a game, waits in the queue until the rig is ready,
// and ends sessions. One object per launch; everything happens on the main thread.
@interface GFCloudMatch : NSObject

- (instancetype)initWithAppId:(NSString *)appId;

// Progress for the launch screen: a sentence, the queue position (0 = none) and the estimate in seconds
@property (nonatomic, copy) void (^onProgress)(NSString *message, NSInteger queuePosition, NSInteger etaSeconds);

// Creates the session (after ending whatever this account still has open) and polls until it is ready to stream.
- (void)startWithCompletion:(GFSessionBlock)completion;
// Stops waiting and ends the session on NVIDIA's side (the completion is not called afterwards)
- (void)cancel;

// Ends a session (DELETE at its own zone). Best effort; completion runs when NVIDIA answered or gave up.
+ (void)stopSession:(GFSession *)session completion:(dispatch_block_t)completion;
// Ends the session remembered from a run that did not finish cleanly (crash, force quit)
+ (void)stopRememberedSessionWithCompletion:(dispatch_block_t)completion;

@end
