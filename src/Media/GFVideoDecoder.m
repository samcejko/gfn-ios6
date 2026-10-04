#import "GFVideoDecoder.h"
#import "GFCommon.h"
#import <CoreMedia/CoreMedia.h>
#include <dlfcn.h>
#include <pthread.h>
#include "gf_rtp.h"

// The private VideoToolbox of iOS 4-7 (same symbols as the public framework later): resolved at run time
typedef CFTypeRef GFVTSessionRef;
typedef void (*GFVTOutputCallback)(void *refcon, CFDictionaryRef frameInfo, OSStatus status, UInt32 infoFlags, CVBufferRef imageBuffer);
typedef struct { GFVTOutputCallback callback; void *refcon; } GFVTOutputCallbackRecord;
typedef OSStatus (*GFVTCreateFn)(CFAllocatorRef, CMFormatDescriptionRef, CFTypeRef, CFDictionaryRef, GFVTOutputCallbackRecord *, GFVTSessionRef *);
typedef OSStatus (*GFVTDecodeFn)(GFVTSessionRef, CMSampleBufferRef, uint32_t, CFDictionaryRef, uint32_t);
typedef void (*GFVTInvalidateFn)(GFVTSessionRef);
typedef OSStatus (*GFVTWaitFn)(GFVTSessionRef);

static GFVTCreateFn g_create;
static GFVTDecodeFn g_decode;
static GFVTInvalidateFn g_invalidate;
static GFVTWaitFn g_wait;
static BOOL g_loaded;

static void GFLoadVideoToolbox(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *paths[] = { "/System/Library/PrivateFrameworks/VideoToolbox.framework/VideoToolbox",
                                "/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox" };
        void *h = NULL;
        for (int i = 0; i < 2 && !h; i++) h = dlopen(paths[i], RTLD_NOW);
        if (!h) { GFLog(@"VideoToolbox: not found (%s)", dlerror()); return; }
        g_create = (GFVTCreateFn)dlsym(h, "VTDecompressionSessionCreate");
        g_decode = (GFVTDecodeFn)dlsym(h, "VTDecompressionSessionDecodeFrame");
        g_invalidate = (GFVTInvalidateFn)dlsym(h, "VTDecompressionSessionInvalidate");
        g_wait = (GFVTWaitFn)dlsym(h, "VTDecompressionSessionWaitForAsynchronousFrames");
        g_loaded = g_create && g_decode && g_invalidate;
        GFLog(@"VideoToolbox: %@", g_loaded ? @"loaded" : @"missing entry points");
    });
}

@interface GFVideoDecoder ()
- (void)outputStatus:(OSStatus)status flags:(UInt32)flags image:(CVBufferRef)image;
@property (nonatomic) NSInteger width;
@property (nonatomic) NSInteger height;
@property (nonatomic) uint64_t decodedFrames;
@property (nonatomic) uint64_t errors;
@property (nonatomic) uint64_t droppedInputs;
@property (nonatomic, copy) NSString *lastError;
@end

@implementation GFVideoDecoder {
    GFVTSessionRef _session;
    CMFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    pthread_mutex_t _lock;
    pthread_cond_t _cond;
    NSMutableArray *_queue;          // NSData access units (Annex B) waiting for the decoder thread
    NSMutableArray *_queueKeyframes; // NSNumber flags parallel to _queue
    CVPixelBufferRef _latest;
    BOOL _running;
    BOOL _waitingForKeyframe;
    double _decodeMsTotal;
    uint64_t _decodeCount;
    NSThread *_thread;
}

+ (BOOL)isAvailable
{
    GFLoadVideoToolbox();
    return g_loaded;
}

- (instancetype)init
{
    if ((self = [super init])) {
        GFLoadVideoToolbox();
        pthread_mutex_init(&_lock, NULL);
        pthread_cond_init(&_cond, NULL);
        _queue = [NSMutableArray array];
        _queueKeyframes = [NSMutableArray array];
        _running = YES;
        _waitingForKeyframe = YES;
        _thread = [[NSThread alloc] initWithTarget:self selector:@selector(threadMain) object:nil];
        _thread.name = @"gfn6-decoder";
        [_thread start];
    }
    return self;
}

