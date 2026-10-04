#import "GFAudioPlayer.h"
#import "GFCommon.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#include <pthread.h>
#include <opus.h>

#define SAMPLE_RATE 48000
#define CHANNELS 2
#define FRAME_SAMPLES 480                       // 10 ms
#define MAX_FRAME_SAMPLES 5760
#define RING_FRAMES (SAMPLE_RATE / 3)           // 333 ms of PCM
#define JITTER_SLOTS 24
#define TARGET_MS 60
#define MAX_BUFFER_MS 160
#define LIMITER_CEILING 30000.0f

typedef struct {
    int used;
    uint16_t seq;
    uint8_t pt;
    uint16_t len;
    uint8_t data[1500];
} jitter_slot;

static void *GFAudioThread(void *arg);

@interface GFAudioPlayer ()
- (void)decodeLoop;
@property (nonatomic) uint64_t decoded;
@property (nonatomic) uint64_t concealed;
@property (nonatomic) uint64_t recovered;
@property (nonatomic) uint64_t underruns;
@end

@implementation GFAudioPlayer {
    AudioComponentInstance _unit;
    OpusDecoder *_decoder;
    pthread_mutex_t _lock;
    pthread_cond_t _cond;
    pthread_t _thread;
    BOOL _running;
    // jitter buffer
    jitter_slot _slots[JITTER_SLOTS];
    int _held;
    uint16_t _expected;
    BOOL _haveExpected;
    BOOL _primed;
    uint64_t _firstPush_us;
    NSInteger _redPayloadType;
    // PCM ring (interleaved int16 stereo)
    int16_t *_ring;
    volatile uint32_t _ringWrite, _ringRead;   // in frames, modulo RING_FRAMES
    float _appliedGain;
    uint32_t _fadeFrames;
}

- (instancetype)init
{
    if ((self = [super init])) {
        pthread_mutex_init(&_lock, NULL);
        pthread_cond_init(&_cond, NULL);
        _gain = 2.0f;
        _appliedGain = 1.0f;
        _redPayloadType = -1;
        _ring = calloc(RING_FRAMES * CHANNELS, sizeof(int16_t));
    }
    return self;
}

- (void)dealloc
{
    [self stop];
    free(_ring);
    pthread_mutex_destroy(&_lock);
    pthread_cond_destroy(&_cond);
}

- (NSInteger)bufferedMs
{
    uint32_t w = _ringWrite, r = _ringRead;
    uint32_t frames = (w + RING_FRAMES - r) % RING_FRAMES;
    return frames * 1000 / SAMPLE_RATE;
}

#pragma mark - Output unit

static OSStatus GFAudioRender(void *inRefCon, AudioUnitRenderActionFlags *ioActionFlags, const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList *ioData)
{
    GFAudioPlayer *self = (__bridge GFAudioPlayer *)inRefCon;
    int16_t *out = ioData->mBuffers[0].mData;
    uint32_t w = self->_ringWrite, r = self->_ringRead;
    uint32_t available = (w + RING_FRAMES - r) % RING_FRAMES;
    uint32_t n = inNumberFrames < available ? inNumberFrames : available;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t idx = (r + i) % RING_FRAMES;
        out[2 * i] = self->_ring[2 * idx];
        out[2 * i + 1] = self->_ring[2 * idx + 1];
    }
    if (n < inNumberFrames) {
        memset(out + 2 * n, 0, (inNumberFrames - n) * CHANNELS * sizeof(int16_t));
        if (available == 0) self->_underruns++;
    }
    self->_ringRead = (r + n) % RING_FRAMES;
    return noErr;
}

- (BOOL)start
{
    if (_running) return YES;
    int err = 0;
    _decoder = opus_decoder_create(SAMPLE_RATE, CHANNELS, &err);
    if (err != OPUS_OK || !_decoder) { GFLog(@"Audio: opus decoder failed (%d)", err); return NO; }

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    [session setCategory:AVAudioSessionCategoryPlayback error:&error];
    [session setPreferredSampleRate:SAMPLE_RATE error:nil];
    [session setPreferredIOBufferDuration:0.01 error:nil];
    [session setActive:YES error:&error];
    if (error) GFLog(@"Audio: session error %@", error.localizedDescription);

    AudioComponentDescription desc = { kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0 };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp || AudioComponentInstanceNew(comp, &_unit) != noErr) { GFLog(@"Audio: no RemoteIO"); return NO; }
    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = SAMPLE_RATE;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    fmt.mChannelsPerFrame = CHANNELS;
    fmt.mBitsPerChannel = 16;
    fmt.mBytesPerFrame = CHANNELS * 2;
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerPacket = CHANNELS * 2;
    OSStatus st = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (st != noErr) GFLog(@"Audio: stream format failed (%d)", (int)st);
    AURenderCallbackStruct cb = { GFAudioRender, (__bridge void *)self };
    AudioUnitSetProperty(_unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof(cb));
    if (AudioUnitInitialize(_unit) != noErr || AudioOutputUnitStart(_unit) != noErr) { GFLog(@"Audio: unit start failed"); return NO; }

    _running = YES;
    _fadeFrames = 0;
    pthread_create(&_thread, NULL, GFAudioThread, (__bridge void *)self);
    GFLog(@"Audio: RemoteIO running at %.0f Hz", session.sampleRate);
    return YES;
}

