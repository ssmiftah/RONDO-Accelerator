#!/usr/bin/env bash
# T-SYN: Yosys synthesis check of rondo_chip_top (SMALL fully mapped; FULL coarse-grain with memories kept as macros).
# usage: scripts/chip_synth.sh [small|full|both]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HF=$ROOT/rtl/third_party/HardFloat/source
W=$ROOT/build/chip/synth; mkdir -p "$W"; cp "$ROOT"/rtl/core/recip_seed_*.mem "$W"/
SRCS="$ROOT/rtl/core/fp_fma_pipe.v $ROOT/rtl/core/affine_bank_pipe.v $ROOT/rtl/core/ladder_scan_inter.v $ROOT/rtl/core/recip_nr_pipe.v \
 $ROOT/rtl/core/ladder_engine_inter.v $ROOT/rtl/core/fused_coproc_pipe.v $ROOT/rtl/core/kan_basis_inter.v $ROOT/rtl/core/kan_sum_bank.v \
 $ROOT/rtl/core/kan_layer_pipe.v $(ls $ROOT/rtl/chip/rondo_*.v | tr '\n' ' ') $HF/HardFloat_primitives.v $HF/HardFloat_rawFN.v $HF/isSigNaNRecFN.v \
 $HF/fNToRecFN.v $HF/recFNToFN.v $HF/RISCV/HardFloat_specialize.v $HF/mulAddRecFN.v"
what=${1:-both}
run() {  # name  chparam-script  synth-args
  name=$1; shift
  cd "$W"
  cat > "$W/$name.ys" <<YS
read_verilog -sv -I$ROOT/rtl -I$ROOT/rtl/chip -I$HF -I$HF/RISCV $SRCS
hierarchy -check -top rondo_chip_top $1
synth -top rondo_chip_top $2
check -assert -noinit
tee -o $ROOT/build/chip/yosys_${name}_stat.txt stat -width
YS
  yosys -q -l "$ROOT/build/chip/yosys_$name.txt" "$W/$name.ys" > "$ROOT/build/chip/yosys_${name}_run.txt" 2>&1
  rc=$?
  echo "SYN $name: rc=$rc  latches: $(grep -c '\$_DLATCH\|\$dlatch' "$ROOT/build/chip/yosys_${name}_stat.txt")  $(grep -i 'cells$' "$ROOT/build/chip/yosys_${name}_stat.txt" | tail -1)"
  return $rc
}
rc=0
if [ "$what" = small ] || [ "$what" = both ]; then
  run small "-chparam WIDTH 16 -chparam PDIM 8 -chparam N_LANES 2" "-flatten" || rc=1
fi
if [ "$what" = full ] || [ "$what" = both ]; then
  run full "" "-run :fine" || rc=1
fi
exit $rc
