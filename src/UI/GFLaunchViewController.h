#import <UIKit/UIKit.h>

// The queue: asks CloudMatch for a seat, shows the progress, then hands over to the stream screen
@interface GFLaunchViewController : UIViewController
- (instancetype)initWithAppId:(NSString *)appId title:(NSString *)title;
@end
