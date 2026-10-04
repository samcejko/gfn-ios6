#include "gf_sctp.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#define CHUNK_DATA 0
#define CHUNK_INIT 1
#define CHUNK_INIT_ACK 2
#define CHUNK_SACK 3
#define CHUNK_HEARTBEAT 4
#define CHUNK_HEARTBEAT_ACK 5
#define CHUNK_ABORT 6
#define CHUNK_SHUTDOWN 7
#define CHUNK_SHUTDOWN_ACK 8
#define CHUNK_ERROR 9
#define CHUNK_COOKIE_ECHO 10
#define CHUNK_COOKIE_ACK 11
#define CHUNK_SHUTDOWN_COMPLETE 14
#define CHUNK_FORWARD_TSN 192

#define PARAM_STATE_COOKIE 7

#define MAX_PACKET 1200
#define MAX_FRAGMENT 1100
#define LOCAL_RWND (256 * 1024)
#define MAX_OUT 512                  // outbound chunks waiting or in flight
#define MAX_REORDER 512              // out-of-order inbound chunks held
#define MAX_STREAMS 1024
#define RTO_INITIAL_US 1000000ULL
#define RTO_MIN_US 200000ULL
#define RTO_MAX_US 5000000ULL
#define MAX_RTX 10

enum { ST_CLOSED, ST_COOKIE_WAIT, ST_COOKIE_ECHOED, ST_ESTABLISHED, ST_SHUTDOWN };

typedef struct {
    uint32_t tsn;
    uint16_t stream, sseq;
    uint32_t ppid;
    uint8_t flags;
    uint16_t len;
    uint8_t *data;
    uint64_t sent_us;
    int sent;             // ever transmitted
    int rtx;              // retransmissions
    int acked;            // gap-acked
    int miss_reports;     // SACKs that passed it over
} out_chunk;

typedef struct {
    uint32_t tsn;
    uint16_t stream, sseq;
    uint32_t ppid;
    uint8_t flags;
    uint16_t len;
    uint8_t *data;
} in_chunk;

typedef struct {
    uint8_t *data;
    size_t len, cap;
    uint32_t ppid;
    int active;
} reassembly;

struct gf_sctp {
    gf_sctp_callbacks cb;
    int state;
    uint16_t local_port, remote_port;
    uint32_t my_vtag, peer_vtag;
    uint32_t next_tsn;            // next TSN to assign
    uint32_t cum_acked;           // highest TSN the peer acked cumulatively (initially next_tsn - 1)
    uint32_t peer_rwnd;
    uint32_t cwnd;
    uint32_t cum_tsn_in;          // highest in-order TSN received
    int have_cum_in;
    uint16_t out_streams, in_streams;
    uint16_t sseq_out[MAX_STREAMS];
    reassembly reasm[MAX_STREAMS];
    out_chunk out[MAX_OUT];
    int out_count;
    in_chunk reorder[MAX_REORDER];
    int reorder_count;
    uint8_t *cookie;
    size_t cookie_len;
    uint64_t rto_us, srtt_us, rttvar_us;
    int have_rtt;
    uint64_t t3_deadline, t1_deadline, hb_deadline;
    int t1_tries;
    int rtx_errors;
    uint64_t retransmits;
    uint64_t now;
    int sack_pending;
    uint32_t dup_tsns[16];
    int dup_count;
};

/* ---- CRC32c (Castagnoli), reflected, as SCTP wants it ---- */

static uint32_t crc_table[256];
static int crc_ready;

static void crc_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0x82F63B78u ^ (c >> 1)) : (c >> 1);
        crc_table[i] = c;
    }
    crc_ready = 1;
}

uint32_t gf_crc32c(const uint8_t *data, size_t len)
{
    if (!crc_ready) crc_init();
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++) crc = crc_table[(crc ^ data[i]) & 0xff] ^ (crc >> 8);
    return ~crc;
}

/* ---- helpers ---- */

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put32(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v; }
static uint16_t get16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static uint32_t get32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static int tsn_lt(uint32_t a, uint32_t b) { return (int32_t)(a - b) < 0; }
static int tsn_le(uint32_t a, uint32_t b) { return (int32_t)(a - b) <= 0; }

