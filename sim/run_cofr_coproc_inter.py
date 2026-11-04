"""Runner for cofr_coproc_inter (A4): the coprocessor on the interleaved lane.

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_cofr_coproc_inter.py

Reuses test_cofr_coproc unchanged -- cofr_coproc_inter is a drop-in for
cofr_coproc at GEN=0, so the same functional check applies. Configs cover one
wave, multiple waves, a partial last wave, single lane, and NSLOT at its lower
bound (FMA_LAT+1 = 6).
"""

import os, shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

SOURCES = [ROOT / "rtl" / "core" / n for n in
           ("fp_fma_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
            "ladder_engine_inter.v", "cofr_coproc_inter.v")]

CONFIGS = [
    # (DEPTH, WIDTH, N_LANES, NSLOT)
    (7,  8, 1, 8),   # one lane, one wave, exactly full
    (7, 16, 2, 8),   # two lanes, one wave
    (7, 32, 2, 8),   # two lanes, two waves
    (7, 13, 2, 8),   # partial last wave, ragged WIDTH
    (7,  5, 1, 8),   # WIDTH < NSLOT: mostly padded slots
    (7, 12, 2, 6),   # NSLOT at the lower bound FMA_LAT+1
    (3, 16, 2, 8),   # shallow ladders
    (16, 8, 1, 8),   # deeper ladders
]

if __name__ == "__main__":
    os.environ["COFR_GEN"] = "0"
    mem = ROOT / "rtl" / "core" / "recip_seed_e8s24_t12.mem"
    shutil.copy(mem, Path.cwd() / mem.name)
    for depth, width, lanes, nslot in CONFIGS:
        build = Path("sim_build") / f"coproc_inter_d{depth}_w{width}_l{lanes}_n{nslot}"
        build.mkdir(parents=True, exist_ok=True)
        shutil.copy(mem, build / mem.name)
        run(
            dut_sources=SOURCES,
            hdl_toplevel="cofr_coproc_inter",
            test_module="test_cofr_coproc",
            parameters={"DEPTH": depth, "WIDTH": width, "N_LANES": lanes,
                        "NSLOT": nslot, "GEN": 0, "SEED_FILE": f'"{mem.name}"'},
            build_dir=str(build),
            hf_sources=HF_FMA_SOURCES,
        )
