#define MBEDTLS_ALLOW_PRIVATE_ACCESS
#include "gf_dtls.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <sys/time.h>
#include "mbedtls/ssl.h"
#include "mbedtls/net_sockets.h"
#include "mbedtls/entropy.h"
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/x509_crt.h"
#include "mbedtls/pk.h"
#include "mbedtls/ecp.h"
#include "mbedtls/sha256.h"
#include "mbedtls/error.h"
#include "psa/crypto.h"

struct gf_dtls {
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_pk_context key;
    mbedtls_x509_crt cert;
    mbedtls_ssl_config conf;
    mbedtls_ssl_context ssl;
    gf_dtls_io io;
    char fingerprint[96];
    char expected[96];
    char error[160];
    int started, connected, failed;
    // the datagram being fed to mbedTLS
    const uint8_t *pending;
    size_t pending_len;
    // timer
    uint64_t timer_start_us;
    uint32_t timer_int_ms, timer_fin_ms;
    int timer_set;
    // exported keying material
    unsigned char master_secret[48];
    size_t master_secret_len;
    unsigned char randoms[64];
    mbedtls_tls_prf_types prf;
    int have_secret;
};

static const mbedtls_ssl_srtp_profile k_profiles[] = {
    MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_80,
    MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_32,
    MBEDTLS_TLS_SRTP_UNSET
};

