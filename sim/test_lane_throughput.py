"""Sustained cycles/ladder for a lane, honouring in_ready.

Streams ladders back to back rather than one at a time, so this measures the
issue rate the array would actually see -- which is the number that matters once
the reciprocal is pipelined and the scan becomes the limiter.
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
TAG = os.environ.get("WL_TAG", "lane")


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


@cocotb.test()
async def throughput(dut):
    depth = len(dut.a) // 32
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    rng = np.random.default_rng(29)
    N = 64
    A = (rng.uniform(-3, 3, (N, depth)) +
         np.sign(rng.uniform(-1, 1, (N, depth))) * 1.5).astype(np.float32)
    packed = [sum((f32_to_bits(A[i, k]) & 0xFFFFFFFF) << (k * 32) for k in range(depth))
              for i in range(N)]

    sent = recvd = cycles = 0
    got = []
    first_issue = None
    while recvd < N:
        await RisingEdge(dut.clock)
        await Timer(1, unit="ns")          # let combinational in_ready/out_valid settle
        cycles += 1
        if dut.out_valid.value == 1:
            got.append(bits_to_f32(int(dut.f.value)))
            recvd += 1
        if dut.in_ready.value == 1 and sent < N:
            dut.a.value = packed[sent]
            dut.in_valid.value = 1
            if first_issue is None:
                first_issue = cycles
            sent += 1
        else:
            dut.in_valid.value = 0
        assert cycles < N * (depth + 120) + 500, f"stalled: sent {sent}, recvd {recvd}"
    dut.in_valid.value = 0

    worst = max(abs(g - f_ref(A[i].astype(np.float64))) /
                (abs(f_ref(A[i].astype(np.float64))) + 1e-30) for i, g in enumerate(got))
    cpl = (cycles - first_issue) / N
    res = dict(tag=TAG, depth=depth, ladders=N, total_cycles=cycles - first_issue,
               cycles_per_ladder=cpl, max_rel=float(worst))
    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_throughput.json").write_text(json.dumps(res, indent=2))
    dut._log.info("LANE " + json.dumps(res))
    assert worst < 1e-3, f"functional error {worst:.2e}"
