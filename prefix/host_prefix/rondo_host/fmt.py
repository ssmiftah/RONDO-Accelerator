"""Element formats: bf16 (RNE from fp32) and fp32 encode/decode (spec 14.4)."""
import numpy as np


def to_bits(v, wb):
    """float(s) -> W-bit pattern(s); bf16 uses round-to-nearest-even of the fp32 value
    (same as sim/test_fused_bf16.py:26-30). Returns an int for scalars, an array otherwise."""
    a = np.asarray(v, dtype=np.float32)
    u = a.view(np.uint32).astype(np.uint64) if a.ndim else np.uint64(a.view(np.uint32))
    if wb == 32:
        r = u & np.uint64(0xFFFFFFFF)
    else:
        # NaN keeps a quiet payload; finite/inf follow the +0x7FFF+lsb RNE trick
        up = (u >> np.uint64(16)) + ((u >> np.uint64(15)) & np.uint64(1))
        r = up & np.uint64(0xFFFF)
    return int(r) if np.ndim(r) == 0 else r.astype(np.uint32)


def from_bits(b, wb):
    a = np.asarray(b, dtype=np.uint64) & np.uint64(0xFFFFFFFF if wb == 32 else 0xFFFF)
    u = a.astype(np.uint32) if wb == 32 else (a.astype(np.uint32) << np.uint32(16))
    f = u.view(np.float32) if np.ndim(u) else np.uint32(u).view(np.float32)
    return float(f) if np.ndim(f) == 0 else f


def exp_bits(b, wb):
    sig = 24 if wb == 32 else 8
    return (int(b) >> (sig - 1)) & 0xFF


def is_naninf(b, wb):
    return exp_bits(b, wb) == 0xFF


QNAN = {16: 0x7FC0, 32: 0x7FC00000}
EPS = {16: 0x3C24, 32: 0x3C23D70A}
