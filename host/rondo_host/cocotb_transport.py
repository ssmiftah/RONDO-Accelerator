"""Run the unmodified blocking `Rondo` API against RTL inside a cocotb simulation (spec 14.4).

The API runs in a thread started with `cocotb.bridge`; every SPI frame / GPIO access is a coroutine converted with
`cocotb.resume`, so the simulator advances while the API call blocks.

    @cocotb.test()
    async def t(dut):
        bfm = SpiBfm(dut.spi_sclk, dut.spi_cs_n, dut.spi_mosi, dut.spi_miso, ...)
        tr = CocotbTransport(bfm); pins = CocotbPins(dut, period_ns=10)
        def body():
            r = Rondo(tr, pins=pins, f_clk=...); ...
        await bridge(body)()
"""
from .transport import Transport


def _api():
    from cocotb._bridge import bridge, resume          # cocotb 2.x
    return bridge, resume


class CocotbTransport(Transport):
    """`bfm.xfer(tx)` is the async SPI master of sim/rondo_spi_bfm.py"""

    def __init__(self, bfm, hz=None, f_src_hz=None, dut=None, min_r=8.0, div_net="div_applied"):
        """f_src_hz: source clock of the chip (rondo_chip_top `clk`); with it set_speed(hz) sets the BFM ratio f_src/hz (the BFM ratio is in
        source-clock periods, sim/rondo_spi_bfm.py). With dut also given, every frame checks R_core = ratio / 2**DIV_APPLIED >= min_r
        (DIV_APPLIED is read from the RTL net `div_net` of the top level) and raises AssertionError otherwise (CHIP_FIX_PLAN task 3).
        Without f_src_hz the ratio stays whatever the bench set (existing tests)."""
        _, resume = _api()
        self.bfm = bfm
        self._blocking_xfer = resume(self._xfer_co)
        self._hz = hz
        self.f_src_hz = f_src_hz
        self.dut = dut
        self.min_r = min_r
        self._div_net = div_net
        self.min_r_seen = None

    async def _xfer_co(self, tx):
        if self.dut is not None and self.f_src_hz:
            div = int(getattr(self.dut, self._div_net).value)
            r_core = self.bfm.ratio / (1 << div)
            self.min_r_seen = r_core if self.min_r_seen is None else min(self.min_r_seen, r_core)
            assert r_core >= self.min_r, f"SPI frame at R={r_core:.2f} < {self.min_r} (SCLK ratio {self.bfm.ratio:.2f} source periods, DIV_APPLIED={div})"
        return await self.bfm.xfer(tx)

    def xfer(self, tx):
        return bytes(self._blocking_xfer(bytes(tx)))

    def set_speed(self, hz):
        if self.f_src_hz:
            self.bfm.set_ratio(self.f_src_hz / hz)
            self._hz = hz
        return hz


class CocotbPins:
    """irq / busy / st_pass / rst_n / bist_en of rondo_chip_top as the gpio.Pins API."""
    available = True

    def __init__(self, dut, period_ns=10.0, cycles_per_s=None):
        _, resume = _api()
        self.dut = dut
        self.period_ns = period_ns
        self._cps = cycles_per_s if cycles_per_s else 1e9 / period_ns
        self._wait = resume(self._wait_irq_co)
        self._read = resume(self._read_co)
        self._reset = resume(self._reset_co)
        self._bist = resume(self._run_bist_co)

    async def _wait_irq_co(self, timeout):
        from cocotb.triggers import FallingEdge
        n = int(timeout * self._cps)
        for _ in range(min(n, 2_000_000)):
            if int(self.dut.irq.value):
                return True
            await FallingEdge(self.dut.clk)
        return bool(int(self.dut.irq.value))

    async def _read_co(self, name):
        return int(getattr(self.dut, {"irq": "irq", "busy": "busy", "st_pass": "st_pass", "clkout": "clkout",
                                      "rst_n": "rst_n", "bist_en": "bist_en"}[name]).value)

    async def _reset_co(self):
        from cocotb.triggers import Timer
        self.dut.rst_n.value = 0
        await Timer(int(8 * self.period_ns), unit="ns")
        self.dut.rst_n.value = 1
        await Timer(int(40 * self.period_ns), unit="ns")

    async def _run_bist_co(self, timeout):
        from cocotb.triggers import Timer, FallingEdge
        self.dut.bist_en.value = 1
        self.dut.rst_n.value = 0
        await Timer(int(8 * self.period_ns), unit="ns")
        self.dut.rst_n.value = 1
        seen = 0
        for _ in range(int(timeout * self._cps)):
            await FallingEdge(self.dut.clk)
            seen |= int(self.dut.busy.value)
            if seen and not int(self.dut.busy.value):
                break
        for _ in range(4):
            await FallingEdge(self.dut.clk)
        ok = bool(int(self.dut.st_pass.value))
        self.dut.bist_en.value = 0
        return ok

    def wait_irq(self, timeout=1.0):
        return self._wait(timeout)

    def read(self, name):
        return self._read(name)

    def pulse_reset(self, *a, **k):
        self._reset()

    def set_bist_en(self, v):
        self.dut.bist_en.value = int(v)

    def run_bist(self, rondo=None, timeout=10.0):
        return self._bist(min(timeout, 0.2))

    def busy_edges(self, timeout=0.0):
        return []

    def close(self):
        pass
