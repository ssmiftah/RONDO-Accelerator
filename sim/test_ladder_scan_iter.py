"""Unit test for ladder_scan_iter: iterative (folded) continuant scan.

Same goldens as the combinational ladder_scan (fp32 fold for tight ULP,
fp64 recurrence for correctness), but clocked with the in_valid/out_valid
handshake. Verifies the folded engine gives identical K0,K1.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32, ulp_diff
from test_ladder_scan import k_ground_truth_f64, k_fold_f32


async def reset(dut):
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def scan(dut, a):
    depth = len(a)
    packed = 0
    for k in range(depth):
        packed |= (f32_to_bits(a[k]) & 0xFFFFFFFF) << (32 * k)
    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.a.value = packed
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0
    for _ in range(depth + 8):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            return bits_to_f32(dut.k0.value), bits_to_f32(dut.k1.value)
    raise TimeoutError("ladder_scan_iter produced no out_valid")


@cocotb.test()
async def scan_iter_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    depth = len(dut.a) // 32
    rng = np.random.default_rng(5)
    n = 200
    worst_ulp, worst_rel = 0, 0.0
    for _ in range(n):
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.5).astype(np.float32)
        k0, k1 = await scan(dut, a)

        f0, f1 = k_fold_f32(a)
        u0, u1 = ulp_diff(k0, f0), ulp_diff(k1, f1)
        assert u0 <= 2 and u1 <= 2, f"ULP: k0 {k0}/{f0}({u0}) k1 {k1}/{f1}({u1}) a={a}"
        worst_ulp = max(worst_ulp, u0, u1)

        g0, g1 = k_ground_truth_f64(a)
        r0 = abs(k0 - g0) / (abs(g0) + 1e-30)
        r1 = abs(k1 - g1) / (abs(g1) + 1e-30)
        assert r0 <= 1e-4 and r1 <= 1e-4, f"rel: k0 {k0}/{g0} k1 {k1}/{g1} a={a}"
        worst_rel = max(worst_rel, r0, r1)

    dut._log.info(f"ladder_scan_iter DEPTH={depth}: {n} cases  max_ulp={worst_ulp}  max_rel={worst_rel:.2e}")


@cocotb.test()
async def scan_iter_backpressure(dut):
    # Two back-to-back requests; in_ready must gate correctly.
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    depth = len(dut.a) // 32
    for seed in (10, 11):
        a = np.full(depth, 2.0, dtype=np.float32) + seed * 1e-3
        k0, k1 = await scan(dut, a)
        g0, g1 = k_ground_truth_f64(a)
        assert abs(k0 - g0) / (abs(g0) + 1e-30) <= 1e-4
        assert abs(k1 - g1) / (abs(g1) + 1e-30) <= 1e-4
    dut._log.info(f"ladder_scan_iter back-to-back requests OK (DEPTH={depth})")
