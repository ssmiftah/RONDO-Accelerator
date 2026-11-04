import os
from cocotb_common import ROOT, run, HF_FMA_SOURCES
SOURCES = [ROOT / "rtl" / "core" / n for n in ("fp_fma_pipe.v", "affine_bank_pipe.v")]
if __name__ == "__main__":
    p = dict(DEPTH=int(os.environ.get("WL_DEPTH", "7")),
             PDIM=int(os.environ.get("WL_PDIM", "40")),
             NBATCH=int(os.environ.get("WL_NBATCH", "8")),
             NLAD=int(os.environ.get("WL_NLAD", "8")),
             NPAR=int(os.environ.get("WL_NPAR", "8")))
    run(dut_sources=SOURCES, hdl_toplevel="affine_bank_pipe",
        test_module="test_affine_pipe", parameters=p,
        build_dir="sim_build/affpipe_" + "_".join(f"{k}{v}" for k, v in p.items()),
        hf_sources=HF_FMA_SOURCES)
