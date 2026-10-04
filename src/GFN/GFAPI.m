#import "GFAPI.h"
#import "GFAuth.h"
#import "GFHTTP.h"
#import "GFSettings.h"
#import "GFUtils.h"
#import "GFCommon.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <unistd.h>

static NSString * const GFClientID = @"ec7e38d4-03af-4b58-b131-cfb0495903ab";
static NSString * const GFClientVersion = @"2.0.80.173";
static NSString * const GFGraphQLURL = @"https://games.geforce.com/graphql";
static NSString * const GFPlayOrigin = @"https://play.geforcenow.com";
static NSString *g_vpcId;

@implementation GFAPI

+ (NSString *)desktopUserAgent
{
    return @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36 NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173";
}

+ (NSString *)authorization
{
    return [@"GFNJWT " stringByAppendingString:[[GFAuth shared] bearerToken] ?: @""];
}

+ (NSDictionary *)lcarsHeadersWithStreamer:(NSString *)streamer
{
    return @{ @"Accept": @"application/json", @"Authorization": [self authorization], @"nv-client-id": GFClientID, @"nv-client-type": @"BROWSER",
              @"nv-client-version": GFClientVersion, @"nv-client-streamer": streamer ?: @"WEBRTC", @"nv-device-os": @"WINDOWS",
              @"nv-device-type": @"DESKTOP", @"User-Agent": [self desktopUserAgent] };
}

+ (NSDictionary *)cloudMatchHeadersWithClientId:(NSString *)clientId deviceId:(NSString *)deviceId
{
    return @{ @"Accept": @"application/json", @"Content-Type": @"application/json", @"Authorization": [self authorization],
              @"Origin": GFPlayOrigin, @"Referer": @"https://play.geforcenow.com/", @"nv-browser-type": @"CHROME",
              @"nv-client-id": clientId ?: GFClientID, @"nv-client-streamer": @"NVIDIA-CLASSIC", @"nv-client-type": @"NATIVE",
              @"nv-client-version": GFClientVersion, @"nv-device-make": @"UNKNOWN", @"nv-device-model": @"UNKNOWN",
              @"nv-device-os": @"WINDOWS", @"nv-device-type": @"DESKTOP", @"x-device-id": deviceId ?: [GFSettings deviceId],
              @"User-Agent": [self desktopUserAgent] };
}

+ (NSDictionary *)graphqlHeaders
{
    return @{ @"Accept": @"application/json, text/plain, */*", @"Content-Type": @"application/json", @"Origin": GFPlayOrigin,
              @"Referer": @"https://play.geforcenow.com/", @"Authorization": [self authorization], @"nv-client-id": GFClientID,
              @"nv-client-type": @"NATIVE", @"nv-client-version": GFClientVersion, @"nv-client-streamer": @"NVIDIA-CLASSIC",
              @"nv-device-os": @"WINDOWS", @"nv-device-type": @"DESKTOP", @"nv-device-make": @"UNKNOWN", @"nv-device-model": @"UNKNOWN",
              @"nv-browser-type": @"CHROME", @"User-Agent": [self desktopUserAgent] };
}

#pragma mark - serverInfo

+ (void)fetchServerInfo:(void (^)(NSDictionary *json, NSError *error))completion
{
    [[GFAuth shared] ensureFreshTokens:^(NSError *error) {
        if (error && error.code == GFErrorAuth) { completion(nil, error); return; }
        NSString *url = [[[GFAuth shared] streamingBaseURL] stringByAppendingString:@"v2/serverInfo"];
        [GFHTTP getJSON:url headers:[self lcarsHeadersWithStreamer:@"WEBRTC"] completion:^(id json, NSInteger status, NSError *error2) {
            if (status == 401 || status == 403) {
                completion(nil, GFMakeError(GFErrorAuth, L(@"The sign-in is no longer valid. Sign in again.")));
                return;
            }
            completion(GFDict(json), error2);
        }];
    }];
}

