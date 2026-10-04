#import "GFCloudMatch.h"
#import "GFAPI.h"
#import "GFAuth.h"
#import "GFHTTP.h"
#import "GFSettings.h"
#import "GFUtils.h"
#import "GFCommon.h"

static const NSTimeInterval GFPollInterval = 2.0;
static const NSInteger GFMaxPolls = 1800;                 // an hour of queue at 2 s
static const NSInteger GFMaxServerErrors = 12;

// A string, number or [string] - CloudMatch sends ids in every shape
static NSString *GFFlexString(id v)
{
    if ([v isKindOfClass:[NSArray class]]) return GFFlexString([v firstObject]);
    return GFStr(v);
}

// Named statuses normalized to the numeric codes
static NSInteger GFStatusCode(id v)
{
    if ([v isKindOfClass:[NSNumber class]]) return [v integerValue];
    NSString *s = [GFStr(v) lowercaseString];
    if (!s.length) return -1;
    if ([s isEqualToString:@"queued"]) return 0;
    for (NSString *w in @[ @"provisioning", @"initializing", @"setup", @"setting_up", @"launching" ]) if ([s hasPrefix:w]) return 1;
    for (NSString *w in @[ @"active", @"ready", @"paused" ]) if ([s isEqualToString:w]) return 2;
    for (NSString *w in @[ @"streaming", @"playing", @"connected" ]) if ([s isEqualToString:w]) return 3;
    for (NSString *w in @[ @"fail", @"error", @"closed", @"terminated", @"cancel" ]) if ([s rangeOfString:w].location != NSNotFound) return 4;
    if ([s rangeOfString:@"ad"].location != NSNotFound) return 6;
    return -1;
}

static NSString *GFHostOf(NSString *url)
{
    NSString *s = url ?: @"";
    for (NSString *p in @[ @"rtsps://", @"rtsp://", @"wss://", @"https://", @"ws://", @"http://" ]) {
        if ([s hasPrefix:p]) { s = [s substringFromIndex:p.length]; break; }
    }
    s = [s componentsSeparatedByString:@"/"].firstObject ?: @"";
    s = [s componentsSeparatedByString:@":"].firstObject ?: @"";
    if (!s.length || [s hasPrefix:@"."]) return nil;
    return s;
}

static BOOL GFIsZoneHost(NSString *host)
{
    return [host rangeOfString:@"cloudmatchbeta.nvidiagrid.net"].location != NSNotFound || [host rangeOfString:@"cloudmatch.nvidiagrid.net"].location != NSNotFound;
}

@interface GFCloudMatch ()
@property (nonatomic, copy) NSString *appId;
@property (nonatomic, copy) NSString *clientId;
@property (nonatomic, copy) NSString *deviceId;
@property (nonatomic, copy) NSString *baseURL;              // the zone this launch uses (no trailing slash)
@property (nonatomic, copy) NSString *globalBaseURL;
@property (nonatomic, copy) GFSessionBlock completion;
@property (nonatomic, strong) GFSession *session;
@property (nonatomic) BOOL cancelled;
@property (nonatomic) NSInteger polls;
@property (nonatomic) NSInteger serverErrors;
@property (nonatomic) NSInteger createThrottled;
@property (nonatomic) NSInteger cleanups;
@property (nonatomic) BOOL wasQueued;
@property (nonatomic, strong) NSMutableDictionary *adStates; // adId -> @(start time) or @"done"
@property (nonatomic, strong) NSArray *ads;                  // dictionaries {adId, lengthMs}
@property (nonatomic, strong) GFHTTPTask *task;
@end

@implementation GFCloudMatch

