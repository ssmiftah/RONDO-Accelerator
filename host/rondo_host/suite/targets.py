import numpy as np
from .. import regmap as R, fmt as F
from ..device import Rondo
from ..model import RondoModel, MockPins
from ..transport import MockTransport
from .cases import Ctx, Vectors


def replay_compute(v):
    """compute() for RondoModel that replays the RTL results stored in the vector file"""
    g = v.geom
    tabs = {}
    for fmt, code in (("bf16", 0), ("fp32", 1)):
        tabs[code] = {tuple(int(a) for a in x): [int(a) for a in z] for x, z in zip(v[f"{fmt}_Xb"], v[f"{fmt}_Z"])}

    def compute(model, code, x_bits):
        fmt = "bf16" if code == 0 else "fp32"
        w = 16 if code == 0 else 32
        nonzero = any(any(e) for l in model.wmem for e in l.values())
        x = tuple(int(a) for a in x_bits)
        model._last_clamped = {}
        if not nonzero and not any(x):                      # stage-isolation injection (W = 0, x = 0)
            beta = [int(b) for b in v[f"{fmt}_beta"]]
            eps = 0x3C24 if w == 16 else 0x3C23D70A
            m = (1 << (w - 1)) - 1
            model._last_clamped = {j: (b & m) < (eps & m) for j, b in enumerate(beta)}
            z = [int(a) for a in v[f"{fmt}_Zinj"]]
            model._inter = dict(a=[[0] * g[3] for _ in range(g[0])], k0=beta, k1=[int(v[f"{fmt}_one"])] * g[0], z=z)
            return z
        z = tabs[code].get(x, [0] * g[0])
        model._inter = dict(a=[[0] * g[3] for _ in range(g[0])], k0=[0] * g[0], k1=[0] * g[0], z=list(z))
        return z
    return compute


def mock_target(v):
    geom = R.Geometry(width=v.geom[0], pdim=v.geom[1], lanes=v.geom[2], depth=v.geom[3], nslot=v.geom[4], npar=v.geom[5],
                      nxbuf=v.geom[6])
    m = RondoModel(geom=geom, compute=replay_compute(v))
    r = Rondo(MockTransport(m), pins=MockPins(m), f_clk=50e6, geom=geom)
    return r, Ctx(cycle_exact=False, kat_exact=False, name="mock", z_exact=False)


def hw_target(v, kind):
    from ..transport import SpidevTransport
    from ..gpio import Pins
    f_clk = 100e6 if kind == "fpga" else 50e6
    hz = 10e6 if kind == "fpga" else 5e6
    r = Rondo(SpidevTransport(hz=hz), pins=Pins(), f_clk=f_clk)
    return r, Ctx(cycle_exact=True, kat_exact=True, name=kind)
