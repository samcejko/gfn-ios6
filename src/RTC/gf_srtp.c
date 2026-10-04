#include "gf_srtp.h"
#include <string.h>
#include "mbedtls/aes.h"
#include "mbedtls/md.h"

static uint32_t get32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }

// AES-CM keystream XORed over data, counter block iv (the low 16 bits count blocks)
static int aes_cm(const uint8_t key[16], uint8_t iv[16], uint8_t *data, size_t n)
{
    mbedtls_aes_context aes;
    unsigned char stream[16];
    size_t off = 0;
    mbedtls_aes_init(&aes);
    if (mbedtls_aes_setkey_enc(&aes, key, 128) != 0) { mbedtls_aes_free(&aes); return 0; }
    int rc = mbedtls_aes_crypt_ctr(&aes, n, &off, iv, stream, data, data);
    mbedtls_aes_free(&aes);
    return rc == 0;
}

// x = master_salt XOR (label << 48); key = AES-CM(master_key, x || 0x0000) keystream
static int derive(const uint8_t *master_key, const uint8_t *master_salt, uint8_t label, uint8_t *out, size_t n)
{
    uint8_t iv[16];
    memset(iv, 0, sizeof(iv));
    memcpy(iv, master_salt, 14);
    iv[7] ^= label;
    memset(out, 0, n);
    return aes_cm(master_key, iv, out, n);
}

int gf_srtp_init(gf_srtp_session *s, const uint8_t *master_key, const uint8_t *master_salt, int tag_len)
{
    memset(s, 0, sizeof(*s));
    s->tag_len = tag_len == 4 ? 4 : 10;
    if (!derive(master_key, master_salt, 0, s->key, 16)) return 0;
    if (!derive(master_key, master_salt, 1, s->auth, 20)) return 0;
    if (!derive(master_key, master_salt, 2, s->salt, 14)) return 0;
    if (!derive(master_key, master_salt, 3, s->rtcp_key, 16)) return 0;
    if (!derive(master_key, master_salt, 4, s->rtcp_auth, 20)) return 0;
    if (!derive(master_key, master_salt, 5, s->rtcp_salt, 14)) return 0;
    return 1;
}

static int hmac(const uint8_t key[20], const uint8_t *a, size_t alen, const uint8_t *b, size_t blen, uint8_t out[20])
{
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA1);
    mbedtls_md_context_t ctx;
    int ok = 0;
    if (!info) return 0;
    mbedtls_md_init(&ctx);
    if (mbedtls_md_setup(&ctx, info, 1) == 0 && mbedtls_md_hmac_starts(&ctx, key, 20) == 0 &&
        mbedtls_md_hmac_update(&ctx, a, alen) == 0 && (!blen || mbedtls_md_hmac_update(&ctx, b, blen) == 0) &&
        mbedtls_md_hmac_finish(&ctx, out) == 0) ok = 1;
    mbedtls_md_free(&ctx);
    return ok;
}

// IV = (salt << 16) XOR (ssrc << 64) XOR (index << 16)
static void make_iv(uint8_t iv[16], const uint8_t salt[14], uint32_t ssrc, uint64_t index)
{
    memset(iv, 0, 16);
    memcpy(iv, salt, 14);
    iv[4] ^= (uint8_t)(ssrc >> 24); iv[5] ^= (uint8_t)(ssrc >> 16); iv[6] ^= (uint8_t)(ssrc >> 8); iv[7] ^= (uint8_t)ssrc;
    iv[8] ^= (uint8_t)(index >> 40); iv[9] ^= (uint8_t)(index >> 32); iv[10] ^= (uint8_t)(index >> 24);
    iv[11] ^= (uint8_t)(index >> 16); iv[12] ^= (uint8_t)(index >> 8); iv[13] ^= (uint8_t)index;
}

