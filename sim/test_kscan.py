"""Unit test for kscan: full continuant array K[0..DEPTH] via scalar recurrence.

Covers unit (GEN=0) and generalized (GEN=1, K[k]=a[k]K[k+1]+b[k+1]K[k+2]).
GEN read from COFR_GEN env var (set by the runner).
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32, ulp_diff
from test_grad_a_unit import k_full
from test_grad_gen_unit import kgen

GEN = int(os.environ.get("COFR_GEN", "0"))


async def reset(dut):
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def run_scan(dut, a, b):
    depth = len(a)
    pa = pb = 0
    for k in range(depth):
        pa |= (f32_to_bits(a[k]) & 0xFFFFFFFF) << (32 * k)
        pb |= (f32_to_bits(b[k]) & 0xFFFFFFFF) << (32 * k)
    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.a.value = pa
    dut.b.value = pb
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0
    for _ in range(depth + 8):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            kbits = int(dut.Kv.value)
            return np.array([bits_to_f32((kbits >> (32 * i)) & 0xFFFFFFFF)
                             for i in range(depth + 1)], dtype=np.float32)
    raise TimeoutError("kscan produced no out_valid")


@cocotb.test()
async def kscan_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    depth = len(dut.a) // 32
    rng = np.random.default_rng(9)
    worst_ulp, worst_rel = 0, 0.0
    kref = (lambda x, dt: kgen(x[0], x[1], dt)) if GEN else (lambda x, dt: k_full(x[0], dt))
    for _ in range(200):
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.5).astype(np.float32)
        b = (1.0 + rng.uniform(-0.3, 0.3, depth)).astype(np.float32)
        K = await run_scan(dut, a, b)

        Kf32 = kref((a, b), np.float32)   # same fp32 op order
        K64  = kref((a, b), np.float64)   # correctness reference
        for i in range(depth + 1):
            worst_ulp = max(worst_ulp, ulp_diff(K[i], Kf32[i]))
            worst_rel = max(worst_rel, abs(K[i] - K64[i]) / (abs(K64[i]) + 1e-30))
            assert ulp_diff(K[i], Kf32[i]) <= 2, f"[GEN={GEN}] K[{i}] {K[i]} vs fp32 {Kf32[i]}, a={a}"
            assert abs(K[i] - K64[i]) / (abs(K64[i]) + 1e-30) <= 1e-4, \
                f"[GEN={GEN}] K[{i}] {K[i]} vs f64 {K64[i]}, a={a}"
    dut._log.info(f"kscan GEN={GEN} DEPTH={depth}: 200 cases  max_ulp={worst_ulp}  max_rel={worst_rel:.2e}")
