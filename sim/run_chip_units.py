"""T-UNITS: clock/reset primitives (T8); memories/packer/checksum parts are added by later
tasks as further entries of UNITS."""
import shutil
from pathlib import Path
from cocotb_common import ROOT, run, HF_FMA_SOURCES

CHIP = ROOT / "rtl" / "chip"
CORE = ["fp_fma_pipe.v", "affine_bank_pipe.v", "ladder_scan_inter.v", "recip_nr_pipe.v",
        "ladder_engine_inter.v", "fused_coproc_pipe.v", "kan_basis_inter.v", "kan_sum_bank.v",
        "kan_layer_pipe.v"]
UNITS = [
    # (name, top, test module, rtl files, tb files)
    ("clk", "tb_chip_units_clk", "test_chip_units",
     ["rondo_sync.v", "rondo_reset_sync.v", "rondo_icg.v", "rondo_clk_mux.v", "rondo_clkdiv.v"],
     ["tb_chip_units_clk.v"]),
    ("mem", "tb_chip_units_mem", "test_chip_units_mem",
     ["rondo_sram_sp.v", "rondo_wmem.v"], ["tb_chip_units_mem.v"]),
    ("pack", "tb_chip_units_pack", "test_chip_units_pack",
     ["rondo_sram_sp.v", "rondo_wmem.v", "rondo_wpack.v"], ["tb_chip_units_pack.v"]),
    ("layers", "tb_chip_units_layers", "test_chip_units_layers",
     ["rondo_sram_sp.v", "rondo_wmem.v", "rondo_wpack.v", "rondo_icg.v", "rondo_layers.v"],
     ["tb_chip_units_layers.v"]),
]

if __name__ == "__main__":
    for name, top, mod, rtl, tb in UNITS:
        build = Path("sim_build_chip") / f"units_{name}"
        build.mkdir(parents=True, exist_ok=True)
        core = [ROOT / "rtl" / "core" / n for n in CORE] if name == "layers" else []
        for m in ("recip_seed_e8s8_t6.mem", "recip_seed_e8s24_t12.mem", "recip_seed_e8s24_t8.mem"):
            shutil.copy(ROOT / "rtl" / "core" / m, build / m); shutil.copy(ROOT / "rtl" / "core" / m, Path.cwd() / m)
        run(dut_sources=core + [CHIP / f for f in rtl] + [ROOT / "sim" / f for f in tb],
            hdl_toplevel=top, test_module=mod, build_dir=str(build),
            hf_sources=HF_FMA_SOURCES if core else [])
