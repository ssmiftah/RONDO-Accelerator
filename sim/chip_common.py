"""Shared helpers for the chip-level cocotb tests (geometry, packing, bare-core driver)."""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
import fpmodel as fm


class Geo:
    def __init__(self, width=16, pdim=8, lanes=2, nslot=8, npar=8, depth=7, nxbuf=4):
        self.width, self.pdim, self.lanes = width, pdim, lanes
        self.nslot, self.npar, self.depth, self.nxbuf = nslot, npar, depth, nxbuf
        self.nlad = width // lanes
        self.nch = nslot * depth
        self.ngroup = self.nch // npar
        self.nbatches = self.nlad // nslot
        self.nwords = self.nbatches * self.ngroup * pdim
        self.nbwords = self.nbatches * self.ngroup

    def params(self):
        return dict(WIDTH=self.width, PDIM=self.pdim, N_LANES=self.lanes,
                    NSLOT=self.nslot, NPAR=self.npar, DEPTH=self.depth)


SMALL = Geo()
FULL = Geo(64, 40, 8)

# format configs: name -> (Fmt, accsig fmt, tbits, eps pattern, seed file)
FORMATS = {
    "bf16": dict(f=fm.BF16, tbits=6, eps=0x3C24, seed="recip_seed_e8s8_t6.mem", sig=8),
    "fp32": dict(f=fm.FP32, tbits=12, eps=0x3C23D70A, seed="recip_seed_e8s24_t12.mem", sig=24),
}


def rand_elem(rng, f, lo_exp=-2, hi_exp=0):
    """random finite element, |v| in [2^lo_exp, 2^(hi_exp+1))"""
    s = rng.getrandbits(1)
    e = f.bias + rng.randint(lo_exp, hi_exp)
    m = rng.getrandbits(f.fr)
    return (s << (f.w - 1)) | (e << f.fr) | m


def rand_weights(rng, geo, f):
    """Wl[j][k][c], Bl[j][k] as bit patterns (small magnitudes keep the scan finite)."""
    Wl = [[[rand_elem(rng, f, -4, -1) for _ in range(geo.pdim)] for _ in range(geo.depth)]
          for _ in range(geo.width)]
    Bl = [[rand_elem(rng, f, -2, 1) for _ in range(geo.depth)] for _ in range(geo.width)]
    return Wl, Bl


def rand_x(rng, geo, f):
    return [rand_elem(rng, f, -3, 0) for _ in range(geo.pdim)]


def core_pack(geo, Wl, Bl):
    """-> (wwords[l][addr] = [npar elems], bwords[l][addr] = [npar elems])."""
    ww = [[None] * geo.nwords for _ in range(geo.lanes)]
    bw = [[None] * geo.nbwords for _ in range(geo.lanes)]
    for l in range(geo.lanes):
        for b in range(geo.nbatches):
            for g in range(geo.ngroup):
                for c in range(geo.pdim):
                    el = []
                    for f_ in range(geo.npar):
                        ch = g * geo.npar + f_
                        jj, kk = ch // geo.depth, ch % geo.depth
                        gl = l * geo.nlad + b * geo.nslot + jj
                        el.append(Wl[gl][kk][c])
                    ww[l][(b * geo.ngroup + g) * geo.pdim + c] = el
                el = []
                for f_ in range(geo.npar):
                    ch = g * geo.npar + f_
                    jj, kk = ch // geo.depth, ch % geo.depth
                    gl = l * geo.nlad + b * geo.nslot + jj
                    el.append(Bl[gl][kk])
                bw[l][b * geo.ngroup + g] = el
    return ww, bw


def word_int(elems, w):
    v = 0
    for i, e in enumerate(elems):
        v |= (e & ((1 << w) - 1)) << (i * w)
    return v


