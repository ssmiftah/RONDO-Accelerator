"""Shared cocotb runner helpers for the CoFrNet RTL.

Run with the RTL venv (.venv-rtl, Python 3.13) that has cocotb; the main .venv
is Python 3.14 which cocotb does not support (see rtl/README.md).
"""

import os
import sys
from pathlib import Path
import numpy as np
from cocotb_tools.runner import get_runner, VerilatorControlFile

# Canonicalize the interpreter path so it matches what the simulator subprocess
# resolves. cocotb sets PYGPI_PYTHON_BIN = sys.executable; when the runner is
# invoked via a relative path (e.g. ../.venv-rtl/bin/python) that value keeps the
# '..' and mismatches, printing a harmless "Unexpected sys.executable" warning.
sys.executable = os.path.realpath(sys.executable)

ROOT = Path(__file__).resolve().parents[1]
HF = ROOT / "rtl" / "third_party" / "HardFloat" / "source"
SPEC = "RISCV"  # HardFloat specialization (NaN propagation etc.)

# HardFloat file sets. _BASE = recode + primitives + specialization shared by all.
_HF_BASE = [
    HF / "HardFloat_primitives.v",
    HF / "HardFloat_rawFN.v",
    HF / "isSigNaNRecFN.v",
    HF / "fNToRecFN.v",
    HF / "recFNToFN.v",
    HF / SPEC / "HardFloat_specialize.v",
]
# FMA path (recode -> mulAdd -> decode): smoke_fma, mat2x2_mul, ladder_scan.
HF_FMA_SOURCES = _HF_BASE + [HF / "mulAddRecFN.v"]
# Divider path (recode -> divSqrtRecFN -> decode): recip_wrap.
HF_DIV_SOURCES = _HF_BASE + [HF / "divSqrtRecFN_small.v"]
# Everything (FMA + divider): ladder_top.
HF_ALL_SOURCES = _HF_BASE + [HF / "mulAddRecFN.v", HF / "divSqrtRecFN_small.v"]
HF_INCLUDES = [str(HF), str(HF / SPEC), str(ROOT / "rtl"), str(ROOT / "rtl" / "chip")]  # rtl/ for cofr_defs.vh, rtl/chip for rondo_kat_sigs.vh


def require_env(*names):
    """Skip cleanly when a parameterised runner is invoked without its config.

    run_all.py globs every run_*.py, but some runners are driven by
    workloads/run_queue.py with per-job environment. Those should report a skip
    rather than fail the regression."""
    missing = [n for n in names if not os.environ.get(n)]
    if missing:
        print(f"SKIP: parameterised runner, needs {', '.join(missing)} "
              f"(driven by workloads/run_queue.py)")
        sys.exit(0)


def run(dut_sources, hdl_toplevel, test_module, parameters=None, build_dir=None,
        hf_sources=None, defines=None, extra_build_args=None):
    """Build `dut_sources` + HardFloat and run `test_module` against it.

    `parameters` sets HDL top-level parameters (e.g. {"DEPTH": 7}); when sweeping,
    pass a distinct `build_dir` per configuration to avoid clobbering.
    `hf_sources` selects the HardFloat set (default HF_FMA_SOURCES).
    """
    sim = os.environ.get("SIM", "icarus")
    hf_sources = hf_sources if hf_sources is not None else HF_FMA_SOURCES
    sources = [str(s) for s in dut_sources] + [str(s) for s in hf_sources]
    parameters = parameters or {}
    build_dir = build_dir or "sim_build"

    # Per-simulator build args.
    #  - Icarus: -g2012 for the SystemVerilog-2012 constructs we use.
    #  - Verilator: prepend a lint waiver that silences the vendored HardFloat
    #    IP only (its intentional width-narrowing trips Verilator's fatal lint);
    #    our own RTL stays strictly linted so real issues still fail the build.
    if sim == "icarus":
        build_args = ["-g2012"]
    elif sim == "verilator":
        # --replication-limit: at CoFrGeNet dimensions x_reg is PDIM*16 = 12,288
        # bits, and `x_reg <= '0` is a replication past Verilator's default 8192,
        # which it reports as suspect and, with warnings fatal, refuses to build.
        # The width is intended; raise the threshold rather than waive the check.
        build_args = ["--replication-limit", "65536"]
        # .vlt control files (not HDL) — wrap so the cocotb runner types them
        # correctly. hardfloat.vlt waives lint for the vendored HardFloat IP;
        # cofr_waivers.vlt scopes-off known false positives in our own RTL.
        sources = [
            VerilatorControlFile(ROOT / "sim" / "hardfloat.vlt"),
            VerilatorControlFile(ROOT / "sim" / "cofr_waivers.vlt"),
            VerilatorControlFile(ROOT / "sim" / "chip_waivers.vlt"),   # chip core changes (C1-C7)
        ] + sources
    else:
        build_args = []

    build_args = list(build_args) + list(extra_build_args or [])
    runner = get_runner(sim)
    runner.build(
        sources=sources,
        includes=HF_INCLUDES,
        hdl_toplevel=hdl_toplevel,
        build_args=build_args,
        always=True,
        timescale=("1ns", "1ps"),
        parameters=parameters,
        build_dir=build_dir,
        defines=defines or {},
    )
    runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module=test_module,
        timescale=("1ns", "1ps"),
        parameters=parameters,
        build_dir=build_dir,
    )


# --- fp32 bit helpers (shared by tests) ---
def f32_to_bits(x):
    return int(np.float32(x).view(np.uint32))


def bits_to_f32(b):
    return float(np.uint32(int(b) & 0xFFFFFFFF).view(np.float32))


def ulp_diff(a, b):
    """ULP distance between two values interpreted as fp32 (monotone key trick)."""
    def key(x):
        u = int(np.float32(x).view(np.uint32))
        return (u ^ 0xFFFFFFFF) if (u >> 31) else (u | 0x80000000)
    return abs(key(a) - key(b))
