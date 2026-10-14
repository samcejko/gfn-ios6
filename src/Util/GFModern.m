// GFModern.m - see GFModern.h. Shared by all of samcejko's iOS 6 apps (only the prefix differs).
//
// Compiled twice: with the iOS 9.3 SDK for the armv7 build (deployment target iOS 6.0) and with the iOS 16.5 SDK
// for the arm64 build (deployment target iOS 14.0). APIs newer than a SDK are behind __IPHONE_OS_VERSION_MAX_ALLOWED,
// APIs newer than the running iOS behind version checks; so this file opts out of the availability errors of the
// app's common header (which it does not import) and of the deprecation warnings of the iOS 6 era APIs it bridges.
#import "GFModern.h"
#import <objc/runtime.h>

#pragma clang diagnostic ignored "-Wunguarded-availability"
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wunknown-pragmas"

#pragma mark - Versions

static NSInteger GFMajorVersion(void)
{
    static NSInteger major = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        major = [[[[UIDevice currentDevice] systemVersion] componentsSeparatedByString:@"."][0] integerValue];
        if (major < 1) major = 6;
    });
    return major;
}

BOOL GFModernIOS(void) { return GFMajorVersion() >= 7; }
static BOOL GFAtLeast(NSInteger major) { return GFMajorVersion() >= major; }

#pragma mark - Safe areas

UIEdgeInsets GFSafeAreaInsets(UIView *view)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (view && GFAtLeast(11)) return view.safeAreaInsets;
#endif
    return UIEdgeInsetsZero;
}

UIEdgeInsets GFScreenSafeAreaInsets(void)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (GFAtLeast(11)) {
        UIApplication *app = [UIApplication sharedApplication];
        UIWindow *window = app.keyWindow ?: app.windows.firstObject;
        if (window) return window.safeAreaInsets;
    }
#endif
    return UIEdgeInsetsZero;
}

UIStatusBarStyle GFModernStatusBarStyle(UIStatusBarStyle ios6Style)
{
    // 1 is UIStatusBarStyleLightContent from iOS 7 on (UIStatusBarStyleBlackTranslucent of the iOS 6 headers)
    return GFModernIOS() ? (UIStatusBarStyle)1 : ios6Style;
}

CGFloat GFModernTopInset(UIView *view, CGFloat ios6Value)
{
    if (!GFModernIOS()) return ios6Value;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (GFAtLeast(11) && view.window) return view.safeAreaInsets.top;
#endif
    if ([UIApplication sharedApplication].statusBarHidden) return 0;
    CGRect frame = [UIApplication sharedApplication].statusBarFrame;
    return MIN(frame.size.width, frame.size.height);
}

CGFloat GFModernGroupedCellMargins(CGFloat ios6Margins)
{
    if (!GFModernIOS()) return ios6Margins;
    return GFAtLeast(13) ? 40 : 0;
}

#pragma mark - The iOS 6 artwork, drawn in code

static UIColor *GFRGB(NSInteger r, NSInteger g, NSInteger b)
{
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1.0];
}

// The colors of one glossy surface: a gradient from c1 to c2 in the upper half, a hard edge, c3 to c4 below.
typedef struct {
    NSInteger c1, c2, c3, c4;   // 0xRRGGBB
    NSInteger line;             // the border (bars: the bottom line; buttons: the outline)
    CGFloat highlight;          // alpha of the white line along the top edge
} GFGloss;

static UIColor *GFHex(NSInteger rgb) { return GFRGB((rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff); }

static void GFDrawGloss(CGContextRef ctx, CGRect rect, GFGloss g)
{
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGFloat locations[4] = { 0.0, 0.5, 0.5, 1.0 };
    NSArray *colors = @[ (id)GFHex(g.c1).CGColor, (id)GFHex(g.c2).CGColor, (id)GFHex(g.c3).CGColor, (id)GFHex(g.c4).CGColor ];
    CGGradientRef gradient = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)colors, locations);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(CGRectGetMidX(rect), CGRectGetMinY(rect)),
                                CGPointMake(CGRectGetMidX(rect), CGRectGetMaxY(rect)), 0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(cs);
}

// Bars (navigation bar, toolbar, search bar background): the iOS 6 blue, or the black of UIBarStyleBlack
static GFGloss GFBarGloss(BOOL black)
{
    GFGloss blue = { 0xb0bccd, 0x889bb3, 0x8195af, 0x6d84a2, 0x2d3642, 0.35 };
    GFGloss dark = { 0x4d4d4d, 0x2e2e2e, 0x262626, 0x141414, 0x000000, 0.18 };
    return black ? dark : blue;
}

