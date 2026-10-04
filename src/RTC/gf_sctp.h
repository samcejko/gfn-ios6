// A small SCTP association (RFC 4960) for WebRTC data channels over DTLS, with the data channel
// establishment protocol (RFC 8832). Reliable ordered/unordered messages, SACK, retransmission, heartbeats.
// Single threaded: the owner feeds packets and ticks the clock.
#ifndef GF_SCTP_H
#define GF_SCTP_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define GF_SCTP_PPID_DCEP    50
#define GF_SCTP_PPID_STRING  51
#define GF_SCTP_PPID_BINARY  53
#define GF_SCTP_PPID_STRING_EMPTY 56
#define GF_SCTP_PPID_BINARY_EMPTY 57

typedef struct gf_sctp gf_sctp;

typedef struct {
    void *ctx;
    int (*send)(void *ctx, const uint8_t *pkt, size_t len);                           // hand a packet to DTLS
    void (*on_connected)(void *ctx);
    void (*on_channel_open)(void *ctx, uint16_t stream, const char *label, const char *protocol); // the peer opened one
    void (*on_channel_ack)(void *ctx, uint16_t stream);                               // our open was acknowledged
    void (*on_message)(void *ctx, uint16_t stream, uint32_t ppid, const uint8_t *data, size_t len);
    void (*on_closed)(void *ctx, const char *reason);
} gf_sctp_callbacks;

gf_sctp *gf_sctp_create(uint16_t local_port, uint16_t remote_port, const gf_sctp_callbacks *cb, uint64_t now_us);
void gf_sctp_destroy(gf_sctp *s);

void gf_sctp_connect(gf_sctp *s, uint64_t now_us);                 // sends INIT
void gf_sctp_input(gf_sctp *s, const uint8_t *pkt, size_t len, uint64_t now_us);
void gf_sctp_tick(gf_sctp *s, uint64_t now_us);                    // retransmissions and timers
uint64_t gf_sctp_next_timeout(const gf_sctp *s);                   // when tick wants to run next (UINT64_MAX = never)
int gf_sctp_is_connected(const gf_sctp *s);

// Opens a data channel on `stream` (DCEP): reliability 0 = reliable, 1 = max retransmissions, 2 = max lifetime ms
int gf_sctp_open_channel(gf_sctp *s, uint16_t stream, const char *label, const char *protocol, int ordered, int reliability, uint32_t reliability_param);
int gf_sctp_send(gf_sctp *s, uint16_t stream, uint32_t ppid, const uint8_t *data, size_t len, int ordered);
void gf_sctp_shutdown(gf_sctp *s);

// Statistics
uint64_t gf_sctp_retransmits(const gf_sctp *s);
int gf_sctp_rto_ms(const gf_sctp *s);

uint32_t gf_crc32c(const uint8_t *data, size_t len);
int gf_sctp_selftest(void);

#ifdef __cplusplus
}
#endif
#endif
