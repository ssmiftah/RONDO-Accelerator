#!/usr/bin/env bash
# T-FORMAL: run every SymbiYosys job (formal/*.sby) and check results.
# usage: scripts/chip_formal.sh [job ...]   (default: regs spi_ctrl spi_phy seq dev_bus tile)
#
# * The task list of a job is read from the [tasks] section of its .sby file (not hard-coded).
# * Each task is labeled by its sby mode: "BMC depth N, bounded" for `mode bmc`, "k-induction depth N" for `mode prove`,
#   "cover depth N" for `mode cover`. A bmc task is never printed as "prove".
# * A task named `mutant`, or any task listed in a header line `# expect-fail: <task> [<task>...]`, passes only if sby reports FAIL
#   (a vacuity check: the harness carries a deliberately false assertion).
# * Cover tasks: every cover must be reached ("Unreached cover" fails) and, if the job has a bmc task, at a step <= that bmc depth
#   (so that the bmc horizon includes the covered behaviors), unless the task is listed in a header line `# cover-exempt: <task>` (a documented
#   exception: spi_ctrl, whose BMC depth is limited by the solver, see formal/spi_ctrl.sby).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/formal"
jobs=("$@"); [ ${#jobs[@]} -eq 0 ] && jobs=(regs spi_ctrl spi_phy seq dev_bus tile)
fail=0

tasks_of() { awk '/^\[tasks\]/{f=1;next} /^\[/{f=0} f && NF && $1 !~ /^#/ {print $1}' "$1"; }
# option value of a task: "<task>: <key> <value>" (preferred) or a plain "<key> <value>" line in [options]
opt_of() {  # file task key
  awk -v t="$2" -v k="$3" '/^\[options\]/{f=1;next} /^\[/{f=0}
       f && $1 == t":" && $2 == k {v=$3} f && $1 == k && g == "" {g=$2} END{print (v != "" ? v : g)}' "$1"
}
expect_fail_of() { grep -E "^# *expect-fail:" "$1" | sed 's/^# *expect-fail://' | tr -s ' ,' '\n\n'; }
cover_exempt_of() { grep -E "^# *cover-exempt:" "$1" | sed 's/^# *cover-exempt://' | tr -s ' ,' '\n\n'; }

for j in "${jobs[@]}"; do
  f="$j.sby"
  bmc_depth=""
  for t in $(tasks_of "$f"); do [ "$(opt_of "$f" "$t" mode)" = "bmc" ] && bmc_depth="$(opt_of "$f" "$t" depth)" && break; done
  for t in $(tasks_of "$f"); do
    mode="$(opt_of "$f" "$t" mode)"; depth="$(opt_of "$f" "$t" depth)"
    case "$mode" in
      bmc)   label="BMC depth $depth, bounded";;
      prove) label="k-induction depth $depth";;
      cover) label="cover depth $depth";;
      *)     label="mode ${mode:-?} depth ${depth:-?}";;
    esac
    xfail=0
    if [ "$t" = "mutant" ] || expect_fail_of "$f" | grep -qx "$t"; then xfail=1; label="$label, expected FAIL"; fi
    out=$(sby -f "$f" "$t" 2>&1)
    res=$(echo "$out" | grep -E "DONE \((PASS|FAIL|UNKNOWN|ERROR)" | tail -1 | sed 's/.*DONE (\([A-Z]*\).*/\1/')
    unreached=$(echo "$out" | grep -c "Unreached cover")
    maxstep=$(echo "$out" | grep -E "reached cover statement" | sed -n 's/.* step \([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)
    ok=0; extra=""
    if [ "$xfail" -eq 1 ]; then
      if [ "$res" = "FAIL" ]; then ok=1; extra=" (failed as required)"; else extra=" (the false assertion was NOT detected: result ${res:-?})"; fi
    elif [ "$res" = "PASS" ] && [ "$unreached" -eq 0 ]; then
      ok=1
      if [ "$mode" = "cover" ]; then
        extra=" (all covers reached, last at step ${maxstep:-?})"
        if cover_exempt_of "$f" | grep -qx "$t"; then extra="$extra, exempt from the bmc-depth rule";
        elif [ -n "$bmc_depth" ] && [ -n "$maxstep" ] && [ "$maxstep" -gt "$bmc_depth" ]; then ok=0; extra=" (cover at step $maxstep > bmc depth $bmc_depth)"; fi
      fi
    else
      extra=" (result ${res:-?}, unreached covers: $unreached)"
    fi
    if [ "$ok" -eq 1 ]; then echo "FORMAL $j/$t ($label): PASS$extra"; else echo "FORMAL $j/$t ($label): FAIL$extra"; fail=1; fi
  done
done
exit $fail