- (instancetype)initWithAppId:(NSString *)appId
{
    if ((self = [super init])) {
        _appId = [appId copy];
        _clientId = [[[NSUUID UUID] UUIDString] lowercaseString];
        _deviceId = [GFSettings deviceId];
        _adStates = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)progress:(NSString *)message queue:(NSInteger)position eta:(NSInteger)eta
{
    if (self.onProgress) self.onProgress(message, position, eta);
}

- (NSDictionary *)headers
{
    return [GFAPI cloudMatchHeadersWithClientId:self.clientId deviceId:self.deviceId];
}

- (void)finishWithSession:(GFSession *)session error:(NSError *)error
{
    if (self.cancelled) return;
    GFSessionBlock block = self.completion;
    self.completion = nil;
    if (block) block(session, error);
}

#pragma mark - Start

- (void)startWithCompletion:(GFSessionBlock)completion
{
    self.completion = completion;
    [self progress:L(@"Checking the account…") queue:0 eta:0];
    [[GFAuth shared] ensureFreshTokens:^(NSError *error) {
        if (self.cancelled) return;
        if (error && error.code == GFErrorAuth) { [self finishWithSession:nil error:error]; return; }
        NSString *global = [[GFAuth shared] streamingBaseURL];
        self.globalBaseURL = [global hasSuffix:@"/"] ? [global substringToIndex:global.length - 1] : global;
        NSString *zone = [GFSettings region];
        if ([zone hasPrefix:@"https://"]) {
            self.baseURL = [zone hasSuffix:@"/"] ? [zone substringToIndex:zone.length - 1] : zone;
            GFLog(@"Creating the session on the pinned zone %@", self.baseURL);
        } else {
            self.baseURL = self.globalBaseURL;
        }
        [self stopLeftoversThenCreate];
    }];
}

// Anything still open on this account would reject the launch: end it first (the note from a crash, then what
// CloudMatch lists), wait for the slot to clear, then create.
- (void)stopLeftoversThenCreate
{
    [self progress:L(@"Ending sessions left open…") queue:0 eta:0];
    [GFCloudMatch stopRememberedSessionWithCompletion:^{
        if (self.cancelled) return;
        [self listActiveSessions:^(NSArray *ids, BOOL ok) {
            if (self.cancelled) return;
            if (!ids.count) { [self createSession]; return; }
            GFLog(@"Ending %lu session(s) still open before launching: %@", (unsigned long)ids.count, [ids componentsJoinedByString:@", "]);
            [self stopSessionIds:ids index:0 stoppedAny:NO completion:^(BOOL stoppedAny) {
                if (self.cancelled) return;
                if (!stoppedAny) { [self createSession]; return; }
                [self waitForClear:0 completion:^{ if (!self.cancelled) [self createSession]; }];
            }];
        }];
    }];
}

- (NSArray *)cleanupBases
{
    if ([self.baseURL isEqualToString:self.globalBaseURL]) return @[ self.globalBaseURL ];
    return @[ self.baseURL, self.globalBaseURL ];
}

// Session ids CloudMatch still counts against the per-device limit (everything except finished ones)
- (void)listActiveSessions:(void (^)(NSArray *ids, BOOL ok))completion
{
    NSArray *bases = [self cleanupBases];
    NSMutableArray *all = [NSMutableArray array];
    __block NSInteger pending = bases.count;
    __block BOOL anyOk = NO;
    for (NSString *base in bases) {
        [GFHTTP get:[base stringByAppendingString:@"/v2/session"] headers:[self headers] completion:^(NSInteger status, NSData *body, NSDictionary *h, NSError *error) {
            NSDictionary *json = GFDict([GFUtils JSONObjectFromData:body]);
            if (json) {
                anyOk = YES;
                for (NSDictionary *s in GFArr(json[@"sessions"])) {
                    NSString *id = GFFlexString(GFDict(s)[@"sessionId"]);
                    if (id.length && GFStatusCode(GFDict(s)[@"status"]) != 4 && ![all containsObject:id]) [all addObject:id];
                }
            } else if (error) {
                GFLog(@"Could not list sessions on %@: %@", base, error.localizedDescription);
            }
            if (--pending == 0) completion(all, anyOk);
        }];
    }
}

- (void)stopSessionIds:(NSArray *)ids index:(NSUInteger)index stoppedAny:(BOOL)stoppedAny completion:(void (^)(BOOL stoppedAny))completion
{
    if (index >= ids.count) { completion(stoppedAny); return; }
    [GFCloudMatch deleteSession:ids[index] bases:[self cleanupBases] index:0 headers:[self headers] completion:^(NSInteger outcome) {
        [self stopSessionIds:ids index:index + 1 stoppedAny:stoppedAny || outcome == 1 completion:completion];
    }];
}

// outcome: 1 stopped (deleted or already gone), 2 forbidden (another device identity), 0 failed
+ (void)deleteSession:(NSString *)sessionId bases:(NSArray *)bases index:(NSUInteger)index headers:(NSDictionary *)headers completion:(void (^)(NSInteger outcome))completion
{
    if (index >= bases.count) { completion(1); return; }   // not found anywhere = gone
    NSString *url = [NSString stringWithFormat:@"%@/v2/session/%@", bases[index], sessionId];
    [GFHTTP request:@"DELETE" url:url headers:headers body:nil retries:0 completion:^(NSInteger status, NSData *body, NSDictionary *h, NSError *error) {
        if (status >= 200 && status < 300) { GFLog(@"Session %@ ended", sessionId); completion(1); return; }
        if (status == 404) { [self deleteSession:sessionId bases:bases index:index + 1 headers:headers completion:completion]; return; }
        if (status == 403) { GFLog(@"CloudMatch refused to end session %@ (another device identity)", sessionId); completion(2); return; }
        GFLog(@"Ending session %@ failed: HTTP %ld %@", sessionId, (long)status, error.localizedDescription ?: @"");
        completion(0);
    }];
}

// A 200 on the DELETE only means NVIDIA accepted it; deprovisioning takes longer. Up to 8 checks, 3 s apart.
- (void)waitForClear:(NSInteger)check completion:(dispatch_block_t)completion
{
    if (check >= 8) { GFLog(@"CloudMatch still reports sessions after 24 s, launching anyway"); completion(); return; }
    [self progress:L(@"Waiting for the previous session to close…") queue:0 eta:0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.cancelled) return;
        [self listActiveSessions:^(NSArray *ids, BOOL ok) {
            if (self.cancelled) return;
            if (!ok || !ids.count) { completion(); return; }
            [self waitForClear:check + 1 completion:completion];
        }];
    }];
}