// A bar background. `above` is the height of the status bar the bar extends under on iOS 7 and newer (the iOS 6
// status bar took the tint of the bar below it, so that part is drawn as a lighter gradient of the same color).
static UIImage *GFBarImage(BOOL black, CGFloat above, CGFloat height)
{
    GFGloss g = GFBarGloss(black);
    CGSize size = CGSizeMake(2, above + height);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (above > 0) {
        GFGloss status = g;
        status.c2 = status.c1;
        status.c3 = status.c1;
        status.c4 = g.c2;
        GFDrawGloss(ctx, CGRectMake(0, 0, size.width, above), status);
    }
    GFDrawGloss(ctx, CGRectMake(0, above, size.width, height), g);
    [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
    UIRectFillUsingBlendMode(CGRectMake(0, above, size.width, 1), kCGBlendModeNormal);
    [GFHex(g.line) setFill];
    UIRectFill(CGRectMake(0, size.height - 1, size.width, 1));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(1, 0, 1, 0) resizingMode:UIImageResizingModeStretch];
}

// Bordered bar buttons: normal, pressed and the blue "Done" style, on the blue or the black bar
static GFGloss GFButtonGloss(BOOL black, BOOL highlighted, BOOL done)
{
    if (done) {
        GFGloss d = { 0x6aa0e6, 0x3c7cd8, 0x3374d4, 0x2563c6, 0x1d478a, 0.4 };
        GFGloss dh = { 0x4e7fc4, 0x2a62b8, 0x235bb4, 0x184ea6, 0x15397a, 0.2 };
        return highlighted ? dh : d;
    }
    if (black) {
        GFGloss b = { 0x6e6e6e, 0x4b4b4b, 0x434343, 0x333333, 0x0b0b0b, 0.25 };
        GFGloss bh = { 0x4a4a4a, 0x303030, 0x2a2a2a, 0x1e1e1e, 0x050505, 0.1 };
        return highlighted ? bh : b;
    }
    GFGloss n = { 0x8fa4c4, 0x748cb1, 0x6d86ad, 0x5f79a3, 0x3b4b62, 0.4 };
    GFGloss nh = { 0x62789a, 0x4e6488, 0x485f84, 0x3f567c, 0x2a3648, 0.2 };
    return highlighted ? nh : n;
}

// The outline of a bar button (30 pt tall): a rounded rectangle, or the iOS 6 back button with its pointed left end
static UIBezierPath *GFButtonPath(CGRect r, BOOL back)
{
    CGFloat radius = 5.0;
    if (!back) return [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:radius];
    CGFloat tip = 12.0, midY = CGRectGetMidY(r);
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(CGRectGetMinX(r) + tip, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMinY(r))];
    [p addArcWithCenter:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMinY(r) + radius) radius:radius startAngle:-M_PI_2 endAngle:0 clockwise:YES];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - radius)];
    [p addArcWithCenter:CGPointMake(CGRectGetMaxX(r) - radius, CGRectGetMaxY(r) - radius) radius:radius startAngle:0 endAngle:M_PI_2 clockwise:YES];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r) + tip, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r) + 1.5, midY + 1.5)];
    [p addQuadCurveToPoint:CGPointMake(CGRectGetMinX(r) + 1.5, midY - 1.5) controlPoint:CGPointMake(CGRectGetMinX(r), midY)];
    [p closePath];
    return p;
}

