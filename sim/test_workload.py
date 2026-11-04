"""W1/W2: replay real trained-CoFrNet ladder coefficients through cofr_coproc.

The dumped model has WL_LADDERS ladders; the hardware instance has WIDTH of
them, so each sample is issued as ceil(WL_LADDERS/WIDTH) chunks -- the same
dispatch a real accelerator performs. Reports datapath error against the fp64
reference and, more usefully, end-to-end test accuracy computed from the RTL's
own outputs.
"""
import os, json
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

NPZ = Path(os.environ["WL_NPZ"])
TAG = os.environ.get("WL_TAG", NPZ.stem)
MAXS = int(os.environ.get("WL_MAXSAMP", "200"))
OUTDIR = Path(os.environ.get("WL_OUT", NPZ.parent))
EPS = 0.01
FMT = os.environ.get("WL_FMT", "fp32")      # must match the RTL EXP/SIG build
WORD = {"fp32": 32, "fp16": 16, "bf16": 16}[FMT]
# What to assert on, per format. Per-ladder relative error is the wrong bar for
# reduced precision: near-cancellation in K0 makes individual ladders noisy while
# the trained read-out layer absorbs it. So we gate on the thing that matters,
# end-to-end accuracy, plus the absence of non-finite outputs. Bounds come from a
# numpy emulation of each format on these same coefficients.
ACC_TOL = {"fp32": 0.0, "fp16": None, "bf16": 0.02}[FMT]   # None = characterise only
REQUIRE_FINITE = FMT != "fp16"                             # fp16 overflows by depth 7


def to_bits(x):
    if FMT == "fp32":
        return int(np.float32(x).view(np.uint32))
    if FMT == "fp16":
        return int(np.float16(x).view(np.uint16))
    u = int(np.float32(x).view(np.uint32))          # bf16: RNE to top 16 bits
    return ((u >> 16) + ((u >> 15) & 1)) & 0xFFFF


def from_bits(b):
    if FMT == "fp32":
        return float(np.uint32(b).view(np.float32))
    if FMT == "fp16":
        return float(np.uint16(b).view(np.float16))
    return float(np.uint32(b << 16).view(np.float32))


def f_ref_f64(a):
    d = len(a)
    K = np.ones(d + 2, dtype=np.float64)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    denom = max(abs(K[0]), EPS)
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / denom, K[0]


async def reset(dut):
    dut.start.value = 0
    dut.a_all.value = 0
    dut.b_all.value = 0
    dut.nReset.value = 0
    await Timer(25, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)


MASK = (1 << WORD) - 1


def _pack(M):
    w, d = M.shape
    v = 0
    for j in range(w):
        for k in range(d):
            v |= (to_bits(M[j, k]) & MASK) << ((j * d + k) * WORD)
    return v


async def run_batch(dut, A):
    w, d = A.shape
    dut.a_all.value = _pack(A)
    dut.b_all.value = 0
    dut.start.value = 1
    await RisingEdge(dut.clock)
    dut.start.value = 0
    for _ in range(w * (d + 60) + 80):
        await RisingEdge(dut.clock)
        if dut.done.value == 1:
            z = int(dut.z.value)
            return np.array([from_bits((z >> (j * WORD)) & MASK) for j in range(w)],
                            dtype=np.float64)
    raise TimeoutError("cofr_coproc produced no done")


@cocotb.test()
async def replay(dut):
    D = np.load(NPZ)
    A_all = D["A"][:MAXS]                       # (nsamp, ladders, depth)
    nsamp, ladders, depth = A_all.shape
    WIDTH = len(dut.z) // WORD
    assert (len(dut.a_all) // WORD) // WIDTH == depth, f"DEPTH mismatch ({FMT}, word={WORD})"

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await reset(dut)

    chunks = (ladders + WIDTH - 1) // WIDTH
    Z = np.zeros((nsamp, ladders), dtype=np.float64)
    cycles = 0
    for s in range(nsamp):
        for c in range(chunks):
            lo, hi = c * WIDTH, min((c + 1) * WIDTH, ladders)
            blk = np.zeros((WIDTH, depth), dtype=np.float32)
            blk[:hi - lo] = A_all[s, lo:hi]
            z = await run_batch(dut, blk)
            Z[s, lo:hi] = z[:hi - lo]
            cycles += 1

    # datapath error against the fp64 reference. Ladders whose K0 sits inside the
    # guard band are reported separately: there the fp64 and finite-precision
    # signs can legitimately differ, so they are characterised, not asserted on.
    ref = np.zeros((nsamp, ladders))
    k0 = np.zeros((nsamp, ladders))
    for s in range(nsamp):
        for j in range(ladders):
            ref[s, j], k0[s, j] = f_ref_f64(A_all[s, j].astype(np.float64))
    rel = np.abs(Z - ref) / (np.abs(ref) + 1e-30)
    near = np.abs(k0) < 10 * EPS
    far = ~near

    res = dict(tag=TAG, fmt=FMT, samples=int(nsamp), ladders=int(ladders), depth=int(depth),
               hw_width=int(WIDTH), batches=int(cycles), acc_tol=ACC_TOL,
               max_rel=float(np.nanmax(rel)), mean_rel=float(np.nanmean(rel)),
               p99_rel=float(np.nanpercentile(rel, 99)),
               max_rel_far=float(np.nanmax(rel[far])) if far.any() else 0.0,
               near_pole_frac=float(near.mean()),
               nonfinite=int((~np.isfinite(Z)).sum()),
               sign_flips=int(((np.sign(Z) != np.sign(ref)) & (np.abs(ref) > 1e-12)).sum()))
    if "V" in D:
        cmin, cmax = D["cmin"], D["cmax"]
        V, direct, y = D["V"], D["direct"][:MAXS], D["y"][:MAXS]
        def logits(z):
            return direct + np.clip(z, cmin, cmax) @ V.T
        res["acc_rtl"] = float((logits(Z.astype(np.float64)).argmax(1) == y).mean())
        res["acc_ref"] = float((logits(ref).argmax(1) == y).mean())
        res["acc_delta"] = round(res["acc_rtl"] - res["acc_ref"], 6)

    OUTDIR.mkdir(parents=True, exist_ok=True)
    (OUTDIR / f"{TAG}_replay.json").write_text(json.dumps(res, indent=2))
    dut._log.info("REPLAY " + json.dumps(res))
    if REQUIRE_FINITE:
        assert res["nonfinite"] == 0, f"[{FMT}] {res['nonfinite']} non-finite outputs"
    if ACC_TOL is not None and "acc_delta" in res:
        assert abs(res["acc_delta"]) <= ACC_TOL + 1e-12, (
            f"[{FMT}] accuracy moved by {res['acc_delta']:+.4f} (tol {ACC_TOL})")
