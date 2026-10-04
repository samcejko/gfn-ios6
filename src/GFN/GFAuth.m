#import "GFAuth.h"
#import "GFKeychain.h"
#import "GFHTTP.h"
#import "GFSettings.h"
#import "GFUtils.h"
#import "GFCommon.h"

// The public OAuth client that supports the device-code grant (the one NVIDIA's own Steam Deck / Linux client uses;
// every open client - OpenNOW, CloudNow, OpenNOW Vita - signs in through it). There is no client secret.
static NSString * const GFOAuthClientID = @"q61ddeJrVt7O90Nl-P-N7I36yctih4Ml6FyXLrb6j-U";
static NSString * const GFDefaultIdpID = @"PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg";
static NSString * const GFDefaultStreamingURL = @"https://prod.cloudmatchbeta.nvidiagrid.net/";
static NSString * const GFOAuthScope = @"openid consent email tk_client age";
static NSString * const GFDeviceAuthorizeURL = @"https://login.nvidia.com/device/authorize";
static NSString * const GFTokenURL = @"https://login.nvidia.com/token";
static NSString * const GFClientTokenURL = @"https://login.nvidia.com/client_token";
static NSString * const GFServiceURLsURL = @"https://pcs.geforcenow.com/v1/serviceUrls";
static NSString * const GFLoginUserAgent = @"Mozilla/5.0 (X11; Linux x86_64; Steam Deck) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36";
static NSString * const GFTokensKey = @"gfn.tokens";
static const NSTimeInterval GFRefreshWindow = 10 * 60;

@implementation GFDeviceCode
- (BOOL)isExpired { return self.expires && [self.expires timeIntervalSinceNow] <= 0; }
@end

@interface GFAuth ()
@property (nonatomic, strong) NSMutableDictionary *tokens;    // access_token, refresh_token, id_token, expires_at, client_token, client_token_expires_at, provider
@property (nonatomic, copy) NSString *userId;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *email;
@property (nonatomic, copy) NSString *membershipTier;
@property (nonatomic, strong) NSMutableArray *refreshWaiters;
@property (nonatomic) BOOL refreshing;
@end

@implementation GFAuth

+ (instancetype)shared
{
    static GFAuth *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[GFAuth alloc] init]; });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _refreshWaiters = [NSMutableArray array];
        NSData *data = [GFKeychain dataForKey:GFTokensKey];
        NSDictionary *saved = data ? GFDict([GFUtils JSONObjectFromData:data]) : nil;
        if (saved[@"access_token"]) {
            _tokens = [saved mutableCopy];
            [self readUserFromTokens];
            GFLog(@"Signed in as %@ (saved login)", _displayName);
        }
    }
    return self;
}

#pragma mark - State

- (BOOL)isSignedIn { return self.tokens[@"access_token"] != nil; }

- (NSString *)bearerToken
{
    return GFStr(self.tokens[@"id_token"]) ?: GFStr(self.tokens[@"access_token"]);
}

- (NSString *)streamingBaseURL
{
    NSString *url = GFStr(GFDict(self.tokens[@"provider"])[@"streamingServiceUrl"]);
    if (!url.length) url = GFDefaultStreamingURL;
    if (![url hasSuffix:@"/"]) url = [url stringByAppendingString:@"/"];
    return url;
}

- (NSString *)providerIdpId
{
    return GFStr(GFDict(self.tokens[@"provider"])[@"idpId"]) ?: GFDefaultIdpID;
}

- (void)saveTokens
{
    if (!self.tokens) { [GFKeychain removeKey:GFTokensKey]; return; }
    [GFKeychain setData:[GFUtils JSONDataFromObject:self.tokens] forKey:GFTokensKey];
}

- (void)notify
{
    GFMain(^{ [[NSNotificationCenter defaultCenter] postNotificationName:GFAuthDidChangeNotification object:self]; });
}

- (void)signOut
{
    self.tokens = nil;
    self.userId = nil;
    self.displayName = nil;
    self.email = nil;
    self.membershipTier = nil;
    [GFKeychain removeKey:GFTokensKey];
    GFLog(@"Signed out");
    [self notify];
}

