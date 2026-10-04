#import <UIKit/UIKit.h>
#import "GFModels.h"

// One game: artwork, facts and the Play button
@interface GFGameDetailViewController : UIViewController
- (instancetype)initWithGame:(GFGame *)game;
@end
