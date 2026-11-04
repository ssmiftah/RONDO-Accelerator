"""End-to-end on pipelined arithmetic: fused_coproc_pipe, x to z.

Every earlier replay fed the RTL precomputed coefficients, which skipped the
affine stage -- ~98% of the layer's arithmetic. This drives the accelerator the
way it would actually be used: load the trained weights once, present an input
vector, read the ladder outputs.

Checked two ways:
  1. per-ladder z against an fp64 reference computed from the same x and W
  2. end-to-end classification accuracy from the RTL's own z, against the
     reference model's accuracy on the same samples
"""
import os, json
from pathlib import Path
import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_common import f32_to_bits, bits_to_f32

NPZ = Path(os.environ["WL_NPZ"])
MAXS = int(os.environ.get("WL_MAXSAMP", "20"))
EPS = 0.01


def f_ref(a):
    d = len(a)
    K = np.ones(d + 2)
    K[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        K[k] = a[k] * K[k + 1] + K[k + 2]
    return np.sign(K[1]) * np.sign(K[0]) * abs(K[1]) / max(abs(K[0]), EPS)


@cocotb.test()
async def fused(dut):
    D = np.load(NPZ)
    X, Wden, bden = D["X"], D["Wden"], D["bden"]
    depth = int(D["depth"])
    width = len(dut.z) // 32
    pdim = len(dut.x) // 32
    nlanes = int(dut.N_LANES.value)
    npar = int(dut.NPAR.value)
    nslot = int(dut.NSLOT.value)
    nlad = width // nlanes
    nch, nbatches = nslot * depth, nlad // nslot
    ngroup = nch // npar
    assert pdim == X.shape[1], f"PDIM {pdim} != dataset p {X.shape[1]}"

    # (WIDTH*DEPTH, p) -> per-ladder (DEPTH, p)
    Wl = Wden.reshape(int(D["width"]), depth, pdim)[:width]
    Bl = bden.reshape(int(D["width"]), depth)[:width]

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    for sig in ("w_we", "b_we", "start", "w_addr", "w_din", "b_addr", "b_din", "x"):
        getattr(dut, sig).value = 0
    dut.w_lane.value = 0        # port exists even at N_LANES=1 (width 1)
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await RisingEdge(dut.clock)

    # ---- load weights: lane l owns ladders [l*nlad, (l+1)*nlad) ----------
    # chain-major layout: within a batch, ch = j*depth + k; group g holds the
    # npar chains g*npar .. g*npar+npar-1, one memory word per (group, input)
    for l in range(nlanes):
        dut.w_lane.value = l
        for b in range(nbatches):
            for g in range(ngroup):
                for c in range(pdim):
                    word = 0
                    for f in range(npar):
                        ch = g * npar + f
                        jj, kk = ch // depth, ch % depth
                        gl = l * nlad + b * nslot + jj
                        word |= (f32_to_bits(np.float32(Wl[gl, kk, c])) & 0xFFFFFFFF) << (f * 32)
                    dut.w_addr.value = (b * ngroup + g) * pdim + c
                    dut.w_din.value = word
                    dut.w_we.value = 1
                    await RisingEdge(dut.clock)
                dut.w_we.value = 0
                word = 0
                for f in range(npar):
                    ch = g * npar + f
                    jj, kk = ch // depth, ch % depth
                    gl = l * nlad + b * nslot + jj
                    word |= (f32_to_bits(np.float32(Bl[gl, kk])) & 0xFFFFFFFF) << (f * 32)
                dut.b_addr.value = b * ngroup + g
                dut.b_din.value = word
                dut.b_we.value = 1
                await RisingEdge(dut.clock)
                dut.b_we.value = 0
    await RisingEdge(dut.clock)
    dut._log.info(f"weights loaded: {width} ladders x {depth} x {pdim}")

    # ---- run samples -----------------------------------------------------
    worst, cycles, n = 0.0, 0, min(MAXS, len(X))
    zr = np.zeros((n, width))
    for si in range(n):
        xs = X[si].astype(np.float32)
        xv = 0
        for i in range(pdim):
            xv |= (f32_to_bits(xs[i]) & 0xFFFFFFFF) << (i * 32)
        dut.x.value = xv
        dut.start.value = 1
        await RisingEdge(dut.clock)
        dut.start.value = 0
        c = 0
        while dut.done.value != 1:
            await RisingEdge(dut.clock)
            c += 1
            assert c < 2_000_000, "fused_coproc hung"
        cycles += c
        zv = int(dut.z.value)
        A = (Wl.astype(np.float64) @ xs.astype(np.float64)) + Bl.astype(np.float64)
        for j in range(width):
            got = bits_to_f32((zv >> (j * 32)) & 0xFFFFFFFF)
            zr[si, j] = got
            exp = f_ref(A[j])
            worst = max(worst, abs(got - exp) / (abs(exp) + 1e-30))

    cpl = cycles / (n * width)
    dut._log.info(f"FUSEDP width={width} pdim={pdim} lanes={nlanes} npar={npar}: "
                  f"{n} samples, {cycles/n:.0f} cycles/sample, "
                  f"{cpl:.2f} cycles/ladder, max_rel={worst:.2e}")

    # ---- end-to-end accuracy from the RTL's own z -------------------------
    V, direct = D["V"], D["direct"][:n]
    zc = np.clip(zr, D["cmin"][:width], D["cmax"][:width])
    logits = direct + zc @ V[:, :width].T
    acc_rtl = float((logits.argmax(1) == D["y"][:n]).mean())
    Aref = np.einsum("np,ldp->nld", X[:n].astype(np.float64), Wl.astype(np.float64)) \
        + Bl.astype(np.float64)
    zref = np.array([[f_ref(Aref[i, j]) for j in range(width)] for i in range(n)])
    zrefc = np.clip(zref, D["cmin"][:width], D["cmax"][:width])
    acc_ref = float(((direct + zrefc @ V[:, :width].T).argmax(1) == D["y"][:n]).mean())
    dut._log.info(f"FUSED accuracy: rtl={acc_rtl:.4f} ref={acc_ref:.4f} "
                  f"delta={acc_rtl-acc_ref:+.4f}")

    out = Path(os.environ.get("WL_OUT", "."))
    out.mkdir(parents=True, exist_ok=True)
    (out / f"fusedpipe_{NPZ.stem}_w{width}.json").write_text(json.dumps(dict(
        width=width, pdim=pdim, lanes=nlanes, npar=npar, samples=n,
        cycles_per_sample=cycles / n, cycles_per_ladder=cpl, max_rel=float(worst),
        acc_rtl=acc_rtl, acc_ref=acc_ref, acc_delta=acc_rtl - acc_ref,
        dec_rtl=logits.argmax(1).tolist(),
        dec_ref=(direct + zrefc @ V[:, :width].T).argmax(1).tolist()), indent=2))
    assert worst < 1e-3, f"z wrong: max_rel {worst:.2e}"