static uint64_t now_us(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

static void set_error(gf_dtls *d, const char *what, int rc)
{
    char buf[100];
    mbedtls_strerror(rc, buf, sizeof(buf));
    snprintf(d->error, sizeof(d->error), "%s: %s (-0x%04x)", what, buf, (unsigned)-rc);
}

/* ---- bio and timer callbacks ---- */

static int bio_send(void *ctx, const unsigned char *buf, size_t len)
{
    gf_dtls *d = (gf_dtls *)ctx;
    if (!d->io.send) return MBEDTLS_ERR_NET_SEND_FAILED;
    if (d->io.send(d->io.ctx, buf, len) < 0) return MBEDTLS_ERR_NET_SEND_FAILED;
    return (int)len;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len)
{
    gf_dtls *d = (gf_dtls *)ctx;
    if (!d->pending_len) return MBEDTLS_ERR_SSL_WANT_READ;
    size_t n = d->pending_len < len ? d->pending_len : len;
    memcpy(buf, d->pending, n);
    d->pending_len = 0;        // a datagram is consumed whole
    d->pending = NULL;
    return (int)n;
}

static void timer_set(void *ctx, uint32_t int_ms, uint32_t fin_ms)
{
    gf_dtls *d = (gf_dtls *)ctx;
    d->timer_int_ms = int_ms;
    d->timer_fin_ms = fin_ms;
    d->timer_start_us = now_us();
    d->timer_set = fin_ms != 0;
}

static int timer_get(void *ctx)
{
    gf_dtls *d = (gf_dtls *)ctx;
    if (!d->timer_set) return -1;
    uint64_t elapsed_ms = (now_us() - d->timer_start_us) / 1000;
    if (elapsed_ms >= d->timer_fin_ms) return 2;
    if (elapsed_ms >= d->timer_int_ms) return 1;
    return 0;
}

static void export_keys(void *p, mbedtls_ssl_key_export_type type, const unsigned char *secret, size_t secret_len,
                        const unsigned char client_random[32], const unsigned char server_random[32], mbedtls_tls_prf_types prf)
{
    gf_dtls *d = (gf_dtls *)p;
    if (type != MBEDTLS_SSL_KEY_EXPORT_TLS12_MASTER_SECRET || secret_len > sizeof(d->master_secret)) return;
    memcpy(d->master_secret, secret, secret_len);
    d->master_secret_len = secret_len;
    memcpy(d->randoms, client_random, 32);
    memcpy(d->randoms + 32, server_random, 32);
    d->prf = prf;
    d->have_secret = 1;
}

/* ---- certificate ---- */

static void hex_fingerprint(const unsigned char *der, size_t len, char *out, size_t cap)
{
    unsigned char hash[32];
    mbedtls_sha256(der, len, hash, 0);
    size_t o = 0;
    for (int i = 0; i < 32 && o + 3 < cap; i++) {
        o += (size_t)snprintf(out + o, cap - o, "%02X%s", hash[i], i < 31 ? ":" : "");
    }
}

static int make_certificate(gf_dtls *d)
{
    int rc;
    mbedtls_x509write_cert w;
    unsigned char der[2048];
    unsigned char serial[8];

    mbedtls_pk_init(&d->key);
    if ((rc = mbedtls_pk_setup(&d->key, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY))) != 0) { set_error(d, "pk_setup", rc); return -1; }
    if ((rc = mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(d->key), mbedtls_ctr_drbg_random, &d->drbg)) != 0) { set_error(d, "ecp_gen_key", rc); return -1; }

    mbedtls_x509write_crt_init(&w);
    mbedtls_x509write_crt_set_version(&w, MBEDTLS_X509_CRT_VERSION_3);
    mbedtls_x509write_crt_set_md_alg(&w, MBEDTLS_MD_SHA256);
    mbedtls_x509write_crt_set_subject_key(&w, &d->key);
    mbedtls_x509write_crt_set_issuer_key(&w, &d->key);
    mbedtls_ctr_drbg_random(&d->drbg, serial, sizeof(serial));
    serial[0] &= 0x7f;
    if ((rc = mbedtls_x509write_crt_set_serial_raw(&w, serial, sizeof(serial))) != 0 ||
        (rc = mbedtls_x509write_crt_set_subject_name(&w, "CN=GFN6")) != 0 ||
        (rc = mbedtls_x509write_crt_set_issuer_name(&w, "CN=GFN6")) != 0 ||
        (rc = mbedtls_x509write_crt_set_validity(&w, "20240101000000", "20401231235959")) != 0) {
        set_error(d, "x509write setup", rc);
        mbedtls_x509write_crt_free(&w);
        return -1;
    }
    rc = mbedtls_x509write_crt_der(&w, der, sizeof(der), mbedtls_ctr_drbg_random, &d->drbg);
    mbedtls_x509write_crt_free(&w);
    if (rc < 0) { set_error(d, "x509write_crt_der", rc); return -1; }
    size_t len = (size_t)rc;
    const unsigned char *start = der + sizeof(der) - len;
    mbedtls_x509_crt_init(&d->cert);
    if ((rc = mbedtls_x509_crt_parse_der(&d->cert, start, len)) != 0) { set_error(d, "x509_crt_parse_der", rc); return -1; }
    hex_fingerprint(start, len, d->fingerprint, sizeof(d->fingerprint));
    return 0;
}

gf_dtls *gf_dtls_create(void)
{
    gf_dtls *d = (gf_dtls *)calloc(1, sizeof(gf_dtls));
    if (!d) return NULL;
    psa_crypto_init();
    mbedtls_entropy_init(&d->entropy);
    mbedtls_ctr_drbg_init(&d->drbg);
    int rc = mbedtls_ctr_drbg_seed(&d->drbg, mbedtls_entropy_func, &d->entropy, (const unsigned char *)"gfn6-dtls", 9);
    if (rc != 0) { set_error(d, "ctr_drbg_seed", rc); gf_dtls_destroy(d); return NULL; }
    if (make_certificate(d) != 0) { gf_dtls_destroy(d); return NULL; }
    mbedtls_ssl_config_init(&d->conf);
    mbedtls_ssl_init(&d->ssl);
    return d;
}

void gf_dtls_destroy(gf_dtls *d)
{
    if (!d) return;
    mbedtls_ssl_free(&d->ssl);
    mbedtls_ssl_config_free(&d->conf);
    mbedtls_x509_crt_free(&d->cert);
    mbedtls_pk_free(&d->key);
    mbedtls_ctr_drbg_free(&d->drbg);
    mbedtls_entropy_free(&d->entropy);
    free(d);
}