// sub / email / preferred_username out of the id token (its signature is not checked: it came from NVIDIA over TLS)
- (void)readUserFromTokens
{
    NSString *jwt = [self bearerToken];
    NSArray *parts = [jwt componentsSeparatedByString:@"."];
    if (parts.count < 2) return;
    NSString *b64 = [[parts[1] stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (b64.length % 4) b64 = [b64 stringByAppendingString:@"="];
    NSDictionary *payload = GFDict([GFUtils JSONObjectFromData:[GFUtils base64Decode:b64]]);
    self.userId = GFStr(payload[@"sub"]);
    self.email = GFStr(payload[@"email"]);
    NSString *name = GFStr(payload[@"preferred_username"]);
    if (!name.length && self.email.length) name = [self.email componentsSeparatedByString:@"@"].firstObject;
    self.displayName = name.length ? name : L(@"Player");
}

#pragma mark - Providers

- (NSDictionary *)defaultProvider
{
    return @{ @"code": @"NVIDIA", @"displayName": @"NVIDIA", @"idpId": GFDefaultIdpID, @"streamingServiceUrl": GFDefaultStreamingURL };
}

// pcs.geforcenow.com says which login provider (NVIDIA or an Alliance partner) serves this country
- (void)discoverProvider:(void (^)(NSDictionary *provider))completion
{
    [GFHTTP getJSON:GFServiceURLsURL headers:@{ @"User-Agent": GFLoginUserAgent } completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *info = GFDict(GFDict(json)[@"gfnServiceInfo"]);
        NSArray *endpoints = GFArr(info[@"gfnServiceEndpoints"]);
        if (error || !endpoints.count) { completion([self defaultProvider]); return; }
        NSMutableArray *providers = [NSMutableArray array];
        for (NSDictionary *ep in endpoints) {
            if (!GFDict(ep)) continue;
            NSString *url = GFStr(ep[@"streamingServiceUrl"]);
            if (!url.length || !GFStr(ep[@"idpId"]).length) continue;
            if (![url hasSuffix:@"/"]) url = [url stringByAppendingString:@"/"];
            [providers addObject:@{ @"code": GFStr(ep[@"loginProviderCode"]) ?: @"", @"displayName": GFStr(ep[@"loginProviderDisplayName"]) ?: @"",
                                    @"idpId": GFStr(ep[@"idpId"]), @"streamingServiceUrl": url,
                                    @"priority": @(ep[@"loginProviderPriority"] ? GFInt(ep[@"loginProviderPriority"]) : 100) }];
        }
        if (!providers.count) { completion([self defaultProvider]); return; }
        [providers sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"priority"] compare:b[@"priority"]];
        }];
        NSString *preferred = GFStr([GFArr(info[@"loginPreferredProviders"]) firstObject]) ?: GFStr(info[@"defaultProvider"]);
        NSDictionary *pick = providers.firstObject;
        for (NSDictionary *p in providers) {
            if (preferred.length && ([p[@"displayName"] caseInsensitiveCompare:preferred] == NSOrderedSame || [p[@"code"] caseInsensitiveCompare:preferred] == NSOrderedSame)) {
                pick = p;
                break;
            }
        }
        GFLog(@"Login provider: %@ (%@)", pick[@"displayName"], pick[@"streamingServiceUrl"]);
        completion(pick);
    }];
}

#pragma mark - Device code login

- (NSDictionary *)loginHeaders
{
    return @{ @"Accept": @"application/json, text/plain, */*", @"Origin": @"https://play.geforcenow.com", @"Referer": @"https://play.geforcenow.com/",
              @"User-Agent": GFLoginUserAgent };
}