#pragma mark - Create

- (NSDictionary *)requestBody
{
    CGSize size = [GFSettings streamSize];
    NSInteger width = (NSInteger)size.width, height = (NSInteger)size.height, fps = [GFSettings streamFps];
    NSString *resolution = [GFUtils JSONDataFromObject:@{ @"horizontalPixels": @(width), @"verticalPixels": @(height) }] ?
        [[NSString alloc] initWithData:[GFUtils JSONDataFromObject:@{ @"horizontalPixels": @(width), @"verticalPixels": @(height) }] encoding:NSUTF8StringEncoding] : @"";
    NSArray *metadata = @[
        @{ @"key": @"SubSessionId", @"value": [[[NSUUID UUID] UUIDString] lowercaseString] },
        @{ @"key": @"wssignaling", @"value": @"1" },
        @{ @"key": @"GSStreamerType", @"value": @"WebRTC" },
        @{ @"key": @"networkType", @"value": @"Unknown" },
        @{ @"key": @"ClientImeSupport", @"value": @"0" },
        @{ @"key": @"clientPhysicalResolution", @"value": resolution },
        @{ @"key": @"surroundAudioInfo", @"value": @"2" },
    ];
    return @{ @"sessionRequestData": @{
        @"appId": self.appId,
        @"internalTitle": [NSNull null],
        @"availableSupportedControllers": @[],
        @"networkTestSessionId": [NSNull null],
        @"parentSessionId": [NSNull null],
        @"clientIdentification": @"GFN-PC",
        @"deviceHashId": self.deviceId,
        @"clientVersion": @"30.0",
        @"sdkVersion": @"1.0",
        @"streamerVersion": @1,
        @"clientPlatformName": @"windows",
        @"clientRequestMonitorSettings": @[ @{
            @"monitorId": @0, @"positionX": @0, @"positionY": @0,
            @"widthInPixels": @(width), @"heightInPixels": @(height), @"framesPerSecond": @(fps),
            @"sdrHdrMode": @0, @"displayData": @{}, @"hdr10PlusGamingData": [NSNull null], @"dpi": @0,
        } ],
        @"useOps": @YES,
        @"audioMode": @2,
        @"metaData": metadata,
        @"sdrHdrMode": @0,
        @"clientDisplayHdrCapabilities": [NSNull null],
        @"surroundAudioInfo": @0,
        @"remoteControllersBitmap": @0,
        @"clientTimezoneOffset": @([[NSTimeZone localTimeZone] secondsFromGMT] / 60),
        @"enhancedStreamMode": @1,
        @"appLaunchMode": @2,
        @"secureRTSPSupported": @NO,
        @"partnerCustomData": @"",
        @"accountLinked": @YES,
        @"enablePersistingInGameSettings": @NO,
        @"userAge": @26,
        @"requestedStreamingFeatures": @{
            @"reflex": @NO, @"bitDepth": @0, @"cloudGsync": @NO, @"enabledL4S": @NO, @"supportedHidDevices": @0, @"profile": @0,
            @"fallbackToLogicalResolution": @NO, @"chromaFormat": @0, @"prefilterMode": @1, @"prefilterSharpness": @50,
            @"prefilterNoiseReduction": @0, @"hudStreamingMode": @0,
        }
    } };
}

