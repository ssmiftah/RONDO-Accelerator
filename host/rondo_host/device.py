"""The `Rondo` host API (spec 14.5). Works against any Transport: spidev on a Pi 5, the byte-accurate mock model, or the RTL
through the cocotb transport. Everything above the transport is identical for the three targets."""
import time
import numpy as np
from . import regmap as R
from . import protocol as P
from . import packing as K
from . import fmt as F

A = R.ADDR
CT = R.CTRL_BITS


class RondoError(RuntimeError):
    pass


def spi_grid_floor(hz, base=200e6):
    """largest SPI0 clock <= hz that the RP1 divider can produce (base / even divider)"""
    n = int(np.ceil(base / max(hz, 1.0)))
    n += n & 1
    return base / n


class Rondo:
    def __init__(self, transport, pins=None, f_clk=50e6, crc=False, geom=None, max_hz=None, fp32_div=0, poll_gap=0,
                 f_clk_alt=None):
        from .gpio import NullPins
        self.t = transport
        self.pins = pins if pins is not None else NullPins()
        self.f_src = f_clk
        self.f_src_alt = f_clk if f_clk_alt is None else f_clk_alt
        self.div = 0                              # CLK_CFG.DIV code (÷1 ÷2 ÷4 ÷8)
        self.f_core = f_clk
        self.max_hz = max_hz if max_hz is not None else (10e6 if f_clk >= 100e6 else 5e6)
        self.fp32_div = fp32_div
        self.crc = crc
        self.geom = geom or R.Geometry()
        self.fmt = "bf16"
        self.caps = set()
        self.poll_gap = poll_gap
        self._set_sclk()

    # ---- link ----------------------------------------------------------------------------------------------------------
    def _set_sclk(self):
        hz = spi_grid_floor(min(self.f_core / 8.0, self.max_hz))
        self.sclk_hz = self.t.set_speed(hz)

    @property
    def W(self):
        return 16 if self.fmt == "bf16" else 32

    def write(self, addr, words):
        words = [int(w) & 0xFFFFFFFF for w in words]
        for a, n in P.split_burst(addr, len(words), P.OP_WRITE, self.crc):
            off = (a - addr) & 0xFFFFFF
            self.t.xfer(P.encode_write(a, words[off:off + n], self.crc))

    def read(self, addr, n):
        out = []
        for a, c in P.split_burst(addr, n, P.OP_READ, self.crc):
            tx, skip = P.encode_read(a, c, self.crc)
            words, ok = P.decode_read(self.t.xfer(tx), skip, c, self.crc)
            if not ok:
                raise RondoError("SPI read data CRC mismatch")
            out += words
        return out

    def reg(self, name):
        return self.read(A[name] if isinstance(name, str) else name, 1)[0]

    def set_reg(self, name, v):
        self.write(A[name] if isinstance(name, str) else name, [v])

    def reg64(self, name):
        lo, hi = self.read(A[name + "_LO"], 2)
        return (hi << 32) | lo

    def ctrl(self, *names):
        v = 0
        for n in names:
            v |= 1 << CT[n]
        self.write(A["CTRL"], [v])

    def status8(self):
        return P.decode_status8(self.t.xfer(P.encode_status(1))[1])

    # ---- bring-up (spec 9.1) ----------------------------------------------------------------------------------------------
    def loopback_test(self, n=16, seed=None):
        rng = np.random.default_rng(seed)
        tx = P.encode_loopback(bytes(rng.integers(0, 256, n, dtype=np.uint8).tolist()))
        rx = self.t.xfer(tx)
        if not P.decode_loopback(tx, rx):
            raise RondoError(f"loopback mismatch: sent {tx.hex()} got {bytes(rx).hex()}")
        return True

    def reset_check(self):
        s = self.status8()
        if not s["signature_ok"]:
            raise RondoError(f"STATUS8 signature wrong: {s['raw']:#04x}")
        if self.reg("CHIP_ID") != R.CHIP_ID_VALUE:
            raise RondoError("CHIP_ID mismatch")
        ver = self.reg("VERSION")
        caps = self.reg("CAPS")
        g0, g1, g2, g3 = (self.reg(n) for n in ("GEOM0", "GEOM1", "GEOM2", "GEOM3"))
        tg = self.reg("TILE_GEOM") if (caps >> R.CAPS_BITS["TILE"]) & 1 else 0
        self.caps = R.bits(R.CAPS_BITS, caps)
        self.layer = R.caps_layer(caps)
        self.version = ver
        if ver < 0x00020101:
            import warnings
            warnings.warn("pre-fix wrapper (VERSION < 0x00020101): PWR_CTRL/KAT refusal rules absent", RuntimeWarning)
        self.geom = R.Geometry.from_regs(g0, g1, g2, g3, tg)
        self.fmt = "fp32" if self.reg("FORMAT") else "bf16"
        return self.geom

    def _f_src_of(self, src):
        alt = (src == "clk_alt") if isinstance(src, str) else bool(src)
        return self.f_src_alt if alt else self.f_src

    def set_clock(self, div=0, src="clk"):
        """spec 14.3: CLK_CFG is applied when the frame that carries it ends. That frame goes out at the current SCLK (legal for the
        old clock); SCLK is then lowered to <= min(f_old, f_new)/8 BEFORE any further frame, the applied value is read back and SCLK is
        set from it. The FPGA top has no rondo_clkdiv (DIV_APPLIED reads 0, DIV has no effect): f_core then follows the readback."""
        self._wait_idle()
        want_alt = (src == "clk_alt") if isinstance(src, str) else bool(src)
        want = (div & 3) | ((1 if want_alt else 0) << 4)
        f_new = self._f_src_of(want_alt) / (1 << (div & 3))
        hz_safe = min(spi_grid_floor(min(self.f_core, f_new) / 8.0), spi_grid_floor(self.max_hz))
        self.set_reg("CLK_CFG", want)             # frame at the current (old-clock) SCLK
        self.sclk_hz = self.t.set_speed(hz_safe)  # before any further frame
        v = self.reg("CLK_CFG")                   # the applied value
        div_a, src_a = (v >> 16) & 3, (v >> 20) & 1
        if (div_a, src_a) != (div & 3, int(want_alt)) and not (div_a == 0 and src_a == 0):
            raise RondoError(f"CLK_CFG not applied: wanted DIV={div & 3} SRC={int(want_alt)}, DIV_APPLIED={div_a} SRC_APPLIED={src_a}")
        self.div = div_a
        self.f_core = self._f_src_of(src_a) / (1 << div_a)
        self._set_sclk()

    def set_format(self, fmt):
        if fmt not in ("bf16", "fp32"):
            raise ValueError(fmt)
        self._wait_idle()
        self.set_reg("FORMAT", 0 if fmt == "bf16" else 1)
        self._wait_idle()
        self.fmt = fmt
        want_div = self.fp32_div if fmt == "fp32" else 0
        if want_div != self.div:
            self.set_clock(want_div)

    def soft_reset(self):
        self.ctrl("SOFT_RST")
        self._wait_idle()

    def hard_reset(self):
        self.pins.pulse_reset()
        return self.reset_check()

    def enable_crc(self, on=True):
        self.set_reg("SPI_CFG", 1 if on else 0)
        self.crc = bool(on)

    def errors(self):
        return R.bits(R.ERR_BITS, self.reg("ERR_STATUS"))

    def clear_errors(self):
        self.set_reg("ERR_STATUS", 0xFFFFFFFF)

    def check_errors(self, allow=()):
        e = self.errors() - set(allow)
        if e:
            raise RondoError(f"chip reports errors: {sorted(e)}")

    def set_lane_mask(self, mask):
        self.set_reg("LANE_EN", mask)

    def clkout(self, k):
        self.set_reg("CLKOUT_CFG", k)

    def power_hold(self, on):
        if "TILE" in self.caps and self.reg("TILE_STATUS") & 1:
            raise RondoError("tile sequence open: TILE_ABORT or finish it before power_hold")
        self.clear_errors()
        self.set_reg("PWR_CTRL", 0b11 if on else 0)
        e = self.errors() & {"BUSY_WR", "TILE_SEQ"}
        if e:
            self.clear_errors()
            raise RondoError(f"PWR_CTRL write refused: {sorted(e)}")

    def mem_test(self, regions=("PS", "TX")):
        """March C- over every mapped PS element (current format width) and TX word through the memory map (CHIP_FIX_PLAN 13.1; MBIST does not
        cover these stores). Returns [] when clean, else failures (region, b, lane, group, field, xor). Needs a tile build and no open sequence;
        the PS valid bits are cleared afterwards (TILE_ABORT). ~39k word accesses at FULL."""
        from . import memtest
        if "TILE" not in self.caps or self.geom.tile_b < 1:
            raise RondoError("mem_test needs a tile build (CAPS.TILE, TILE_B >= 1)")
        self._wait_idle()
        if self.reg("TILE_STATUS") & 1:
            raise RondoError("tile sequence open: TILE_ABORT or finish it before mem_test")
        fails = memtest.run_blocking(memtest.march(self.geom, tuple(regions), self.W), self.read, self.write)
        self.ctrl("TILE_ABORT")                       # the PS writes marked entries valid
        return fails

    # ---- waiting -----------------------------------------------------------------------------------------------------------
    def _wait_idle(self, timeout=5.0):
        t0 = time.monotonic()
        n = 0
        while True:
            s8 = self.status8()
            if not s8["ACTIVE"]:
                return s8
            n += 1
            if time.monotonic() - t0 > timeout or n > 2_000_000:
                raise RondoError("chip stays ACTIVE")
            for _ in range(self.poll_gap):
                self.t.xfer(P.encode_status(0))

    def _wait_irq(self, timeout=1.0):
        if self.pins.available:
            ok = self.pins.wait_irq(timeout)
            if ok is not None:
                if not ok:
                    raise RondoError("timeout waiting for irq")
                return
        self._wait_idle(timeout)

    # ---- data ----------------------------------------------------------------------------------------------------------------
    def _bits(self, arr):
        return np.asarray(F.to_bits(np.asarray(arr, dtype=np.float32), self.W), dtype=np.uint64)

    def load_weights(self, Wl, Bl, verify="crc"):
        """Wl (width, depth, pdim) and Bl (width, depth) floats -> chip (current FORMAT)."""
        g = self.geom
        return self.load_weights_bits(self._bits(np.reshape(Wl, (g.width, g.depth, g.pdim))),
                                      self._bits(np.reshape(Bl, (g.width, g.depth))), verify)

    def load_weights_bits(self, Wb, Bb, verify="crc", with_bias=True):
        """same, from W-bit element patterns"""
        g = self.geom
        W = self.W
        Wb = np.asarray(Wb, dtype=np.uint64)
        Bb = np.asarray(Bb, dtype=np.uint64)
        Wp, Bp = K.pack_weights(Wb, Bb, g)
        self.ctrl("CRC_CLR")
        vals = []
        for l in range(g.lanes):
            ws = [int(v) for v in Wp[l].reshape(-1)]
            bs = [int(v) for v in Bp[l].reshape(-1)]
            self.write(g.weight_word_addr(l, 0, 0), ws)
            if with_bias:
                self.write(g.bias_word_addr(l, 0, 0), bs)
            vals += ws + (bs if with_bias else [])
        self.last_load_crc = K.load_crc(vals, W)
        if verify == "crc":
            got, want = self.reg("LOAD_CRC"), self.last_load_crc
            if got != want:
                raise RondoError(f"LOAD_CRC {got:#010x} != host {want:#010x}")
        elif verify == "readback":
            Wr, Br = self.read_weights(bits=True)
            if not (np.array_equal(Wr, Wb) and np.array_equal(Br, Bb)):
                raise RondoError("weight read-back mismatch")
        self.check_errors(allow=("GUARD",))

    def read_weights(self, bits=False):
        g = self.geom
        Wp = np.zeros((g.lanes, g.nwords, g.npar), dtype=np.uint64)
        Bp = np.zeros((g.lanes, g.nbwords, g.npar), dtype=np.uint64)
        for l in range(g.lanes):
            Wp[l] = np.array(self.read(g.weight_word_addr(l, 0, 0), g.nwords * g.npar), dtype=np.uint64).reshape(g.nwords, g.npar)
            Bp[l] = np.array(self.read(g.bias_word_addr(l, 0, 0), g.nbwords * g.npar), dtype=np.uint64).reshape(g.nbwords, g.npar)
        Wl, Bl = K.unpack_weights(Wp, Bp, g)
        if bits:
            return Wl, Bl
        return F.from_bits(Wl, self.W).astype(np.float32), F.from_bits(Bl, self.W).astype(np.float32)

    def write_x(self, entry, x, bits=False):
        g = self.geom
        xb = np.asarray(x, dtype=np.uint64).reshape(-1) if bits else self._bits(np.reshape(x, (-1,)))
        if len(xb) != g.pdim:
            raise ValueError(f"x must have {g.pdim} elements")
        self.write(g.xbuf_addr(entry, 0), [int(v) for v in xb])

    def read_z(self, bits=False):
        z = np.array(self.read(R.ZBUF_BASE, self.geom.width), dtype=np.uint64) & np.uint64((1 << self.W) - 1)
        return z if bits else F.from_bits(z, self.W).astype(np.float32)

    def infer(self, x, entry=0, timeout=1.0, bits=False, x_bits=False):
        self.write_x(entry, x, bits=x_bits)
        self.set_reg("XSEL", entry)
        self.set_reg("IRQ_STATUS", 1)
        self.ctrl("START")
        self._wait_irq(timeout)
        z = self.read_z(bits)
        self.set_reg("IRQ_STATUS", 1)
        return z

    def self_run(self, xs, count=0):
        g = self.geom
        if not 1 <= len(xs) <= g.nxbuf:
            raise ValueError(f"1..{g.nxbuf} input vectors")
        for e, x in enumerate(xs):
            self.write_x(e, x)
        self.set_reg("SR_N", len(xs))
        self.set_reg("SR_COUNT", count)
        self.set_reg("IRQ_STATUS", 2)
        self.ctrl("CNT_CLR", "CKSUM_CLR")
        self.ctrl("SR_START")

    def stop(self):
        self.ctrl("SR_STOP")

    def wait_sr_done(self, timeout=10.0):
        if self.pins.available:
            ok = self.pins.wait_irq(timeout)
            if ok is False:
                raise RondoError("timeout waiting for the self-run to finish")
        t0 = time.monotonic()
        while not (self.reg("IRQ_STATUS") >> 1) & 1:
            if time.monotonic() - t0 > timeout:
                raise RondoError("self-run did not finish")
        self._wait_idle(timeout)

    def bench_stats(self):
        n = self.reg("SR_DONE_CNT")
        cyc = self.reg64("SR_CYC")
        return dict(sr_done=n, sr_cycles=cyc, infer_cnt=self.reg64("INFER_CNT"), busy_cycles=self.reg64("BUSY_CYC"),
                    total_cycles=self.reg64("TOTAL_CYC"), checksum=self.reg("CHECKSUM"), sr_pass_cksum=self.reg("SR_PASS_CKSUM"),
                    guard_hits=self.reg("GUARD_HITS"), naninf=self.reg("NANINF_CNT"), last_cycles=self.reg("LAST_CYCLES"),
                    f_core=self.f_core, throughput=(n * self.f_core / cyc) if cyc else 0.0)

    def expected_checksum(self, z_per_entry, n):
        """CHECKSUM after n inferences cycling through the entries; z_per_entry[e] = W-bit patterns of entry e's output"""
        c = 0
        ne = len(z_per_entry)
        for i in range(n):
            c = K.update(c, [int(v) for v in z_per_entry[i % ne]], self.W)
        return c

    # ---- self-test, debug ------------------------------------------------------------------------------------------------------------
    def kat(self, fmt=None):
        if fmt and fmt != self.fmt:
            self.set_format(fmt)
        if self.reg("PWR_CTRL") & 3:
            raise RondoError("KAT needs PWR_CTRL.CORE_HOLD = CORE_CLK_OFF = 0")
        self.clear_errors()
        self.ctrl("KAT_START")
        self._wait_idle(60.0)
        st = self.reg("ST_STATUS")
        ok = bool((st >> 2) & 1) and "KAT_FAIL" not in self.errors()
        return ok

    def bist_at_reset(self):
        ok = self.pins.run_bist(self)
        self.reset_check()
        return ok

    def mbist(self):
        if "MBIST" not in self.caps:
            raise RondoError("MBIST not built")
        self.ctrl("MBIST_START")
        self._wait_idle(60.0)
        st = self.reg("MBIST_STATUS")
        return dict(fail=bool((st >> 2) & 1), lane=(st >> 4) & 7, half=(st >> 7) & 1, bias=(st >> 8) & 1,
                    element=(st >> 9) & 15, count=st >> 16, addr=self.reg("MBIST_FAIL_ADDR"), xor=self.reg("MBIST_FAIL_XOR"))

    def debug(self, lane, sig, idx, live=0):
        self.set_reg("DBG_SEL", lane | (sig << 4) | (idx << 8) | (live << 16))
        self.ctrl("DBG_LATCH")
        self.reg("CHIP_ID")                        # DBG_DATA is latched 4 cycles after DBG_SEL / DBG_LATCH
        return self.reg("DBG_DATA")

    def trace(self, cfg, timeout=2.0, ns=None):
        """cfg = TRC_CFG value; arms, waits for completion (TRC_STATUS.DONE), returns [(ts, flags, tag, data)]"""
        self.set_reg("TRC_CFG", cfg)
        self.ctrl("TRC_ARM")
        t0 = time.monotonic()
        while not (self.reg("TRC_STATUS") >> 2) & 1:
            if time.monotonic() - t0 > timeout:
                raise RondoError("trace did not complete")
        st = self.reg("TRC_STATUS")
        nvalid = (st >> 8) & 255
        out = []
        for k in range(nvalid if ns is None else min(ns, nvalid)):
            d, m = self.read(R.TRACE_BASE + 2 * k, 2)
            out.append((m >> 16, (m >> 8) & 255, m & 255, d))
        return out

    # ---- stage isolation (spec 2.6, 9.10) -----------------------------------------------------------------------------------------------
    def _zero_weights(self):
        g = self.geom
        z = [0] * (g.nwords * g.npar)
        for l in range(g.lanes):
            self.write(g.weight_word_addr(l, 0, 0), z)

    def inject_coeffs(self, a_by_ladder):
        """W = 0, B = a, x = 0 for every ladder: a_by_ladder (width, depth) floats (rows beyond the given ones are 0).
        The weights are overwritten: save them with read_weights() first and restore afterwards."""
        g = self.geom
        a = np.zeros((g.width, g.depth), dtype=np.float32)
        arr = np.asarray(a_by_ladder, dtype=np.float32).reshape(-1, g.depth)
        a[:len(arr)] = arr
        Wb = np.zeros((g.width, g.depth, g.pdim), dtype=np.uint64)
        Bb = self._bits(a)
        Wp, Bp = K.pack_weights(Wb, Bb, g)
        for l in range(g.lanes):
            self.write(g.weight_word_addr(l, 0, 0), [int(v) for v in Wp[l].reshape(-1)])
            self.write(g.bias_word_addr(l, 0, 0), [int(v) for v in Bp[l].reshape(-1)])
        self.write_x(0, np.zeros(g.pdim, dtype=np.float32))
        self.set_reg("XSEL", 0)
        self.ctrl("START")
        self._wait_idle(5.0)

    def recip_probe(self, beta_list):
        """z = 1/beta (or sign/eps with a guard hit) from the real reciprocal, one beta per ladder."""
        g = self.geom
        betas = list(beta_list)
        if len(betas) > g.width:
            raise ValueError(f"at most {g.width} divisors per probe")
        a = np.zeros((g.width, g.depth), dtype=np.float32)
        a[:len(betas), g.depth - 1] = betas
        a[len(betas):, g.depth - 1] = 1.0
        self.inject_coeffs(a)
        return [float(v) for v in self.read_z()[:len(betas)]]


    # ---- input tiling: layers wider than PDIM (spec 18.7) ------------------------------------------------------------------------
    def tile_plan(self, L, p, N, batch=None, depth=7):
        """groups / slices / weight loads and the estimated SPI time of run_wide_layer (no chip access)."""
        g = self.geom
        S = -(-p // g.pdim)
        G = -(-L // g.width)
        tb = max(g.tile_b, 1)
        batch = batch or min(N, tb)
        swap = batch > tb
        chunks = -(-N // batch)
        subs = -(-batch // tb) if swap else 1
        loads = G * S * (chunks if swap else -(-N // tb))
        words_slice = g.lanes * g.nwords * g.npar
        bytes_load = 4 * (words_slice + 6 * g.lanes)
        bytes_ps = 4 * g.lanes * g.nbwords * g.npar * 2 * (S - 1) * min(N, batch) * G * chunks if swap else 0
        bytes_tx = 4 * g.pdim * S * N * G
        total = loads * bytes_load + bytes_ps + bytes_tx + 4 * g.lanes * g.nbwords * g.npar * G
        sclk = self.sclk_hz if hasattr(self, "sclk_hz") else 5e6
        return dict(groups=G, slices=S, loads=loads, host_swap=swap, sub_batches=subs, spi_bytes=total,
                    est_seconds=total * 8.0 / sclk, sclk_hz=sclk)

    def run_wide_layer(self, Wden, bden, X, fmt="fp32", batch=None, depth=7, bf16_max_p=80, allow_bf16_wide=False,
                       verify="crc", progress=None):
        """Wden (L*depth, p), bden (L*depth,), X (N, p) -> Z (N, L) float32 on the tiled chip (spec 18.7).
        Ladders run in groups of `width`; the p inputs in slices of PDIM (weights padded with -0, inputs with +0).
        batch=None: sub-batches of at most TILE_B inputs; batch > TILE_B: HOST_SLICE with the PS window swapped over SPI."""
        g = self.geom
        Wden = np.asarray(Wden, dtype=np.float32)
        bden = np.asarray(bden, dtype=np.float32)
        X = np.asarray(X, dtype=np.float32)
        p = Wden.shape[1]
        N = X.shape[0]
        L = Wden.shape[0] // depth
        if depth != g.depth or X.shape[1] != p or Wden.shape[0] != L * depth:
            raise ValueError("shape mismatch (depth must equal the chip's DEPTH; X is (N, p))")
        if fmt == "bf16" and p > g.pdim:
            if p > bf16_max_p and not allow_bf16_wide:
                raise RondoError(f"bf16 refused for p={p} > bf16_max_p={bf16_max_p}: tiling fixes width, not accuracy "
                                 "(use fp32 or allow_bf16_wide=True)")
        S = -(-p // g.pdim)
        P = S * g.pdim
        tb = max(g.tile_b, 1)
        if g.tile_b < 1:
            raise RondoError("TILE_B = 0 chip: only KEEP mode (not supported by run_wide_layer)")
        if self.fmt != fmt:
            self.set_format(fmt)
        w = self.W
        negz = 0x8000 if w == 16 else 0x80000000
        Wb = F.to_bits(Wden, w).astype(np.uint64).reshape(L, depth, p)
        Bb = F.to_bits(bden, w).astype(np.uint64).reshape(L, depth)
        Xb = F.to_bits(X, w).astype(np.uint64)
        Wb = np.concatenate([Wb, np.full((L, depth, P - p), negz, dtype=np.uint64)], axis=2)
        Xb = np.concatenate([Xb, np.zeros((N, P - p), dtype=np.uint64)], axis=1)
        G = -(-L // g.width)
        batch = batch or min(N, tb)
        swap = batch > tb
        plan = self.tile_plan(L, p, N, batch if swap else None, depth)
        done_loads = 0
        lane_all = (1 << g.lanes) - 1
        Z = np.zeros((N, L), dtype=np.uint64)
        self.set_reg("IRQ_STATUS", 0x7F)
        for gi in range(G):
            lo, hi = gi * g.width, min(L, (gi + 1) * g.width)
            n = hi - lo
            Wg = np.full((g.width, depth, P), negz, dtype=np.uint64)
            Bg = np.zeros((g.width, depth), dtype=np.uint64)
            Wg[:n], Bg[:n] = Wb[lo:hi], Bb[lo:hi]
            lanes_used = -(-n // g.nlad)
            self.set_reg("LANE_EN", (1 << lanes_used) - 1 if lanes_used < g.lanes else lane_all)

            def load(s):
                nonlocal done_loads
                self.load_weights_bits(Wg[:, :, s * g.pdim:(s + 1) * g.pdim], Bg, verify, with_bias=(s == 0))
                crc = self.last_load_crc if verify == "crc" else self.reg("LOAD_CRC")
                done_loads += 1
                if progress:
                    progress(done_loads, plan["loads"])
                return self.reg("LOAD_CRC") if verify != "crc" else crc

            def run(crcs):
                self.set_reg("IRQ_STATUS", 0x60)
                self.ctrl("TILE_RUN")
                self._wait_irq(30.0)
                self.set_reg("IRQ_STATUS", 0x60)
                self.check_errors(allow=("GUARD", "NAN_INF"))

            def tx(b, x, s):
                self.write(g.tx_addr(b, 0), [int(v) for v in x[s * g.pdim:(s + 1) * g.pdim]])

            def tz(nb):
                return [self.read(g.tz_addr(b, 0), g.width) for b in range(nb)]

            if not swap:
                for c0 in range(0, N, tb):
                    idx = list(range(c0, min(N, c0 + tb)))
                    self.set_reg("TILE_CFG", 1 | (S << 8) | (len(idx) << 16))
                    crcs = []
                    for s in range(S):
                        crcs.append(load(s))
                        for b, i in enumerate(idx):
                            tx(b, Xb[i], s)
                        run(crcs)
                    want = 0
                    for c in crcs:
                        want = K.crc32_chain(want, c)
                    if self.reg("TILE_SEQ_CRC") != want:
                        raise RondoError("TILE_SEQ_CRC mismatch")
                    zz = tz(len(idx))                       # one TZ read per input of the sub-batch
                    for b, i in enumerate(idx):
                        Z[i, lo:hi] = np.array(zz[b][:n], dtype=np.uint64)
            else:
                for c0 in range(0, N, batch):
                    idx = list(range(c0, min(N, c0 + batch)))
                    subs = [(idx[k:k + tb] + [None] * tb)[:tb] for k in range(0, len(idx), tb)]
                    self.set_reg("TILE_CFG", 1 | (S << 8) | (tb << 16) | (1 << 25))
                    saved = {}
                    nel = g.nbwords * g.npar
                    for s in range(S):
                        load(s)
                        for si, sub in enumerate(subs):
                            if s > 0:
                                self.set_reg("TILE_SLICE", s)
                                for b in range(len(sub)):
                                    for l in range(g.lanes):
                                        self.write(g.ps_addr(b, l, 0, 0), saved[(si, b, l)])
                            for b, i in enumerate(sub):
                                tx(b, Xb[i] if i is not None else np.zeros(P, dtype=np.uint64), s)
                            run(None)
                            if s < S - 1:
                                for b in range(len(sub)):
                                    for l in range(g.lanes):
                                        saved[(si, b, l)] = self.read(g.ps_addr(b, l, 0, 0), nel)
                            else:
                                zz = tz(len(sub))
                                for b, i in enumerate(sub):
                                    if i is not None:
                                        Z[i, lo:hi] = np.array(zz[b][:n], dtype=np.uint64)
                    self.ctrl("TILE_ABORT")
        self.set_reg("LANE_EN", lane_all)
        return F.from_bits(Z & np.uint64((1 << w) - 1), w).astype(np.float32)
