#import <Foundation/Foundation.h>
#import "GFModels.h"

@class GFHTTPTask;

typedef void (^GFCatalogPageBlock)(GFCatalogPage *page, NSError *error);

// The GeForce NOW services around a session: CloudMatch's serverInfo (VPC id, streaming zones) and the games
// GraphQL catalog. Completions run on the main thread.
@interface GFAPI : NSObject

// Header sets the services expect (the client pretends to be the Windows desktop client, like every open client)
+ (NSDictionary *)lcarsHeadersWithStreamer:(NSString *)streamer;                    // serverInfo (needs a bearer token)
+ (NSDictionary *)cloudMatchHeadersWithClientId:(NSString *)clientId deviceId:(NSString *)deviceId;
+ (NSDictionary *)graphqlHeaders;
+ (NSString *)desktopUserAgent;

// requestStatus.serverId of GET v2/serverInfo - the "VPC id" catalog and session calls want. Cached per process;
// GFN-PC when the lookup fails for a reason other than authorization.
+ (void)resolveVpcId:(void (^)(NSString *vpcId, NSError *error))completion;
+ (void)forgetVpcId;

// The streaming zones the provider advertises (serverInfo metaData), unmeasured
+ (void)fetchRegions:(void (^)(NSArray *regions, NSError *error))completion;
// TCP connect times to the zones, in the background; the array is the same objects with pingMs filled in
+ (void)measureRegions:(NSArray *)regions completion:(void (^)(NSArray *regions))completion;

// One page (up to 200 titles) of the catalog. query = nil for browsing; ownedOnly limits it to the account's
// library. sort: "relevance", "title", "last_played" (the last one is applied locally by the caller).
+ (GFHTTPTask *)fetchCatalogPageWithQuery:(NSString *)query cursor:(NSString *)cursor ownedOnly:(BOOL)ownedOnly
                                     sort:(NSString *)sort completion:(GFCatalogPageBlock)completion;

@end
