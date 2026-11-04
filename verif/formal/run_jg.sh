#!/bin/bash
# Run JasperGold for the formal jobs. UNTESTED HERE (no Cadence tools on this machine).
# usage: run_jg.sh [--prefix] [job[_task] ...]     default: every verif/formal/jg/*.tcl
# Needs `jg` (or JG=jaspergold) on PATH and a license. One batch session per Tcl file; logs in build/verif/jg/<tag>/.
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd $HERE/../.. && pwd); JG=${JG:-jg}
export VERIF_ROOT=$ROOT; TAG=fixed
if [ "$1" = "--prefix" ]; then shift; export RTL_ROOT=$ROOT/build/verif/rtl_prefix; TAG=prefix; fi
python3 $HERE/gen_jobs.py --tag $TAG ${RTL_ROOT:+--rtl-root $RTL_ROOT} > /dev/null
OUT=$ROOT/build/verif/jg/$TAG; mkdir -p $OUT
list=("$@"); [ ${#list[@]} -eq 0 ] && list=($(ls $HERE/jg/*.tcl | xargs -n1 basename | sed 's/\.tcl$//'))
for n in "${list[@]}"; do
  ( cd $OUT && $JG -no_gui -allow_unsupported_OS -tcl $HERE/jg/$n.tcl > $n.log 2>&1; echo "$n rc=$?" ) &
  while [ $(jobs -r | wc -l) -ge ${JG_PAR:-4} ]; do sleep 5; done
done; wait
# summary: every log must end with a property summary block (see TOOLS.md for the expected counts)
for n in "${list[@]}"; do echo "== $n"; grep -E "proven|cex|covered|unreachable|undetermined|assertions|covers" $OUT/$n.log | tail -6; done
