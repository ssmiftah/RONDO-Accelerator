"""I-12 test: train_coproc — WIDTH-batched forward+backward.

Drives WIDTH ladders' denominators and per-ladder grad_out; checks every z[j]
(forward) and grad_a_all[j] (backward) against the reference math.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_ladder_top import f_reference
from test_grad_a_unit import grad_analytic, k_full


async def reset(dut):
    dut.start.value = 0
    dut.a_all.value = 0
    dut.grad_out_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


async def run_batch(dut, A, G):
    width, depth = A.shape
    pa = pg = 0
    for j in range(width):
        pg |= (f32_to_bits(G[j]) & 0xFFFFFFFF) << (32 * j)
        for k in range(depth):
            pa |= (f32_to_bits(A[j, k]) & 0xFFFFFFFF) << ((j * depth + k) * 32)
    dut.a_all.value = pa
    dut.grad_out_all.value = pg
    dut.start.value = 1
    await RisingEdge(dut.clock)
    dut.start.value = 0
    for _ in range(width * (depth + 60) + 50):
        await RisingEdge(dut.clock)
        if dut.done.value == 1:
            zb = int(dut.z.value)
            gb = int(dut.grad_a_all.value)
            z = np.array([bits_to_f32((zb >> (32 * j)) & 0xFFFFFFFF) for j in range(width)])
            ga = np.array([[bits_to_f32((gb >> ((j * depth + k) * 32)) & 0xFFFFFFFF)
                            for k in range(depth)] for j in range(width)])
            return z, ga
    raise TimeoutError("train_coproc produced no done")


@cocotb.test()
async def train_coproc_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    width = len(dut.z) // 32
    depth = (len(dut.a_all) // 32) // width
    rng = np.random.default_rng(13)
    wf, wg = 0.0, 0.0
    for _ in range(15):
        # well-conditioned denominators (|K0|>0.5 per ladder)
        A = np.zeros((width, depth), np.float32)
        for j in range(width):
            while True:
                aj = (rng.uniform(-3, 3, depth) + np.sign(rng.uniform(-1, 1, depth)) * 2.0).astype(np.float32)
                if abs(k_full(aj, np.float64)[0]) > 0.5:
                    A[j] = aj; break
        G = rng.uniform(-2, 2, width).astype(np.float32)

        z, ga = await run_batch(dut, A, G)
        for j in range(width):
            f_exp = f_reference(A[j])
            wf = max(wf, abs(z[j] - f_exp) / (abs(f_exp) + 1e-30))
            assert abs(z[j] - f_exp) / (abs(f_exp) + 1e-30) <= 1e-4, f"f ladder {j}: {z[j]} vs {f_exp}"
            ga_exp = grad_analytic(A[j], float(G[j]))
            for k in range(depth):
                s = abs(ga_exp[k]) + 1e-6
                wg = max(wg, abs(ga[j, k] - ga_exp[k]) / s)
                assert abs(ga[j, k] - ga_exp[k]) / s <= 2e-3, \
                    f"grad_a ladder {j} k {k}: {ga[j,k]} vs {ga_exp[k]}"
    dut._log.info(f"train_coproc WIDTH={width} DEPTH={depth}: 15 batches OK  f_rel={wf:.2e}  grad_rel={wg:.2e}")
