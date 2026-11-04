"""Bit-exact model of kan_layer_pipe / kan_layer_bf16, in the RTL's operation order.

Every FMA is modelled as p = round(a*b + c) with ONE rounding (exact rational
arithmetic, round-to-nearest-even), at any (EXP, SIG) in HardFloat's convention
(SIG includes the leading bit: fp32 = (8, 24), bf16 = (8, 8)).

Operation order, which is what the RTL fixes and what makes the model exact:
  basis   T0 = 1, T1 = x, T_{n+1} = FMA(2x, T_n, -T_{n-1})       (2x is exact)
  partial S[o,n] = FMA(c[o,i,n], T_n(x_i), S[o,n]) for i = 0..p-1, S starts +0
  combine balanced tree over n: level s = 1,2,4,..: S[n] = FMA(S[n+s], 1, S[n])
          for n = 0, 2s, 4s, ... with n+s <= D; y_o = S[0]

This differs from workloads/kan_golden.py's bf16/fp32 emulation, which
accumulates one running sum over (i, n) and rounds the product and the sum
separately. Both are exact in fp64; they differ only in rounding. The fp64
reference is the one the fidelity numbers are measured against.
"""
from fractions import Fraction
import numpy as np


class Fmt:
    def __init__(self, exp, sig):
        self.E, self.S = exp, sig
        self.W = exp + sig
        self.F = sig - 1                     # fraction bits
        self.bias = (1 << (exp - 1)) - 1
        self.emin = 1 - self.bias
        self.emax_b = (1 << exp) - 1

    # ---- bits <-> exact value --------------------------------------------
    def val(self, bits):
        s = (bits >> (self.W - 1)) & 1
        e = (bits >> self.F) & self.emax_b
        m = bits & ((1 << self.F) - 1)
        if e == self.emax_b:
            raise ValueError("inf/nan in model")
        if e == 0:
            v = Fraction(m) * Fraction(2) ** (self.emin - self.F)
        else:
            v = Fraction((1 << self.F) + m) * Fraction(2) ** (e - self.bias - self.F)
        return (-v if s else v), s

    def bits(self, v, zsign=0):
        """Round exact rational v to this format (RNE). zsign: sign of an exact 0."""
        if v == 0:
            return zsign << (self.W - 1)
        s = 1 if v < 0 else 0
        a = -v if s else v
        # e = floor(log2 a)
        e = a.numerator.bit_length() - a.denominator.bit_length()
        if Fraction(2) ** e > a:
            e -= 1
        elif Fraction(2) ** (e + 1) <= a:
            e += 1
        qe = (self.emin - self.F) if e < self.emin else (e - self.F)
        t = a / Fraction(2) ** qe
        M = t.numerator // t.denominator
        r = t - M
        if r > Fraction(1, 2) or (r == Fraction(1, 2) and (M & 1)):
            M += 1
        if M == (1 << (self.F + 1)):
            M >>= 1
            qe += 1
        if M < (1 << self.F):                 # subnormal
            be, frac = 0, M
        else:
            be, frac = qe + self.F + self.bias, M - (1 << self.F)
        if be >= self.emax_b:
            return (s << (self.W - 1)) | (self.emax_b << self.F)
        return (s << (self.W - 1)) | (be << self.F) | frac

    def from_float(self, x):
        """Host-side quantisation of an fp64 value (RNE)."""
        return self.bits(Fraction(float(x)))

    def to_float(self, bits):
        v, _ = self.val(bits)
        return float(v)

    def fma(self, a, b, c):
        va, sa = self.val(a)
        vb, sb = self.val(b)
        vc, sc = self.val(c)
        r = va * vb + vc
        if r == 0:
            sp = sa ^ sb
            zs = sp if (va * vb == 0 and vc == 0 and sp == sc) else 0
            return self.bits(r, zs)
        return self.bits(r)

    def neg(self, b):
        return b ^ (1 << (self.W - 1))

    def one(self):
        return self.bias << self.F


FP32 = Fmt(8, 24)
BF16 = Fmt(8, 8)


def kan_layer_bits(fmt, xbits, cbits):
    """xbits [p] ints, cbits [O][p][D+1] ints -> y bits [O]."""
    p = len(xbits)
    O = len(cbits)
    Dp1 = len(cbits[0][0])
    one = fmt.one()
    T = []
    for i in range(p):
        x = xbits[i]
        x2 = fmt.bits(2 * fmt.val(x)[0], fmt.val(x)[1])
        row = [one, x]
        for n in range(1, Dp1 - 1):
            row.append(fmt.fma(x2, row[n], fmt.neg(row[n - 1])))
        T.append(row[:Dp1])
    ys = []
    for o in range(O):
        S = [0] * Dp1
        for i in range(p):
            for n in range(Dp1):
                S[n] = fmt.fma(cbits[o][i][n], T[i][n], S[n])
        s = 1
        while s < Dp1:
            for n in range(0, Dp1, 2 * s):
                if n + s < Dp1:
                    S[n] = fmt.fma(S[n + s], one, S[n])
            s *= 2
        ys.append(S[0])
    return ys
