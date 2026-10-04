#import "GFSettingsViewController.h"
#import "GFChoiceViewController.h"
#import "GFRootViewController.h"
#import "GFAuth.h"
#import "GFAPI.h"
#import "GFSettings.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"

enum { SecAccount, SecStream, SecControls, SecAppearance, SecNetwork, SecAbout, SecCount };
enum { RowResolution, RowFps, RowBitrate, RowRegion, RowLanguage, RowStats, StreamRowCount };
enum { RowGamepad, RowOpacity, RowSensitivity, ControlsRowCount };

@interface GFSettingsViewController ()
@property (nonatomic, strong) NSArray *regions;
@property (nonatomic) BOOL loadingRegions;
@end

@implementation GFSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [[GFTheme shared] applyToTableView:self.tableView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh) name:GFAuthDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged) name:GFThemeDidChangeNotification object:nil];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    if ([GFAuth shared].isSignedIn && ![GFAuth shared].membershipTier) {
        [GFAPI resolveVpcId:^(NSString *vpcId, NSError *error) {
            [[GFAuth shared] fetchMembershipTierWithVpcId:vpcId completion:^(NSString *tier) { [self refresh]; }];
        }];
    }
}

- (void)refresh { [self.tableView reloadData]; }

- (void)themeChanged
{
    [[GFTheme shared] applyToTableView:self.tableView];
    [self.tableView reloadData];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

#pragma mark - Options

- (NSArray *)resolutionOptions
{
    CGSize native = [GFSettings streamSize];
    return @[ @{ @"key": @"native", @"title": [NSString stringWithFormat:L(@"Screen (%dx%d)"), (int)native.width, (int)native.height] },
              @{ @"key": @"960x544", @"title": @"960x544" },
              @{ @"key": @"1024x768", @"title": @"1024x768" },
              @{ @"key": @"1280x720", @"title": @"1280x720" },
              @{ @"key": @"1280x800", @"title": @"1280x800" },
              @{ @"key": @"1280x960", @"title": @"1280x960" },
              @{ @"key": @"1600x900", @"title": [NSString stringWithFormat:@"1600x900 (%@)", L(@"heavy")] },
              @{ @"key": @"1920x1080", @"title": [NSString stringWithFormat:@"1920x1080 (%@)", L(@"heavy")] } ];
}

- (NSArray *)languageOptions
{
    return @[ @[@"en_US", @"English (US)"], @[@"en_GB", @"English (UK)"], @[@"cs_CZ", @"Čeština"], @[@"de_DE", @"Deutsch"], @[@"es_ES", @"Español (España)"],
              @[@"es_MX", @"Español (México)"], @[@"fr_FR", @"Français"], @[@"it_IT", @"Italiano"], @[@"nl_NL", @"Nederlands"], @[@"pl_PL", @"Polski"],
              @[@"pt_BR", @"Português (Brasil)"], @[@"hu_HU", @"Magyar"], @[@"ru_RU", @"Russian"], @[@"uk_UA", @"Ukrainian"], @[@"tr_TR", @"Türkçe"],
              @[@"sv_SE", @"Svenska"], @[@"nb_NO", @"Norsk"], @[@"da_DK", @"Dansk"], @[@"fi_FI", @"Suomi"], @[@"ja_JP", @"日本語"], @[@"ko_KR", @"한국어"],
              @[@"zh_CN", @"简体中文"], @[@"zh_TW", @"繁體中文"], @[@"th_TH", @"Thai"] ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return SecCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    switch (section) {
        case SecAccount: return [GFAuth shared].isSignedIn ? 2 : 1;
        case SecStream: return StreamRowCount;
        case SecControls: return ControlsRowCount;
        case SecAppearance: return 1;
        case SecNetwork: return 1;
        case SecAbout: return 2;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
    switch (section) {
        case SecAccount: return L(@"NVIDIA account");
        case SecStream: return L(@"Stream");
        case SecControls: return L(@"Controls");
        case SecAppearance: return L(@"Appearance");
        case SecNetwork: return L(@"Network");
        case SecAbout: return L(@"About");
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
    switch (section) {
        case SecStream: return L(@"Lower resolution and bitrate help on a weak Wi-Fi or an older device. 60 fps looks smoother but costs more decoding power.");
        case SecControls: return L(@"During a stream, tap the small gear for the keyboard, mouse mode and the on-screen gamepad.");
        case SecAbout: return L(@"GFN6 is an unofficial client and is not affiliated with, endorsed by or associated with NVIDIA or GeForce NOW. You need your own GeForce NOW account.");
    }
    return nil;
}

- (UISlider *)sliderWithMin:(float)min max:(float)max value:(float)value tag:(NSInteger)tag
{
    UISlider *s = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, GFIsPad() ? 240 : 150, 30)];
    s.minimumValue = min;
    s.maximumValue = max;
    s.value = value;
    s.tag = tag;
    s.continuous = NO;
    [s addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UISwitch *)switchOn:(BOOL)on tag:(NSInteger)tag
{
    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectZero];
    s.on = on;
    s.tag = tag;
    [s addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    [[GFTheme shared] styleCell:cell];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    GFAuth *auth = [GFAuth shared];
    NSInteger s = indexPath.section, r = indexPath.row;
    if (s == SecAccount) {
        if (!auth.isSignedIn) {
            cell.textLabel.text = L(@"Sign in with your NVIDIA account");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        } else if (r == 0) {
            cell.textLabel.text = auth.displayName ?: @"";
            cell.detailTextLabel.text = auth.membershipTier.length ? [auth.membershipTier capitalizedString] : auth.email;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = L(@"Sign out");
            cell.textLabel.textColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1];
        }
    } else if (s == SecStream) {
        switch (r) {
            case RowResolution: {
                cell.textLabel.text = L(@"Resolution");
                NSString *key = [GFSettings streamResolution];
                NSString *title = key;
                for (NSDictionary *o in [self resolutionOptions]) if ([o[@"key"] isEqualToString:key]) title = o[@"title"];
                cell.detailTextLabel.text = title;
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            case RowFps:
                cell.textLabel.text = L(@"Frame rate");
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld fps", (long)[GFSettings streamFps]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case RowBitrate:
                cell.textLabel.text = [NSString stringWithFormat:@"%@ %ld Mb/s", L(@"Bitrate"), (long)[GFSettings maxBitrateMbps]];
                cell.accessoryView = [self sliderWithMin:3 max:30 value:[GFSettings maxBitrateMbps] tag:RowBitrate];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowRegion:
                cell.textLabel.text = L(@"Server region");
                cell.detailTextLabel.text = [GFSettings region].length ? ([GFSettings regionName].length ? [GFSettings regionName] : [GFSettings region]) : L(@"Automatic");
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            case RowLanguage: {
                cell.textLabel.text = L(@"Game language");
                NSString *code = [GFSettings gameLanguage];
                cell.detailTextLabel.text = code;
                for (NSArray *o in [self languageOptions]) if ([o[0] isEqualToString:code]) cell.detailTextLabel.text = o[1];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                break;
            }
            case RowStats:
                cell.textLabel.text = L(@"Statistics overlay");
                cell.accessoryView = [self switchOn:[GFSettings showStats] tag:100 + RowStats];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
        }
    } else if (s == SecControls) {
        switch (r) {
            case RowGamepad:
                cell.textLabel.text = L(@"On-screen gamepad");
                cell.accessoryView = [self switchOn:[GFSettings touchGamepad] tag:200 + RowGamepad];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowOpacity:
                cell.textLabel.text = L(@"Gamepad opacity");
                cell.accessoryView = [self sliderWithMin:0.2 max:0.9 value:[GFSettings gamepadOpacity] tag:200 + RowOpacity];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
            case RowSensitivity:
                cell.textLabel.text = L(@"Mouse sensitivity");
                cell.accessoryView = [self sliderWithMin:0.5 max:3 value:[GFSettings mouseSensitivity] tag:200 + RowSensitivity];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                break;
        }
    } else if (s == SecAppearance) {
        cell.textLabel.text = L(@"Dark theme");
        cell.accessoryView = [self switchOn:[GFTheme shared].isDark tag:300];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (s == SecNetwork) {
        cell.textLabel.text = L(@"Verify certificates");
        cell.accessoryView = [self switchOn:[GFSettings verifyTLS] tag:400];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (s == SecAbout) {
        if (r == 0) {
            cell.textLabel.text = L(@"Version");
            cell.detailTextLabel.text = [GFUtils appVersion];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else {
            cell.textLabel.text = L(@"Open-source licenses");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
    }
    return cell;
}

- (void)sliderChanged:(UISlider *)slider
{
    if (slider.tag == RowBitrate) [GFSettings setMaxBitrateMbps:(NSInteger)lroundf(slider.value)];
    else if (slider.tag == 200 + RowOpacity) [GFSettings setGamepadOpacity:slider.value];
    else if (slider.tag == 200 + RowSensitivity) [GFSettings setMouseSensitivity:slider.value];
    [self.tableView reloadData];
}

- (void)switchChanged:(UISwitch *)sw
{
    switch (sw.tag) {
        case 100 + RowStats: [GFSettings setShowStats:sw.on]; break;
        case 200 + RowGamepad: [GFSettings setTouchGamepad:sw.on]; break;
        case 300: [[GFTheme shared] setDark:sw.on]; break;
        case 400: [GFSettings setVerifyTLS:sw.on]; [GFSettings save]; break;
    }
}

- (void)pushChoice:(NSArray *)titles subtitles:(NSArray *)subtitles selected:(NSInteger)selected title:(NSString *)title completion:(void (^)(NSInteger))completion
{
    GFChoiceViewController *c = [[GFChoiceViewController alloc] initWithStyle:UITableViewStyleGrouped];
    c.title = title;
    c.titles = titles;
    c.subtitles = subtitles;
    c.selectedIndex = selected;
    c.completion = completion;
    [self.navigationController pushViewController:c animated:YES];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSInteger s = indexPath.section, r = indexPath.row;
    if (s == SecAccount) {
        if (![GFAuth shared].isSignedIn) { [(GFRootViewController *)self.tabBarController presentSignIn]; return; }
        if (r == 1) {
            [[GFAuth shared] signOut];
            [GFAPI forgetVpcId];
            [self.tableView reloadData];
        }
        return;
    }
    if (s == SecStream) {
        if (r == RowResolution) {
            NSArray *options = [self resolutionOptions];
            NSMutableArray *titles = [NSMutableArray array];
            NSInteger selected = 0;
            for (NSUInteger i = 0; i < options.count; i++) {
                [titles addObject:options[i][@"title"]];
                if ([options[i][@"key"] isEqualToString:[GFSettings streamResolution]]) selected = (NSInteger)i;
            }
            [self pushChoice:titles subtitles:nil selected:selected title:L(@"Resolution") completion:^(NSInteger index) {
                [GFSettings setStreamResolution:options[(NSUInteger)index][@"key"]];
                [self.tableView reloadData];
            }];
        } else if (r == RowFps) {
            [self pushChoice:@[ @"60 fps", @"30 fps" ] subtitles:@[ L(@"Smoothest; needs a fast device and network"), L(@"Easier on the iPad 2 and on Wi-Fi") ]
                    selected:[GFSettings streamFps] == 30 ? 1 : 0 title:L(@"Frame rate") completion:^(NSInteger index) {
                [GFSettings setStreamFps:index == 1 ? 30 : 60];
                [self.tableView reloadData];
            }];
        } else if (r == RowRegion) {
            [self pickRegion];
        } else if (r == RowLanguage) {
            NSArray *options = [self languageOptions];
            NSMutableArray *titles = [NSMutableArray array];
            NSInteger selected = 0;
            for (NSUInteger i = 0; i < options.count; i++) {
                [titles addObject:options[i][1]];
                if ([options[i][0] isEqualToString:[GFSettings gameLanguage]]) selected = (NSInteger)i;
            }
            [self pushChoice:titles subtitles:nil selected:selected title:L(@"Game language") completion:^(NSInteger index) {
                [GFSettings setGameLanguage:options[(NSUInteger)index][0]];
                [self.tableView reloadData];
            }];
        }
        return;
    }
    if (s == SecAbout && r == 1) {
        UIViewController *vc = [[UIViewController alloc] init];
        vc.title = L(@"Licenses");
        UITextView *tv = [[UITextView alloc] initWithFrame:vc.view.bounds];
        tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tv.editable = NO;
        tv.font = [UIFont systemFontOfSize:12];
        NSMutableString *text = [NSMutableString string];
        NSString *dir = [[NSBundle mainBundle] pathForResource:@"licenses" ofType:nil];
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
            NSString *content = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
            if (content) [text appendFormat:@"==== %@ ====\n\n%@\n\n", name, content];
        }
        tv.text = text.length ? text : L(@"The license texts are added by the build.");
        [vc.view addSubview:tv];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

- (void)pickRegion
{
    if (self.loadingRegions) return;
    self.loadingRegions = YES;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    [GFAPI fetchRegions:^(NSArray *regions, NSError *error) {
        if (!regions.count) {
            self.loadingRegions = NO;
            self.navigationItem.rightBarButtonItem = nil;
            [GFUtils alertWithTitle:L(@"Server region") message:error.localizedDescription ?: L(@"NVIDIA did not list any regions.")];
            return;
        }
        [GFAPI measureRegions:regions completion:^(NSArray *measured) {
            self.loadingRegions = NO;
            self.navigationItem.rightBarButtonItem = nil;
            self.regions = measured;
            NSMutableArray *titles = [NSMutableArray arrayWithObject:L(@"Automatic")];
            NSMutableArray *subtitles = [NSMutableArray arrayWithObject:L(@"NVIDIA picks the zone")];
            NSInteger selected = 0;
            for (NSUInteger i = 0; i < measured.count; i++) {
                GFRegion *r = measured[i];
                [titles addObject:r.name];
                [subtitles addObject:r.pingMs > 0 ? [NSString stringWithFormat:@"%ld ms", (long)r.pingMs] : (r.pingMs == 0 ? L(@"unreachable") : @"")];
                if ([r.url isEqualToString:[GFSettings region]]) selected = (NSInteger)i + 1;
            }
            [self pushChoice:titles subtitles:subtitles selected:selected title:L(@"Server region") completion:^(NSInteger index) {
                if (index == 0) { [GFSettings setRegion:@""]; [GFSettings setRegionName:@""]; }
                else { GFRegion *r = measured[(NSUInteger)index - 1]; [GFSettings setRegion:r.url]; [GFSettings setRegionName:r.name]; }
                [self.tableView reloadData];
            }];
        }];
    }];
}

@end
