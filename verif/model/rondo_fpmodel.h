// C port of sim/fpmodel.py + packing/CRC/checksum/LFSR helpers (host/rondo_host/packing.py, protocol.py).
// Exact integer arithmetic (704-bit fixed point), no floating point. Scalar DPI-C API at the end.
#ifndef RONDO_FPMODEL_H
#define RONDO_FPMODEL_H
#include <stdint.h>
typedef struct { int exp, sig, w, bias, fr, emax, emin; uint64_t qnan, inf; } fpm_fmt_t;
void fpm_fmt_init(fpm_fmt_t *f, int exp, int sig);
// fma: RNE, subnormals, overflow to Inf, zero-sign rule sa&sc; Inf/NaN per RISC-V rules (class level; not validated vs RTL)
uint64_t fpm_fma_f(const fpm_fmt_t *f, uint64_t a, uint64_t b, uint64_t c);
uint64_t fpm_widen_f(const fpm_fmt_t *fa, const fpm_fmt_t *f, uint64_t v);
uint64_t fpm_narrow_f(const fpm_fmt_t *fa, const fpm_fmt_t *f, uint64_t u);
// recip stage: returns z; *hit = guard hit. seed has 2^tbits entries.
uint64_t fpm_recip_f(const fpm_fmt_t *f, uint64_t k0, uint64_t k1, const uint32_t *seed, int tbits, uint64_t eps, int nr, int *hit);
// scalar DPI API
int      fpm_load_seed(int sig, int tbits, const char *dir);
void     fpm_cfg(int width, int pdim, int depth, int lanes, int nslot, int npar, int nxbuf);
void     fpm_set_w(int lane, int caddr, int field, uint64_t bits);
void     fpm_set_b(int lane, int caddr, int field, uint64_t bits);
void     fpm_set_w_logical(int j, int k, int c, uint64_t bits);
void     fpm_set_b_logical(int j, int k, uint64_t bits);
void     fpm_set_x(int i, uint64_t bits);
void     fpm_run(int is_fp32, int accsig, int tbits, int nr, int lane_mask);
void     fpm_tile_slice(int is_fp32, int accsig, int tbits, int nr, int lane_mask, int first, int last);
uint64_t fpm_recip(int is_fp32, int tbits, int nr, uint64_t k0, uint64_t k1);   // bit 63 = guard hit
uint64_t fpm_z(int j);   int fpm_hit(int j);
uint64_t fpm_a(int j, int k); uint64_t fpm_acc(int j, int k);
uint64_t fpm_k0(int j);  uint64_t fpm_k1(int j);
uint64_t fpm_fma(int exp, int sig, uint64_t a, uint64_t b, uint64_t c);
uint32_t fpm_crc8(uint32_t crc, uint32_t byte);
uint32_t fpm_crc32_update(uint32_t crc, uint32_t data, int nbytes);   // zlib-style running CRC (crc in/out are final values)
uint32_t fpm_cksum_update(uint32_t cks, int w);                       // uses z set by fpm_run (all lanes)
uint32_t fpm_rotl32(uint32_t v, int r);
uint32_t fpm_lfsr_next(uint32_t s);
uint64_t fpm_kat_element(uint32_t r, int w);
void     fpm_weight_addr(int j, int k, int c, int *lane, int *caddr, int *field);
#endif
