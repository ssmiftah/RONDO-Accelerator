"""Input tiling through the Rondo API against the mock model (spec 18): run_wide_layer, tile_plan, bf16 guard, rules."""
import numpy as np
import pytest
from rondo_host import regmap as R, fmt as F
from rondo_host.device import Rondo, RondoError
from rondo_host.model import RondoModel, MockPins
from rondo_host.transport import MockTransport

G = dict(width=16, pdim=8, lanes=2, tile_b=3)


def make(**kw):
    g = R.Geometry(**G)
    m = RondoModel(geom=g, tile_b=3, **kw)
    return m, Rondo(MockTransport(m), pins=MockPins(m), f_clk=50e6, geom=g)


def golden(Wden, bden, X, depth=7):
    L = Wden.shape[0] // depth
    a = X.astype(np.float64) @ Wden.astype(np.float64).T + bden
    out = np.zeros((len(X), L))
    for i in range(len(X)):
        for j in range(L):
            aj = a[i, j * depth:(j + 1) * depth]
            Kc = np.ones(depth + 2); Kc[depth - 1] = aj[-1]
            for k in range(depth - 2, -1, -1):
                Kc[k] = aj[k] * Kc[k + 1] + Kc[k + 2]
            out[i, j] = np.sign(Kc[1]) * np.sign(Kc[0]) * abs(Kc[1]) / max(abs(Kc[0]), 0.01)
    return out


def data(rng, L, p, N, depth=7):
    return (rng.normal(0, 0.15, (L * depth, p)).astype(np.float32), rng.normal(0, 0.5, L * depth).astype(np.float32),
            rng.normal(0, 1, (N, p)).astype(np.float32))


@pytest.mark.parametrize("L,p,N,batch", [(16, 24, 3, None), (32, 20, 7, None), (32, 24, 9, 9), (20, 17, 4, 6)])
def test_run_wide_layer_matches_golden(L, p, N, batch):
    rng = np.random.default_rng(L * 100 + p)
    W, b, X = data(rng, L, p, N)
    m, r = make()
    Z = r.run_wide_layer(W, b, X, fmt="fp32", batch=batch)
    ref = golden(W, b, X)
    ok = np.isfinite(ref)
    assert Z.shape == (N, L)
    np.testing.assert_allclose(Z[ok], ref[ok], rtol=2e-3, atol=1e-5)


def test_swap_equals_noswap():
    rng = np.random.default_rng(5)
    W, b, X = data(rng, 16, 24, 9)
    _, r1 = make(); _, r2 = make()
    # the model keeps partial sums in float64; a host swap rounds them to the element format (the chip is exact)
    np.testing.assert_allclose(r1.run_wide_layer(W, b, X, batch=None), r2.run_wide_layer(W, b, X, batch=9), rtol=1e-5)


def test_bf16_guard():
    rng = np.random.default_rng(6)
    W, b, X = data(rng, 16, 96, 2)
    m, r = make()
    with pytest.raises(RondoError):
        r.run_wide_layer(W, b, X, fmt="bf16")
    Z = r.run_wide_layer(W, b, X, fmt="bf16", allow_bf16_wide=True)
    assert Z.shape == (2, 16)
    W2, b2, X2 = data(rng, 16, 24, 2)
    r.run_wide_layer(W2, b2, X2, fmt="bf16")            # p = 24 <= bf16_max_p = 80


def test_tile_plan():
    m, r = make()
    pl = r.tile_plan(32, 24, 9)
    assert pl["groups"] == 2 and pl["slices"] == 3 and not pl["host_swap"] and pl["loads"] == 2 * 3 * 3
    pl2 = r.tile_plan(32, 24, 9, batch=9)
    assert pl2["host_swap"] and pl2["loads"] == 2 * 3 and pl2["est_seconds"] > 0