static UIImage *GFButtonImage(BOOL black, BOOL highlighted, BOOL done, BOOL back)
{
    GFGloss g = GFButtonGloss(black, highlighted, done);
    CGSize size = CGSizeMake(back ? 28 : 14, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect inner = CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5);
    UIBezierPath *path = GFButtonPath(inner, back);
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    GFDrawGloss(ctx, CGRectMake(0, 0, size.width, size.height), g);
    [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
    UIRectFillUsingBlendMode(CGRectMake(0, 1, size.width, 1), kCGBlendModeNormal);
    CGContextRestoreGState(ctx);
    [GFHex(g.line) setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    UIEdgeInsets caps = back ? UIEdgeInsetsMake(7, 15, 7, 6) : UIEdgeInsetsMake(7, 6, 7, 6);
    return [image resizableImageWithCapInsets:caps resizingMode:UIImageResizingModeStretch];
}

// A fully transparent image (hides the iOS 7 back chevron: the pointed button background draws the arrow)
static UIImage *GFClearImage(CGSize size)
{
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

// The white rounded text field of the iOS 6 search bar
static UIImage *GFSearchFieldImage(void)
{
    CGSize size = CGSizeMake(30, 30);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5) cornerRadius:14.5];
    [[UIColor whiteColor] setFill];
    [path fill];
    [[UIColor colorWithWhite:0.0 alpha:0.35] setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(14, 14, 14, 14) resizingMode:UIImageResizingModeStretch];
}

// The black iOS 6 tab bar, and the darker rounded area behind its selected item
static UIImage *GFTabBarImage(void)
{
    GFGloss g = { 0x484848, 0x2a2a2a, 0x202020, 0x0a0a0a, 0x000000, 0.2 };
    CGSize size = CGSizeMake(2, 49);
    UIGraphicsBeginImageContextWithOptions(size, YES, 0);
    GFDrawGloss(UIGraphicsGetCurrentContext(), CGRectMake(0, 0, size.width, size.height), g);
    [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
    UIRectFillUsingBlendMode(CGRectMake(0, 0, size.width, 1), kCGBlendModeNormal);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(1, 0, 1, 0) resizingMode:UIImageResizingModeStretch];
}

static UIImage *GFTabSelectionImage(void)
{
    CGSize size = CGSizeMake(64, 49);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 3, size.width - 4, size.height - 6) cornerRadius:5];
    [[UIColor colorWithWhite:1.0 alpha:0.14] setFill];
    [path fill];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(10, 10, 10, 10) resizingMode:UIImageResizingModeStretch];
}

// Segments of a plain segmented control: light gray, the selected one darker
static UIImage *GFSegmentImage(BOOL selected)
{
    GFGloss normal = { 0xfbfbfb, 0xe6e6e6, 0xdcdcdc, 0xc9c9c9, 0x8e8e8e, 0.0 };
    GFGloss sel = { 0x9c9c9c, 0x7a7a7a, 0x717171, 0x5e5e5e, 0x4a4a4a, 0.15 };
    GFGloss g = selected ? sel : normal;
    CGSize size = CGSizeMake(14, 32);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect inner = CGRectInset(CGRectMake(0, 0, size.width, size.height), 0.5, 0.5);
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:inner cornerRadius:5];
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path.CGPath);
    CGContextClip(ctx);
    GFDrawGloss(ctx, CGRectMake(0, 0, size.width, size.height), g);
    if (g.highlight > 0) {
        [[UIColor colorWithWhite:1.0 alpha:g.highlight] setFill];
        UIRectFillUsingBlendMode(CGRectMake(0, 1, size.width, 1), kCGBlendModeNormal);
    }
    CGContextRestoreGState(ctx);
    [GFHex(g.line) setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(7, 6, 7, 6) resizingMode:UIImageResizingModeStretch];
}

static UIImage *GFSegmentDividerImage(void)
{
    CGSize size = CGSizeMake(1, 32);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [GFHex(0x8e8e8e) setFill];
    UIRectFill(CGRectMake(0, 0, size.width, size.height));
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

#pragma mark - Text styles

// White, bold, with the dark shadow above the glyphs that iOS 6 gave bar titles and bar buttons
static NSDictionary *GFEmbossedTextAttributes(CGFloat fontSize)
{
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    shadow.shadowOffset = CGSizeMake(0, -1);
    return @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize],
              NSForegroundColorAttributeName: [UIColor whiteColor],
              NSShadowAttributeName: shadow };
}

static NSDictionary *GFEngravedTextAttributes(CGFloat fontSize, UIColor *color)
{
    NSShadow *shadow = [[NSShadow alloc] init];
    shadow.shadowColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    shadow.shadowOffset = CGSizeMake(0, 1);
    return @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:fontSize],
              NSForegroundColorAttributeName: color,
              NSShadowAttributeName: shadow };
}

#pragma mark - Bars

// The height of the status bar the navigation bar reaches under in portrait (0 when it is hidden)
static CGFloat GFStatusBarHeight(void)
{
    CGRect frame = [UIApplication sharedApplication].statusBarFrame;
    CGFloat h = MIN(frame.size.width, frame.size.height);
    if (h <= 0) h = 20;
    return h;
}

static BOOL GFIsBlack(UIBarStyle style) { return style == UIBarStyleBlack; }

