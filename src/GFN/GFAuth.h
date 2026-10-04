#import <Foundation/Foundation.h>

// A device-code login in progress: the code the user types in on another device, and what the poll needs.
@interface GFDeviceCode : NSObject
@property (nonatomic, copy) NSString *userCode;
@property (nonatomic, copy) NSString *verificationURL;        // includes the code already (what the QR points at)
@property (nonatomic, copy) NSString *deviceCode;
@property (nonatomic) NSTimeInterval interval;                // seconds between polls
@property (nonatomic, strong) NSDate *expires;
@property (nonatomic, strong) NSDictionary *provider;         // the login provider this code belongs to
- (BOOL)isExpired;
@end

typedef void (^GFDeviceCodeBlock)(GFDeviceCode *code, NSError *error);
// authorized: signed in; pending: keep polling (after `interval`); otherwise error says why it is over
typedef void (^GFDevicePollBlock)(BOOL authorized, BOOL pending, NSError *error);

// NVIDIA account: the OAuth device-code flow ("sign in on another device with this code"), tokens in the keychain,
// refresh before they expire. Everything runs on the main thread. Posts GFAuthDidChangeNotification.
@interface GFAuth : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isSignedIn;
@property (nonatomic, readonly) NSString *userId;             // the account's subject id
@property (nonatomic, readonly) NSString *displayName;
@property (nonatomic, readonly) NSString *email;
@property (nonatomic, readonly) NSString *membershipTier;     // "FREE", "PERFORMANCE", "ULTIMATE"... (nil until fetched)

// The token the GFN services expect behind "GFNJWT " (the id token, else the access token)
- (NSString *)bearerToken;
// The login provider's streaming service (CloudMatch) base URL and idp id
- (NSString *)streamingBaseURL;
- (NSString *)providerIdpId;

- (void)startDeviceLogin:(GFDeviceCodeBlock)completion;
- (void)pollDeviceLogin:(GFDeviceCode *)code completion:(GFDevicePollBlock)completion;

// Refreshes the tokens when they are about to expire (or have an unknown expiry); calls back at once otherwise.
// A rejected refresh signs the user out and reports GFErrorAuth.
- (void)ensureFreshTokens:(void (^)(NSError *error))completion;
- (void)fetchMembershipTierWithVpcId:(NSString *)vpcId completion:(void (^)(NSString *tier))completion;
- (NSTimeInterval)maxSessionSeconds;                           // by membership tier

- (void)signOut;

@end
