"""RondoModel: byte-accurate software model of the RONDO chip behind the SPI protocol (spec 14.4).

Frames (opcodes, CRC-8, loopback, STATUS8), the register file (reset values, RO/W1C/self-clearing, error bits), the address
map and the element packing (staging / PARTIAL / read cache semantics are not needed because reads return the stored elements),
LOAD_CRC, ZBUF/XBUF, FORMAT switch effects, lane mask, counters, checksum, self-run, KAT and the input-tiling sequence are
modeled. Time is counted in core cycles: every SPI byte and rbus access advances it, an inference takes `infer_cycles`, so
ACTIVE, START_BUSY, BUSY_WR and timeouts behave like the chip. The sequencer is simplified in two ways: a self-run is evaluated
lazily and its cycle counts are idealized, and the trace buffer is a stub.

`compute(fmt, W_elems, B_elems, x_elems, lane_en) -> list of z bit patterns` is pluggable: the default is the golden float64
f_ref evaluated from the stored weights and rounded to the format (decision-level, not bit-exact); tests that need bit-exact
results install a replay of the RTL results.
"""
import numpy as np
from . import regmap as R
from . import protocol as P
from . import packing as K
from . import fmt as F

A = R.ADDR
EPS = {16: 0.01, 32: 0.01}


def default_compute(model, fmt, x_bits):
    """float64 golden: z = f_ref(W x + b) per ladder, rounded to the format; also returns the intermediates."""
    g, w = model.geom, (16 if fmt == 0 else 32)
    Wf, Bf = model._float_weights(w)
    x = np.array([F.from_bits(int(v), w) for v in x_bits], dtype=np.float64)
    a = np.einsum("jkc,c->jk", Wf, x) + Bf
    z, k0s, k1s = [], [], []
    d = g.depth
    for j in range(g.width):
        aj = a[j]
        Kc = np.ones(d + 2)
        Kc[d - 1] = aj[d - 1]
        for k in range(d - 2, -1, -1):
            Kc[k] = aj[k] * Kc[k + 1] + Kc[k + 2]
        with np.errstate(all="ignore"):
            f = np.sign(Kc[1]) * np.sign(Kc[0]) * abs(Kc[1]) / max(abs(Kc[0]), EPS[w])
        clamped = abs(Kc[0]) < EPS[w]
        z.append(F.to_bits(np.float32(f), w) if np.isfinite(f) else F.QNAN[w])
        k0s.append(F.to_bits(np.float32(Kc[0]), w)); k1s.append(F.to_bits(np.float32(Kc[1]), w))
        model._last_clamped[j] = clamped
    model._inter = dict(a=[[F.to_bits(np.float32(v), w) for v in row] for row in a], k0=k0s, k1=k1s, z=list(z))
    return z


