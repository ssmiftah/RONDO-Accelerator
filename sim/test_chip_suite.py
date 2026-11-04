import os, sys
from pathlib import Path
import cocotb
from cocotb._bridge import bridge
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from rondo_host.device import Rondo                                     # noqa: E402
from rondo_host.suite.cases import Vectors, Ctx, run_suite              # noqa: E402
from test_chip_host import make_api, reset                              # noqa: E402


def body(dut, tr, pins, v):
    r = Rondo(tr, pins=pins, f_clk=50e6)
    return run_suite(r, v, Ctx(cycle_exact=True, kat_exact=True, name="sim"), log=lambda s: None)


@cocotb.test()
async def suite_sim(dut):
    v = Vectors(os.environ["SUITE_VECTORS"])
    tr, pins, bfm = make_api(dut)
    await reset(dut)
    res = await bridge(body)(dut, tr, pins, v)
    for name, ok, msg in res:
        dut._log.info(f"suite[sim] {name}: {'PASS' if ok else 'FAIL ' + msg}")
    bad = [(n, m) for n, ok, m in res if not ok]
    assert not bad, f"suite failures: {bad}"
