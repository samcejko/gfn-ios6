// STUN for ICE connectivity checks (RFC 5389 / 8445): Binding requests with the ICE attributes, responses,
// MESSAGE-INTEGRITY (HMAC-SHA1) and FINGERPRINT. Plain C, no allocation.
#ifndef GF_STUN_H
#define GF_STUN_H

#include <stdint.h>
#include <stddef.h>

#define GF_STUN_BINDING_REQUEST  0x0001
#define GF_STUN_BINDING_SUCCESS  0x0101
#define GF_STUN_BINDING_ERROR    0x0111

#ifdef __cplusplus
extern "C" {
#endif

// 1 when the datagram looks like STUN (first two bits 00, magic cookie in place)
int gf_stun_is_stun(const uint8_t *p, size_t n);

// A Binding request. username is "remoteUfrag:localUfrag", pwd the remote ICE password (the integrity key).
// Returns the length written, 0 when the buffer is too small.
size_t gf_stun_build_request(uint8_t *out, size_t cap, const uint8_t tid[12], const char *username, const char *pwd,
                             uint32_t priority, uint64_t tiebreaker, int use_candidate);

// A Binding success response to a request with the given transaction id; the mapped address is the sender's.
size_t gf_stun_build_response(uint8_t *out, size_t cap, const uint8_t tid[12], uint32_t peer_ip, uint16_t peer_port, const char *pwd);

typedef struct {
    int type;                   // GF_STUN_BINDING_*
    uint8_t tid[12];
    int has_mapped;
    uint32_t mapped_ip;         // host order
    uint16_t mapped_port;
    char username[128];
    int error_code;
    int integrity_ok;           // 1 verified with pwd, 0 absent/not checked, -1 wrong
    int use_candidate;
} gf_stun_info;

// Parses a message; verifies MESSAGE-INTEGRITY with pwd when both are present. Returns 0, or -1 for garbage.
int gf_stun_parse(const uint8_t *p, size_t n, const char *pwd, gf_stun_info *info);

#ifdef __cplusplus
}
#endif
#endif
