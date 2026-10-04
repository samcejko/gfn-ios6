#include "gf_rtp.h"
#include <stdlib.h>
#include <string.h>

#define MAX_AU (2 * 1024 * 1024)

int gf_rtp_parse(const uint8_t *pkt, size_t len, gf_rtp_header *h)
{
    if (len < 12 || (pkt[0] >> 6) != 2) return -1;
    size_t off = 12 + 4 * (pkt[0] & 0x0f);
    if (off > len) return -1;
    if (pkt[0] & 0x10) {
        if (off + 4 > len) return -1;
        size_t ext = 4 * (size_t)((pkt[off + 2] << 8) | pkt[off + 3]);
        off += 4 + ext;
        if (off > len) return -1;
    }
    size_t end = len;
    if (pkt[0] & 0x20) {
        size_t pad = pkt[len - 1];
        if (pad == 0 || off + pad > len) return -1;
        end = len - pad;
    }
    h->payload_type = pkt[1] & 0x7f;
    h->marker = (pkt[1] & 0x80) != 0;
    h->seq = (uint16_t)((pkt[2] << 8) | pkt[3]);
    h->timestamp = ((uint32_t)pkt[4] << 24) | ((uint32_t)pkt[5] << 16) | ((uint32_t)pkt[6] << 8) | pkt[7];
    h->ssrc = ((uint32_t)pkt[8] << 24) | ((uint32_t)pkt[9] << 16) | ((uint32_t)pkt[10] << 8) | pkt[11];
    h->payload = pkt + off;
    h->payload_len = end - off;
    return 0;
}

/* ---- depacketizer ---- */

static int seq_lt(uint16_t a, uint16_t b) { return (int16_t)(a - b) < 0; }
static int ts_newer(uint32_t a, uint32_t b) { uint32_t d = a - b; return d != 0 && d < 0x80000000u; }

static void frame_clear(gf_h264_frame *f)
{
    for (int i = 0; i < f->count; i++) free(f->pkts[i].data);
    memset(f, 0, sizeof(*f));
}

void gf_h264_init(gf_h264_depack *d)
{
    memset(d, 0, sizeof(*d));
    d->cap = 256 * 1024;
    d->buf = (uint8_t *)malloc(d->cap);
}

void gf_h264_free(gf_h264_depack *d)
{
    frame_clear(&d->frames[0]);
    frame_clear(&d->frames[1]);
    free(d->buf);
    d->buf = NULL;
    d->cap = d->len = 0;
}

void gf_h264_reset(gf_h264_depack *d)
{
    frame_clear(&d->frames[0]);
    frame_clear(&d->frames[1]);
    d->len = 0;
    d->have_seq = 0;
}

static int append(gf_h264_depack *d, const uint8_t *p, size_t n)
{
    if (d->len + n > d->cap) {
        size_t cap = d->cap * 2;
        while (cap < d->len + n) cap *= 2;
        if (cap > MAX_AU) return 0;
        uint8_t *nb = (uint8_t *)realloc(d->buf, cap);
        if (!nb) return 0;
        d->buf = nb;
        d->cap = cap;
    }
    memcpy(d->buf + d->len, p, n);
    d->len += n;
    return 1;
}

static int start_code(gf_h264_depack *d)
{
    static const uint8_t sc[4] = { 0, 0, 0, 1 };
    return append(d, sc, 4);
}

// A packet that may begin a frame: a single NAL unit, a STAP-A, or the first fragment of a FU-A
static int is_partition_head(const uint8_t *p, size_t n)
{
    if (n < 1) return 0;
    uint8_t type = p[0] & 0x1f;
    if (type >= 1 && type <= 24) return 1;
    if (type == 28) return n >= 2 && (p[1] & 0x80) != 0;
    return 0;
}

static int cmp_pkt(const void *a, const void *b)
{
    const gf_rtp_pkt *x = (const gf_rtp_pkt *)a, *y = (const gf_rtp_pkt *)b;
    return seq_lt(x->seq, y->seq) ? -1 : (x->seq == y->seq ? 0 : 1);
}

// Sorted and gap-free from `first` to the marker packet?
static int frame_contiguous(gf_h264_frame *f, uint16_t first)
{
    if (!f->has_marker || !f->count) return 0;
    qsort(f->pkts, (size_t)f->count, sizeof(gf_rtp_pkt), cmp_pkt);
    if (f->pkts[0].seq != first) return 0;
    if (f->pkts[f->count - 1].seq != f->marker_seq) return 0;
    for (int i = 1; i < f->count; i++) if (f->pkts[i].seq != (uint16_t)(f->pkts[i - 1].seq + 1)) return 0;
    return 1;
}

