#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Hardware H.264 decoding through the VideoToolbox framework, which is private on iOS 6 (public from iOS 8 with the
// same entry points). Access units go in on any thread and are decoded on the decoder's own thread; the newest
// decoded picture is kept for whoever draws it.
@interface GFVideoDecoder : NSObject

+ (BOOL)isAvailable;                 // the framework loaded and has the entry points

- (void)decodeAccessUnit:(const uint8_t *)annexB length:(size_t)length timestamp:(uint32_t)rtpTimestamp keyframe:(BOOL)keyframe;
// The newest picture not yet taken (retained; the caller releases it), or NULL
- (CVPixelBufferRef)copyLatestFrame;
- (void)flush;                       // drop queued input (after a keyframe request)
- (void)invalidate;

@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) uint64_t decodedFrames;
@property (nonatomic, readonly) uint64_t errors;
@property (nonatomic, readonly) uint64_t droppedInputs;
@property (nonatomic, readonly) double averageDecodeMs;
@property (nonatomic, readonly) NSString *lastError;

@end
