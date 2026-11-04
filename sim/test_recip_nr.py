"""recip_nr: pipelined pole-guarded reciprocal.

Checks three things the digit-recurrence version cannot give us:
  * accuracy -- against the same fp32 NR model the table was generated for
  * throughput -- a new operand accepted every cycle (II = 1)
  * the guard still holds inside the pole band
"""
import os
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01
TBITS = int(os.environ.get("WL_TBITS", "12"))


def guard(k0):
    return np.float32(np.sign(k0) * max(abs(float(k0)), EPS))


def model(k0, k1):
    """Bit-accurate model of the RTL: table seed, one NR iteration, then *k1."""
    b = guard(k0)
    u = np.float32(b).view(np.uint32)
    s, E, frac = int(u >> 31), int((u >> 23) & 0xFF), int(u & 0x7FFFFF)
    i = frac >> (23 - TBITS)
    m_mid = 1.0 + (i + 0.5) / (1 << TBITS)
    mant = min(max(int(round((2.0 / m_mid - 1.0) * (1 << 23))), 0), (1 << 23) - 1)
    e0 = (2 * 127 - 1) - E
    x0 = np.uint32((s << 31) | (e0 << 23) | mant).view(np.float32)
    t = np.float32(np.float64(-b) * np.float64(x0) + 2.0)      # fused
    x1 = np.float32(np.float64(x0) * np.float64(t))
    return np.float32(np.float64(k1) * np.float64(x1))


@cocotb.test()
async def recip_pipelined(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.inValid.value = 0
    dut.k0.value = 0
    dut.k1.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(3)
    mags = np.concatenate([rng.uniform(0.001, 1, 300),      # inside the guard band too
                           rng.uniform(1, 1e5, 300),
                           rng.uniform(1e5, 1e20, 200)])
    k0 = (mags * rng.choice([-1.0, 1.0], mags.size)).astype(np.float32)
    k1 = rng.uniform(-50, 50, mags.size).astype(np.float32)
    n = len(k0)

    # stream one operand per cycle; collect results as they emerge
    got, sent, recvd = [], 0, 0
    while recvd < n:
        if sent < n:
            dut.k0.value = f32_to_bits(k0[sent])
            dut.k1.value = f32_to_bits(k1[sent])
            dut.inValid.value = 1
            sent += 1
        else:
            dut.inValid.value = 0
        await RisingEdge(dut.clock)
        if dut.outValid.value == 1:
            got.append(bits_to_f32(int(dut.f.value)))
            recvd += 1
    dut.inValid.value = 0

    got = np.array(got, dtype=np.float32)
    exp = np.array([model(a, b) for a, b in zip(k0, k1)], dtype=np.float32)
    ulp = np.abs(got.view(np.int32) - exp.view(np.int32))
    assert ulp.max() == 0, f"{int((ulp>0).sum())}/{n} differ from the model, max {ulp.max()} ULP"

    # accuracy against exact arithmetic, and the guard
    ref = np.array([float(k1[i]) / float(guard(k0[i])) for i in range(n)])
    rel = np.abs(got.astype(np.float64) - ref) / (np.abs(ref) + 1e-30)
    inband = np.abs(k0) < EPS
    assert np.isfinite(got).all(), "non-finite output"
    assert rel.max() < 1e-6, f"accuracy vs exact: {rel.max():.2e}"

    dut._log.info(
        f"RECIP_NR TBITS={TBITS}: {n} operands, 0 ULP vs model, "
        f"max_rel_vs_exact={rel.max():.2e}, {int(inband.sum())} inside the guard band, "
        f"II=1 sustained")