- (void)startDeviceLogin:(GFDeviceCodeBlock)completion
{
    [self discoverProvider:^(NSDictionary *provider) {
        NSMutableDictionary *headers = [[self loginHeaders] mutableCopy];
        [headers addEntriesFromDictionary:@{
            @"x-device-id": [GFSettings deviceId], @"nv-client-id": GFOAuthClientID, @"nv-client-streamer": @"WEBRTC",
            @"nv-client-type": @"BROWSER", @"nv-client-platform-name": @"browser", @"nv-browser-type": @"CHROME",
            @"nv-device-os": @"STEAMOS", @"nv-device-type": @"CONSOLE", @"nv-device-model": @"STEAMDECK", @"nv-device-make": @"VALVE",
        }];
        NSDictionary *fields = @{ @"client_id": GFOAuthClientID, @"scope": GFOAuthScope, @"device_id": [GFSettings deviceId],
                                  @"display_name": [NSString stringWithFormat:@"GFN6 (%@)", GFIsPad() ? @"iPad" : @"iPhone"],
                                  @"idp_id": provider[@"idpId"] ?: GFDefaultIdpID };
        [GFHTTP postForm:GFDeviceAuthorizeURL headers:headers fields:fields completion:^(id json, NSInteger status, NSError *error) {
            NSDictionary *d = GFDict(json);
            if (error || !GFStr(d[@"device_code"]).length) {
                completion(nil, error ?: GFMakeError(GFErrorBadResponse, L(@"NVIDIA did not issue a sign-in code.")));
                return;
            }
            GFDeviceCode *code = [[GFDeviceCode alloc] init];
            code.deviceCode = GFStr(d[@"device_code"]);
            code.userCode = GFStr(d[@"user_code"]) ?: @"";
            code.verificationURL = GFStr(d[@"verification_uri_complete"]) ?: GFStr(d[@"verification_uri"]) ?: @"https://login.nvidia.com/device";
            code.interval = MAX(1, d[@"interval"] ? GFDbl(d[@"interval"]) : 5);
            code.expires = [NSDate dateWithTimeIntervalSinceNow:d[@"expires_in"] ? GFDbl(d[@"expires_in"]) : 600];
            code.provider = provider;
            GFLog(@"Device code issued: %@ (poll every %.0f s)", code.userCode, code.interval);
            completion(code, nil);
        }];
    }];
}

- (void)pollDeviceLogin:(GFDeviceCode *)code completion:(GFDevicePollBlock)completion
{
    NSDictionary *fields = @{ @"grant_type": @"urn:ietf:params:oauth:grant-type:device_code", @"device_code": code.deviceCode ?: @"",
                              @"client_id": GFOAuthClientID };
    [GFHTTP postForm:GFTokenURL headers:[self loginHeaders] fields:fields completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = GFDict(json);
        if (!error && GFStr(d[@"access_token"]).length) {
            [self adoptTokenResponse:d provider:code.provider];
            [self fetchClientTokenWithCompletion:^{
                GFLog(@"Signed in as %@", self.displayName);
                [self notify];
                completion(YES, NO, nil);
            }];
            return;
        }
        NSString *oauthError = GFStr(d[@"error"]) ?: @"";
        if ([oauthError isEqualToString:@"authorization_pending"]) { completion(NO, YES, nil); return; }
        if ([oauthError isEqualToString:@"slow_down"]) { code.interval += 5; completion(NO, YES, nil); return; }
        if ([oauthError isEqualToString:@"expired_token"]) { completion(NO, NO, GFMakeError(GFErrorTimeout, L(@"The sign-in code expired. Ask for a new one."))); return; }
        if ([oauthError isEqualToString:@"access_denied"]) { completion(NO, NO, GFMakeError(GFErrorAuth, L(@"The sign-in was declined."))); return; }
        if (status == 0 && error) { completion(NO, YES, nil); return; }     // a network hiccup: just poll again
        completion(NO, NO, error ?: GFMakeError(GFErrorBadResponse, oauthError.length ? oauthError : L(@"Unexpected answer from NVIDIA.")));
    }];
}