- (void)dealloc
{
    [self destroySession];
    if (_latest) CVBufferRelease(_latest);
    pthread_mutex_destroy(&_lock);
    pthread_cond_destroy(&_cond);
}

- (double)averageDecodeMs { return _decodeCount ? _decodeMsTotal / (double)_decodeCount : 0; }

#pragma mark - Input

- (void)decodeAccessUnit:(const uint8_t *)annexB length:(size_t)length timestamp:(uint32_t)rtpTimestamp keyframe:(BOOL)keyframe
{
    if (!g_loaded || !length) return;
    NSData *au = [NSData dataWithBytes:annexB length:length];
    pthread_mutex_lock(&_lock);
    if (_queue.count >= 4) {
        // the decoder is behind: start again from the next keyframe rather than build latency
        _droppedInputs += _queue.count;
        [_queue removeAllObjects];
        [_queueKeyframes removeAllObjects];
        _waitingForKeyframe = YES;
    }
    [_queue addObject:au];
    [_queueKeyframes addObject:@(keyframe)];
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_lock);
}

- (void)flush
{
    pthread_mutex_lock(&_lock);
    [_queue removeAllObjects];
    [_queueKeyframes removeAllObjects];
    _waitingForKeyframe = YES;
    pthread_mutex_unlock(&_lock);
}

- (CVPixelBufferRef)copyLatestFrame
{
    pthread_mutex_lock(&_lock);
    CVPixelBufferRef f = _latest;
    _latest = NULL;
    pthread_mutex_unlock(&_lock);
    return f;
}

- (void)invalidate
{
    pthread_mutex_lock(&_lock);
    _running = NO;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_lock);
}

#pragma mark - Decoder thread

- (void)threadMain
{
    while (1) {
        @autoreleasepool {
            NSData *au = nil;
            BOOL keyframe = NO;
            pthread_mutex_lock(&_lock);
            while (_running && !_queue.count) pthread_cond_wait(&_cond, &_lock);
            if (!_running) { pthread_mutex_unlock(&_lock); break; }
            au = _queue[0];
            keyframe = [_queueKeyframes[0] boolValue];
            [_queue removeObjectAtIndex:0];
            [_queueKeyframes removeObjectAtIndex:0];
            pthread_mutex_unlock(&_lock);
            [self decode:au keyframe:keyframe];
        }
    }
    [self destroySession];
}

static void GFVTOutput(void *refcon, CFDictionaryRef frameInfo, OSStatus status, UInt32 infoFlags, CVBufferRef imageBuffer)
{
    GFVideoDecoder *self = (__bridge GFVideoDecoder *)refcon;
    [self outputStatus:status flags:infoFlags image:imageBuffer];
}

- (void)outputStatus:(OSStatus)status flags:(UInt32)flags image:(CVBufferRef)image
{
    if (status != 0 || !image) {
        self.errors++;
        if (status != 0 && self.errors < 10) GFLog(@"VideoToolbox: frame failed (%d)", (int)status);
        return;
    }
    if (flags & 2) return;    // dropped
    pthread_mutex_lock(&_lock);
    if (_latest) CVBufferRelease(_latest);
    _latest = CVBufferRetain(image);
    _decodedFrames++;
    pthread_mutex_unlock(&_lock);
}

- (void)destroySession
{
    if (_session) {
        if (g_invalidate) g_invalidate(_session);
        CFRelease(_session);
        _session = NULL;
    }
    if (_format) { CFRelease(_format); _format = NULL; }
}

