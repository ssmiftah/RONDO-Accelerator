"""M2 test for cofr_coproc: WIDTH-ladder coprocessor over N_LANES engines.

Drives all WIDTH ladders' denominators, waits `done`, and checks every z[j]
against the reference f (fp64 continuant recurrence + pole-guarded ratio).
WIDTH and DEPTH are read from the port widths; N_LANES is internal.
"""

import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import numpy as np

from cocotb_common import f32_to_bits, bits_to_f32
from test_ladder_top import f_reference
from test_ladder_engine import f_reference_gen

GEN = int(os.environ.get("COFR_GEN", "0"))


async def reset(dut):
    dut.start.value = 0
    dut.a_all.value = 0
    dut.b_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


def _pack_grid(M):
    width, depth = M.shape
    packed = 0
    for j in range(width):
        for k in range(depth):
            packed |= (f32_to_bits(M[j, k]) & 0xFFFFFFFF) << ((j * depth + k) * 32)
    return packed


async def run_batch(dut, A, B):
    """A,B: (WIDTH, DEPTH) fp32. Returns z: (WIDTH,) f-values."""
    width, depth = A.shape
    dut.a_all.value = _pack_grid(A)
    dut.b_all.value = _pack_grid(B)
    dut.start.value = 1
    await RisingEdge(dut.clock)
    dut.start.value = 0
    for _ in range(width * (depth + 60) + 50):
        await RisingEdge(dut.clock)
        if dut.done.value == 1:
            zbits = int(dut.z.value)
            return np.array([bits_to_f32((zbits >> (j * 32)) & 0xFFFFFFFF) for j in range(width)],
                            dtype=np.float32)
    raise TimeoutError("cofr_coproc produced no done")


@cocotb.test()
async def coproc_random(dut):
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)
    width = len(dut.z) // 32
    depth = (len(dut.a_all) // 32) // width
    rng = np.random.default_rng(7)
    worst = 0.0
    for _ in range(20):
        A = (rng.uniform(-3, 3, (width, depth)) +
             np.sign(rng.uniform(-1, 1, (width, depth))) * 1.5).astype(np.float32)
        B = (1.0 + rng.uniform(-0.3, 0.3, (width, depth))).astype(np.float32)
        z = await run_batch(dut, A, B)
        for j in range(width):
            exp = f_reference_gen(A[j], B[j]) if GEN else f_reference(A[j])
            rel = abs(z[j] - exp) / (abs(exp) + 1e-30)
            assert rel <= 1e-3, f"[GEN={GEN}] ladder {j}: got {z[j]}, exp {exp}, rel {rel:.2e}"
            worst = max(worst, rel)
    dut._log.info(f"cofr_coproc GEN={GEN} WIDTH={width} DEPTH={depth}: 20 batches OK  max_rel={worst:.2e}")
