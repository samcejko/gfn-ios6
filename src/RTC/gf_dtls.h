// DTLS 1.2 client on mbedTLS for WebRTC: a self-signed certificate made on the device, the use_srtp extension
// (SRTP keys exported after the handshake), application data for SCTP. Non-blocking: the owner feeds datagrams
// and ticks the retransmission timer.
#ifndef GF_DTLS_H
#define GF_DTLS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct gf_dtls gf_dtls;

typedef struct {
    void *ctx;
    int (*send)(void *ctx, const uint8_t *data, size_t len);      // one datagram to the peer
} gf_dtls_io;

// Makes the key pair and certificate (a second or so on an A5). NULL on failure.
gf_dtls *gf_dtls_create(void);
void gf_dtls_destroy(gf_dtls *d);

// "AB:CD:..." SHA-256 of our certificate, for the SDP answer
const char *gf_dtls_fingerprint(gf_dtls *d);

// Starts the handshake as the client. expected_fingerprint is the offer's "sha-256 AB:CD:..." value (checked after
// the handshake; pass NULL to skip). Returns 0 or -1.
int gf_dtls_start(gf_dtls *d, const gf_dtls_io *io, const char *expected_fingerprint, uint64_t now_us);
// Feeds a received DTLS datagram. Returns 1 when the handshake has just completed, 0 otherwise, -1 on a fatal error.
int gf_dtls_input(gf_dtls *d, const uint8_t *pkt, size_t len, uint64_t now_us);
// Runs the retransmission timer. Same return values as gf_dtls_input.
int gf_dtls_tick(gf_dtls *d, uint64_t now_us);
uint64_t gf_dtls_next_timeout(gf_dtls *d);          // UINT64_MAX = none
int gf_dtls_is_connected(const gf_dtls *d);
const char *gf_dtls_last_error(const gf_dtls *d);

// Application data received (call until it returns 0 after each input); -1 when the peer closed
int gf_dtls_read(gf_dtls *d, uint8_t *out, size_t cap);
int gf_dtls_write(gf_dtls *d, const uint8_t *data, size_t len);

// After the handshake: the SRTP master keys of both directions. tag_len is 10 or 4 by the negotiated profile.
int gf_dtls_srtp_keys(gf_dtls *d, uint8_t client_key[16], uint8_t server_key[16], uint8_t client_salt[14], uint8_t server_salt[14], int *tag_len);

#ifdef __cplusplus
}
#endif
#endif
