#import "GFAppDelegate.h"
#import "GFRootViewController.h"
#import "GFStreamViewController.h"
#import "GFTLSSocket.h"
#import "GFImageLoader.h"
#import "GFSettings.h"
#import "GFCloudMatch.h"
#import "GFAuth.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"
#import "GFVideoDecoder.h"
#include "gf_srtp.h"
#include "gf_sctp.h"
#include "gf_stun.h"
#include "gf_dtls.h"
#include "gf_rtp.h"
#include <dlfcn.h>
#include <signal.h>
#include <mach/mach.h>

// A button "named" text: by its title or by its accessibility label (icon buttons have no title), case does not matter
static BOOL GFButtonMatches(UIButton *button, NSString *text)
{
    for (NSString *name in @[ button.currentTitle ?: @"", button.accessibilityLabel ?: @"" ]) {
        if (name.length && [name rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

// Is the text in a label of this view? (Controls' own labels excepted: a segment title is not its table row's text.)
static BOOL GFViewContainsText(UIView *view, NSString *text)
{
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *s = ((UILabel *)view).text;
        return s.length && [s rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound;
    }
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIControl class]]) continue;
        if (GFViewContainsText(sub, text)) return YES;
    }
    return NO;
}

// Acts on a view "named" text the way a finger would: a button is pressed, a segment selected, the switch of a table
// row flipped, a table or grid row selected. YES when this view was the one.
static BOOL GFPressView(UIView *v, NSString *text)
{
    if ([v isKindOfClass:[UIButton class]]) {
        if (!GFButtonMatches((UIButton *)v, text)) return NO;
        [(UIButton *)v sendActionsForControlEvents:UIControlEventTouchUpInside];
        return YES;
    }
    if ([v isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segments = (UISegmentedControl *)v;
        for (NSUInteger i = 0; i < segments.numberOfSegments; i++) {
            NSString *title = [segments titleForSegmentAtIndex:i];
            if (title.length && [title rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                segments.selectedSegmentIndex = (NSInteger)i;
                [segments sendActionsForControlEvents:UIControlEventValueChanged];
                return YES;
            }
        }
        return NO;
    }
    if ([v isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)v;
        if (!GFViewContainsText(cell, text)) return NO;
        if ([cell.accessoryView isKindOfClass:[UISwitch class]]) {
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            [sw setOn:!sw.on animated:NO];
            [sw sendActionsForControlEvents:UIControlEventValueChanged];
            return YES;
        }
        UIView *table = cell.superview;
        while (table && ![table isKindOfClass:[UITableView class]]) table = table.superview;
        NSIndexPath *ip = [(UITableView *)table indexPathForCell:cell];
        id<UITableViewDelegate> delegate = [(UITableView *)table delegate];
        if (!ip || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        [delegate tableView:(UITableView *)table didSelectRowAtIndexPath:ip];
        return YES;
    }
    if ([v isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *cell = (UICollectionViewCell *)v;
        if (!GFViewContainsText(cell, text)) return NO;
        UIView *grid = cell.superview;
        while (grid && ![grid isKindOfClass:[UICollectionView class]]) grid = grid.superview;
        NSIndexPath *ip = [(UICollectionView *)grid indexPathForCell:cell];
        id<UICollectionViewDelegate> delegate = [(UICollectionView *)grid delegate];
        if (!ip || ![delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) return NO;
        [delegate collectionView:(UICollectionView *)grid didSelectItemAtIndexPath:ip];
        return YES;
    }
    return NO;
}

static UIViewController *GFTopController(UIViewController *root)
{
    UIViewController *top = root;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UITabBarController class]]) top = [(UITabBarController *)top selectedViewController];
    if ([top isKindOfClass:[UINavigationController class]]) top = [(UINavigationController *)top topViewController];
    return top;
}

@implementation GFAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    // (a peer that went away must not kill the process while a socket is written to)
    signal(SIGPIPE, SIG_IGN);
    [GFSettings registerDefaults];
    GFLog(@"GFN6 %@ starting on %@ (iOS %@)", [GFUtils appVersion], [GFUtils deviceModel], [UIDevice currentDevice].systemVersion);
    [GFTLSSocket warmUp];
    [[GFImageLoader shared] pruneDisk];
    [GFAuth shared];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.rootViewController = [[GFRootViewController alloc] init];
    self.window.rootViewController = self.rootViewController;
    self.window.backgroundColor = [[GFTheme shared] backgroundColor];
    [self.window makeKeyAndVisible];
    [application setStatusBarStyle:[[GFTheme shared] statusBarStyle] animated:NO];

    // a session left open by a crash would block the next launch: end it now
    if ([GFSettings rememberedSessionId].length && [GFAuth shared].isSignedIn) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[GFAuth shared] ensureFreshTokens:^(NSError *error) {
                if (!error) [GFCloudMatch stopRememberedSessionWithCompletion:nil];
            }];
        });
    }
    return YES;
}

