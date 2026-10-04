#import "GFSDP.h"
#import "GFCommon.h"
#import <Security/Security.h>

// section keys: type (audio/video/application/other), mid, proto, ptypes (array of strings), rtpmap (pt -> "opus/48000/2"),
// fmtp (pt -> params), direction, sctpPort, rejected
@implementation GFSDPOffer

+ (instancetype)offerWithSDP:(NSString *)sdp serverIp:(NSString *)serverIp
{
    GFSDPOffer *o = [[GFSDPOffer alloc] init];
    o.raw = sdp;
    o.h264PayloadType = -1;
    o.opusPayloadType = -1;
    o.redPayloadType = -1;
    o.sctpPort = 5000;
    o.riPartialReliableThresholdMs = 300;
    o.riHidDeviceMask = 0xffffffffu;
    o.riPartialReliableGamepadMask = 0x0f;
    o.riPartialReliableHidMask = 0xffffffffu;
    NSString *ip = [GFSDP publicIPFromHost:serverIp];
    NSMutableArray *sections = [NSMutableArray array];
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableDictionary *current = nil;
    NSArray *lines = [[sdp stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length) continue;
        if ([line hasPrefix:@"m="]) {
            NSArray *parts = [[line substringFromIndex:2] componentsSeparatedByString:@" "];
            current = [NSMutableDictionary dictionary];
            current[@"type"] = parts.count ? parts[0] : @"other";
            current[@"proto"] = parts.count > 2 ? parts[2] : @"";
            current[@"ptypes"] = parts.count > 3 ? [parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] : @[];
            current[@"rtpmap"] = [NSMutableDictionary dictionary];
            current[@"fmtp"] = [NSMutableDictionary dictionary];
            current[@"mid"] = [NSString stringWithFormat:@"%lu", (unsigned long)sections.count];
            [sections addObject:current];
            continue;
        }
        if (![line hasPrefix:@"a="]) continue;
        NSString *attr = [line substringFromIndex:2];
        NSRange colon = [attr rangeOfString:@":"];
        NSString *name = colon.location == NSNotFound ? attr : [attr substringToIndex:colon.location];
        NSString *value = colon.location == NSNotFound ? @"" : [attr substringFromIndex:colon.location + 1];
        if ([name isEqualToString:@"ice-ufrag"] && !o.iceUfrag.length) o.iceUfrag = value;
        else if ([name isEqualToString:@"ice-pwd"] && !o.icePwd.length) o.icePwd = value;
        else if ([name isEqualToString:@"fingerprint"] && !o.fingerprint.length) o.fingerprint = value;
        else if ([name isEqualToString:@"candidate"]) {
            NSMutableArray *parts = [[value componentsSeparatedByString:@" "] mutableCopy];
            if (parts.count >= 8 && ip.length && ([parts[4] isEqualToString:@"0.0.0.0"] || [parts[4] isEqualToString:@"127.0.0.1"])) parts[4] = ip;
            if (parts.count >= 3 && [[parts[2] lowercaseString] isEqualToString:@"tcp"]) continue;
            [candidates addObject:[@"candidate:" stringByAppendingString:[parts componentsJoinedByString:@" "]]];
        }
        else if ([name hasPrefix:@"ri."]) {
            NSString *v = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            unsigned long long n = 0;
            if ([v hasPrefix:@"0x"] || [v hasPrefix:@"0X"]) { NSScanner *sc = [NSScanner scannerWithString:[v substringFromIndex:2]]; [sc scanHexLongLong:&n]; }
            else n = (unsigned long long)[v longLongValue];
            if ([name isEqualToString:@"ri.partialReliableThresholdMs"] && n > 0) o.riPartialReliableThresholdMs = (NSInteger)MIN(5000ULL, n);
            else if ([name isEqualToString:@"ri.hidDeviceMask"]) o.riHidDeviceMask = (uint32_t)n;
            else if ([name isEqualToString:@"ri.enablePartiallyReliableTransferGamepad"]) o.riPartialReliableGamepadMask = (uint32_t)n;
            else if ([name isEqualToString:@"ri.enablePartiallyReliableTransferHid"]) o.riPartialReliableHidMask = (uint32_t)n;
        }
        if (!current) continue;
        if ([name isEqualToString:@"mid"]) current[@"mid"] = value;
        else if ([name isEqualToString:@"rtpmap"]) {
            NSRange sp = [value rangeOfString:@" "];
            if (sp.location != NSNotFound) current[@"rtpmap"][[value substringToIndex:sp.location]] = [value substringFromIndex:sp.location + 1];
        } else if ([name isEqualToString:@"fmtp"]) {
            NSRange sp = [value rangeOfString:@" "];
            if (sp.location != NSNotFound) current[@"fmtp"][[value substringToIndex:sp.location]] = [value substringFromIndex:sp.location + 1];
        } else if ([name isEqualToString:@"sctp-port"]) {
            current[@"sctpPort"] = @([value integerValue]);
        } else if ([name isEqualToString:@"sctpmap"]) {
            current[@"sctpPort"] = @([[value componentsSeparatedByString:@" "].firstObject integerValue]);
        } else if ([name isEqualToString:@"ssrc"]) {
            NSString *first = [value componentsSeparatedByString:@" "].firstObject;
            if (!current[@"ssrc"]) current[@"ssrc"] = @([first longLongValue]);
        } else if ([name isEqualToString:@"sendonly"] || [name isEqualToString:@"recvonly"] || [name isEqualToString:@"sendrecv"] || [name isEqualToString:@"inactive"]) {
            current[@"direction"] = name;
        }
    }
    o.sections = sections;
    o.candidates = candidates;

    // codecs: the first H.264 payload type with packetization-mode=1 (else the first H.264 at all), opus and its RED
    BOOL videoSeen = NO, audioSeen = NO;
    for (NSDictionary *s in sections) {
        NSString *type = s[@"type"];
        NSDictionary *rtpmap = s[@"rtpmap"], *fmtp = s[@"fmtp"];
        if ([type isEqualToString:@"video"] && !videoSeen) {
            videoSeen = YES;
            NSInteger fallback = -1;
            for (NSString *pt in s[@"ptypes"]) {
                NSString *codec = [[rtpmap[pt] componentsSeparatedByString:@"/"].firstObject uppercaseString];
                if (![codec isEqualToString:@"H264"]) continue;
                NSString *params = fmtp[pt] ?: @"";
                if (fallback < 0) fallback = [pt integerValue];
                if ([params rangeOfString:@"packetization-mode=1"].location != NSNotFound) { o.h264PayloadType = [pt integerValue]; o.h264Fmtp = params; break; }
            }
            if (o.h264PayloadType < 0 && fallback >= 0) { o.h264PayloadType = fallback; o.h264Fmtp = fmtp[[NSString stringWithFormat:@"%ld", (long)fallback]]; }
            if (s[@"ssrc"]) o.videoSSRC = (uint32_t)[s[@"ssrc"] longLongValue];
        } else if ([type isEqualToString:@"audio"] && !audioSeen) {
            audioSeen = YES;
            for (NSString *pt in s[@"ptypes"]) {
                NSString *codec = [[rtpmap[pt] componentsSeparatedByString:@"/"].firstObject uppercaseString];
                if ([codec isEqualToString:@"OPUS"] && o.opusPayloadType < 0) { o.opusPayloadType = [pt integerValue]; o.opusFmtp = fmtp[pt]; }
                else if ([codec isEqualToString:@"RED"] && o.redPayloadType < 0) o.redPayloadType = [pt integerValue];
            }
            if (s[@"ssrc"]) o.audioSSRC = (uint32_t)[s[@"ssrc"] longLongValue];
        } else if ([type isEqualToString:@"application"]) {
            if (s[@"sctpPort"]) o.sctpPort = [s[@"sctpPort"] integerValue];
        }
    }
    return o;
}

