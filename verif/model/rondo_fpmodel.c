#include "rondo_fpmodel.h"
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

#define NL 11
typedef struct { uint64_t w[NL]; } bn;

static void bn_zero(bn *a) { memset(a, 0, sizeof *a); }
static int bn_iszero(const bn *a) { for (int i = 0; i < NL; i++) if (a->w[i]) return 0; return 1; }
static void bn_from_u64_shl(bn *a, uint64_t v, int sh) {
    bn_zero(a); int q = sh / 64, r = sh % 64;
    if (q < NL) a->w[q] |= v << r;
    if (r && q + 1 < NL) a->w[q + 1] |= v >> (64 - r);
}
static int bn_cmp(const bn *a, const bn *b) {
    for (int i = NL - 1; i >= 0; i--) { if (a->w[i] > b->w[i]) return 1; if (a->w[i] < b->w[i]) return -1; } return 0;
}
static void bn_add(bn *r, const bn *a, const bn *b) {
    unsigned __int128 c = 0; for (int i = 0; i < NL; i++) { c += (unsigned __int128)a->w[i] + b->w[i]; r->w[i] = (uint64_t)c; c >>= 64; }
}
static void bn_sub(bn *r, const bn *a, const bn *b) { // a >= b
    uint64_t br = 0; for (int i = 0; i < NL; i++) { uint64_t x = a->w[i], y = b->w[i]; uint64_t d = x - y - br; br = (x < y) || (x == y && br) ? 1 : 0; r->w[i] = d; }
}
static int bn_msb(const bn *a) { for (int i = NL - 1; i >= 0; i--) if (a->w[i]) return i * 64 + 63 - __builtin_clzll(a->w[i]); return -1; }
static int bn_bit(const bn *a, int n) { if (n < 0) return 0; if (n >= NL * 64) return 0; return (a->w[n / 64] >> (n % 64)) & 1; }
static int bn_any_below(const bn *a, int n) { // any bit with index < n
    for (int i = 0; i < n; ) { if (i % 64 == 0 && i + 64 <= n) { if (a->w[i / 64]) return 1; i += 64; } else { if (bn_bit(a, i)) return 1; i++; } } return 0;
}
static uint64_t bn_extract(const bn *a, int lo, int nbits) { uint64_t v = 0; for (int i = 0; i < nbits; i++) v |= (uint64_t)bn_bit(a, lo + i) << i; return v; }

void fpm_fmt_init(fpm_fmt_t *f, int exp, int sig) {
    f->exp = exp; f->sig = sig; f->w = exp + sig; f->bias = (1 << (exp - 1)) - 1; f->fr = sig - 1; f->emax = f->bias; f->emin = 1 - f->bias;
    f->inf = ((1ull << exp) - 1) << f->fr; f->qnan = f->inf | (1ull << (f->fr - 1));
}
static int is_special(const fpm_fmt_t *f, uint64_t v) { return ((v >> f->fr) & ((1ull << f->exp) - 1)) == ((1ull << f->exp) - 1); }
static int is_nan(const fpm_fmt_t *f, uint64_t v) { return is_special(f, v) && (v & ((1ull << f->fr) - 1)); }
static int is_zero(const fpm_fmt_t *f, uint64_t v) { return (v & ((1ull << (f->w - 1)) - 1)) == 0; }

static void decode(const fpm_fmt_t *f, uint64_t v, int *s, uint64_t *m, int *lexp) {
    *s = (v >> (f->w - 1)) & 1; uint64_t e = (v >> f->fr) & ((1ull << f->exp) - 1), fr = v & ((1ull << f->fr) - 1);
    if (e == 0) { *m = fr; *lexp = f->emin - f->fr; } else { *m = fr | (1ull << f->fr); *lexp = (int)e - f->bias - f->fr; }
}

