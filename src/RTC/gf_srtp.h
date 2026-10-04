// SRTP / SRTCP (RFC 3711) with AES-128 counter mode and HMAC-SHA1 (the DTLS-SRTP profiles
// SRTP_AES128_CM_HMAC_SHA1_80 / _32), on mbedTLS primitives. Receive direction for RTP, both for RTCP.
#ifndef GF_SRTP_H
#define GF_SRTP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t key[16], salt[14], auth[20];
    uint8_t rtcp_key[16], rtcp_salt[14], rtcp_auth[20];
    int tag_len;                 // 10 (SHA1_80) or 4 (SHA1_32)
    uint32_t rtcp_index;         // next SRTCP index for the send direction
} gf_srtp_session;

// Per-SSRC receive state (rollover counter)
typedef struct {
    uint32_t ssrc;
    uint32_t roc;
    uint16_t s_l;
    int started;
} gf_srtp_stream;

// Derives the session keys from the 16-byte master key and 14-byte master salt (key derivation rate 0)
int gf_srtp_init(gf_srtp_session *s, const uint8_t *master_key, const uint8_t *master_salt, int tag_len);

// Authenticates and decrypts one SRTP packet in place. Returns the plain RTP length, or -1 (bad tag / short).
int gf_srtp_unprotect(gf_srtp_session *s, gf_srtp_stream *st, uint8_t *pkt, size_t len);

// Encrypts and tags one RTCP compound packet in place (cap must leave room for 4 + tag_len bytes). Returns the new length.
int gf_srtp_protect_rtcp(gf_srtp_session *s, uint8_t *pkt, size_t len, size_t cap);

// Authenticates and decrypts an incoming SRTCP packet in place. Returns the plain length or -1.
int gf_srtp_unprotect_rtcp(gf_srtp_session *s, uint8_t *pkt, size_t len);

// Self test against the RFC 3711 key derivation vectors (returns 1 when they match)
int gf_srtp_selftest(void);

#ifdef __cplusplus
}
#endif
#endif
