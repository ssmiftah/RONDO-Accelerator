#!/bin/bash
# Code coverage (xsim --cc_type sbct) for one top: builds the *_cc snapshot (datapath/HardFloat in an uninstrumented library), runs the test list
# SEQUENTIALLY in one directory (xsim accumulates the code-coverage database across runs there) and writes build/verif/ccrep/<top>_<cfg>/.
# usage: cc_regress.sh DEV|CHIP [cfg=S] "test1 test2 ..." [seed=1]
export PATH=${VIVADO_BIN:-/home/CAD/2025.2/Vivado/bin}:$PATH
ROOT=$(cd "$(dirname "$0")/../.." && pwd); TOP=$1; CFG=${2:-S}; TESTS=$3; SEED=${4:-1}
export ELAB_ARGS="--cc_type sbct"; CC_SPLIT=1 TAGSUFFIX=_cc TOPSEL=$TOP $ROOT/verif/scripts/xsim_build.sh tb_top $CFG >/dev/null 2>&1 || { echo build failed; exit 1; }
B=$ROOT/build/verif/xsim/tb_top_${TOP}_${CFG}_cc; D=$ROOT/build/verif/ccrun/${TOP}_${CFG}; rm -rf $D; mkdir -p $D; cd $D
cp $B/recip_seed*.mem .; cp -r $B/xsim.dir .; cp -r $B/xsim.codeCov .
for t in $TESTS; do
  extra=""; [ $t = u_b4_host_replay ] && extra="--testplusarg B4_LOG=$ROOT/build/verif/b4_fixed.log"
  xsim snap -R --sv_seed $SEED --testplusarg UVM_TESTNAME=$t --testplusarg CORE_DIR=. $extra > run_$t.log 2>&1
  echo "$t: $(grep -c 'UVM_ERROR :    0' run_$t.log) clean"
done
mkdir -p $ROOT/build/verif/ccrep; xcrg -cc_dir . -cc_db snap -report_format text -report_dir $ROOT/build/verif/ccrep/${TOP}_${CFG} 2>&1 | tail -6
