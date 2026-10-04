#import <Foundation/Foundation.h>

@class GFWebSocket;

// Everything is delivered on the socket's own reader thread; implementations hop to whatever queue they need.
@protocol GFWebSocketDelegate <NSObject>
- (void)webSocketDidOpen:(GFWebSocket *)socket;
- (void)webSocket:(GFWebSocket *)socket didReceiveText:(NSString *)text;
- (void)webSocket:(GFWebSocket *)socket didReceiveData:(NSData *)data;
- (void)webSocket:(GFWebSocket *)socket didCloseWithReason:(NSString *)reason;   // also for connect failures
@end

// A small RFC 6455 client over the app's TLS socket: text and binary frames, ping/pong, close. One reader thread
// per connection; -sendText: may be called from any thread.
@interface GFWebSocket : NSObject

- (instancetype)initWithURL:(NSURL *)url protocols:(NSArray *)protocols headers:(NSDictionary *)headers delegate:(id<GFWebSocketDelegate>)delegate;
- (void)open;
- (BOOL)sendText:(NSString *)text;
- (BOOL)sendData:(NSData *)data;
- (void)close;

@property (nonatomic, readonly) BOOL isOpen;
@property (nonatomic, readonly) NSString *connectedHost;

@end
