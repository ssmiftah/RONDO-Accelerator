"""Energy / throughput benchmark CLI (spec 14.6).

    python -m rondo_host.bench --target spidev --fmt bf16 --npz workloads/results/waveform_coeffs.npz --rails rails.json -T 5
    python -m rondo_host.bench --target mock   ...      (no hardware: model + synthetic rails)

Procedure: load weights; P_idle = mean rail power over T s with the chip idle (clock running); self-run with count 0, P_run over
T s (window bracketed by the busy edges when available); stop; read SR_DONE_CNT and SR_CYC.
Energy per inference = (P_run - P_idle) * SR_CYC / (f_core * SR_DONE_CNT); the total-power energy is reported too.
rails.json: {"VDD_CORE": {"addr": 64, "r_shunt": 0.01, "i_max": 3.0}, ...}
"""
import argparse
import json
import time
import numpy as np


def run_bench(r, xs, rails, duration=2.0, sleep=time.sleep, clock=time.monotonic):
    """r: Rondo with weights loaded; rails: object with clear()/start()/stop()/mean() (power.RailSet-like)."""
    rails.start()
    rails.clear()
    t0 = clock(); sleep(duration); t1 = clock()
    p_idle = rails.mean(t0, t1)
    r.self_run(xs, count=0)
    sleep(0.05)
    rails.clear()
    t2 = clock(); sleep(duration); t3 = clock()
    p_run = rails.mean(t2, t3)
    r.stop()
    r.wait_sr_done(timeout=10.0)
    rails.stop()
    st = r.bench_stats()
    n, cyc, f = st["sr_done"], st["sr_cycles"], r.f_core
    tot_idle, tot_run = sum(p_idle.values()), sum(p_run.values())
    out = dict(fmt=r.fmt, f_core=f, sr_done=n, sr_cycles=cyc, throughput_inf_per_s=st["throughput"],
               p_idle_w=p_idle, p_run_w=p_run, checksum=st["checksum"], guard_hits=st["guard_hits"])
    if n and cyc:
        out["energy_per_inference_j"] = (tot_run - tot_idle) * cyc / (f * n)
        out["energy_per_inference_total_j"] = tot_run * cyc / (f * n)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rondo_host.bench")
    ap.add_argument("--target", choices=("mock", "spidev"), default="mock")
    ap.add_argument("--fmt", choices=("bf16", "fp32"), default="bf16")
    ap.add_argument("--npz")
    ap.add_argument("--rails")
    ap.add_argument("-T", type=float, default=2.0)
    ap.add_argument("--f-clk", type=float, default=50e6)
    ap.add_argument("--hz", type=float, default=5e6)
    ap.add_argument("-n", type=int, default=4, help="input vectors in the self-run loop")
    a = ap.parse_args(argv)

    from .device import Rondo
    if a.target == "spidev":
        from .transport import SpidevTransport
        from .gpio import Pins
        tr, pins = SpidevTransport(hz=a.hz), Pins()
    else:
        from .transport import MockTransport
        from .model import RondoModel, MockPins
        m = RondoModel()
        tr, pins = MockTransport(m), MockPins(m)
    r = Rondo(tr, pins=pins, f_clk=a.f_clk)
    g = r.reset_check()
    r.set_format(a.fmt)
    if a.npz:
        D = np.load(a.npz)
        Wl = D["Wden"].reshape(int(D["width"]), g.depth, -1)[:g.width, :, :g.pdim].astype(np.float32)
        Bl = D["bden"].reshape(int(D["width"]), g.depth)[:g.width].astype(np.float32)
        X = D["X"][:a.n, :g.pdim].astype(np.float32)
    else:
        rng = np.random.default_rng(1)
        Wl = rng.normal(0, 0.1, (g.width, g.depth, g.pdim)).astype(np.float32)
        Bl = rng.normal(0, 0.4, (g.width, g.depth)).astype(np.float32)
        X = rng.uniform(-1, 1, (a.n, g.pdim)).astype(np.float32)
    r.load_weights(Wl, Bl)
    if a.target == "spidev":
        from .power import INA226, RailSet
        cfg = json.load(open(a.rails)) if a.rails else {}
        rails = RailSet({n: INA226(addr=c["addr"], r_shunt=c.get("r_shunt", 0.01), i_max=c.get("i_max", 3.0))
                         for n, c in cfg.items()})
        sleeper = time.sleep
    else:
        class Fake:
            def start(self): pass
            def stop(self): pass
            def clear(self): pass
            def mean(self, t0=None, t1=None): return {"core": 0.1 if self.running else 0.05}
            running = False
        rails = Fake()
        orig_self_run = r.self_run
        def sr(xs, count=0):
            rails.running = True
            return orig_self_run(xs, count)
        r.self_run = sr
        def sleeper(s):
            m.tick(int(s * r.f_core))
    res = run_bench(r, list(X), rails, a.T, sleep=sleeper)
    print(json.dumps(res, indent=1, default=float))
    return res


if __name__ == "__main__":
    main()
