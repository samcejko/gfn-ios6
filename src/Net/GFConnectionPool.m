#import "GFConnectionPool.h"
#import "GFTLSSocket.h"
#import "GFCommon.h"

static const NSTimeInterval GFIdleTimeout = 25;     // most servers drop idle connections after 5 to 60 s
static const NSUInteger GFMaxIdlePerKey = 6;
static const NSUInteger GFMaxIdleTotal = 24;

@interface GFPooledConnection : NSObject
@property (nonatomic, strong) GFTLSSocket *socket;
@property (nonatomic) NSTimeInterval lastUsed;
@end

@implementation GFPooledConnection
@end

@implementation GFConnectionPool {
    NSMutableDictionary *_idle;     // key -> NSMutableArray<GFPooledConnection>
    NSUInteger _count;
    NSUInteger _reuses;
}

+ (instancetype)shared
{
    static GFConnectionPool *pool;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pool = [[GFConnectionPool alloc] init]; });
    return pool;
}

- (instancetype)init
{
    self = [super init];
    if (self) _idle = [NSMutableDictionary dictionary];
    return self;
}

// Must be called with the lock held. Moves expired connections into `dead`.
- (void)pruneLocked:(NSMutableArray *)dead
{
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    NSMutableArray *emptyKeys = [NSMutableArray array];
    for (NSString *key in _idle) {
        NSMutableArray *list = _idle[key];
        for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
            GFPooledConnection *c = list[(NSUInteger)i];
            if (now - c.lastUsed > GFIdleTimeout) {
                [dead addObject:c.socket];
                [list removeObjectAtIndex:(NSUInteger)i];
                _count--;
            }
        }
        if (!list.count) [emptyKeys addObject:key];
    }
    [_idle removeObjectsForKeys:emptyKeys];
}

- (GFTLSSocket *)checkoutSocketForKey:(NSString *)key
{
    if (!key) return nil;
    NSMutableArray *dead = [NSMutableArray array];
    GFTLSSocket *result = nil;
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        while (list.count && !result) {
            GFPooledConnection *c = [list lastObject];
            [list removeLastObject];
            _count--;
            if ([c.socket isLikelyAlive]) result = c.socket;
            else [dead addObject:c.socket];
        }
        if (result) _reuses++;
    }
    for (GFTLSSocket *s in dead) [s close];
    return result;
}

- (void)checkinSocket:(GFTLSSocket *)socket forKey:(NSString *)key
{
    if (!socket || !key) return;
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        [self pruneLocked:dead];
        NSMutableArray *list = _idle[key];
        if (!list) {
            list = [NSMutableArray array];
            _idle[key] = list;
        }
        if (list.count >= GFMaxIdlePerKey || _count >= GFMaxIdleTotal) {
            [dead addObject:socket];
        } else {
            GFPooledConnection *c = [[GFPooledConnection alloc] init];
            c.socket = socket;
            c.lastUsed = [NSDate timeIntervalSinceReferenceDate];
            [list addObject:c];
            _count++;
        }
    }
    for (GFTLSSocket *s in dead) [s close];
}

- (void)drain
{
    NSMutableArray *dead = [NSMutableArray array];
    @synchronized (self) {
        for (NSString *key in _idle) {
            for (GFPooledConnection *c in _idle[key]) [dead addObject:c.socket];
        }
        [_idle removeAllObjects];
        _count = 0;
    }
    for (GFTLSSocket *s in dead) [s close];
    if (dead.count) GFLog(@"Connection pool drained (%lu closed)", (unsigned long)dead.count);
}

- (NSUInteger)idleCount
{
    @synchronized (self) { return _count; }
}

- (NSUInteger)reuseCount
{
    @synchronized (self) { return _reuses; }
}

@end