// Depacketizes the frame's packets (sorted) into one Annex B access unit and hands it over
static void deliver(gf_h264_depack *d, gf_h264_frame *f, int damaged, gf_h264_au_cb cb, void *ctx)
{
    qsort(f->pkts, (size_t)f->count, sizeof(gf_rtp_pkt), cmp_pkt);
    d->len = 0;
    int has_idr = 0, in_fu = 0;
    uint16_t expect = f->pkts[0].seq;
    if (d->have_seq && seq_lt(d->next_seq, expect)) {
        d->lost += (uint16_t)(expect - d->next_seq);
        damaged = 1;
    }
    for (int i = 0; i < f->count; i++) {
        gf_rtp_pkt *k = &f->pkts[i];
        if (k->seq != expect) {
            d->lost += (uint16_t)(k->seq - expect);
            damaged = 1;
            in_fu = 0;
        }
        expect = (uint16_t)(k->seq + 1);
        const uint8_t *p = k->data;
        size_t n = k->len;
        if (n < 1) continue;
        uint8_t type = p[0] & 0x1f;
        if (type >= 1 && type <= 23) {
            in_fu = 0;
            if (type == 5) has_idr = 1;
            if (!start_code(d) || !append(d, p, n)) damaged = 1;
        } else if (type == 24) {
            in_fu = 0;
            size_t off = 1;
            while (off + 2 <= n) {
                size_t sz = ((size_t)p[off] << 8) | p[off + 1];
                off += 2;
                if (sz == 0 || off + sz > n) { damaged = 1; break; }
                if ((p[off] & 0x1f) == 5) has_idr = 1;
                if (!start_code(d) || !append(d, p + off, sz)) damaged = 1;
                off += sz;
            }
        } else if (type == 28 && n >= 2) {
            uint8_t fu = p[1];
            int start = (fu & 0x80) != 0, end = (fu & 0x40) != 0;
            uint8_t nal_type = fu & 0x1f;
            if (start) {
                uint8_t header = (uint8_t)((p[0] & 0xe0) | nal_type);
                if (nal_type == 5) has_idr = 1;
                in_fu = 1;
                if (!start_code(d) || !append(d, &header, 1)) damaged = 1;
            } else if (!in_fu) {
                damaged = 1;
            }
            if (in_fu && !append(d, p + 2, n - 2)) damaged = 1;
            if (end) in_fu = 0;
        }
    }
    if (!f->has_marker) damaged = 1;
    d->next_seq = (uint16_t)expect;
    d->have_seq = 1;
    if (d->len && cb) cb(ctx, d->buf, d->len, f->ts, has_idr, damaged);
    d->frames_out++;
    if (damaged) d->dropped++;
    frame_clear(f);
}

static gf_h264_frame *older_frame(gf_h264_depack *d)
{
    gf_h264_frame *a = &d->frames[0], *b = &d->frames[1];
    if (!a->active) return b->active ? b : NULL;
    if (!b->active) return a;
    return ts_newer(a->ts, b->ts) ? b : a;
}

static void try_deliver(gf_h264_depack *d, gf_h264_au_cb cb, void *ctx)
{
    for (int guard = 0; guard < 4; guard++) {
        gf_h264_frame *f = older_frame(d);
        if (!f) return;
        gf_h264_frame *g = (f == &d->frames[0]) ? &d->frames[1] : &d->frames[0];
        if (f->has_marker) {
            if (d->have_seq) {
                if (frame_contiguous(f, d->next_seq)) { deliver(d, f, 0, cb, ctx); continue; }
            } else if (frame_contiguous(f, f->min_seq) && is_partition_head(f->pkts[0].data, f->pkts[0].len)) {
                deliver(d, f, 0, cb, ctx);
                continue;
            }
        }
        // the older frame is incomplete: once the newer one is whole, give up on the missing packets
        if (g->active && g->has_marker && frame_contiguous(g, g->min_seq) && is_partition_head(g->pkts[0].data, g->pkts[0].len)) {
            deliver(d, f, 1, cb, ctx);
            d->next_seq = g->min_seq;
            continue;
        }
        return;
    }
}

static void note_missing(gf_h264_depack *d, uint16_t seq)
{
    if (d->missing_count < (int)(sizeof(d->missing) / sizeof(d->missing[0]))) d->missing[d->missing_count++] = seq;
}

