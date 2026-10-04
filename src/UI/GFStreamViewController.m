#import "GFStreamViewController.h"
#import "GFGamepadOverlayView.h"
#import "GFSignaling.h"
#import "GFPeer.h"
#import "GFSDP.h"
#import "GFCloudMatch.h"
#import "GFVideoDecoder.h"
#import "GFVideoView.h"
#import "GFAudioPlayer.h"
#import "GFSettings.h"
#import "GFTheme.h"
#import "GFUtils.h"
#import "GFCommon.h"

// A view that takes keyboard input and forwards it as key presses
@interface GFKeyInputView : UIView <UIKeyInput>
@property (nonatomic, copy) void (^onCharacter)(unichar c);
@property (nonatomic, copy) void (^onBackspace)(void);
@property (nonatomic, strong) UIView *accessory;
@end

@implementation GFKeyInputView
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (UIView *)inputAccessoryView { return self.accessory; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeASCIICapable; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceAlert; }
- (void)insertText:(NSString *)text
{
    for (NSUInteger i = 0; i < text.length; i++) if (self.onCharacter) self.onCharacter([text characterAtIndex:i]);
}
- (void)deleteBackward
{
    if (self.onBackspace) self.onBackspace();
}
@end

@interface GFStreamViewController () <GFSignalingDelegate, GFPeerDelegate, UIActionSheetDelegate, UIGestureRecognizerDelegate>
@property (nonatomic, strong) GFSession *session;
@property (nonatomic, copy) NSString *gameTitle;
@property (nonatomic, strong) GFSignaling *signaling;
@property (nonatomic, strong) GFPeer *peer;
@property (nonatomic, strong) GFVideoDecoder *decoder;
@property (nonatomic, strong) GFAudioPlayer *audio;
@property (nonatomic, strong) GFVideoView *videoView;
@property (nonatomic, strong) GFGamepadOverlayView *gamepad;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) UILabel *toastLabel;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) GFKeyInputView *keyInput;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic) BOOL mouseMode;
@property (nonatomic) BOOL finished;
@property (nonatomic) BOOL gotFirstFrame;
@property (nonatomic) BOOL offerHandled;
@property (nonatomic, strong) NSDate *startedAt;
@property (nonatomic) CGPoint lastPan;
@property (nonatomic) CGFloat mouseRemainderX, mouseRemainderY;
@property (nonatomic, strong) NSDictionary *lastStats;
@end

@implementation GFStreamViewController

