"""Measure cycles/ladder through cofr_coproc as N_LANES varies.

W1 measured four lanes and W4 measured one; the 6-lane figure quoted in the deck
was extrapolated from those. This measures the curve directly, so the throughput
projection rests on one fewer assumption.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

OUTDIR = Path(os.environ["WL_OUT"])
EPS = 0.01


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


@cocotb.test()
async def lane_sweep(dut):
    width = len(dut.z) // 32
    depth = (len(dut.a_all) // 32) // width
    lanes = int(os.environ["WL_LANES"])
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.start.value = 0
    dut.a_all.value = 0
    dut.b_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(17)
    total_cycles, batches, worst = 0, 40, 0.0
    for _ in range(batches):
        A = (rng.uniform(-3, 3, (width, depth)) +
             np.sign(rng.uniform(-1, 1, (width, depth))) * 1.5).astype(np.float32)
        v = 0
        for j in range(width):
            for k in range(depth):
                v |= (f32_to_bits(A[j, k]) & 0xFFFFFFFF) << ((j * depth + k) * 32)
        dut.a_all.value = v
        dut.start.value = 1
        await RisingEdge(dut.clock)
        dut.start.value = 0
        n = 0
        while True:
            await RisingEdge(dut.clock)
            n += 1
            if dut.done.value == 1:
                break
            if n > width * (depth + 80) + 500:
                raise TimeoutError(f"no done at lanes={lanes}")
        total_cycles += n
        z = int(dut.z.value)
        for j in range(width):
            got = bits_to_f32((z >> (j * 32)) & 0xFFFFFFFF)
            exp = f_ref(A[j].astype(np.float64))
            worst = max(worst, abs(got - exp) / (abs(exp) + 1e-30))

    cpl = total_cycles / (batches * width)
    res = dict(lanes=lanes, width=width, depth=depth, batches=batches,
               cycles_per_ladder=cpl, cycles_per_batch=total_cycles / batches,
               max_rel=float(worst))
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"lanes{lanes}.json").write_text(json.dumps(res, indent=2))
    dut._log.info("LANES " + json.dumps(res))
    assert worst < 1e-3, f"functional error {worst:.2e}"