- (void)createSession
{
    [self progress:L(@"Requesting a seat…") queue:0 eta:0];
    NSString *language = [GFSettings gameLanguage];
    NSString *url = [NSString stringWithFormat:@"%@/v2/session?keyboardLayout=us&languageCode=%@", self.baseURL, [GFUtils urlEncode:language.length ? language : @"en_US"]];
    NSData *body = [GFUtils JSONDataFromObject:[self requestBody]];
    self.task = [GFHTTP request:@"POST" url:url headers:[self headers] body:body retries:0 completion:^(NSInteger status, NSData *data, NSDictionary *h, NSError *error) {
        if (self.cancelled) return;
        NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"" : @"";
        NSDictionary *json = GFDict([GFUtils JSONObjectFromData:data]);
        NSDictionary *rs = GFDict(json[@"requestStatus"]);
        NSInteger code = GFInt(rs[@"statusCode"]);
        NSString *describe = [self describeStatus:rs];
        if (status >= 200 && status < 300 && json) {
            if (code == 1) { [self adoptPayload:json]; [self pollSession]; return; }
            if ([self isSessionLimit:rs text:text]) { [self handleSessionLimit:json]; return; }
            [self finishWithSession:nil error:GFMakeError(GFErrorAPI, [NSString stringWithFormat:L(@"NVIDIA refused the launch: %@"), describe])];
            return;
        }
        if (status == 403 || [[text uppercaseString] rangeOfString:@"SESSION_LIMIT"].location != NSNotFound) {
            [self handleSessionLimit:json];
            return;
        }
        if (status == 429 || status >= 500) {
            self.createThrottled++;
            if (self.createThrottled <= 6) {
                NSInteger wait = MIN(30, MAX(1, [h[@"retry-after"] integerValue] ?: (2 << MIN(3, self.createThrottled))));
                GFLog(@"CloudMatch replied %ld, retrying in %ld s", (long)status, (long)wait);
                [self progress:L(@"NVIDIA is busy, trying again…") queue:0 eta:0];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!self.cancelled) [self createSession]; });
                return;
            }
            [self finishWithSession:nil error:GFMakeError(GFErrorAPI, L(@"NVIDIA kept refusing the launch (rate limit). Try again in a few minutes."))];
            return;
        }
        if (status == 401) { [self finishWithSession:nil error:GFMakeError(GFErrorAuth, L(@"The sign-in is no longer valid. Sign in again."))]; return; }
        if (status == 0 && error) {
            if (self.createThrottled++ < 3) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!self.cancelled) [self createSession]; });
                return;
            }
            [self finishWithSession:nil error:error];
            return;
        }
        [self finishWithSession:nil error:GFMakeError(GFErrorAPI, [NSString stringWithFormat:@"HTTP %ld: %@", (long)status, describe.length ? describe : [GFUtils truncate:text to:200]])];
    }];
}

- (NSString *)describeStatus:(NSDictionary *)rs
{
    NSString *text = GFStr(rs[@"statusDescription"]) ?: GFStr(rs[@"statusMessage"]);
    id unified = rs[@"unifiedErrorCode"];
    if (text.length && unified) return [NSString stringWithFormat:@"%@ (#%@)", text, unified];
    if (text.length) return text;
    if (unified) return [NSString stringWithFormat:@"#%@", unified];
    return rs ? [NSString stringWithFormat:@"code %ld", (long)GFInt(rs[@"statusCode"])] : @"unknown";
}