- (void)adoptTokenResponse:(NSDictionary *)d provider:(NSDictionary *)provider
{
    NSMutableDictionary *t = [self.tokens mutableCopy] ?: [NSMutableDictionary dictionary];
    t[@"access_token"] = GFStr(d[@"access_token"]);
    // NVIDIA routinely leaves id_token (and the refresh token) out of a refresh answer: keep the old ones
    if (GFStr(d[@"refresh_token"]).length) t[@"refresh_token"] = GFStr(d[@"refresh_token"]);
    if (GFStr(d[@"id_token"]).length) t[@"id_token"] = GFStr(d[@"id_token"]);
    double expiresIn = d[@"expires_in"] ? GFDbl(d[@"expires_in"]) : 86400;
    t[@"expires_at"] = @([[NSDate date] timeIntervalSince1970] + expiresIn);
    NSString *clientToken = GFStr(d[@"client_token"]);
    if (clientToken.length) {
        if (![clientToken isEqualToString:t[@"client_token"]]) t[@"client_token_expires_at"] = @0;   // a rotated one needs its own lifetime
        t[@"client_token"] = clientToken;
    }
    if (provider) t[@"provider"] = provider;
    self.tokens = t;
    [self readUserFromTokens];
    [self saveTokens];
}

// The long-lived device credential that outlives the OAuth refresh token (best effort)
- (void)fetchClientTokenWithCompletion:(dispatch_block_t)completion
{
    NSMutableDictionary *headers = [[self loginHeaders] mutableCopy];
    headers[@"Authorization"] = [@"Bearer " stringByAppendingString:GFStr(self.tokens[@"access_token"]) ?: @""];
    [GFHTTP getJSON:GFClientTokenURL headers:headers completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = GFDict(json);
        if (!error && GFStr(d[@"client_token"]).length && self.tokens) {
            self.tokens[@"client_token"] = GFStr(d[@"client_token"]);
            self.tokens[@"client_token_expires_at"] = @([[NSDate date] timeIntervalSince1970] + (d[@"expires_in"] ? GFDbl(d[@"expires_in"]) : 86400 * 30));
            [self saveTokens];
        }
        if (completion) completion();
    }];
}

#pragma mark - Refresh

- (BOOL)needsRefresh
{
    double at = GFDbl(self.tokens[@"expires_at"]);
    return at == 0 || at - [[NSDate date] timeIntervalSince1970] < GFRefreshWindow;
}

- (void)ensureFreshTokens:(void (^)(NSError *error))completion
{
    if (!self.isSignedIn) { if (completion) completion(GFMakeError(GFErrorAuth, L(@"Sign in first."))); return; }
    if (![self needsRefresh]) { if (completion) completion(nil); return; }
    if (completion) [self.refreshWaiters addObject:[completion copy]];
    if (self.refreshing) return;
    self.refreshing = YES;
    NSString *clientToken = GFStr(self.tokens[@"client_token"]);
    if (clientToken.length && self.userId.length) {
        [self postTokenForm:@{ @"grant_type": @"urn:ietf:params:oauth:grant-type:client_token", @"client_token": clientToken,
                               @"client_id": GFOAuthClientID, @"sub": self.userId } attempt:1 completion:^(NSDictionary *d, BOOL dead, NSError *error) {
            if (d) { [self finishRefresh:d error:nil]; return; }
            GFLog(@"Client-token refresh failed (%@), trying the refresh token", error.localizedDescription);
            [self refreshWithRefreshToken];
        }];
    } else {
        [self refreshWithRefreshToken];
    }
}

- (void)refreshWithRefreshToken
{
    NSString *refreshToken = GFStr(self.tokens[@"refresh_token"]);
    if (!refreshToken.length) {
        [self finishRefresh:nil error:GFMakeError(GFErrorAuth, L(@"The saved sign-in cannot be renewed. Sign in again."))];
        return;
    }
    [self postTokenForm:@{ @"grant_type": @"refresh_token", @"refresh_token": refreshToken, @"client_id": GFOAuthClientID } attempt:1
             completion:^(NSDictionary *d, BOOL dead, NSError *error) {
        if (d) { [self finishRefresh:d error:nil]; return; }
        if (dead) {
            [self finishRefresh:nil error:GFMakeError(GFErrorAuth, L(@"The saved sign-in is no longer valid. Sign in again."))];
        } else {
            // something transient: keep the saved login, the next request may still work (or come back 401)
            [self finishRefresh:nil error:error];
        }
    }];
}

