#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// User preferences, kept in NSUserDefaults. Setters post GFSettingsDidChangeNotification.
@interface GFSettings : NSObject

+ (void)registerDefaults;
+ (void)save;

// Appearance
+ (BOOL)darkTheme;
+ (void)setDarkTheme:(BOOL)value;

// Stream
+ (NSString *)streamResolution;         // "1024x768"; "native" = the screen in pixels
+ (void)setStreamResolution:(NSString *)value;
+ (CGSize)streamSize;                   // the resolution resolved to numbers
+ (NSInteger)streamFps;                 // 30 or 60
+ (void)setStreamFps:(NSInteger)value;
+ (NSInteger)maxBitrateMbps;            // the ceiling NVIDIA's encoder is told (3..30)
+ (void)setMaxBitrateMbps:(NSInteger)value;
+ (NSString *)region;                   // "" = automatic, else the https base URL of a zone
+ (void)setRegion:(NSString *)value;
+ (NSString *)regionName;
+ (void)setRegionName:(NSString *)value;
+ (NSString *)gameLanguage;             // "en_US", "cs_CZ"...
+ (void)setGameLanguage:(NSString *)value;
+ (BOOL)showStats;                      // the small stream statistics overlay
+ (void)setShowStats:(BOOL)value;

// Controls
+ (BOOL)touchGamepad;                   // the on-screen gamepad
+ (void)setTouchGamepad:(BOOL)value;
+ (CGFloat)gamepadOpacity;              // 0.2..0.9
+ (void)setGamepadOpacity:(CGFloat)value;
+ (CGFloat)mouseSensitivity;            // 0.5..3
+ (void)setMouseSensitivity:(CGFloat)value;

// Library
+ (NSString *)libraryFilter;            // "my_games" or "all"
+ (void)setLibraryFilter:(NSString *)value;
+ (NSString *)librarySort;              // "title", "last_played"
+ (void)setLibrarySort:(NSString *)value;

// Network
+ (BOOL)verifyTLS;
+ (void)setVerifyTLS:(BOOL)value;

// Identity: a random id made once per installation (NVIDIA calls it the device hash id)
+ (NSString *)deviceId;

// A session that may still be open on NVIDIA's side (the app was killed while playing)
+ (NSString *)rememberedSessionId;
+ (NSString *)rememberedSessionBaseURL;
+ (void)rememberSession:(NSString *)sessionId baseURL:(NSString *)baseURL;
+ (void)forgetSession;

// Search history (most recent first, 15 kept)
+ (NSArray *)recentSearches;
+ (void)addRecentSearch:(NSString *)query;
+ (void)clearRecentSearches;

@end