- (BOOL)isSessionLimit:(NSDictionary *)rs text:(NSString *)text
{
    NSInteger code = GFInt(rs[@"statusCode"]);
    if (code == 11 || code == 50 || code == 83) return YES;
    NSString *d = [GFStr(rs[@"statusDescription"]) uppercaseString] ?: @"";
    return [d rangeOfString:@"SESSION_LIMIT"].location != NSNotFound || [d rangeOfString:@"SESSION_EXISTS"].location != NSNotFound;
}

- (void)handleSessionLimit:(NSDictionary *)json
{
    if (self.cleanups++ >= 15) {
        [self finishWithSession:nil error:GFMakeError(GFErrorRestricted, L(@"NVIDIA still reports an open session for this account. Close it on another device and try again."))];
        return;
    }
    NSMutableArray *ids = [NSMutableArray array];
    NSString *own = GFFlexString(GFDict(json[@"session"])[@"sessionId"]);
    if (own.length) [ids addObject:own];
    for (NSDictionary *s in GFArr(json[@"otherUserSessions"])) {
        NSString *id = GFFlexString(GFDict(s)[@"sessionId"]);
        if (id.length && ![ids containsObject:id]) [ids addObject:id];
    }
    [self progress:L(@"Ending the session already open…") queue:0 eta:0];
    [self listActiveSessions:^(NSArray *listed, BOOL ok) {
        if (self.cancelled) return;
        for (NSString *id in listed) if (![ids containsObject:id]) [ids addObject:id];
        if (!ids.count) {
            [self finishWithSession:nil error:GFMakeError(GFErrorRestricted, L(@"NVIDIA reports an open session for this account that this device may not close."))];
            return;
        }
        GFLog(@"Session limit hit; stopping %@", [ids componentsJoinedByString:@", "]);
        [self stopSessionIds:ids index:0 stoppedAny:NO completion:^(BOOL stoppedAny) {
            if (self.cancelled) return;
            if (!stoppedAny) {
                [self finishWithSession:nil error:GFMakeError(GFErrorRestricted, L(@"NVIDIA reports an open session for this account that this device may not close."))];
                return;
            }
            [self waitForClear:0 completion:^{ if (!self.cancelled) [self createSession]; }];
        }];
    }];
}

#pragma mark - Poll

