"""M1 integration test: ladder_top full single-ladder forward f = K1/K0.

Reference = the same math continuant_scan.py / CoFrContinuant implement, computed
in fp64 (recurrence for K, then the pole-guarded ratio). RTL is fp32, so compared
with a relative tolerance. DEPTH read from the a port width.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_ladder_scan import k_ground_truth_f64

EPS = 0.01


def f_reference(a):
    """f = sign(K1)*sign(K0)*|K1| / max(|K0|, eps), K from fp64 recurrence.
    (Equivalent to continuant_scan.continuant_scan for unit numerators.)"""
    k0, k1 = k_ground_truth_f64(a)
    denom = max(abs(k0), EPS)
    return np.sign(k1) * np.sign(k0) * abs(k1) / denom


async def reset(dut):
    dut.inValid.value = 0
    dut.a.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def evaluate(dut, a):
    depth = len(a)
    packed = 0
    for k in range(depth):
        packed |= (f32_to_bits(a[k]) & 0xFFFFFFFF) << (32 * k)
    while dut.inReady.value != 1:
        await RisingEdge(dut.clock)
    dut.a.value = packed
    dut.inValid.value = 1
    await RisingEdge(dut.clock)
    dut.inValid.value = 0
    for _ in range(200):
        await RisingEdge(dut.clock)
        if dut.outValid.value == 1:
            return bits_to_f32(dut.f.value)
    raise TimeoutError("ladder_top produced no outValid")


@cocotb.test()
async def ladder_top_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    depth = len(dut.a) // 32
    rng = np.random.default_rng(4)
    n = 120
    worst = 0.0
    for _ in range(n):
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.5).astype(np.float32)
        got = await evaluate(dut, a)
        exp = f_reference(a)
        rel = abs(got - exp) / (abs(exp) + 1e-30)
        assert rel <= 1e-4, f"f mismatch: got {got}, exp {exp}, rel {rel:.2e}, a={a}"
        worst = max(worst, rel)
    dut._log.info(f"ladder_top DEPTH={depth}: {n} cases  max_rel={worst:.2e}")