static uint32_t rnd32(void)
{
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) v = (v << 8) | (uint32_t)(rand() & 0xff);
    return v;
}

// Sends one packet made of the chunks in body (already padded); fills the common header and checksum
static void send_packet(gf_sctp *s, uint32_t vtag, const uint8_t *body, size_t body_len)
{
    uint8_t pkt[MAX_PACKET + 64];
    if (body_len + 12 > sizeof(pkt)) return;
    put16(pkt, s->local_port);
    put16(pkt + 2, s->remote_port);
    put32(pkt + 4, vtag);
    memset(pkt + 8, 0, 4);
    memcpy(pkt + 12, body, body_len);
    uint32_t crc = gf_crc32c(pkt, body_len + 12);
    // the checksum travels in little-endian byte order
    pkt[8] = (uint8_t)crc; pkt[9] = (uint8_t)(crc >> 8); pkt[10] = (uint8_t)(crc >> 16); pkt[11] = (uint8_t)(crc >> 24);
    if (s->cb.send) s->cb.send(s->cb.ctx, pkt, body_len + 12);
}

static size_t chunk_header(uint8_t *p, uint8_t type, uint8_t flags, size_t len)
{
    p[0] = type;
    p[1] = flags;
    put16(p + 2, (uint16_t)len);
    return (len + 3) & ~(size_t)3;
}

static void closed(gf_sctp *s, const char *reason)
{
    if (s->state == ST_CLOSED) return;
    s->state = ST_CLOSED;
    if (s->cb.on_closed) s->cb.on_closed(s->cb.ctx, reason);
}

/* ---- lifecycle ---- */

gf_sctp *gf_sctp_create(uint16_t local_port, uint16_t remote_port, const gf_sctp_callbacks *cb, uint64_t now_us)
{
    gf_sctp *s = (gf_sctp *)calloc(1, sizeof(gf_sctp));
    if (!s) return NULL;
    s->cb = *cb;
    s->local_port = local_port;
    s->remote_port = remote_port;
    s->my_vtag = rnd32();
    if (!s->my_vtag) s->my_vtag = 1;
    s->next_tsn = rnd32();
    s->cum_acked = s->next_tsn - 1;
    s->peer_rwnd = 128 * 1024;
    s->cwnd = 3 * MAX_PACKET;
    s->rto_us = RTO_INITIAL_US;
    s->out_streams = s->in_streams = MAX_STREAMS;
    s->now = now_us;
    s->t1_deadline = s->t3_deadline = s->hb_deadline = UINT64_MAX;
    return s;
}

void gf_sctp_destroy(gf_sctp *s)
{
    if (!s) return;
    for (int i = 0; i < s->out_count; i++) free(s->out[i].data);
    for (int i = 0; i < s->reorder_count; i++) free(s->reorder[i].data);
    for (int i = 0; i < MAX_STREAMS; i++) free(s->reasm[i].data);
    free(s->cookie);
    free(s);
}

static void send_init(gf_sctp *s)
{
    uint8_t body[64];
    size_t n = chunk_header(body, CHUNK_INIT, 0, 20);
    put32(body + 4, s->my_vtag);
    put32(body + 8, LOCAL_RWND);
    put16(body + 12, s->out_streams);
    put16(body + 14, s->in_streams);
    put32(body + 16, s->next_tsn);
    send_packet(s, 0, body, n);
}

void gf_sctp_connect(gf_sctp *s, uint64_t now_us)
{
    s->now = now_us;
    s->state = ST_COOKIE_WAIT;
    s->t1_tries = 0;
    send_init(s);
    s->t1_deadline = now_us + s->rto_us;
}

int gf_sctp_is_connected(const gf_sctp *s) { return s->state == ST_ESTABLISHED; }
uint64_t gf_sctp_retransmits(const gf_sctp *s) { return s->retransmits; }
int gf_sctp_rto_ms(const gf_sctp *s) { return (int)(s->rto_us / 1000); }

/* ---- outbound ---- */

static size_t outstanding_bytes(const gf_sctp *s)
{
    size_t n = 0;
    for (int i = 0; i < s->out_count; i++) if (s->out[i].sent && !s->out[i].acked) n += s->out[i].len;
    return n;
}