- (void)stop
{
    if (!_running) return;
    pthread_mutex_lock(&_lock);
    _running = NO;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_lock);
    pthread_join(_thread, NULL);
    if (_unit) {
        AudioOutputUnitStop(_unit);
        AudioUnitUninitialize(_unit);
        AudioComponentInstanceDispose(_unit);
        _unit = NULL;
    }
    if (_decoder) { opus_decoder_destroy(_decoder); _decoder = NULL; }
    [[AVAudioSession sharedInstance] setActive:NO error:nil];
}

#pragma mark - Jitter buffer

- (void)pushPacket:(const uint8_t *)payload length:(size_t)length sequence:(uint16_t)sequence payloadType:(uint8_t)pt redPayloadType:(NSInteger)redPayloadType
{
    if (!_running || !length || length > 1500) return;
    pthread_mutex_lock(&_lock);
    _redPayloadType = redPayloadType;
    if (!_firstPush_us) _firstPush_us = GFMonotonicMicros();
    if (_haveExpected && (int16_t)(sequence - _expected) < 0) { pthread_mutex_unlock(&_lock); return; }   // already played past it
    if (_haveExpected && (int16_t)(sequence - _expected) > 200) {
        // the sender restarted its numbering: start over
        for (int i = 0; i < JITTER_SLOTS; i++) _slots[i].used = 0;
        _held = 0;
        _haveExpected = NO;
        _primed = NO;
        _firstPush_us = GFMonotonicMicros();
    }
    int free = -1, oldest = -1;
    for (int i = 0; i < JITTER_SLOTS; i++) {
        if (!_slots[i].used) { if (free < 0) free = i; continue; }
        if (_slots[i].seq == sequence) { pthread_mutex_unlock(&_lock); return; }
        if (oldest < 0 || (int16_t)(_slots[i].seq - _slots[oldest].seq) < 0) oldest = i;
    }
    if (free < 0) { free = oldest; _held--; }
    _slots[free].used = 1;
    _slots[free].seq = sequence;
    _slots[free].pt = pt;
    _slots[free].len = (uint16_t)length;
    memcpy(_slots[free].data, payload, length);
    _held++;
    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_lock);
}

// The primary opus payload of a RED packet (RFC 2198), or the data itself for plain opus
static const uint8_t *red_primary(const uint8_t *data, size_t len, size_t *out_len)
{
    size_t header = 0, redundant = 0;
    while (header < len && (data[header] & 0x80)) {
        if (header + 4 > len) return NULL;
        redundant += (size_t)(((data[header + 2] & 0x03) << 8) | data[header + 3]);
        header += 4;
    }
    if (header >= len) return NULL;
    header += 1;
    if (header + redundant >= len) return NULL;
    *out_len = len - header - redundant;
    return data + header + redundant;
}

// The first redundant block of a RED packet: a copy of the previous packet's audio
static const uint8_t *red_first_redundant(const uint8_t *data, size_t len, size_t *out_len)
{
    if (len < 5 || !(data[0] & 0x80)) return NULL;
    size_t first = (size_t)(((data[2] & 0x03) << 8) | data[3]);
    size_t header = 0;
    while (header < len && (data[header] & 0x80)) { if (header + 4 > len) return NULL; header += 4; }
    if (header >= len || first == 0) return NULL;
    header += 1;
    if (header + first > len) return NULL;
    *out_len = first;
    return data + header;
}

- (int)slotForSeq:(uint16_t)seq
{
    for (int i = 0; i < JITTER_SLOTS; i++) if (_slots[i].used && _slots[i].seq == seq) return i;
    return -1;
}

static void *GFAudioThread(void *arg)
{
    GFAudioPlayer *self = (__bridge GFAudioPlayer *)arg;
    [self decodeLoop];
    return NULL;
}