- (instancetype)initWithSession:(GFSession *)session title:(NSString *)title
{
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _session = session;
        _gameTitle = [title copy];
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.wantsFullScreenLayout = YES;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - View

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.videoView = [[GFVideoView alloc] initWithFrame:self.view.bounds];
    self.videoView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.videoView];

    // mouse surface: pan = move, tap = left click, two-finger tap = right click, two-finger pan = wheel
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mousePan:)];
    pan.maximumNumberOfTouches = 1;
    pan.delegate = self;
    [self.videoView addGestureRecognizer:pan];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mouseTap:)];
    tap.delegate = self;
    [self.videoView addGestureRecognizer:tap];
    UITapGestureRecognizer *twoTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(mouseRightTap:)];
    twoTap.numberOfTouchesRequired = 2;
    twoTap.delegate = self;
    [self.videoView addGestureRecognizer:twoTap];
    UIPanGestureRecognizer *wheel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(mouseWheel:)];
    wheel.minimumNumberOfTouches = 2;
    wheel.maximumNumberOfTouches = 2;
    wheel.delegate = self;
    [self.videoView addGestureRecognizer:wheel];
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(mouseHold:)];
    hold.minimumPressDuration = 0.5;
    hold.delegate = self;
    [self.videoView addGestureRecognizer:hold];

    self.gamepad = [[GFGamepadOverlayView alloc] initWithFrame:self.view.bounds];
    self.gamepad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.gamepad.controlOpacity = [GFSettings gamepadOpacity];
    self.gamepad.hidden = ![GFSettings touchGamepad];
    __weak GFStreamViewController *weakSelf = self;
    self.gamepad.onChange = ^(GFGamepadState state) { [weakSelf.peer sendGamepad:state]; };
    [self.view addSubview:self.gamepad];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.font = [UIFont systemFontOfSize:GFIsPad() ? 16 : 13];
    self.statusLabel.textColor = [UIColor whiteColor];
    self.statusLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.text = L(@"Connecting…");
    [self.view addSubview:self.statusLabel];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    self.statsLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statsLabel.font = [UIFont fontWithName:@"Courier-Bold" size:11];
    self.statsLabel.textColor = [UIColor colorWithRed:0.6 green:1 blue:0.3 alpha:1];
    self.statsLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.statsLabel.numberOfLines = 0;
    self.statsLabel.hidden = ![GFSettings showStats];
    [self.view addSubview:self.statsLabel];

    self.toastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.toastLabel.font = [UIFont boldSystemFontOfSize:GFIsPad() ? 16 : 13];
    self.toastLabel.textColor = [UIColor whiteColor];
    self.toastLabel.backgroundColor = [UIColor colorWithRed:0.3 green:0.5 blue:0.05 alpha:0.85];
    self.toastLabel.textAlignment = NSTextAlignmentCenter;
    self.toastLabel.numberOfLines = 0;
    self.toastLabel.hidden = YES;
    [self.view addSubview:self.toastLabel];

    self.menuButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.menuButton setImage:[[GFTheme shared] gearIconWhite] forState:UIControlStateNormal];
    self.menuButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    self.menuButton.layer.cornerRadius = 16;
    self.menuButton.alpha = 0.7;
    self.menuButton.accessibilityLabel = L(@"Stream menu");
    [self.menuButton addTarget:self action:@selector(showMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.menuButton];

    self.keyInput = [[GFKeyInputView alloc] initWithFrame:CGRectZero];
    self.keyInput.onCharacter = ^(unichar c) { [weakSelf typeCharacter:c]; };
    self.keyInput.onBackspace = ^{ [weakSelf tapKey:[GFInputProtocol keyNamed:@"backspace"]]; };
    self.keyInput.accessory = [self keyboardAccessory];
    [self.view addSubview:self.keyInput];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(settingsChanged) name:GFSettingsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appWillResign) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
}

- (UIView *)keyboardAccessory
{
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    bar.barStyle = UIBarStyleBlack;
    NSMutableArray *items = [NSMutableArray array];
    NSArray *keys = @[ @[ @"Esc", @"escape" ], @[ @"Tab", @"tab" ], @[ @"Enter", @"enter" ], @[ @"↑", @"up" ], @[ @"↓", @"down" ], @[ @"←", @"left" ], @[ @"→", @"right" ], @[ @"F1", @"f1" ], @[ @"F5", @"f5" ] ];
    for (NSArray *k in keys) {
        UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithTitle:k[0] style:UIBarButtonItemStyleBordered target:self action:@selector(accessoryKey:)];
        item.accessibilityLabel = k[1];
        [items addObject:item];
    }
    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil]];
    [items addObject:[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(hideKeyboard)]];
    bar.items = items;
    return bar;
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    self.spinner.center = CGPointMake(w / 2, h / 2);
    CGSize s = [self.statusLabel.text sizeWithFont:self.statusLabel.font constrainedToSize:CGSizeMake(w - 80, 120)];
    self.statusLabel.frame = CGRectMake((w - s.width - 24) / 2, h / 2 + 40, s.width + 24, s.height + 12);
    self.menuButton.frame = CGRectMake(w / 2 - 16, 6, 32, 32);
    CGSize st = [self.statsLabel.text sizeWithFont:self.statsLabel.font constrainedToSize:CGSizeMake(w / 2, 200)];
    self.statsLabel.frame = CGRectMake(w / 2 + 30, 6, st.width + 10, st.height + 6);
    CGSize ts = [self.toastLabel.text sizeWithFont:self.toastLabel.font constrainedToSize:CGSizeMake(w - 80, 100)];
    self.toastLabel.frame = CGRectMake((w - ts.width - 30) / 2, 50, ts.width + 30, ts.height + 14);
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    if (self.startedAt) return;
    self.startedAt = [NSDate date];
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    [self startPipeline];
}

