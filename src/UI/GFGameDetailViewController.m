#import "GFGameDetailViewController.h"
#import "GFLaunchViewController.h"
#import "GFRootViewController.h"
#import "GFImageLoader.h"
#import "GFAuth.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"

@interface GFGameDetailViewController ()
@property (nonatomic, strong) GFGame *game;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) GFImageView *heroView;
@property (nonatomic, strong) GFImageView *coverView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UILabel *factsLabel;
@property (nonatomic, strong) UIButton *playButton;
@end

@implementation GFGameDetailViewController

- (instancetype)initWithGame:(GFGame *)game
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _game = game;
        self.title = game.title;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    GFTheme *theme = [GFTheme shared];
    self.view.backgroundColor = [theme backgroundColor];
    self.scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];

    self.heroView = [[GFImageView alloc] initWithFrame:CGRectZero];
    self.heroView.contentMode = UIViewContentModeScaleAspectFill;
    self.heroView.clipsToBounds = YES;
    self.heroView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.heroView.maxPixels = 1024;
    [self.heroView setImageURL:self.game.heroURL placeholder:[theme thumbnailPlaceholder]];
    [self.scroll addSubview:self.heroView];

    self.coverView = [[GFImageView alloc] initWithFrame:CGRectZero];
    self.coverView.contentMode = UIViewContentModeScaleAspectFill;
    self.coverView.clipsToBounds = YES;
    self.coverView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    self.coverView.layer.borderWidth = 2;
    [self.coverView setImageURL:self.game.coverURL placeholder:[theme boxArtPlaceholder]];
    [self.scroll addSubview:self.coverView];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:GFIsPad() ? 24 : 19];
    self.titleLabel.numberOfLines = 0;
    self.titleLabel.backgroundColor = [UIColor clearColor];
    self.titleLabel.textColor = [theme primaryTextColor];
    self.titleLabel.text = [GFUtils displayText:self.game.title];
    [self.scroll addSubview:self.titleLabel];

    self.metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.metaLabel.font = [theme smallFont];
    self.metaLabel.numberOfLines = 0;
    self.metaLabel.backgroundColor = [UIColor clearColor];
    self.metaLabel.textColor = [theme secondaryTextColor];
    NSMutableArray *meta = [NSMutableArray array];
    if ([self.game storeDisplayName].length) [meta addObject:[self.game storeDisplayName]];
    if (self.game.publisher.length) [meta addObject:self.game.publisher];
    self.metaLabel.text = [meta componentsJoinedByString:@" · "];
    [self.scroll addSubview:self.metaLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.playButton setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [self.playButton setBackgroundImage:[theme accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [self.playButton setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:YES] forState:UIControlStateDisabled];
    [self.playButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.playButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [self.playButton setTitle:L(@"Play") forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
    [self.scroll addSubview:self.playButton];

    self.factsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.factsLabel.font = [theme bodyFont];
    self.factsLabel.numberOfLines = 0;
    self.factsLabel.backgroundColor = [UIColor clearColor];
    self.factsLabel.textColor = [theme primaryTextColor];
    NSMutableArray *facts = [NSMutableArray array];
    if (self.game.genres.length) [facts addObject:[NSString stringWithFormat:@"%@: %@", L(@"Genres"), self.game.genres]];
    if (self.game.lastPlayed) [facts addObject:[NSString stringWithFormat:@"%@: %@", L(@"Last played"), [GFUtils formatRelativeDate:self.game.lastPlayed]]];
    if (self.game.owned) [facts addObject:L(@"In your library")];
    else if (self.game.freeToPlay) [facts addObject:L(@"Free to play")];
    else [facts addObject:L(@"Not in your library yet - you need to own it in the store shown above and have the store linked to your NVIDIA account.")];
    if ([self.game.status isEqualToString:@"MAINTENANCE"]) [facts addObject:L(@"Under maintenance right now.")];
    else if ([self.game.status isEqualToString:@"PATCHING"]) [facts addObject:L(@"Being updated on NVIDIA's side right now.")];
    [facts addObject:[NSString stringWithFormat:@"%@: %@", L(@"App id"), self.game.appId]];
    self.factsLabel.text = [facts componentsJoinedByString:@"\n"];
    [self.scroll addSubview:self.factsLabel];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat heroH = floor(w * 9 / 16);
    if (heroH > 320) heroH = 320;
    self.heroView.frame = CGRectMake(0, 0, w, heroH);
    CGFloat coverW = GFIsPad() ? 150 : 100, coverH = coverW * 4 / 3;
    self.coverView.frame = CGRectMake(16, heroH - coverH / 2, coverW, coverH);
    CGFloat textX = 16 + coverW + 14;
    CGFloat textW = w - textX - 16;
    CGSize ts = [self.titleLabel.text sizeWithFont:self.titleLabel.font constrainedToSize:CGSizeMake(textW, 200)];
    self.titleLabel.frame = CGRectMake(textX, heroH + 8, textW, ts.height);
    CGSize ms = [self.metaLabel.text sizeWithFont:self.metaLabel.font constrainedToSize:CGSizeMake(textW, 60)];
    self.metaLabel.frame = CGRectMake(textX, CGRectGetMaxY(self.titleLabel.frame) + 2, textW, ms.height);
    CGFloat y = MAX(CGRectGetMaxY(self.coverView.frame), CGRectGetMaxY(self.metaLabel.frame)) + 16;
    self.playButton.frame = CGRectMake(16, y, w - 32, 48);
    y += 64;
    CGSize fs = [self.factsLabel.text sizeWithFont:self.factsLabel.font constrainedToSize:CGSizeMake(w - 32, 1000)];
    self.factsLabel.frame = CGRectMake(16, y, w - 32, fs.height);
    self.scroll.contentSize = CGSizeMake(w, y + fs.height + 30);
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)play
{
    if (![GFAuth shared].isSignedIn) {
        [(GFRootViewController *)self.tabBarController presentSignIn];
        return;
    }
    GFLaunchViewController *launch = [[GFLaunchViewController alloc] initWithAppId:self.game.appId title:self.game.title];
    [self presentViewController:launch animated:YES completion:nil];
}

@end
