#import "GFLibraryViewController.h"
#import "GFGameDetailViewController.h"
#import "GFRootViewController.h"
#import "GFCells.h"
#import "GFAPI.h"
#import "GFAuth.h"
#import "GFHTTP.h"
#import "GFSettings.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"

@interface GFLibraryViewController () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UISearchBarDelegate>
@property (nonatomic) BOOL ownedOnly;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UICollectionView *grid;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSMutableArray *games;
@property (nonatomic, strong) NSArray *shown;          // filtered/sorted view of games
@property (nonatomic, copy) NSString *nextCursor;
@property (nonatomic, copy) NSString *query;           // server search (all games) or local filter (library)
@property (nonatomic, strong) GFHTTPTask *task;
@property (nonatomic) BOOL loading;
@property (nonatomic) BOOL loadedOnce;
@property (nonatomic) NSInteger totalCount;
@end

@implementation GFLibraryViewController

- (instancetype)initWithOwnedOnly:(BOOL)ownedOnly
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _ownedOnly = ownedOnly;
        _games = [NSMutableArray array];
        _shown = @[];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.task cancel];
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    GFTheme *theme = [GFTheme shared];
    self.view.backgroundColor = [theme backgroundColor];

    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.searchBar.placeholder = self.ownedOnly ? L(@"Filter my games") : L(@"Search all games");
    self.searchBar.delegate = self;
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    [theme applyToSearchBar:self.searchBar];
    [self.view addSubview:self.searchBar];

    UICollectionViewFlowLayout *layout = [[UICollectionViewFlowLayout alloc] init];
    layout.sectionInset = UIEdgeInsetsMake(10, 10, 10, 10);
    layout.minimumInteritemSpacing = 10;
    layout.minimumLineSpacing = 10;
    self.grid = [[UICollectionView alloc] initWithFrame:CGRectMake(0, 44, self.view.bounds.size.width, self.view.bounds.size.height - 44) collectionViewLayout:layout];
    self.grid.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.grid.backgroundColor = [UIColor clearColor];
    self.grid.alwaysBounceVertical = YES;
    self.grid.dataSource = self;
    self.grid.delegate = self;
    [self.grid registerClass:[GFGameCell class] forCellWithReuseIdentifier:@"game"];
    [self.view addSubview:self.grid];

    self.messageLabel = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 30, 0)];
    self.messageLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.backgroundColor = [UIColor clearColor];
    self.messageLabel.textColor = [theme secondaryTextColor];
    self.messageLabel.font = [theme bodyFont];
    self.messageLabel.hidden = YES;
    [self.view addSubview:self.messageLabel];

    self.actionButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.actionButton setBackgroundImage:[theme accentButtonImageHighlighted:NO disabled:NO] forState:UIControlStateNormal];
    [self.actionButton setBackgroundImage:[theme accentButtonImageHighlighted:YES disabled:NO] forState:UIControlStateHighlighted];
    [self.actionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.actionButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    self.actionButton.frame = CGRectMake(0, 0, 200, 44);
    self.actionButton.hidden = YES;
    [self.actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.actionButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[theme spinnerStyle]];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];

    if (!self.ownedOnly) {
        self.navigationItem.rightBarButtonItem = nil;
    } else {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:L(@"Sort") style:UIBarButtonItemStyleBordered target:self action:@selector(sortTapped)];
    }
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reload)];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(authChanged) name:GFAuthDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged) name:GFThemeDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:GFSettingsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(imageLoaded:) name:GFImageDidLoadNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    if (!self.loadedOnce) [self reload];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    self.spinner.center = CGPointMake(b.size.width / 2, b.size.height / 2 - 30);
    self.messageLabel.frame = CGRectMake(30, b.size.height / 2 - 80, b.size.width - 60, 100);
    self.actionButton.center = CGPointMake(b.size.width / 2, b.size.height / 2 + 50);
}

- (void)willAnimateRotationToInterfaceOrientation:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration
{
    [self.grid.collectionViewLayout invalidateLayout];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)themeChanged
{
    GFTheme *theme = [GFTheme shared];
    self.view.backgroundColor = [theme backgroundColor];
    self.messageLabel.textColor = [theme secondaryTextColor];
    [theme applyToSearchBar:self.searchBar];
    [self.grid reloadData];
}

- (void)settingsChanged
{
    [self applyFilter];
}

- (void)authChanged
{
    [self.games removeAllObjects];
    self.nextCursor = nil;
    self.loadedOnce = NO;
    [self applyFilter];
    if (self.isViewLoaded && self.view.window) [self reload];
}

- (void)imageLoaded:(NSNotification *)note
{
    // cells draw their own images through GFImageView; nothing to do beyond letting them know
}

#pragma mark - Loading

- (void)showMessage:(NSString *)message action:(NSString *)action
{
    self.messageLabel.text = message;
    self.messageLabel.hidden = message == nil;
    [self.actionButton setTitle:action forState:UIControlStateNormal];
    self.actionButton.hidden = action == nil;
}

- (void)actionTapped
{
    if (![GFAuth shared].isSignedIn) {
        [(GFRootViewController *)self.tabBarController presentSignIn];
    } else {
        [self reload];
    }
}

