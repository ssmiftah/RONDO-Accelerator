"""kan_layer_pipe / kan_layer_bf16: xt in, y out, coefficients resident.

Stimulus comes from an npz (KAN_IN) holding
    xt [B, p]           layer inputs, already tanh-squashed on the host (fp64)
    c  [O, p, D+1]      coefficients (fp64), O = the DUT's N_OUT (padded by the
                        runner with zero rows when the real layer is smaller)
Both are quantised on the host to the DUT format (RNE), loaded through the real
load port, and every sample is run start -> done.

Checks
  1. bit-exact: the first KAN_CHECK samples against sim/kan_rtl_model.py, which
     models every FMA with one exact rounding in the RTL's operation order
  2. characterisation: relative error of every output against the fp64 layer
Writes y (as floats), cycles per evaluation and the check results to KAN_OUT.
"""
import os, json, time
from pathlib import Path
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ReadOnly
from cocotb.utils import get_sim_time
from kan_rtl_model import FP32, BF16, kan_layer_bits

IN = Path(os.environ["KAN_IN"])
OUT = Path(os.environ["KAN_OUT"])
NCHECK = int(os.environ.get("KAN_CHECK", "2"))
MAXS = int(os.environ.get("KAN_MAXSAMP", "1000000"))


@cocotb.test()
async def kan_layer(dut):
    D = np.load(IN)
    XT, C = D["xt"].astype(np.float64), D["c"].astype(np.float64)
    WB = len(dut.x) // XT.shape[1]
    fmt = FP32 if WB == 32 else BF16
    p = XT.shape[1]
    n_out = len(dut.y) // WB
    nl = int(dut.N_LANES.value)
    nob = int(dut.NOB.value)
    nmac = int(dut.NMAC.value)
    nbas = int(dut.NBAS.value)
    depth = int(dut.DEPTH.value)
    dp1 = depth + 1
    assert C.shape == (n_out, p, dp1), f"c {C.shape} vs DUT ({n_out},{p},{dp1})"
    noutl = n_out // nl
    ngroup = nob * dp1 // nmac
    nbat = noutl // nob

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    for sig in ("w_we", "w_lane", "w_addr", "w_din", "start", "x"):
        getattr(dut, sig).value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    cb = [[[fmt.from_float(C[o, i, n]) for n in range(dp1)] for i in range(p)]
          for o in range(n_out)]
    t0 = time.time()
    for l in range(nl):
        dut.w_lane.value = l
        for b in range(nbat):
            for g in range(ngroup):
                for i in range(p):
                    word = 0
                    for f in range(nmac):
                        ch = g * nmac + f
                        o = l * noutl + b * nob + ch // dp1
                        word |= cb[o][i][ch % dp1] << (f * WB)
                    dut.w_addr.value = (b * ngroup + g) * p + i
                    dut.w_din.value = word
                    dut.w_we.value = 1
                    await RisingEdge(dut.clock)
    dut.w_we.value = 0
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
    dut._log.info(f"loaded {n_out}x{p}x{dp1} coefficients in {time.time()-t0:.1f}s")

    n = min(MAXS, len(XT))
    ybits = np.zeros((n, n_out), dtype=np.uint64)
    cycles = []
    mism, checked = 0, 0
    t0 = time.time()
    for s in range(n):
        xb = [fmt.from_float(v) for v in XT[s]]
        xv = 0
        for i in range(p):
            xv |= xb[i] << (i * WB)
        dut.x.value = xv
        dut.start.value = 1
        await RisingEdge(dut.clock)
        t_start = get_sim_time("ns")
        dut.start.value = 0
        while True:
            await RisingEdge(dut.clock)
            await ReadOnly()
            if dut.done.value == 1:
                break
        # cycles from the start edge to the edge that raised done
        cycles.append(int(round((get_sim_time("ns") - t_start) / 10.0)))
        yv = int(dut.y.value)
        for o in range(n_out):
            ybits[s, o] = (yv >> (o * WB)) & ((1 << WB) - 1)
        await RisingEdge(dut.clock)
        if s < NCHECK:
            ref = kan_layer_bits(fmt, xb, cb)
            for o in range(n_out):
                got = int(ybits[s, o])
                # +0 and -0 compare equal
                if got != ref[o] and not ((got | ref[o]) & ~(1 << (WB - 1)) == 0):
                    mism += 1
                    if mism <= 5:
                        dut._log.error(f"sample {s} out {o}: rtl {got:#x} "
                                       f"({fmt.to_float(got)!r}) model {ref[o]:#x} "
                                       f"({fmt.to_float(ref[o])!r})")
                checked += 1

    yf = np.array([[fmt.to_float(int(b)) for b in row] for row in ybits])
    # fp64 reference of the same layer (host-side basis by recurrence)
    T = np.empty((n, p, dp1))
    T[..., 0] = 1.0
    T[..., 1] = XT[:n]
    for k in range(1, depth):
        T[..., k + 1] = 2 * XT[:n] * T[..., k] - T[..., k - 1]
    yref = np.einsum("bin,oin->bo", T, C)
    rel = np.abs(yf - yref) / (np.abs(yref) + 1e-30)
    cyc = float(np.mean(cycles))
    dut._log.info(
        f"KANLAYER wb={WB} p={p} n_out={n_out} lanes={nl} nob={nob} nmac={nmac} "
        f"nbas={nbas} depth={depth}: {n} samples in {time.time()-t0:.1f}s, "
        f"cycles/eval={cyc:.2f} (min {min(cycles)} max {max(cycles)}), "
        f"cycles/output={cyc/n_out:.4f}, bitexact {checked-mism}/{checked}, "
        f"max_rel_vs_fp64={rel.max():.3e} median={np.median(rel):.3e}")
    OUT.parent.mkdir(parents=True, exist_ok=True)
    np.savez(OUT, y=yf, ybits=ybits, yref=yref, cycles=np.array(cycles))
    OUT.with_suffix(".json").write_text(json.dumps(dict(
        wb=WB, p=p, n_out=n_out, lanes=nl, nob=nob, nmac=nmac, nbas=nbas,
        depth=depth, samples=n, cycles_per_eval=cyc,
        cycles_min=int(min(cycles)), cycles_max=int(max(cycles)),
        cycles_per_output=cyc / n_out, bitexact_checked=checked,
        bitexact_mismatch=mism, max_rel_vs_fp64=float(rel.max()),
        median_rel_vs_fp64=float(np.median(rel))), indent=2))
    assert mism == 0, f"{mism}/{checked} outputs differ from the exact model"