- (BOOL)shouldAutorotate { return YES; }
- (NSUInteger)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)settingsChanged
{
    self.gamepad.controlOpacity = [GFSettings gamepadOpacity];
    self.gamepad.hidden = ![GFSettings touchGamepad];
    self.statsLabel.hidden = ![GFSettings showStats];
}

- (void)appWillResign
{
    // the host keeps running; release every button so nothing stays pressed
    GFGamepadState zero;
    memset(&zero, 0, sizeof(zero));
    [self.peer sendGamepad:zero];
}

- (void)appDidBecomeActive
{
    [self.peer requestKeyframe];
}

#pragma mark - Pipeline

- (void)startPipeline
{
    if (![GFVideoDecoder isAvailable]) {
        [self endWithMessage:L(@"This device has no usable hardware video decoder (VideoToolbox).")];
        return;
    }
    self.decoder = [[GFVideoDecoder alloc] init];
    GFVideoDecoder *decoder = self.decoder;
    self.videoView.frameSource = ^CVPixelBufferRef { return [decoder copyLatestFrame]; };
    [self.videoView startDisplayLink];
    self.audio = [[GFAudioPlayer alloc] init];
    [self.audio start];
    self.statusLabel.text = L(@"Contacting the game server…");
    [self.view setNeedsLayout];
    self.signaling = [[GFSignaling alloc] initWithSession:self.session delegate:self];
    [self.signaling connect];
}

- (void)signalingDidConnect:(GFSignaling *)signaling
{
    self.statusLabel.text = L(@"Waiting for the server's offer…");
    [self.view setNeedsLayout];
}

- (void)signaling:(GFSignaling *)signaling didReceiveOffer:(NSString *)sdp
{
    if (self.offerHandled || self.finished) return;
    self.offerHandled = YES;
    GFSDPOffer *offer = [GFSDPOffer offerWithSDP:sdp serverIp:self.session.serverIp];
    if (offer.h264PayloadType < 0) {
        [self endWithMessage:L(@"The server offered no H.264 video stream.")];
        return;
    }
    GFLog(@"Offer: H264 pt %ld (%@), opus %ld, red %ld, sctp %ld, %lu candidates, fingerprint %@", (long)offer.h264PayloadType, offer.h264Fmtp,
          (long)offer.opusPayloadType, (long)offer.redPayloadType, (long)offer.sctpPort, (unsigned long)offer.candidates.count, offer.fingerprint);
    self.peer = [[GFPeer alloc] initWithSession:self.session offer:offer delegate:self];
    CGSize size = [GFSettings streamSize];
    self.peer.streamWidth = self.session.width ?: (NSInteger)size.width;
    self.peer.streamHeight = self.session.height ?: (NSInteger)size.height;
    self.peer.streamFps = self.session.fps ?: [GFSettings streamFps];
    self.peer.maxKbps = [GFSettings maxBitrateMbps] * 1000;
    GFVideoDecoder *decoder = self.decoder;
    GFAudioPlayer *audio = self.audio;
    NSInteger redPT = offer.redPayloadType;
    self.peer.videoSink = ^(const uint8_t *au, size_t len, uint32_t ts, BOOL keyframe, BOOL damaged) {
        [decoder decodeAccessUnit:au length:len timestamp:ts keyframe:keyframe];
    };
    self.peer.audioSink = ^(const uint8_t *payload, size_t len, uint16_t seq, uint8_t pt, uint32_t ts) {
        [audio pushPacket:payload length:len sequence:seq payloadType:pt redPayloadType:redPT];
    };
    [self.peer start];
}

- (void)signaling:(GFSignaling *)signaling didReceiveCandidate:(NSDictionary *)candidate
{
    [self.peer addRemoteCandidate:candidate];
}

