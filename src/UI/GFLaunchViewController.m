#import "GFLaunchViewController.h"
#import "GFStreamViewController.h"
#import "GFCloudMatch.h"
#import "GFAuth.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"

@interface GFLaunchViewController ()
@property (nonatomic, copy) NSString *appId;
@property (nonatomic, copy) NSString *gameTitle;
@property (nonatomic, strong) GFCloudMatch *cloudMatch;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *queueLabel;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL streaming;
@end

@implementation GFLaunchViewController

- (instancetype)initWithAppId:(NSString *)appId title:(NSString *)title
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _appId = [appId copy];
        _gameTitle = [title copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.06 green:0.07 blue:0.08 alpha:1];
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:GFIsPad() ? 26 : 20];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.backgroundColor = [UIColor clearColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.text = [GFUtils displayText:self.gameTitle];
    [self.view addSubview:self.titleLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont systemFontOfSize:GFIsPad() ? 18 : 15];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.85 alpha:1];
    self.statusLabel.backgroundColor = [UIColor clearColor];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = L(@"Starting…");
    [self.view addSubview:self.statusLabel];

    self.queueLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.queueLabel.font = [UIFont systemFontOfSize:GFIsPad() ? 15 : 13];
    self.queueLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    self.queueLabel.backgroundColor = [UIColor clearColor];
    self.queueLabel.textAlignment = NSTextAlignmentCenter;
    self.queueLabel.numberOfLines = 0;
    [self.view addSubview:self.queueLabel];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.cancelButton setBackgroundImage:[[GFTheme shared] buttonImageHighlighted:NO] forState:UIControlStateNormal];
    [self.cancelButton setBackgroundImage:[[GFTheme shared] buttonImageHighlighted:YES] forState:UIControlStateHighlighted];
    [self.cancelButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.cancelButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.cancelButton setTitle:L(@"Cancel") forState:UIControlStateNormal];
    [self.cancelButton addTarget:self action:@selector(cancelTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.cancelButton];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    self.titleLabel.frame = CGRectMake(30, h * 0.22, w - 60, 70);
    self.spinner.center = CGPointMake(w / 2, h * 0.22 + 110);
    self.statusLabel.frame = CGRectMake(30, h * 0.22 + 150, w - 60, 60);
    self.queueLabel.frame = CGRectMake(30, h * 0.22 + 215, w - 60, 50);
    self.cancelButton.frame = CGRectMake((w - 160) / 2, h - 90, 160, 44);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.started) return;
    self.started = YES;
    self.startedAt = [NSDate date];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    self.cloudMatch = [[GFCloudMatch alloc] initWithAppId:self.appId];
    __weak GFLaunchViewController *weakSelf = self;
    self.cloudMatch.onProgress = ^(NSString *message, NSInteger position, NSInteger eta) {
        GFLaunchViewController *self = weakSelf;
        self.statusLabel.text = message;
        NSMutableArray *parts = [NSMutableArray array];
        if (position > 0) [parts addObject:[NSString stringWithFormat:L(@"%ld ahead of you"), (long)position]];
        if (eta > 0) [parts addObject:[NSString stringWithFormat:L(@"about %@"), [GFUtils formatDuration:eta]]];
        NSTimeInterval waited = -[self.startedAt timeIntervalSinceNow];
        if (waited > 20) [parts addObject:[NSString stringWithFormat:L(@"waiting %@"), [GFUtils formatDuration:waited]]];
        self.queueLabel.text = [parts componentsJoinedByString:@" · "];
    };
    [self.cloudMatch startWithCompletion:^(GFSession *session, NSError *error) {
        GFLaunchViewController *self = weakSelf;
        if (!self) return;
        if (!session) {
            [self.spinner stopAnimating];
            self.statusLabel.text = error.localizedDescription ?: L(@"The launch failed.");
            self.queueLabel.text = @"";
            [self.cancelButton setTitle:L(@"Close") forState:UIControlStateNormal];
            return;
        }
        self.statusLabel.text = L(@"Seat ready, connecting the stream…");
        self.queueLabel.text = @"";
        [self startStream:session];
    }];
}

- (void)startStream:(GFSession *)session
{
    self.streaming = YES;
    GFStreamViewController *stream = [[GFStreamViewController alloc] initWithSession:session title:self.gameTitle];
    __weak GFLaunchViewController *weakSelf = self;
    stream.onFinished = ^(NSString *message) {
        GFLaunchViewController *self = weakSelf;
        [self dismissViewControllerAnimated:NO completion:^{
            [self finishWithMessage:message];
        }];
    };
    [self presentViewController:stream animated:YES completion:nil];
}

- (void)finishWithMessage:(NSString *)message
{
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self.presentingViewController dismissViewControllerAnimated:YES completion:^{
        if (message.length) [GFUtils alertWithTitle:L(@"Stream ended") message:message];
    }];
}

- (void)cancelTapped
{
    [self.cloudMatch cancel];
    self.cloudMatch = nil;
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)prefersStatusBarHidden { return YES; }

@end
