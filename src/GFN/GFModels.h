#import <Foundation/Foundation.h>

// A title of the GeForce NOW catalog (one row of the GraphQL `apps` query)
@interface GFGame : NSObject
@property (nonatomic, copy) NSString *appId;        // numeric id CloudMatch wants
@property (nonatomic, copy) NSString *variantId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *coverURL;     // portrait box art (JPEG, resized by the CDN)
@property (nonatomic, copy) NSString *heroURL;      // wide key art
@property (nonatomic, copy) NSString *store;        // "STEAM", "EPIC", "UBISOFT", "EA_APP", "GOG", "XBOX"...
@property (nonatomic, copy) NSString *publisher;
@property (nonatomic, copy) NSString *genres;       // "Action, RPG"
@property (nonatomic, copy) NSString *status;       // gfn status: "AVAILABLE", "MAINTENANCE", "PATCHING"...
@property (nonatomic, copy) NSString *libraryStatus;// "OWNED" / "NOT_OWNED" / "MANUAL" / "PLATFORM_SYNC"...
@property (nonatomic, strong) NSDate *lastPlayed;
@property (nonatomic) BOOL owned;
@property (nonatomic) BOOL freeToPlay;
@property (nonatomic) BOOL favorite;
@property (nonatomic, copy) NSString *searchKey;    // lowercase title
+ (instancetype)gameFromCatalogItem:(NSDictionary *)item;
- (NSString *)storeDisplayName;
@end

// One page of the catalog
@interface GFCatalogPage : NSObject
@property (nonatomic, strong) NSArray *games;
@property (nonatomic, copy) NSString *nextCursor;   // nil on the last page
@property (nonatomic) NSInteger totalCount;
@end

// A streaming zone of CloudMatch (serverInfo metaData)
@interface GFRegion : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;          // https base URL, trailing slash
@property (nonatomic) NSInteger pingMs;             // -1 = not measured, 0 = unreachable
@end

// What CloudMatch told us about a session, as much as the streaming stack needs
@interface GFSession : NSObject
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *appId;
@property (nonatomic) NSInteger status;             // 0 queued, 1 setting up, 2 ready, 3 streaming, 4 finished...
@property (nonatomic, copy) NSString *serverIp;     // the seat host (IPv4 or an Alliance host name)
@property (nonatomic, copy) NSString *signalingURL; // wss://host/nvst/
@property (nonatomic, copy) NSString *streamingBaseURL; // the zone this session lives on
@property (nonatomic, copy) NSString *clientId;     // per-launch UUID sent as nv-client-id
@property (nonatomic, copy) NSString *deviceId;
@property (nonatomic, copy) NSString *mediaIp;      // connectionInfo usage 2/17: the ICE host candidate
@property (nonatomic) NSInteger mediaPort;
@property (nonatomic, strong) NSArray *iceServers;  // dictionaries {urls, username, credential}
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) NSInteger fps;
@property (nonatomic) NSInteger queuePosition;
@property (nonatomic) NSInteger etaSeconds;
@property (nonatomic) NSInteger setupStep;
@end
