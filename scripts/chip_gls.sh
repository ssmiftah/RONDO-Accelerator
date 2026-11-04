#!/usr/bin/env bash
# T-GLS: zero-delay gate-level simulation of the Yosys netlist of rondo_chip_top (reduced SMALL geometry: WIDTH 8, PDIM 4,
# 1 lane, both formats) against the bit-exact model: pin-level bring-up, weight load, inference, KAT bf16 and fp32.
# The netlist is simulated with Verilator + Yosys simcells.v (Icarus is too slow for ~10^5 cells x 10^5 cycles).
# Timing GLS (SDF) is specified in docs/CHIP_INTERFACE_SPEC.md 15.4 and is executed once a PDK flow exists.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HF=$ROOT/rtl/third_party/HardFloat/source
W=$ROOT/build/chip/gls; mkdir -p "$W"; cp "$ROOT"/rtl/core/recip_seed_*.mem "$W"/
SRCS="$ROOT/rtl/core/fp_fma_pipe.v $ROOT/rtl/core/affine_bank_pipe.v $ROOT/rtl/core/ladder_scan_inter.v $ROOT/rtl/core/recip_nr_pipe.v \
 $ROOT/rtl/core/ladder_engine_inter.v $ROOT/rtl/core/fused_coproc_pipe.v $ROOT/rtl/core/kan_basis_inter.v $ROOT/rtl/core/kan_sum_bank.v \
 $ROOT/rtl/core/kan_layer_pipe.v $(ls $ROOT/rtl/chip/rondo_*.v | tr '\n' ' ') $HF/HardFloat_primitives.v $HF/HardFloat_rawFN.v $HF/isSigNaNRecFN.v \
 $HF/fNToRecFN.v $HF/recFNToFN.v $HF/RISCV/HardFloat_specialize.v $HF/mulAddRecFN.v"
cd "$W"
cat > gls.ys <<YS
read_verilog -sv -I$ROOT/rtl -I$ROOT/rtl/chip -I$HF -I$HF/RISCV $SRCS
hierarchy -check -top rondo_chip_top -chparam WIDTH 8 -chparam PDIM 4 -chparam N_LANES 1 -chparam KAT 1 -chparam TRACE 0 -chparam DBG 0 -chparam HB_BIT 7
synth -top rondo_chip_top -flatten
check -assert -noinit
write_verilog -noattr -noexpr netlist.v
tee -o gls_stat.txt stat
YS
yosys -q -l yosys_gls.log gls.ys > yosys_gls_run.txt 2>&1 || { echo "GLS: synthesis failed"; exit 1; }
echo "GLS netlist: $(grep -c '' netlist.v) lines, $(grep -i 'cells$' gls_stat.txt | tail -1)"
cd "$ROOT/sim"
PYTHONPATH=. GLS_NETLIST=$W/netlist.v GLS_SIMCELLS=$(yosys-config --datdir)/simcells.v SIM=verilator \
  "$ROOT/.venv-rtl/bin/python" run_chip_gls.py 2>&1 | grep -E "TESTS=|GLS|assert|Error" | head -20
