"""M0 smoke test: drive HardFloat fp32 FMA and check against a numpy golden.

This proves the Verilator/Icarus + cocotb + HardFloat stack works end-to-end.
It is intentionally loose on numeric tolerance (the point is 'the toolchain and
IP are wired correctly', not exhaustive ULP verification -- that comes with the
real mat2x2_mul / ladder unit tests against continuant_scan.py).
"""

import cocotb
from cocotb.triggers import Timer
import numpy as np


def f32_to_bits(x):
    return int(np.float32(x).view(np.uint32))


def bits_to_f32(b):
    return float(np.uint32(int(b) & 0xFFFFFFFF).view(np.float32))


@cocotb.test()
async def smoke_fma_random(dut):
    rng = np.random.default_rng(0)
    n = 500
    worst = 0.0
    for _ in range(n):
        a, b, c = rng.uniform(-100.0, 100.0, size=3).astype(np.float32)

        dut.a_ieee.value = f32_to_bits(a)
        dut.b_ieee.value = f32_to_bits(b)
        dut.c_ieee.value = f32_to_bits(c)
        await Timer(1, unit="ns")  # combinational settle

        got = bits_to_f32(dut.y_ieee.value)
        # fused reference computed in fp64 then rounded to fp32
        exp = float(np.float32(np.float64(a) * np.float64(b) + np.float64(c)))

        err = abs(got - exp)
        worst = max(worst, err)
        tol = 1e-2 + 1e-4 * abs(exp)  # loose: catches gross wiring/IP failures
        assert err <= tol, (
            f"FMA mismatch: a={a} b={b} c={c} -> got {got}, exp {exp}, err {err}"
        )

    dut._log.info(f"smoke FMA passed {n} random fp32 cases (worst abs err {worst:.3e})")
