"""Steady-state throughput: batches issued back to back, not one at a time.

The single-batch test waits for every result before issuing again, which charges
the reciprocal's pipeline latency to every batch. In use, in_ready rises as soon
as the SCAN is free -- the reciprocal drains independently at II=1 -- so the real
rate is scan-limited. This measures that.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

EPS = 0.01
OUTDIR = Path(os.environ["WL_OUT"])
TAG = os.environ.get("WL_TAG", "steady")


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


@cocotb.test()
async def steady(dut):
    W = 32
    nslot = int(os.environ["WL_NSLOT"])
    depth = (len(dut.a_all) // W) // nslot
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(71)
    NB = 12
    A = [(rng.uniform(-3, 3, (nslot, depth)) +
          np.sign(rng.uniform(-1, 1, (nslot, depth))) * 1.5).astype(np.float32)
         for _ in range(NB)]
    packed = []
    for m in A:
        v = 0
        for s in range(nslot):
            for k in range(depth):
                v |= (f32_to_bits(m[s, k]) & 0xFFFFFFFF) << ((s * depth + k) * W)
        packed.append(v)

    sent, got, cycles, first = 0, [], 0, None
    total = NB * nslot
    while len(got) < total:
        await RisingEdge(dut.clock)
        await Timer(1, unit="ns")
        cycles += 1
        if dut.out_valid.value == 1:
            got.append(bits_to_f32(int(dut.f.value)))
        # issue the moment the scan will take another batch
        if dut.in_ready.value == 1 and sent < NB:
            dut.a_all.value = packed[sent]
            dut.in_valid.value = 1
            if first is None:
                first = cycles
            sent += 1
        else:
            dut.in_valid.value = 0
        assert cycles < total * (depth + 40) + 800, f"stalled at {len(got)}/{total}"
    dut.in_valid.value = 0

    worst = 0.0
    for b in range(NB):
        for s in range(nslot):
            exp = f_ref(A[b][s].astype(np.float64))
            worst = max(worst, abs(got[b*nslot + s] - exp) / (abs(exp) + 1e-30))

    cpl = (cycles - first) / total
    res = dict(tag=TAG, nslot=nslot, depth=depth, batches=NB, ladders=total,
               cycles_per_ladder=cpl, max_rel=float(worst))
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_steady.json").write_text(json.dumps(res, indent=2))
    dut._log.info("STEADY " + json.dumps(res))
    assert worst < 1e-3, f"functional error {worst:.2e}"
