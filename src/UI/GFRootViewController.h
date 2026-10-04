#import <UIKit/UIKit.h>

// The tab bar: My games, All games, Settings
@interface GFRootViewController : UITabBarController
- (void)selectTab:(NSInteger)index;
- (void)searchFor:(NSString *)query;
- (void)presentSignIn;
- (void)openGameId:(NSString *)appId;      // deep link gfn6:play/<appId>
@end
