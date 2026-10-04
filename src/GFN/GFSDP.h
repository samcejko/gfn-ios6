#import <Foundation/Foundation.h>

// What the app needs out of NVIDIA's SDP offer
@interface GFSDPOffer : NSObject
@property (nonatomic, copy) NSString *raw;
@property (nonatomic, copy) NSString *iceUfrag;
@property (nonatomic, copy) NSString *icePwd;
@property (nonatomic, copy) NSString *fingerprint;          // "sha-256 AB:CD:..."
@property (nonatomic, strong) NSArray *sections;            // dictionaries per m= line, in order (see GFSDP.m)
@property (nonatomic) NSInteger h264PayloadType;            // -1 when none
@property (nonatomic, copy) NSString *h264Fmtp;
@property (nonatomic) NSInteger opusPayloadType;            // -1 when none
@property (nonatomic, copy) NSString *opusFmtp;
@property (nonatomic) NSInteger redPayloadType;             // RFC 2198 redundancy wrapping opus, -1 when none
@property (nonatomic) NSInteger sctpPort;
@property (nonatomic) uint32_t videoSSRC;                   // 0 when the offer does not say
@property (nonatomic) uint32_t audioSSRC;
@property (nonatomic, strong) NSArray *candidates;          // "candidate:..." strings (0.0.0.0 already replaced)
@property (nonatomic) NSInteger riPartialReliableThresholdMs;
@property (nonatomic) uint32_t riHidDeviceMask;
@property (nonatomic) uint32_t riPartialReliableGamepadMask;
@property (nonatomic) uint32_t riPartialReliableHidMask;
+ (instancetype)offerWithSDP:(NSString *)sdp serverIp:(NSString *)serverIp;
@end

@interface GFSDP : NSObject

// The WebRTC answer: opus (+red) and the chosen H.264 payload type received, the data channel transport, the
// microphone and anything else rejected. All transport attributes are ours (ICE credentials, DTLS fingerprint,
// setup:active).
+ (NSString *)answerForOffer:(GFSDPOffer *)offer iceUfrag:(NSString *)ufrag icePwd:(NSString *)pwd
                 fingerprint:(NSString *)fingerprint videoKbps:(NSInteger)videoKbps;

// NVIDIA's own parameter blob sent next to the answer ("nvstSdp"): the stream settings and, importantly, the ICE
// credentials the server validates STUN requests against.
+ (NSString *)nvstSDPForOffer:(GFSDPOffer *)offer iceUfrag:(NSString *)ufrag icePwd:(NSString *)pwd fingerprint:(NSString *)fingerprint
                        width:(NSInteger)width height:(NSInteger)height fps:(NSInteger)fps maxKbps:(NSInteger)maxKbps;

// Random ICE strings: ufrag (4+) and password (22+) characters from the ice-char alphabet
+ (NSString *)randomICEString:(NSUInteger)length;

// A literal a.b.c.d, or the address an Alliance host name encodes in its first label ("62-210-1-2.host...")
+ (NSString *)publicIPFromHost:(NSString *)host;

@end