// Sends whatever fits into the windows, bundling chunks into packets
static void flush(gf_sctp *s)
{
    if (s->state != ST_ESTABLISHED) return;
    uint8_t body[MAX_PACKET];
    size_t body_len = 0;
    size_t budget = s->peer_rwnd < s->cwnd ? s->peer_rwnd : s->cwnd;
    size_t in_flight = outstanding_bytes(s);
    for (int i = 0; i < s->out_count; i++) {
        out_chunk *c = &s->out[i];
        if (c->sent) continue;
        if (in_flight + c->len > budget && in_flight > 0) break;
        size_t need = 16 + c->len;
        size_t padded = (need + 3) & ~(size_t)3;
        if (body_len + padded > sizeof(body)) {
            send_packet(s, s->peer_vtag, body, body_len);
            body_len = 0;
        }
        uint8_t *p = body + body_len;
        chunk_header(p, CHUNK_DATA, c->flags, need);
        put32(p + 4, c->tsn);
        put16(p + 8, c->stream);
        put16(p + 10, c->sseq);
        put32(p + 12, c->ppid);
        memcpy(p + 16, c->data, c->len);
        if (padded > need) memset(p + need, 0, padded - need);
        body_len += padded;
        c->sent = 1;
        c->sent_us = s->now;
        in_flight += c->len;
    }
    if (body_len) send_packet(s, s->peer_vtag, body, body_len);
    if (outstanding_bytes(s) && s->t3_deadline == UINT64_MAX) s->t3_deadline = s->now + s->rto_us;
}

static int queue_chunk(gf_sctp *s, uint16_t stream, uint32_t ppid, uint8_t flags, uint16_t sseq, const uint8_t *data, size_t len)
{
    if (s->out_count >= MAX_OUT) return 0;
    out_chunk *c = &s->out[s->out_count];
    memset(c, 0, sizeof(*c));
    c->data = (uint8_t *)malloc(len ? len : 1);
    if (!c->data) return 0;
    memcpy(c->data, data, len);
    c->len = (uint16_t)len;
    c->tsn = s->next_tsn++;
    c->stream = stream;
    c->sseq = sseq;
    c->ppid = ppid;
    c->flags = flags;
    s->out_count++;
    return 1;
}

int gf_sctp_send(gf_sctp *s, uint16_t stream, uint32_t ppid, const uint8_t *data, size_t len, int ordered)
{
    if (s->state != ST_ESTABLISHED || stream >= MAX_STREAMS) return 0;
    if (len == 0) {
        // an empty message still needs one byte in SCTP; WebRTC marks it with the *_EMPTY payload types
        uint8_t zero = 0;
        uint32_t p = ppid == GF_SCTP_PPID_STRING ? GF_SCTP_PPID_STRING_EMPTY : GF_SCTP_PPID_BINARY_EMPTY;
        if (!queue_chunk(s, stream, p, (uint8_t)(0x03 | (ordered ? 0 : 0x04)), ordered ? s->sseq_out[stream] : 0, &zero, 1)) return 0;
        if (ordered) s->sseq_out[stream]++;
        flush(s);
        return 1;
    }
    size_t fragments = (len + MAX_FRAGMENT - 1) / MAX_FRAGMENT;
    if (s->out_count + (int)fragments > MAX_OUT) return 0;
    uint16_t sseq = ordered ? s->sseq_out[stream] : 0;
    size_t off = 0;
    for (size_t f = 0; f < fragments; f++) {
        size_t n = len - off < MAX_FRAGMENT ? len - off : MAX_FRAGMENT;
        uint8_t flags = (uint8_t)((f == 0 ? 0x02 : 0) | (f == fragments - 1 ? 0x01 : 0) | (ordered ? 0 : 0x04));
        if (!queue_chunk(s, stream, ppid, flags, sseq, data + off, n)) return 0;
        off += n;
    }
    if (ordered) s->sseq_out[stream]++;
    flush(s);
    return 1;
}