const char *gf_dtls_fingerprint(gf_dtls *d) { return d->fingerprint; }
int gf_dtls_is_connected(const gf_dtls *d) { return d->connected; }
const char *gf_dtls_last_error(const gf_dtls *d) { return d->error; }

/* ---- handshake ---- */

int gf_dtls_start(gf_dtls *d, const gf_dtls_io *io, const char *expected_fingerprint, uint64_t now)
{
    int rc;
    (void)now;
    d->io = *io;
    if (expected_fingerprint) {
        // "sha-256 AB:CD:..." - drop the algorithm, normalize to upper case hex and colons
        const char *space = strrchr(expected_fingerprint, ' ');
        const char *start = space ? space + 1 : expected_fingerprint;
        size_t o = 0;
        for (const char *p = start; *p && o + 1 < sizeof(d->expected); p++) {
            char c = *p;
            if (c >= 'a' && c <= 'f') c = (char)(c - 'a' + 'A');
            if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F') || c == ':') d->expected[o++] = c;
        }
        d->expected[o] = 0;
    }
    if ((rc = mbedtls_ssl_config_defaults(&d->conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_DATAGRAM, MBEDTLS_SSL_PRESET_DEFAULT)) != 0) {
        set_error(d, "ssl_config_defaults", rc);
        return -1;
    }
    mbedtls_ssl_conf_authmode(&d->conf, MBEDTLS_SSL_VERIFY_NONE);     // the fingerprint from the SDP is what matters
    mbedtls_ssl_conf_rng(&d->conf, mbedtls_ctr_drbg_random, &d->drbg);
    mbedtls_ssl_conf_handshake_timeout(&d->conf, 500, 6000);
    mbedtls_ssl_conf_min_tls_version(&d->conf, MBEDTLS_SSL_VERSION_TLS1_2);
    mbedtls_ssl_conf_max_tls_version(&d->conf, MBEDTLS_SSL_VERSION_TLS1_2);
    if ((rc = mbedtls_ssl_conf_own_cert(&d->conf, &d->cert, &d->key)) != 0) { set_error(d, "conf_own_cert", rc); return -1; }
    if ((rc = mbedtls_ssl_conf_dtls_srtp_protection_profiles(&d->conf, k_profiles)) != 0) { set_error(d, "conf_dtls_srtp", rc); return -1; }
    mbedtls_ssl_conf_srtp_mki_value_supported(&d->conf, MBEDTLS_SSL_DTLS_SRTP_MKI_UNSUPPORTED);
    if ((rc = mbedtls_ssl_setup(&d->ssl, &d->conf)) != 0) { set_error(d, "ssl_setup", rc); return -1; }
    mbedtls_ssl_set_mtu(&d->ssl, 1200);
    mbedtls_ssl_set_bio(&d->ssl, d, bio_send, bio_recv, NULL);
    mbedtls_ssl_set_timer_cb(&d->ssl, d, timer_set, timer_get);
    mbedtls_ssl_set_export_keys_cb(&d->ssl, export_keys, d);
    d->started = 1;
    return gf_dtls_tick(d, now) < 0 ? -1 : 0;
}

static int finish_handshake(gf_dtls *d)
{
    if (d->expected[0]) {
        const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&d->ssl);
        if (!peer) { snprintf(d->error, sizeof(d->error), "no peer certificate"); return -1; }
        char fp[96];
        hex_fingerprint(peer->raw.p, peer->raw.len, fp, sizeof(fp));
        if (strcmp(fp, d->expected) != 0) {
            snprintf(d->error, sizeof(d->error), "peer certificate fingerprint mismatch");
            return -1;
        }
    }
    mbedtls_dtls_srtp_info info;
    mbedtls_ssl_get_dtls_srtp_negotiation_result(&d->ssl, &info);
    if (info.chosen_dtls_srtp_profile == MBEDTLS_TLS_SRTP_UNSET) {
        snprintf(d->error, sizeof(d->error), "the server did not negotiate SRTP");
        return -1;
    }
    if (!d->have_secret) { snprintf(d->error, sizeof(d->error), "no master secret exported"); return -1; }
    d->connected = 1;
    return 1;
}

