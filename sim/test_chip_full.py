"""T-FULL: Waveform coefficients through the chip at full geometry, both formats switching in one run.
8 samples bit-exact vs the bare cores and cycle-exact LAST_CYCLES; decisions vs golden f_ref; self-run CHECKSUM == model."""
import os
from pathlib import Path
import numpy as np
import cocotb
from chip_tb import ChipTB, R, STAT
import chip_common as cc
from rondo_host import packing as K, fmt as hf, regmap

GEO = cc.FULL
NPZ = Path(__file__).resolve().parents[1] / "workloads" / "results" / "waveform_coeffs.npz"
NS = int(os.environ.get("FULL_NSAMP", "8"))


def f_ref(a, eps=0.01):
    d = len(a)
    Kc = np.ones(d + 2)
    Kc[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        Kc[k] = a[k] * Kc[k + 1] + Kc[k + 2]
    return np.sign(Kc[1]) * np.sign(Kc[0]) * abs(Kc[1]) / max(abs(Kc[0]), eps)


@cocotb.test()
async def waveform_full(dut):
    D = np.load(NPZ)
    Wf = D["Wden"].reshape(int(D["width"]), GEO.depth, GEO.pdim)[:GEO.width].astype(np.float32)
    Bf = D["bden"].reshape(int(D["width"]), GEO.depth)[:GEO.width].astype(np.float32)
    X = D["X"][:NS, :GEO.pdim].astype(np.float32)
    V, direct, cmin, cmax, y = D["V"], D["direct"][:NS], D["cmin"][:GEO.width], D["cmax"][:GEO.width], D["y"][:NS]
    t = ChipTB(dut, GEO)
    await t.boot()
    t.poll_gap = 30
    res = {}
    for fmt in ("bf16", "fp32", "bf16"):
        w = 16 if fmt == "bf16" else 32
        await t.set_format(fmt)
        Wl = hf.to_bits(Wf, w).astype(np.uint64).tolist()
        Bl = hf.to_bits(Bf, w).astype(np.uint64).tolist()
        xs = [[int(v) for v in hf.to_bits(X[i], w)] for i in range(NS)]
        await t.ctrl("CRC_CLR")
        await t.load_weights(fmt, Wl, Bl)
        await t.bare_load(fmt, Wl, Bl)
        zs = []
        for base in range(0, NS, 4):
            for k in range(4):
                if base + k < NS:
                    await t.write_x(k, xs[base + k])
            for k in range(4):
                if base + k >= NS:
                    break
                zc = await t.infer(k)
                zb, cyc = await t.bare_infer(fmt, xs[base + k])
                assert zc == zb, f"{fmt} sample {base + k}: chip z != bare core z"
                assert await t.rd("LAST_CYCLES") == cyc
                zs.append(zc)
        # decisions vs the golden float64 reference
        zf = np.array([[hf.from_bits(v, w) for v in z] for z in zs], dtype=np.float64)
        Aref = np.einsum("np,ldp->nld", X.astype(np.float64), Wf.astype(np.float64)) + Bf.astype(np.float64)
        zr = np.array([[f_ref(Aref[i, j]) for j in range(GEO.width)] for i in range(NS)])
        dec_chip = (direct + np.clip(zf, cmin, cmax) @ V[:, :GEO.width].T).argmax(1)
        dec_ref = (direct + np.clip(zr, cmin, cmax) @ V[:, :GEO.width].T).argmax(1)
        agree = float((dec_chip == dec_ref).mean())
        dut._log.info(f"T-FULL {fmt}: {NS} samples bit-exact vs bare core; decision agreement with golden {agree:.3f}")
        if fmt == "fp32":
            assert agree == 1.0
        # self-run: 4 entries x 3 passes
        await t.wr("SR_N", 4); await t.wr("SR_COUNT", 12)
        await t.ctrl("CKSUM_CLR", "CNT_CLR")
        for k in range(4):
            await t.write_x(k, xs[k % NS])
        await t.ctrl("SR_START")
        await t.wait_idle()
        zmodel = [zs[k % NS] for k in range(4)]
        c = 0
        passes = []
        for i in range(12):
            c = K.update(c, zmodel[i % 4], w)
            if i == 3:
                first = c
        assert await t.rd("CHECKSUM") == c, f"{fmt}: self-run CHECKSUM"
        assert await t.rd("SR_PASS_CKSUM") == first
        assert await t.rd("SR_DONE_CNT") == 12
    dut._log.info("T-FULL: format switching bf16 -> fp32 -> bf16 with Waveform weights OK")