int gf_sctp_open_channel(gf_sctp *s, uint16_t stream, const char *label, const char *protocol, int ordered, int reliability, uint32_t reliability_param)
{
    uint8_t msg[512];
    size_t ll = strlen(label), pl = protocol ? strlen(protocol) : 0;
    if (12 + ll + pl > sizeof(msg)) return 0;
    msg[0] = 0x03;                                   // DATA_CHANNEL_OPEN
    uint8_t type = reliability == 1 ? 0x01 : reliability == 2 ? 0x02 : 0x00;
    if (!ordered) type |= 0x80;
    msg[1] = type;
    put16(msg + 2, 0);                               // priority
    put32(msg + 4, reliability ? reliability_param : 0);
    put16(msg + 8, (uint16_t)ll);
    put16(msg + 10, (uint16_t)pl);
    memcpy(msg + 12, label, ll);
    if (pl) memcpy(msg + 12 + ll, protocol, pl);
    return gf_sctp_send(s, stream, GF_SCTP_PPID_DCEP, msg, 12 + ll + pl, 1);
}

void gf_sctp_shutdown(gf_sctp *s)
{
    if (s->state == ST_CLOSED) return;
    if (s->state == ST_ESTABLISHED) {
        uint8_t body[8];
        size_t n = chunk_header(body, CHUNK_ABORT, 0, 4);
        send_packet(s, s->peer_vtag, body, n);
    }
    s->state = ST_CLOSED;
}

/* ---- SACK ---- */

static int cmp_in(const void *a, const void *b)
{
    const in_chunk *x = (const in_chunk *)a, *y = (const in_chunk *)b;
    return tsn_lt(x->tsn, y->tsn) ? -1 : (x->tsn == y->tsn ? 0 : 1);
}

static void send_sack(gf_sctp *s)
{
    s->sack_pending = 0;
    if (!s->have_cum_in) return;
    uint8_t body[MAX_PACKET];
    // gap blocks from the reorder buffer (sorted)
    uint16_t gaps[128][2];
    int ngaps = 0;
    for (int i = 0; i < s->reorder_count && ngaps < 128; i++) {
        uint32_t off = s->reorder[i].tsn - s->cum_tsn_in;
        if (off == 0 || off > 65535) continue;
        if (ngaps && gaps[ngaps - 1][1] + 1 == off) { gaps[ngaps - 1][1] = (uint16_t)off; continue; }
        gaps[ngaps][0] = (uint16_t)off;
        gaps[ngaps][1] = (uint16_t)off;
        ngaps++;
    }
    size_t len = 16 + 4 * (size_t)ngaps + 4 * (size_t)s->dup_count;
    size_t n = chunk_header(body, CHUNK_SACK, 0, len);
    put32(body + 4, s->cum_tsn_in);
    size_t held = 0;
    for (int i = 0; i < s->reorder_count; i++) held += s->reorder[i].len;
    put32(body + 8, held < LOCAL_RWND ? (uint32_t)(LOCAL_RWND - held) : 0);
    put16(body + 12, (uint16_t)ngaps);
    put16(body + 14, (uint16_t)s->dup_count);
    uint8_t *p = body + 16;
    for (int i = 0; i < ngaps; i++) { put16(p, gaps[i][0]); put16(p + 2, gaps[i][1]); p += 4; }
    for (int i = 0; i < s->dup_count; i++) { put32(p, s->dup_tsns[i]); p += 4; }
    s->dup_count = 0;
    send_packet(s, s->peer_vtag, body, n);
}

/* ---- inbound data ---- */

static void deliver_message(gf_sctp *s, uint16_t stream, uint32_t ppid, const uint8_t *data, size_t len)
{
    if (ppid == GF_SCTP_PPID_DCEP) {
        if (len >= 1 && data[0] == 0x02) {
            if (s->cb.on_channel_ack) s->cb.on_channel_ack(s->cb.ctx, stream);
        } else if (len >= 12 && data[0] == 0x03) {
            size_t ll = get16(data + 8), pl = get16(data + 10);
            char label[256], proto[256];
            if (12 + ll + pl > len) return;
            size_t cl = ll < 255 ? ll : 255, cp = pl < 255 ? pl : 255;
            memcpy(label, data + 12, cl); label[cl] = 0;
            memcpy(proto, data + 12 + ll, cp); proto[cp] = 0;
            uint8_t ack = 0x02;
            gf_sctp_send(s, stream, GF_SCTP_PPID_DCEP, &ack, 1, 1);
            if (s->cb.on_channel_open) s->cb.on_channel_open(s->cb.ctx, stream, label, proto);
        }
        return;
    }
    if (ppid == GF_SCTP_PPID_STRING_EMPTY || ppid == GF_SCTP_PPID_BINARY_EMPTY) len = 0;
    if (s->cb.on_message) s->cb.on_message(s->cb.ctx, stream, ppid, data, len);
}