- (void)signaling:(GFSignaling *)signaling didClose:(NSString *)reason
{
    if (self.finished) return;
    if ([reason isEqualToString:@"BYE"] || [reason isEqualToString:@"peerRemoved"]) {
        [self endWithMessage:L(@"The session was ended by the server.")];
    } else if (!self.peer.isConnected) {
        [self endWithMessage:[NSString stringWithFormat:L(@"Signaling failed: %@"), reason]];
    } else {
        GFLog(@"Signaling dropped after the stream was up (%@); carrying on", reason);
    }
}

#pragma mark - Peer

- (void)peer:(GFPeer *)peer status:(NSString *)status
{
    if (self.gotFirstFrame) return;
    self.statusLabel.text = status;
    [self.view setNeedsLayout];
}

- (void)peer:(GFPeer *)peer didCreateAnswer:(NSString *)sdp nvstSDP:(NSString *)nvstSDP
{
    [self.signaling sendAnswer:sdp nvstSDP:nvstSDP];
}

- (void)peer:(GFPeer *)peer didGatherCandidate:(NSDictionary *)candidate
{
    [self.signaling sendCandidate:candidate];
}

- (void)peerDidConnect:(GFPeer *)peer
{
    self.statusLabel.text = L(@"Connected, waiting for the first picture…");
    [self.view setNeedsLayout];
}

- (void)peer:(GFPeer *)peer inputReadyWithProtocolVersion:(NSInteger)version
{
    [self showToast:L(@"Controls connected")];
}

- (void)peer:(GFPeer *)peer didReceiveControlMessage:(NSDictionary *)message
{
    NSString *type = GFStr(message[@"type"]);
    if ([type isEqualToString:@"timerNotification"]) {
        NSInteger seconds = GFInt(message[@"secondsLeft"]);
        if (seconds > 0) [self showToast:[NSString stringWithFormat:L(@"Session time left: %@"), [GFUtils formatDuration:seconds]]];
    } else {
        GFLog(@"Control message: %@", message);
    }
}

- (void)peer:(GFPeer *)peer stats:(NSDictionary *)stats
{
    self.lastStats = stats;
    if (!self.gotFirstFrame && self.decoder.decodedFrames > 0) {
        self.gotFirstFrame = YES;
        [self.spinner stopAnimating];
        self.statusLabel.hidden = YES;
        GFLog(@"First picture after %.1f s", -[self.startedAt timeIntervalSinceNow]);
    }
    if (!self.statsLabel.hidden) {
        self.statsLabel.text = [NSString stringWithFormat:@"%.0f fps  %.0f kb/s  rtt %.0f ms\nlost %@  pli %@  nack %@\ndec %llu (%.1f ms) err %llu drop %llu\naudio %@ pk  buf %ld ms  conceal %llu",
                                [stats[@"fps"] doubleValue], [stats[@"kbps"] doubleValue], [stats[@"rtt"] doubleValue],
                                stats[@"lost"], stats[@"pli"], stats[@"nack"],
                                self.decoder.decodedFrames, self.decoder.averageDecodeMs, self.decoder.errors, self.decoder.droppedInputs,
                                stats[@"audio"], (long)self.audio.bufferedMs, self.audio.concealed];
        [self.view setNeedsLayout];
    }
}

- (void)peer:(GFPeer *)peer didDisconnect:(NSString *)reason
{
    [self endWithMessage:reason];
}

#pragma mark - Ending

- (void)endWithMessage:(NSString *)message
{
    if (self.finished) return;
    self.finished = YES;
    GFLog(@"Stream over: %@", message ?: @"-");
    [self.keyInput resignFirstResponder];
    [self.videoView stopDisplayLink];
    [self.peer close];
    self.peer = nil;
    [self.signaling close];
    self.signaling = nil;
    [self.audio stop];
    [self.decoder invalidate];
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [GFCloudMatch stopSession:self.session completion:nil];
    if (self.onFinished) self.onFinished(message);
}

#pragma mark - Menu