uint64_t fpm_fma_f(const fpm_fmt_t *f, uint64_t a, uint64_t b, uint64_t c) {
    uint64_t signb = 1ull << (f->w - 1);
    int sa = (a >> (f->w - 1)) & 1, sb = (b >> (f->w - 1)) & 1, sc = (c >> (f->w - 1)) & 1, sp = sa ^ sb;
    if (is_nan(f, a) || is_nan(f, b) || is_nan(f, c)) return f->qnan;
    int ia = is_special(f, a), ib = is_special(f, b), ic = is_special(f, c);
    if (ia || ib) {
        if ((ia && is_zero(f, b)) || (ib && is_zero(f, a))) return f->qnan;      // Inf * 0
        if (ic && sc != sp) return f->qnan;                                        // Inf - Inf
        return (sp ? signb : 0) | f->inf;
    }
    if (ic) return (sc ? signb : 0) | f->inf;
    int ea, eb, ec; uint64_t ma, mb, mc; int t;
    decode(f, a, &t, &ma, &ea); decode(f, b, &t, &mb, &eb); decode(f, c, &t, &mc, &ec);
    uint64_t pm = ma * mb; int pe = ea + eb;
    if (pm == 0 && mc == 0) return (uint64_t)(sp & sc) << (f->w - 1);
    int base; bn P, C, R; int rs;
    if (pm == 0) { base = ec; bn_from_u64_shl(&R, mc, 0); rs = sc; }
    else if (mc == 0) { base = pe; bn_from_u64_shl(&R, pm, 0); rs = sp; }
    else {
        base = pe < ec ? pe : ec;
        bn_from_u64_shl(&P, pm, pe - base); bn_from_u64_shl(&C, mc, ec - base);
        if (sp == sc) { bn_add(&R, &P, &C); rs = sp; }
        else { int cm = bn_cmp(&P, &C); if (cm == 0) return 0; if (cm > 0) { bn_sub(&R, &P, &C); rs = sp; } else { bn_sub(&R, &C, &P); rs = sc; } }
    }
    int n = bn_msb(&R); int e = n + base; if (e < f->emin) e = f->emin;
    int et = e - f->fr; int sh = et - base; uint64_t ni;
    if (sh <= 0) { ni = bn_extract(&R, 0, 64) << (-sh); }
    else {
        ni = bn_extract(&R, sh, 40); int rb = bn_bit(&R, sh - 1); int st = bn_any_below(&R, sh - 1);
        if (rb && (st || (ni & 1))) ni++;
    }
    if (ni == (1ull << f->sig)) { ni >>= 1; e++; et++; }
    if (e > f->emax) return (rs ? signb : 0) | f->inf;
    if (ni < (1ull << f->fr)) return (rs ? signb : 0) | ni;
    return (rs ? signb : 0) | ((uint64_t)(e + f->bias) << f->fr) | (ni & ((1ull << f->fr) - 1));
}

uint64_t fpm_widen_f(const fpm_fmt_t *fa, const fpm_fmt_t *f, uint64_t v) { return v << (fa->sig - f->sig); }
uint64_t fpm_narrow_f(const fpm_fmt_t *fa, const fpm_fmt_t *f, uint64_t u) {
    int sh = fa->sig - f->sig; if (sh == 0) return u;
    int rb = (u >> (sh - 1)) & 1, st = (sh > 1 && (u & ((1ull << (sh - 1)) - 1))) ? 1 : 0, lsb = (u >> sh) & 1;
    return ((u >> sh) + (rb & (st | lsb))) & ((1ull << f->w) - 1);
}

uint64_t fpm_recip_f(const fpm_fmt_t *f, uint64_t k0, uint64_t k1, const uint32_t *seed, int tbits, uint64_t eps, int nr, int *hit) {
    int w = f->w; uint64_t sgn = (k0 >> (w - 1)) & 1, mag = k0 & ((1ull << (w - 1)) - 1), epsm = eps & ((1ull << (w - 1)) - 1);
    int h = mag < epsm; uint64_t b = (sgn << (w - 1)) | (h ? epsm : mag);
    int64_t bexp = (b >> f->fr) & ((1ull << f->exp) - 1); uint64_t bfrac = b & ((1ull << f->fr) - 1);
    uint64_t tidx = bfrac >> (f->fr - tbits); int64_t esum = 2 * f->bias - 1, e0f = esum - bexp, e0;
    if (e0f <= 0) e0 = 1; else if (e0f > (1 << f->exp) - 2) e0 = (1 << f->exp) - 2; else e0 = e0f;
    uint64_t x = (sgn << (w - 1)) | ((uint64_t)e0 << f->fr) | seed[tidx];
    uint64_t nb = b ^ (1ull << (w - 1)), two = (uint64_t)(f->bias + 1) << f->fr;
    for (int i = 0; i < nr; i++) { uint64_t t = fpm_fma_f(f, nb, x, two); x = fpm_fma_f(f, x, t, 0); }
    if (hit) *hit = h;
    return fpm_fma_f(f, k1, x, 0);
}

/* ---------------- stateful layer model ---------------- */
#define MAXW 64
#define MAXD 8
#define MAXP 64
static uint32_t seed_t[3][1 << 12];   // 0: e8s8_t6, 1: e8s24_t8, 2: e8s24_t12
static int seed_ok[3];
static int G_w = 16, G_p = 8, G_d = 7, G_l = 2, G_ns = 8, G_np = 8, G_nx = 4, G_nlad, G_nch, G_ngrp, G_nb, G_nwords, G_nbwords;
static uint64_t *Wp, *Bp;       // [lane][nwords][npar], [lane][nbwords][npar]
static uint64_t X[MAXP * 2];
static uint64_t Z[MAXW], A[MAXW][MAXD], ACC[MAXW][MAXD], K0[MAXW], K1[MAXW], PS[MAXW][MAXD];
static int HIT[MAXW];

