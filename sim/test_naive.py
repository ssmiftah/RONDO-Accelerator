"""Ablation baseline: the ladder evaluated as written, one division per level.

Checks the naive engine against an fp64 model of the SAME algorithm (bottom-up
reciprocals), and reports cycles/ladder -- the number the continuant
reformulation is measured against.
"""
import os, json
from pathlib import Path
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01


def guard(x):
    return np.sign(x) * max(abs(x), EPS) if x != 0 else EPS


def f_naive(a):
    """t = a[d-1]; t = a[k] + 1/t; f = 1/t -- the direct evaluation."""
    d = len(a)
    t = a[d - 1]
    for k in range(d - 2, -1, -1):
        t = a[k] + 1.0 / guard(t)
    return 1.0 / guard(t)


@cocotb.test()
async def naive(dut):
    depth = len(dut.a) // 32
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(11)
    n, total, worst = 30, 0, 0.0
    for _ in range(n):
        A = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 1.5).astype(np.float32)
        v = 0
        for k in range(depth):
            v |= (f32_to_bits(A[k]) & 0xFFFFFFFF) << (k * 32)
        while dut.in_ready.value != 1:
            await RisingEdge(dut.clock)
        dut.a.value = v
        dut.in_valid.value = 1
        await RisingEdge(dut.clock)
        dut.in_valid.value = 0
        c = 0
        while dut.out_valid.value != 1:
            await RisingEdge(dut.clock)
            c += 1
            assert c < 20000, "naive engine hung"
        total += c
        got = bits_to_f32(int(dut.f.value))
        exp = f_naive(A.astype(np.float64))
        worst = max(worst, abs(got - exp) / (abs(exp) + 1e-30))

    cpl = total / n
    dut._log.info(f"NAIVE depth={depth} cycles/ladder={cpl:.2f} max_rel={worst:.2e}")
    out = Path(os.environ.get("WL_OUT", "."))
    out.mkdir(parents=True, exist_ok=True)
    (out / f"naive_d{depth}.json").write_text(json.dumps(
        dict(depth=depth, cycles_per_ladder=cpl, max_rel=float(worst)), indent=2))
    assert worst < 1e-2, f"naive engine wrong: {worst:.2e}"
