"""train_ladder_inter: forward + df/da for NSLOT ladders on pipelined units.

Checks the whole engine end to end against the same fp64 references the
sequential train_ladder is checked against, so a pass means the rebuilt engine
agrees with the verified one and not merely with itself:

  * f       vs K1/clamp_signed(K0)
  * grad_a  vs grad_analytic, and separately vs finite differences

Also asserts f and grad_a are valid TOGETHER on out_valid, which is the property
that makes one engine useful for training rather than two.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_grad_a_unit import (k_full, clamp_signed, f_forward, grad_analytic,
                              grad_fd)

DEPTH = int(os.environ.get("WL_DEPTH", "7"))
NSLOT = int(os.environ.get("WL_NSLOT", "8"))


async def reset(dut):
    dut.in_valid.value = 0
    dut.a_all.value = 0
    dut.gout_all.value = 0
    dut.nReset.value = 0
    await Timer(40, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def run_batch(dut, A, gout):
    pa = pg = 0
    for s in range(NSLOT):
        for k in range(DEPTH):
            pa |= (f32_to_bits(A[s][k]) & 0xFFFFFFFF) << (32 * (s * DEPTH + k))
        pg |= (f32_to_bits(gout[s]) & 0xFFFFFFFF) << (32 * s)

    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.a_all.value = pa
    dut.gout_all.value = pg
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0

    budget = (DEPTH * NSLOT) + (2 * NSLOT) + (NSLOT * DEPTH) + 400
    for _ in range(budget):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            break
    else:
        raise AssertionError("train_ladder_inter never raised out_valid")

    rf = int(dut.f_all.value)
    rg = int(dut.grad_a_all.value)
    f = np.zeros(NSLOT, np.float32)
    g = np.zeros((NSLOT, DEPTH), np.float32)
    for s in range(NSLOT):
        f[s] = bits_to_f32((rf >> (32 * s)) & 0xFFFFFFFF)
        for k in range(DEPTH):
            g[s][k] = bits_to_f32((rg >> (32 * (s * DEPTH + k))) & 0xFFFFFFFF)
    return f, g


def _well_conditioned(rng, floor=0.5):
    while True:
        a = (rng.uniform(-3, 3, DEPTH)
             + np.sign(rng.uniform(-1, 1, DEPTH)) * 2.0).astype(np.float32)
        if abs(k_full(a, np.float64)[0]) >= floor:
            return a


@cocotb.test()
async def test_forward_and_backward_together(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(20260909)

    worst_f, worst_g = 0.0, 0.0
    for trial in range(3):
        A = np.stack([_well_conditioned(rng) for _ in range(NSLOT)])
        gout = rng.uniform(-2, 2, NSLOT).astype(np.float32)
        f, g = await run_batch(dut, A, gout)

        for s in range(NSLOT):
            fe = f_forward(A[s].astype(np.float64))
            rel = abs(float(f[s]) - fe) / max(abs(fe), 1e-6)
            worst_f = max(worst_f, rel)
            assert rel < 1e-4, f"trial {trial} slot {s}: f {f[s]!r} vs {fe!r}"

            ge = grad_analytic(A[s].astype(np.float64), float(gout[s]))
            for k in range(DEPTH):
                r = abs(float(g[s][k]) - ge[k]) / max(abs(ge[k]), 1e-6)
                worst_g = max(worst_g, r)
                assert r < 1e-4, (
                    f"trial {trial} slot {s} k {k}: {g[s][k]!r} vs {ge[k]!r}"
                )
    dut._log.info(f"worst rel: f {worst_f:.3e}, grad_a {worst_g:.3e}")


@cocotb.test()
async def test_grad_vs_finite_differences(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(31)
    A = np.stack([_well_conditioned(rng, 1.0) for _ in range(NSLOT)])
    gout = rng.uniform(-2, 2, NSLOT).astype(np.float32)
    _, g = await run_batch(dut, A, gout)
    for s in range(NSLOT):
        fd = grad_fd(A[s], float(gout[s]))
        for k in range(DEPTH):
            r = abs(float(g[s][k]) - fd[k]) / max(abs(fd[k]), 1e-3)
            assert r < 1e-2, f"slot {s} k {k}: {g[s][k]!r} vs fd {fd[k]!r}"


@cocotb.test()
async def test_back_to_back_batches(dut):
    """Two batches without a reset: the counters must not leak between them."""
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    rng = np.random.default_rng(77)
    for _ in range(2):
        A = np.stack([_well_conditioned(rng) for _ in range(NSLOT)])
        gout = rng.uniform(-2, 2, NSLOT).astype(np.float32)
        f, g = await run_batch(dut, A, gout)
        for s in range(NSLOT):
            fe = f_forward(A[s].astype(np.float64))
            assert abs(float(f[s]) - fe) / max(abs(fe), 1e-6) < 1e-4
            ge = grad_analytic(A[s].astype(np.float64), float(gout[s]))
            for k in range(DEPTH):
                assert abs(float(g[s][k]) - ge[k]) / max(abs(ge[k]), 1e-6) < 1e-4
