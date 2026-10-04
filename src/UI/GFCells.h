#import <UIKit/UIKit.h>
#import "GFImageLoader.h"
#import "GFModels.h"

// A game in the grid: box art with the title under it
@interface GFGameCell : UICollectionViewCell
@property (nonatomic, strong, readonly) GFImageView *coverView;
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UILabel *badgeLabel;
- (void)showGame:(GFGame *)game;
+ (CGSize)cellSizeForWidth:(CGFloat)width;
@end
