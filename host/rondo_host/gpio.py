"""GPIO on the Raspberry Pi 5 through libgpiod v2 (spec 14.1, 14.2). RPi.GPIO does not work on the Pi 5."""
import glob
import time

# BCM line numbers (spec 14.2)
IRQ, BUSY, RST_N, ST_PASS, BIST_EN, CLKOUT = 25, 24, 23, 22, 27, 17


class NullPins:
    """For PCs and mock runs: no wait on edges, outputs recorded."""
    available = False

    def __init__(self):
        self.rst_n, self.bist_en = 1, 0
        self.irq_events = 0

    def wait_irq(self, timeout=1.0):
        return None            # None = unknown, caller falls back to polling STATUS

    def read(self, name):
        return 0

    def pulse_reset(self, low_s=1e-5, settle_s=1e-3):
        self.rst_n = 0
        self.rst_n = 1

    def set_bist_en(self, v):
        self.bist_en = int(v)

    def run_bist(self, rondo=None, timeout=10.0):
        self.set_bist_en(1)
        self.pulse_reset()
        self.set_bist_en(0)
        return None

    def busy_edges(self, timeout=0.0):
        return []

    def close(self):
        pass


class Pins:
    """gpiod v2 request on the chip labeled `pinctrl-rp1` (not a fixed /dev/gpiochipN: the number differs between kernels)."""
    available = True
    CHIP_LABEL = "pinctrl-rp1"

    def __init__(self, consumer="rondo", chip_path=None, lines=None):
        import gpiod                                           # lazy: not available on a PC
        from gpiod.line import Direction, Edge, Value, Bias
        self.gpiod, self.Value, self.Edge = gpiod, Value, Edge
        self.chip_path = chip_path or self.find_chip(gpiod)
        cfg = {
            IRQ: gpiod.LineSettings(direction=Direction.INPUT, edge_detection=Edge.RISING),
            BUSY: gpiod.LineSettings(direction=Direction.INPUT, edge_detection=Edge.BOTH),
            ST_PASS: gpiod.LineSettings(direction=Direction.INPUT),
            CLKOUT: gpiod.LineSettings(direction=Direction.INPUT, edge_detection=Edge.RISING),
            RST_N: gpiod.LineSettings(direction=Direction.OUTPUT, output_value=Value.ACTIVE),
            BIST_EN: gpiod.LineSettings(direction=Direction.OUTPUT, output_value=Value.INACTIVE),
        }
        self._req = gpiod.request_lines(self.chip_path, consumer=consumer, config=cfg)
        self._names = {"irq": IRQ, "busy": BUSY, "st_pass": ST_PASS, "clkout": CLKOUT, "rst_n": RST_N, "bist_en": BIST_EN}

    @classmethod
    def find_chip(cls, gpiod):
        for path in sorted(glob.glob("/dev/gpiochip*")):
            try:
                if not gpiod.is_gpiochip_device(path):
                    continue
                with gpiod.Chip(path) as chip:
                    if chip.get_info().label == cls.CHIP_LABEL:
                        return path
            except OSError:
                continue
        raise RuntimeError(f"no gpiochip labeled {cls.CHIP_LABEL!r} found")

    def read(self, name):
        return 1 if self._req.get_value(self._names[name]) == self.Value.ACTIVE else 0

    def wait_irq(self, timeout=1.0):
        """True on a rising edge of irq within timeout, False on timeout. Level already high counts as an event."""
        if self.read("irq"):
            return True
        if self._req.wait_edge_events(timeout):
            for ev in self._req.read_edge_events():
                if ev.line_offset == IRQ:
                    return True
            return bool(self.read("irq"))
        return False

    def busy_edges(self, timeout=0.0):
        out = []
        while self._req.wait_edge_events(timeout):
            for ev in self._req.read_edge_events():
                if ev.line_offset == BUSY:
                    out.append((ev.timestamp_ns, ev.event_type))
        return out

    def _set(self, name, v):
        self._req.set_value(self._names[name], self.Value.ACTIVE if v else self.Value.INACTIVE)

    def set_bist_en(self, v):
        self._set("bist_en", v)

    def pulse_reset(self, low_s=1e-5, settle_s=1e-3):
        self._set("rst_n", 0)
        time.sleep(low_s)
        self._set("rst_n", 1)
        time.sleep(settle_s)

    def run_bist(self, rondo=None, timeout=10.0):
        """strap self-test: bist_en high while rst_n is released; wait for busy to fall; return st_pass"""
        self.set_bist_en(1)
        self.pulse_reset()
        t0 = time.monotonic()
        time.sleep(1e-3)
        while self.read("busy") and time.monotonic() - t0 < timeout:
            time.sleep(1e-3)
        ok = bool(self.read("st_pass"))
        self.set_bist_en(0)
        return ok

    def close(self):
        self._req.release()