int gf_h264_push(gf_h264_depack *d, const gf_rtp_header *h, gf_h264_au_cb cb, void *ctx)
{
    int gap = 0;
    d->packets++;
    if (d->have_highest) {
        int16_t delta = (int16_t)(h->seq - d->highest_seq);
        if (delta > 1) {
            gap = delta - 1;
            if (gap <= 64) for (uint16_t s = (uint16_t)(d->highest_seq + 1); s != h->seq; s++) note_missing(d, s);
        }
        if (delta > 0) d->highest_seq = h->seq;
    } else {
        d->have_highest = 1;
        d->highest_seq = h->seq;
    }
    if (d->have_seq && seq_lt(h->seq, d->next_seq)) return gap;     // belongs to a frame already delivered
    if (h->payload_len < 1) return gap;

    gf_h264_frame *f = NULL;
    for (int i = 0; i < 2; i++) if (d->frames[i].active && d->frames[i].ts == h->timestamp) f = &d->frames[i];
    if (!f) {
        for (int i = 0; i < 2 && !f; i++) if (!d->frames[i].active) f = &d->frames[i];
        if (!f) {
            // two frames pending and a third begins: the oldest one is not going to complete
            gf_h264_frame *old = older_frame(d);
            if (ts_newer(old->ts, h->timestamp)) return gap;   // older than both: too late
            deliver(d, old, 1, cb, ctx);
            f = old;
        }
        f->active = 1;
        f->ts = h->timestamp;
        f->count = 0;
        f->has_marker = 0;
        f->min_seq = h->seq;
    }
    for (int i = 0; i < f->count; i++) if (f->pkts[i].seq == h->seq) return gap;    // duplicate
    if (f->count >= GF_FRAME_MAX_PACKETS) { deliver(d, f, 1, cb, ctx); return gap; }
    gf_rtp_pkt *k = &f->pkts[f->count];
    k->data = (uint8_t *)malloc(h->payload_len);
    if (!k->data) return gap;
    memcpy(k->data, h->payload, h->payload_len);
    k->len = (uint16_t)h->payload_len;
    k->seq = h->seq;
    k->marker = h->marker;
    f->count++;
    if (seq_lt(h->seq, f->min_seq)) f->min_seq = h->seq;
    if (h->marker) { f->has_marker = 1; f->marker_seq = h->seq; }
    try_deliver(d, cb, ctx);
    return gap;
}

int gf_h264_take_missing(gf_h264_depack *d, uint16_t *out, int cap)
{
    int n = d->missing_count < cap ? d->missing_count : cap;
    memcpy(out, d->missing, (size_t)n * sizeof(uint16_t));
    d->missing_count = 0;
    return n;
}

/* ---- Annex B helpers ---- */

// Iterates NAL units of an Annex B buffer: *pos is where to start looking; returns the NAL start and length
static int next_nal(const uint8_t *au, size_t len, size_t *pos, const uint8_t **nal, size_t *nal_len)
{
    size_t i = *pos;
    while (i + 3 <= len) {
        if (au[i] == 0 && au[i + 1] == 0 && (au[i + 2] == 1 || (i + 4 <= len && au[i + 2] == 0 && au[i + 3] == 1))) break;
        i++;
    }
    if (i + 3 > len) return 0;
    i += (au[i + 2] == 1) ? 3 : 4;
    size_t start = i;
    while (i + 3 <= len) {
        if (au[i] == 0 && au[i + 1] == 0 && (au[i + 2] == 1 || (i + 4 <= len && au[i + 2] == 0 && au[i + 3] == 1))) break;
        i++;
    }
    size_t end = (i + 3 <= len) ? i : len;
    while (end > start && au[end - 1] == 0 && i + 3 <= len) end--;     // trailing zeros belong to the next start code
    *nal = au + start;
    *nal_len = end - start;
    *pos = i;
    return 1;
}

int gf_h264_find_parameter_sets(const uint8_t *au, size_t len, const uint8_t **sps, size_t *sps_len, const uint8_t **pps, size_t *pps_len)
{
    size_t pos = 0;
    const uint8_t *nal;
    size_t nlen;
    *sps = *pps = NULL;
    *sps_len = *pps_len = 0;
    while (next_nal(au, len, &pos, &nal, &nlen)) {
        if (nlen < 1) continue;
        uint8_t type = nal[0] & 0x1f;
        if (type == 7 && !*sps) { *sps = nal; *sps_len = nlen; }
        else if (type == 8 && !*pps) { *pps = nal; *pps_len = nlen; }
    }
    return *sps && *pps;
}

/* ---- SPS parsing (just enough for the picture size) ---- */

typedef struct { const uint8_t *p; size_t n; size_t bit; } bitreader;

static uint32_t rbit(bitreader *b)
{
    if (b->bit >= b->n * 8) return 0;
    uint32_t v = (b->p[b->bit >> 3] >> (7 - (b->bit & 7))) & 1;
    b->bit++;
    return v;
}

static uint32_t rbits(bitreader *b, int n)
{
    uint32_t v = 0;
    while (n-- > 0) v = (v << 1) | rbit(b);
    return v;
}

