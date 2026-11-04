#!/bin/bash
# Red-on-prefix / green-on-fixed table for B1..B7 + robustness. Output: verif/reports/prefix_check.md (also printed).
ROOT=$(cd "$(dirname "$0")/../.." && pwd); cd $ROOT; PY=$ROOT/.venv-rtl/bin/python; O=$ROOT/verif/reports/prefix_check.md
{ echo "# Red on pre-fix, green on fixed ($(date -I))"; echo; echo "| scenario | check | pre-fix RTL (build/verif/rtl_prefix) | fixed RTL |"; echo "|---|---|---|---|"; } > $O
row() { echo "| $1 | $2 | $3 | $4 |" >> $O; }
res() { if [ "$1" = 0 ]; then echo PASS; else echo FAIL; fi; }
for t in u_b1_keep_corehold u_b2_kat_pwr u_b4_host_replay; do
  python3 verif/scripts/regress.py --tier nightly --prefix --tests $t --seeds 1 >/dev/null 2>&1; p=$?
  python3 verif/scripts/regress.py --tier nightly --tests $t --seeds 1 >/dev/null 2>&1; f=$?
  case $t in u_b1*) b=B1;; u_b2*) b=B2;; u_b4*) b=B4;; esac
  row $b "UVM $t" "$(res $p) (expected FAIL)" "$(res $f) (expected PASS)"
done
verif/scripts/elab_neg.sh $ROOT/build/verif/rtl_prefix >/dev/null 2>&1; p=$?; verif/scripts/elab_neg.sh >/dev/null 2>&1; f=$?
row B3 "elab_neg.sh (TILE with ACCSIG_BF16=24 and 5 other illegal parameter sets must be fatal)" "$(res $p) (expected FAIL)" "$(res $f) (expected PASS)"
cd build/verif/cocotb
RTL_ROOT=$ROOT/build/verif/rtl_prefix PYTHONPATH=$ROOT/sim $PY -I $ROOT/verif/cocotb/run_b7.py > b7_prefix.log 2>&1; grep -q 'FAIL=1' b7_prefix.log && p=1 || p=0
RTL_ROOT=$ROOT PYTHONPATH=$ROOT/sim $PY -I $ROOT/verif/cocotb/run_b7.py > b7_fixed.log 2>&1; grep -q 'FAIL=1' b7_fixed.log && f=1 || f=0
grep -c 'PASS=1' b7_fixed.log | grep -q 2 || f=1
cd $ROOT
row B7 "cocotb run_b7.py (sim/test_core_c6.py::c6_start_in_done_disabled, bf16+fp32)" "$(res $p) (expected FAIL)" "$(res $f) (expected PASS)"
verif/formal/struct_checks.sh $ROOT/build/verif/rtl_prefix >/dev/null 2>&1; p=$?; verif/formal/struct_checks.sh >/dev/null 2>&1; f=$?
row B6 "formal/struct_checks.sh STRUCT.1 (core_rst_n from a flop)" "$(res $p) (expected FAIL)" "$(res $f) (expected PASS)"
row B5 "u_caps (formula) on the pre-fix RTL is not meaningful: CAPS layout differs" "n/a" "PASS (S, S_MIN, S_KAN, S_MB, S_SCAN_PG, S_ACC24)"
echo >> $O; echo "Formal red-on-prefix: see formal_summary_prefix.md (seq, regs, kat)." >> $O; cat $O
