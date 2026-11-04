#!/bin/bash
# Cadence Xcelium flow for the RONDO UVM testbench. UNTESTED HERE (no Cadence tools on this machine); written against xrun 23.x/24.x documentation.
# The SystemVerilog sources are tool-neutral standard UVM 1.2; every tool difference lives in this script.
#
#   run_xcelium.sh build <top DEV|CHIP> <cfg> [RTL_ROOT]       elaborate once   -> build/verif/xcelium/<tag>/ (xcelium.d + snapshot)
#   run_xcelium.sh run   <tag> <test> <seed> [+plusargs ...]    run one test     -> build/verif/xcelium_runs/<tag>/<test>_<seed>/run.log
#   run_xcelium.sh one   <top> <cfg> <test> <seed> [+args]      xrun single step (compile + elaborate + run), handy for debugging
#   run_xcelium.sh merge <tag>                                  merge the coverage of all runs of <tag> with IMC and write a report
#
# Environment: XRUN (default xrun), IMC (default imc), UVMHOME (default CDNS-1.2, the UVM 1.2 shipped inside Xcelium),
#   ACCESS=1 adds -access +rwc (waveform/debug), COV=0 disables coverage, XRUN_EXTRA="..." extra xrun options, LICQ=1 adds -licqueue.
set -e
ROOT=$(cd "$(dirname "$0")/../../.." && pwd); V=$ROOT/verif
XRUN=${XRUN:-xrun}; IMC=${IMC:-imc}; UVMHOME=${UVMHOME:-CDNS-1.2}
mode=$1; shift
common_opts() {   # $1 top  $2 cfg  $3 rtl root
  local top=$1 cfg=$2 rr=${3:-$ROOT}
  local HF=$ROOT/rtl/third_party/HardFloat/source
  $V/scripts/gen_filelists.sh "$rr" $ROOT/build/verif/xcelium/fl_$cfg >/dev/null
  local FL=$ROOT/build/verif/xcelium/fl_$cfg
  local chipf=""; [ "$top" = CHIP ] && chipf="-f $FL/chip_top.f"
  echo "-64bit -sv -uvm -uvmhome $UVMHOME -timescale 1ns/1ps -nowarn DSEMEL -nowarn CUVWSP \
        -incdir $HF -incdir $HF/RISCV -incdir $rr/rtl -incdir $rr/rtl/chip -incdir $V/common/cfg -incdir $V/model -incdir $V/uvm -incdir $V/uvm/env -incdir $V/uvm/agents -incdir $V/uvm/tb \
        -define CFG_${cfg} -define TOP_${top} \
        -f $FL/hardfloat.f -f $FL/core.f -f $FL/chip.f $chipf $(ls $rr/rtl/chip/sva/*.v | tr '\n' ' ') \
        $V/uvm/tb/rondo_ifs.sv $V/uvm/rondo_pkg.sv $V/uvm/tb/tb_top.sv \
        $V/model/rondo_fpmodel.c -top tb_top $( [ -n "$ACCESS" ] && echo -access +rwc ) $( [ -n "$LICQ" ] && echo -licqueue ) $XRUN_EXTRA"
}
cov_opts() {      # $1 tag $2 testname  -> functional + code coverage (block, expression, toggle, fsm) into one work area per tag
  [ "${COV:-1}" = 0 ] && return
  echo "-coverage all -covoverwrite -covworkdir $ROOT/build/verif/xcelium_cov/$1 -covtest $2 -covfile $V/uvm/cov/xcelium_covfile.cf"
}
case $mode in
  build)
    top=$1; cfg=$2; rr=$(cd "${3:-$ROOT}" && pwd); tag=tb_top_${top}_${cfg}; [ "$rr" != "$ROOT" ] && tag=${tag}_prefix   # same tag rule as xsim_build.sh / regress.py (check round fix)
    D=$ROOT/build/verif/xcelium/$tag; mkdir -p $D; cd $D
    # -elaborate stops after elaboration; the DPI C file is compiled and linked by xrun itself (no xsc/gcc step)
    $XRUN $(common_opts $top $cfg $rr) -elaborate -snapshot snap -xmlibdirname $D/xcelium.d -coverage all -covfile $V/uvm/cov/xcelium_covfile.cf > build.log 2>&1
    echo "built $D (see build.log)";;
  run)
    tag=$1; test=$2; seed=$3; shift 3
    D=$ROOT/build/verif/xcelium_runs/$tag/${test}_$seed; B=$ROOT/build/verif/xcelium/$tag; rm -rf $D; mkdir -p $D; cd $D
    cp $ROOT/rtl/core/recip_seed_*.mem .
    pa=""; for a in "$@"; do pa="$pa $a"; done
    # pass = UVM_ERROR 0, UVM_FATAL 0 and TEST_DONE seen (same criterion as xsim_run.sh; TEST_DONE added in the check round)
    # -R runs the snapshot; seed with -svseed; test through the standard +UVM_TESTNAME; CORE_DIR for the seed tables read by the C model
    $XRUN -64bit -R -r snap -xmlibdirname $B/xcelium.d -svseed $seed +UVM_TESTNAME=$test +UVM_VERBOSITY=${UVM_VERBOSITY:-UVM_LOW} +CORE_DIR=. $pa \
          $(cov_opts $tag ${test}_$seed) > run.log 2>&1 || true
    if grep -q "UVM_ERROR :    0" run.log && grep -q "UVM_FATAL :    0" run.log && grep -q "TEST_DONE" run.log; then echo "PASS $tag $test seed=$seed"; else echo "FAIL $tag $test seed=$seed"; fi;;
  one)
    top=$1; cfg=$2; test=$3; seed=$4; shift 4; tag=tb_top_${top}_${cfg}
    D=$ROOT/build/verif/xcelium_runs/$tag/${test}_$seed; rm -rf $D; mkdir -p $D; cd $D; cp $ROOT/rtl/core/recip_seed_*.mem .
    $XRUN $(common_opts $top $cfg) -svseed $seed +UVM_TESTNAME=$test +CORE_DIR=. "$@" $(cov_opts $tag ${test}_$seed) 2>&1 | tee run.log | tail -30;;
  merge)
    tag=$1; W=$ROOT/build/verif/xcelium_cov/$tag; R=$ROOT/verif/reports/cov_xcelium_$tag; mkdir -p $R
    # IMC batch: merge every run, then write a summary (functional covergroups + code coverage)
    cat > $W/merge.cmd <<EOT
merge $W/scope/* -out $W/merged -overwrite
load -run $W/merged
report -summary -detail -metrics all -out $R/summary.txt
report -html -metrics all -out $R/html
exit
EOT
    $IMC -batch -execcmd "source $W/merge.cmd";;
  *) echo "usage: $0 build|run|one|merge ..."; exit 2;;
esac