// Legacy customization (iOS 7-12; also what iOS 13 and newer fall back to where no appearance object is set).
// Whatever the look, the bar is dark: UIBarStyleBlack makes the status bar's text light and the title white.
static void GFApplyLegacyNavigationBar(UINavigationBar *bar, BOOL black)
{
    UIImage *tall = GFBarImage(black, GFStatusBarHeight(), 44);
    UIImage *compact = GFBarImage(black, 0, 32);
    [bar setBackgroundImage:tall forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:compact forBarMetrics:(UIBarMetrics)1];   // UIBarMetricsCompact (landscape iPhone)
    [bar setShadowImage:GFClearImage(CGSizeMake(1, 1))];
    [bar setTitleTextAttributes:GFEmbossedTextAttributes(20)];
    [bar setTintColor:[UIColor whiteColor]];
    [bar setBarStyle:UIBarStyleBlack];
    if ([bar respondsToSelector:@selector(setBackIndicatorImage:)]) {
        [bar setBackIndicatorImage:GFClearImage(CGSizeMake(1, 20))];
        [bar setBackIndicatorTransitionMaskImage:GFClearImage(CGSizeMake(1, 20))];
    }
}

static void GFApplyLegacyBarButtons(UIBarButtonItem *proxy, BOOL black)
{
    for (int metrics = 0; metrics < 2; metrics++) {
        [proxy setBackgroundImage:GFButtonImage(black, NO, NO, NO) forState:UIControlStateNormal barMetrics:(UIBarMetrics)metrics];
        [proxy setBackgroundImage:GFButtonImage(black, YES, NO, NO) forState:UIControlStateHighlighted barMetrics:(UIBarMetrics)metrics];
        [proxy setBackgroundImage:GFButtonImage(black, NO, YES, NO) forState:UIControlStateNormal style:UIBarButtonItemStyleDone barMetrics:(UIBarMetrics)metrics];
        [proxy setBackgroundImage:GFButtonImage(black, YES, YES, NO) forState:UIControlStateHighlighted style:UIBarButtonItemStyleDone barMetrics:(UIBarMetrics)metrics];
        [proxy setBackButtonBackgroundImage:GFButtonImage(black, NO, NO, YES) forState:UIControlStateNormal barMetrics:(UIBarMetrics)metrics];
        [proxy setBackButtonBackgroundImage:GFButtonImage(black, YES, NO, YES) forState:UIControlStateHighlighted barMetrics:(UIBarMetrics)metrics];
        [proxy setBackButtonTitlePositionAdjustment:UIOffsetMake(6, 0) forBarMetrics:(UIBarMetrics)metrics];
    }
    [proxy setTitleTextAttributes:GFEmbossedTextAttributes(12) forState:UIControlStateNormal];
    [proxy setTitleTextAttributes:GFEmbossedTextAttributes(12) forState:UIControlStateHighlighted];
}

static void GFApplyLegacyToolbar(UIToolbar *bar, BOOL black)
{
    [bar setBackgroundImage:GFBarImage(black, 0, 44) forToolbarPosition:(UIBarPosition)0 barMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:GFBarImage(black, 0, 32) forToolbarPosition:(UIBarPosition)0 barMetrics:(UIBarMetrics)1];
    [bar setShadowImage:GFClearImage(CGSizeMake(1, 1)) forToolbarPosition:(UIBarPosition)0];
    [bar setTintColor:[UIColor whiteColor]];
}

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
// iOS 13 and newer: the appearance objects (without them iOS 15 draws the bars transparent at the scroll edge)
static UIBarButtonItemAppearance *GFButtonAppearance(BOOL black, BOOL done, BOOL back)
{
    UIBarButtonItemAppearance *a = [[UIBarButtonItemAppearance alloc] initWithStyle:done ? UIBarButtonItemStyleDone : UIBarButtonItemStylePlain];
    NSDictionary *text = GFEmbossedTextAttributes(12);
    a.normal.backgroundImage = GFButtonImage(black, NO, done, back);
    a.normal.titleTextAttributes = text;
    a.highlighted.backgroundImage = GFButtonImage(black, YES, done, back);
    a.highlighted.titleTextAttributes = text;
    a.disabled.backgroundImage = a.normal.backgroundImage;
    a.disabled.titleTextAttributes = @{ NSFontAttributeName: [UIFont boldSystemFontOfSize:12], NSForegroundColorAttributeName: [UIColor colorWithWhite:1.0 alpha:0.5] };
    if (back) {
        a.normal.titlePositionAdjustment = UIOffsetMake(6, 0);
        a.highlighted.titlePositionAdjustment = UIOffsetMake(6, 0);
        a.disabled.titlePositionAdjustment = UIOffsetMake(6, 0);
    }
    return a;
}

