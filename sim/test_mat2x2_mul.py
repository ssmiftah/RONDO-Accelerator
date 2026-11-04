"""Unit test for mat2x2_mul: fp32 2x2 matrix product P = L @ R.

Golden mirrors the RTL's exact rounding structure per element:
    t = fp32( L[i][1] * R[1][j] )                 # rounded to fp32
    P = fp32_fma( L[i][0], R[0][j], t )           # single-rounded accumulate
so we can hold the DUT to <= 1 ULP. Also checks directed cases (identity,
zeros, and a transfer-matrix example from the continuant recurrence).
"""

import cocotb
from cocotb.triggers import Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32, ulp_diff


def golden_mat2x2(L, R):
    """fp32 2x2 product mirroring the RTL: round partial product, then fused acc."""
    P = np.zeros((2, 2), dtype=np.float32)
    for i in range(2):
        for j in range(2):
            t = np.float32(np.float32(L[i, 1]) * np.float32(R[1, j]))  # rounded fp32
            # fused a*b + t: a*b exact in fp64, + t exact in fp64, one round to fp32
            P[i, j] = np.float32(np.float64(L[i, 0]) * np.float64(R[0, j]) + np.float64(t))
    return P


async def _apply(dut, L, R):
    dut.l00.value = f32_to_bits(L[0, 0]); dut.l01.value = f32_to_bits(L[0, 1])
    dut.l10.value = f32_to_bits(L[1, 0]); dut.l11.value = f32_to_bits(L[1, 1])
    dut.r00.value = f32_to_bits(R[0, 0]); dut.r01.value = f32_to_bits(R[0, 1])
    dut.r10.value = f32_to_bits(R[1, 0]); dut.r11.value = f32_to_bits(R[1, 1])
    await Timer(1, unit="ns")
    return np.array([[bits_to_f32(dut.p00.value), bits_to_f32(dut.p01.value)],
                     [bits_to_f32(dut.p10.value), bits_to_f32(dut.p11.value)]], dtype=np.float32)


async def _check(dut, L, R, max_ulp, tag):
    L = L.astype(np.float32); R = R.astype(np.float32)
    got = await _apply(dut, L, R)
    exp = golden_mat2x2(L, R)
    for i in range(2):
        for j in range(2):
            d = ulp_diff(got[i, j], exp[i, j])
            assert d <= 1, f"[{tag}] P[{i}][{j}] got {got[i,j]} exp {exp[i,j]} ulp={d}\nL={L}\nR={R}"
            max_ulp[0] = max(max_ulp[0], d)


@cocotb.test()
async def directed(dut):
    I = np.eye(2, dtype=np.float32)
    Z = np.zeros((2, 2), dtype=np.float32)
    A = np.array([[2.0, -3.0], [1.0, 0.0]], np.float32)   # a transfer matrix M_k form
    B = np.array([[0.5, 4.0], [1.0, 0.0]], np.float32)
    mu = [0]
    await _check(dut, I, A, mu, "I@A")     # -> A
    await _check(dut, A, I, mu, "A@I")     # -> A
    await _check(dut, Z, A, mu, "0@A")     # -> 0
    await _check(dut, A, B, mu, "A@B")
    dut._log.info(f"directed cases passed (max ulp {mu[0]})")


@cocotb.test()
async def random_fp32(dut):
    rng = np.random.default_rng(1)
    n = 400
    mu = [0]
    for _ in range(n):
        L = rng.uniform(-10, 10, (2, 2))
        R = rng.uniform(-10, 10, (2, 2))
        await _check(dut, L, R, mu, "rand")
    dut._log.info(f"random_fp32 passed {n} cases (max ulp {mu[0]})")