int gf_srtp_unprotect(gf_srtp_session *s, gf_srtp_stream *st, uint8_t *pkt, size_t len)
{
    if (len < 12 + (size_t)s->tag_len) return -1;
    size_t hdr = 12 + 4 * (pkt[0] & 0x0f);
    if (pkt[0] & 0x10) {                     // header extension
        if (len < hdr + 4) return -1;
        hdr += 4 + 4 * (size_t)((pkt[hdr + 2] << 8) | pkt[hdr + 3]);
    }
    if (len < hdr + (size_t)s->tag_len) return -1;
    uint16_t seq = (uint16_t)((pkt[2] << 8) | pkt[3]);
    uint32_t ssrc = get32(pkt + 8);

    // index estimation (RFC 3711 3.3.1)
    uint32_t v = st->roc;
    if (!st->started) {
        st->started = 1;
        st->ssrc = ssrc;
        st->roc = 0;
        st->s_l = seq;
        v = 0;
    } else if (st->s_l < 32768) {
        if ((int)seq - (int)st->s_l > 32768) v = st->roc - 1;
    } else {
        if ((int)st->s_l - 32768 > (int)seq) v = st->roc + 1;
    }
    uint64_t index = ((uint64_t)v << 16) | seq;

    size_t body = len - (size_t)s->tag_len;
    uint8_t roc_be[4], mac[20];
    put32(roc_be, v);
    if (!hmac(s->auth, pkt, body, roc_be, 4, mac)) return -1;
    if (memcmp(mac, pkt + body, (size_t)s->tag_len) != 0) return -1;

    uint8_t iv[16];
    make_iv(iv, s->salt, ssrc, index);
    if (!aes_cm(s->key, iv, pkt + hdr, body - hdr)) return -1;

    if (v == st->roc + 1) { st->roc = v; st->s_l = seq; }
    else if (v == st->roc && seq > st->s_l) st->s_l = seq;
    return (int)body;
}

int gf_srtp_protect_rtcp(gf_srtp_session *s, uint8_t *pkt, size_t len, size_t cap)
{
    if (len < 8 || len + 4 + (size_t)s->tag_len > cap) return -1;
    uint32_t ssrc = get32(pkt + 4);
    uint32_t index = s->rtcp_index++ & 0x7fffffffu;
    uint8_t iv[16];
    make_iv(iv, s->rtcp_salt, ssrc, index);
    if (!aes_cm(s->rtcp_key, iv, pkt + 8, len - 8)) return -1;
    put32(pkt + len, index | 0x80000000u);
    uint8_t mac[20];
    if (!hmac(s->rtcp_auth, pkt, len + 4, NULL, 0, mac)) return -1;
    memcpy(pkt + len + 4, mac, (size_t)s->tag_len);
    return (int)(len + 4 + (size_t)s->tag_len);
}

int gf_srtp_unprotect_rtcp(gf_srtp_session *s, uint8_t *pkt, size_t len)
{
    if (len < 8 + 4 + (size_t)s->tag_len) return -1;
    size_t body = len - (size_t)s->tag_len;    // includes the E||index word
    uint8_t mac[20];
    if (!hmac(s->rtcp_auth, pkt, body, NULL, 0, mac)) return -1;
    if (memcmp(mac, pkt + body, (size_t)s->tag_len) != 0) return -1;
    uint32_t eidx = get32(pkt + body - 4);
    size_t plain = body - 4;
    if (eidx & 0x80000000u) {
        uint8_t iv[16];
        make_iv(iv, s->rtcp_salt, get32(pkt + 4), eidx & 0x7fffffffu);
        if (!aes_cm(s->rtcp_key, iv, pkt + 8, plain - 8)) return -1;
    }
    return (int)plain;
}

int gf_srtp_selftest(void)
{
    // RFC 3711 B.3 key derivation test vectors
    static const uint8_t master_key[16] = { 0xE1,0xF9,0x7A,0x0D,0x3E,0x01,0x8B,0xE0,0xD6,0x4F,0xA3,0x2C,0x06,0xDE,0x41,0x39 };
    static const uint8_t master_salt[14] = { 0x0E,0xC6,0x75,0xAD,0x49,0x8A,0xFE,0xEB,0xB6,0x96,0x0B,0x3A,0xAB,0xE6 };
    static const uint8_t want_key[16] = { 0xC6,0x1E,0x7A,0x93,0x74,0x4F,0x39,0xEE,0x10,0x73,0x4A,0xFE,0x3F,0xF7,0xA0,0x87 };
    static const uint8_t want_salt[14] = { 0x30,0xCB,0xBC,0x08,0x86,0x3D,0x8C,0x85,0xD4,0x9D,0xB3,0x4A,0x9A,0xE1 };
    static const uint8_t want_auth[20] = { 0xCE,0xBE,0x32,0x1F,0x6F,0xF7,0x71,0x6B,0x6F,0xD4,0xAB,0x49,0xAF,0x25,0x6A,0x15,0x6D,0x38,0xBA,0xA4 };
    gf_srtp_session s;
    if (!gf_srtp_init(&s, master_key, master_salt, 10)) return 0;
    return memcmp(s.key, want_key, 16) == 0 && memcmp(s.salt, want_salt, 14) == 0 && memcmp(s.auth, want_auth, 20) == 0;
}