static int pump(gf_dtls *d)
{
    if (d->failed) return -1;
    if (d->connected) return 0;
    while (1) {
        int rc = mbedtls_ssl_handshake(&d->ssl);
        if (rc == 0) {
            int f = finish_handshake(d);
            if (f < 0) d->failed = 1;
            return f;
        }
        if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) return 0;
        if (rc == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) continue;
        set_error(d, "handshake", rc);
        d->failed = 1;
        return -1;
    }
}

int gf_dtls_input(gf_dtls *d, const uint8_t *pkt, size_t len, uint64_t now)
{
    (void)now;
    if (!d->started || d->failed) return -1;
    d->pending = pkt;
    d->pending_len = len;
    if (!d->connected) {
        int r = pump(d);
        d->pending = NULL;
        d->pending_len = 0;
        return r;
    }
    // application data: left in the pending slot for gf_dtls_read to consume
    return 0;
}

int gf_dtls_tick(gf_dtls *d, uint64_t now)
{
    (void)now;
    if (!d->started || d->failed) return d->failed ? -1 : 0;
    if (d->connected) return 0;
    if (!d->timer_set || timer_get(d) == 2 || d->ssl.state == MBEDTLS_SSL_HELLO_REQUEST) return pump(d);
    return 0;
}

uint64_t gf_dtls_next_timeout(gf_dtls *d)
{
    if (!d->started || d->connected || d->failed || !d->timer_set) return UINT64_MAX;
    uint64_t fin = d->timer_start_us + (uint64_t)d->timer_fin_ms * 1000;
    uint64_t n = now_us();
    return fin > n ? fin - n : 0;      // relative: how long from now
}

int gf_dtls_read(gf_dtls *d, uint8_t *out, size_t cap)
{
    if (!d->connected) return 0;
    int rc = mbedtls_ssl_read(&d->ssl, out, cap);
    if (rc > 0) return rc;
    if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) return 0;
    if (rc == 0 || rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) { snprintf(d->error, sizeof(d->error), "peer closed DTLS"); d->failed = 1; return -1; }
    if (rc == MBEDTLS_ERR_SSL_RECEIVED_NEW_SESSION_TICKET) return 0;
    set_error(d, "read", rc);
    return 0;      // a bad record is dropped, the association goes on
}

int gf_dtls_write(gf_dtls *d, const uint8_t *data, size_t len)
{
    if (!d->connected) return -1;
    int rc = mbedtls_ssl_write(&d->ssl, data, len);
    if (rc < 0) { set_error(d, "write", rc); return -1; }
    return rc;
}

int gf_dtls_srtp_keys(gf_dtls *d, uint8_t client_key[16], uint8_t server_key[16], uint8_t client_salt[14], uint8_t server_salt[14], int *tag_len)
{
    if (!d->connected || !d->have_secret) return -1;
    unsigned char material[60];
    int rc = mbedtls_ssl_tls_prf(d->prf, d->master_secret, d->master_secret_len, "EXTRACTOR-dtls_srtp", d->randoms, sizeof(d->randoms), material, sizeof(material));
    if (rc != 0) { set_error(d, "tls_prf", rc); return -1; }
    memcpy(client_key, material, 16);
    memcpy(server_key, material + 16, 16);
    memcpy(client_salt, material + 32, 14);
    memcpy(server_salt, material + 46, 14);
    mbedtls_dtls_srtp_info info;
    mbedtls_ssl_get_dtls_srtp_negotiation_result(&d->ssl, &info);
    *tag_len = info.chosen_dtls_srtp_profile == MBEDTLS_TLS_SRTP_AES128_CM_HMAC_SHA1_32 ? 4 : 10;
    return 0;
}