- (void)showMenu
{
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:self.gameTitle delegate:self cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    [sheet addButtonWithTitle:L(@"Keyboard")];
    [sheet addButtonWithTitle:self.gamepad.hidden ? L(@"Show gamepad") : L(@"Hide gamepad")];
    [sheet addButtonWithTitle:self.mouseMode ? L(@"Mouse mode: on") : L(@"Mouse mode: off")];
    [sheet addButtonWithTitle:self.statsLabel.hidden ? L(@"Show statistics") : L(@"Hide statistics")];
    [sheet addButtonWithTitle:L(@"Send Escape")];
    [sheet addButtonWithTitle:L(@"Send Alt+Enter")];
    sheet.destructiveButtonIndex = [sheet addButtonWithTitle:L(@"Quit game")];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:L(@"Back to game")];
    if (GFIsPad()) [sheet showFromRect:self.menuButton.frame inView:self.view animated:YES];
    else [sheet showInView:self.view];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)index
{
    switch (index) {
        case 0: [self.keyInput becomeFirstResponder]; break;
        case 1: [GFSettings setTouchGamepad:self.gamepad.hidden]; break;
        case 2: self.mouseMode = !self.mouseMode; [self showToast:self.mouseMode ? L(@"Mouse mode: drag to move, tap to click, two fingers for the right button") : L(@"Mouse mode off")]; break;
        case 3: [GFSettings setShowStats:self.statsLabel.hidden]; break;
        case 4: [self tapKey:[GFInputProtocol keyNamed:@"escape"]]; break;
        case 5: {
            GFKeyStroke alt = [GFInputProtocol keyNamed:@"alt"], enter = [GFInputProtocol keyNamed:@"enter"];
            [self.peer sendKey:alt pressed:YES];
            enter.modifiers = 0x04;
            [self.peer sendKey:enter pressed:YES];
            [self.peer sendKey:enter pressed:NO];
            [self.peer sendKey:alt pressed:NO];
            break;
        }
        case 6: [self endWithMessage:nil]; break;
        default: break;
    }
}

- (void)showToast:(NSString *)text
{
    self.toastLabel.text = text;
    self.toastLabel.hidden = NO;
    [self.view setNeedsLayout];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:3.0];
}

- (void)hideToast
{
    self.toastLabel.hidden = YES;
}

#pragma mark - Keyboard

- (void)tapKey:(GFKeyStroke)key
{
    [self.peer sendKey:key pressed:YES];
    [self.peer sendKey:key pressed:NO];
}

- (void)typeCharacter:(unichar)c
{
    GFKeyStroke key;
    if (![GFInputProtocol keyStroke:&key forCharacter:c]) return;
    if (key.modifiers & 0x01) [self.peer sendKey:[GFInputProtocol keyNamed:@"shift"] pressed:YES];
    [self tapKey:key];
    if (key.modifiers & 0x01) [self.peer sendKey:[GFInputProtocol keyNamed:@"shift"] pressed:NO];
}

- (void)accessoryKey:(UIBarButtonItem *)item
{
    [self tapKey:[GFInputProtocol keyNamed:item.accessibilityLabel]];
}

- (void)hideKeyboard
{
    [self.keyInput resignFirstResponder];
}

