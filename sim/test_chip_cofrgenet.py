"""T-CFG: CoFrGeNet-shaped layer (p = 768, S = 20 slices of PDIM 40) through rondo_dev with WIDTH 16, 2 lanes.

First 16 ladders and 8 samples of workloads/results/cofrgenet_shape.npz. The tiled chip must be bit-identical to a
bare UNTILED fused_coproc_pipe with PDIM = 800 (768 real + 32 padding: weights -0, inputs +0). fp32 is also compared
with the float64 golden f_ref (max relative error on unguarded ladders); bf16 agreement is reported, not asserted."""
import sys
from pathlib import Path
import numpy as np
import cocotb
from chip_tb import ChipTB
import chip_common as cc
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from rondo_host import fmt as hf             # noqa: E402

PDIM, PW, S, TILE_B, NL, NS = 40, 800, 20, 8, 16, 8
P = 768
GEO = cc.Geo(16, PDIM, 2)
GEOW = cc.Geo(16, PW, 2)
NPZ = Path(__file__).resolve().parents[1] / "workloads" / "results" / "cofrgenet_shape.npz"
WB = {"bf16": 16, "fp32": 32}
NEGZ = {"bf16": 0x8000, "fp32": 0x80000000}


def f_ref(a, eps):
    d = len(a)
    K = np.ones(d + 2)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    z = np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), eps)
    return z, abs(K[0]) < eps


@cocotb.test()
async def cofrgenet(dut):
    D = np.load(NPZ)
    depth = int(D["depth"]); eps = float(D["eps"])
    Wd = D["Wden"][:NL * depth].astype(np.float64)
    bd = D["bden"][:NL * depth].astype(np.float64)
    X = D["X"][:NS].astype(np.float64)
    t = ChipTB(dut, GEO)
    await t.boot()
    # golden
    A = X @ Wd.T + bd                                  # (NS, NL*depth)
    zref = np.zeros((NS, NL)); guarded = np.zeros((NS, NL), bool)
    for i in range(NS):
        for j in range(NL):
            zref[i, j], guarded[i, j] = f_ref(A[i, j * depth:(j + 1) * depth], eps)
    for fmt in ("fp32", "bf16"):
        wb = WB[fmt]
        await t.set_format(fmt)
        Wb = hf.to_bits(Wd.astype(np.float32), wb)
        Bb = hf.to_bits(bd.astype(np.float32), wb)
        Xb = hf.to_bits(X.astype(np.float32), wb)
        W = [[[int(v) for v in Wb[j * depth + k]] + [NEGZ[fmt]] * (PW - P) for k in range(depth)] for j in range(NL)]
        B = [[int(Bb[j * depth + k]) for k in range(depth)] for j in range(NL)]
        xs = [[int(v) for v in Xb[i]] + [0] * (PW - P) for i in range(NS)]
        await cc.core_load(dut, GEOW, wb, W, B, pfx="bf_" if fmt == "bf16" else "fp_", clk=t.clk)
        ref = [(await t.bare_infer(fmt, x))[0] for x in xs]
        await t.wr("TILE_CFG", 1 | (S << 8) | (NS << 16))
        for s in range(S):
            Ws = [[row[s * PDIM:(s + 1) * PDIM] for row in Wj] for Wj in W]
            await t.ctrl("CRC_CLR")
            await t.load_weights(fmt, Ws, B)
            for b in range(NS):
                await t.rb.write_burst(t.g.tx_addr(b, 0), xs[b][s * PDIM:(s + 1) * PDIM])
            await t.ctrl("TILE_RUN")
            await t.wait_idle(timeout=400000)
        for b in range(NS):
            z = await t.rb.read_burst(t.g.tz_addr(b, 0), NL)
            assert z == ref[b], f"{fmt} sample {b}: tiled != untiled PDIM={PW}"
        zf = np.array([[hf.from_bits(v, wb) for v in r] for r in ref])
        ok = ~guarded & np.isfinite(zf)
        rel = np.abs(zf - zref) / np.maximum(np.abs(zref), 1e-30)
        if fmt == "fp32":
            mr = float(rel[ok].max())
            dut._log.info(f"T-CFG fp32: bit-identical to untiled PDIM={PW}; max_rel vs f_ref on {int(ok.sum())} unguarded = {mr:.3e}")
            assert mr < 1e-3, mr
        else:
            sg = np.sign(zf[ok]) == np.sign(zref[ok])
            dut._log.info(f"T-CFG bf16: bit-identical to untiled; sign agreement {sg.mean():.3f}, median rel {np.median(rel[ok]):.3e}")
