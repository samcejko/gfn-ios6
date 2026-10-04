#import "GFLoginViewController.h"
#import "GFAuth.h"
#import "GFExternalOpen.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"
#include "qrcodegen.h"

static UIImage *GFQRImage(NSString *text, CGFloat pixelsPerModule)
{
    uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
    uint8_t temp[qrcodegen_BUFFER_LEN_MAX];
    if (!qrcodegen_encodeText([text UTF8String], temp, qr, qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX, qrcodegen_Mask_AUTO, true)) return nil;
    int size = qrcodegen_getSize(qr);
    int quiet = 2;
    CGFloat side = (size + 2 * quiet) * pixelsPerModule;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), YES, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(ctx, [UIColor whiteColor].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, 0, side, side));
    CGContextSetFillColorWithColor(ctx, [UIColor blackColor].CGColor);
    for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
            if (qrcodegen_getModule(qr, x, y)) CGContextFillRect(ctx, CGRectMake((x + quiet) * pixelsPerModule, (y + quiet) * pixelsPerModule, pixelsPerModule, pixelsPerModule));
        }
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@interface GFLoginViewController ()
@property (nonatomic, strong) UILabel *instructionLabel;
@property (nonatomic, strong) UILabel *codeLabel;
@property (nonatomic, strong) UILabel *urlLabel;
@property (nonatomic, strong) UIImageView *qrView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *openButton;
@property (nonatomic, strong) UIButton *linkCopyButton;
@property (nonatomic, strong) UIButton *freshCodeButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) GFDeviceCode *code;
@property (nonatomic) BOOL polling;
@property (nonatomic) BOOL finished;
@end

@implementation GFLoginViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    GFTheme *theme = [GFTheme shared];
    self.title = L(@"Sign in");
    self.view.backgroundColor = [theme backgroundColor];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];

    self.instructionLabel = [self label:[theme bodyFont] color:[theme primaryTextColor]];
    self.instructionLabel.text = L(@"On your phone or computer open the link below (or scan the code) and enter this code with your NVIDIA account:");
    self.codeLabel = [self label:[UIFont fontWithName:@"Courier-Bold" size:GFIsPad() ? 44 : 34] color:[theme accentColor]];
    self.codeLabel.textAlignment = NSTextAlignmentCenter;
    self.urlLabel = [self label:[theme smallFont] color:[theme linkColor]];
    self.urlLabel.textAlignment = NSTextAlignmentCenter;
    self.urlLabel.lineBreakMode = NSLineBreakByCharWrapping;
    self.qrView = [[UIImageView alloc] initWithFrame:CGRectZero];
    self.qrView.contentMode = UIViewContentModeScaleAspectFit;
    [self.view addSubview:self.qrView];
    self.statusLabel = [self label:[theme smallFont] color:[theme secondaryTextColor]];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;

    self.openButton = [self button:L(@"Open link here")];
    [self.openButton addTarget:self action:@selector(openLink:) forControlEvents:UIControlEventTouchUpInside];
    self.linkCopyButton = [self button:L(@"Copy link")];
    [self.linkCopyButton addTarget:self action:@selector(copyLink) forControlEvents:UIControlEventTouchUpInside];
    self.freshCodeButton = [self button:L(@"New code")];
    [self.freshCodeButton addTarget:self action:@selector(requestCode) forControlEvents:UIControlEventTouchUpInside];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    [self requestCode];
}

- (UILabel *)label:(UIFont *)font color:(UIColor *)color
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.font = font;
    l.textColor = color;
    l.numberOfLines = 0;
    l.backgroundColor = [UIColor clearColor];
    [self.view addSubview:l];
    return l;
}

