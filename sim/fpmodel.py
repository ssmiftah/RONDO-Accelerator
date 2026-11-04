"""Exact bit-level model of the RONDO layer (test-only scoreboard).

fma(a, b, c) is a single-rounded RNE fused multiply-add on (EXP, SIG) patterns
(finite inputs; Inf/NaN pass through as quiet NaN / Inf only where noted), used to
rebuild affine_bank_pipe, ladder_scan_inter and recip_nr_pipe bit for bit.
"""
from fractions import Fraction
from pathlib import Path

CORE = Path(__file__).resolve().parents[1] / "rtl" / "core"


class Fmt:
    def __init__(self, exp, sig):
        self.exp, self.sig = exp, sig
        self.w = exp + sig
        self.bias = (1 << (exp - 1)) - 1
        self.fr = sig - 1
        self.emax = self.bias
        self.emin = 1 - self.bias
        self.qnan = (((1 << exp) - 1) << self.fr) | (1 << (self.fr - 1))
        self.inf = ((1 << exp) - 1) << self.fr


BF16 = Fmt(8, 8)
FP32 = Fmt(8, 24)


def is_special(f, v):
    return ((v >> f.fr) & ((1 << f.exp) - 1)) == (1 << f.exp) - 1


def to_frac(f, v):
    s = (v >> (f.w - 1)) & 1
    e = (v >> f.fr) & ((1 << f.exp) - 1)
    m = v & ((1 << f.fr) - 1)
    if e == 0:
        val = Fraction(m, 1 << f.fr) * Fraction(2) ** f.emin
    else:
        val = (1 + Fraction(m, 1 << f.fr)) * Fraction(2) ** (e - f.bias)
    return -val if s else val


def round_frac(f, r, zero_sign=0):
    if r == 0:
        return zero_sign << (f.w - 1)
    s = 1 if r < 0 else 0
    a = -r if s else r
    # exponent e with 2^e <= a < 2^(e+1)
    num, den = a.numerator, a.denominator
    e = num.bit_length() - den.bit_length()
    if Fraction(2) ** e > a:
        e -= 1
    if e < f.emin:
        e = f.emin
    q = Fraction(2) ** (e - f.fr)
    n = a / q
    ni = n.numerator // n.denominator
    rem = n - ni
    if rem > Fraction(1, 2) or (rem == Fraction(1, 2) and (ni & 1)):
        ni += 1
    if ni == (1 << f.sig):
        ni >>= 1
        e += 1
    if e > f.emax:
        return (s << (f.w - 1)) | f.inf
    if ni < (1 << f.fr):            # subnormal
        return (s << (f.w - 1)) | ni
    return (s << (f.w - 1)) | ((e + f.bias) << f.fr) | (ni & ((1 << f.fr) - 1))


def fma(f, a, b, c):
    for v in (a, b, c):
        assert not is_special(f, v), "fpmodel: Inf/NaN operand"
    pa, pb = to_frac(f, a), to_frac(f, b)
    sa = ((a ^ b) >> (f.w - 1)) & 1
    sc = (c >> (f.w - 1)) & 1
    r = pa * pb + to_frac(f, c)
    return round_frac(f, r, zero_sign=(sa & sc))


def widen(f_acc, f, v):
    """Zero-extend a (EXP,SIG) pattern to (EXP,ACCSIG)."""
    sh = f_acc.sig - f.sig
    return v << sh


def narrow(f_acc, f, u):
    sh = f_acc.sig - f.sig
    if sh == 0:
        return u
    rbit = (u >> (sh - 1)) & 1
    sticky = 1 if (sh > 1 and (u & ((1 << (sh - 1)) - 1))) else 0
    lsb = (u >> sh) & 1
    up = rbit & (sticky | lsb)
    return ((u >> sh) + up) & ((1 << f.w) - 1)


def load_seed(sig, tbits):
    p = CORE / f"recip_seed_e8s{sig}_t{tbits}.mem"
    return [int(x, 16) for x in p.read_text().split()]


def recip_stage(f, k0, k1, seed, tbits, eps, nr_iters=1):
    """recip_nr_pipe: (guard_hit, f)."""
    w = f.w
    sgn = (k0 >> (w - 1)) & 1
    mag = k0 & ((1 << (w - 1)) - 1)
    epsm = eps & ((1 << (w - 1)) - 1)
    hit = 1 if mag < epsm else 0
    b = (sgn << (w - 1)) | (epsm if hit else mag)
    bexp = (b >> f.fr) & ((1 << f.exp) - 1)
    bfrac = b & ((1 << f.fr) - 1)
    tidx = bfrac >> (f.fr - tbits)
    esum = 2 * f.bias - 1
    e0f = esum - bexp
    if e0f < 0 or e0f == 0:                      # e0_full[EXP+1] || == 0
        e0 = 1
    elif e0f > (1 << f.exp) - 2:
        e0 = (1 << f.exp) - 2
    else:
        e0 = e0f
    # e0_full is EXP+2 bits: negative values wrap; esum-bexp < 0 only when bexp>esum
    x0 = (sgn << (w - 1)) | (e0 << f.fr) | seed[tidx]
    nb = b ^ (1 << (w - 1))
    two = (f.bias + 1) << f.fr
    x = x0
    for _ in range(nr_iters):
        t = fma(f, nb, x, two)
        x = fma(f, x, t, 0)
    return hit, fma(f, k1, x, 0)


def affine(f, f_acc, wv, xv, bv):
    """a = narrow(sum w*x + b) with the accumulator at ACCSIG; wv list of PDIM."""
    acc = widen(f_acc, f, bv)
    for c in range(len(xv)):
        acc = fma(f_acc, widen(f_acc, f, wv[c]), widen(f_acc, f, xv[c]), acc)
    return narrow(f_acc, f, acc)


def scan(f, a):
    d = len(a)
    one = f.bias << f.fr
    lo, hi = a[d - 1], one
    for k in range(d - 2, -1, -1):
        lo, hi = fma(f, a[k], lo, hi), lo
    return lo, hi         # K0, K1


def ladder(f, a, seed, tbits, eps, nr_iters=1):
    k0, k1 = scan(f, a)
    hit, z = recip_stage(f, k0, k1, seed, tbits, eps, nr_iters)
    return hit, z, k0, k1


def to_bits(f, v):
    """float -> pattern with RNE (via Fraction)."""
    import math
    if v == 0:
        return 0
    return round_frac(f, Fraction(v))


def from_bits(f, u):
    return float(to_frac(f, u))
