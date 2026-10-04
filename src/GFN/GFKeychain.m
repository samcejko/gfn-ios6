#import "GFKeychain.h"
#import "GFCommon.h"
#import <Security/Security.h>

static NSString * const GFKeychainService = @"com.samcejko.gfn6";

@implementation GFKeychain

+ (NSMutableDictionary *)queryForKey:(NSString *)key
{
    return [@{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: GFKeychainService,
        (__bridge id)kSecAttrAccount: key ?: @"",
    } mutableCopy];
}

+ (NSString *)fallbackKey:(NSString *)key
{
    return [@"kc." stringByAppendingString:key ?: @""];
}

+ (NSData *)dataForKey:(NSString *)key
{
    NSMutableDictionary *q = [self queryForKey:key];
    q[(__bridge id)kSecReturnData] = (__bridge id)kCFBooleanTrue;
    q[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        return data;
    }
    if (status != errSecItemNotFound) GFLog(@"Keychain read of %@ failed (%d), using preferences", key, (int)status);
    return [[NSUserDefaults standardUserDefaults] dataForKey:[self fallbackKey:key]];
}

+ (BOOL)setData:(NSData *)data forKey:(NSString *)key
{
    if (!data) { [self removeKey:key]; return YES; }
    NSMutableDictionary *q = [self queryForKey:key];
    SecItemDelete((__bridge CFDictionaryRef)q);
    q[(__bridge id)kSecValueData] = data;
    q[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)q, NULL);
    if (status == errSecSuccess) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self fallbackKey:key]];
        return YES;
    }
    GFLog(@"Keychain write of %@ failed (%d), using preferences", key, (int)status);
    [[NSUserDefaults standardUserDefaults] setObject:data forKey:[self fallbackKey:key]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return NO;
}

+ (void)removeKey:(NSString *)key
{
    SecItemDelete((__bridge CFDictionaryRef)[self queryForKey:key]);
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:[self fallbackKey:key]];
}

@end
