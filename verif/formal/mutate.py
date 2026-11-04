#!/usr/bin/env python3
"""Mutation sanity for a formal job (plan 2.4.3). usage: mutate.py <job> <task> <dut.v relative to rtl root> <module> [N] [depth_override]
Uses `yosys mutate -list N -seed 1` on the DUT module only, applies each mutation, writes the mutant as Verilog and runs the job's task on it
(SymbiYosys). A mutant is KILLED when sby reports FAIL. Survivors are listed in verif/reports/mutation_<job>.md; each needs a one-line
equivalence/benign argument (written by hand below the table)."""
import os, re, subprocess, sys, shutil, concurrent.futures as cf
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
job, task, dut, mod = sys.argv[1:5]; N = int(sys.argv[5]) if len(sys.argv) > 5 else 30; depth = sys.argv[6] if len(sys.argv) > 6 else None
base = os.path.join(ROOT, "build/verif/formal/fixed", job); W = os.path.join(ROOT, "build/verif/mutate", job); shutil.rmtree(W, ignore_errors=True); os.makedirs(W)
sby0 = open(os.path.join(base, job + ".sby")).read()
# elaborate the job exactly as sby does for this task, then list mutations inside the DUT module(s) only
scr = re.search(rf"^{task}: (read_verilog .*)$", sby0, re.M).group(1); top = re.search(r"^prep -top (\S+)", sby0, re.M).group(1)
files = sby0.split("[files]")[1].split()
os.makedirs(f"{W}/src")
for f in files: shutil.copy(f, f"{W}/src/{os.path.basename(f)}")      # same relative names as sby uses: cell names contain the file name
subprocess.run(["yosys", "-q", "-p", f"{scr}; prep -top {top}; mutate -list {N} -seed 1 -o {W}/list.txt *{mod}*/*"], check=True, capture_output=True, cwd=f"{W}/src")
muts = [l.strip() for l in open(f"{W}/list.txt") if l.strip()]
env = dict(os.environ); env["ABC"] = os.path.join(ROOT, "verif/scripts/abc_wrap.sh")
def one(i):
    m = muts[i]; d = os.path.join(W, f"m{i}"); os.makedirs(d)
    sby = sby0.replace(f"prep -top {top}", f"prep -top {top}\n{m}")
    if depth: sby = re.sub(rf"^({task}: depth) \d+", rf"\1 {depth}", sby, flags=re.M)
    open(os.path.join(d, "m.sby"), "w").write(sby)
    r = subprocess.run(["timeout", os.environ.get("MUT_TIMEOUT", "300"), "sby", "-f", "m.sby", task], cwd=d, env=env, capture_output=True, text=True)
    st = open(os.path.join(d, f"m_{task}/status")).read().split()[0] if os.path.exists(os.path.join(d, f"m_{task}", "status")) else "TIMEOUT/ERROR"
    return i, m, st
res = []
with cf.ThreadPoolExecutor(int(os.environ.get("MUT_J", "10"))) as ex:
    for r in ex.map(one, range(len(muts))): res.append(r)
killed = [r for r in res if r[2] == "FAIL"]; surv = [r for r in res if r[2] != "FAIL"]
out = os.path.join(ROOT, f"verif/reports/mutation_{job}.md")
with open(out, "w") as f:
    f.write(f"# Mutation sanity: {job}/{task} on {dut} ({mod}), yosys mutate -list {N} -seed 1" + (f", depth {depth}" if depth else "") + "\n\n")
    f.write(f"{len(res)} mutants, killed {len(killed)} ({100 * len(killed) / max(1, len(res)):.0f}%), survived/other {len(surv)}\n\n| # | result | mutation |\n|---|---|---|\n")
    for i, m, st in res: f.write(f"| {i} | {st} | `{m[:150]}` |\n")
    f.write("\nSurvivor arguments (benign/equivalent), to be filled by hand: see below.\n")
print(f"{job}: {len(killed)}/{len(res)} killed -> {out}")