int fpm_load_seed(int sig, int tbits, const char *dir) {
    int idx = (sig == 8) ? 0 : (tbits == 8 ? 1 : 2); char p[1024]; snprintf(p, sizeof p, "%s/recip_seed_e8s%d_t%d.mem", dir, sig, tbits);
    FILE *fp = fopen(p, "r"); if (!fp) return -1; unsigned v; int n = 0;
    while (n < (1 << tbits) && fscanf(fp, "%x", &v) == 1) seed_t[idx][n++] = v; fclose(fp);
    seed_ok[idx] = (n == (1 << tbits)); return seed_ok[idx] ? 0 : -2;
}
void fpm_cfg(int width, int pdim, int depth, int lanes, int nslot, int npar, int nxbuf) {
    G_w = width; G_p = pdim; G_d = depth; G_l = lanes; G_ns = nslot; G_np = npar; G_nx = nxbuf;
    G_nlad = width / lanes; G_nch = nslot * depth; G_ngrp = G_nch / npar; G_nb = G_nlad / nslot; G_nwords = G_nb * G_ngrp * pdim; G_nbwords = G_nb * G_ngrp;
    free(Wp); free(Bp); Wp = calloc((size_t)lanes * G_nwords * npar, 8); Bp = calloc((size_t)lanes * G_nbwords * npar, 8);
}
void fpm_set_w(int lane, int caddr, int field, uint64_t bits) { if (lane < G_l && caddr < G_nwords && field < G_np) Wp[((size_t)lane * G_nwords + caddr) * G_np + field] = bits; }
void fpm_set_b(int lane, int caddr, int field, uint64_t bits) { if (lane < G_l && caddr < G_nbwords && field < G_np) Bp[((size_t)lane * G_nbwords + caddr) * G_np + field] = bits; }
void fpm_set_x(int i, uint64_t bits) { if (i >= 0 && i < MAXP * 2) X[i] = bits; }
void fpm_set_w_logical(int j, int k, int c, uint64_t bits) { int l, a, f; fpm_weight_addr(j, k, c, &l, &a, &f); fpm_set_w(l, a, f, bits); }
void fpm_set_b_logical(int j, int k, uint64_t bits) { int l, a, f; fpm_weight_addr(j, k, 0, &l, &a, &f); fpm_set_b(l, a / G_p, f, bits); }
void fpm_weight_addr(int j, int k, int c, int *lane, int *caddr, int *field) {
    int l = j / G_nlad, r = j % G_nlad, b = r / G_ns, s = r % G_ns, ch = s * G_d + k, g = ch / G_np, f = ch % G_np;
    *lane = l; *caddr = (b * G_ngrp + g) * G_p + c; *field = f;
}
static uint64_t gw_(int j, int k, int c) { int l, a, f; fpm_weight_addr(j, k, c, &l, &a, &f); return Wp[((size_t)l * G_nwords + a) * G_np + f]; }
static uint64_t gb_(int j, int k) { int l, a, f; fpm_weight_addr(j, k, 0, &l, &a, &f); a = a / G_p; return Bp[((size_t)l * G_nbwords + a) * G_np + f]; }

