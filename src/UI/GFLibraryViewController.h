#import <UIKit/UIKit.h>

// The grid of games: the account's library (ownedOnly) or the whole catalog with server-side search
@interface GFLibraryViewController : UIViewController
- (instancetype)initWithOwnedOnly:(BOOL)ownedOnly;
- (void)searchFor:(NSString *)query;
- (void)reload;
@end
