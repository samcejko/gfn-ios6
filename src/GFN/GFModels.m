#import "GFModels.h"
#import "GFCommon.h"

static NSString *GFFirstImage(id value)
{
    if ([value isKindOfClass:[NSString class]]) return [value length] ? value : nil;
    if ([value isKindOfClass:[NSArray class]]) {
        for (id v in value) if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    }
    return nil;
}

// img.nvidiagrid.net resizes and transcodes on the fly through a URL suffix (JPEG: iOS 6 cannot decode WebP)
static NSString *GFOptimizedImage(NSString *url, NSInteger width)
{
    if (!url.length) return nil;
    if ([url rangeOfString:@"img.nvidiagrid.net"].location != NSNotFound) {
        return [NSString stringWithFormat:@"%@;f=jpeg;w=%ld", url, (long)width];
    }
    return url;
}

static BOOL GFIsNumeric(NSString *s)
{
    if (!s.length) return NO;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

@implementation GFGame

+ (instancetype)gameFromCatalogItem:(NSDictionary *)item
{
    if (!item) return nil;
    GFGame *g = [[GFGame alloc] init];
    g.title = GFStr(item[@"title"]) ?: @"";
    g.searchKey = [g.title lowercaseString];
    g.publisher = GFStr(item[@"publisherName"]);
    NSArray *genres = GFArr(item[@"genres"]);
    if (genres.count) {
        NSMutableArray *names = [NSMutableArray array];
        for (id x in genres) { NSString *s = GFStr(x); if (s) [names addObject:s]; }
        g.genres = [names componentsJoinedByString:@", "];
    }
    NSDictionary *images = GFDict(item[@"images"]);
    g.coverURL = GFOptimizedImage(GFFirstImage(images[@"GAME_BOX_ART"]) ?: GFFirstImage(images[@"KEY_IMAGE"]) ?: GFFirstImage(images[@"KEY_ART"]), 256);
    g.heroURL = GFOptimizedImage(GFFirstImage(images[@"HERO_IMAGE"]) ?: GFFirstImage(images[@"KEY_ART"]) ?: GFFirstImage(images[@"GAME_BOX_ART"]), 640);

    NSArray *variants = GFArr(item[@"variants"]);
    NSDictionary *chosen = nil;
    for (NSDictionary *v in variants) {
        if (!GFDict(v)) continue;
        if (GFIsNumeric(GFStr(v[@"id"]))) { chosen = v; break; }
    }
    if (!chosen) chosen = GFDict(variants.firstObject);
    NSString *itemId = GFStr(item[@"id"]);
    g.variantId = GFStr(chosen[@"id"]);
    g.appId = GFIsNumeric(g.variantId) ? g.variantId : (GFIsNumeric(itemId) ? itemId : (g.variantId ?: itemId));
    g.store = GFStr(chosen[@"appStore"]);
    NSDictionary *gfn = GFDict(chosen[@"gfn"]);
    g.status = GFStr(gfn[@"status"]);
    NSDictionary *library = GFDict(gfn[@"library"]);
    g.libraryStatus = GFStr(library[@"status"]);
    g.lastPlayed = GFDateFromISO(GFStr(library[@"lastPlayedDate"]));
    for (NSDictionary *v in variants) {
        NSDictionary *lib = GFDict(GFDict(v[@"gfn"])[@"library"]);
        NSString *st = GFStr(lib[@"status"]);
        if (st.length && ![st isEqualToString:@"NOT_OWNED"]) g.owned = YES;
        if (!g.lastPlayed) g.lastPlayed = GFDateFromISO(GFStr(lib[@"lastPlayedDate"]));
    }
    NSDictionary *appGfn = GFDict(item[@"gfn"]);
    NSString *playType = [GFStr(appGfn[@"playType"]) uppercaseString] ?: @"";
    g.freeToPlay = [playType rangeOfString:@"FREE"].location != NSNotFound;
    if (!g.status.length) g.status = GFStr(appGfn[@"playabilityState"]);
    g.favorite = GFBool(GFDict(item[@"library"])[@"favorited"]);
    return g;
}

- (NSString *)storeDisplayName
{
    NSString *s = [self.store uppercaseString] ?: @"";
    NSDictionary *names = @{ @"STEAM": @"Steam", @"EPIC": @"Epic Games", @"UBISOFT": @"Ubisoft Connect", @"EA_APP": @"EA app",
                             @"ORIGIN": @"EA app", @"GOG": @"GOG", @"XBOX": @"Xbox", @"BATTLENET": @"Battle.net", @"NONE": @"" };
    return names[s] ?: [s capitalizedString];
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<GFGame %@ '%@' %@%@>", self.appId, self.title, self.store ?: @"", self.owned ? @" owned" : @""];
}

@end

@implementation GFCatalogPage
@end

@implementation GFRegion
- (instancetype)init { if ((self = [super init])) _pingMs = -1; return self; }
@end

@implementation GFSession
- (NSString *)description
{
    return [NSString stringWithFormat:@"<GFSession %@ status %ld server %@ signaling %@ media %@:%ld %ldx%ld@%ld>", self.sessionId,
            (long)self.status, self.serverIp, self.signalingURL, self.mediaIp, (long)self.mediaPort, (long)self.width, (long)self.height, (long)self.fps];
}
@end
