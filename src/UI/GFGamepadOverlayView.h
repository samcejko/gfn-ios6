#import <UIKit/UIKit.h>
#import "GFInputProtocol.h"

// The on-screen Xbox-style gamepad: two sticks, D-pad, A/B/X/Y, bumpers, triggers, Back/Start. Touches that land
// on a control are consumed; the rest pass through to whatever is underneath (the mouse surface).
@interface GFGamepadOverlayView : UIView
@property (nonatomic, copy) void (^onChange)(GFGamepadState state);
@property (nonatomic) CGFloat controlOpacity;        // 0.2..0.9
@property (nonatomic, readonly) GFGamepadState state;
@end
