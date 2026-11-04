"""Chip-level (rondo_dev / rondo_chip_top) cocotb driver helpers built on the rbus BFM."""
import sys
from pathlib import Path
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from rondo_host import regmap as R            # noqa: E402
import chip_common as cc                      # noqa: E402
import fpmodel as fm                          # noqa: E402
from rondo_rbus_bfm import RbusMaster         # noqa: E402

A = R.ADDR
CTRL = R.CTRL_BITS
ERR = R.ERR_BITS
STAT = R.STATUS_BITS


class ChipTB:
    def __init__(self, dut, geo, clk=None, bare=True):
        self.dut, self.geo = dut, geo
        self.clk = clk if clk is not None else dut.clk
        self.rb = RbusMaster(dut, self.clk)
        self.g = R.Geometry(width=geo.width, pdim=geo.pdim, lanes=geo.lanes, nslot=geo.nslot, npar=geo.npar,
                            depth=geo.depth, nxbuf=geo.nxbuf)
        self.fmt = "bf16"
        self.bare = bare
        self.poll_gap = 0

    async def boot(self, period=10, strap=0):
        dut = self.dut
        self.clk_task = cocotb.start_soon(Clock(self.clk, period, unit="ns").start())
        for n in ("test_mode", "spi_err_frame", "spi_err_crc", "spi_frame_end"):
            if hasattr(dut, n):
                getattr(dut, n).value = 0
        if hasattr(dut, "bist_strap"):
            dut.bist_strap.value = strap
        if self.bare:
            for p in ("bf_", "fp_"):
                for n in ("w_we", "w_lane", "w_addr", "w_din", "b_we", "b_addr", "b_din", "start", "x"):
                    getattr(dut, p + n).value = 0
        dut.rst_n.value = 0
        if hasattr(dut, 'sva_viol'):
            self.sva_task = cocotb.start_soon(self._sva_watch())
        await Timer(4 * period + 3, unit="ns")
        dut.rst_n.value = 1
        for _ in range(8):
            await FallingEdge(self.clk)
        await self.wait_idle()

    async def _sva_watch(self):
        while True:
            await FallingEdge(self.clk)
            v = self.dut.sva_viol.value
            if v.is_resolvable and int(v) != 0:
                raise AssertionError(f"protocol checker violation: sva_viol={int(v):#012x}")

    # ---- register helpers -----------------------------------------------------------------------
    async def rd(self, name):
        return await self.rb.read(A[name] if isinstance(name, str) else name)

    async def wr(self, name, val):
        return await self.rb.write(A[name] if isinstance(name, str) else name, val)

    async def rd64(self, lo, hi):
        l = await self.rd(lo)
        h = await self.rd(hi)
        return (h << 32) | l

    async def ctrl(self, *bits, val=None):
        v = 0
        for b in bits:
            v |= 1 << CTRL[b]
        return await self.wr("CTRL", v if val is None else val)

    async def status(self):
        return await self.rd("STATUS")

    async def wait_idle(self, timeout=200000):
        n = 0
        while True:
            s = await self.status()
            if not (s >> STAT["ACTIVE"]) & 1:
                return s
            n += 1
            assert n < timeout // 8, f"chip stays ACTIVE (STATUS={s:#x})"
            if self.poll_gap:                       # the external port has priority: leave gaps for internal masters
                for _ in range(self.poll_gap):
                    await FallingEdge(self.clk)

    async def errors(self):
        return R.bits(ERR, await self.rd("ERR_STATUS"))

    async def clear_errors(self):
        await self.wr("ERR_STATUS", 0xFFFFFFFF)

    # ---- data movement -----------------------------------------------------------------------------
    async def load_weights(self, fmt, Wl, Bl):
        w = 16 if fmt == "bf16" else 32
        ww, bw = cc.core_pack(self.geo, Wl, Bl)
        g = self.g
        for l in range(g.lanes):
            base = g.weight_word_addr(l, 0, 0)
            els = [e for words in ww[l] for e in words]
            await self.rb.write_burst(base, els)
            bbase = g.bias_word_addr(l, 0, 0)
            els = [e for words in bw[l] for e in words]
            await self.rb.write_burst(bbase, els)

    async def write_x(self, entry, x):
        await self.rb.write_burst(self.g.xbuf_addr(entry, 0), x)

    async def read_z(self):
        return await self.rb.read_burst(R.ZBUF_BASE, self.geo.width)

    async def set_format(self, fmt):
        await self.wr("FORMAT", 0 if fmt == "bf16" else 1)
        self.fmt = fmt
        await self.wait_idle()

    async def infer(self, entry=0):
        await self.wr("XSEL", entry)
        await self.ctrl("START")
        await self.wait_idle()
        return await self.read_z()

    def model_z(self, fmt, Wl, Bl, x):
        if fmt == "bf16":
            return cc.model_layer(self.geo, "bf16", Wl, Bl, x)[0]
        return cc.model_layer(self.geo, "fp32", Wl, Bl, x, nr_iters=2, tbits=8, seed=fm.load_seed(24, 8))[0]


