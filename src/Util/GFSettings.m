#import "GFSettings.h"
#import "GFCommon.h"
#import <UIKit/UIKit.h>
#import <Security/Security.h>

#define DEF [NSUserDefaults standardUserDefaults]

@implementation GFSettings

+ (NSString *)deviceLanguageCode
{
    NSString *code = [[[NSLocale preferredLanguages] firstObject] componentsSeparatedByString:@"-"].firstObject;
    NSDictionary *map = @{ @"cs": @"cs_CZ", @"en": @"en_US", @"de": @"de_DE", @"fr": @"fr_FR", @"es": @"es_ES", @"it": @"it_IT",
                           @"pl": @"pl_PL", @"ru": @"ru_RU", @"pt": @"pt_BR", @"nl": @"nl_NL", @"hu": @"hu_HU", @"sv": @"sv_SE",
                           @"da": @"da_DK", @"fi": @"fi_FI", @"nb": @"nb_NO", @"tr": @"tr_TR", @"ja": @"ja_JP", @"ko": @"ko_KR",
                           @"uk": @"uk_UA", @"th": @"th_TH" };
    return map[code ?: @""] ?: @"en_US";
}

+ (void)registerDefaults
{
    [DEF registerDefaults:@{
        @"darkTheme": @YES,
        @"streamResolution": @"native",
        @"streamFps": @30,          // the iPad 2 (A5) decoder holds 30 fps comfortably; 60 fps overruns it and stutters
        @"maxBitrateMbps": @10,
        @"region": @"",
        @"regionName": @"",
        @"gameLanguage": [self deviceLanguageCode],
        @"showStats": @NO,
        @"touchGamepad": @YES,
        @"gamepadOpacity": @0.45,
        @"mouseSensitivity": @1.5,
        @"libraryFilter": @"my_games",
        @"librarySort": @"last_played",
        @"verifyTLS": @YES,
    }];
}

+ (void)save
{
    [DEF synchronize];
}

+ (void)notify
{
    GFMain(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:GFSettingsDidChangeNotification object:nil];
    });
}

#pragma mark - Appearance

+ (BOOL)darkTheme { return [DEF boolForKey:@"darkTheme"]; }
+ (void)setDarkTheme:(BOOL)value { [DEF setBool:value forKey:@"darkTheme"]; }

#pragma mark - Stream

+ (NSString *)streamResolution { return [DEF stringForKey:@"streamResolution"] ?: @"native"; }
+ (void)setStreamResolution:(NSString *)value { [DEF setObject:value ?: @"native" forKey:@"streamResolution"]; [self notify]; }

+ (CGSize)streamSize
{
    NSString *r = [self streamResolution];
    if (![r isEqualToString:@"native"]) {
        NSArray *parts = [r componentsSeparatedByString:@"x"];
        if (parts.count == 2) {
            CGSize s = CGSizeMake([parts[0] integerValue], [parts[1] integerValue]);
            if (s.width >= 320 && s.height >= 240) return s;
        }
    }
    // the screen in landscape pixels, both sides even (H.264 wants it)
    CGRect b = [UIScreen mainScreen].bounds;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGFloat w = MAX(b.size.width, b.size.height) * scale;
    CGFloat h = MIN(b.size.width, b.size.height) * scale;
    // retina iPads: 2048x1536 is far beyond a 2012 decoder, stream at the point size instead
    if (w > 1280) { w /= scale; h /= scale; }
    return CGSizeMake(floor(w / 2) * 2, floor(h / 2) * 2);
}

+ (NSInteger)streamFps { NSInteger v = [DEF integerForKey:@"streamFps"]; return v == 30 ? 30 : 60; }
+ (void)setStreamFps:(NSInteger)value { [DEF setInteger:value forKey:@"streamFps"]; [self notify]; }

+ (NSInteger)maxBitrateMbps { NSInteger v = [DEF integerForKey:@"maxBitrateMbps"]; return MIN(30, MAX(3, v ?: 10)); }
+ (void)setMaxBitrateMbps:(NSInteger)value { [DEF setInteger:value forKey:@"maxBitrateMbps"]; [self notify]; }

+ (NSString *)region { return [DEF stringForKey:@"region"] ?: @""; }
+ (void)setRegion:(NSString *)value { [DEF setObject:value ?: @"" forKey:@"region"]; [self notify]; }
+ (NSString *)regionName { return [DEF stringForKey:@"regionName"] ?: @""; }
+ (void)setRegionName:(NSString *)value { [DEF setObject:value ?: @"" forKey:@"regionName"]; }