- (BOOL)createSessionWithSPS:(NSData *)sps PPS:(NSData *)pps
{
    [self destroySession];
    int w = 0, h = 0;
    if (!gf_h264_sps_dimensions(sps.bytes, sps.length, &w, &h)) { self.lastError = @"bad SPS"; return NO; }
    const uint8_t *s = sps.bytes;
    NSMutableData *avcc = [NSMutableData data];
    uint8_t head[6] = { 1, s[1], s[2], s[3], 0xFF, 0xE1 };
    [avcc appendBytes:head length:6];
    uint8_t len16[2] = { (uint8_t)(sps.length >> 8), (uint8_t)sps.length };
    [avcc appendBytes:len16 length:2];
    [avcc appendData:sps];
    uint8_t one = 1;
    [avcc appendBytes:&one length:1];
    len16[0] = (uint8_t)(pps.length >> 8);
    len16[1] = (uint8_t)pps.length;
    [avcc appendBytes:len16 length:2];
    [avcc appendData:pps];
    NSDictionary *atoms = @{ @"avcC": avcc };
    NSDictionary *extensions = @{ (__bridge NSString *)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms };
    OSStatus st = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_H264, w, h, (__bridge CFDictionaryRef)extensions, &_format);
    if (st != 0 || !_format) { self.lastError = [NSString stringWithFormat:@"format description %d", (int)st]; _format = NULL; return NO; }
    NSDictionary *attrs = @{ (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
                             (__bridge NSString *)kCVPixelBufferOpenGLESCompatibilityKey: @YES };
    GFVTOutputCallbackRecord cb = { GFVTOutput, (__bridge void *)self };
    st = g_create(kCFAllocatorDefault, _format, NULL, (__bridge CFDictionaryRef)attrs, &cb, &_session);
    if (st != 0 || !_session) {
        self.lastError = [NSString stringWithFormat:@"session create %d", (int)st];
        _session = NULL;
        return NO;
    }
    self.width = w;
    self.height = h;
    GFLog(@"VideoToolbox: session %dx%d (profile %d)", w, h, s[1]);
    return YES;
}

- (void)decode:(NSData *)au keyframe:(BOOL)keyframe
{
    const uint8_t *sps = NULL, *pps = NULL;
    size_t spsLen = 0, ppsLen = 0;
    if (gf_h264_find_parameter_sets(au.bytes, au.length, &sps, &spsLen, &pps, &ppsLen)) {
        NSData *newSps = [NSData dataWithBytes:sps length:spsLen], *newPps = [NSData dataWithBytes:pps length:ppsLen];
        if (!_session || ![newSps isEqualToData:_sps] || ![newPps isEqualToData:_pps]) {
            _sps = newSps;
            _pps = newPps;
            if (![self createSessionWithSPS:newSps PPS:newPps]) { self.errors++; return; }
        }
    }
    if (!_session) return;
    if (_waitingForKeyframe) {
        if (!keyframe) { self.droppedInputs++; return; }
        _waitingForKeyframe = NO;
    }
    size_t cap = au.length + 64;
    uint8_t *avcc = malloc(cap);
    if (!avcc) return;
    size_t n = gf_h264_annexb_to_avcc(au.bytes, au.length, avcc, cap);
    if (!n) { free(avcc); return; }
    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avcc, n, kCFAllocatorMalloc, NULL, 0, n, 0, &block);
    if (st != 0 || !block) { free(avcc); self.errors++; return; }
    CMSampleBufferRef sample = NULL;
    st = CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, _format, 1, 0, NULL, 0, NULL, &sample);
    CFRelease(block);
    if (st != 0 || !sample) { self.errors++; return; }
    uint64_t t0 = GFMonotonicMicros();
    st = g_decode(_session, sample, 0, NULL, 0);
    if (st != 0) {
        self.errors++;
        if (self.errors < 10 || self.errors % 100 == 0) GFLog(@"VideoToolbox: decode returned %d", (int)st);
        // a broken reference chain: wait for the next keyframe, and rebuild the session on repeated failures
        _waitingForKeyframe = YES;
        if (st == -12911 || st == -12909 || st == -12902) { [self destroySession]; _sps = nil; }
    } else if (g_wait) {
        g_wait(_session);
    }
    _decodeMsTotal += (double)(GFMonotonicMicros() - t0) / 1000.0;
    _decodeCount++;
    CFRelease(sample);
}

@end