// A chunk in TSN order: reassemble fragments per stream, deliver whole messages
static void accept_chunk(gf_sctp *s, in_chunk *c)
{
    int begin = (c->flags & 0x02) != 0, end = (c->flags & 0x01) != 0;
    if (c->stream >= MAX_STREAMS) return;
    if (begin && end) { deliver_message(s, c->stream, c->ppid, c->data, c->len); return; }
    reassembly *r = &s->reasm[c->stream];
    if (begin) { r->len = 0; r->active = 1; r->ppid = c->ppid; }
    if (!r->active) return;
    if (r->len + c->len > r->cap) {
        size_t cap = r->cap ? r->cap * 2 : 4096;
        while (cap < r->len + c->len) cap *= 2;
        if (cap > 1024 * 1024) { r->active = 0; return; }
        uint8_t *nb = (uint8_t *)realloc(r->data, cap);
        if (!nb) { r->active = 0; return; }
        r->data = nb;
        r->cap = cap;
    }
    memcpy(r->data + r->len, c->data, c->len);
    r->len += c->len;
    if (end) {
        r->active = 0;
        deliver_message(s, c->stream, r->ppid, r->data, r->len);
    }
}

// p points behind the 4-byte chunk header: TSN(4) stream(2) sseq(2) PPID(4) then the user data
static void handle_data(gf_sctp *s, const uint8_t *p, size_t len, uint8_t flags)
{
    if (len < 13) return;
    in_chunk c;
    c.tsn = get32(p);
    c.stream = get16(p + 4);
    c.sseq = get16(p + 6);
    c.ppid = get32(p + 8);
    c.flags = flags;
    c.len = (uint16_t)(len - 12);
    c.data = NULL;
    s->sack_pending = 1;
    if (!s->have_cum_in) {
        // the first chunk after the cookie: the peer's initial TSN was learned from INIT ACK (cum_tsn_in = initial - 1)
        s->have_cum_in = 1;
    }
    if (tsn_le(c.tsn, s->cum_tsn_in)) {
        if (s->dup_count < 16) s->dup_tsns[s->dup_count++] = c.tsn;
        return;
    }
    if (c.tsn == s->cum_tsn_in + 1) {
        in_chunk now = c;
        now.data = (uint8_t *)(p + 12);
        s->cum_tsn_in = c.tsn;
        accept_chunk(s, &now);
        // drain what became in order
        int progressed = 1;
        while (progressed && s->reorder_count) {
            progressed = 0;
            for (int i = 0; i < s->reorder_count; i++) {
                if (s->reorder[i].tsn == s->cum_tsn_in + 1) {
                    in_chunk held = s->reorder[i];
                    memmove(&s->reorder[i], &s->reorder[i + 1], (size_t)(s->reorder_count - i - 1) * sizeof(in_chunk));
                    s->reorder_count--;
                    s->cum_tsn_in = held.tsn;
                    accept_chunk(s, &held);
                    free(held.data);
                    progressed = 1;
                    break;
                }
            }
        }
        return;
    }
    // out of order: hold it
    for (int i = 0; i < s->reorder_count; i++) {
        if (s->reorder[i].tsn == c.tsn) { if (s->dup_count < 16) s->dup_tsns[s->dup_count++] = c.tsn; return; }
    }
    if (s->reorder_count >= MAX_REORDER) return;
    c.data = (uint8_t *)malloc(c.len ? c.len : 1);
    if (!c.data) return;
    memcpy(c.data, p + 12, c.len);
    s->reorder[s->reorder_count++] = c;
    qsort(s->reorder, (size_t)s->reorder_count, sizeof(in_chunk), cmp_in);
}

/* ---- inbound SACK ---- */

