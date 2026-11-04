import os, shutil
from pathlib import Path
import numpy as np
from cocotb_common import ROOT, run, HF_FMA_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
            "ladder_engine_inter.v", "cofr_coproc_inter.v")] + \
          [ROOT / "rtl" / "board" / "cofr_power_top.v"]
if __name__ == "__main__":
    build = Path("sim_build") / "power_top"
    build.mkdir(parents=True, exist_ok=True)
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    stim = build / "stimulus.mem"
    # Same distribution as workloads/gen_power_stimulus.py, generated inline so
    # the runner does not depend on which interpreter has numpy.
    rng = np.random.default_rng(20260905)
    a = (rng.uniform(-3, 3, (24, 48, 7))
         + np.sign(rng.uniform(-1, 1, (24, 48, 7))) * 1.5).astype(np.float32)
    stim.write_text("\n".join(f"{w:08x}" for w in a.reshape(-1).view(np.uint32)) + "\n")
    shutil.copy(mem, build / mem.name); shutil.copy(mem, Path.cwd() / mem.name)
    shutil.copy(stim, Path.cwd() / "stimulus.mem")
    os.environ["WL_STIM"] = str(stim.resolve())
    run(dut_sources=SOURCES, hdl_toplevel="cofr_power_top",
        test_module="test_power_top",
        parameters={"DEPTH": 7, "WIDTH": 48, "N_LANES": 2, "NSLOT": 8,
                    "SEED_FILE": f'"{mem.name}"', "STIM_FILE": '"stimulus.mem"'},
        build_dir=str(build), hf_sources=HF_FMA_SOURCES)
