"""Run the KAT for each format on the RTL (signature constants are zero-free: any value is accepted), dump the
measured signatures, and cross-check the RTL against the bit-exact model and the golden float64 f_ref."""
import json, os
from pathlib import Path
import numpy as np
import cocotb
from chip_tb import ChipTB, R, ERR
import chip_common as cc
import fpmodel as fm
from rondo_host import packing as K, regmap, fmt as hf
import test_chip_kat as tk

GEOM = os.environ.get("CHIP_GEOM", "small")
GEO = cc.FULL if GEOM == "full" else cc.SMALL
tk.GEO = GEO


def f_ref(a, eps=0.01):
    d = len(a)
    Kc = np.ones(d + 2)
    Kc[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        Kc[k] = a[k] * Kc[k + 1] + Kc[k + 2]
    return np.sign(Kc[1]) * np.sign(Kc[0]) * abs(Kc[1]) / max(abs(Kc[0]), eps), Kc[0]


def golden_check(fmt):
    w = 16 if fmt == "bf16" else 32
    g = regmap.Geometry(width=GEO.width, pdim=GEO.pdim, lanes=GEO.lanes, nslot=GEO.nslot, npar=GEO.npar,
                        depth=GEO.depth, nxbuf=GEO.nxbuf)
    Wd, Bd, X = K.kat_stream(g, w, GEO.nxbuf)
    Wl, Bl = K.unpack_weights(Wd, Bd, g)
    _, zs = tk.kat_signature(fmt)
    worst, ncmp, flips = 0.0, 0, 0
    for e, x in enumerate(X):
        xv = np.array([hf.from_bits(int(v), w) for v in x], dtype=np.float64)
        Wf = np.vectorize(lambda v: hf.from_bits(int(v), w))(Wl).astype(np.float64)
        Bf = np.vectorize(lambda v: hf.from_bits(int(v), w))(Bl).astype(np.float64)
        A = Wf @ xv + Bf
        Mag = np.abs(Wf) @ np.abs(xv) + np.abs(Bf)          # sum of |terms| of every coefficient
        for j in range(GEO.width):
            ref, k0 = f_ref(A[j])
            got = hf.from_bits(zs[e][j], w)
            # excluded as ill-conditioned (documented in the log): near a pole / guard-clamped, a coefficient that
            # cancels to < 1% of its terms, or a continuant that cancels to < 1% of its absolute-value recurrence
            _, k0abs = f_ref(np.abs(A[j]) + 0.0)
            if abs(k0) < 0.05 or np.min(np.abs(A[j]) / Mag[j]) < 1e-2 or abs(k0) < 1e-2 * abs(k0abs):
                continue
            ncmp += 1
            rel = abs(got - ref) / (abs(ref) + 1e-30)
            if fmt == "fp32":
                worst = max(worst, rel)
            else:
                flips += int(np.sign(got) != np.sign(ref))
    return worst, ncmp, flips


@cocotb.test()
async def gen(dut):
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 40
    out = {}
    for fmt in ("bf16", "fp32"):
        await t.set_format(fmt)
        exp, _ = tk.kat_signature(fmt)
        await t.ctrl("KAT_START")
        await t.wait_idle(timeout=8000000)
        got = await t.rd("KAT_GOT_BF16" if fmt == "bf16" else "KAT_GOT_FP32")
        assert got == exp, f"{fmt}: RTL KAT signature {got:#x} != model {exp:#x}"
        worst, ncmp, flips = golden_check(fmt)
        if fmt == "fp32":
            assert worst < 1e-3, f"fp32 KAT outputs vs f_ref: max_rel {worst:.2e}"
        out[fmt] = dict(sig=got, golden_max_rel=worst, golden_compared=ncmp, sign_flips=flips)
        dut._log.info(f"KAT {GEOM} {fmt}: signature {got:#010x}, vs f_ref: max_rel={worst:.2e} over {ncmp}, sign flips {flips}")
    p = Path(os.environ.get("KAT_OUT", str(Path(__file__).resolve().parents[1] / "build" / "chip" / f"kat_sigs_{GEOM}.json")))
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(out, indent=1))
