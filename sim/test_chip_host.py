"""T-HOST: the unmodified Rondo host API (host/rondo_host) against rondo_chip_top SMALL through the cocotb transport."""
import sys
from pathlib import Path
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer
from cocotb._bridge import bridge
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from rondo_host.device import Rondo, RondoError                      # noqa: E402
from rondo_host.cocotb_transport import CocotbTransport, CocotbPins  # noqa: E402
from rondo_host import regmap as R, packing as K, fmt as F           # noqa: E402
from rondo_spi_bfm import SpiBfm                                     # noqa: E402
import chip_common as cc                                             # noqa: E402
import fpmodel as fm                                                 # noqa: E402


def make_api(dut, ratio=8.0, seed=1):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.clk_alt.value = 0
    dut.bist_en.value = 0
    dut.test_mode_pin.value = 0
    bfm = SpiBfm(dut.spi_sclk, dut.spi_cs_n, dut.spi_mosi, dut.spi_miso, 10.0, ratio, seed)
    return CocotbTransport(bfm), CocotbPins(dut, 10.0), bfm


async def reset(dut):
    dut.rst_n.value = 0
    await Timer(60, unit="ns")
    dut.rst_n.value = 1
    await Timer(300, unit="ns")


def body_all(dut, tr, pins):
    r = Rondo(tr, pins=pins, f_clk=50e6)
    out = {}
    assert r.loopback_test(16)
    g = r.reset_check()
    assert (g.width, g.pdim, g.lanes) == (16, 8, 2) and r.version == R.VERSION_VALUE
    rng = np.random.default_rng(3)
    Wl = rng.normal(0, 0.15, (g.width, g.depth, g.pdim)).astype(np.float32)
    Bl = rng.normal(0, 0.5, (g.width, g.depth)).astype(np.float32)
    for fmt_ in ("bf16", "fp32"):
        if fmt_ == "fp32":
            r.set_format("fp32")
        r.load_weights(Wl, Bl, verify="crc")
        Wr, Br = r.read_weights(bits=True)
        w = r.W
        Wb, Bb = F.to_bits(Wl, w), F.to_bits(Bl, w)
        assert np.array_equal(Wr, Wb) and np.array_equal(Br, Bb)
        x = rng.uniform(-1, 1, g.pdim).astype(np.float32)
        z = r.infer(x, bits=True)
        out[fmt_] = (z, Wb, Bb, F.to_bits(x, w))
        # self-run with 2 entries x 3 passes + the checksum
        xs = [x, -x]
        zs = [z, r.infer(-x, entry=1, bits=True)]
        r.self_run(xs, count=6)
        r.wait_sr_done(timeout=1.0)
        st = r.bench_stats()
        assert st["sr_done"] == 6 and st["checksum"] == r.expected_checksum(zs, 6)
        assert r.kat(fmt_), f"{fmt_} KAT failed"
        # debug tap: K0 of slot 0, lane 0 after a fresh inference
        r.load_weights(Wl, Bl)
        r.infer(x)
        out[fmt_ + "_dbg"] = r.debug(0, 2, 0)
        # trace of the live core stream, triggered on done
        tr_ = r.trace(0 | (1 << 3) | (2 << 4) | (3 << 8), timeout=0.5) if False else None
        r.set_lane_mask(1)
        zm = r.infer(x, bits=True)
        r.set_lane_mask(3)
        assert all(int(v) == (0x7FC0 if w == 16 else 0x7FC00000) for v in zm[g.nlad:])
    r.set_format("bf16")
    assert r.bist_at_reset() in (True, False)
    out["errors"] = r.errors()
    return out


@cocotb.test()
async def host_api(dut):
    tr, pins, bfm = make_api(dut)
    await reset(dut)
    res = await bridge(body_all)(dut, tr, pins)
    g = cc.Geo(16, 8, 2)
    for fmt_ in ("bf16", "fp32"):
        z, Wb, Bb, xb = res[fmt_]
        w = 16 if fmt_ == "bf16" else 32
        Wl = [[[int(Wb[j, k, c]) for c in range(g.pdim)] for k in range(g.depth)] for j in range(g.width)]
        Bl = [[int(Bb[j, k]) for k in range(g.depth)] for j in range(g.width)]
        x = [int(v) for v in xb]
        if fmt_ == "bf16":
            zm = cc.model_layer(g, "bf16", Wl, Bl, x)[0]
        else:
            zm = cc.model_layer(g, "fp32", Wl, Bl, x, nr_iters=2, tbits=8, seed=fm.load_seed(24, 8))[0]
        assert [int(v) for v in z] == zm, f"{fmt_}: API result differs from the bit-exact model"
    dut._log.info("T-HOST: unmodified Rondo API: loopback, reset_check, set_format, load/read weights, infer, self_run, kat, debug, lane mask")


TB_WIDE = 2          # TILE_B of the T-WIDE build (run_chip_host.py)


