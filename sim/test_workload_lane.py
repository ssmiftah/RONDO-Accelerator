"""I-29: replay the W1 coefficient dumps through ladder_engine_fast.

W1 established that the exact digit-recurrence divider preserves *every*
classification decision (accuracy delta 0.0000 on three datasets). recip_nr is a
~1 ULP Newton-Raphson reciprocal, not correctly rounded, so that has to be
re-established rather than assumed before anything switches to the new lane.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from cocotb_common import f32_to_bits, bits_to_f32

NPZ = Path(os.environ["WL_NPZ"])
TAG = os.environ.get("WL_TAG", NPZ.stem)
MAXS = int(os.environ.get("WL_MAXSAMP", "200"))
OUTDIR = Path(os.environ["WL_OUT"])
EPS = 0.01


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS), K[0]


@cocotb.test()
async def replay_lane(dut):
    D = np.load(NPZ)
    A = D["A"][:MAXS]                       # (nsamp, ladders, depth)
    nsamp, ladders, depth = A.shape
    assert len(dut.a) // 32 == depth, "DEPTH mismatch with the dump"

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    flat = A.reshape(-1, depth)
    packed = [sum((f32_to_bits(row[k]) & 0xFFFFFFFF) << (k * 32) for k in range(depth))
              for row in flat]
    N = len(packed)

    got, sent, recvd, cycles = [], 0, 0, 0
    while recvd < N:
        await RisingEdge(dut.clock)
        await Timer(1, unit="ns")
        cycles += 1
        if dut.out_valid.value == 1:
            got.append(bits_to_f32(int(dut.f.value)))
            recvd += 1
        if dut.in_ready.value == 1 and sent < N:
            dut.a.value = packed[sent]
            dut.in_valid.value = 1
            sent += 1
        else:
            dut.in_valid.value = 0
        assert cycles < N * (depth + 40) + 1000, f"stalled at {recvd}/{N}"
    dut.in_valid.value = 0

    Z = np.array(got, dtype=np.float64).reshape(nsamp, ladders)
    ref = np.zeros_like(Z)
    for s in range(nsamp):
        for j in range(ladders):
            ref[s, j], _ = f_ref(flat[s * ladders + j].astype(np.float64))
    rel = np.abs(Z - ref) / (np.abs(ref) + 1e-30)

    res = dict(tag=TAG, lane="ladder_engine_fast", samples=int(nsamp), ladders=int(ladders),
               depth=int(depth), cycles_per_ladder=cycles / N,
               max_rel=float(rel.max()), p999_rel=float(np.percentile(rel, 99.9)),
               nonfinite=int((~np.isfinite(Z)).sum()),
               sign_flips=int(((np.sign(Z) != np.sign(ref)) & (np.abs(ref) > 1e-12)).sum()))
    if "V" in D:
        cmin, cmax, V = D["cmin"], D["cmax"], D["V"]
        direct, y = D["direct"][:MAXS], D["y"][:MAXS]
        logits = lambda z: direct + np.clip(z, cmin, cmax) @ V.T
        res["acc_lane"] = float((logits(Z).argmax(1) == y).mean())
        res["acc_ref"] = float((logits(ref).argmax(1) == y).mean())
        res["acc_delta"] = round(res["acc_lane"] - res["acc_ref"], 6)

    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_lane.json").write_text(json.dumps(res, indent=2))
    dut._log.info("LANE_REPLAY " + json.dumps(res))
    assert res["nonfinite"] == 0, "non-finite outputs"
    # the bar W1 set for the exact divider: no classification decision changes
    assert abs(res.get("acc_delta", 0.0)) <= 0.002, (
        f"accuracy moved {res['acc_delta']:+.4f} -- the NR reciprocal is not "
        f"application-neutral")