async def _bare_load(self, fmt, Wl, Bl):
    p = "bf_" if fmt == "bf16" else "fp_"
    await cc.core_load(self.dut, self.geo, 16 if fmt == "bf16" else 32, Wl, Bl, pfx=p, clk=self.clk)


async def _bare_infer(self, fmt, x):
    """-> (z list, cycles) from the bare reference core (cycles as LAST_CYCLES defines them)."""
    p = "bf_" if fmt == "bf16" else "fp_"
    w = 16 if fmt == "bf16" else 32
    dut = self.dut
    getattr(dut, p + "x").value = cc.pack_x(x, w)
    await FallingEdge(self.clk)
    getattr(dut, p + "start").value = 1
    await FallingEdge(self.clk)
    getattr(dut, p + "start").value = 0
    n = 0
    while not int(getattr(dut, p + "done").value):
        await FallingEdge(self.clk)
        n += 1
        assert n < 20000
    z = cc.unpack_z(int(getattr(dut, p + "z").value), self.geo, w)
    for _ in range(4):
        await FallingEdge(self.clk)
    last = int(dut.bf_last.value if fmt == "bf16" else dut.fp_last.value)
    return z, last


ChipTB.bare_load = _bare_load
ChipTB.bare_infer = _bare_infer


# ======================= SPI-level driver (rondo_chip_top) =============================================
import random as _random                       # noqa: E402
from rondo_spi_bfm import SpiBfm                 # noqa: E402


class SpiBus:
    """rbus-like read/write interface carried over the SPI BFM (same method names as RbusMaster)."""

    def __init__(self, bfm, crc=False, chunk_words=1000):
        self.bfm, self.crc, self.chunk = bfm, crc, chunk_words
        self.last_err = 0
        self.max_latency = self.max_total = 0

    async def write(self, addr, data):
        await self.bfm.write(addr, [data & 0xFFFFFFFF], crc=self.crc)
        return 0

    async def read(self, addr):
        w, ok = await self.bfm.read(addr, 1, crc=self.crc)
        assert ok, "SPI read DCRC mismatch"
        return w[0]

    async def write_burst(self, addr, words):
        for i in range(0, len(words), self.chunk):
            await self.bfm.write(addr + i, [w & 0xFFFFFFFF for w in words[i:i + self.chunk]], crc=self.crc)

    async def read_burst(self, addr, n):
        out = []
        for i in range(0, n, self.chunk):
            w, ok = await self.bfm.read(addr + i, min(self.chunk, n - i), crc=self.crc)
            assert ok, "SPI read DCRC mismatch"
            out += w
        return out


class TopTB(ChipTB):
    """ChipTB over the SPI pins of rondo_chip_top."""

    def __init__(self, dut, geo, ratio=8.0, period=10, seed=1):
        self.dut, self.geo = dut, geo
        self.clk = dut.clk
        self.g = R.Geometry(width=geo.width, pdim=geo.pdim, lanes=geo.lanes, nslot=geo.nslot, npar=geo.npar,
                            depth=geo.depth, nxbuf=geo.nxbuf)
        self.fmt = "bf16"
        self.period = period
        self.bfm = SpiBfm(dut.spi_sclk, dut.spi_cs_n, dut.spi_mosi, dut.spi_miso, period, ratio, seed)
        self.rb = SpiBus(self.bfm)
        self.bare = False

    async def boot(self, strap=0, alt_period=None, rst_cycles=6):
        dut = self.dut
        self.clk_task = cocotb.start_soon(Clock(dut.clk, self.period, unit="ns").start())
        self.alt_task = None
        dut.clk_alt.value = 0
        if alt_period:
            self.alt_task = cocotb.start_soon(Clock(dut.clk_alt, alt_period, unit="ns").start())
        dut.bist_en.value = strap
        if hasattr(dut, "test_mode_pin"):
            dut.test_mode_pin.value = 0
        dut.rst_n.value = 0
        await Timer(rst_cycles * self.period, unit="ns")
        dut.rst_n.value = 1
        await Timer(20 * self.period, unit="ns")

    def set_core_period(self, core_period_ns, ratio=None):
        """retarget the SPI master to the (divided) core clock"""
        self.bfm.cp_ps = int(core_period_ns * 1000)
        self.bfm.set_ratio(ratio if ratio is not None else self.bfm.ratio)

    async def status8(self):
        rx = await self.bfm.xfer(bytes([0x05, 0x00]))
        return rx[1]

    async def wait_idle(self, timeout=400):
        for _ in range(timeout):
            s8 = await self.status8()
            if not (s8 >> 4) & 1:
                return await self.status()
        raise AssertionError("chip stays ACTIVE")
