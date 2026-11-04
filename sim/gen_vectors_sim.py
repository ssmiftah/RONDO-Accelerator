"""Simulation half of scripts/gen_vectors.py: runs bare reference cores (tb_chip_vs_core) and writes the vector file."""
import os
from pathlib import Path
import numpy as np
import cocotb
from chip_tb import ChipTB
import chip_common as cc
import fpmodel as fm
from rondo_host import packing as K, fmt as hf

GEOM = os.environ.get("CHIP_GEOM", "small")
GEO = cc.FULL if GEOM == "full" else cc.SMALL
OUT = Path(os.environ["GV_OUT"])
NX = 16


@cocotb.test()
async def gen(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    rng = np.random.default_rng(2026)
    D = None
    if GEOM == "full":
        D = np.load(Path(__file__).resolve().parents[1] / "workloads" / "results" / "waveform_coeffs.npz")
    out = dict(geom=np.array([GEO.width, GEO.pdim, GEO.lanes, GEO.depth, GEO.nslot, GEO.npar, GEO.nxbuf]))
    for fmt in ("bf16", "fp32"):
        w = 16 if fmt == "bf16" else 32
        if D is not None:
            Wf = D["Wden"].reshape(int(D["width"]), GEO.depth, GEO.pdim)[:GEO.width].astype(np.float32)
            Bf = D["bden"].reshape(int(D["width"]), GEO.depth)[:GEO.width].astype(np.float32)
            Xf = D["X"][:NX, :GEO.pdim].astype(np.float32)
        else:
            Wf = rng.normal(0, 0.12, (GEO.width, GEO.depth, GEO.pdim)).astype(np.float32)
            Bf = rng.normal(0, 0.5, (GEO.width, GEO.depth)).astype(np.float32)
            Xf = rng.uniform(-1, 1, (NX, GEO.pdim)).astype(np.float32)
        Wb = hf.to_bits(Wf, w).astype(np.uint64)
        Bb = hf.to_bits(Bf, w).astype(np.uint64)
        Xb = hf.to_bits(Xf, w).astype(np.uint64)
        Wl = Wb.tolist(); Bl = Bb.tolist()
        await t.bare_load(fmt, Wl, Bl)
        Z, C = [], []
        for i in range(NX):
            z, cyc = await t.bare_infer(fmt, [int(v) for v in Xb[i]])
            Z.append(z); C.append(cyc)
        ck = 0
        for i in range(12):
            ck = K.update(ck, Z[i % 4], w)
            if i == 3:
                first = ck
        # injection (spec 2.6): W = 0, B = a with a_{d-1} = beta, x = 0
        eps = 0.01
        beta = np.array([2.0 ** ((j % 9) - 4) * (1 if j % 2 == 0 else -1) for j in range(GEO.width)], dtype=np.float32)
        beta[1::7] = np.float32(0.004)          # below eps: guard hits
        beta[3::11] = np.float32(0.0)
        a = np.zeros((GEO.width, GEO.depth), dtype=np.float32)
        a[:, GEO.depth - 1] = beta
        Wz = np.zeros_like(Wb); Bi = hf.to_bits(a, w).astype(np.uint64)
        await t.bare_load(fmt, Wz.tolist(), Bi.tolist())
        zi, _ = await t.bare_infer(fmt, [0] * GEO.pdim)
        one = hf.to_bits(np.float32(1.0), w)
        out.update({f"{fmt}_Wb": Wb, f"{fmt}_Bb": Bb, f"{fmt}_Xb": Xb, f"{fmt}_Z": np.array(Z, dtype=np.uint64),
                    f"{fmt}_cycles": np.array(C), f"{fmt}_cks": np.array([ck, first], dtype=np.uint64),
                    f"{fmt}_beta": Bi[:, GEO.depth - 1], f"{fmt}_Zinj": np.array(zi, dtype=np.uint64),
                    f"{fmt}_one": np.array(one)})
        # restore the real weights in the bare core for the next format is not needed (reloaded per format)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    np.savez(OUT, **out)