static void update_rto(gf_sctp *s, uint64_t rtt)
{
    if (!s->have_rtt) {
        s->srtt_us = rtt;
        s->rttvar_us = rtt / 2;
        s->have_rtt = 1;
    } else {
        uint64_t diff = s->srtt_us > rtt ? s->srtt_us - rtt : rtt - s->srtt_us;
        s->rttvar_us = (3 * s->rttvar_us + diff) / 4;
        s->srtt_us = (7 * s->srtt_us + rtt) / 8;
    }
    uint64_t rto = s->srtt_us + 4 * s->rttvar_us;
    if (rto < RTO_MIN_US) rto = RTO_MIN_US;
    if (rto > RTO_MAX_US) rto = RTO_MAX_US;
    s->rto_us = rto;
}

static void handle_sack(gf_sctp *s, const uint8_t *p, size_t len)
{
    if (len < 12) return;
    uint32_t cum = get32(p);
    uint32_t rwnd = get32(p + 4);
    uint16_t ngaps = get16(p + 8);
    if (len < 12 + 4 * (size_t)ngaps) return;
    if (tsn_lt(cum, s->cum_acked)) return;         // old
    int advanced = tsn_lt(s->cum_acked, cum);
    s->cum_acked = cum;
    uint64_t rtt_sample = 0;
    int rtt_valid = 0;
    // mark acked
    for (int i = 0; i < s->out_count; i++) {
        out_chunk *c = &s->out[i];
        if (!c->sent) continue;
        int acked = tsn_le(c->tsn, cum);
        for (uint16_t g = 0; g < ngaps && !acked; g++) {
            uint32_t a = cum + get16(p + 12 + 4 * g), b = cum + get16(p + 14 + 4 * g);
            if (tsn_le(a, c->tsn) && tsn_le(c->tsn, b)) acked = 1;
        }
        if (acked) {
            if (!c->acked && c->rtx == 0 && !rtt_valid) { rtt_sample = s->now - c->sent_us; rtt_valid = 1; }
            c->acked = 1;
        }
    }
    if (rtt_valid) update_rto(s, rtt_sample);
    // drop everything cumulatively acked from the head
    int keep = 0;
    for (int i = 0; i < s->out_count; i++) {
        if (tsn_le(s->out[i].tsn, cum)) { free(s->out[i].data); continue; }
        s->out[keep++] = s->out[i];
    }
    s->out_count = keep;
    // fast retransmit: a chunk passed over by three SACKs
    uint32_t highest_acked = cum;
    for (uint16_t g = 0; g < ngaps; g++) { uint32_t b = cum + get16(p + 14 + 4 * g); if (tsn_lt(highest_acked, b)) highest_acked = b; }
    for (int i = 0; i < s->out_count; i++) {
        out_chunk *c = &s->out[i];
        if (c->sent && !c->acked && tsn_lt(c->tsn, highest_acked)) {
            if (++c->miss_reports == 3) { c->sent = 0; c->rtx++; s->retransmits++; }
        }
    }
    size_t flight = outstanding_bytes(s);
    s->peer_rwnd = rwnd > flight ? rwnd - (uint32_t)flight : 0;
    if (advanced) {
        s->rtx_errors = 0;
        if (s->cwnd < 64 * 1024) s->cwnd += MAX_PACKET;
        s->t3_deadline = flight ? s->now + s->rto_us : UINT64_MAX;
    }
    flush(s);
}

/* ---- control chunks ---- */

static void handle_init_ack(gf_sctp *s, const uint8_t *p, size_t len)
{
    if (s->state != ST_COOKIE_WAIT || len < 16) return;
    s->peer_vtag = get32(p);
    s->peer_rwnd = get32(p + 4);
    uint16_t os = get16(p + 8), mis = get16(p + 10);
    if (os && os < s->in_streams) s->in_streams = os;
    if (mis && mis < s->out_streams) s->out_streams = mis;
    s->cum_tsn_in = get32(p + 12) - 1;
    s->have_cum_in = 1;
    size_t off = 16;
    free(s->cookie);
    s->cookie = NULL;
    s->cookie_len = 0;
    while (off + 4 <= len) {
        uint16_t type = get16(p + off), plen = get16(p + off + 2);
        if (plen < 4 || off + plen > len) break;
        if (type == PARAM_STATE_COOKIE) {
            s->cookie_len = plen - 4;
            s->cookie = (uint8_t *)malloc(s->cookie_len ? s->cookie_len : 1);
            if (s->cookie) memcpy(s->cookie, p + off + 4, s->cookie_len);
        }
        off += (plen + 3) & ~3u;
    }
    if (!s->cookie) { closed(s, "INIT ACK without a cookie"); return; }
    uint8_t body[MAX_PACKET];
    if (s->cookie_len + 4 > sizeof(body)) { closed(s, "cookie too large"); return; }
    size_t n = chunk_header(body, CHUNK_COOKIE_ECHO, 0, 4 + s->cookie_len);
    memcpy(body + 4, s->cookie, s->cookie_len);
    if (n > 4 + s->cookie_len) memset(body + 4 + s->cookie_len, 0, n - 4 - s->cookie_len);
    send_packet(s, s->peer_vtag, body, n);
    s->state = ST_COOKIE_ECHOED;
    s->t1_tries = 0;
    s->t1_deadline = s->now + s->rto_us;
}

