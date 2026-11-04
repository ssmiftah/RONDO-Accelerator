#!/usr/bin/env bash
# T-LINT: verilator --lint-only -Wall on the chip RTL, default and parameter variants.
# usage: scripts/chip_lint.sh [top] ; with no argument runs rondo_chip_top (if present) variants.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HF=rtl/third_party/HardFloat/source
HFSRC="$HF/HardFloat_primitives.v $HF/HardFloat_rawFN.v $HF/isSigNaNRecFN.v $HF/fNToRecFN.v $HF/recFNToFN.v $HF/RISCV/HardFloat_specialize.v $HF/mulAddRecFN.v"
CORE="rtl/core/fp_fma_pipe.v rtl/core/affine_bank_pipe.v rtl/core/ladder_scan_inter.v rtl/core/recip_nr_pipe.v rtl/core/ladder_engine_inter.v rtl/core/fused_coproc_pipe.v rtl/core/kan_basis_inter.v rtl/core/kan_sum_bank.v rtl/core/kan_layer_pipe.v"
CHIP=$(ls rtl/chip/*.v | grep -v genesys2_pi_top)
VLT="sim/hardfloat.vlt sim/cofr_waivers.vlt sim/chip_waivers.vlt"
TOP="${1:-rondo_chip_top}"
OUT=build/chip/lint; mkdir -p "$OUT"
fail=0
run() {  # name, params...
  name=$1; shift
  verilator --lint-only -Wall --top-module "$TOP" --replication-limit 65536 -Irtl -Irtl/chip -I$HF -I$HF/RISCV \
    $VLT $CHIP $CORE $HFSRC "$@" > "$OUT/$name.log" 2>&1
  n=$(grep -c '^%Warning\|^%Error' "$OUT/$name.log")
  if [ "$n" -ne 0 ]; then echo "LINT $name: $n warning(s)/error(s)  (see $OUT/$name.log)"; fail=1; else echo "LINT $name: clean"; fi
}
run_expect_fail() {  # name, message, params...: passes only if verilator exits non-zero AND the log contains the message
  name=$1; msg=$2; shift 2
  verilator --lint-only -Wall --top-module "$TOP" --replication-limit 65536 -Irtl -Irtl/chip -I$HF -I$HF/RISCV \
    $VLT $CHIP $CORE $HFSRC "$@" > "$OUT/$name.log" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ] && grep -q -- "$msg" "$OUT/$name.log"; then echo "LINT $name: rejected as expected (\"$msg\")";
  else echo "LINT $name: EXPECTED an elaboration error \"$msg\" (rc=$rc, see $OUT/$name.log)"; fail=1; fi
}
if [ "$TOP" = "rondo_chip_top" ]; then
  run default
  run mbist_scan_pg -GMBIST=1 -GSCAN=1 -GPG=1
  run no_fp32 -GHAS_FP32=0
  run no_bf16 -GHAS_BF16=0
  run kan -GLAYER=1
  run small -GWIDTH=16 -GPDIM=8 -GN_LANES=2
  run accsig24 -GACCSIG_BF16=24 -GTILE=0
  run tile_b0 -GTILE_B=0
  # elaboration checks (spec 7.1, 10.1, 18.3): illegal parameter sets must be rejected
  run_expect_fail accsig24_tile "TILE=1 needs ACCSIG_BF16=8" -GACCSIG_BF16=24
  run_expect_fail npar6 "NPAR must be a power of two" -GNPAR=6
  run_expect_fail tbits10 "TBITS_FP32 must be 8 or 12" -GTBITS_FP32=10
  # the other tools must reject the same bad build at elaboration (Icarus: top-level -P override; Yosys: chparam)
  CHIPDEV=$(echo "$CHIP" | tr ' ' '\n' | grep -v rondo_chip_top | tr '\n' ' ')
  if iverilog -g2012 -s rondo_dev -P rondo_dev.NPAR=6 -Irtl -Irtl/chip -I$HF -I$HF/RISCV -o "$OUT/neg.vvp" $CHIPDEV $CORE $HFSRC > "$OUT/iverilog_npar6.log" 2>&1; then
    echo "LINT iverilog_npar6: EXPECTED an elaboration error (iverilog accepted NPAR=6)"; fail=1
  elif grep -q "NPAR must be a power of two" "$OUT/iverilog_npar6.log"; then echo "LINT iverilog_npar6: rejected as expected";
  else echo "LINT iverilog_npar6: failed for another reason (see $OUT/iverilog_npar6.log)"; fail=1; fi
  if iverilog -g2012 -s rondo_dev -Irtl -Irtl/chip -I$HF -I$HF/RISCV -o "$OUT/pos.vvp" $CHIPDEV $CORE $HFSRC > "$OUT/iverilog_default.log" 2>&1; then
    echo "LINT iverilog_default: elaborates"; else echo "LINT iverilog_default: FAILED (see $OUT/iverilog_default.log)"; fail=1; fi
  if yosys -q -p "read_verilog -sv -Irtl -Irtl/chip -I$HF -I$HF/RISCV $CHIPDEV $CORE $HFSRC; chparam -set NPAR 6 rondo_dev; hierarchy -top rondo_dev" > "$OUT/yosys_npar6.log" 2>&1; then
    echo "LINT yosys_npar6: EXPECTED an elaboration error (yosys accepted NPAR=6)"; fail=1
  elif grep -q "rondo_dev.v:[0-9]*: ERROR: FATAL" "$OUT/yosys_npar6.log"; then echo "LINT yosys_npar6: rejected as expected (Yosys prints the location of the \$fatal, not its message)";
  else echo "LINT yosys_npar6: failed for another reason (see $OUT/yosys_npar6.log)"; fail=1; fi
else
  run default
  run no_fp32 -GHAS_FP32=0
  run kan -GLAYER=1
fi
if [ "$TOP" = "rondo_chip_top" ]; then
  # no file-wide UNUSED* waiver may cover rtl/chip (every entry names one signal / parameter)
  if grep -E 'lint_off.*UNUSED[A-Z]*.*-file "[^"]*rtl/chip/\*' sim/chip_waivers.vlt | grep -v -- '-match' > /dev/null; then
    echo "LINT waivers: a file-wide UNUSED* waiver for rtl/chip is present in sim/chip_waivers.vlt"; fail=1
  else echo "LINT waivers: no file-wide UNUSED* waiver for rtl/chip"; fi
  # spec 3.4 structural check: core_rst_n is driven by a flop (+ the test-mode mux only)
  scripts/chip_struct.sh || fail=1
fi
exit $fail
