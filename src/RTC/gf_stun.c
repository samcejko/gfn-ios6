#include "gf_stun.h"
#include <string.h>
#include <zlib.h>
#include "mbedtls/md.h"

#define STUN_MAGIC 0x2112A442u
#define ATTR_MAPPED_ADDRESS     0x0001
#define ATTR_USERNAME           0x0006
#define ATTR_MESSAGE_INTEGRITY  0x0008
#define ATTR_ERROR_CODE         0x0009
#define ATTR_XOR_MAPPED_ADDRESS 0x0020
#define ATTR_PRIORITY           0x0024
#define ATTR_USE_CANDIDATE      0x0025
#define ATTR_FINGERPRINT        0x8028
#define ATTR_ICE_CONTROLLED     0x8029
#define ATTR_ICE_CONTROLLING    0x802A

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static uint16_t get16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t get32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

int gf_stun_is_stun(const uint8_t *p, size_t n)
{
    return n >= 20 && (p[0] & 0xC0) == 0 && get32(p + 4) == STUN_MAGIC;
}

typedef struct {
    uint8_t *buf;
    size_t cap;
    size_t len;
} wr;

static int attr(wr *w, uint16_t type, const uint8_t *value, size_t vlen)
{
    size_t padded = (vlen + 3) & ~(size_t)3;
    if (w->len + 4 + padded > w->cap) return 0;
    put16(w->buf + w->len, type);
    put16(w->buf + w->len + 2, (uint16_t)vlen);
    if (vlen) memcpy(w->buf + w->len + 4, value, vlen);
    if (padded > vlen) memset(w->buf + w->len + 4 + vlen, 0, padded - vlen);
    w->len += 4 + padded;
    put16(w->buf + 2, (uint16_t)(w->len - 20));
    return 1;
}

static int hmac_sha1(const char *key, const uint8_t *data, size_t n, uint8_t out[20])
{
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA1);
    if (!info) return 0;
    return mbedtls_md_hmac(info, (const unsigned char *)key, strlen(key), data, n, out) == 0;
}

// MESSAGE-INTEGRITY is computed over the message with the length field counting the attribute itself
static int add_integrity(wr *w, const char *pwd)
{
    if (!pwd || w->len + 24 > w->cap) return 0;
    put16(w->buf + 2, (uint16_t)(w->len - 20 + 24));
    uint8_t mac[20];
    if (!hmac_sha1(pwd, w->buf, w->len, mac)) return 0;
    put16(w->buf + 2, (uint16_t)(w->len - 20));
    return attr(w, ATTR_MESSAGE_INTEGRITY, mac, 20);
}

static int add_fingerprint(wr *w)
{
    if (w->len + 8 > w->cap) return 0;
    put16(w->buf + 2, (uint16_t)(w->len - 20 + 8));
    uint32_t crc = (uint32_t)crc32(0L, w->buf, (uInt)w->len) ^ 0x5354554Eu;
    put16(w->buf + 2, (uint16_t)(w->len - 20));
    uint8_t v[4];
    put32(v, crc);
    return attr(w, ATTR_FINGERPRINT, v, 4);
}

static void header(wr *w, uint16_t type, const uint8_t tid[12])
{
    put16(w->buf, type);
    put16(w->buf + 2, 0);
    put32(w->buf + 4, STUN_MAGIC);
    memcpy(w->buf + 8, tid, 12);
    w->len = 20;
}

