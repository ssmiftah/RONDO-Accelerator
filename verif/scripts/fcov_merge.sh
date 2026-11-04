#!/bin/bash
# Merge the xsim functional-coverage DBs written by `regress.py --cov` (build/verif/cov/<tag>/xsim.covdb/<test>_<seed>)
# into build/verif/covall and write the xcrg text report to verif/reports/cov/functional_merged.txt.
# (Added in the check round: this step had been done by hand and was not reproducible from the scripts.)
# usage: verif/scripts/fcov_merge.sh
set -e
export PATH=${VIVADO_BIN:-/home/CAD/2025.2/Vivado/bin}:$PATH
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ALL=$ROOT/build/verif/covall; REP=$ROOT/build/verif/covrep/all
rm -rf $ALL $REP; mkdir -p $ALL/xsim.covdb $REP
n=0
for d in $ROOT/build/verif/cov/*/xsim.covdb/*/; do
  tag=$(basename "$(dirname "$(dirname "$d")")"); cp -r "$d" "$ALL/xsim.covdb/${tag}__$(basename "$d")"; n=$((n + 1))
done
[ $n -eq 0 ] && { echo "no coverage DBs under build/verif/cov (run regress.py --cov first)"; exit 1; }
cd $ROOT/build/verif      # xcrg writes xcrg.log / xcrg.pb into the working directory
xcrg -cov_db_dir $ALL -report_format text -report_dir $REP > $REP/xcrg_stdout.log 2>&1
mkdir -p $ROOT/verif/reports/cov
cp $REP/functionalCoverageReport/xcrg_func_cov_report.txt $ROOT/verif/reports/cov/functional_merged.txt
echo "merged $n DBs -> verif/reports/cov/functional_merged.txt"
grep -E "Coverage Score|rondo_cov::" $ROOT/verif/reports/cov/functional_merged.txt | head -8
