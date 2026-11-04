"""grad_a_inter: the closed-form ladder gradient, streamed at one result/cycle.

Two checks, deliberately kept separate:

  * against grad_analytic (fp64), the same reference grad_a_unit is checked
    against, so a pass means the streamed unit agrees with the verified
    combinational one rather than merely with itself;
  * against finite differences of the forward function, which validates the
    formula and its sign convention independently of any RTL.

Every slot gets different coefficients, a different reciprocal and a different
upstream gradient. Identical ones would pass even if the writeback dropped every
result into slot 0, or if grad_out were read for the wrong slot.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_grad_a_unit import k_full, clamp_signed, grad_analytic, grad_fd

DEPTH = int(os.environ.get("WL_DEPTH", "7"))
NSLOT = int(os.environ.get("WL_NSLOT", "8"))


async def reset(dut):
    dut.in_valid.value = 0
    dut.Kv_all.value = 0
    dut.rK0_all.value = 0
    dut.gout_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def run_batch(dut, A, gout):
    Kv = rk = go = 0
    rk0s = []
    for s in range(NSLOT):
        K = k_full(A[s], np.float32)
        for i in range(DEPTH + 1):
            Kv |= (f32_to_bits(K[i]) & 0xFFFFFFFF) << (32 * (s * (DEPTH + 1) + i))
        r = np.float32(1.0 / clamp_signed(np.float64(K[0])))
        rk0s.append(r)
        rk |= (f32_to_bits(r) & 0xFFFFFFFF) << (32 * s)
        go |= (f32_to_bits(gout[s]) & 0xFFFFFFFF) << (32 * s)

    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.Kv_all.value = Kv
    dut.rK0_all.value = rk
    dut.gout_all.value = go
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0

    for _ in range(NSLOT * DEPTH + 6 * 5 + 64):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            break
    else:
        raise AssertionError("grad_a_inter never raised out_valid")

    raw = int(dut.grad_a_all.value)
    out = np.zeros((NSLOT, DEPTH), np.float32)
    for s in range(NSLOT):
        for k in range(DEPTH):
            w = (raw >> (32 * (s * DEPTH + k))) & 0xFFFFFFFF
            out[s][k] = bits_to_f32(w)
    return out


@cocotb.test()
async def test_vs_analytic_all_slots(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(20260908)

    worst = 0.0
    for trial in range(4):
        A = np.zeros((NSLOT, DEPTH), np.float32)
        for s in range(NSLOT):
            while True:
                a = (rng.uniform(-3, 3, DEPTH)
                     + np.sign(rng.uniform(-1, 1, DEPTH)) * 2.0).astype(np.float32)
                if abs(k_full(a, np.float64)[0]) >= 0.5:   # away from the pole
                    A[s] = a
                    break
        gout = rng.uniform(-2, 2, NSLOT).astype(np.float32)

        got = await run_batch(dut, A, gout)
        for s in range(NSLOT):
            exp = grad_analytic(A[s].astype(np.float64), float(gout[s]))
            for k in range(DEPTH):
                den = max(abs(exp[k]), 1e-6)
                rel = abs(float(got[s][k]) - exp[k]) / den
                worst = max(worst, rel)
                assert rel < 2e-5, (
                    f"trial {trial} slot {s} k {k}: got {got[s][k]!r} "
                    f"expected {exp[k]!r} (rel {rel:.2e})"
                )
    dut._log.info(f"worst relative error vs analytic: {worst:.3e}")


@cocotb.test()
async def test_formula_vs_finite_differences(dut):
    """Validates the sign convention independently of the RTL."""
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(11)

    A = np.zeros((NSLOT, DEPTH), np.float32)
    for s in range(NSLOT):
        while True:
            a = (rng.uniform(-3, 3, DEPTH)
                 + np.sign(rng.uniform(-1, 1, DEPTH)) * 2.0).astype(np.float32)
            if abs(k_full(a, np.float64)[0]) >= 1.0:
                A[s] = a
                break
    gout = rng.uniform(-2, 2, NSLOT).astype(np.float32)

    got = await run_batch(dut, A, gout)
    for s in range(NSLOT):
        fd = grad_fd(A[s], float(gout[s]))
        for k in range(DEPTH):
            den = max(abs(fd[k]), 1e-3)
            rel = abs(float(got[s][k]) - fd[k]) / den
            assert rel < 1e-2, (
                f"slot {s} k {k}: RTL {got[s][k]!r} vs finite diff {fd[k]!r}"
            )