#pragma mark - Mouse

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer
{
    return self.mouseMode && self.peer.inputReady;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b
{
    return [a isKindOfClass:[UILongPressGestureRecognizer class]] || [b isKindOfClass:[UILongPressGestureRecognizer class]];
}

- (void)mousePan:(UIPanGestureRecognizer *)pan
{
    CGPoint p = [pan locationInView:self.videoView];
    if (pan.state == UIGestureRecognizerStateBegan) { self.lastPan = p; return; }
    if (pan.state != UIGestureRecognizerStateChanged) return;
    CGFloat sens = [GFSettings mouseSensitivity] * [UIScreen mainScreen].scale;
    CGFloat fx = (p.x - self.lastPan.x) * sens + self.mouseRemainderX;
    CGFloat fy = (p.y - self.lastPan.y) * sens + self.mouseRemainderY;
    int dx = (int)fx, dy = (int)fy;
    self.mouseRemainderX = fx - dx;
    self.mouseRemainderY = fy - dy;
    self.lastPan = p;
    if (dx || dy) [self.peer sendMouseMoveDX:dx dy:dy];
}

- (void)mouseTap:(UITapGestureRecognizer *)tap
{
    [self.peer sendMouseButton:1 pressed:YES];
    [self.peer sendMouseButton:1 pressed:NO];
}

- (void)mouseRightTap:(UITapGestureRecognizer *)tap
{
    [self.peer sendMouseButton:3 pressed:YES];
    [self.peer sendMouseButton:3 pressed:NO];
}

- (void)mouseHold:(UILongPressGestureRecognizer *)hold
{
    if (hold.state == UIGestureRecognizerStateBegan) {
        [self.peer sendMouseButton:1 pressed:YES];
        self.lastPan = [hold locationInView:self.videoView];
    } else if (hold.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [hold locationInView:self.videoView];
        CGFloat sens = [GFSettings mouseSensitivity] * [UIScreen mainScreen].scale;
        int dx = (int)((p.x - self.lastPan.x) * sens), dy = (int)((p.y - self.lastPan.y) * sens);
        if (dx || dy) { [self.peer sendMouseMoveDX:dx dy:dy]; self.lastPan = p; }
    } else if (hold.state == UIGestureRecognizerStateEnded || hold.state == UIGestureRecognizerStateCancelled) {
        [self.peer sendMouseButton:1 pressed:NO];
    }
}

- (void)mouseWheel:(UIPanGestureRecognizer *)pan
{
    if (pan.state != UIGestureRecognizerStateChanged) return;
    CGPoint t = [pan translationInView:self.videoView];
    if (fabs(t.y) >= 20) {
        [self.peer sendMouseWheel:t.y < 0 ? -120 : 120];
        [pan setTranslation:CGPointZero inView:self.videoView];
    }
}

#pragma mark - Debug

- (void)debugCommand:(NSString *)command params:(NSDictionary *)params
{
    if ([command isEqualToString:@"key"]) {
        [self tapKey:[GFInputProtocol keyNamed:params[@"name"] ?: @"escape"]];
    } else if ([command isEqualToString:@"type"]) {
        NSString *text = params[@"text"] ?: @"";
        for (NSUInteger i = 0; i < text.length; i++) [self typeCharacter:[text characterAtIndex:i]];
    } else if ([command isEqualToString:@"pad"]) {
        GFGamepadState s;
        memset(&s, 0, sizeof(s));
        s.buttons = (uint16_t)strtoul([params[@"buttons"] ?: @"0" UTF8String], NULL, 0);
        s.leftX = (int16_t)[params[@"lx"] intValue];
        s.leftY = (int16_t)[params[@"ly"] intValue];
        [self.peer sendGamepad:s];
        double hold = [params[@"hold"] doubleValue] ?: 0.2;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            GFGamepadState zero;
            memset(&zero, 0, sizeof(zero));
            [self.peer sendGamepad:zero];
        });
    } else if ([command isEqualToString:@"mouse"]) {
        [self.peer sendMouseMoveDX:[params[@"dx"] intValue] dy:[params[@"dy"] intValue]];
        if ([params[@"click"] boolValue]) { [self.peer sendMouseButton:1 pressed:YES]; [self.peer sendMouseButton:1 pressed:NO]; }
    } else if ([command isEqualToString:@"keyframe"]) {
        [self.peer requestKeyframe];
    } else if ([command isEqualToString:@"quit"]) {
        [self endWithMessage:nil];
    }
}

- (NSString *)debugDescription
{
    return [NSString stringWithFormat:@"stream %@ connected=%d input=%d firstFrame=%d decoded=%llu errors=%llu dropped=%llu decodeMs=%.1f drawn=%llu audioDecoded=%llu concealed=%llu underruns=%llu stats=%@",
            self.session.sessionId, self.peer.isConnected, self.peer.inputReady, self.gotFirstFrame, self.decoder.decodedFrames, self.decoder.errors,
            self.decoder.droppedInputs, self.decoder.averageDecodeMs, self.videoView.framesDrawn, self.audio.decoded, self.audio.concealed, self.audio.underruns, self.lastStats];
}

@end