@end

@implementation GFSDP

+ (NSString *)randomICEString:(NSUInteger)length
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    uint8_t bytes[64];
    if (length > sizeof(bytes)) length = sizeof(bytes);
    if (SecRandomCopyBytes(kSecRandomDefault, length, bytes) != 0) for (NSUInteger i = 0; i < length; i++) bytes[i] = (uint8_t)arc4random_uniform(256);
    char out[65];
    for (NSUInteger i = 0; i < length; i++) out[i] = alphabet[bytes[i] & 63];
    out[length] = 0;
    return [NSString stringWithUTF8String:out];
}

+ (NSString *)publicIPFromHost:(NSString *)host
{
    if (!host.length) return nil;
    NSArray *dots = [host componentsSeparatedByString:@"."];
    BOOL numeric = dots.count == 4;
    for (NSString *p in dots) if (!p.length || p.length > 3 || [p rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) numeric = NO;
    if (numeric) return host;
    NSArray *dashes = [dots.firstObject componentsSeparatedByString:@"-"];
    if (dashes.count != 4) return nil;
    for (NSString *p in dashes) if (!p.length || p.length > 3 || [p rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return nil;
    return [dashes componentsJoinedByString:@"."];
}

+ (NSString *)answerForOffer:(GFSDPOffer *)offer iceUfrag:(NSString *)ufrag icePwd:(NSString *)pwd
                 fingerprint:(NSString *)fingerprint videoKbps:(NSInteger)videoKbps
{
    NSMutableArray *lines = [NSMutableArray array];
    NSMutableArray *bundle = [NSMutableArray array];
    NSMutableArray *media = [NSMutableArray array];
    BOOL audioDone = NO, videoDone = NO, appDone = NO;
    NSArray *transport = @[ [@"a=ice-ufrag:" stringByAppendingString:ufrag], [@"a=ice-pwd:" stringByAppendingString:pwd],
                            @"a=ice-options:trickle", [@"a=fingerprint:sha-256 " stringByAppendingString:fingerprint], @"a=setup:active" ];
    for (NSDictionary *s in offer.sections) {
        NSString *type = s[@"type"], *mid = s[@"mid"], *proto = s[@"proto"];
        NSMutableArray *m = [NSMutableArray array];
        if ([type isEqualToString:@"audio"] && !audioDone && offer.opusPayloadType >= 0) {
            audioDone = YES;
            NSMutableArray *pts = [NSMutableArray arrayWithObject:@(offer.opusPayloadType).stringValue];
            if (offer.redPayloadType >= 0) [pts addObject:@(offer.redPayloadType).stringValue];
            [m addObject:[NSString stringWithFormat:@"m=audio 9 %@ %@", proto.length ? proto : @"UDP/TLS/RTP/SAVPF", [pts componentsJoinedByString:@" "]]];
            [m addObject:@"b=AS:256"];
            [m addObject:@"c=IN IP4 0.0.0.0"];
            [m addObject:@"a=rtcp:9 IN IP4 0.0.0.0"];
            [m addObjectsFromArray:transport];
            [m addObject:[@"a=mid:" stringByAppendingString:mid]];
            [m addObject:@"a=recvonly"];
            [m addObject:@"a=rtcp-mux"];
            [m addObject:[NSString stringWithFormat:@"a=rtpmap:%ld opus/48000/2", (long)offer.opusPayloadType]];
            NSString *fmtp = offer.opusFmtp.length ? offer.opusFmtp : @"minptime=10;useinbandfec=1";
            if ([fmtp rangeOfString:@"stereo=1"].location == NSNotFound) fmtp = [fmtp stringByAppendingString:@";stereo=1"];
            [m addObject:[NSString stringWithFormat:@"a=fmtp:%ld %@", (long)offer.opusPayloadType, fmtp]];
            if (offer.redPayloadType >= 0) {
                [m addObject:[NSString stringWithFormat:@"a=rtpmap:%ld red/48000/2", (long)offer.redPayloadType]];
                [m addObject:[NSString stringWithFormat:@"a=fmtp:%ld %ld/%ld", (long)offer.redPayloadType, (long)offer.opusPayloadType, (long)offer.opusPayloadType]];
            }
            [bundle addObject:mid];
        } else if ([type isEqualToString:@"video"] && !videoDone && offer.h264PayloadType >= 0) {
            videoDone = YES;
            [m addObject:[NSString stringWithFormat:@"m=video 9 %@ %ld", proto.length ? proto : @"UDP/TLS/RTP/SAVPF", (long)offer.h264PayloadType]];
            [m addObject:[NSString stringWithFormat:@"b=AS:%ld", (long)videoKbps]];
            [m addObject:@"c=IN IP4 0.0.0.0"];
            [m addObject:@"a=rtcp:9 IN IP4 0.0.0.0"];
            [m addObjectsFromArray:transport];
            [m addObject:[@"a=mid:" stringByAppendingString:mid]];
            [m addObject:@"a=recvonly"];
            [m addObject:@"a=rtcp-mux"];
            [m addObject:[NSString stringWithFormat:@"a=rtpmap:%ld H264/90000", (long)offer.h264PayloadType]];
            [m addObject:[NSString stringWithFormat:@"a=rtcp-fb:%ld nack", (long)offer.h264PayloadType]];
            [m addObject:[NSString stringWithFormat:@"a=rtcp-fb:%ld nack pli", (long)offer.h264PayloadType]];
            [m addObject:[NSString stringWithFormat:@"a=rtcp-fb:%ld goog-remb", (long)offer.h264PayloadType]];
            if (offer.h264Fmtp.length) [m addObject:[NSString stringWithFormat:@"a=fmtp:%ld %@", (long)offer.h264PayloadType, offer.h264Fmtp]];
            [bundle addObject:mid];
        } else if ([type isEqualToString:@"application"] && !appDone) {
            appDone = YES;
            BOOL oldStyle = [proto rangeOfString:@"webrtc-datachannel"].location == NSNotFound && ![s[@"ptypes"] containsObject:@"webrtc-datachannel"];
            if (oldStyle) {
                [m addObject:[NSString stringWithFormat:@"m=application 9 %@ %ld", proto.length ? proto : @"DTLS/SCTP", (long)offer.sctpPort]];
            } else {
                [m addObject:[NSString stringWithFormat:@"m=application 9 %@ webrtc-datachannel", proto.length ? proto : @"UDP/DTLS/SCTP"]];
            }
            [m addObject:@"c=IN IP4 0.0.0.0"];
            [m addObjectsFromArray:transport];
            [m addObject:[@"a=mid:" stringByAppendingString:mid]];
            if (oldStyle) [m addObject:[NSString stringWithFormat:@"a=sctpmap:%ld webrtc-datachannel 1024", (long)offer.sctpPort]];
            else [m addObject:[NSString stringWithFormat:@"a=sctp-port:%ld", (long)offer.sctpPort]];
            [m addObject:@"a=max-message-size:262144"];
            [bundle addObject:mid];
        } else {
            // the microphone and anything else: rejected
            NSString *pts = [s[@"ptypes"] componentsJoinedByString:@" "];
            [m addObject:[NSString stringWithFormat:@"m=%@ 0 %@%@%@", type, proto.length ? proto : @"UDP/TLS/RTP/SAVPF", pts.length ? @" " : @"", pts]];
            [m addObject:@"c=IN IP4 0.0.0.0"];
            [m addObjectsFromArray:transport];
            [m addObject:[@"a=mid:" stringByAppendingString:mid]];
            [m addObject:@"a=inactive"];
            NSDictionary *rtpmap = s[@"rtpmap"];
            for (NSString *pt in s[@"ptypes"]) if (rtpmap[pt]) [m addObject:[NSString stringWithFormat:@"a=rtpmap:%@ %@", pt, rtpmap[pt]]];
        }
        [media addObjectsFromArray:m];
    }
    [lines addObject:@"v=0"];
    [lines addObject:[NSString stringWithFormat:@"o=- %llu 2 IN IP4 127.0.0.1", (unsigned long long)arc4random() << 16 | arc4random_uniform(65536)]];
    [lines addObject:@"s=-"];
    [lines addObject:@"t=0 0"];
    if (bundle.count) [lines addObject:[@"a=group:BUNDLE " stringByAppendingString:[bundle componentsJoinedByString:@" "]]];
    [lines addObject:@"a=msid-semantic: WMS"];
    [lines addObjectsFromArray:media];
    return [[lines componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"];
}

+ (NSString *)nvstSDPForOffer:(GFSDPOffer *)offer iceUfrag:(NSString *)ufrag icePwd:(NSString *)pwd fingerprint:(NSString *)fingerprint
                        width:(NSInteger)width height:(NSInteger)height fps:(NSInteger)fps maxKbps:(NSInteger)maxKbps
{
    // the floor decides which axis a weak link degrades on: low, so congestion control spends bitrate before pixels
    NSInteger minKbps = MAX(3000, maxKbps * 25 / 100);
    NSInteger initialKbps = MAX(minKbps, maxKbps * 75 / 100);
    NSString *sdp = [NSString stringWithFormat:
        @"v=0\r\n"
        @"o=SdpTest test_id_13 14 IN IPv4 127.0.0.1\r\n"
        @"s=-\r\n"
        @"t=0 0\r\n"
        @"a=general.icePassword:%@\r\n"
        @"a=general.iceUserNameFragment:%@\r\n"
        @"a=general.dtlsFingerprint:sha-256 %@\r\n"
        @"m=video 0 RTP/AVP\r\n"
        @"a=msid:fbc-video-0\r\n"
        @"a=vqos.fec.rateDropWindow:10\r\n"
        @"a=vqos.fec.minRequiredFecPackets:2\r\n"
        @"a=vqos.drc.minRequiredBitrateCheckEnabled:1\r\n"
        @"a=vqos.fec.repairMinPercent:6\r\n"
        @"a=vqos.fec.repairPercent:8\r\n"
        @"a=vqos.fec.repairMaxPercent:30\r\n"
        @"a=vqos.dynamicStreamingMode:0\r\n"
        @"a=vqos.drc.enable:0\r\n"
        @"a=vqos.dfc.enable:0\r\n"
        @"a=vqos.dfc.adjustResAndFps:0\r\n"
        @"a=vqos.resControl.cpmRtc.enable:0\r\n"
        @"a=vqos.resControl.cpmRtc.featureMask:0\r\n"
        @"a=vqos.resControl.cpmRtc.minResolutionPercent:100\r\n"
        @"a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999\r\n"
        @"a=vqos.drc.qpMaxResThresholdAdj:4\r\n"
        @"a=vqos.grc.qpMaxResThresholdAdj:4\r\n"
        @"a=vqos.drc.iirFilterFactor:100\r\n"
        @"a=vqos.grc.enable:0\r\n"
        @"a=vqos.grc.maximumBitrateKbps:%ld\r\n"
        @"a=vqos.adjustStreamingFpsDuringOutOfFocus:1\r\n"
        @"a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1\r\n"
        @"a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1\r\n"
        @"a=video.dx9EnableNv12:1\r\n"
        @"a=video.dx9EnableHdr:1\r\n"
        @"a=vqos.qpg.enable:1\r\n"
        @"a=vqos.resControl.qp.qpg.featureSetting:7\r\n"
        @"a=bwe.useOwdCongestionControl:1\r\n"
        @"a=video.enableRtpNack:1\r\n"
        @"a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200\r\n"
        @"a=vqos.drc.bitrateIirFilterFactor:18\r\n"
        @"a=video.packetSize:1140\r\n"
        @"a=video.rtpNackQueueLength:1024\r\n"
        @"a=video.rtpNackQueueMaxPackets:512\r\n"
        @"a=video.rtpNackMaxPacketCount:25\r\n"
        @"a=packetPacing.numGroups:6\r\n"
        @"a=packetPacing.minNumPacketsPerGroup:10\r\n"
        @"a=packetPacing.minNumPacketsFrame:10\r\n"
        @"a=packetPacing.maxDelayUs:1250\r\n"
        @"a=video.mapRtpTimestampsToFrames:1\r\n"
        @"a=video.encoderCscMode:3\r\n"
        @"a=video.dynamicRangeMode:0\r\n"
        @"a=video.bitDepth:8\r\n"
        @"a=video.scalingFeature1:0\r\n"
        @"a=video.prefilterParams.prefilterModel:0\r\n"
        @"a=vqos.bllFec.enable:0\r\n"
        @"a=video.clientViewportWd:%ld\r\n"
        @"a=video.clientViewportHt:%ld\r\n"
        @"a=video.maxFPS:%ld\r\n"
        @"a=video.maxNumReferenceFrames:1\r\n"
        @"a=video.initialBitrateKbps:%ld\r\n"
        @"a=video.initialPeakBitrateKbps:%ld\r\n"
        @"a=vqos.bw.maximumBitrateKbps:%ld\r\n"
        @"a=vqos.bw.minimumBitrateKbps:%ld\r\n"
        @"a=vqos.bw.peakBitrateKbps:%ld\r\n"
        @"a=vqos.bw.serverPeakBitrateKbps:%ld\r\n"
        @"a=vqos.bw.enableBandwidthEstimation:1\r\n"
        @"a=vqos.bw.disableBitrateLimit:0\r\n"
        @"m=audio 0 RTP/AVP\r\n"
        @"a=msid:audio\r\n"
        @"m=application 0 RTP/AVP\r\n"
        @"a=msid:input_1\r\n"
        @"a=ri.partialReliableThresholdMs:%ld\r\n"
        @"a=ri.hidDeviceMask:%u\r\n"
        @"a=ri.enablePartiallyReliableTransferGamepad:%u\r\n"
        @"a=ri.enablePartiallyReliableTransferHid:%u\r\n",
        pwd, ufrag, fingerprint,
        (long)maxKbps,
        (long)width, (long)height, (long)fps,
        (long)initialKbps, (long)maxKbps, (long)maxKbps, (long)minKbps, (long)maxKbps, (long)maxKbps,
        (long)offer.riPartialReliableThresholdMs, (unsigned)offer.riHidDeviceMask, (unsigned)offer.riPartialReliableGamepadMask, (unsigned)offer.riPartialReliableHidMask];
    return sdp;
}

@end
