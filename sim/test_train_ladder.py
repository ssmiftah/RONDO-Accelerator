"""M3 integration test: train_ladder produces both f (forward) and grad_a (backward).

Forward f checked vs the reference math; backward grad_a checked vs the analytic
closed form (and, at low depth, finite differences). Well-conditioned denominators.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_ladder_top import f_reference
from test_grad_a_unit import grad_analytic, grad_fd, k_full


async def reset(dut):
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.grad_out.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def run_one(dut, a, grad_out):
    depth = len(a)
    packed = 0
    for k in range(depth):
        packed |= (f32_to_bits(a[k]) & 0xFFFFFFFF) << (32 * k)
    while dut.in_ready.value != 1:
        await RisingEdge(dut.clock)
    dut.a.value = packed
    dut.grad_out.value = f32_to_bits(grad_out)
    dut.in_valid.value = 1
    await RisingEdge(dut.clock)
    dut.in_valid.value = 0
    for _ in range(depth + 60):
        await RisingEdge(dut.clock)
        if dut.out_valid.value == 1:
            f = bits_to_f32(dut.f.value)
            ga = np.array([bits_to_f32((int(dut.grad_a.value) >> (32 * k)) & 0xFFFFFFFF)
                           for k in range(depth)])
            return f, ga
    raise TimeoutError("train_ladder produced no out_valid")


@cocotb.test()
async def train_ladder_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    depth = len(dut.a) // 32
    rng = np.random.default_rng(11)
    wf, wg = 0.0, 0.0
    n = 0
    while n < 80:
        a = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 2.0).astype(np.float32)
        if abs(k_full(a, np.float64)[0]) < 0.5:   # stay away from the pole
            continue
        n += 1
        grad_out = np.float32(rng.uniform(-2, 2))

        f, ga = await run_one(dut, a, grad_out)

        f_exp = f_reference(a)
        rf = abs(f - f_exp) / (abs(f_exp) + 1e-30)
        assert rf <= 1e-4, f"f: got {f}, exp {f_exp}, rel {rf:.2e}, a={a}"
        wf = max(wf, rf)

        ga_exp = grad_analytic(a, float(grad_out))
        for k in range(depth):
            scale = abs(ga_exp[k]) + 1e-6
            rg = abs(ga[k] - ga_exp[k]) / scale
            assert rg <= 2e-3, f"grad_a[{k}]: got {ga[k]}, exp {ga_exp[k]}, rel {rg:.2e}, a={a}"
            wg = max(wg, rg)
        if depth <= 3:   # finite-diff sanity
            fd = grad_fd(a, float(grad_out))
            for k in range(depth):
                assert abs(ga_exp[k] - fd[k]) / (abs(ga_exp[k]) + 1e-6) <= 5e-3
    dut._log.info(f"train_ladder DEPTH={depth}: 80 cases  f_rel={wf:.2e}  grad_rel={wg:.2e}")