// dead = NVIDIA says the credential is finished (400/401); otherwise a transient failure (retried up to 3 times)
- (void)postTokenForm:(NSDictionary *)fields attempt:(NSInteger)attempt completion:(void (^)(NSDictionary *d, BOOL dead, NSError *error))completion
{
    [GFHTTP postForm:GFTokenURL headers:[self loginHeaders] fields:fields completion:^(id json, NSInteger status, NSError *error) {
        NSDictionary *d = GFDict(json);
        if (!error && GFStr(d[@"access_token"]).length) { completion(d, NO, nil); return; }
        if (status == 400 || status == 401) { completion(nil, YES, error); return; }
        BOOL temporary = status == 0 || status == 408 || status == 429 || status >= 500;
        if (temporary && attempt < 3) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((attempt == 1 ? 0.5 : 1.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self postTokenForm:fields attempt:attempt + 1 completion:completion];
            });
            return;
        }
        completion(nil, NO, error ?: GFMakeError(GFErrorBadResponse, L(@"Unexpected answer from NVIDIA.")));
    }];
}

- (void)finishRefresh:(NSDictionary *)response error:(NSError *)error
{
    self.refreshing = NO;
    if (response) {
        [self adoptTokenResponse:response provider:nil];
        GFLog(@"Tokens refreshed");
        double clientAt = GFDbl(self.tokens[@"client_token_expires_at"]);
        if (!GFStr(self.tokens[@"client_token"]).length || clientAt - [[NSDate date] timeIntervalSince1970] < GFRefreshWindow) {
            [self fetchClientTokenWithCompletion:nil];
        }
    } else if (error.code == GFErrorAuth) {
        [self signOut];
    }
    NSArray *waiters = [self.refreshWaiters copy];
    [self.refreshWaiters removeAllObjects];
    for (void (^block)(NSError *) in waiters) block(error);
}

#pragma mark - Membership

- (void)fetchMembershipTierWithVpcId:(NSString *)vpcId completion:(void (^)(NSString *tier))completion
{
    if (!self.isSignedIn || !self.userId.length) { if (completion) completion(nil); return; }
    NSString *url = [NSString stringWithFormat:@"https://mes.geforcenow.com/v4/subscriptions?serviceName=gfn_pc&languageCode=en_US&vpcId=%@&userId=%@",
                     [GFUtils urlEncode:vpcId ?: @"GFN-PC"], [GFUtils urlEncode:self.userId]];
    NSDictionary *headers = @{ @"Authorization": [@"GFNJWT " stringByAppendingString:[self bearerToken] ?: @""], @"Accept": @"application/json",
                               @"Content-Type": @"application/json",
                               @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Safari/537.36" };
    [GFHTTP getJSON:url headers:headers completion:^(id json, NSInteger status, NSError *error) {
        NSString *tier = nil;
        NSMutableArray *candidates = [NSMutableArray array];
        if (GFDict(json)) {
            [candidates addObject:json];
            [candidates addObjectsFromArray:GFArr(GFDict(json)[@"subscriptions"]) ?: @[]];
        } else if (GFArr(json)) {
            [candidates addObjectsFromArray:json];
        }
        for (id c in candidates) {
            NSString *t = GFStr(GFDict(c)[@"membershipTier"]);
            if (t.length) { tier = t; break; }
        }
        if (tier) {
            self.membershipTier = tier;
            GFLog(@"Membership tier: %@", tier);
        } else if (error) {
            GFLog(@"Subscription lookup failed: %@", error.localizedDescription);
        }
        if (completion) completion(tier);
    }];
}

- (NSTimeInterval)maxSessionSeconds
{
    NSString *t = [self.membershipTier uppercaseString] ?: @"";
    if ([t rangeOfString:@"ULTIMATE"].location != NSNotFound || [t rangeOfString:@"RTX"].location != NSNotFound) return 8 * 3600;
    for (NSString *word in @[ @"PRIORITY", @"PREMIUM", @"PERFORMANCE", @"FOUNDER", @"STANDARD", @"PASS" ]) {
        if ([t rangeOfString:word].location != NSNotFound) return 6 * 3600;
    }
    return 3600;
}

@end
