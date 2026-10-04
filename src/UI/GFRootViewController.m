#import "GFRootViewController.h"
#import "GFLibraryViewController.h"
#import "GFSettingsViewController.h"
#import "GFLoginViewController.h"
#import "GFLaunchViewController.h"
#import "GFTheme.h"
#import "GFCommon.h"

@interface GFRootViewController ()
@property (nonatomic, strong) GFLibraryViewController *library;
@property (nonatomic, strong) GFLibraryViewController *store;
@property (nonatomic, strong) GFSettingsViewController *settings;
@end

@implementation GFRootViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    GFTheme *theme = [GFTheme shared];
    self.library = [[GFLibraryViewController alloc] initWithOwnedOnly:YES];
    self.library.title = L(@"My games");
    self.store = [[GFLibraryViewController alloc] initWithOwnedOnly:NO];
    self.store.title = L(@"All games");
    self.settings = [[GFSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    self.settings.title = L(@"Settings");

    NSMutableArray *controllers = [NSMutableArray array];
    NSArray *pairs = @[ @[ self.library, [theme tabIconLibrary] ], @[ self.store, [theme tabIconSearch] ], @[ self.settings, [theme tabIconSettings] ] ];
    for (NSArray *pair in pairs) {
        UIViewController *vc = pair[0];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.tabBarItem = [[UITabBarItem alloc] initWithTitle:vc.title image:pair[1] tag:controllers.count];
        [controllers addObject:nav];
    }
    self.viewControllers = controllers;
    [self applyTheme];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyTheme) name:GFThemeDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applyTheme
{
    GFTheme *theme = [GFTheme shared];
    [theme applyToTabBar:self.tabBar];
    for (UINavigationController *nav in self.viewControllers) [theme applyToNavigationBar:nav.navigationBar];
    [[UIApplication sharedApplication] setStatusBarStyle:[theme statusBarStyle] animated:YES];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)selectTab:(NSInteger)index
{
    if (index >= 0 && index < (NSInteger)self.viewControllers.count) self.selectedIndex = (NSUInteger)index;
}

- (void)searchFor:(NSString *)query
{
    self.selectedIndex = 1;
    [self.store searchFor:query];
}

- (void)presentSignIn
{
    GFLoginViewController *login = [[GFLoginViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    [[GFTheme shared] applyToNavigationBar:nav.navigationBar];
    if (GFIsPad()) nav.modalPresentationStyle = UIModalPresentationFormSheet;
    UIViewController *top = self.presentedViewController ?: self;
    [top presentViewController:nav animated:YES completion:nil];
}

- (void)openGameId:(NSString *)appId
{
    if (!appId.length) return;
    GFLaunchViewController *launch = [[GFLaunchViewController alloc] initWithAppId:appId title:appId];
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:launch animated:YES completion:nil];
}

@end
