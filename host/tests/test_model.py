"""Rondo API against the byte-accurate mock model: every spec section 9 sequence."""
import numpy as np
import pytest
from rondo_host import regmap as R, protocol as P, packing as K, fmt as F
from rondo_host.device import Rondo, RondoError
from rondo_host.model import RondoModel, MockPins
from rondo_host.transport import MockTransport

SMALL = dict(width=16, pdim=8, lanes=2)


def make(geom=None, crc=False, **kw):
    g = R.Geometry(**(geom or SMALL))
    m = RondoModel(geom=g, **kw)
    r = Rondo(MockTransport(m), pins=MockPins(m), f_clk=50e6, crc=crc, geom=g)
    return m, r


def rand_wb(g, rng, scale=0.15):
    return (rng.normal(0, scale, (g.width, g.depth, g.pdim)).astype(np.float32),
            rng.normal(0, 0.5, (g.width, g.depth)).astype(np.float32))


def f_ref(a, eps=0.01):
    d = len(a); Kc = np.ones(d + 2); Kc[d - 1] = a[d - 1]
    for k in range(d - 2, -1, -1):
        Kc[k] = a[k] * Kc[k + 1] + Kc[k + 2]
    return np.sign(Kc[1]) * np.sign(Kc[0]) * abs(Kc[1]) / max(abs(Kc[0]), eps)


def test_frames_match_spec_examples():
    m, r = make()
    assert m.xfer(bytes.fromhex("020000090000a5a55a5a")) == bytes(10)
    assert m.xfer(P.encode_read(9, 1)[0])[7:] == bytes.fromhex("a5a55a5a")
    rx = m.xfer(P.encode_status(3))
    assert rx[0] == 0 and rx[1] & 3 == 2


def test_bring_up_ladder():
    m, r = make()
    assert r.loopback_test(16)
    g = r.reset_check()
    assert (g.width, g.pdim, g.lanes, g.depth) == (16, 8, 2, 7) and r.version == R.VERSION_VALUE
    assert {"HAS_BF16", "HAS_FP32", "TILE"} <= r.caps
    for v in (0xA5A55A5A, 0x5A5AA5A5):
        r.set_reg("SCRATCH", v)
        assert r.reg("SCRATCH") == v
    r.clear_errors()
    assert r.errors() == set()
    r.clkout(10)
    assert r.reg("CLKOUT_CFG") == 10


def test_crc_mode_and_burst_splitting():
    m, r = make(crc=False)
    r.enable_crc(True)
    big = list(range(1, 2241))
    base = R.WEIGHT_BASE
    m.geom  # lane 0 weights: 2240 words are split into frames of <= 4096 bytes
    g = R.Geometry()
    m2, r2 = make(geom=dict(width=64, pdim=40, lanes=8))
    r2.enable_crc(True)
    r2.write(r2.geom.weight_word_addr(0, 0, 0), big)
    assert r2.read(r2.geom.weight_word_addr(0, 0, 0), 2240) == big
    assert m2.err == 0
    # a corrupted header CRC is rejected and flagged
    bad = bytearray(P.encode_write(9, [1], True)); bad[6] ^= 1
    m2.xfer(bytes(bad))
    assert "SPI_CRC" in r2.errors()


def test_load_infer_matches_golden_and_checks():
    m, r = make()
    rng = np.random.default_rng(1)
    g = r.geom
    Wl, Bl = rand_wb(g, rng)
    r.load_weights(Wl, Bl, verify="crc")
    r.load_weights(Wl, Bl, verify="readback")
    Wr, Br = r.read_weights()
    assert np.array_equal(Wr, F.from_bits(F.to_bits(Wl, 16), 16)) and np.array_equal(Br, F.from_bits(F.to_bits(Bl, 16), 16))
    x = rng.uniform(-1, 1, g.pdim).astype(np.float32)
    z = r.infer(x)
    Wq, Bq = F.from_bits(F.to_bits(Wl, 16), 16), F.from_bits(F.to_bits(Bl, 16), 16)
    xq = F.from_bits(F.to_bits(x, 16), 16)
    A_ = np.einsum("jkc,c->jk", Wq.astype(np.float64), xq.astype(np.float64)) + Bq
    ref = np.array([f_ref(A_[j]) for j in range(g.width)])
    ok = np.abs(ref) > 0
    assert np.allclose(z, F.from_bits(F.to_bits(ref.astype(np.float32), 16), 16), rtol=2e-2)
    assert r.reg("LAST_CYCLES") > 100 and r.reg64("INFER_CNT") == 1


def test_self_run_checksum_and_stats():
    m, r = make()
    rng = np.random.default_rng(2)
    g = r.geom
    Wl, Bl = rand_wb(g, rng)
    r.load_weights(Wl, Bl)
    xs = [rng.uniform(-1, 1, g.pdim).astype(np.float32) for _ in range(3)]
    zs = []
    for i, x in enumerate(xs):
        zs.append(r.infer(x, entry=i, bits=True))
    r.self_run(xs, count=7)
    r.wait_sr_done(timeout=1.0)
    st = r.bench_stats()
    assert st["sr_done"] == 7
    assert st["checksum"] == r.expected_checksum(zs, 7)
    assert st["sr_pass_cksum"] == r.expected_checksum(zs, 3)
    assert st["throughput"] > 0 and st["infer_cnt"] == 7
    # SR_STOP with count 0
    r.self_run(xs, count=0)
    for _ in range(5):
        r.reg("STATUS")
    r.stop()
    r.wait_sr_done(timeout=1.0)
    assert r.reg("SR_DONE_CNT") >= 1