+ (void)resolveVpcId:(void (^)(NSString *vpcId, NSError *error))completion
{
    if (g_vpcId.length) { completion(g_vpcId, nil); return; }
    [self fetchServerInfo:^(NSDictionary *json, NSError *error) {
        NSString *id = GFStr(GFDict(json[@"requestStatus"])[@"serverId"]);
        if (id.length) {
            g_vpcId = id;
            GFLog(@"VPC id: %@", id);
            completion(id, nil);
            return;
        }
        if (error.code == GFErrorAuth) { completion(nil, error); return; }
        // The wrong VPC id makes the catalog answer with a degenerate list, but it is better than nothing offline
        GFLog(@"serverInfo failed (%@), using GFN-PC", error.localizedDescription);
        completion(@"GFN-PC", nil);
    }];
}

+ (void)forgetVpcId
{
    g_vpcId = nil;
}

+ (void)fetchRegions:(void (^)(NSArray *regions, NSError *error))completion
{
    [self fetchServerInfo:^(NSDictionary *json, NSError *error) {
        if (!json) { completion(nil, error); return; }
        NSMutableArray *regions = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *entry in GFArr(json[@"metaData"])) {
            NSString *name = [GFStr(GFDict(entry)[@"key"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *value = [GFStr(GFDict(entry)[@"value"]) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (!name.length || [name hasPrefix:@"gfn-"] || ![value hasPrefix:@"https://"]) continue;
            NSString *authority = [[value substringFromIndex:8] componentsSeparatedByString:@"/"].firstObject;
            if (!authority.length || [authority rangeOfString:@"@"].location != NSNotFound) continue;
            if (![value hasSuffix:@"/"]) value = [value stringByAppendingString:@"/"];
            if ([seen containsObject:value]) continue;
            [seen addObject:value];
            GFRegion *r = [[GFRegion alloc] init];
            r.name = name;
            r.url = value;
            [regions addObject:r];
        }
        [regions sortUsingComparator:^NSComparisonResult(GFRegion *a, GFRegion *b) { return [a.name compare:b.name]; }];
        GFLog(@"serverInfo advertised %lu zones", (unsigned long)regions.count);
        completion(regions, nil);
    }];
}

// One TCP connect to host:443, milliseconds, or -1 (3 s limit)
static NSInteger GFConnectMillis(NSString *host, int port)
{
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char service[16];
    snprintf(service, sizeof(service), "%d", port);
    if (getaddrinfo([host UTF8String], service, &hints, &res) != 0 || !res) return -1;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); return -1; }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    uint64_t start = GFMonotonicMicros();
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    NSInteger ms = -1;
    if (rc == 0) {
        ms = 0;
    } else if (errno == EINPROGRESS) {
        struct pollfd p = { fd, POLLOUT, 0 };
        if (poll(&p, 1, 3000) == 1) {
            int err = 0;
            socklen_t len = sizeof(err);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) ms = (NSInteger)((GFMonotonicMicros() - start) / 1000);
        }
    }
    close(fd);
    freeaddrinfo(res);
    return ms;
}

+ (void)measureRegions:(NSArray *)regions completion:(void (^)(NSArray *regions))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t parallel = dispatch_semaphore_create(4);
        for (GFRegion *r in regions) {
            dispatch_semaphore_wait(parallel, DISPATCH_TIME_FOREVER);
            dispatch_group_async(group, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *authority = [[r.url substringFromIndex:8] componentsSeparatedByString:@"/"].firstObject;
                NSArray *hp = [authority componentsSeparatedByString:@":"];
                NSString *host = hp.firstObject;
                int port = hp.count > 1 ? [hp[1] intValue] : 443;
                GFConnectMillis(host, port);                     // warms the DNS cache and the route
                NSInteger total = 0, answered = 0;
                for (int i = 0; i < 3; i++) {
                    NSInteger ms = GFConnectMillis(host, port);
                    if (ms >= 0) { total += ms; answered++; }
                    usleep(100 * 1000);
                }
                r.pingMs = answered ? (total + answered / 2) / answered : 0;
                dispatch_semaphore_signal(parallel);
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(regions); });
    });
}

#pragma mark - Catalog