static UINavigationBarAppearance *GFNavigationBarAppearance(BOOL black, BOOL compact)
{
    UINavigationBarAppearance *a = [[UINavigationBarAppearance alloc] init];
    [a configureWithOpaqueBackground];
    a.backgroundImage = compact ? GFBarImage(black, 0, 32) : GFBarImage(black, GFStatusBarHeight(), 44);
    a.backgroundImageContentMode = UIViewContentModeScaleToFill;
    a.shadowColor = nil;
    a.shadowImage = nil;
    a.titleTextAttributes = GFEmbossedTextAttributes(compact ? 17 : 20);
    a.largeTitleTextAttributes = GFEmbossedTextAttributes(34);
    a.buttonAppearance = GFButtonAppearance(black, NO, NO);
    a.doneButtonAppearance = GFButtonAppearance(black, YES, NO);
    a.backButtonAppearance = GFButtonAppearance(black, NO, YES);
    [a setBackIndicatorImage:GFClearImage(CGSizeMake(1, 20)) transitionMaskImage:GFClearImage(CGSizeMake(1, 20))];
    return a;
}

static void GFSetNavigationBarAppearances(UINavigationBar *bar, UINavigationBarAppearance *standard, UINavigationBarAppearance *compact)
{
    [bar setStandardAppearance:standard];
    [bar setScrollEdgeAppearance:standard];
    [bar setCompactAppearance:compact];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (GFAtLeast(15)) [bar setCompactScrollEdgeAppearance:compact];
#endif
}

static void GFApplyNavigationBarAppearance(UINavigationBar *bar, BOOL black)
{
    GFSetNavigationBarAppearances(bar, GFNavigationBarAppearance(black, NO), GFNavigationBarAppearance(black, YES));
    [bar setTintColor:[UIColor whiteColor]];
    [bar setBarStyle:UIBarStyleBlack];
}

static UIToolbarAppearance *GFToolbarAppearance(BOOL black, BOOL compact)
{
    UIToolbarAppearance *a = [[UIToolbarAppearance alloc] init];
    [a configureWithOpaqueBackground];
    a.backgroundImage = GFBarImage(black, 0, compact ? 32 : 44);
    a.backgroundImageContentMode = UIViewContentModeScaleToFill;
    a.shadowColor = nil;
    a.shadowImage = nil;
    return a;
}

static void GFApplyToolbarAppearance(UIToolbar *bar, BOOL black)
{
    UIToolbarAppearance *standard = GFToolbarAppearance(black, NO);
    UIToolbarAppearance *compact = GFToolbarAppearance(black, YES);
    [bar setStandardAppearance:standard];
    [bar setCompactAppearance:compact];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (GFAtLeast(15)) {
        [bar setScrollEdgeAppearance:standard];
        [bar setCompactScrollEdgeAppearance:compact];
    }
#endif
    [bar setTintColor:[UIColor whiteColor]];
}

static void GFSetTabBarAppearance(UITabBar *bar, UITabBarAppearance *a)
{
    [bar setStandardAppearance:a];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000
    if (GFAtLeast(15)) [bar setScrollEdgeAppearance:a];
#endif
}

static void GFApplyTabBarAppearance(UITabBar *bar)
{
    UITabBarAppearance *a = [[UITabBarAppearance alloc] init];
    [a configureWithOpaqueBackground];
    a.backgroundImage = GFTabBarImage();
    a.shadowColor = nil;
    a.shadowImage = nil;
    a.selectionIndicatorImage = GFTabSelectionImage();
    UIColor *selected = GFRGB(84, 164, 255), *normal = GFRGB(146, 146, 146);
    for (UITabBarItemAppearance *item in @[ a.stackedLayoutAppearance, a.inlineLayoutAppearance, a.compactInlineLayoutAppearance ]) {
        item.selected.iconColor = selected;
        item.selected.titleTextAttributes = @{ NSForegroundColorAttributeName: selected, NSFontAttributeName: [UIFont boldSystemFontOfSize:10] };
        item.normal.iconColor = normal;
        item.normal.titleTextAttributes = @{ NSForegroundColorAttributeName: normal, NSFontAttributeName: [UIFont boldSystemFontOfSize:10] };
    }
    GFSetTabBarAppearance(bar, a);
    [bar setTintColor:selected];
}
#endif