- (void)writePCM:(int16_t *)pcm frames:(int)frames
{
    // gain with a peak limiter and a short fade-in; then into the ring, dropping a frame when it runs long
    float peak = 1;
    for (int i = 0; i < frames * CHANNELS; i++) { float v = fabsf((float)pcm[i]); if (v > peak) peak = v; }
    float wanted = self.gain;
    float allowed = LIMITER_CEILING / peak;
    float target = wanted < allowed ? wanted : allowed;
    if (target < _appliedGain) _appliedGain = target;
    else _appliedGain += (target - _appliedGain) * 0.08f;
    for (int i = 0; i < frames * CHANNELS; i++) {
        float v = (float)pcm[i] * _appliedGain;
        if (_fadeFrames < 12000) { v *= (float)_fadeFrames / 12000.0f; }
        pcm[i] = (int16_t)(v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
    }
    _fadeFrames += (uint32_t)frames;
    uint32_t w = _ringWrite, r = _ringRead;
    uint32_t buffered = (w + RING_FRAMES - r) % RING_FRAMES;
    if (buffered > (uint32_t)(SAMPLE_RATE * MAX_BUFFER_MS / 1000)) return;   // running long: drop this 10 ms
    if (buffered + (uint32_t)frames >= RING_FRAMES - 1) return;
    for (int i = 0; i < frames; i++) {
        uint32_t idx = (w + (uint32_t)i) % RING_FRAMES;
        _ring[2 * idx] = pcm[2 * i];
        _ring[2 * idx + 1] = pcm[2 * i + 1];
    }
    _ringWrite = (w + (uint32_t)frames) % RING_FRAMES;
}

- (void)decodeLoop
{
    int16_t pcm[MAX_FRAME_SAMPLES * CHANNELS];
    uint8_t packet[1500];
    while (1) {
        pthread_mutex_lock(&_lock);
        while (_running && !_held) pthread_cond_wait(&_cond, &_lock);
        if (!_running) { pthread_mutex_unlock(&_lock); return; }
        if (!_primed) {
            uint64_t waited = GFMonotonicMicros() - _firstPush_us;
            if (_held < TARGET_MS / 10 && waited < (uint64_t)TARGET_MS * 1000) {
                pthread_mutex_unlock(&_lock);
                usleep(5000);
                continue;
            }
            // start from the lowest sequence number held
            int lowest = -1;
            for (int i = 0; i < JITTER_SLOTS; i++) if (_slots[i].used && (lowest < 0 || (int16_t)(_slots[i].seq - _slots[lowest].seq) < 0)) lowest = i;
            _expected = _slots[lowest].seq;
            _haveExpected = YES;
            _primed = YES;
        }
        // keep the ring around the target: when playback has enough queued, wait a little
        uint32_t buffered = (_ringWrite + RING_FRAMES - _ringRead) % RING_FRAMES;
        if (buffered > (uint32_t)(SAMPLE_RATE * (TARGET_MS + 20) / 1000)) {
            pthread_mutex_unlock(&_lock);
            usleep(5000);
            continue;
        }
        int idx = [self slotForSeq:_expected];
        size_t len = 0;
        const uint8_t *data = NULL;
        BOOL conceal = NO;
        if (idx >= 0) {
            if ((NSInteger)_slots[idx].pt == _redPayloadType) data = red_primary(_slots[idx].data, _slots[idx].len, &len);
            else { data = _slots[idx].data; len = _slots[idx].len; }
            if (data) memcpy(packet, data, len);
            _slots[idx].used = 0;
            _held--;
            if (!data) conceal = YES;
        } else {
            // missing: the next packet, if RED, carries a copy of exactly this one
            int next = [self slotForSeq:(uint16_t)(_expected + 1)];
            if (next >= 0 && (NSInteger)_slots[next].pt == _redPayloadType && (data = red_first_redundant(_slots[next].data, _slots[next].len, &len))) {
                memcpy(packet, data, len);
                self.recovered++;
            } else if (_held < 2) {
                // nothing newer either: give the late packet a moment instead of concealing at once
                pthread_mutex_unlock(&_lock);
                usleep(5000);
                pthread_mutex_lock(&_lock);
                if (!_running) { pthread_mutex_unlock(&_lock); return; }
                if ([self slotForSeq:_expected] >= 0) { pthread_mutex_unlock(&_lock); continue; }
                conceal = YES;
                data = NULL;
            } else {
                conceal = YES;
                data = NULL;
            }
        }
        _expected++;
        pthread_mutex_unlock(&_lock);

        int frames;
        if (conceal || !data) {
            frames = opus_decode(_decoder, NULL, 0, pcm, FRAME_SAMPLES, 0);
            self.concealed++;
        } else {
            frames = opus_decode(_decoder, packet, (opus_int32)len, pcm, MAX_FRAME_SAMPLES, 0);
            if (frames > 0) self.decoded++;
        }
        if (frames > 0) [self writePCM:pcm frames:frames];
    }
}

@end