static NSString * const GFCatalogFields =
    @"items { id title publisherName genres "
    @"variants { id appStore gfn { status library { status lastPlayedDate } } } "
    @"images { GAME_BOX_ART KEY_IMAGE KEY_ART HERO_IMAGE } "
    @"gfn { playType playabilityState } } "
    @"pageInfo { hasNextPage endCursor totalCount }";

+ (GFHTTPTask *)fetchCatalogPageWithQuery:(NSString *)query cursor:(NSString *)cursor ownedOnly:(BOOL)ownedOnly
                                     sort:(NSString *)sort completion:(GFCatalogPageBlock)completion
{
    GFHTTPTask *outer = [[GFHTTPTask alloc] init];
    [self resolveVpcId:^(NSString *vpcId, NSError *error) {
        if (outer.isCancelled) return;
        if (!vpcId) { completion(nil, error); return; }
        BOOL searching = query.length > 0;
        NSString *document = searching
            ? [NSString stringWithFormat:@"query GetCatalogSearchApps($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $searchString: String!, $filters: AppFilterFields!) "
               @"{ apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, searchQuery: $searchString, filters: $filters) { %@ } }", GFCatalogFields]
            : [NSString stringWithFormat:@"query GetCatalogApps($vpcId: String!, $locale: String!, $sortString: String!, $fetchCount: Int!, $cursor: String!, $filters: AppFilterFields!) "
               @"{ apps(vpcId: $vpcId, language: $locale, orderBy: $sortString, first: $fetchCount, after: $cursor, filters: $filters) { %@ } }", GFCatalogFields];
        NSString *sortString = [sort isEqualToString:@"title"] ? @"sortName:ASC" : @"itemMetadata.relevance:DESC,sortName:ASC";
        NSDictionary *filters = ownedOnly ? @{ @"variants": @{ @"gfn": @{ @"library": @{ @"status": @{ @"notEquals": @"NOT_OWNED" } } } } } : @{};
        NSMutableDictionary *variables = [@{ @"vpcId": vpcId, @"locale": @"en_US", @"sortString": sortString, @"fetchCount": @200,
                                             @"cursor": cursor ?: @"", @"filters": filters } mutableCopy];
        if (searching) variables[@"searchString"] = query;
        GFHTTPTask *inner = [GFHTTP postJSON:GFGraphQLURL headers:[self graphqlHeaders] object:@{ @"query": document, @"variables": variables } retries:1
                                  completion:^(id json, NSInteger status, NSError *error2) {
            if (outer.isCancelled) return;
            NSDictionary *d = GFDict(json);
            NSArray *errors = GFArr(d[@"errors"]);
            if (status == 401 || status == 403) {
                [self forgetVpcId];
                completion(nil, GFMakeError(GFErrorAuth, L(@"The sign-in is no longer valid. Sign in again.")));
                return;
            }
            if (error2 && !GFDict(d[@"data"])) { completion(nil, error2); return; }
            if (errors.count && !GFDict(d[@"data"])) {
                completion(nil, GFMakeError(GFErrorAPI, GFStr(GFDict(errors.firstObject)[@"message"]) ?: L(@"The catalog request failed.")));
                return;
            }
            NSDictionary *apps = GFDict(GFDict(d[@"data"])[@"apps"]);
            GFCatalogPage *page = [[GFCatalogPage alloc] init];
            NSMutableArray *games = [NSMutableArray array];
            for (NSDictionary *item in GFArr(apps[@"items"])) {
                GFGame *g = [GFGame gameFromCatalogItem:GFDict(item)];
                if (g && g.appId.length) [games addObject:g];
            }
            page.games = games;
            NSDictionary *pageInfo = GFDict(apps[@"pageInfo"]);
            NSString *end = GFStr(pageInfo[@"endCursor"]);
            page.nextCursor = (GFBool(pageInfo[@"hasNextPage"]) && end.length) ? end : nil;
            page.totalCount = GFInt(pageInfo[@"totalCount"]);
            completion(page, nil);
        }];
        outer.cancelBlock = ^{ [inner cancel]; };
    }];
    return outer;
}

@end
