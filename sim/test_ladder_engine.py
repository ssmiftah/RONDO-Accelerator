"""Unit test for ladder_engine: iterative single ladder -> f, vs reference math.

Covers both unit numerators (GEN=0) and generalized numerators (GEN=1, learned
b). GEN is read from the COFR_GEN env var (set by the runner). Reference is the
fp64 continuant recurrence + pole-guarded ratio, times b0 for the generalized
case. Compared with a relative tolerance.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_ladder_top import f_reference

GEN = int(os.environ.get("COFR_GEN", "0"))
EPS = 0.01


def f_reference_gen(a, b):
    """f = sign(K1)*sign(K0)*|K1|/max(|K0|,eps) * b0, K via generalized recurrence."""
    d = len(a)
    a = np.asarray(a, np.float64); b = np.asarray(b, np.float64)
    K = np.ones(d + 2)
    K[d] = 1.0; K[d + 1] = 0.0; K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + b[k + 1] * K[k + 2]
    denom = max(abs(K[0]), EPS)
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / denom * b[0]


def _pack(v):
    p = 0
    for k in range(len(v)):
        p |= (f32_to_bits(v[k]) & 0xFFFFFFFF) << (32 * k)
    return p


async def reset(dut):
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def evaluate(dut, a, b):
    depth = len(a)
    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.a.value = _pack(a)
    dut.b.value = _pack(b)
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0
    for _ in range(depth + 60):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            return bits_to_f32(dut.f.value)
    raise TimeoutError("ladder_engine produced no out_valid")


@cocotb.test()
async def engine_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    depth = len(dut.a) // 32
    rng = np.random.default_rng(6)
    n = 100
    worst = 0.0
    for _ in range(n):
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.5).astype(np.float32)
        # b near 1 keeps the generalized continuants well-conditioned in fp32
        b = (1.0 + rng.uniform(-0.3, 0.3, depth)).astype(np.float32)
        got = await evaluate(dut, a, b)
        exp = f_reference_gen(a, b) if GEN else f_reference(a)
        rel = abs(got - exp) / (abs(exp) + 1e-30)
        assert rel <= 1e-3, f"[GEN={GEN}] got {got}, exp {exp}, rel {rel:.2e}, a={a}, b={b}"
        worst = max(worst, rel)
    dut._log.info(f"ladder_engine GEN={GEN} DEPTH={depth}: {n} cases  max_rel={worst:.2e}")
