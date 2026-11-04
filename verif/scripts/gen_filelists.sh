#!/bin/bash
# Generates verif/common/filelists/{hardfloat,core,chip,chip_top}.f for a given RTL root (default: the fixed tree).
# usage: gen_filelists.sh [RTL_ROOT] [OUT_DIR]   (RTL_ROOT must contain rtl/chip, rtl/core; HardFloat always from the main tree)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RR=${1:-$ROOT}; OUT=${2:-$ROOT/verif/common/filelists}; mkdir -p "$OUT"
HF=$ROOT/rtl/third_party/HardFloat/source
{ for f in HardFloat_primitives HardFloat_rawFN isSigNaNRecFN fNToRecFN recFNToFN; do echo $HF/$f.v; done; echo $HF/RISCV/HardFloat_specialize.v; echo $HF/mulAddRecFN.v; } > $OUT/hardfloat.f
for f in fp_fma_pipe affine_bank_pipe ladder_scan_inter recip_nr_pipe ladder_engine_inter fused_coproc_pipe kan_basis_inter kan_sum_bank kan_layer_pipe; do echo $RR/rtl/core/$f.v; done > $OUT/core.f
ls $RR/rtl/chip/*.v | grep -v 'genesys2_pi_top\|rondo_chip_top\|rondo_spi_slave' > $OUT/chip.f
echo $RR/rtl/chip/rondo_spi_slave.v >> $OUT/chip.f
echo $RR/rtl/chip/rondo_chip_top.v > $OUT/chip_top.f
