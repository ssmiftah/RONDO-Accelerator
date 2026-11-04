"""Gate-level simulation of the Yosys netlist (see scripts/chip_gls.sh). Without GLS_NETLIST it runs the same test on the RTL
top at the same reduced geometry (fast, keeps run_all meaningful)."""
import os, shutil
from pathlib import Path
from cocotb_tools.runner import get_runner, VerilatorControlFile
from cocotb_common import ROOT, run, HF_FMA_SOURCES
import run_chip_regs as r

PARAMS = dict(WIDTH=8, PDIM=4, N_LANES=1, HB_BIT=7, TRACE=0, DBG=0)

if __name__ == "__main__":
    net = os.environ.get("GLS_NETLIST")
    build = Path("sim_build_chip") / ("gls_net" if net else "gls_rtl")
    build.mkdir(parents=True, exist_ok=True)
    for m in r.SEEDS:
        shutil.copy(ROOT / "rtl" / "core" / m, build / m); shutil.copy(ROOT / "rtl" / "core" / m, Path.cwd() / m)
    if not net:
        r.build_and_run("gls_rtl", "rondo_chip_top", "test_chip_gls", PARAMS, tb=None, with_top=True)
    else:
        runner = get_runner("verilator")
        runner.build(sources=[net, os.environ["GLS_SIMCELLS"]], hdl_toplevel="rondo_chip_top", always=True,
                     build_args=["-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-UNOPTFLAT", "--timescale-override", "1ns/1ps",
                                 "-O1"],
                     timescale=("1ns", "1ps"), build_dir=str(build))
        runner.test(hdl_toplevel="rondo_chip_top", test_module="test_chip_gls", build_dir=str(build),
                    timescale=("1ns", "1ps"))
