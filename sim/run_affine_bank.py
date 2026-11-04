import os
from cocotb_common import ROOT, run, HF_ALL_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in ("fp_fma.v", "affine_bank.v")]
if __name__ == "__main__":
    p = dict(DEPTH=int(os.environ.get("WL_DEPTH", "7")),
             PDIM=int(os.environ.get("WL_PDIM", "8")),
             NMAC=int(os.environ.get("WL_NMAC", "1")),
             NLAD=int(os.environ.get("WL_NLAD", "4")))
    run(dut_sources=SOURCES, hdl_toplevel="affine_bank",
        test_module="test_affine_bank", parameters=p,
        build_dir="sim_build/affine_bank_" + "_".join(f"{k}{v}" for k, v in p.items()),
        hf_sources=HF_ALL_SOURCES)
