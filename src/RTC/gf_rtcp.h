// RTCP builders: receiver reports, and the feedback the server listens to (NACK, PLI, REMB).
#ifndef GF_RTCP_H
#define GF_RTCP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// RR with one report block (or none when media_ssrc is 0). Returns the length (multiple of 4).
size_t gf_rtcp_build_rr(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc, uint8_t fraction_lost,
                        int32_t cumulative_lost, uint32_t extended_highest_seq, uint32_t jitter, uint32_t lsr, uint32_t dlsr);
size_t gf_rtcp_build_pli(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc);
// Generic NACK: the sequence numbers are packed into PID/BLP pairs
size_t gf_rtcp_build_nack(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc, const uint16_t *seqs, size_t count);
size_t gf_rtcp_build_remb(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc, uint64_t bitrate_bps);

// Reads the first packet's type and (for SR) the NTP middle 32 bits, for the LSR of our reports
int gf_rtcp_parse_sr(const uint8_t *pkt, size_t len, uint32_t *sender_ssrc, uint32_t *ntp_middle);

#ifdef __cplusplus
}
#endif
#endif
