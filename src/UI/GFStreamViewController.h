#import <UIKit/UIKit.h>
#import "GFModels.h"

// The game on screen: signaling + WebRTC peer, hardware decoding into the GL view, audio, touch controls,
// the in-stream menu (keyboard, mouse mode, statistics, quit).
@interface GFStreamViewController : UIViewController
- (instancetype)initWithSession:(GFSession *)session title:(NSString *)title;
@property (nonatomic, copy) void (^onFinished)(NSString *message);   // called once when the stream is over (message may be nil)
// Debug hook (gfn6:stream?...): "key" with name, "pad" with buttons, "mouse" with dx/dy, "quit"
- (void)debugCommand:(NSString *)command params:(NSDictionary *)params;
- (NSString *)debugDescription;
@end