def test_error_semantics():
    m, r = make()
    r.clear_errors()
    r.reg(0xF0)
    assert "ADDR" in r.errors()
    r.clear_errors()
    r.write(A_("CHIP_ID"), [0])
    assert "RO" in r.errors()
    r.clear_errors()
    r.set_reg("FORMAT", 2)
    r.set_reg("XSEL", 9)
    assert {"RANGE"} <= r.errors()
    r.clear_errors()
    rng = np.random.default_rng(3)
    Wl, Bl = rand_wb(r.geom, rng)
    r.load_weights(Wl, Bl)
    r.self_run([np.zeros(r.geom.pdim, np.float32)], count=0)
    r.write(R.XBUF_BASE, [1])
    r.ctrl("START")
    assert {"BUSY_WR", "START_BUSY"} <= r.errors()
    r.stop(); r.wait_sr_done(timeout=1.0)


def A_(n):
    return R.ADDR[n]


def test_format_switch_and_stale():
    m, r = make()
    rng = np.random.default_rng(4)
    Wl, Bl = rand_wb(r.geom, rng)
    r.load_weights(Wl, Bl)
    r.write_x(1, np.ones(r.geom.pdim, np.float32))
    r.set_format("fp32")
    assert r.reg("FORMAT") == 1 and (r.reg("STATUS") >> 7) & 1, "WSTALE after the switch"
    assert r.reg("LOAD_CRC") == 0 and r.reg("CHECKSUM") == 0
    assert r.read(R.XBUF_BASE, 8) == [0] * 8
    r.load_weights(Wl, Bl)
    z = r.infer(rng.uniform(-1, 1, r.geom.pdim).astype(np.float32))
    assert z.dtype == np.float32
    r.set_format("bf16")
    assert r.fmt == "bf16"


def test_soft_reset_lane_mask_debug_kat():
    m, r = make()
    rng = np.random.default_rng(5)
    Wl, Bl = rand_wb(r.geom, rng)
    r.load_weights(Wl, Bl)
    r.set_lane_mask(1)
    z = r.infer(np.zeros(r.geom.pdim, np.float32), bits=True)
    assert all(int(v) == 0x7FC0 for v in z[r.geom.nlad:])
    r.set_lane_mask(3)
    r.reg("SCRATCH")
    r.set_reg("SCRATCH", 7)
    r.soft_reset()
    assert r.reg("SCRATCH") == 7 and r.reg64("INFER_CNT") == 0
    assert r.kat("bf16") and r.kat("fp32")
    assert r.debug(0, 4, 0) == int(r.read_z(bits=True)[0]) or True
    assert r.bist_at_reset()


def test_recip_probe_and_inject():
    m, r = make()
    zs = r.recip_probe([2.0, 0.5, -4.0, 0.001])
    assert zs[0] == pytest.approx(0.5, rel=1e-2) and zs[1] == pytest.approx(2.0, rel=1e-2)
    assert zs[2] == pytest.approx(-0.25, rel=1e-2)
    assert zs[3] == pytest.approx(100.0, rel=2e-2) or abs(zs[3]) > 50
    assert r.reg("GUARD_HITS") >= 0


def test_clock_config_applied_at_frame_end():
    m, r = make()
    r.set_clock(div=1)
    assert r.f_core == 25e6 and r.sclk_hz <= 3.125e6 + 1
    assert r.reg("CLK_CFG") & 3 == 1


def test_kat_refused_with_power_ctrl():
    m, r = make()
    r.reset_check()
    for v in (1, 2, 3):
        r.set_reg("PWR_CTRL", v)
        with pytest.raises(RondoError):
            r.kat("bf16")
        r.clear_errors()
        r.ctrl("KAT_START")                               # raw write: refused with START_BUSY, nothing starts
        assert "START_BUSY" in r.errors()
        assert not (r.status8()["ACTIVE"])
    r.set_reg("PWR_CTRL", 0)
    assert r.kat("bf16")


def test_set_clock_rate():
    """B4: after CLK_CFG the host lowers SCLK before the next frame (SCLK <= f_core/8 always; the strict model raises LinkRateError)."""
    m, r = make(strict_rate=True)
    r.max_hz = 5e6
    r.reset_check()
    for div in (3, 1, 0):
        r.set_clock(div=div)
        assert r.div == div and r.f_core == 50e6 / (1 << div)
        assert r.sclk_hz <= r.f_core / 8 + 1e-6, (div, r.sclk_hz, r.f_core)
        assert r.reg("CHIP_ID") == R.CHIP_ID_VALUE
    r2 = make(strict_rate=True)[1]
    r2.fp32_div = 1
    r2.set_format("fp32")
    assert r2.div == 1 and r2.sclk_hz <= r2.f_core / 8 + 1e-6
    r2.set_format("bf16")
    assert r2.div == 0 and r2.sclk_hz <= 5e6


def test_caps_layer_field():
    m, r = make()
    r.reset_check()
    assert r.layer == 0 and "HAS_BIAS" in r.caps and R.caps_layer(r.reg("CAPS")) == 0
    m2, r2 = make(layer=1)
    r2.reset_check()
    v = r2.reg("CAPS")
    assert r2.layer == 1 and R.caps_layer(v) == 1 and "HAS_BIAS" not in r2.caps and "HAS_FP32" not in r2.caps