void GFModernApplyNavigationBarBackground(UINavigationBar *bar, UIImage *image, NSDictionary *titleAttributes,
                                             UIImage *buttonImage, UIImage *buttonImageHighlighted, NSDictionary *buttonTitleAttributes)
{
    if (!bar || !image || !GFModernIOS()) return;
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) {
        UINavigationBarAppearance *a = [[UINavigationBarAppearance alloc] init];
        [a configureWithOpaqueBackground];
        a.backgroundImage = image;
        a.backgroundImageContentMode = UIViewContentModeScaleToFill;
        a.shadowColor = nil;
        a.shadowImage = nil;
        if (titleAttributes) a.titleTextAttributes = titleAttributes;
        if (buttonImage || buttonTitleAttributes) {
            for (UIBarButtonItemAppearance *b in @[ a.buttonAppearance, a.doneButtonAppearance, a.backButtonAppearance ]) {
                if (buttonImage) {
                    b.normal.backgroundImage = buttonImage;
                    b.highlighted.backgroundImage = buttonImageHighlighted ?: buttonImage;
                    b.disabled.backgroundImage = buttonImage;
                }
                if (buttonTitleAttributes) {
                    b.normal.titleTextAttributes = buttonTitleAttributes;
                    b.highlighted.titleTextAttributes = buttonTitleAttributes;
                }
            }
        }
        GFSetNavigationBarAppearances(bar, a, a);
        return;
    }
#endif
    [bar setBackgroundImage:image forBarMetrics:UIBarMetricsDefault];
    [bar setBackgroundImage:image forBarMetrics:(UIBarMetrics)1];
    [bar setShadowImage:GFClearImage(CGSizeMake(1, 1))];
    if (titleAttributes) [bar setTitleTextAttributes:titleAttributes];
    // (the legacy button images come from the app's own UIBarButtonItem appearance; nothing more to do here)
}

UITextField *GFModernSearchBarTextField(UISearchBar *bar)
{
    if (!bar) return nil;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) return bar.searchTextField;
#endif
    NSMutableArray *queue = [NSMutableArray arrayWithObject:bar];
    while (queue.count) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:[UITextField class]]) return (UITextField *)v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

void GFModernApplyTabBarBackground(UITabBar *bar, UIImage *image)
{
    if (!bar || !image || !GFModernIOS()) return;
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) {
        UITabBarAppearance *a = [[UITabBarAppearance alloc] init];
        [a configureWithOpaqueBackground];
        a.backgroundImage = image;
        a.shadowColor = nil;
        a.shadowImage = nil;
        GFSetTabBarAppearance(bar, a);
        return;
    }
#endif
    [bar setBackgroundImage:image];
    [bar setShadowImage:GFClearImage(CGSizeMake(1, 1))];
}

void GFModernKeepScrollViewInsets(UIScrollView *scrollView)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000
    if (scrollView && GFAtLeast(11)) scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
#endif
}

void GFModernDisableSwipeBack(UINavigationController *nav)
{
    if (nav && [nav respondsToSelector:@selector(interactivePopGestureRecognizer)]) nav.interactivePopGestureRecognizer.enabled = NO;
}

void GFModernStatusBarChanged(UIViewController *vc)
{
    if (vc && [vc respondsToSelector:@selector(setNeedsStatusBarAppearanceUpdate)]) [vc setNeedsStatusBarAppearanceUpdate];
}

void GFModernStyleNavigationBar(UINavigationBar *bar)
{
    if (!bar || !GFModernIOS()) return;
    BOOL black = GFIsBlack(bar.barStyle);
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) { GFApplyNavigationBarAppearance(bar, black); return; }
#endif
    GFApplyLegacyNavigationBar(bar, black);
}

void GFModernStyleToolbar(UIToolbar *bar)
{
    if (!bar || !GFModernIOS()) return;
    BOOL black = GFIsBlack(bar.barStyle);
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) { GFApplyToolbarAppearance(bar, black); return; }
#endif
    GFApplyLegacyToolbar(bar, black);
}

void GFModernStyleSearchBar(UISearchBar *bar)
{
    if (!bar || !GFModernIOS()) return;
    BOOL black = GFIsBlack(bar.barStyle);
    bar.translucent = NO;
    [bar setBackgroundImage:GFBarImage(black, 0, 44)];
    [bar setSearchFieldBackgroundImage:GFSearchFieldImage() forState:UIControlStateNormal];
    [bar setSearchTextPositionAdjustment:UIOffsetMake(4, 0)];
    bar.tintColor = [UIColor whiteColor];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) {
        bar.searchTextField.tintColor = GFRGB(30, 90, 200);
        bar.searchTextField.textColor = [UIColor blackColor];
    }
#endif
}

void GFModernStyleTabBar(UITabBar *bar)
{
    if (!bar || !GFModernIOS()) return;
    bar.translucent = NO;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) { GFApplyTabBarAppearance(bar); return; }