- (void)selfTest
{
    GFLog(@"Self test: SRTP key derivation %@", gf_srtp_selftest() ? @"OK" : @"FAILED");
    GFLog(@"Self test: CRC32c %@", gf_sctp_selftest() ? @"OK" : @"FAILED");
    uint8_t tid[12] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, msg[256];
    size_t n = gf_stun_build_request(msg, sizeof(msg), tid, "remote:local", "secretpassword", 1, 2, 1);
    gf_stun_info info;
    int rc = gf_stun_parse(msg, n, "secretpassword", &info);
    GFLog(@"Self test: STUN build/parse %@ (len %lu, integrity %d, username %s)", (rc == 0 && info.integrity_ok == 1 && info.type == GF_STUN_BINDING_REQUEST) ? @"OK" : @"FAILED",
          (unsigned long)n, info.integrity_ok, info.username);
    uint64_t t0 = GFMonotonicMicros();
    gf_dtls *d = gf_dtls_create();
    GFLog(@"Self test: DTLS certificate %@ in %.0f ms, fingerprint %s", d ? @"OK" : @"FAILED", (GFMonotonicMicros() - t0) / 1000.0, d ? gf_dtls_fingerprint(d) : "-");
    if (d) gf_dtls_destroy(d);
    // an x264 High-profile SPS of a 1280x720 stream (with an emulation prevention byte inside) - picture size parsing
    static const uint8_t sps[] = { 0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x50, 0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60 };
    int w = 0, h = 0;
    int ok = gf_h264_sps_dimensions(sps, sizeof(sps), &w, &h) && w == 1280 && h == 720;
    GFLog(@"Self test: SPS parse %@ (%dx%d, expected 1280x720)", ok ? @"OK" : @"FAILED", w, h);
    GFLog(@"Self test: VideoToolbox %@", [GFVideoDecoder isAvailable] ? @"available" : @"MISSING");
}

