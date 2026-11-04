"""W1 replay through cofr_coproc_inter (A4 accuracy check).

Same test body and same dumped models as run_workload, so the accuracy delta is
directly comparable to the W1 numbers in docs/WORKLOAD_RESULTS.md. The only
difference is the DUT: interleaved lanes and a Newton-Raphson reciprocal instead
of iterative lanes and the divSqrt divider.
"""
import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES, require_env

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
            "ladder_engine_inter.v", "cofr_coproc_inter.v")]

if __name__ == "__main__":
    require_env('WL_NPZ')
    depth = int(os.environ.get("WL_DEPTH", "7"))
    width = int(os.environ.get("WL_WIDTH", "16"))
    lanes = int(os.environ.get("WL_LANES", "2"))
    nslot = int(os.environ.get("WL_NSLOT", "8"))
    # bf16 needs its own seed table (6-bit index into a 7-bit fraction) and its
    # own epsilon encoding; W2 established bf16 is the viable reduced format and
    # fp16 is not, so only these two are supported here.
    fmt = os.environ.get("WL_FMT", "fp32")
    if fmt == "bf16":
        mem = ROOT / "rtl" / "core" / "recip_seed_e8s8_t6.mem"
        tbits, exp, sig = 6, 8, 8
    elif fmt == "fp32":
        mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
        tbits, exp, sig = 12, 8, 24
    else:
        raise SystemExit(f"unsupported WL_FMT {fmt!r}: fp16 overflows the continuants (W2)")
    tag = os.environ.get("WL_TAG", "wl")
    build = Path("sim_build") / f"wlint_{tag}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="cofr_coproc_inter",
        test_module="test_workload",
        parameters={"DEPTH": depth, "WIDTH": width, "N_LANES": lanes,
                    "NSLOT": nslot, "GEN": 0, "SEED_FILE": f'"{mem.name}"',
                    "EXP": exp, "SIG": sig, "TBITS": tbits,
                    **({"EPS": int(os.environ["WL_EPSBITS"])}
                       if os.environ.get("WL_EPSBITS") else {})},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