static void cfg_fmt(int is_fp32, int accsig, int tbits, fpm_fmt_t *f, fpm_fmt_t *fa, const uint32_t **seed, uint64_t *eps) {
    fpm_fmt_init(f, 8, is_fp32 ? 24 : 8); fpm_fmt_init(fa, 8, accsig ? accsig : f->sig);
    *eps = is_fp32 ? 0x3C23D70Aull : 0x3C24ull; int idx = is_fp32 ? (tbits == 8 ? 1 : 2) : 0; *seed = seed_t[idx];
}
static void finish(const fpm_fmt_t *f, const fpm_fmt_t *fa, const uint32_t *seed, int tbits, uint64_t eps, int nr, int lane_mask, int do_a) {
    for (int j = 0; j < G_w; j++) {
        int lane = j / G_nlad;
        if (!((lane_mask >> lane) & 1)) { Z[j] = f->qnan; HIT[j] = 0; continue; }
        uint64_t one = (uint64_t)f->bias << f->fr, lo, hi;
        if (do_a) for (int k = 0; k < G_d; k++) A[j][k] = fpm_narrow_f(fa, f, ACC[j][k]);
        lo = A[j][G_d - 1]; hi = one;
        for (int k = G_d - 2; k >= 0; k--) { uint64_t n = fpm_fma_f(f, A[j][k], lo, hi); hi = lo; lo = n; }
        K0[j] = lo; K1[j] = hi; int h; Z[j] = fpm_recip_f(f, lo, hi, seed, tbits, eps, nr, &h); HIT[j] = h;
    }
}
void fpm_run(int is_fp32, int accsig, int tbits, int nr, int lane_mask) {
    fpm_fmt_t f, fa; const uint32_t *seed; uint64_t eps; cfg_fmt(is_fp32, accsig, tbits, &f, &fa, &seed, &eps);
    for (int j = 0; j < G_w; j++) for (int k = 0; k < G_d; k++) {
        uint64_t acc = fpm_widen_f(&fa, &f, gb_(j, k));
        for (int c = 0; c < G_p; c++) acc = fpm_fma_f(&fa, fpm_widen_f(&fa, &f, gw_(j, k, c)), fpm_widen_f(&fa, &f, X[c]), acc);
        ACC[j][k] = acc;
    }
    finish(&f, &fa, seed, tbits, eps, nr, lane_mask, 1);
}
void fpm_tile_slice(int is_fp32, int accsig, int tbits, int nr, int lane_mask, int first, int last) {
    fpm_fmt_t f, fa; const uint32_t *seed; uint64_t eps; cfg_fmt(is_fp32, accsig, tbits, &f, &fa, &seed, &eps);
    for (int j = 0; j < G_w; j++) for (int k = 0; k < G_d; k++) {
        uint64_t acc = first ? fpm_widen_f(&fa, &f, gb_(j, k)) : PS[j][k];
        for (int c = 0; c < G_p; c++) acc = fpm_fma_f(&fa, fpm_widen_f(&fa, &f, gw_(j, k, c)), fpm_widen_f(&fa, &f, X[c]), acc);
        ACC[j][k] = acc; PS[j][k] = acc;
    }
    if (last) finish(&f, &fa, seed, tbits, eps, nr, lane_mask, 1);
}
uint64_t fpm_recip(int is_fp32, int tbits, int nr, uint64_t k0, uint64_t k1) {
    fpm_fmt_t f, fa; const uint32_t *seed; uint64_t eps; cfg_fmt(is_fp32, 0, tbits, &f, &fa, &seed, &eps); int h; uint64_t z = fpm_recip_f(&f, k0, k1, seed, tbits, eps, nr, &h); return z | ((uint64_t)h << 63);
}
uint64_t fpm_z(int j) { return Z[j]; } int fpm_hit(int j) { return HIT[j]; }
uint64_t fpm_a(int j, int k) { return A[j][k]; } uint64_t fpm_acc(int j, int k) { return ACC[j][k]; }
uint64_t fpm_k0(int j) { return K0[j]; } uint64_t fpm_k1(int j) { return K1[j]; }
uint64_t fpm_fma(int exp, int sig, uint64_t a, uint64_t b, uint64_t c) { fpm_fmt_t f; fpm_fmt_init(&f, exp, sig); return fpm_fma_f(&f, a, b, c); }

uint32_t fpm_crc8(uint32_t crc, uint32_t byte) { crc = (crc ^ byte) & 0xFF; for (int i = 0; i < 8; i++) crc = (crc & 0x80) ? ((crc << 1) ^ 0x07) & 0xFF : (crc << 1) & 0xFF; return crc; }
uint32_t fpm_crc32_update(uint32_t crc, uint32_t data, int nbytes) {
    uint32_t c = ~crc; for (int i = 0; i < nbytes; i++) { c ^= (data >> (8 * i)) & 0xFF; for (int k = 0; k < 8; k++) c = (c & 1) ? (c >> 1) ^ 0xEDB88320u : c >> 1; } return ~c;
}
uint32_t fpm_rotl32(uint32_t v, int r) { r &= 31; return r ? (v << r) | (v >> (32 - r)) : v; }
uint32_t fpm_cksum_update(uint32_t cks, int w) {
    uint32_t s = 0; for (int j = 0; j < G_w; j++) s += fpm_rotl32((uint32_t)(Z[j] & ((w >= 32) ? 0xFFFFFFFFull : ((1ull << w) - 1))), j % 32);
    return fpm_rotl32(cks, 1) + s;
}
uint32_t fpm_lfsr_next(uint32_t s) { uint32_t l = s & 1; s >>= 1; if (l) s ^= 0x80200003u; return s; }
uint64_t fpm_kat_element(uint32_t r, int w) {
    int sig = (w == 16) ? 8 : 24, fr = sig - 1; uint64_t s = (r >> 31) & 1, e = 127 - 2 + ((r >> 29) & 3), m = (r >> (29 - fr)) & ((1ull << fr) - 1);
    return (s << (w - 1)) | (e << fr) | m;
}
