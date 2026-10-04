#import <Foundation/Foundation.h>

typedef void (^GFHTTPCompletion)(NSInteger status, NSData *body, NSDictionary *headers, NSError *error);
typedef void (^GFJSONCompletion)(id json, NSInteger status, NSError *error);

// A running request of GFHTTP. After -cancel the completion block is never called.
@interface GFHTTPTask : NSObject
@property (atomic, readonly) BOOL isCancelled;
@property (atomic, copy) dispatch_block_t cancelBlock;   // for chained requests: called by -cancel (once)
- (void)cancel;
@end

// Convenience layer over GFHTTPRequest for API calls: redirects are followed, GET requests are tried a second
// time after a network error, completion blocks run on the main thread.
@interface GFHTTP : NSObject

+ (GFHTTPTask *)request:(NSString *)method url:(NSString *)url headers:(NSDictionary *)headers body:(NSData *)body
                retries:(NSInteger)retries completion:(GFHTTPCompletion)completion;

+ (GFHTTPTask *)get:(NSString *)url headers:(NSDictionary *)headers completion:(GFHTTPCompletion)completion;

// JSON answers. `error` is set for network errors, for statuses >= 400 (code = the status, message from the body
// when it has one) and for bodies that are not JSON; `json` is passed even with an error when the body parsed.
+ (GFHTTPTask *)getJSON:(NSString *)url headers:(NSDictionary *)headers completion:(GFJSONCompletion)completion;
+ (GFHTTPTask *)postJSON:(NSString *)url headers:(NSDictionary *)headers object:(id)object retries:(NSInteger)retries
              completion:(GFJSONCompletion)completion;
+ (GFHTTPTask *)postForm:(NSString *)url fields:(NSDictionary *)fields completion:(GFJSONCompletion)completion;
+ (GFHTTPTask *)postForm:(NSString *)url headers:(NSDictionary *)headers fields:(NSDictionary *)fields completion:(GFJSONCompletion)completion;

@end