static void handle_cookie_ack(gf_sctp *s)
{
    if (s->state != ST_COOKIE_ECHOED) return;
    s->state = ST_ESTABLISHED;
    s->t1_deadline = UINT64_MAX;
    s->hb_deadline = s->now + 15000000ULL;
    if (s->cb.on_connected) s->cb.on_connected(s->cb.ctx);
    flush(s);
}

static void handle_heartbeat(gf_sctp *s, const uint8_t *p, size_t len)
{
    uint8_t body[MAX_PACKET];
    if (len + 4 > sizeof(body)) return;
    size_t n = chunk_header(body, CHUNK_HEARTBEAT_ACK, 0, 4 + len);
    memcpy(body + 4, p, len);
    if (n > 4 + len) memset(body + 4 + len, 0, n - 4 - len);
    send_packet(s, s->peer_vtag, body, n);
}

static void handle_forward_tsn(gf_sctp *s, const uint8_t *p, size_t len)
{
    if (len < 4) return;
    uint32_t new_cum = get32(p);
    if (tsn_le(new_cum, s->cum_tsn_in)) return;
    s->cum_tsn_in = new_cum;
    // drop held chunks now behind, deliver what became in order
    int keep = 0;
    for (int i = 0; i < s->reorder_count; i++) {
        if (tsn_le(s->reorder[i].tsn, s->cum_tsn_in)) { free(s->reorder[i].data); continue; }
        s->reorder[keep++] = s->reorder[i];
    }
    s->reorder_count = keep;
    int progressed = 1;
    while (progressed && s->reorder_count) {
        progressed = 0;
        if (s->reorder[0].tsn == s->cum_tsn_in + 1) {
            in_chunk held = s->reorder[0];
            memmove(&s->reorder[0], &s->reorder[1], (size_t)(s->reorder_count - 1) * sizeof(in_chunk));
            s->reorder_count--;
            s->cum_tsn_in = held.tsn;
            accept_chunk(s, &held);
            free(held.data);
            progressed = 1;
        }
    }
    s->sack_pending = 1;
}

