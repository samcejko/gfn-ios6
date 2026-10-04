// Shared macros and constants. Everything here must be iOS 6.0 safe.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// Any API newer than the iOS 6.0 deployment target is a hard error in files that include this header.
#pragma clang diagnostic error "-Wunguarded-availability"

#define L(key) NSLocalizedString((key), nil)
#define GFIsPad() (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad)
#define GFLog(fmt, ...) NSLog((@"[GFN6] " fmt), ##__VA_ARGS__)

// Runs a block on the main thread (immediately if already there).
static inline void GFMain(dispatch_block_t block)
{
    if ([NSThread isMainThread]) block();
    else dispatch_async(dispatch_get_main_queue(), block);
}

extern NSString * const GFErrorDomain;
extern NSString * const GFThemeDidChangeNotification;
extern NSString * const GFSettingsDidChangeNotification;
extern NSString * const GFAuthDidChangeNotification;        // signed in or out (posted on the main thread)
extern NSString * const GFLibraryDidChangeNotification;     // the game list or favourites changed

// NSError codes in GFErrorDomain (HTTP errors use the HTTP status as code)
enum {
    GFErrorNetwork        = -1,
    GFErrorTLS            = -2,
    GFErrorCertificate    = -3,
    GFErrorTimeout        = -4,
    GFErrorCancelled      = -5,
    GFErrorBadResponse    = -6,
    GFErrorDNS            = -7,
    GFErrorConnect        = -8,
    GFErrorConnectionLost = -9,
    GFErrorAPI            = -10,   // NVIDIA answered, but with an error
    GFErrorOffline        = -11,
    GFErrorAuth           = -12,   // the saved login is no longer valid, sign in again
    GFErrorRestricted     = -13,   // not allowed (membership, region...)
    GFErrorStream         = -14,   // the media transport failed (ICE, DTLS, decoder)
};

NSError *GFMakeError(NSInteger code, NSString *message);

// JSON values as the type the caller expects, nil/0 for anything else (NSNull, wrong type)
NSString *GFStr(id value);         // numbers become their decimal string
NSDictionary *GFDict(id value);
NSArray *GFArr(id value);
NSInteger GFInt(id value);
double GFDbl(id value);
BOOL GFBool(id value);

// "2026-10-02T17:31:00Z" and "2026-10-02T17:31:05.042684Z"
NSDate *GFDateFromISO(NSString *string);

// Monotonic microseconds since an arbitrary point (mach_absolute_time based)
uint64_t GFMonotonicMicros(void);