def model_layer(geo, fmt, Wl, Bl, x, accsig=None, nr_iters=1, tbits=None, seed=None):
    """Bit-exact layer model -> (z[], hits[], a[][], k0[], k1[])."""
    cfg = FORMATS[fmt]
    f = cfg["f"]
    fa = fm.Fmt(8, accsig if accsig else f.sig)
    tb = tbits or cfg["tbits"]
    sd = seed if seed is not None else fm.load_seed(f.sig, tb)
    z, hits, A, K0, K1 = [], [], [], [], []
    for j in range(geo.width):
        a = [fm.affine(f, fa, Wl[j][k], x, Bl[j][k]) for k in range(geo.depth)]
        h, zz, k0, k1 = fm.ladder(f, a, sd, tb, cfg["eps"], nr_iters)
        z.append(zz); hits.append(h); A.append(a); K0.append(k0); K1.append(k1)
    return z, hits, A, K0, K1


async def start_clock(dut, clk="clock", period=10):
    cocotb.start_soon(Clock(getattr(dut, clk), period, unit="ns").start())


async def core_reset(dut, geo, w):
    for s in ("w_we", "b_we", "start", "w_addr", "w_din", "b_addr", "b_din", "x", "w_lane"):
        if hasattr(dut, s):
            getattr(dut, s).value = 0
    dut.nReset.value = 0
    await Timer(35, unit="ns")
    dut.nReset.value = 1
    await FallingEdge(dut.clock)


async def core_load(dut, geo, w, Wl, Bl, pfx="", clk=None):
    ww, bw = core_pack(geo, Wl, Bl)
    sg = lambda n: getattr(dut, pfx + n)
    clk = clk if clk is not None else dut.clock
    for l in range(geo.lanes):
        for a, el in enumerate(ww[l]):
            sg("w_lane").value = l
            sg("w_addr").value = a
            sg("w_din").value = word_int(el, w)
            sg("w_we").value = 1
            await FallingEdge(clk)
        sg("w_we").value = 0
        for a, el in enumerate(bw[l]):
            sg("b_addr").value = a
            sg("b_din").value = word_int(el, w)
            sg("b_we").value = 1
            await FallingEdge(clk)
        sg("b_we").value = 0
    for _ in range(4):
        await FallingEdge(clk)


def pack_x(x, w):
    return word_int(x, w)


def unpack_z(zv, geo, w):
    return [(zv >> (j * w)) & ((1 << w) - 1) for j in range(geo.width)]


async def core_infer(dut, geo, w, x, timeout=100000, start="start", done="done", gap=2):
    """One inference on a bare core. Returns (cycles, z list). cycles = edges after
    the start-sampling edge up to and including the edge after which done is 1."""
    getattr(dut, "x").value = pack_x(x, w)
    await FallingEdge(dut.clock)
    getattr(dut, start).value = 1
    await FallingEdge(dut.clock)     # start sampled by the rising edge in between
    getattr(dut, start).value = 0
    c = 1
    while int(getattr(dut, done).value) != 1:
        await FallingEdge(dut.clock)
        c += 1
        assert c < timeout, "core hung"
    zv = int(dut.z.value)
    for _ in range(gap):
        await FallingEdge(dut.clock)
    return c, unpack_z(zv, geo, w)


def affine_acc(f, f_acc, wv, xv, bv):
    """accumulator value (EXP+ACCSIG bits) after the coefficient stage."""
    acc = fm.widen(f_acc, f, bv)
    for c in range(len(xv)):
        acc = fm.fma(f_acc, fm.widen(f_acc, f, wv[c]), fm.widen(f_acc, f, xv[c]), acc)
    return acc


async def dbg_read(dut, lane, sig, idx, settle=4):
    dut.dbg_lane.value = lane
    dut.dbg_sig.value = sig
    dut.dbg_idx.value = idx
    for _ in range(settle):
        await FallingEdge(dut.clock)
    return int(dut.dbg_data.value)


async def tb_core_reset(dut, geo, w):
    for s in ("lane_en", "dbg_lane", "dbg_sig", "dbg_idx", "dbg_live_sel"):
        getattr(dut, s).value = 0 if s != "lane_en" else (1 << geo.lanes) - 1
    await core_reset(dut, geo, w)


def ulp_key(f, a, b):
    def key(u):
        return (u ^ ((1 << f.w) - 1)) if (u >> (f.w - 1)) else (u | (1 << (f.w - 1)))
    return abs(key(a) - key(b))
