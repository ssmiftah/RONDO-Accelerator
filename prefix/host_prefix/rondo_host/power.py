"""INA226 current/voltage/power monitor over I2C (smbus2) and a threaded multi-rail sampler (spec 14.4, 14.6)."""
import threading
import time


class INA226:
    REG_CONFIG, REG_SHUNT, REG_BUS, REG_POWER, REG_CURRENT, REG_CAL = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05
    BUS_LSB = 1.25e-3              # V
    SHUNT_LSB = 2.5e-6             # V

    def __init__(self, bus=1, addr=0x40, r_shunt=0.01, i_max=3.0, smbus=None, avg_code=4, vbus_ct=4, vsh_ct=4):
        if smbus is None:
            import smbus2                              # lazy: not available on a PC
            smbus = smbus2.SMBus(bus)
        self._bus, self.addr, self.r_shunt = smbus, addr, r_shunt
        self.i_lsb = i_max / 32768.0
        self.cal = int(0.00512 / (self.i_lsb * r_shunt))
        self.config = 0x4000 | (avg_code << 9) | (vbus_ct << 6) | (vsh_ct << 3) | 0x7        # continuous shunt + bus
        self._write16(self.REG_CAL, self.cal)
        self._write16(self.REG_CONFIG, self.config)

    def _write16(self, reg, v):
        self._bus.write_i2c_block_data(self.addr, reg, [(v >> 8) & 255, v & 255])

    def _read16(self, reg):
        d = self._bus.read_i2c_block_data(self.addr, reg, 2)
        return (d[0] << 8) | d[1]

    @staticmethod
    def _signed(v):
        return v - 0x10000 if v & 0x8000 else v

    def bus_voltage(self):
        return self._read16(self.REG_BUS) * self.BUS_LSB

    def shunt_voltage(self):
        return self._signed(self._read16(self.REG_SHUNT)) * self.SHUNT_LSB

    def current(self):
        return self._signed(self._read16(self.REG_CURRENT)) * self.i_lsb

    def power(self):
        return self._read16(self.REG_POWER) * 25.0 * self.i_lsb

    def sample(self):
        return dict(v=self.bus_voltage(), i=self.current(), p=self.power())


class RailSet:
    """Samples a set of INA226 rails in a background thread; mean power over windows."""

    def __init__(self, rails, period=0.01):
        self.rails, self.period = rails, period          # rails: {name: INA226}
        self._lock = threading.Lock()
        self._samples = []                               # (t, {name: p})
        self._stop = threading.Event()
        self._th = None

    def start(self):
        self._stop.clear()
        self._th = threading.Thread(target=self._run, daemon=True)
        self._th.start()

    def _run(self):
        while not self._stop.is_set():
            t = time.monotonic()
            s = {n: r.power() for n, r in self.rails.items()}
            with self._lock:
                self._samples.append((t, s))
            self._stop.wait(self.period)

    def stop(self):
        self._stop.set()
        if self._th:
            self._th.join()

    def mean(self, t0=None, t1=None):
        with self._lock:
            sel = [s for t, s in self._samples if (t0 is None or t >= t0) and (t1 is None or t <= t1)]
        if not sel:
            return {n: 0.0 for n in self.rails}
        return {n: sum(x[n] for x in sel) / len(sel) for n in self.rails}

    def clear(self):
        with self._lock:
            self._samples.clear()