// gfn6:play/<appId> starts a game, gfn6:search?q=<text> searches the catalog. Over SSH (uiopen) a few commands help
// checking the app: snapshot and screen write tmp/screen.png, press?n=1 presses a button of the alert on screen,
// press?title=X a button, segment, switch row or list row with that text, tab?n=1 switches the tab, back pops the
// navigation stack, selftest runs the protocol self tests, stream?cmd=key&name=escape drives the open stream,
// stats logs the memory in use and the stream state. The commands need a file named "debug" in the app's Documents.
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url sourceApplication:(NSString *)sourceApplication annotation:(id)annotation
{
    NSString *s = url.absoluteString ?: @"";
    if (![[s lowercaseString] hasPrefix:@"gfn6:"]) return NO;
    NSString *target = [s substringFromIndex:@"gfn6:".length];
    while ([target hasPrefix:@"/"]) target = [target substringFromIndex:1];
    NSString *query = nil;
    NSRange q = [target rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        query = [target substringFromIndex:q.location + 1];
        target = [target substringToIndex:q.location];
    }
    NSDictionary *params = query.length ? [GFUtils parseQuery:query] : @{};
    if ([target hasPrefix:@"play/"]) {
        [self.rootViewController openGameId:[target substringFromIndex:@"play/".length]];
        return YES;
    }
    if ([target isEqualToString:@"search"] && [params[@"q"] length]) {
        [self.rootViewController searchFor:params[@"q"]];
        return YES;
    }
    if ([target isEqualToString:@"signin"]) {
        [self.rootViewController presentSignIn];
        return YES;
    }
    BOOL debug = [[NSFileManager defaultManager] fileExistsAtPath:[[GFUtils documentsPath] stringByAppendingPathComponent:@"debug"]];
    if (!debug) return YES;
    UIViewController *top = GFTopController(self.rootViewController);
    if ([target isEqualToString:@"stats"]) {
        struct task_basic_info info;
        mach_msg_type_number_t count = TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_BASIC_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
            GFLog(@"Memory: %.1f MB resident, %.1f MB virtual", info.resident_size / 1048576.0, info.virtual_size / 1048576.0);
        }
        GFLog(@"Windows: %lu, top controller: %@, dark theme %d, signed in %d (%@)", (unsigned long)[UIApplication sharedApplication].windows.count,
              NSStringFromClass([top class]), [GFTheme shared].isDark, [GFAuth shared].isSignedIn, [GFAuth shared].displayName);
        if ([top isKindOfClass:[GFStreamViewController class]]) GFLog(@"Stream: %@", [(GFStreamViewController *)top debugDescription]);
        return YES;
    }
    if ([target isEqualToString:@"selftest"]) {
        [self selfTest];
        return YES;
    }
    if ([target isEqualToString:@"stream"]) {
        if ([top isKindOfClass:[GFStreamViewController class]]) [(GFStreamViewController *)top debugCommand:params[@"cmd"] ?: @"" params:params];
        else GFLog(@"Stream command: no stream open");
        return YES;
    }
    if ([target isEqualToString:@"snapshot"]) {
        // every visible window drawn into one picture (alerts and sheets have windows of their own)
        CGSize size = [UIScreen mainScreen].bounds.size;
        UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
        CGContextRef ctx = UIGraphicsGetCurrentContext();
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.hidden || w.alpha <= 0) continue;
            CGContextSaveGState(ctx);
            CGContextTranslateCTM(ctx, w.frame.origin.x, w.frame.origin.y);
            [w.layer renderInContext:ctx];
            CGContextRestoreGState(ctx);
        }
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = [UIImagePNGRepresentation(image) writeToFile:path atomically:YES];
        GFLog(@"Snapshot %@: %@", ok ? @"written to" : @"failed for", path);
        return YES;
    }
    if ([target isEqualToString:@"screen"]) {
        // what the screen really shows, video included (the system's own screen grab, resolved at run time)
        CGImageRef (*grab)(void) = (CGImageRef (*)(void))dlsym(RTLD_DEFAULT, "UIGetScreenImage");
        CGImageRef shot = grab ? grab() : NULL;
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"screen.png"];
        BOOL ok = NO;
        if (shot) {
            ok = [UIImagePNGRepresentation([UIImage imageWithCGImage:shot]) writeToFile:path atomically:YES];
            CGImageRelease(shot);
        }
        GFLog(@"Screen grab %@: %@", ok ? @"written to" : @"failed for", path);
        return YES;
    }
    if ([target isEqualToString:@"press"]) {
        NSString *byTitle = params[@"title"];
        NSInteger n = [params[@"n"] integerValue];
        NSMutableArray *views = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) [views addObject:w];
        BOOL pressed = NO;
        for (NSUInteger i = 0; i < views.count && !pressed; i++) {
            UIView *v = views[i];
            if (!byTitle.length && [v isKindOfClass:[UIAlertView class]] && ((UIAlertView *)v).visible) {
                UIAlertView *alert = (UIAlertView *)v;
                if ([alert.delegate respondsToSelector:@selector(alertView:clickedButtonAtIndex:)]) [alert.delegate alertView:alert clickedButtonAtIndex:n];
                [alert dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (!byTitle.length && [v isKindOfClass:[UIActionSheet class]] && ((UIActionSheet *)v).visible) {
                UIActionSheet *sheet = (UIActionSheet *)v;
                if ([sheet.delegate respondsToSelector:@selector(actionSheet:clickedButtonAtIndex:)]) [sheet.delegate actionSheet:sheet clickedButtonAtIndex:n];
                [sheet dismissWithClickedButtonIndex:n animated:NO];
                pressed = YES;
            } else if (byTitle.length && !v.hidden && GFPressView(v, byTitle)) {
                pressed = YES;
            } else {
                [views addObjectsFromArray:v.subviews];
            }
        }
        GFLog(@"Press %@: %@", query ?: @"", pressed ? @"done" : @"nothing found");
        return YES;
    }
    if ([target isEqualToString:@"tab"]) {
        [self.rootViewController selectTab:[params[@"n"] integerValue]];
        return YES;
    }
    if ([target isEqualToString:@"scroll"]) {
        // scroll?y=400 (or y=end) moves the largest scroll view on screen, so that rows further down can be pressed
        UIScrollView *largest = nil;
        NSMutableArray *views = [NSMutableArray array];
        for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.hidden) [views addObject:w];
        for (NSUInteger i = 0; i < views.count; i++) {
            UIView *v = views[i];
            if ([v isKindOfClass:[UIScrollView class]] && !v.hidden && v.window) {
                CGFloat area = v.bounds.size.width * v.bounds.size.height;
                if (!largest || area > largest.bounds.size.width * largest.bounds.size.height) largest = (UIScrollView *)v;
            }
            [views addObjectsFromArray:v.subviews];
        }
        if (largest) {
            CGFloat maxY = MAX(0, largest.contentSize.height + largest.contentInset.bottom - largest.bounds.size.height);
            CGFloat y = [params[@"y"] isEqualToString:@"end"] ? maxY : MIN(maxY, MAX(-largest.contentInset.top, [params[@"y"] doubleValue]));
            [largest setContentOffset:CGPointMake(largest.contentOffset.x, y) animated:NO];
        }
        GFLog(@"Scroll: %@", largest ? NSStringFromClass([largest class]) : @"no scroll view");
        return YES;
    }
    if ([target isEqualToString:@"back"]) {
        UIViewController *presented = self.rootViewController;
        while (presented.presentedViewController) presented = presented.presentedViewController;
        if (presented != self.rootViewController && ![presented isKindOfClass:[GFStreamViewController class]]) {
            [presented.presentingViewController dismissViewControllerAnimated:YES completion:nil];
            GFLog(@"Back: dismissed %@", NSStringFromClass([presented class]));
            return YES;
        }
        UINavigationController *nav = [top isKindOfClass:[UINavigationController class]] ? (UINavigationController *)top : top.navigationController;
        GFLog(@"Back: %@", [nav popViewControllerAnimated:YES] ? @"popped" : @"nothing to pop");
        return YES;
    }
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    [GFSettings save];
}

@end
