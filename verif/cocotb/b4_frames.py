"""B4 frame recorder: runs Rondo.set_clock()/set_format() against a recording MockTransport and logs every SPI frame with the SCLK it was sent at.
usage: HOST_ROOT=<dir containing rondo_host> python -I verif/cocotb/b4_frames.py <log out>
Log lines: `W <addr_hex> <data_hex> @<hz>` (one-word WRITE), `R <addr_hex> @<hz>` (one-word READ). The R monitor of the UVM test u_b4_host_replay and the
summary printed here use R = f_core / SCLK, where f_core follows the CLK_CFG writes (applied at the end of the frame that wrote them), f_clk = 50 MHz.
Exit code 1 when a frame has R < 6 (error); frames with R < 8 are reported as warnings."""
import sys, os
sys.path.insert(0, os.environ["HOST_ROOT"])
from rondo_host import regmap as R, protocol as P
from rondo_host.device import Rondo
from rondo_host.model import RondoModel, MockPins
from rondo_host.transport import MockTransport

class Rec(MockTransport):
    def __init__(self, model, log):
        super().__init__(model); self.log = log; self.div = 0; self.minR = 1e9; self.nlow = 0; self.nwarn = 0; self.n = 0
    def xfer(self, tx):
        tx = bytes(tx); hz = self._hz; fcore = 50e6 / (1 << self.div); Rr = fcore / hz; self.minR = min(self.minR, Rr); self.n += 1
        if Rr < 6: self.nlow += 1
        elif Rr < 8: self.nwarn += 1
        op = tx[0]; addr = ((tx[1] << 16) | (tx[2] << 8) | tx[3]) if len(tx) >= 6 else 0
        if op == P.OP_WRITE and len(tx) >= 10:
            d = int.from_bytes(tx[6:10], "big"); self.log.write(f"W {addr:06x} {d:08x} @{hz:.0f}\n")
            if addr == R.ADDR["CLK_CFG"]: self.div_next = d & 3
        elif op == P.OP_READ: self.log.write(f"R {addr:06x} @{hz:.0f}\n")
        try:
            rx = super().xfer(tx)
        except Exception:
            rx = b"\x00" * len(tx)               # pre-fix tree under a strict model: keep recording
        if op == P.OP_WRITE and addr == R.ADDR["CLK_CFG"] and len(tx) >= 10: self.div = int.from_bytes(tx[6:10], "big") & 3
        return rx

out = sys.argv[1]
g = R.Geometry(width=16, pdim=8, lanes=2)
try: m = RondoModel(geom=g, strict_rate=False)
except TypeError: m = RondoModel(geom=g)
with open(out, "w") as log:
    t = Rec(m, log); r = Rondo(t, pins=MockPins(m), f_clk=50e6, geom=g)
    try: r.max_hz = 5e6
    except Exception: pass
    r.reset_check()
    for div in (3, 1, 0, 2): r.set_clock(div=div); r.reg("CHIP_ID"); r.reg("SCRATCH")
    r.fp32_div = 1 if hasattr(r, "fp32_div") else None
    r.set_format("fp32"); r.reg("CHIP_ID"); r.set_format("bf16"); r.reg("CHIP_ID")
print(f"B4 frames: {t.n} frames, min R = {t.minR:.2f}, frames with R<6: {t.nlow}, R<8: {t.nwarn}")
sys.exit(1 if t.nlow else 0)
