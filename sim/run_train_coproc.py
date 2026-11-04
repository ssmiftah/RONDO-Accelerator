"""Runner for train_coproc (I-12 WIDTH-batched fwd+bwd). Sweeps (WIDTH,N_LANES).

    cd sim && PYTHONPATH=. ../.venv-rtl/bin/python run_train_coproc.py
"""

from cocotb_common import ROOT, run, HF_ALL_SOURCES

SOURCES = [
    ROOT / "rtl" / "core" / "fp_fma.v",
    ROOT / "rtl" / "core" / "fp_mul.v",
    ROOT / "rtl" / "core" / "kscan.v",
    ROOT / "rtl" / "core" / "recip_wrap.v",
    ROOT / "rtl" / "core" / "grad_a_unit.v",
    ROOT / "rtl" / "core" / "train_ladder.v",
    ROOT / "rtl" / "core" / "train_coproc.v",
]

CONFIGS = [
    # (DEPTH, WIDTH, N_LANES)
    (3, 4, 4),   # full parallel
    (3, 4, 2),   # two waves
    (3, 5, 2),   # partial last wave
    (7, 3, 1),   # single lane, deeper
]

if __name__ == "__main__":
    for depth, width, lanes in CONFIGS:
        run(
            dut_sources=SOURCES,
            hdl_toplevel="train_coproc",
            test_module="test_train_coproc",
            parameters={"DEPTH": depth, "WIDTH": width, "N_LANES": lanes},
            build_dir=f"sim_build/traincoproc_d{depth}_w{width}_l{lanes}",
            hf_sources=HF_ALL_SOURCES,
        )