+ (NSString *)gameLanguage { return [DEF stringForKey:@"gameLanguage"] ?: @"en_US"; }
+ (void)setGameLanguage:(NSString *)value { [DEF setObject:value ?: @"en_US" forKey:@"gameLanguage"]; [self notify]; }

+ (BOOL)showStats { return [DEF boolForKey:@"showStats"]; }
+ (void)setShowStats:(BOOL)value { [DEF setBool:value forKey:@"showStats"]; [self notify]; }

#pragma mark - Controls

+ (BOOL)touchGamepad { return [DEF boolForKey:@"touchGamepad"]; }
+ (void)setTouchGamepad:(BOOL)value { [DEF setBool:value forKey:@"touchGamepad"]; [self notify]; }

+ (CGFloat)gamepadOpacity { double v = [DEF doubleForKey:@"gamepadOpacity"]; return (CGFloat)MIN(0.9, MAX(0.2, v ?: 0.45)); }
+ (void)setGamepadOpacity:(CGFloat)value { [DEF setDouble:value forKey:@"gamepadOpacity"]; [self notify]; }

+ (CGFloat)mouseSensitivity { double v = [DEF doubleForKey:@"mouseSensitivity"]; return (CGFloat)MIN(3.0, MAX(0.5, v ?: 1.5)); }
+ (void)setMouseSensitivity:(CGFloat)value { [DEF setDouble:value forKey:@"mouseSensitivity"]; [self notify]; }

#pragma mark - Library

+ (NSString *)libraryFilter { return [DEF stringForKey:@"libraryFilter"] ?: @"my_games"; }
+ (void)setLibraryFilter:(NSString *)value { [DEF setObject:value ?: @"my_games" forKey:@"libraryFilter"]; [self notify]; }

+ (NSString *)librarySort { return [DEF stringForKey:@"librarySort"] ?: @"last_played"; }
+ (void)setLibrarySort:(NSString *)value { [DEF setObject:value ?: @"last_played" forKey:@"librarySort"]; [self notify]; }

#pragma mark - Network

+ (BOOL)verifyTLS { return [DEF boolForKey:@"verifyTLS"]; }
+ (void)setVerifyTLS:(BOOL)value { [DEF setBool:value forKey:@"verifyTLS"]; }

#pragma mark - Identity

+ (NSString *)deviceId
{
    NSString *existing = [DEF stringForKey:@"deviceId"];
    if (existing.length == 32) return existing;
    uint8_t bytes[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != 0) {
        for (int i = 0; i < 16; i++) bytes[i] = (uint8_t)arc4random_uniform(256);
    }
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", bytes[i]];
    [DEF setObject:hex forKey:@"deviceId"];
    [DEF synchronize];
    return hex;
}

#pragma mark - Remembered session

+ (NSString *)rememberedSessionId { return [DEF stringForKey:@"rememberedSessionId"]; }
+ (NSString *)rememberedSessionBaseURL { return [DEF stringForKey:@"rememberedSessionBaseURL"]; }

+ (void)rememberSession:(NSString *)sessionId baseURL:(NSString *)baseURL
{
    if (!sessionId.length) return;
    [DEF setObject:sessionId forKey:@"rememberedSessionId"];
    [DEF setObject:baseURL ?: @"" forKey:@"rememberedSessionBaseURL"];
    [DEF synchronize];
}

+ (void)forgetSession
{
    [DEF removeObjectForKey:@"rememberedSessionId"];
    [DEF removeObjectForKey:@"rememberedSessionBaseURL"];
    [DEF synchronize];
}

#pragma mark - Search history

+ (NSArray *)recentSearches
{
    return [DEF arrayForKey:@"recentSearches"] ?: @[];
}

+ (void)addRecentSearch:(NSString *)query
{
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!q.length) return;
    NSMutableArray *list = [[self recentSearches] mutableCopy];
    for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
        if ([list[(NSUInteger)i] caseInsensitiveCompare:q] == NSOrderedSame) [list removeObjectAtIndex:(NSUInteger)i];
    }
    [list insertObject:q atIndex:0];
    while (list.count > 15) [list removeLastObject];
    [DEF setObject:list forKey:@"recentSearches"];
}

+ (void)clearRecentSearches
{
    [DEF removeObjectForKey:@"recentSearches"];
}

@end
