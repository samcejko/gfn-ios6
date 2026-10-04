#include "gf_rtcp.h"
#include <string.h>

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static uint32_t get32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

static void header(uint8_t *p, uint8_t count, uint8_t type, size_t len)
{
    p[0] = (uint8_t)(0x80 | (count & 0x1f));
    p[1] = type;
    put16(p + 2, (uint16_t)(len / 4 - 1));
}

size_t gf_rtcp_build_rr(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc, uint8_t fraction_lost,
                        int32_t cumulative_lost, uint32_t extended_highest_seq, uint32_t jitter, uint32_t lsr, uint32_t dlsr)
{
    size_t len = media_ssrc ? 32 : 8;
    if (cap < len) return 0;
    header(out, media_ssrc ? 1 : 0, 201, len);
    put32(out + 4, sender_ssrc);
    if (media_ssrc) {
        put32(out + 8, media_ssrc);
        uint32_t lost = (uint32_t)cumulative_lost & 0xffffff;
        put32(out + 12, ((uint32_t)fraction_lost << 24) | lost);
        put32(out + 16, extended_highest_seq);
        put32(out + 20, jitter);
        put32(out + 24, lsr);
        put32(out + 28, dlsr);
    }
    return len;
}

size_t gf_rtcp_build_pli(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc)
{
    if (cap < 12) return 0;
    header(out, 1, 206, 12);          // PSFB, FMT 1 = PLI
    put32(out + 4, sender_ssrc);
    put32(out + 8, media_ssrc);
    return 12;
}

size_t gf_rtcp_build_nack(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc, const uint16_t *seqs, size_t count)
{
    if (!count) return 0;
    // pack into PID + 16-bit bitmask items
    uint8_t items[64 * 4];
    size_t n_items = 0;
    size_t i = 0;
    while (i < count && n_items < 64) {
        uint16_t pid = seqs[i];
        uint16_t blp = 0;
        size_t j = i + 1;
        while (j < count) {
            uint16_t delta = (uint16_t)(seqs[j] - pid);
            if (delta == 0 || delta > 16) break;
            blp |= (uint16_t)(1u << (delta - 1));
            j++;
        }
        put16(items + n_items * 4, pid);
        put16(items + n_items * 4 + 2, blp);
        n_items++;
        i = j;
    }
    size_t len = 12 + n_items * 4;
    if (cap < len) return 0;
    header(out, 1, 205, len);          // RTPFB, FMT 1 = generic NACK
    put32(out + 4, sender_ssrc);
    put32(out + 8, media_ssrc);
    memcpy(out + 12, items, n_items * 4);
    return len;
}

size_t gf_rtcp_build_remb(uint8_t *out, size_t cap, uint32_t sender_ssrc, uint32_t media_ssrc, uint64_t bitrate_bps)
{
    if (cap < 24) return 0;
    header(out, 15, 206, 24);          // PSFB, FMT 15 = application layer feedback (REMB)
    put32(out + 4, sender_ssrc);
    put32(out + 8, 0);
    memcpy(out + 12, "REMB", 4);
    // mantissa 18 bits, exponent 6 bits
    unsigned exp = 0;
    uint64_t mantissa = bitrate_bps;
    while (mantissa > 0x3ffff) { mantissa >>= 1; exp++; }
    out[16] = 1;                       // one SSRC
    out[17] = (uint8_t)((exp << 2) | ((mantissa >> 16) & 3));
    out[18] = (uint8_t)(mantissa >> 8);
    out[19] = (uint8_t)mantissa;
    put32(out + 20, media_ssrc);
    return 24;
}

int gf_rtcp_parse_sr(const uint8_t *pkt, size_t len, uint32_t *sender_ssrc, uint32_t *ntp_middle)
{
    if (len < 28 || pkt[1] != 200) return 0;
    *sender_ssrc = get32(pkt + 4);
    *ntp_middle = (get32(pkt + 8) << 16) | (get32(pkt + 12) >> 16);
    return 1;
}