size_t gf_stun_build_request(uint8_t *out, size_t cap, const uint8_t tid[12], const char *username, const char *pwd,
                             uint32_t priority, uint64_t tiebreaker, int use_candidate)
{
    if (cap < 20) return 0;
    wr w = { out, cap, 0 };
    header(&w, GF_STUN_BINDING_REQUEST, tid);
    if (!attr(&w, ATTR_USERNAME, (const uint8_t *)username, strlen(username))) return 0;
    uint8_t tb[8];
    put32(tb, (uint32_t)(tiebreaker >> 32));
    put32(tb + 4, (uint32_t)tiebreaker);
    if (!attr(&w, ATTR_ICE_CONTROLLING, tb, 8)) return 0;
    if (use_candidate && !attr(&w, ATTR_USE_CANDIDATE, NULL, 0)) return 0;
    uint8_t pr[4];
    put32(pr, priority);
    if (!attr(&w, ATTR_PRIORITY, pr, 4)) return 0;
    if (!add_integrity(&w, pwd)) return 0;
    if (!add_fingerprint(&w)) return 0;
    return w.len;
}

size_t gf_stun_build_response(uint8_t *out, size_t cap, const uint8_t tid[12], uint32_t peer_ip, uint16_t peer_port, const char *pwd)
{
    if (cap < 20) return 0;
    wr w = { out, cap, 0 };
    header(&w, GF_STUN_BINDING_SUCCESS, tid);
    uint8_t xa[8];
    xa[0] = 0;
    xa[1] = 1;   // IPv4
    put16(xa + 2, (uint16_t)(peer_port ^ (STUN_MAGIC >> 16)));
    put32(xa + 4, peer_ip ^ STUN_MAGIC);
    if (!attr(&w, ATTR_XOR_MAPPED_ADDRESS, xa, 8)) return 0;
    if (!add_integrity(&w, pwd)) return 0;
    if (!add_fingerprint(&w)) return 0;
    return w.len;
}

int gf_stun_parse(const uint8_t *p, size_t n, const char *pwd, gf_stun_info *info)
{
    memset(info, 0, sizeof(*info));
    if (!gf_stun_is_stun(p, n)) return -1;
    size_t mlen = get16(p + 2);
    if (mlen + 20 > n || (mlen & 3)) return -1;
    info->type = get16(p);
    memcpy(info->tid, p + 8, 12);
    size_t off = 20, end = 20 + mlen;
    while (off + 4 <= end) {
        uint16_t type = get16(p + off), vlen = get16(p + off + 2);
        const uint8_t *v = p + off + 4;
        if (off + 4 + vlen > end) return -1;
        switch (type) {
            case ATTR_XOR_MAPPED_ADDRESS:
                if (vlen >= 8 && v[1] == 1) {
                    info->has_mapped = 1;
                    info->mapped_port = (uint16_t)(get16(v + 2) ^ (STUN_MAGIC >> 16));
                    info->mapped_ip = get32(v + 4) ^ STUN_MAGIC;
                }
                break;
            case ATTR_MAPPED_ADDRESS:
                if (!info->has_mapped && vlen >= 8 && v[1] == 1) {
                    info->has_mapped = 1;
                    info->mapped_port = get16(v + 2);
                    info->mapped_ip = get32(v + 4);
                }
                break;
            case ATTR_USERNAME: {
                size_t c = vlen < sizeof(info->username) - 1 ? vlen : sizeof(info->username) - 1;
                memcpy(info->username, v, c);
                info->username[c] = 0;
                break;
            }
            case ATTR_ERROR_CODE:
                if (vlen >= 4) info->error_code = (v[2] & 7) * 100 + v[3];
                break;
            case ATTR_USE_CANDIDATE:
                info->use_candidate = 1;
                break;
            case ATTR_MESSAGE_INTEGRITY:
                if (vlen == 20 && pwd) {
                    // the length field must count up to and including this attribute while hashing
                    uint8_t copy[1500];
                    size_t upto = off;
                    if (upto > sizeof(copy)) { info->integrity_ok = -1; break; }
                    memcpy(copy, p, upto);
                    put16(copy + 2, (uint16_t)(upto - 20 + 24));
                    uint8_t mac[20];
                    info->integrity_ok = (hmac_sha1(pwd, copy, upto, mac) && memcmp(mac, v, 20) == 0) ? 1 : -1;
                }
                break;
            default:
                break;
        }
        off += 4 + ((vlen + 3) & ~3u);
    }
    return 0;
}
