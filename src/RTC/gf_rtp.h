// RTP header parsing and the H.264 depacketizer (RFC 6184: single NAL units, STAP-A, FU-A) that turns packets
// into Annex B access units. Packets of a frame are held until the frame is complete, so retransmitted and
// reordered packets still find their place; a frame that never completes is handed over damaged once the next
// one is whole. Loss bookkeeping drives NACK and keyframe requests.
#ifndef GF_RTP_H
#define GF_RTP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t payload_type;
    int marker;
    uint16_t seq;
    uint32_t timestamp;
    uint32_t ssrc;
    const uint8_t *payload;
    size_t payload_len;
} gf_rtp_header;

// 0 on success (payload points into pkt, padding removed), -1 for a malformed packet
int gf_rtp_parse(const uint8_t *pkt, size_t len, gf_rtp_header *h);

// An access unit ready for the decoder (Annex B, 4-byte start codes). keyframe: contains an IDR slice.
// damaged: packets were missing while it was assembled (a keyframe has been requested).
typedef void (*gf_h264_au_cb)(void *ctx, const uint8_t *au, size_t len, uint32_t rtp_ts, int keyframe, int damaged);

#define GF_FRAME_MAX_PACKETS 512

typedef struct {
    uint16_t seq;
    uint16_t len;
    int marker;
    uint8_t *data;
} gf_rtp_pkt;

typedef struct {
    int active;
    uint32_t ts;
    gf_rtp_pkt pkts[GF_FRAME_MAX_PACKETS];
    int count;
    int has_marker;
    uint16_t marker_seq;
    uint16_t min_seq;
} gf_h264_frame;

typedef struct {
    uint8_t *buf;
    size_t len, cap;
    gf_h264_frame frames[2];
    uint16_t next_seq;            // the first sequence number of the next frame to deliver
    int have_seq;
    uint16_t highest_seq;
    int have_highest;
    uint64_t frames, dropped;     // frames delivered / of which damaged
    uint64_t packets, lost;
    uint16_t missing[64];         // recent gaps, for NACK
    int missing_count;
} gf_h264_depack;

void gf_h264_init(gf_h264_depack *d);
void gf_h264_free(gf_h264_depack *d);
void gf_h264_reset(gf_h264_depack *d);
// Feeds one packet; calls cb for every frame that becomes deliverable. Returns the number of sequence numbers
// found missing just before this packet (0 normally).
int gf_h264_push(gf_h264_depack *d, const gf_rtp_header *h, gf_h264_au_cb cb, void *ctx);
// Takes the missing sequence numbers accumulated since the last call (for a NACK); returns the count.
int gf_h264_take_missing(gf_h264_depack *d, uint16_t *out, int cap);

// Finds the SPS and PPS NAL units in an Annex B access unit (pointers into au, lengths without start codes)
int gf_h264_find_parameter_sets(const uint8_t *au, size_t len, const uint8_t **sps, size_t *sps_len, const uint8_t **pps, size_t *pps_len);
// The coded picture size from an SPS NAL unit (with its header byte, without start code). 1 on success.
int gf_h264_sps_dimensions(const uint8_t *sps, size_t len, int *width, int *height);
// Rewrites an Annex B access unit into AVCC (4-byte big-endian lengths), dropping SPS/PPS/AUD NAL units.
// out may equal au (in place). Returns the new length.
size_t gf_h264_annexb_to_avcc(const uint8_t *au, size_t len, uint8_t *out, size_t cap);

#ifdef __cplusplus
}
#endif
#endif
