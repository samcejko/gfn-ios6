#import <Foundation/Foundation.h>

// Small values (tokens) in the keychain, generic-password items of the app's service. When the keychain refuses
// (no entitlement, locked), the preferences hold the value instead so the app still works.
@interface GFKeychain : NSObject
+ (NSData *)dataForKey:(NSString *)key;
+ (BOOL)setData:(NSData *)data forKey:(NSString *)key;
+ (void)removeKey:(NSString *)key;
@end