void gf_sctp_input(gf_sctp *s, const uint8_t *pkt, size_t len, uint64_t now_us)
{
    s->now = now_us;
    if (s->state == ST_CLOSED || len < 12) return;
    uint32_t vtag = get32(pkt + 4);
    {
        uint8_t tmp[1600];
        if (len > sizeof(tmp)) return;
        memcpy(tmp, pkt, len);
        memset(tmp + 8, 0, 4);
        uint32_t crc = gf_crc32c(tmp, len);
        uint32_t got = (uint32_t)pkt[8] | ((uint32_t)pkt[9] << 8) | ((uint32_t)pkt[10] << 16) | ((uint32_t)pkt[11] << 24);
        if (crc != got) return;
    }
    size_t off = 12;
    int first = 1;
    while (off + 4 <= len) {
        uint8_t type = pkt[off], flags = pkt[off + 1];
        size_t clen = get16(pkt + off + 2);
        if (clen < 4 || off + clen > len) break;
        const uint8_t *val = pkt + off + 4;
        size_t vlen = clen - 4;
        if (type == CHUNK_INIT_ACK) {
            if (vtag == s->my_vtag) handle_init_ack(s, val, vlen);
        } else if (vtag != s->my_vtag && type != CHUNK_INIT && type != CHUNK_ABORT) {
            break;      // not for this association
        } else {
            switch (type) {
                case CHUNK_DATA: handle_data(s, val, vlen, flags); break;
                case CHUNK_SACK: handle_sack(s, val, vlen); break;
                case CHUNK_HEARTBEAT: handle_heartbeat(s, val, vlen); break;
                case CHUNK_HEARTBEAT_ACK: break;
                case CHUNK_COOKIE_ACK: handle_cookie_ack(s); break;
                case CHUNK_ABORT: closed(s, "peer aborted"); return;
                case CHUNK_SHUTDOWN: {
                    uint8_t body[8];
                    size_t n = chunk_header(body, CHUNK_SHUTDOWN_ACK, 0, 4);
                    send_packet(s, s->peer_vtag, body, n);
                    closed(s, "peer shut down");
                    return;
                }
                case CHUNK_SHUTDOWN_ACK: {
                    uint8_t body[8];
                    size_t n = chunk_header(body, CHUNK_SHUTDOWN_COMPLETE, 0, 4);
                    send_packet(s, s->peer_vtag, body, n);
                    closed(s, "shutdown complete");
                    return;
                }
                case CHUNK_FORWARD_TSN: handle_forward_tsn(s, val, vlen); break;
                case CHUNK_ERROR: break;
                case CHUNK_INIT: break;     // the server never initiates here
                default: break;
            }
        }
        first = 0;
        off += (clen + 3) & ~(size_t)3;
    }
    (void)first;
    if (s->sack_pending && s->state == ST_ESTABLISHED) send_sack(s);
}

/* ---- timers ---- */

uint64_t gf_sctp_next_timeout(const gf_sctp *s)
{
    uint64_t t = s->t1_deadline;
    if (s->t3_deadline < t) t = s->t3_deadline;
    if (s->hb_deadline < t) t = s->hb_deadline;
    return t;
}

void gf_sctp_tick(gf_sctp *s, uint64_t now_us)
{
    s->now = now_us;
    if (s->state == ST_CLOSED) return;
    if (now_us >= s->t1_deadline) {
        if (++s->t1_tries > 8) { closed(s, "no answer to INIT/COOKIE"); return; }
        s->rto_us = s->rto_us * 2 > RTO_MAX_US ? RTO_MAX_US : s->rto_us * 2;
        if (s->state == ST_COOKIE_WAIT) {
            send_init(s);
        } else if (s->state == ST_COOKIE_ECHOED && s->cookie) {
            uint8_t body[MAX_PACKET];
            size_t n = chunk_header(body, CHUNK_COOKIE_ECHO, 0, 4 + s->cookie_len);
            memcpy(body + 4, s->cookie, s->cookie_len);
            if (n > 4 + s->cookie_len) memset(body + 4 + s->cookie_len, 0, n - 4 - s->cookie_len);
            send_packet(s, s->peer_vtag, body, n);
        }
        s->t1_deadline = now_us + s->rto_us;
    }
    if (now_us >= s->t3_deadline) {
        if (++s->rtx_errors > MAX_RTX) { closed(s, "too many retransmissions"); return; }
        s->rto_us = s->rto_us * 2 > RTO_MAX_US ? RTO_MAX_US : s->rto_us * 2;
        s->cwnd = MAX_PACKET;
        // the earliest unacked chunks go again
        size_t budget = MAX_PACKET;
        for (int i = 0; i < s->out_count && budget > 0; i++) {
            out_chunk *c = &s->out[i];
            if (c->sent && !c->acked) {
                if (c->len + 16 > budget) break;
                budget -= c->len + 16;
                c->sent = 0;
                c->rtx++;
                s->retransmits++;
            }
        }
        s->t3_deadline = now_us + s->rto_us;
        flush(s);
    }
    if (now_us >= s->hb_deadline) {
        uint8_t body[16];
        size_t n = chunk_header(body, CHUNK_HEARTBEAT, 0, 12);
        put16(body + 4, 1);
        put16(body + 6, 8);
        put32(body + 8, (uint32_t)(now_us / 1000));
        send_packet(s, s->peer_vtag, body, n);
        s->hb_deadline = now_us + 15000000ULL;
    }
}

int gf_sctp_selftest(void)
{
    // CRC32c check value for "123456789" is 0xE3069283
    return gf_crc32c((const uint8_t *)"123456789", 9) == 0xE3069283u;
}
