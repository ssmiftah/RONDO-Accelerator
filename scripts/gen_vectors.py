#!/usr/bin/env python3
"""Write build/vectors/rondo_vectors_<geom>.npz (spec 15.5): per format the packed weights, 16 inputs, expected z bits (from a bare-core
RTL simulation), expected LAST_CYCLES, self-run CHECKSUM / SR_PASS_CKSUM (4 entries x 3 passes), KAT signatures (rondo_kat_sigs.vh)
and the stage-isolation injection vectors (spec 2.6) with their expected z. usage: scripts/gen_vectors.py [small] [full]"""
import os, re, subprocess, sys
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
PY = os.environ.get("RONDO_PY") or (str(ROOT / ".venv-rtl" / "bin" / "python") if (ROOT / ".venv-rtl" / "bin" / "python").exists() else sys.executable)


def tiled_vectors(geom):
    """tiled case (p = 3 * PDIM): weights/inputs as floats, expected z bits from the bit-exact Python model (sim/fpmodel.py, which
    T-TILE/T-CFG proved equal to the untiled bare-core RTL at PDIM = p)"""
    sys.path[:0] = [str(ROOT / "sim"), str(ROOT / "host")]
    import chip_common as cc, fpmodel as fm
    from rondo_host import fmt as hf
    width, pdim, lanes, depth = geom[0], geom[1], geom[2], geom[3]
    P, N = 3 * pdim, 3
    gw = cc.Geo(width, P, lanes)
    rng = np.random.default_rng(1234)
    out = {}
    for fmt, w in (("bf16", 16), ("fp32", 32)):
        W = rng.normal(0, 0.12, (width * depth, P)).astype(np.float32)
        b = rng.normal(0, 0.5, width * depth).astype(np.float32)
        X = rng.uniform(-1, 1, (N, P)).astype(np.float32)
        Wb, Bb, Xb = hf.to_bits(W, w), hf.to_bits(b, w), hf.to_bits(X, w)
        Wl = [[[int(Wb[j * depth + k, c]) for c in range(P)] for k in range(depth)] for j in range(width)]
        Bl = [[int(Bb[j * depth + k]) for k in range(depth)] for j in range(width)]
        Z = []
        for i in range(N):
            if fmt == "bf16":
                z = cc.model_layer(gw, "bf16", Wl, Bl, [int(v) for v in Xb[i]])[0]
            else:
                z = cc.model_layer(gw, "fp32", Wl, Bl, [int(v) for v in Xb[i]], nr_iters=2, tbits=8, seed=fm.load_seed(24, 8))[0]
            Z.append(z)
        out.update({f"tile_{fmt}_W": W, f"tile_{fmt}_b": b, f"tile_{fmt}_X": X, f"tile_{fmt}_Z": np.array(Z, dtype=np.uint64)})
    return out


def main():
    geoms = [a for a in sys.argv[1:] if a in ("small", "full")] or ["small"]
    sigs = (ROOT / "rtl" / "chip" / "rondo_kat_sigs.vh").read_text()
    for g in geoms:
        out = ROOT / "build" / "vectors" / f"rondo_vectors_{g}.npz"
        env = dict(os.environ, PYTHONPATH=str(ROOT / "sim"), GV_GEOM=g, GV_OUT=str(out))
        p = subprocess.run([PY, "run_gen_vectors.py"], cwd=ROOT / "sim", env=env, capture_output=True, text=True)
        txt = p.stdout + p.stderr
        m = re.search(r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)", txt)
        if p.returncode or not m or m.group(3) != "0":
            print(txt[-3000:]); sys.exit(f"vector generation failed for {g}")
        D = dict(np.load(out))
        for f in ("bf16", "fp32"):
            mm = re.search(rf"RONDO_KATSIG_{g.upper()}_{f.upper()}\s+32'h([0-9a-f]+)", sigs)
            D[f"{f}_katsig"] = np.array(int(mm.group(1), 16), dtype=np.uint64)
        D.update(tiled_vectors([int(x) for x in D["geom"]]))
        np.savez(out, **D)
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