static uint32_t rue(bitreader *b)
{
    int zeros = 0;
    while (rbit(b) == 0 && zeros < 32 && b->bit < b->n * 8) zeros++;
    if (zeros == 0) return 0;
    return (1u << zeros) - 1 + rbits(b, zeros);
}

static int32_t rse(bitreader *b)
{
    uint32_t k = rue(b);
    return (k & 1) ? (int32_t)((k + 1) / 2) : -(int32_t)(k / 2);
}

static void skip_scaling_list(bitreader *b, int size)
{
    int last = 8, next = 8;
    for (int j = 0; j < size; j++) {
        if (next != 0) next = (last + rse(b) + 256) % 256;
        last = next ? next : last;
    }
}

int gf_h264_sps_dimensions(const uint8_t *sps, size_t len, int *width, int *height)
{
    uint8_t rbsp[1024];
    size_t m = 0;
    if (len < 4) return 0;
    for (size_t i = 1; i < len && m < sizeof(rbsp); i++) {
        if (i >= 2 && sps[i] == 3 && sps[i - 1] == 0 && sps[i - 2] == 0) continue;   // emulation prevention byte
        rbsp[m++] = sps[i];
    }
    bitreader b = { rbsp, m, 0 };
    uint32_t profile = rbits(&b, 8);
    rbits(&b, 8);
    rbits(&b, 8);
    rue(&b);
    uint32_t chroma = 1;
    if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83 || profile == 86 ||
        profile == 118 || profile == 128 || profile == 138 || profile == 139 || profile == 134 || profile == 135) {
        chroma = rue(&b);
        if (chroma == 3) rbit(&b);
        rue(&b);
        rue(&b);
        rbit(&b);
        if (rbit(&b)) {
            int lists = chroma != 3 ? 8 : 12;
            for (int i = 0; i < lists; i++) if (rbit(&b)) skip_scaling_list(&b, i < 6 ? 16 : 64);
        }
    }
    rue(&b);
    uint32_t poc = rue(&b);
    if (poc == 0) {
        rue(&b);
    } else if (poc == 1) {
        rbit(&b);
        rse(&b);
        rse(&b);
        uint32_t n = rue(&b);
        if (n > 256) return 0;
        for (uint32_t i = 0; i < n; i++) rse(&b);
    }
    rue(&b);
    rbit(&b);
    uint32_t pw = rue(&b), ph = rue(&b);
    uint32_t frame_mbs_only = rbit(&b);
    if (!frame_mbs_only) rbit(&b);
    rbit(&b);
    uint32_t l = 0, r = 0, t = 0, bo = 0;
    if (rbit(&b)) { l = rue(&b); r = rue(&b); t = rue(&b); bo = rue(&b); }
    int w = (int)((pw + 1) * 16);
    int h = (int)((2 - frame_mbs_only) * (ph + 1) * 16);
    int cx = (chroma == 1 || chroma == 2) ? 2 : 1;
    int cy = (int)(2 - frame_mbs_only) * (chroma == 1 ? 2 : 1);
    w -= (int)(l + r) * cx;
    h -= (int)(t + bo) * cy;
    if (w <= 0 || h <= 0 || w > 8192 || h > 8192) return 0;
    *width = w;
    *height = h;
    return 1;
}

size_t gf_h264_annexb_to_avcc(const uint8_t *au, size_t len, uint8_t *out, size_t cap)
{
    struct { size_t start, len; } ranges[256];
    int count = 0;
    size_t pos = 0;
    const uint8_t *nal;
    size_t nlen;
    size_t total = 0;
    while (count < 256 && next_nal(au, len, &pos, &nal, &nlen)) {
        if (nlen < 1) continue;
        uint8_t type = nal[0] & 0x1f;
        if (type == 7 || type == 8 || type == 9) continue;
        ranges[count].start = (size_t)(nal - au);
        ranges[count].len = nlen;
        count++;
        total += 4 + nlen;
    }
    if (total > cap || !count) return 0;
    uint8_t *tmp = (out == au) ? (uint8_t *)malloc(total) : out;
    if (!tmp) return 0;
    size_t o = 0;
    for (int i = 0; i < count; i++) {
        tmp[o] = (uint8_t)(ranges[i].len >> 24); tmp[o + 1] = (uint8_t)(ranges[i].len >> 16);
        tmp[o + 2] = (uint8_t)(ranges[i].len >> 8); tmp[o + 3] = (uint8_t)ranges[i].len;
        memcpy(tmp + o + 4, au + ranges[i].start, ranges[i].len);
        o += 4 + ranges[i].len;
    }
    if (out == au) {
        memcpy(out, tmp, total);
        free(tmp);
    }
    return total;
}