- (void)reload
{
    [self.task cancel];
    self.task = nil;
    self.loading = NO;
    if (![GFAuth shared].isSignedIn) {
        [self.games removeAllObjects];
        self.nextCursor = nil;
        [self applyFilter];
        [self showMessage:L(@"Sign in with your NVIDIA account to see your games.") action:L(@"Sign in")];
        return;
    }
    [self showMessage:nil action:nil];
    [self.games removeAllObjects];
    self.nextCursor = nil;
    self.loadedOnce = YES;
    [self applyFilter];
    [self loadPage];
}

- (void)loadPage
{
    if (self.loading) return;
    self.loading = YES;
    [self.spinner startAnimating];
    NSString *query = self.ownedOnly ? nil : self.query;
    NSString *cursor = self.nextCursor ?: @"";
    NSString *sort = self.ownedOnly ? @"title" : @"relevance";
    __weak GFLibraryViewController *weakSelf = self;
    self.task = [GFAPI fetchCatalogPageWithQuery:query cursor:cursor ownedOnly:self.ownedOnly sort:sort completion:^(GFCatalogPage *page, NSError *error) {
        GFLibraryViewController *self = weakSelf;
        if (!self) return;
        self.loading = NO;
        [self.spinner stopAnimating];
        if (error) {
            if (error.code == GFErrorAuth) {
                [self showMessage:error.localizedDescription action:L(@"Sign in")];
            } else if (!self.games.count) {
                [self showMessage:error.localizedDescription action:L(@"Try again")];
            }
            return;
        }
        NSMutableSet *known = [NSMutableSet set];
        for (GFGame *g in self.games) [known addObject:g.appId];
        for (GFGame *g in page.games) if (![known containsObject:g.appId]) { [self.games addObject:g]; [known addObject:g.appId]; }
        self.nextCursor = page.nextCursor;
        self.totalCount = page.totalCount;
        [self applyFilter];
        if (!self.games.count) {
            [self showMessage:self.ownedOnly ? L(@"Your library is empty. Add games on play.geforcenow.com or in a store you linked, then refresh.") : L(@"No games found.") action:self.ownedOnly ? L(@"Refresh") : nil];
        } else {
            [self showMessage:nil action:nil];
        }
        // the library keeps paging until it has everything (it is usually small)
        if (self.ownedOnly && self.nextCursor && self.games.count < 2000) [self loadPage];
    }];
}

- (void)applyFilter
{
    NSArray *list = self.games;
    if (self.ownedOnly && self.query.length) {
        NSString *q = [self.query lowercaseString];
        NSMutableArray *filtered = [NSMutableArray array];
        for (GFGame *g in list) if ([g.searchKey rangeOfString:q].location != NSNotFound) [filtered addObject:g];
        list = filtered;
    }
    if (self.ownedOnly) {
        BOOL byPlayed = [[GFSettings librarySort] isEqualToString:@"last_played"];
        list = [list sortedArrayUsingComparator:^NSComparisonResult(GFGame *a, GFGame *b) {
            if (byPlayed) {
                if (a.lastPlayed && !b.lastPlayed) return NSOrderedAscending;
                if (!a.lastPlayed && b.lastPlayed) return NSOrderedDescending;
                if (a.lastPlayed && b.lastPlayed) {
                    NSComparisonResult r = [b.lastPlayed compare:a.lastPlayed];
                    if (r != NSOrderedSame) return r;
                }
            }
            return [a.title localizedCaseInsensitiveCompare:b.title];
        }];
    }
    self.shown = list;
    [self.grid reloadData];
}

#pragma mark - Search

- (void)searchFor:(NSString *)query
{
    self.searchBar.text = query;
    [self searchBar:self.searchBar textDidChange:query];
    [self searchBarSearchButtonClicked:self.searchBar];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text
{
    self.query = text;
    if (self.ownedOnly) { [self applyFilter]; return; }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
    [self performSelector:@selector(runSearch) withObject:nil afterDelay:0.6];
}

- (void)runSearch
{
    if (!self.ownedOnly) [self reload];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar
{
    [searchBar resignFirstResponder];
    if (!self.ownedOnly) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
        if (self.query.length) [GFSettings addRecentSearch:self.query];
        [self reload];
    }
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar
{
    searchBar.text = @"";
    [searchBar resignFirstResponder];
    [self searchBar:searchBar textDidChange:@""];
}

- (void)sortTapped
{
    BOOL byPlayed = [[GFSettings librarySort] isEqualToString:@"last_played"];
    [GFSettings setLibrarySort:byPlayed ? @"title" : @"last_played"];
    [GFUtils alertWithTitle:nil message:byPlayed ? L(@"Sorted by title.") : L(@"Sorted by last played.")];
}

#pragma mark - Grid

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section
{
    return (NSInteger)self.shown.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath
{
    GFGameCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"game" forIndexPath:indexPath];
    [cell showGame:self.shown[(NSUInteger)indexPath.item]];
    if (!self.ownedOnly && self.nextCursor && !self.loading && indexPath.item >= (NSInteger)self.shown.count - 12) [self loadPage];
    return cell;
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath
{
    return [GFGameCell cellSizeForWidth:collectionView.bounds.size.width];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];
    [self.searchBar resignFirstResponder];
    GFGame *game = self.shown[(NSUInteger)indexPath.item];
    GFGameDetailViewController *detail = [[GFGameDetailViewController alloc] initWithGame:game];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
    [self.searchBar resignFirstResponder];
}

@end