- (UIButton *)button:(NSString *)title
{
    GFTheme *theme = [GFTheme shared];
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setBackgroundImage:[theme buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [b setBackgroundImage:[theme buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [b setTitleColor:[theme primaryTextColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b setTitle:title forState:UIControlStateNormal];
    [self.view addSubview:b];
    return b;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    CGFloat margin = 20, y = 16;
    CGSize is = [self.instructionLabel.text sizeWithFont:self.instructionLabel.font constrainedToSize:CGSizeMake(w - 2 * margin, 200)];
    self.instructionLabel.frame = CGRectMake(margin, y, w - 2 * margin, is.height);
    y += is.height + 12;
    self.codeLabel.frame = CGRectMake(margin, y, w - 2 * margin, 52);
    y += 56;
    CGSize us = [self.urlLabel.text sizeWithFont:self.urlLabel.font constrainedToSize:CGSizeMake(w - 2 * margin, 80)];
    self.urlLabel.frame = CGRectMake(margin, y, w - 2 * margin, us.height);
    y += us.height + 10;
    CGFloat qr = MIN(220, MAX(120, h - y - 170));
    self.qrView.frame = CGRectMake((w - qr) / 2, y, qr, qr);
    y += qr + 10;
    self.statusLabel.frame = CGRectMake(margin, y, w - 2 * margin, 20);
    self.spinner.center = CGPointMake(w / 2, y + 36);
    y += 26;
    CGFloat bw = MIN(140, (w - 2 * margin - 16) / 3);
    CGFloat total = bw * 3 + 16;
    CGFloat x = (w - total) / 2;
    self.openButton.frame = CGRectMake(x, y + 24, bw, 40);
    self.linkCopyButton.frame = CGRectMake(x + bw + 8, y + 24, bw, 40);
    self.freshCodeButton.frame = CGRectMake(x + 2 * (bw + 8), y + 24, bw, 40);
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)cancel
{
    self.finished = YES;
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)requestCode
{
    self.code = nil;
    self.codeLabel.text = @"";
    self.urlLabel.text = @"";
    self.qrView.image = nil;
    self.statusLabel.text = L(@"Asking NVIDIA for a code…");
    [self.spinner startAnimating];
    [[GFAuth shared] startDeviceLogin:^(GFDeviceCode *code, NSError *error) {
        if (self.finished) return;
        [self.spinner stopAnimating];
        if (!code) {
            self.statusLabel.text = error.localizedDescription ?: L(@"Could not get a code.");
            return;
        }
        self.code = code;
        self.codeLabel.text = code.userCode;
        self.urlLabel.text = code.verificationURL;
        self.qrView.image = GFQRImage(code.verificationURL, 6);
        self.statusLabel.text = L(@"Waiting for you to approve the sign-in…");
        [self.view setNeedsLayout];
        [self schedulePoll];
    }];
}

- (void)schedulePoll
{
    if (!self.code || self.finished) return;
    __weak GFLoginViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.code.interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf poll];
    });
}

- (void)poll
{
    if (!self.code || self.finished || self.polling) return;
    if ([self.code isExpired]) {
        self.statusLabel.text = L(@"The code expired. Ask for a new one.");
        return;
    }
    self.polling = YES;
    GFDeviceCode *code = self.code;
    [[GFAuth shared] pollDeviceLogin:code completion:^(BOOL authorized, BOOL pending, NSError *error) {
        self.polling = NO;
        if (self.finished || code != self.code) return;
        if (authorized) {
            self.finished = YES;
            self.statusLabel.text = [NSString stringWithFormat:L(@"Signed in as %@."), [GFAuth shared].displayName];
            [self dismissViewControllerAnimated:YES completion:nil];
            return;
        }
        if (pending) { [self schedulePoll]; return; }
        self.statusLabel.text = error.localizedDescription ?: L(@"The sign-in did not go through.");
    }];
}

- (void)openLink:(UIButton *)sender
{
    if (!self.code.verificationURL.length) return;
    [GFExternalOpen presentOpenInForURL:[NSURL URLWithString:self.code.verificationURL] from:self anchor:sender];
}

- (void)copyLink
{
    if (!self.code.verificationURL.length) return;
    [UIPasteboard generalPasteboard].string = self.code.verificationURL;
    self.statusLabel.text = L(@"Link copied.");
}

@end
