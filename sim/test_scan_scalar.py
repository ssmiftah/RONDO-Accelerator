"""ladder_scan_scalar: the continuant scan on one FMA.

Checked against a *scalar* fp32 FMA model, not the 2x2 fold's model. The two are
mathematically equivalent but round differently, so demanding bit-equality with
the 2x2 would be testing the wrong thing. What matters is that each matches its
own arithmetic exactly, and how close each lands to fp64 truth.
"""
import os
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

GEN = int(os.environ.get("COFR_GEN", "0"))


def fma32(a, b, c):
    return np.float32(np.float64(a) * np.float64(b) + np.float64(c))


def scalar_model(a, b=None):
    """Two rolling registers, one FMA per step -- exactly what the RTL does."""
    d = len(a)
    lo, hi = np.float32(a[d - 1]), np.float32(1.0)
    for k in range(d - 2, -1, -1):
        add = hi if b is None else np.float32(np.float64(b[k + 1]) * np.float64(hi))
        lo, hi = fma32(a[k], lo, add), lo
    return lo, hi


def f64_model(a, b=None):
    d = len(a)
    lo, hi = np.float64(a[d - 1]), 1.0
    for k in range(d - 2, -1, -1):
        add = hi if b is None else np.float64(b[k + 1]) * hi
        lo, hi = np.float64(a[k]) * lo + add, lo
    return lo, hi


@cocotb.test()
async def scan_scalar(dut):
    depth = len(dut.a) // 32
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(19)
    worst_ulp, rel32, rel64, cycles = 0, [], [], []
    for _ in range(60):
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.2).astype(np.float32)
        bb = (1.0 + rng.uniform(-0.3, 0.3, depth)).astype(np.float32) if GEN else None

        pa = sum((f32_to_bits(a[i]) & 0xFFFFFFFF) << (i * 32) for i in range(depth))
        dut.a.value = pa
        dut.b.value = (sum((f32_to_bits(bb[i]) & 0xFFFFFFFF) << (i * 32)
                           for i in range(depth)) if GEN else 0)
        dut.in_valid.value = 1
        await RisingEdge(dut.clock)
        dut.in_valid.value = 0
        n = 0
        while True:
            await RisingEdge(dut.clock)
            n += 1
            if dut.out_valid.value == 1:
                break
            assert n < depth * 8 + 40, "no out_valid"
        cycles.append(n)
        got = (bits_to_f32(int(dut.k0.value)), bits_to_f32(int(dut.k1.value)))
        exp32 = scalar_model(a, bb)
        exp64 = f64_model(a.astype(np.float64), bb.astype(np.float64) if GEN else None)
        for g, e32, e64 in zip(got, exp32, exp64):
            u = abs(int(np.float32(g).view(np.int32)) - int(np.float32(e32).view(np.int32)))
            worst_ulp = max(worst_ulp, u)
            rel32.append(abs(g - e32) / (abs(e32) + 1e-30))
            rel64.append(abs(float(g) - e64) / (abs(e64) + 1e-30))

    assert worst_ulp == 0, f"differs from its own fp32 model by {worst_ulp} ULP"
    dut._log.info(f"SCAN_SCALAR DEPTH={depth} GEN={GEN}: 60 vectors, 0 ULP vs fp32 model, "
                  f"max_rel_vs_fp64={max(rel64):.2e}, {np.mean(cycles):.1f} cycles")
