"""cycles/ladder vs N_LANES for cofr_coproc_inter (A4).

Same test body as run_lane_sweep, different DUT, so the two curves are directly
comparable. WIDTH is held fixed across the sweep; a wave covers N_LANES*NSLOT
ladders here, not N_LANES.
"""
import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES, require_env
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
            "ladder_engine_inter.v", "cofr_coproc_inter.v")]
if __name__ == "__main__":
    require_env('WL_LANES', 'WL_OUT')
    lanes = int(os.environ["WL_LANES"])
    width = int(os.environ.get("WL_WIDTH", "48"))
    nslot = int(os.environ.get("WL_NSLOT", "8"))
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    build = Path("sim_build") / f"lanes_inter_{lanes}_n{nslot}"
    build.mkdir(parents=True, exist_ok=True)
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    run(dut_sources=SOURCES, hdl_toplevel="cofr_coproc_inter",
        test_module="test_lane_sweep",
        parameters={"DEPTH": 7, "WIDTH": width, "N_LANES": lanes,
                    "NSLOT": nslot, "GEN": 0, "SEED_FILE": f'"{mem.name}"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