- (void)pollSession
{
    if (self.cancelled) return;
    if (self.polls++ >= GFMaxPolls) {
        [self finishWithSession:nil error:GFMakeError(GFErrorTimeout, L(@"The session did not become ready in time."))];
        return;
    }
    NSString *url = [NSString stringWithFormat:@"%@/v2/session/%@", self.session.streamingBaseURL, self.session.sessionId];
    self.task = [GFHTTP get:url headers:[self headers] completion:^(NSInteger status, NSData *data, NSDictionary *h, NSError *error) {
        if (self.cancelled) return;
        NSDictionary *json = GFDict([GFUtils JSONObjectFromData:data]);
        NSDictionary *rs = GFDict(json[@"requestStatus"]);
        if (status >= 500 || (status == 0 && error)) {
            BOOL patching = GFInt(rs[@"statusCode"]) == 41 && [[GFStr(rs[@"statusDescription"]) uppercaseString] rangeOfString:@"APP_PATCHING"].location != NSNotFound;
            if (patching) {
                self.serverErrors = 0;
                [self progress:L(@"The game is being updated on NVIDIA's side, please wait…") queue:0 eta:0];
                [self scheduleNextPoll:GFPollInterval];
                return;
            }
            self.serverErrors++;
            if (self.serverErrors > GFMaxServerErrors) {
                [self finishWithSession:nil error:error ?: GFMakeError(GFErrorAPI, [NSString stringWithFormat:L(@"NVIDIA stopped answering: %@"), [self describeStatus:rs]])];
                return;
            }
            NSTimeInterval backoff = MIN(15.0, GFPollInterval * (1 << MIN(3, self.serverErrors - 1)));
            [self progress:L(@"NVIDIA is busy, trying again…") queue:0 eta:0];
            [self scheduleNextPoll:backoff];
            return;
        }
        self.serverErrors = 0;
        if (status == 401) { [self finishWithSession:nil error:GFMakeError(GFErrorAuth, L(@"The sign-in is no longer valid. Sign in again."))]; return; }
        if (status < 200 || status >= 300 || !json) {
            [self finishWithSession:nil error:GFMakeError(GFErrorAPI, [NSString stringWithFormat:@"HTTP %ld: %@", (long)status, [self describeStatus:rs]])];
            return;
        }
        if (GFInt(rs[@"statusCode"]) != 1) {
            [self finishWithSession:nil error:GFMakeError(GFErrorAPI, [NSString stringWithFormat:L(@"NVIDIA ended the launch: %@"), [self describeStatus:rs]])];
            return;
        }
        NSDictionary *s = GFDict(json[@"session"]);
        if (!s) { [self finishWithSession:nil error:GFMakeError(GFErrorBadResponse, L(@"Unexpected answer from NVIDIA."))]; return; }
        [self observeAds:s];
        NSDictionary *seat = GFDict(s[@"seatSetupInfo"]);
        NSInteger position = GFInt(seat[@"queuePosition"]);
        NSInteger eta = GFInt(seat[@"seatSetupEta"]);
        NSInteger st = GFStatusCode(s[@"status"]);
        if (position > 0) self.wasQueued = YES;
        NSString *message;
        if (position > 0) message = [NSString stringWithFormat:L(@"In the queue: position %ld"), (long)position];
        else if (st == 1) message = L(@"Your rig is starting the game…");
        else if (st == 0) message = L(@"Waiting in the queue…");
        else message = L(@"Preparing the session…");
        if (self.ads.count && [self pendingAd]) message = L(@"A short sponsor break, please wait…");
        [self progress:message queue:position eta:eta];
        if (st == 2 || st == 3) {
            [self adoptPayload:json];
            GFLog(@"Session ready: %@", self.session);
            [self finishWithSession:self.session error:nil];
            return;
        }
        if (st == 4 || st == 7) {
            [self finishWithSession:nil error:GFMakeError(GFErrorAPI, L(@"NVIDIA ended the session before it started."))];
            return;
        }
        [self scheduleNextPoll:GFPollInterval];
    }];
}

- (void)scheduleNextPoll:(NSTimeInterval)delay
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self pollSession]; });
}

#pragma mark - Queue ads (free tier)

- (NSDictionary *)pendingAd
{
    for (NSDictionary *ad in self.ads) {
        if (![self.adStates[ad[@"adId"]] isEqual:@"done"]) return ad;
    }
    return nil;
}

// The free tier shows sponsor videos while queueing and expects the client to report start and finish of each.
// There is no video player here: each one is reported after its length has passed.
- (void)observeAds:(NSDictionary *)session
{
    NSArray *raw = GFArr(session[@"sessionAds"]) ?: GFArr(session[@"ads"]);
    if (raw.count) {
        NSMutableArray *ads = [NSMutableArray array];
        for (NSDictionary *a in raw) {
            NSString *id = GFFlexString(GFDict(a)[@"adId"]);
            if (!id.length) continue;
            double lengthMs = a[@"durationMs"] ? GFDbl(a[@"durationMs"]) : GFDbl(a[@"adLengthInSeconds"]) * 1000;
            [ads addObject:@{ @"adId": id, @"lengthMs": @(lengthMs > 0 ? lengthMs : 15000) }];
        }
        if (ads.count && ![ads isEqualToArray:self.ads]) GFLog(@"Queue ads: %lu", (unsigned long)ads.count);
        self.ads = ads;
    }
    NSDictionary *ad = [self pendingAd];
    if (!ad) return;
    id state = self.adStates[ad[@"adId"]];
    if (!state) {
        [self reportAd:ad[@"adId"] action:1 watchedMs:0 completion:^(BOOL ok) {
            if (ok) self.adStates[ad[@"adId"]] = @([[NSDate date] timeIntervalSince1970]);
        }];
    } else if ([state isKindOfClass:[NSNumber class]]) {
        double elapsedMs = ([[NSDate date] timeIntervalSince1970] - [state doubleValue]) * 1000;
        if (elapsedMs >= [ad[@"lengthMs"] doubleValue]) {
            [self reportAd:ad[@"adId"] action:4 watchedMs:(NSInteger)elapsedMs completion:^(BOOL ok) {
                if (ok) self.adStates[ad[@"adId"]] = @"done";
            }];
        }
    }
}