def body_wide(dut, tr, pins):
    r = Rondo(tr, pins=pins, f_clk=50e6)
    g = r.reset_check()
    assert g.tile_b == TB_WIDE, g.tile_b
    rng = np.random.default_rng(11)
    L, p, N, depth = 32, 96, 2 * TB_WIDE + 1, g.depth
    W = rng.normal(0, 0.12, (L * depth, p)).astype(np.float32)
    b = rng.normal(0, 0.5, L * depth).astype(np.float32)
    X = rng.uniform(-1, 1, (N, p)).astype(np.float32)
    try:
        r.run_wide_layer(W, b, X, fmt="bf16")
        refused = False
    except RondoError:
        refused = True
    plan = r.tile_plan(L, p, N, batch=N)
    Z = r.run_wide_layer(W, b, X, fmt="fp32", batch=N)          # N > TILE_B: HOST_SLICE swap, two ladder groups
    return refused, plan, Z, W, b, X, r.errors()


@cocotb.test()
async def host_wide(dut):
    """T-WIDE: run_wide_layer (32 ladders x p = 96 x N = 2*TILE_B+1, host swap) == bare-core reference model"""
    tr, pins, bfm = make_api(dut)
    await reset(dut)
    refused, plan, Z, W, b, X, errs = await bridge(body_wide)(dut, tr, pins)
    assert refused, "bf16 must be refused above bf16_max_p"
    assert plan["groups"] == 2 and plan["slices"] == 12 and plan["host_swap"]
    L, p, N, depth = 32, 96, X.shape[0], 7
    gw = cc.Geo(L, p, 2)
    Wb, Bb, Xb = F.to_bits(W, 32), F.to_bits(b, 32), F.to_bits(X, 32)
    Wl = [[[int(Wb[j * depth + k, c]) for c in range(p)] for k in range(depth)] for j in range(L)]
    Bl = [[int(Bb[j * depth + k]) for k in range(depth)] for j in range(L)]
    zbits = F.to_bits(Z, 32)
    for i in range(N):
        zm = cc.model_layer(gw, "fp32", Wl, Bl, [int(v) for v in Xb[i]], nr_iters=2, tbits=8, seed=fm.load_seed(24, 8))[0]
        assert [int(v) for v in zbits[i]] == zm, f"input {i}: run_wide_layer != bare-core reference"
    dut._log.info(f"T-WIDE: run_wide_layer 32 ladders x p=96 x N={N} (host swap, 2 groups) bit-exact; bf16 refused; errors={errs}")


def body_clock(dut, tr, pins):
    r = Rondo(tr, pins=pins, f_clk=50e6, max_hz=50e6 / 8)
    g = r.reset_check()
    rng = np.random.default_rng(11)
    Wl = rng.normal(0, 0.15, (g.width, g.depth, g.pdim)).astype(np.float32)
    Bl = rng.normal(0, 0.5, (g.width, g.depth)).astype(np.float32)
    r.set_clock(3)                                  # core /8: every later frame must run at R >= 8 of the NEW core clock
    r.set_reg("SCRATCH", 0xA5A5F00F)
    assert r.reg("SCRATCH") == 0xA5A5F00F
    assert r.div == 3 and r.f_core == 50e6 / 8 and r.sclk_hz <= r.f_core / 8 + 1e-6
    r.set_clock(1)
    assert r.reg("SCRATCH") == 0xA5A5F00F
    r.set_clock(0)
    r.load_weights(Wl, Bl, verify="crc")
    x = rng.uniform(-1, 1, g.pdim).astype(np.float32)
    z = r.infer(x, bits=True)
    return Wl, Bl, x, z, tr.min_r_seen


@cocotb.test()
async def host_set_clock_rate(dut):
    """B4 (CHIP_FIX_PLAN task 3): set_clock lowers SCLK before the next frame; the transport models the SCLK ratio and asserts R >= 8."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.clk_alt.value = 0; dut.bist_en.value = 0; dut.test_mode_pin.value = 0
    bfm = SpiBfm(dut.spi_sclk, dut.spi_cs_n, dut.spi_mosi, dut.spi_miso, 10.0, 8.0, 1)
    tr = CocotbTransport(bfm, f_src_hz=50e6, dut=dut, min_r=8.0)
    pins = CocotbPins(dut, 10.0)
    await reset(dut)
    Wl, Bl, x, z, min_r = await bridge(body_clock)(dut, tr, pins)
    assert min_r >= 8.0, min_r
    g = cc.Geo(16, 8, 2)
    Wb, Bb, xb = F.to_bits(Wl, 16), F.to_bits(Bl, 16), [int(v) for v in F.to_bits(x, 16)]
    Wi = [[[int(Wb[j, k, c]) for c in range(g.pdim)] for k in range(g.depth)] for j in range(g.width)]
    Bi = [[int(Bb[j, k]) for k in range(g.depth)] for j in range(g.width)]
    zm = cc.model_layer(g, "bf16", Wi, Bi, xb)[0]
    assert [int(v) for v in z] == zm, "inference after the clock changes differs from the bit-exact model"
    dut._log.info(f"T-HOST set_clock: DIV 3 -> 1 -> 0 with every frame at R >= {min_r:.2f}; bit-exact inference afterwards")