class RondoModel:
    def __init__(self, geom=None, compute=None, f_core=50e6, infer_cycles=(400, 420), kat=True, trace=True, dbg=True,
                 mbist=False, tile=True, tile_b=8, nxbuf=4, version=R.VERSION_VALUE):
        self.geom = geom or R.Geometry()
        g = self.geom
        self.compute = compute or default_compute
        self.f_core = f_core
        self.infer_cycles = infer_cycles
        self.feat = dict(kat=kat, trace=trace, dbg=dbg, mbist=mbist, tile=tile)
        self.tile_b = tile_b if tile else 0
        self.version = version
        self.cyc = 0
        self.log = []                                  # (cycle, 'W'/'R', addr, data) rbus accesses
        self._events = []                              # (time, seq, fn)
        self._evseq = 0
        self._last_clamped = {}
        self._inter = None
        self.reset()

    # ------------------------------------------------------------------------------------------------------------
    def reset(self):
        g = self.geom
        self.fmt = 0
        self.r = dict(SCRATCH=0, IRQ_EN=0x7F, ERR_MASK=0xFFFFFDFF, XSEL=0, SR_N=1, SR_COUNT=0, WDOG_LIMIT=0,
                      LANE_EN=(1 << g.lanes) - 1, CLK_CFG=0, CLKOUT_CFG=0, PWR_CTRL=0, SPI_CFG=0, DBG_SEL=0, TRC_CFG=0,
                      TRC_TRIG_CYC=0, TILE_CFG=0, TILE_SLICE=0)
        self.err = 0
        self.irq_status = 0
        self.wstale = True
        self.wmem = [dict() for _ in range(g.lanes)]     # lane -> {core addr: [NPAR elements]}
        self.bmem = [dict() for _ in range(g.lanes)]
        self.xbuf = [[0] * g.pdim for _ in range(g.nxbuf)]
        self.zbuf = [0] * g.width
        self.zvalid = False
        self.load_crc_vals = []
        self.counters_clear(all_=True)
        self.heartbeat_cnt = 0
        self.busy_until = 0
        self.sr = None
        self.clk_pend = None
        self.dbg_data = 0
        self.kat_got = {0: 0, 1: 0}
        self.st = dict(running=False, done=False, pass_=False, ran=[0, 0], pass_f=[0, 0], at_reset=False)
        self.stg = {}
        self.part_tag = None
        self.xptr = 0
        self.lane_applied = self.r["LANE_EN"]
        self._wver = 0
        self._fw_cache = None
        self._events.clear()
        self.tile_reset()

    def counters_clear(self, all_=False):
        self.last_cycles = 0
        self.infer_cnt = 0
        self.busy_cyc = 0
        self.total_base = self.cyc
        self.sr_cyc = 0
        self.sr_done = 0
        self.checksum = 0
        self.sr_pass = 0
        self.guard_hits = 0
        self.naninf = 0

    # ---- helpers --------------------------------------------------------------------------------------------------
    @property
    def W(self):
        return 16 if self.fmt == 0 else 32

    def _float_weights(self, w):
        if self._fw_cache and self._fw_cache[0] == (self._wver, w):
            return self._fw_cache[1], self._fw_cache[2]
        g = self.geom
        Wl = np.zeros((g.width, g.depth, g.pdim), dtype=np.float64)
        Bl = np.zeros((g.width, g.depth), dtype=np.float64)
        for j in range(g.width):
            for k in range(g.depth):
                l, a, f = K.bias_addr(g, j, k)
                Bl[j, k] = F.from_bits(self.bmem[l].get(a, [0] * g.npar)[f], w)
                for c in range(g.pdim):
                    l, a, f = K.weight_addr(g, j, k, c)
                    Wl[j, k, c] = F.from_bits(self.wmem[l].get(a, [0] * g.npar)[f], w)
        self._fw_cache = ((self._wver, w), Wl, Bl)
        return Wl, Bl

    @property
    def active(self):
        return self.cyc < self.busy_until or (self.sr is not None) or self.st["running"] or self.tile_active()

    def status_bits(self):
        s = 0
        s |= int(self.cyc < self.busy_until or (self.sr is not None and self.sr["inflight"]))
        s |= int(self.active) << 1
        s |= int(self.sr is not None) << 2
        s |= int(bool(self.sr and self.sr["stopping"])) << 3
        s |= int(self.zvalid) << 4
        s |= (self.heartbeat_cnt >> 24 & 1) << 6 if False else 0
        s |= int(self.wstale) << 7
        s |= self.fmt << 8
        s |= (self.xptr & 15) << 12
        s |= (self.lane_applied & 0xFF) << 16
        s |= int(self._err_any()) << 31
        s |= (((self.cyc >> 24) & 1) << 6)
        return s

    def _err_any(self):
        return bool(self.err & self.r["ERR_MASK"])

    def status8(self):
        irq = int(self.irq_level())
        return (int(self._err_any()) << 7) | (irq << 6) | (int(self.sr is not None) << 5) | (int(self.active) << 4) | \
            (int(self.cyc < self.busy_until) << 3) | (self.fmt << 2) | 2

    def irq_level(self):
        st = self.irq_status | (int(self._err_any()) << 2)
        return bool(st & self.r["IRQ_EN"] & 0x7F)

    def _seterr(self, name):
        self.err |= 1 << R.ERR_BITS[name]

    # ---- time/event handling -------------------------------------------------------------------------------------------
    def _schedule(self, t, fn):
        self._evseq += 1
        self._events.append((t, self._evseq, fn))
        self._events.sort(key=lambda e: (e[0], e[1]))

    def _advance(self, now):
        while self._events and self._events[0][0] <= now:
            t, _, fn = self._events.pop(0)
            self.cyc = max(self.cyc, t)
            fn()
        self.cyc = max(self.cyc, now)

    def tick(self, cycles):
        self._advance(self.cyc + int(cycles))

    def advance_until_irq(self, max_cycles):
        """advance the model clock to the next irq edge or max_cycles; returns True if irq is high"""
        end = self.cyc + int(max_cycles)
        while not self.irq_level() and self.cyc < end:
            nxt = self._events[0][0] if self._events else end
            self._advance(min(max(nxt, self.cyc + 1), end))
        return self.irq_level()

    # ---- SPI frames -----------------------------------------------------------------------------------------------------
    def xfer(self, tx, hz=5_000_000):
        self._advance(self.cyc)
        rx = bytearray(len(tx))
        n = len(tx)
        crc = bool(self.r["SPI_CFG"] & 1)
        if n == 0:
            return b""
        op = tx[0]
        cyc_per_byte = max(1, int(8 * self.f_core / hz))
        if op == P.OP_LOOPBACK:
            rx[1:] = tx[:-1]
        elif op == P.OP_STATUS:
            for k in range(1, n):
                self._advance(self.cyc + cyc_per_byte)
                rx[k] = self.status8()
            self._finish_frame()
            return bytes(rx)
        elif op in (P.OP_NOP0, P.OP_NOP1):
            pass
        elif op in (P.OP_WRITE, P.OP_READ):
            self._rw_frame(op, tx, rx, crc, cyc_per_byte)
        else:
            self._seterr("SPI_FRAME")
        self._advance(self.cyc + n * cyc_per_byte)
        self._finish_frame()
        return bytes(rx)

    def _finish_frame(self):
        if self.clk_pend is not None and not self.active:
            div, src = self.clk_pend
            self.r["CLK_CFG"] = (self.r["CLK_CFG"] & ~0x13) | div | (src << 4)
            self.f_core = self.base_f_core() / (1 << div)
            self.clk_pend = None

    def base_f_core(self):
        return getattr(self, "_f_base", self.f_core * (1 << (self.r["CLK_CFG"] & 3)))

    def _rw_frame(self, op, tx, rx, crc, cyc_per_byte):
        n = len(tx)
        hl = 7 if crc else 6
        if n < hl:
            self._seterr("SPI_FRAME")
            return
        hdr = tx[:6]
        if crc and P.crc8(hdr) != tx[6]:
            self._seterr("SPI_CRC")
            return
        addr = (hdr[1] << 16) | (hdr[2] << 8) | hdr[3]
        nw = ((hdr[4] << 8) | hdr[5]) + 1
        per = 5 if crc else 4
        if op == P.OP_WRITE:
            p = hl
            for i in range(nw):
                if p + per > n:
                    if p < n:
                        self._seterr("SPI_FRAME")
                    return
                wb = tx[p:p + 4]
                if crc and P.crc8(wb) != tx[p + 4]:
                    self._seterr("SPI_CRC")
                    return
                self._rbus_write((addr + i) & 0xFFFFFF, int.from_bytes(wb, "big"))
                p += per
        else:
            p = hl + 1
            self._advance(self.cyc + 8)
            for i in range(nw):
                if p >= n:
                    return
                val = self._rbus_read((addr + i) & 0xFFFFFF)
                wb = val.to_bytes(4, "big")
                chunk = wb + (bytes([P.crc8(wb)]) if crc else b"")
                m = min(per, n - p)
                if m < per and i < nw:
                    pass
                rx[p:p + m] = chunk[:m]
                if m < per:
                    self._seterr("SPI_FRAME")
                    return
                p += per

    # ---- rbus ----------------------------------------------------------------------------------------------------------------
    def _rbus_write(self, addr, data):
        self.log.append((self.cyc, "W", addr, data))
        self._advance(self.cyc + 8)
        self._access(True, addr, data)

    def _rbus_read(self, addr):
        self._advance(self.cyc + 8)
        v = self._access(False, addr, 0)
        self.log.append((self.cyc, "R", addr, v))
        return v & 0xFFFFFFFF

    def _decode(self, addr):
        g = self.geom
        if addr >> 8 == 0:
            return ("reg", addr & 0xFF)
        top = addr >> 16
        off = addr & 0xFFFF
        if top == 0x01:
            e, i = off >> g.xw, off & ((1 << g.xw) - 1)
            if off >> g.xw < g.nxbuf and i < g.pdim:
                return ("xbuf", (e, i))
        elif top == 0x02:
            if off < g.width:
                return ("zbuf", off)
        elif top == 0x03:
            if self.feat["trace"] and (off >> 1) < 64:
                return ("trace", off)
        elif top == 0x04 and self.feat["tile"]:
            b, i = off >> g.xw, off & ((1 << g.xw) - 1)
            if b < max(self.tile_b, 1) and i < g.pdim:
                return ("tx", (b, i))
        elif top == 0x05 and self.feat["tile"]:
            wsh = max(1, (g.width - 1).bit_length())
            b, j = off >> wsh, off & ((1 << wsh) - 1)
            if b < max(self.tile_b, 1) and j < g.width:
                return ("tz", (b, j))
        elif top == 0x06 and self.feat["tile"]:
            sh = g.lnw + g.baw + g.fw
            b = off >> sh
            l = (off >> (g.baw + g.fw)) & ((1 << g.lnw) - 1)
            gg = (off >> g.fw) & ((1 << g.baw) - 1)
            f = off & ((1 << g.fw) - 1)
            if b < max(self.tile_b, 1) and l < g.lanes and gg < g.ngroup:
                return ("ps", (b, l, gg, f))
        elif top == 0x10:
            f = off & (g.npar - 1)
            gg = (off >> g.fw) & ((1 << g.baw) - 1)
            l = off >> (g.baw + g.fw)
            if (off >> (g.baw + g.fw + g.lnw)) == 0 and l < g.lanes and gg < g.nbwords:
                return ("bias", (l, gg, f))
        elif addr >> 23:
            off = addr & 0x7FFFFF
            f = off & (g.npar - 1)
            a = (off >> g.fw) & ((1 << g.waw) - 1)
            l = off >> (g.waw + g.fw)
            if (off >> (g.waw + g.fw + g.lnw)) == 0 and l < g.lanes and a < g.nwords:
                return ("wgt", (l, a, f))
        return (None, None)

    def _access(self, we, addr, data):
        kind, key = self._decode(addr)
        W = self.W
        mask = (1 << W) - 1
        if kind is None:
            self._seterr("ADDR")
            return 0
        if kind == "reg":
            return self._reg_write(key, data) if we else self._reg_read(key)
        if kind in ("wgt", "bias"):
            if self.active and not False:
                self._seterr("BUSY_WR")
                return 0
            l, a, f = key
            if not we:
                return (self.bmem if kind == "bias" else self.wmem)[l].get(a, [0] * self.geom.npar)[f] & mask
            self._write_elem(kind, l, a, f, data & mask)
            return 0
        if kind == "xbuf":
            e, i = key
            if we:
                if self.active:
                    self._seterr("BUSY_WR")
                    return 0
                self.xbuf[e][i] = data & mask
                return 0
            return self.xbuf[e][i] & mask
        if kind == "zbuf":
            if we:
                self._seterr("RO")
                return 0
            return self.zbuf[key]
        if kind == "trace":
            if we:
                self._seterr("RO")
            return 0
        return self.tile_access(kind, key, we, data)

    def _write_elem(self, kind, l, a, f, v):
        g = self.geom
        W = self.W
        self.load_crc_vals.append(v)
        self.wstale = False
        tag = (kind, l, a)
        if self.stg.get("mask") and self.stg.get("tag") != tag:
            self._seterr("PARTIAL")
            self.stg = {}
        self.stg.setdefault("els", [0] * g.npar)
        self.stg.setdefault("mask", 0)
        self.stg["tag"] = tag
        self.stg["els"][f] = v
        self.stg["mask"] |= 1 << f
        if f == g.npar - 1:
            if self.stg["mask"] != (1 << g.npar) - 1:
                self._seterr("PARTIAL")
            (self.bmem if kind == "bias" else self.wmem)[l][a] = list(self.stg["els"])
            self.stg = {}
            self._wver += 1

    # ---- registers -------------------------------------------------------------------------------------------------------------
    def _lo_hi(self, v64):
        return v64 & 0xFFFFFFFF, (v64 >> 32) & 0xFFFFFFFF

    def _reg_read(self, idx):
        g = self.geom
        name = R.NAME.get(idx)
        if name is None:
            self._seterr("ADDR")
            return 0
        feat_off = (name in ("DBG_SEL", "DBG_DATA") and not self.feat["dbg"]) or \
                   (name.startswith("TRC") and not self.feat["trace"]) or \
                   (name.startswith("KAT") or name == "ST_STATUS") and not self.feat["kat"] or \
                   (name.startswith("MBIST") and not self.feat["mbist"]) or \
                   (name.startswith("TILE") and not self.feat["tile"])
        if feat_off:
            return 0
        r = self.r
        if name == "CHIP_ID":
            return R.CHIP_ID_VALUE
        if name == "VERSION":
            return self.version
        if name == "CAPS":
            c = (1 << 0) | (1 << 1) | (1 << 4) | (1 << 5) | (1 << 7) | (1 << 13) | (1 << 14) | (1 << 15)
            for n, b in (("dbg", 8), ("trace", 9), ("kat", 10), ("mbist", 11), ("tile", 17)):
                if self.feat[n]:
                    c |= 1 << b
            return c
        if name == "GEOM0":
            return (g.pdim << 16) | g.width
        if name == "GEOM1":
            return (g.npar << 24) | (g.nslot << 16) | (g.lanes << 8) | g.depth
        if name == "GEOM2":
            return (3 << 24) | (g.baw << 16) | (g.waw << 8) | g.nxbuf
        if name == "GEOM3":
            return (2 << 28) | (1 << 24) | (8 << 20) | (6 << 16) | (5 << 8) | 8
        if name == "EPS_BF16":
            return 0x3C24
        if name == "EPS_FP32":
            return 0x3C23D70A
        if name == "CTRL":
            return 0
        if name == "STATUS":
            return self.status_bits()
        if name == "IRQ_STATUS":
            return (self.irq_status & ~4) | (int(self._err_any()) << 2)
        if name == "ERR_STATUS":
            return self.err
        if name == "FORMAT":
            return self.fmt
        if name == "CLK_CFG":
            return (r["CLK_CFG"] & 0x13)
        if name == "LAST_CYCLES":
            return self.last_cycles
        if name in ("INFER_CNT_LO", "INFER_CNT_HI", "BUSY_CYC_LO", "BUSY_CYC_HI", "TOTAL_CYC_LO", "TOTAL_CYC_HI",
                    "SR_CYC_LO", "SR_CYC_HI"):
            base = name[:-3]
            val = {"INFER_CNT": self.infer_cnt, "BUSY_CYC": self.busy_cyc, "TOTAL_CYC": self.cyc - self.total_base,
                   "SR_CYC": self.sr_cyc}[base]
            if name.endswith("_LO"):
                self._shadow = getattr(self, "_shadow", {})
                self._shadow[base] = (val >> 32) & 0xFFFFFFFF
                return val & 0xFFFFFFFF
            return getattr(self, "_shadow", {}).get(base, 0)
        if name == "SR_DONE_CNT":
            return self.sr_done
        if name == "CHECKSUM":
            return self.checksum
        if name == "SR_PASS_CKSUM":
            return self.sr_pass
        if name == "LOAD_CRC":
            return K.load_crc(self.load_crc_vals, self.W)
        if name == "GUARD_HITS":
            return self.guard_hits
        if name == "NANINF_CNT":
            return self.naninf
        if name == "DBG_DATA":
            return self.dbg_data
        if name == "TRC_STATUS":
            return 0
        if name == "ST_STATUS":
            s = self.st
            return int(s["running"]) | (int(s["done"]) << 1) | (int(s["pass_"] and s["done"]) << 2) | \
                (s["pass_f"][0] << 3) | (s["pass_f"][1] << 4) | (1 << 5) | (int(s["at_reset"]) << 6) | \
                (s["ran"][0] << 7) | (s["ran"][1] << 8)
        if name in ("KAT_SIG_BF16", "KAT_SIG_FP32"):
            return self.kat_expected(0 if name.endswith("BF16") else 1)
        if name == "KAT_GOT_BF16":
            return self.kat_got[0]
        if name == "KAT_GOT_FP32":
            return self.kat_got[1]
        if name in ("MBIST_STATUS", "MBIST_FAIL_ADDR", "MBIST_FAIL_XOR"):
            return 0
        if name.startswith("TILE"):
            return self.tile_reg_read(name)
        return r.get(name, 0)

    def _reg_write(self, idx, v):
        g = self.geom
        name = R.NAME.get(idx)
        if name is None:
            self._seterr("ADDR")
            return 0
        acc = R.REGS[name][1]
        r = self.r
        if acc == "RO":
            self._seterr("RO")
            return 0
        if name == "CTRL":
            self._ctrl(v)
        elif name == "IRQ_STATUS":
            self.irq_status &= ~(v & 0x7B)
        elif name == "ERR_STATUS":
            self.err &= ~v
        elif name == "IRQ_EN":
            r["IRQ_EN"] = v & 0x7F
        elif name == "FORMAT":
            if self.active:
                self._seterr("BUSY_WR")
            elif self.tile_open():
                self._seterr("TILE_SEQ")
            elif v > 1:
                self._seterr("RANGE")
            else:
                self._format_switch(v)
        elif name == "XSEL":
            if v >= g.nxbuf:
                self._seterr("RANGE")
            else:
                r["XSEL"] = v
        elif name == "SR_N":
            if not 1 <= v <= g.nxbuf:
                self._seterr("RANGE")
            else:
                r["SR_N"] = v
        elif name == "LANE_EN":
            if self.active:
                self._seterr("BUSY_WR")
            elif self.tile_open():
                self._seterr("TILE_SEQ")
            else:
                r["LANE_EN"] = v & ((1 << g.lanes) - 1)
        elif name == "CLK_CFG":
            if self.active:
                self._seterr("BUSY_WR")
            else:
                r["CLK_CFG"] = (r["CLK_CFG"] & ~0x13) | (v & 0x13)
                self.clk_pend = (v & 3, (v >> 4) & 1)
                if not hasattr(self, "_f_base"):
                    self._f_base = self.f_core * (1 << (r["CLK_CFG"] & 3 if False else 0))
        elif name == "CLKOUT_CFG":
            r[name] = v & 15
        elif name == "PWR_CTRL":
            if self.active:
                self._seterr("BUSY_WR")
            else:
                r[name] = v & 7
        elif name == "SPI_CFG":
            r[name] = v & 1
        elif name in ("DBG_SEL",):
            if not self.feat["dbg"]:
                self._seterr("ADDR")
            else:
                r[name] = v & 0x3FFFFFF
                self._dbg_latch()
        elif name in ("TRC_CFG", "TRC_TRIG_CYC"):
            if not self.feat["trace"]:
                self._seterr("ADDR")
            else:
                r[name] = v
        elif name in ("TILE_CFG", "TILE_SLICE"):
            return self.tile_reg_write(name, v)
        else:
            r[name] = v & 0xFFFFFFFF
        return 0

    def _dbg_latch(self):
        sel = self.r["DBG_SEL"]
        lane, sig, idx = sel & 15, (sel >> 4) & 7, (sel >> 8) & 255
        it = self._inter
        g = self.geom
        val = 0
        if it:
            nl = g.nlad
            if sig in (0, 1) and idx < g.nch:
                val = it["a"][lane * nl + idx // g.depth][idx % g.depth]
            elif sig == 2 and idx < g.nslot:
                val = it["k0"][lane * nl + idx]
            elif sig == 3 and idx < g.nslot:
                val = it["k1"][lane * nl + idx]
            elif sig == 4 and idx < nl:
                val = it["z"][lane * nl + idx]
            elif sig == 5:
                val = (g.nbatches * g.nslot) << 4
        self.dbg_data = val

    def _format_switch(self, v):
        self.fmt = v
        self.xbuf = [[0] * self.geom.pdim for _ in range(self.geom.nxbuf)]
        self.zbuf = [0] * self.geom.width
        self.zvalid = False
        self.checksum = self.sr_pass = self.last_cycles = 0
        self.load_crc_vals = []
        self.wstale = True
        self.stg = {}
        self.tile_invalidate(error=False)
        self.busy_until = max(self.busy_until, self.cyc + 8)

    # ---- commands ---------------------------------------------------------------------------------------------------------------
    def _ctrl(self, w):
        B = R.CTRL_BITS
        bit = lambda n: (w >> B[n]) & 1
        if bit("SOFT_RST"):
            return self._soft_reset()
        if bit("CNT_CLR"):
            self.infer_cnt = self.busy_cyc = self.last_cycles = 0
            self.total_base = self.cyc
        if bit("CKSUM_CLR"):
            self.checksum = self.sr_pass = 0
        if bit("CRC_CLR"):
            self.load_crc_vals = []
        if bit("GUARD_CLR"):
            self.guard_hits = self.naninf = 0
        if bit("TILE_ABORT"):
            if self.feat["tile"]:
                self.tile_invalidate(error=False)
                self.r["TILE_SLICE"] = 0
            else:
                self._seterr("ADDR")
        if bit("SR_STOP") and self.sr is not None:
            self.sr["stopping"] = True
        for n in ("TRC_ARM", "TRC_FORCE"):
            if bit(n) and not self.feat["trace"]:
                self._seterr("ADDR")
        if bit("DBG_LATCH"):
            if self.feat["dbg"]:
                self._dbg_latch()
            else:
                self._seterr("ADDR")
        starts = [n for n in ("START", "SR_START", "KAT_START", "MBIST_START", "TILE_RUN") if bit(n)]
        if not starts:
            return
        if self.active:
            self._seterr("START_BUSY")
            return
        if len(starts) > 1:
            self._seterr("START_BUSY")
        s = starts[0]
        tile_en = self.feat["tile"] and (self.r["TILE_CFG"] & 1)
        if s in ("START", "SR_START") and (tile_en or self.tile_open()):
            self._seterr("TILE_SEQ")
            return
        if s in ("KAT_START", "MBIST_START") and self.tile_open():
            self._seterr("TILE_SEQ")
            return
        if s == "START":
            self._start_single()
        elif s == "SR_START":
            self._start_sr()
        elif s == "KAT_START":
            if self.feat["kat"]:
                self._kat()
            else:
                self._seterr("ADDR")
        elif s == "MBIST_START":
            self._seterr("ADDR")
        elif s == "TILE_RUN":
            self.tile_run()

    def _soft_reset(self):
        keep = dict(self.r)
        self.sr = None
        self._events.clear()
        self.err = 0
        self.irq_status = 0
        self.zvalid = False
        self.zbuf = [0] * self.geom.width
        self.counters_clear()
        self.busy_until = self.cyc + 8
        self.stg = {}
        self.st = dict(running=False, done=False, pass_=False, ran=[0, 0], pass_f=[0, 0], at_reset=False)
        self.tile_invalidate(error=True)
        self.r = keep
        if self.feat["tile"]:
            self.r["TILE_SLICE"] = 0
            self.t["busy_until"] = 0

    def _cycles(self):
        return self.infer_cycles[self.fmt]

    def _lane_en(self):
        return self.lane_applied

    def _run_compute(self, entry_bits):
        g = self.geom
        W = self.W
        z = list(self.compute(self, self.fmt, entry_bits))
        for j in range(g.width):
            lane = j // g.nlad
            if not (self.lane_applied >> lane) & 1:
                z[j] = F.QNAN[W]
        return z

    def _complete(self, z, cycles, single, entry=None):
        g, W = self.geom, self.W
        self.zbuf = [v & ((1 << W) - 1) for v in z]
        self.zvalid = True
        self.last_cycles = cycles
        self.infer_cnt += 1
        self.busy_cyc += cycles
        self.checksum = K.update(self.checksum, self.zbuf, W)
        nan = sum(1 for j, v in enumerate(self.zbuf) if F.is_naninf(v, W) and (self.lane_applied >> (j // g.nlad)) & 1)
        if nan:
            self.naninf += nan
            self._seterr("NAN_INF")
        gh = sum(1 for j, c in self._last_clamped.items() if c and (self.lane_applied >> (j // g.nlad)) & 1)
        if gh:
            self.guard_hits += gh
            self._seterr("GUARD")
        lim = self.r["WDOG_LIMIT"]
        if lim and cycles > lim:
            self._seterr("WDOG")

    def _start_single(self):
        if self.wstale:
            self._seterr("WSTALE_RUN")
        self.lane_applied = self.r["LANE_EN"]
        e = self.r["XSEL"]
        self.xptr = e
        z = self._run_compute(self.xbuf[e])
        cyc = self._cycles()
        t0 = self.cyc
        self.busy_until = t0 + cyc + self.geom.width + 1

        def fin():
            self._complete(z, cyc, True)
            self.irq_status |= 1
        self._schedule(t0 + cyc + self.geom.width + 1, fin)

    def _start_sr(self):
        if self.wstale:
            self._seterr("WSTALE_RUN")
        self.lane_applied = self.r["LANE_EN"]
        n = self.r["SR_N"]
        self.checksum = self.sr_pass = 0
        self.sr_done = 0
        self.sr_cyc = 0
        self.sr = dict(n=n, count=self.r["SR_COUNT"], i=0, stopping=False, inflight=True, t0=self.cyc,
                       zs=[self._run_compute(self.xbuf[k]) for k in range(n)])
        self._sr_launch(self.cyc)

    def _sr_launch(self, t):
        sr = self.sr
        cyc = self._cycles()
        end = t + cyc
        sr["inflight"] = True

        def fin(sr=sr, cyc=cyc):
            if self.sr is not sr:
                return
            z = sr["zs"][sr["i"] % sr["n"]]
            self.xptr = sr["i"] % sr["n"]
            self._complete(z, cyc, False)
            sr["i"] += 1
            self.sr_done += 1
            if sr["i"] == sr["n"]:
                self.sr_pass = self.checksum
            sr["inflight"] = False
            last = sr["stopping"] or (sr["count"] and sr["i"] >= sr["count"])
            if last:
                end2 = self.cyc + self.geom.width + 1
                self.sr_cyc = end2 - sr["t0"]
                self.busy_until = max(self.busy_until, end2)

                def done():
                    self.sr = None
                    self.irq_status |= 2
                self._schedule(end2, done)
            else:
                self._sr_launch(self.cyc + 2)
        self._schedule(end, fin)

    def stop_pending(self):
        return self.sr is not None

    # ---- known-answer test ----------------------------------------------------------------------------------------------------------
    def kat_expected(self, f):
        return getattr(self, "_kat_exp", {}).get(f, 0)

    def _kat(self):
        g, W = self.geom, self.W
        Wd, Bd, X = K.kat_stream(g, W, g.nxbuf)
        for l in range(g.lanes):
            self.wmem[l] = {a: [int(v) for v in Wd[l, a]] for a in range(g.nwords)}
            self.bmem[l] = {a: [int(v) for v in Bd[l, a]] for a in range(g.nbwords)}
        self.xbuf = [[int(v) for v in e] for e in X]
        self._wver += 1
        saved = self.lane_applied
        self.lane_applied = (1 << g.lanes) - 1
        zs = [self._run_compute(self.xbuf[k]) for k in range(g.nxbuf)]
        self.lane_applied = saved
        sig = 0
        for i in range(2 * g.nxbuf):
            sig = K.update(sig, zs[i % g.nxbuf], W)
        self.kat_got[self.fmt] = sig
        if not hasattr(self, "_kat_exp"):
            self._kat_exp = {}
        self._kat_exp[self.fmt] = sig
        self.st.update(done=True, pass_=True)
        self.st["ran"][self.fmt] = 1
        self.st["pass_f"][self.fmt] = 1
        self.wstale = True
        self.load_crc_vals = []
        self.irq_status |= 1 << 4
        self.busy_until = self.cyc + 2 * g.nxbuf * self._cycles() + 2000

    # ---- input tiling (spec 18.6): decision-level model of the tile sequencer ------------------------------------------------------
    # Partial sums are float64 accumulators per (ladder, chain) -- the chip keeps them in the accumulator format -- and the final
    # ladder reuses the golden f_ref, so tiled results equal default_compute on the concatenated (padded) layer. Rules, errors,
    # TILE_STATUS, TILE_SEQ_CRC, IRQ bits and invalidation follow the RTL (rondo_tile.v).
    def tile_reset(self):
        g = self.geom
        tb = max(self.tile_b, 1)
        self.t = dict(open=False, slice=0, sdone=False, final=False, stale=False, done=0, crc=0, busy_until=0,
                      valid=[False] * tb, tag=[0] * tb, ps=[np.zeros((g.width, g.depth)) for _ in range(tb)],
                      tx=[[0] * g.pdim for _ in range(tb)], tz=[[0] * g.width for _ in range(tb)])
        self.r["TILE_CFG"] = 0
        self.r["TILE_SLICE"] = 0

    def tile_active(self):
        return self.feat["tile"] and self.cyc < self.t["busy_until"]

    def tile_open(self):
        return self.feat["tile"] and self.t["open"]

    def tile_invalidate(self, error=True):
        if not self.feat["tile"]:
            return
        t = self.t
        t["valid"] = [False] * len(t["valid"])
        if t["open"]:
            t["open"] = False
            t["slice"] = 0
            self.r["TILE_SLICE"] = 0
            if error:
                t["stale"] = True
                self._seterr("TILE_STALE")
        if not error:
            t["stale"] = False

    def _tile_cfg(self):
        c = self.r["TILE_CFG"]
        return dict(en=c & 1, nslice=(c >> 8) & 255, tbatch=(c >> 16) & 255, keep=(c >> 24) & 1, host=(c >> 25) & 1)

    def tile_reg_read(self, name):
        t = self.t
        if not self.feat["tile"]:
            self._seterr("ADDR")
            return 0
        if name == "TILE_CFG":
            return self.r["TILE_CFG"]
        if name == "TILE_SLICE":
            return self.r["TILE_SLICE"]
        if name == "TILE_GEOM":
            return self.tile_b | (16 << 8) | (32 << 16)
        if name == "TILE_SEQ_CRC":
            return t["crc"]
        c = self._tile_cfg()
        sl = (self.r["TILE_SLICE"] & 255) if c["host"] else t["slice"]
        return int(t["open"]) | (int(t["sdone"]) << 1) | (int(t["final"]) << 2) | (int(t["stale"]) << 3) | (sl << 8) | \
            ((t["done"] & 255) << 16)

    def tile_reg_write(self, name, v):
        if not self.feat["tile"]:
            self._seterr("ADDR")
            return 0
        t = self.t
        if name == "TILE_CFG":
            if self.active or t["open"]:
                self._seterr("TILE_SEQ")
                return 0
            en, ns, tbt, keep = v & 1, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 1
            tbmax = max(self.tile_b, 1)
            if en and (ns == 0 or tbt == 0 or (not keep and tbt > tbmax) or (self.tile_b == 0 and not keep)):
                self._seterr("RANGE")
                return 0
            self.r["TILE_CFG"] = en | (ns << 8) | ((1 if keep else tbt) << 16) | (keep << 24) | (((v >> 25) & 1) << 25)
            return 0
        c = self._tile_cfg()
        if not (c["host"] and t["open"]) or self.active:
            self._seterr("TILE_SEQ")
            return 0
        self.r["TILE_SLICE"] = v & 255
        return 0

    def tile_access(self, kind, key, we, data):
        t, g, W = self.t, self.geom, self.W
        if not self.feat["tile"]:
            self._seterr("ADDR")
            return 0
        if self.active:
            self._seterr("BUSY_WR")
            return 0
        mask = (1 << W) - 1
        if kind == "tx":
            b, i = key
            if we:
                t["tx"][b][i] = data & mask
                return 0
            return t["tx"][b][i]
        if kind == "tz":
            b, j = key
            if we:
                self._seterr("RO")
                return 0
            return t["tz"][b][j]
        b, l, gg, f = key                                   # ps
        j = l * g.nlad + (gg * g.npar + f) // g.depth
        k = (gg * g.npar + f) % g.depth
        if not we:
            return F.to_bits(np.float32(t["ps"][b][j, k]), W)
        t["ps"][b][j, k] = F.from_bits(data & mask, W)
        t["valid"][b] = True
        c = self._tile_cfg()
        sl = (self.r["TILE_SLICE"] & 255) if c["host"] else t["slice"]
        t["tag"][b] = (sl - 1) & 255
        return 0

    def tile_run(self):
        t, g, W = self.t, self.geom, self.W
        c = self._tile_cfg()
        if not self.feat["tile"]:
            self._seterr("ADDR")
            return
        if not c["en"]:
            self._seterr("TILE_SEQ")
            return
        s = (self.r["TILE_SLICE"] & 255) if c["host"] else t["slice"]
        if s >= c["nslice"]:
            self._seterr("TILE_SEQ")
            return
        nb = c["tbatch"]
        if s == 0 or t["open"]:
            if s != 0 and any((not t["valid"][b]) or t["tag"][b] != s - 1 for b in range(nb if not c["keep"] else 1)):
                t["stale"] = True
                self._seterr("TILE_STALE")
                return
        else:
            t["stale"] = True
            self._seterr("TILE_STALE")
            return
        if s == 0:
            t["open"] = True
            t["final"] = False
            t["stale"] = False
            t["valid"] = [False] * len(t["valid"])
            t["crc"] = K.crc32_chain(0, K.load_crc(self.load_crc_vals, W))
        else:
            t["crc"] = K.crc32_chain(t["crc"], K.load_crc(self.load_crc_vals, W))
        t["sdone"] = False
        t["done"] = 0
        last = s == c["nslice"] - 1
        self.lane_applied = self.r["LANE_EN"]
        Wf, Bf = self._float_weights(W)
        cyc = self._cycles()
        per = (cyc if last else 301) + (g.width if last else 0) + g.pdim + 8
        results = []
        for b in range(nb):
            x = np.array([F.from_bits(int(v), W) for v in t["tx"][b]], dtype=np.float64)
            part = np.einsum("jkc,c->jk", Wf, x)
            base = Bf if s == 0 else t["ps"][0 if c["keep"] else b]
            a = part + base
            if last:
                results.append(self._tile_ladders(a, W))
            else:
                results.append(a)
        t0 = self.cyc
        t["busy_until"] = t0 + per * nb

        def fin():
            for b in range(nb):
                self.infer_cnt += 1
                self.busy_cyc += per
                self.last_cycles = cyc if last else 301
                if last:
                    z = results[b]
                    t["tz"][b] = list(z)
                    self.zbuf = list(z)
                    self.zvalid = True
                    self.checksum = K.update(self.checksum, self.zbuf, W)
                    nan = sum(1 for j, v in enumerate(z) if F.is_naninf(v, W) and (self.lane_applied >> (j // g.nlad)) & 1)
                    if nan:
                        self.naninf += nan
                        self._seterr("NAN_INF")
                else:
                    t["ps"][0 if c["keep"] else b] = results[b]
                    t["valid"][0 if c["keep"] else b] = True
                    t["tag"][0 if c["keep"] else b] = s
            t["done"] = nb
            if last:
                t["final"] = True
                t["valid"] = [False] * len(t["valid"])
                if not c["host"]:
                    t["open"] = False
                    t["slice"] = 0
                    self.r["TILE_SLICE"] = 0
                self.irq_status |= 1 << 6
            else:
                t["sdone"] = True
                if not c["host"]:
                    t["slice"] = s + 1
                self.irq_status |= 1 << 5
        self._schedule(t0 + per * nb, fin)

    def _tile_ladders(self, a, W):
        g = self.geom
        d = g.depth
        z = []
        for j in range(g.width):
            aj = a[j]
            Kc = np.ones(d + 2)
            Kc[d - 1] = aj[d - 1]
            for k in range(d - 2, -1, -1):
                Kc[k] = aj[k] * Kc[k + 1] + Kc[k + 2]
            with np.errstate(all="ignore"):
                fv = np.sign(Kc[1]) * np.sign(Kc[0]) * abs(Kc[1]) / max(abs(Kc[0]), EPS[W])
            z.append(F.to_bits(np.float32(fv), W) if np.isfinite(fv) else F.QNAN[W])
        for j in range(g.width):
            if not (self.lane_applied >> (j // g.nlad)) & 1:
                z[j] = F.QNAN[W]
        return z


class MockPins:
    """gpio.Pins stand-in on a RondoModel: irq follows the model, waiting advances the model clock."""
    available = False

    def __init__(self, model):
        self.m = model
        self.bist_en = 0

    def wait_irq(self, timeout=1.0):
        cycles = int(timeout * self.m.f_core)
        return self.m.advance_until_irq(min(cycles, 50_000_000))

    def read(self, name):
        return {"irq": int(self.m.irq_level()), "busy": int(self.m.cyc < self.m.busy_until),
                "st_pass": int(self.m.st["pass_"] and self.m.st["done"]), "rst_n": 1, "bist_en": self.bist_en,
                "clkout": 0}.get(name, 0)

    def set_bist_en(self, v):
        self.bist_en = int(v)

    def pulse_reset(self, *a, **k):
        keep_fmt = None
        self.m.reset()

    def run_bist(self, rondo=None, timeout=10.0):
        self.m.fmt = 0
        for f in (0, 1):
            self.m.fmt = f
            self.m._kat()
        self.m.fmt = 0
        self.m.st["at_reset"] = True
        return True

    def busy_edges(self, timeout=0.0):
        return []

    def close(self):
        pass