- (void)reportAd:(NSString *)adId action:(NSInteger)action watchedMs:(NSInteger)watchedMs completion:(void (^)(BOOL ok))completion
{
    NSMutableDictionary *update = [@{ @"adId": adId, @"adAction": @(action), @"clientTimestamp": @((long long)[[NSDate date] timeIntervalSince1970]) } mutableCopy];
    if (action == 4) { update[@"watchedTimeInMs"] = @(watchedMs); update[@"pausedTimeInMs"] = @0; }
    NSDictionary *body = @{ @"action": @6, @"adUpdates": @[ update ] };
    NSString *url = [NSString stringWithFormat:@"%@/v2/session/%@", self.session.streamingBaseURL, self.session.sessionId];
    [GFHTTP request:@"PUT" url:url headers:[self headers] body:[GFUtils JSONDataFromObject:body] retries:0 completion:^(NSInteger status, NSData *data, NSDictionary *h, NSError *error) {
        NSDictionary *json = GFDict([GFUtils JSONObjectFromData:data]);
        BOOL ok = status >= 200 && status < 300 && GFInt(GFDict(json[@"requestStatus"])[@"statusCode"]) == 1;
        GFLog(@"Ad %@ action %ld: %@", adId, (long)action, ok ? @"accepted" : [NSString stringWithFormat:@"rejected (HTTP %ld)", (long)status]);
        completion(ok);
    }];
}

#pragma mark - Parsing

// rtsps://host:port/... becomes wss://host/nvst/; wss:// passes; a bare path hangs off the server ip
- (NSString *)signalingURLFromResource:(NSString *)raw serverIp:(NSString *)serverIp
{
    if ([raw hasPrefix:@"rtsps://"] || [raw hasPrefix:@"rtsp://"]) {
        NSString *host = GFHostOf(raw);
        return host ? [NSString stringWithFormat:@"wss://%@/nvst/", host] : [NSString stringWithFormat:@"wss://%@:443/nvst/", serverIp];
    }
    if ([raw hasPrefix:@"wss://"]) return raw;
    if (!serverIp.length) return nil;
    if ([raw hasPrefix:@"/"]) return [NSString stringWithFormat:@"wss://%@:443%@", serverIp, raw];
    return [NSString stringWithFormat:@"wss://%@:443/nvst/", serverIp];
}

- (BOOL)connection:(NSDictionary *)conn hasUsage:(NSInteger)usage
{
    id u = conn[@"usage"];
    return GFInt(u) == usage && u != nil;
}

