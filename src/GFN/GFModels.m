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
    g.title = GFStr([item objectForKey:@"title"]) ?: @"";
    g.searchKey = [g.title lowercaseString];
    g.publisher = GFStr([item objectForKey:@"publisherName"]);
    NSArray *genres = GFArr([item objectForKey:@"genres"]);
    if (genres.count) {
        NSMutableArray *names = [NSMutableArray array];
        for (id x in genres) { NSString *s = GFStr(x); if (s) [names addObject:s]; }
        g.genres = [names componentsJoinedByString:@", "];
    }
    NSDictionary *images = GFDict([item objectForKey:@"images"]);
    g.coverURL = GFOptimizedImage(GFFirstImage([images objectForKey:@"GAME_BOX_ART"]) ?: GFFirstImage([images objectForKey:@"KEY_IMAGE"]) ?: GFFirstImage([images objectForKey:@"KEY_ART"]), 256);
    g.heroURL = GFOptimizedImage(GFFirstImage([images objectForKey:@"HERO_IMAGE"]) ?: GFFirstImage([images objectForKey:@"KEY_ART"]) ?: GFFirstImage([images objectForKey:@"GAME_BOX_ART"]), 640);

    NSArray *variants = GFArr([item objectForKey:@"variants"]);
    NSDictionary *chosen = nil;
    for (NSDictionary *v in variants) {
        if (!GFDict(v)) continue;
        if (GFIsNumeric(GFStr([v objectForKey:@"id"]))) { chosen = v; break; }
    }
    if (!chosen) chosen = GFDict(variants.firstObject);
    NSString *itemId = GFStr([item objectForKey:@"id"]);
    g.variantId = GFStr([chosen objectForKey:@"id"]);
    g.appId = GFIsNumeric(g.variantId) ? g.variantId : (GFIsNumeric(itemId) ? itemId : (g.variantId ?: itemId));
    g.store = GFStr([chosen objectForKey:@"appStore"]);
    NSDictionary *gfn = GFDict([chosen objectForKey:@"gfn"]);
    g.status = GFStr([gfn objectForKey:@"status"]);
    NSDictionary *library = GFDict([gfn objectForKey:@"library"]);
    g.libraryStatus = GFStr([library objectForKey:@"status"]);
    g.lastPlayed = GFDateFromISO(GFStr([library objectForKey:@"lastPlayedDate"]));
    for (NSDictionary *v in variants) {
        NSDictionary *lib = GFDict([GFDict([v objectForKey:@"gfn"]) objectForKey:@"library"]);
        NSString *st = GFStr([lib objectForKey:@"status"]);
        if (st.length && ![st isEqualToString:@"NOT_OWNED"]) g.owned = YES;
        if (!g.lastPlayed) g.lastPlayed = GFDateFromISO(GFStr([lib objectForKey:@"lastPlayedDate"]));
    }
    NSDictionary *appGfn = GFDict([item objectForKey:@"gfn"]);
    NSString *playType = [GFStr([appGfn objectForKey:@"playType"]) uppercaseString] ?: @"";
    g.freeToPlay = [playType rangeOfString:@"FREE"].location != NSNotFound;
    if (!g.status.length) g.status = GFStr([appGfn objectForKey:@"playabilityState"]);
    g.favorite = GFBool([GFDict([item objectForKey:@"library"]) objectForKey:@"favorited"]);
    return g;
}

- (NSString *)storeDisplayName
{
    NSString *s = [self.store uppercaseString] ?: @"";
    NSDictionary *names = @{ @"STEAM": @"Steam", @"EPIC": @"Epic Games", @"UBISOFT": @"Ubisoft Connect", @"EA_APP": @"EA app",
                             @"ORIGIN": @"EA app", @"GOG": @"GOG", @"XBOX": @"Xbox", @"BATTLENET": @"Battle.net", @"NONE": @"" };
    return [names objectForKey:s] ?: [s capitalizedString];
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
