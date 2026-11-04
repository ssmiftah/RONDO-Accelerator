#!/bin/bash
# usage: xsim_run.sh <build tag e.g. tb_top_DEV_S> <test> <seed> [extra +args ...]
# Own run dir build/verif/runs/<tag>/<test>_<seed>; log run.log; functional coverage DB only with COV=1 (xcrg report later).
export PATH=${VIVADO_BIN:-/home/CAD/2025.2/Vivado/bin}:$PATH
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TAG=$1; TEST=$2; SEED=$3; shift 3
B=$ROOT/build/verif/xsim/$TAG; D=$ROOT/build/verif/runs/$TAG/${TEST}_$SEED
rm -rf $D; mkdir -p $D; cd $D
cp $B/recip_seed_*.mem . 2>/dev/null; cp -r $B/xsim.dir .
ARGS="--sv_seed $SEED --testplusarg UVM_TESTNAME=$TEST --testplusarg UVM_VERBOSITY=${UVM_VERBOSITY:-UVM_LOW} --testplusarg CORE_DIR=."
for a in "$@"; do ARGS="$ARGS --testplusarg ${a#+}"; done
COVARGS=""; [ -n "$COV" ] && mkdir -p $ROOT/build/verif/cov/$TAG && COVARGS="--cov_db_dir $ROOT/build/verif/cov/$TAG --cov_db_name ${TEST}_$SEED"
timeout ${RUN_TIMEOUT:-900} xsim snap -R $ARGS $COVARGS > run.log 2>&1
rc=$?
rm -rf xsim.dir
errs=$(grep -c "^UVM_ERROR\b.*\[" run.log); fat=$(grep -c "^UVM_FATAL\b.*\[" run.log)
summ=$(grep -E "^UVM_ERROR :|^UVM_FATAL :" run.log | tr -s ' ' | tr '\n' ' ')
if grep -q "^UVM_ERROR :    0" run.log && grep -q "^UVM_FATAL :    0" run.log && [ $rc -eq 0 ] && grep -q "TEST_DONE" run.log; then echo "PASS $TAG $TEST seed=$SEED"; else echo "FAIL $TAG $TEST seed=$SEED rc=$rc $summ"; fi