def test_sequence_rules():
    m, r = make()
    r.set_reg("TILE_CFG", 1 | (3 << 8) | (2 << 16))
    r.clear_errors()
    r.ctrl("START")
    assert "TILE_SEQ" in r.errors()
    r.clear_errors()
    r.set_reg("TILE_CFG", 0)
    r.ctrl("TILE_RUN")
    assert "TILE_SEQ" in r.errors()
    r.clear_errors()
    r.set_reg("TILE_CFG", 1 | (3 << 8) | (4 << 16))     # TBATCH > TILE_B
    assert "RANGE" in r.errors()
    r.clear_errors()
    r.set_reg("TILE_CFG", 1 | (3 << 8) | (2 << 16))
    r.set_reg("TILE_SLICE", 1)                           # not HOST_SLICE
    assert "TILE_SEQ" in r.errors()
    r.clear_errors()
    r.ctrl("TILE_RUN")                                   # opens, slice 0
    r.set_reg("IRQ_STATUS", 0x7F)
    st = r.reg("TILE_STATUS")
    assert st & 1
    r.clear_errors()
    r.ctrl("START")
    assert "TILE_SEQ" in r.errors()
    r.clear_errors()
    r.ctrl("SOFT_RST")
    assert r.reg("TILE_STATUS") & 1 == 0 and "TILE_STALE" in r.errors()


def test_power_hold_refused_while_open():
    m, r = make()
    r.reset_check()
    r.set_reg("TILE_CFG", 1 | (3 << 8) | (2 << 16))
    r.ctrl("TILE_RUN")                                   # opens the sequence (slice 0)
    r._wait_idle()
    assert r.reg("TILE_STATUS") & 1
    with pytest.raises(RondoError):
        r.power_hold(True)
    assert r.reg("PWR_CTRL") == 0
    # a raw write is rejected by the model with TILE_SEQ
    r.clear_errors()
    r.set_reg("PWR_CTRL", 1)
    assert "TILE_SEQ" in r.errors() and r.reg("PWR_CTRL") == 0
    r.ctrl("TILE_ABORT")
    r.power_hold(True)
    assert r.reg("PWR_CTRL") == 3
    r.power_hold(False)


def test_wide_layer_tz_reads_once():
    """run_wide_layer reads TZ once per input of a sub-batch (not TBATCH times per sub-batch)."""
    from rondo_host import protocol as P

    class Counting(MockTransport):
        def __init__(self, model):
            super().__init__(model)
            self.tz_frames = 0

        def xfer(self, tx):
            tx = bytes(tx)
            if tx[0] == P.OP_READ and 0x050000 <= int.from_bytes(tx[1:4], "big") <= 0x05FFFF:
                self.tz_frames += 1
            return super().xfer(tx)

    g = R.Geometry(**G)
    m = RondoModel(geom=g, tile_b=3)
    tr = Counting(m)
    r = Rondo(tr, pins=MockPins(m), f_clk=50e6, geom=g)
    rng = np.random.default_rng(12)
    L, p, N = 16, 24, 7                                   # one group, 3 slices, sub-batches of 3, 3, 1 inputs
    W, b, X = data(rng, L, p, N)
    Z = r.run_wide_layer(W, b, X, fmt="fp32", batch=None)
    assert Z.shape == (N, L)
    per_input = len(P.split_burst(0x050000, g.width, P.OP_READ, r.crc))
    assert tr.tz_frames == N * per_input, f"TZ read frames: {tr.tz_frames}, expected {N * per_input} (one read burst per input)"


def test_mem_test_mock():
    """Rondo.mem_test: clean run reports nothing; a stuck PS bit and a stuck TX bit are reported with the right location."""
    from rondo_host.model import RondoModel as RM
    m, r = make()
    r.reset_check()
    g = r.geom
    assert r.mem_test() == []
    for fmt in ("fp32",):
        r.set_format(fmt)
        assert r.mem_test() == []

    class Stuck(RM):
        def _access(self, we, addr, data):
            v = super()._access(we, addr, data)
            if not we and addr == self.stuck_ps:
                v |= 1 << 3
            if not we and addr == self.stuck_tx:
                v &= ~(1 << 9)
            return v

    g2 = R.Geometry(**G)
    m2 = Stuck(geom=g2, tile_b=3)
    m2.stuck_ps = g2.ps_addr(2, 1, 4, 5)
    m2.stuck_tx = g2.tx_addr(1, 6)
    r2 = Rondo(MockTransport(m2), pins=MockPins(m2), f_clk=50e6, geom=g2)
    r2.reset_check()
    fails = r2.mem_test()
    assert ("PS", 2, 1, 4, 5, 1 << 3) in fails, fails
    assert ("TX", 1, None, None, 6, 1 << 9) in fails, fails
    assert len(fails) == 2, fails
    assert r2.mem_test(regions=("PS",)) == [("PS", 2, 1, 4, 5, 1 << 3)]