#endif
    [bar setBackgroundImage:GFTabBarImage()];
    [bar setSelectionIndicatorImage:GFTabSelectionImage()];
    [bar setShadowImage:GFClearImage(CGSizeMake(1, 1))];
    [bar setTintColor:GFRGB(84, 164, 255)];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 100000
    if ([bar respondsToSelector:@selector(setUnselectedItemTintColor:)]) [bar setUnselectedItemTintColor:GFRGB(146, 146, 146)];
#endif
}

#pragma mark - The defaults for every bar (UIAppearance)

static id GFAppearanceInside(Class<UIAppearance> cls, Class container)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 90000
    if ([(id)cls respondsToSelector:@selector(appearanceWhenContainedInInstancesOfClasses:)]) {
        return [cls appearanceWhenContainedInInstancesOfClasses:@[ container ]];
    }
#endif
    return [cls appearanceWhenContainedIn:container, nil];
}

// full-width separators, as before iOS 7
static void GFInstallTableDefaults(void)
{
    [[UITableView appearance] setSeparatorInset:UIEdgeInsetsZero];
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 90000
    if ([[UITableView appearance] respondsToSelector:@selector(setCellLayoutMarginsFollowReadableWidth:)]) {
        [[UITableView appearance] setCellLayoutMarginsFollowReadableWidth:NO];
    }
#endif
}

static void GFInstallAppearance(BOOL black)
{
    // navigation bars, toolbars, tab bars, search bars (the same artwork as the per-bar functions above)
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) {
        GFApplyNavigationBarAppearance([UINavigationBar appearance], black);
        GFApplyToolbarAppearance([UIToolbar appearance], black);
        GFApplyTabBarAppearance([UITabBar appearance]);
    } else
#endif
    {
        GFApplyLegacyNavigationBar([UINavigationBar appearance], black);
        GFApplyLegacyToolbar([UIToolbar appearance], black);
        [[UITabBar appearance] setBackgroundImage:GFTabBarImage()];
        [[UITabBar appearance] setSelectionIndicatorImage:GFTabSelectionImage()];
        [[UITabBar appearance] setTintColor:GFRGB(84, 164, 255)];
    }
    [[UINavigationBar appearance] setTranslucent:NO];
    [[UIToolbar appearance] setTranslucent:NO];
    [[UITabBar appearance] setTranslucent:NO];

    // bordered bar buttons: in navigation bars (as on iOS 6, where plain items were bordered there too) and the
    // Cancel button of search bars; toolbars keep their borderless white glyphs
    GFApplyLegacyBarButtons((UIBarButtonItem *)GFAppearanceInside([UIBarButtonItem class], [UINavigationBar class]), black);
    GFApplyLegacyBarButtons((UIBarButtonItem *)GFAppearanceInside([UIBarButtonItem class], [UISearchBar class]), black);
    [[UIBarButtonItem appearance] setTitleTextAttributes:GFEmbossedTextAttributes(12) forState:UIControlStateNormal];

    [[UISearchBar appearance] setBackgroundImage:GFBarImage(black, 0, 44)];
    [[UISearchBar appearance] setSearchFieldBackgroundImage:GFSearchFieldImage() forState:UIControlStateNormal];
    [[UISearchBar appearance] setSearchTextPositionAdjustment:UIOffsetMake(4, 0)];
    [(UITextField *)GFAppearanceInside([UITextField class], [UISearchBar class]) setTintColor:GFRGB(30, 90, 200)];

    // the iOS 6 blue of switches; glossy gray segmented controls with engraved labels
    [[UISwitch appearance] setOnTintColor:GFRGB(26, 108, 213)];
    UISegmentedControl *segment = [UISegmentedControl appearance];
    [segment setBackgroundImage:GFSegmentImage(NO) forState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [segment setBackgroundImage:GFSegmentImage(YES) forState:UIControlStateSelected barMetrics:UIBarMetricsDefault];
    [segment setBackgroundImage:GFSegmentImage(YES) forState:UIControlStateHighlighted barMetrics:UIBarMetricsDefault];
    UIImage *divider = GFSegmentDividerImage();
    [segment setDividerImage:divider forLeftSegmentState:UIControlStateNormal rightSegmentState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [segment setDividerImage:divider forLeftSegmentState:UIControlStateSelected rightSegmentState:UIControlStateNormal barMetrics:UIBarMetricsDefault];
    [segment setDividerImage:divider forLeftSegmentState:UIControlStateNormal rightSegmentState:UIControlStateSelected barMetrics:UIBarMetricsDefault];
    [segment setTitleTextAttributes:GFEngravedTextAttributes(13, GFRGB(60, 60, 60)) forState:UIControlStateNormal];
    [segment setTitleTextAttributes:GFEmbossedTextAttributes(13) forState:UIControlStateSelected];
    GFInstallTableDefaults();
}

#pragma mark - iOS 13: full-screen modals and rounded grouped tables

#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
static void (*GFOriginalPresent)(id, SEL, UIViewController *, BOOL, void (^)(void));
static id (*GFOriginalTableInit)(id, SEL, CGRect, UITableViewStyle);

// The app's own view controllers (also wrapped in a navigation or tab bar controller), not UIKit's pickers and sheets
static BOOL GFIsAppController(UIViewController *vc)
{
    UIViewController *probe = vc;
    if ([vc isKindOfClass:[UINavigationController class]]) probe = ((UINavigationController *)vc).viewControllers.firstObject ?: vc;
    else if ([vc isKindOfClass:[UITabBarController class]]) probe = ((UITabBarController *)vc).viewControllers.firstObject ?: vc;
    // (the bundle of a class from the executable is the main bundle; a system picker or sheet lives under /System)
    NSBundle *bundle = [NSBundle bundleForClass:[probe class]];
    if (bundle == [NSBundle mainBundle]) return YES;
    NSString *path = bundle.bundlePath ?: @"";
    return path.length && ![path hasPrefix:@"/System/"] && ![path hasPrefix:@"/Developer/"] && ![path hasPrefix:@"/usr/"];
}

static void GFPresent(id self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void))
{
    // iOS 13 made the default a card that slides up and can be dragged away; iOS 6 presented full screen
    if (vc && vc.modalPresentationStyle == UIModalPresentationAutomatic && GFIsAppController(vc)) {
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
    }
    GFOriginalPresent(self, _cmd, vc, animated, completion);
}

