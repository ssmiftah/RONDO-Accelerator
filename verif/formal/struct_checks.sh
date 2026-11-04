#!/bin/bash
# FV-STRUCT (yosys, not SBY). usage: struct_checks.sh [RTL_ROOT]  -> prints PASS/FAIL per check; exit 1 on a failing check.
#  1. core_rst_n[f] is driven by a flop (+ the test-mode mux only)  [B6]       (scripts/chip_struct.sh on the given rondo_seq.v)
#  2. only rondo_icg produces latches: number of $dlatch cells in rondo_chip_top (S geometry) == number of rondo_icg instances
ROOT=$(cd "$(dirname "$0")/../.." && pwd); RR=${1:-$ROOT}; rc=0
B=$ROOT/build/verif/struct; mkdir -p $B
if (cd $ROOT && scripts/chip_struct.sh $RR/rtl/chip/rondo_seq.v > $B/s1.log 2>&1); then echo "PASS  STRUCT.1 core_rst_n driven by a flop (rondo_seq at $RR)"; else echo "FAIL  STRUCT.1 core_rst_n cone contains logic"; rc=1; fi
FILES=$(ls $RR/rtl/chip/*.v | grep -v genesys2 | tr '\n' ' ')
CORE="fp_fma_pipe affine_bank_pipe ladder_scan_inter recip_nr_pipe ladder_engine_inter fused_coproc_pipe kan_basis_inter kan_sum_bank kan_layer_pipe"
CF=""; for c in $CORE; do CF="$CF $RR/rtl/core/$c.v"; done
HF=$ROOT/rtl/third_party/HardFloat/source
HFF="$HF/HardFloat_primitives.v $HF/HardFloat_rawFN.v $HF/isSigNaNRecFN.v $HF/fNToRecFN.v $HF/recFNToFN.v $HF/RISCV/HardFloat_specialize.v $HF/mulAddRecFN.v"
yosys -q -l $B/s2.log -p "read_verilog -sv -I $RR/rtl -I $RR/rtl/chip -I $HF -I $HF/RISCV $HFF $CF $FILES; chparam -set WIDTH 16 -set PDIM 8 -set N_LANES 2 -set HB_BIT 7 rondo_chip_top; hierarchy -top rondo_chip_top; proc; flatten; opt_clean; stat" > $B/s2.out 2>&1
nl=$(grep -c "rondo_icg" $B/s2.log); 
dl=$(grep -E '\$dlatch' $B/s2.log | awk '{s+=$1} END{print s+0}')
ic=3   # rondo_icg instances in the S build: 1 in rondo_clkdiv + 2 in rondo_layers (bf16, fp32), see grep of rondo_icg in rtl/chip
echo "INFO  STRUCT.2 $dlatch cells in rondo_chip_top (S): $dl; expected rondo_icg instances: $ic"
if [ "$dl" -eq "$ic" ]; then echo "PASS  STRUCT.2 latches only from the 3 rondo_icg instances"; else echo "FAIL  STRUCT.2 latch count $dl != $ic"; rc=1; fi
exit $rc