- (void)adoptPayload:(NSDictionary *)json
{
    NSDictionary *s = GFDict(json[@"session"]);
    GFSession *info = self.session ?: [[GFSession alloc] init];
    info.sessionId = GFFlexString(s[@"sessionId"]) ?: info.sessionId;
    info.appId = GFFlexString(GFDict(s[@"sessionRequestData"])[@"appId"]) ?: self.appId;
    info.status = GFStatusCode(s[@"status"]);
    info.streamingBaseURL = self.baseURL;
    info.clientId = self.clientId;
    info.deviceId = self.deviceId;
    info.width = GFInt(s[@"width"]);
    info.height = GFInt(s[@"height"]);
    info.fps = GFInt(s[@"fps"]);
    NSDictionary *seat = GFDict(s[@"seatSetupInfo"]);
    info.queuePosition = GFInt(seat[@"queuePosition"]);
    info.etaSeconds = GFInt(seat[@"seatSetupEta"]);
    info.setupStep = GFInt(seat[@"seatSetupStep"]);

    NSArray *connections = GFArr(s[@"connectionInfo"]);
    NSDictionary *signaling = nil;
    for (NSDictionary *c in connections) if (GFDict(c) && [self connection:c hasUsage:14]) { signaling = c; break; }
    // the seat host: usage 14's ip, then the host inside its resourcePath, then sessionControlInfo.ip
    NSString *serverIp = GFFlexString(signaling[@"ip"]);
    if (!serverIp.length) serverIp = GFHostOf(GFStr(signaling[@"resourcePath"]));
    if (!serverIp.length) serverIp = GFFlexString(GFDict(s[@"sessionControlInfo"])[@"ip"]);
    info.serverIp = serverIp ?: @"";
    if (!signaling || !GFFlexString(signaling[@"ip"]).length) {
        for (NSDictionary *c in connections) if (GFDict(c) && GFFlexString(c[@"ip"]).length) { signaling = signaling ?: c; break; }
    }
    NSString *resource = GFStr(signaling[@"resourcePath"]) ?: @"/nvst/";
    info.signalingURL = [self signalingURLFromResource:resource serverIp:info.serverIp];

    info.mediaIp = nil;
    info.mediaPort = 0;
    for (NSNumber *usage in @[ @2, @17 ]) {
        for (NSDictionary *c in connections) {
            if (!GFDict(c) || ![self connection:c hasUsage:[usage integerValue]]) continue;
            NSInteger port = GFInt(c[@"port"]);
            NSString *ip = GFFlexString(c[@"ip"]);
            if (!ip.length) ip = info.serverIp;
            if (port > 1024 && port != 443 && ip.length) { info.mediaIp = ip; info.mediaPort = port; }
            break;
        }
        if (info.mediaPort) break;
    }

    NSMutableArray *ice = [NSMutableArray array];
    for (NSDictionary *server in GFArr(GFDict(s[@"iceServerConfiguration"])[@"iceServers"])) {
        if (!GFDict(server)) continue;
        NSArray *urls = GFArr(server[@"urls"]) ?: (GFStr(server[@"urls"]) ? @[ GFStr(server[@"urls"]) ] : @[]);
        [ice addObject:@{ @"urls": urls, @"username": GFStr(server[@"username"]) ?: @"", @"credential": GFStr(server[@"credential"]) ?: @"" }];
    }
    info.iceServers = ice;
    self.session = info;
    if (info.sessionId.length) [GFSettings rememberSession:info.sessionId baseURL:info.streamingBaseURL];
}

#pragma mark - Stop

- (void)cancel
{
    if (self.cancelled) return;
    self.cancelled = YES;
    [self.task cancel];
    self.completion = nil;
    if (self.session.sessionId.length) [GFCloudMatch stopSession:self.session completion:nil];
}

+ (void)stopSession:(GFSession *)session completion:(dispatch_block_t)completion
{
    if (!session.sessionId.length) { if (completion) completion(); return; }
    NSString *base = session.streamingBaseURL.length ? session.streamingBaseURL : [[[GFAuth shared] streamingBaseURL] stringByReplacingOccurrencesOfString:@"/+$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, [[GFAuth shared] streamingBaseURL].length)];
    NSDictionary *headers = [GFAPI cloudMatchHeadersWithClientId:session.clientId deviceId:session.deviceId];
    [self deleteSession:session.sessionId bases:@[ base ] index:0 headers:headers completion:^(NSInteger outcome) {
        if (outcome != 0 && [[GFSettings rememberedSessionId] isEqualToString:session.sessionId]) [GFSettings forgetSession];
        if (completion) completion();
    }];
}

+ (void)stopRememberedSessionWithCompletion:(dispatch_block_t)completion
{
    NSString *sessionId = [GFSettings rememberedSessionId];
    if (!sessionId.length) { if (completion) completion(); return; }
    NSString *base = [GFSettings rememberedSessionBaseURL];
    if (!base.length) {
        base = [[GFAuth shared] streamingBaseURL];
        base = [base hasSuffix:@"/"] ? [base substringToIndex:base.length - 1] : base;
    }
    GFLog(@"Ending the session left over from a previous run: %@", sessionId);
    NSDictionary *headers = [GFAPI cloudMatchHeadersWithClientId:[[[NSUUID UUID] UUIDString] lowercaseString] deviceId:[GFSettings deviceId]];
    [self deleteSession:sessionId bases:@[ base ] index:0 headers:headers completion:^(NSInteger outcome) {
        if (outcome != 0) [GFSettings forgetSession];   // gone, or not ours to end: either way stop blocking launches with it
        if (completion) completion();
    }];
}

@end
