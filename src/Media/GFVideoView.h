#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

// Draws decoded pictures (BGRA pixel buffers from the hardware decoder) with OpenGL ES 2 through the texture
// cache: no copies. A display link asks the source for the newest picture 60 times a second.
@interface GFVideoView : UIView

@property (nonatomic, copy) CVPixelBufferRef (^frameSource)(void);     // returns a retained buffer or NULL
@property (nonatomic) BOOL aspectFill;                                  // NO = letterbox (default)
@property (nonatomic, readonly) uint64_t framesDrawn;
@property (nonatomic, readonly) CGSize frameSize;                       // of the last picture

- (void)startDisplayLink;
- (void)stopDisplayLink;
- (void)clear;

@end
