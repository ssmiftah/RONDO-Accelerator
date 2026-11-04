import json
import numpy as np
from rondo_host import bench, power, gpio


def test_bench_mock_end_to_end(capsys):
    res = bench.main(["--target", "mock", "-T", "0.001", "-n", "2"])
    assert res["sr_done"] >= 1 and res["energy_per_inference_j"] > 0 and res["throughput_inf_per_s"] > 0


class FakeBus:
    def __init__(self):
        self.regs = {0x02: 0x1000, 0x01: 0x0800, 0x04: 0x0400, 0x03: 0x0100}
        self.writes = {}

    def write_i2c_block_data(self, addr, reg, data):
        self.writes[reg] = (data[0] << 8) | data[1]

    def read_i2c_block_data(self, addr, reg, n):
        v = self.regs[reg]
        return [v >> 8, v & 255]


def test_ina226_scaling():
    bus = FakeBus()
    d = power.INA226(addr=0x40, r_shunt=0.01, i_max=3.0, smbus=bus)
    ilsb = 3.0 / 32768
    assert bus.writes[0x05] == int(0.00512 / (ilsb * 0.01))
    assert abs(d.bus_voltage() - 0x1000 * 1.25e-3) < 1e-9
    assert abs(d.shunt_voltage() - 0x0800 * 2.5e-6) < 1e-12
    assert abs(d.current() - 0x0400 * ilsb) < 1e-12
    assert abs(d.power() - 0x0100 * 25 * ilsb) < 1e-12
    rs = power.RailSet({"a": d}, period=0.001)
    rs.start()
    import time; time.sleep(0.02)
    rs.stop()
    assert rs.mean()["a"] > 0


def test_pins_with_fake_gpiod(monkeypatch):
    import sys, types
    mod = types.ModuleType("gpiod")
    line = types.ModuleType("gpiod.line")
    class E:  # enums
        INPUT = "in"; OUTPUT = "out"; RISING = "r"; BOTH = "b"; ACTIVE = 1; INACTIVE = 0; DISABLED = 0
    line.Direction = line.Edge = line.Value = line.Bias = E
    state = {}
    class Req:
        def __init__(self): self.vals = {gpio.IRQ: 0, gpio.BUSY: 0, gpio.ST_PASS: 1}
        def get_value(self, l): return self.vals.get(l, 0)
        def set_value(self, l, v): self.vals[l] = v; state.setdefault("set", []).append((l, v))
        def wait_edge_events(self, t): return False
        def read_edge_events(self): return []
        def release(self): pass
    mod.LineSettings = lambda **kw: kw
    mod.request_lines = lambda path, consumer, config: Req()
    mod.is_gpiochip_device = lambda p: True
    class Chip:
        def __init__(self, p): pass
        def __enter__(self): return self
        def __exit__(self, *a): pass
        def get_info(self): return types.SimpleNamespace(label="pinctrl-rp1")
    mod.Chip = Chip
    monkeypatch.setitem(sys.modules, "gpiod", mod); monkeypatch.setitem(sys.modules, "gpiod.line", line)
    monkeypatch.setattr(gpio.glob, "glob", lambda pat: ["/dev/gpiochip4"])
    p = gpio.Pins()
    assert p.chip_path == "/dev/gpiochip4"
    assert p.read("st_pass") == 1 and p.wait_irq(0.001) is False
    p.pulse_reset(low_s=0, settle_s=0)
    assert (gpio.RST_N, 0) in state["set"] and (gpio.RST_N, 1) in state["set"]