static id GFTableInit(id self, SEL _cmd, CGRect frame, UITableViewStyle style)
{
    // iOS 13 draws grouped tables as full-width flat lists; the inset style keeps the rounded groups of iOS 6
    if (style == UITableViewStyleGrouped) {
        self = GFOriginalTableInit(self, _cmd, frame, UITableViewStyleInsetGrouped);
        [self setBackgroundColor:GFRGB(197, 204, 212)];
        return self;
    }
    return GFOriginalTableInit(self, _cmd, frame, style);
}

static void GFInstallIOS13Behaviour(void)
{
    Method present = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (present && !GFOriginalPresent) {
        GFOriginalPresent = (void (*)(id, SEL, UIViewController *, BOOL, void (^)(void)))method_getImplementation(present);
        method_setImplementation(present, (IMP)GFPresent);
    }
    Method tableInit = class_getInstanceMethod([UITableView class], @selector(initWithFrame:style:));
    if (tableInit && !GFOriginalTableInit) {
        GFOriginalTableInit = (id (*)(id, SEL, CGRect, UITableViewStyle))method_getImplementation(tableInit);
        method_setImplementation(tableInit, (IMP)GFTableInit);
    }
}
#endif

#pragma mark - Tables

void GFModernSetTableViewDark(UITableView *tableView, BOOL dark)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    // (the forced light style of the app would draw dark grey section headers on a dark table)
    if (GFAtLeast(13)) tableView.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
#endif
}
#pragma mark - Set-up

static BOOL GFsetUpDone = NO;

void GFModernSetUp(UIBarStyle defaultBarStyle)
{
    if (!GFModernIOS() || GFsetUpDone) return;
    GFsetUpDone = YES;
    GFInstallAppearance(GFIsBlack(defaultBarStyle));
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) GFInstallIOS13Behaviour();
#endif
    NSLog(@"[GFModern] iOS %@: the iOS 6 look is on", [UIDevice currentDevice].systemVersion);
}

void GFModernSetUpWithoutSkin(void)
{
    if (!GFModernIOS() || GFsetUpDone) return;
    GFsetUpDone = YES;
    GFInstallTableDefaults();
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000
    if (GFAtLeast(13)) GFInstallIOS13Behaviour();
#endif
    NSLog(@"[GFModern] iOS %@: iOS 6 behaviour on (the app's own look)", [UIDevice currentDevice].systemVersion);
}

void GFModernRequestNotificationPermission(void)
{
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 80000
    UIApplication *app = [UIApplication sharedApplication];
    if (GFAtLeast(8) && [app respondsToSelector:@selector(registerUserNotificationSettings:)]) {
        UIUserNotificationType types = UIUserNotificationTypeAlert | UIUserNotificationTypeSound | UIUserNotificationTypeBadge;
        [app registerUserNotificationSettings:[UIUserNotificationSettings settingsForTypes:types categories:nil]];
    }
#endif
}
