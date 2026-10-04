#import <Foundation/Foundation.h>

// Game audio: Opus packets (10 ms, 48 kHz stereo, with NVIDIA's RED redundancy) reordered in a small jitter
// buffer, decoded on a worker thread, played through the RemoteIO audio unit. Loss is concealed by the decoder.
@interface GFAudioPlayer : NSObject

- (BOOL)start;
- (void)stop;
// From the network thread
- (void)pushPacket:(const uint8_t *)payload length:(size_t)length sequence:(uint16_t)sequence payloadType:(uint8_t)payloadType redPayloadType:(NSInteger)redPayloadType;

@property (nonatomic) float gain;                 // 1.0 = as sent (NVIDIA's level is low; 2.0 default, limited to avoid clipping)
@property (nonatomic, readonly) uint64_t decoded;
@property (nonatomic, readonly) uint64_t concealed;
@property (nonatomic, readonly) uint64_t recovered;
@property (nonatomic, readonly) uint64_t underruns;
@property (nonatomic, readonly) NSInteger bufferedMs;

@end
