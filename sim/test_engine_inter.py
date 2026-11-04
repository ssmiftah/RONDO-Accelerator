"""ladder_engine_inter: the assembled interleaved lane.

Checks the composition is free -- results emerge one per cycle, matching the
scan's completion rate -- and that the values equal the sequential lane's.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01
OUTDIR = Path(os.environ.get("WL_OUT", "."))
TAG = os.environ.get("WL_TAG", "engine_inter")


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


@cocotb.test()
async def assembled(dut):
    W = 32
    nslot = int(os.environ.get("WL_NSLOT", "8"))
    depth = (len(dut.a_all) // W) // nslot
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(67)
    batches, worst, cycles_total, gap_max = 10, 0.0, 0, 0
    for _ in range(batches):
        A = (rng.uniform(-3, 3, (nslot, depth)) +
             np.sign(rng.uniform(-1, 1, (nslot, depth))) * 1.5).astype(np.float32)
        packed = 0
        for s in range(nslot):
            for k in range(depth):
                packed |= (f32_to_bits(A[s, k]) & 0xFFFFFFFF) << ((s * depth + k) * W)
        dut.a_all.value = packed
        while True:
            await RisingEdge(dut.clock)
            await Timer(1, unit="ns")
            if dut.in_ready.value == 1:
                break
        dut.in_valid.value = 1
        await RisingEdge(dut.clock)
        dut.in_valid.value = 0

        got, n, last_hit = [], 0, None
        while len(got) < nslot:
            await RisingEdge(dut.clock)
            await Timer(1, unit="ns")
            n += 1
            if dut.out_valid.value == 1:
                if last_hit is not None:
                    gap_max = max(gap_max, n - last_hit)
                last_hit = n
                got.append(bits_to_f32(int(dut.f.value)))
            assert n < nslot * depth * 4 + 400, f"stalled at {len(got)}/{nslot}"
        cycles_total += n
        for s in range(nslot):
            exp = f_ref(A[s].astype(np.float64))
            rel = abs(got[s] - exp) / (abs(exp) + 1e-30)
            worst = max(worst, rel)

    cpl = cycles_total / (batches * nslot)
    res = dict(tag=TAG, nslot=nslot, depth=depth, cycles_per_ladder=cpl,
               max_rel=float(worst), max_gap_between_results=gap_max)
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_engine.json").write_text(json.dumps(res, indent=2))
    dut._log.info("ENGINE_INTER " + json.dumps(res))
    assert worst < 1e-3, f"functional error {worst:.2e}"
    assert gap_max <= 1, f"results not emerging one per cycle (max gap {gap_max})"
