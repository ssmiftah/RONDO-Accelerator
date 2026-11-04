"""Unit test for ladder_scan: continuant K0, K1 of a unit-numerator ladder.

Two goldens:
  * fp64 ground truth (the real recurrence) -> checked with a relative tolerance,
    this is the *correctness* check against the math.
  * fp32 fold mirroring the RTL (same op structure as mat2x2_mul) -> checked
    tightly in ULP, this is the *self-consistency* check.

DEPTH is read from the DUT port width (a is DEPTH*32 bits wide).
"""

import cocotb
from cocotb.triggers import Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32, ulp_diff
from test_mat2x2_mul import golden_mat2x2  # fp32 mirror of the RTL combine


def k_ground_truth_f64(a):
    """Exact continuant K0, K1 via the recurrence in fp64 (K[d]=1, K[d+1]=0)."""
    d = len(a)
    a = np.asarray(a, dtype=np.float64)
    K = np.ones(d + 2, dtype=np.float64)
    K[d] = 1.0
    K[d + 1] = 0.0
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return K[0], K[1]


def k_fold_f32(a):
    """fp32 K0, K1 by folding mat2x2 in the same structure as the RTL."""
    ONE = np.float32(1.0)
    ZERO = np.float32(0.0)
    P = np.array([[np.float32(a[0]), ONE], [ONE, ZERO]], dtype=np.float32)
    for k in range(1, len(a)):
        Mk = np.array([[np.float32(a[k]), ONE], [ONE, ZERO]], dtype=np.float32)
        P = golden_mat2x2(P, Mk)
    return P[0, 0], P[1, 0]


async def run_case(dut, a):
    depth = len(a)
    packed = 0
    for k in range(depth):
        packed |= (f32_to_bits(a[k]) & 0xFFFFFFFF) << (32 * k)
    dut.a.value = packed
    await Timer(1, unit="ns")
    return bits_to_f32(dut.k0.value), bits_to_f32(dut.k1.value)


@cocotb.test()
async def ladder_scan_random(dut):
    depth = len(dut.a) // 32
    rng = np.random.default_rng(2)
    n = 300
    worst_ulp = 0
    worst_rel = 0.0
    for _ in range(n):
        # denominators offset from zero (as in real ladders) to avoid degenerate K0
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.5).astype(np.float32)

        k0, k1 = await run_case(dut, a)

        # self-consistency (tight, ULP) vs fp32 fold
        f0, f1 = k_fold_f32(a)
        u0, u1 = ulp_diff(k0, f0), ulp_diff(k1, f1)
        assert u0 <= 2 and u1 <= 2, f"ULP vs fold: k0 {k0}/{f0} ({u0}), k1 {k1}/{f1} ({u1}), a={a}"
        worst_ulp = max(worst_ulp, u0, u1)

        # correctness (relative) vs fp64 ground truth
        g0, g1 = k_ground_truth_f64(a)
        r0 = abs(k0 - g0) / (abs(g0) + 1e-30)
        r1 = abs(k1 - g1) / (abs(g1) + 1e-30)
        assert r0 <= 1e-4 and r1 <= 1e-4, f"rel vs f64: k0 {k0}/{g0} ({r0:.2e}), k1 {k1}/{g1} ({r1:.2e}), a={a}"
        worst_rel = max(worst_rel, r0, r1)

    dut._log.info(f"ladder_scan DEPTH={depth}: {n} cases  max_ulp={worst_ulp}  max_rel={worst_rel:.2e}")


@cocotb.test()
async def ladder_scan_directed(dut):
    depth = len(dut.a) // 32
    # a = [2, 2, ..., 2]: known continuant growth; just check finiteness + f64 match
    a = np.full(depth, 2.0, dtype=np.float32)
    k0, k1 = await run_case(dut, a)
    g0, g1 = k_ground_truth_f64(a)
    assert abs(k0 - g0) / (abs(g0) + 1e-30) <= 1e-4
    assert abs(k1 - g1) / (abs(g1) + 1e-30) <= 1e-4
    dut._log.info(f"directed a=2*ones DEPTH={depth}: k0={k0} (f64 {g0:.4f}), k1={k1} (f64 {g1:.4f})")
