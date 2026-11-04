#!/usr/bin/env python3
"""Regression runner. usage: regress.py --tier smoke|nightly|signoff [--sim xsim|xcelium] [-j N] [--prefix] [--cov] [--tests a,b]
xsim: builds each (top,cfg) snapshot once (xsim_build.sh) and runs tests in parallel (xsim_run.sh).
xcelium (UNTESTED here): verif/uvm/scripts/run_xcelium.sh build/run; coverage merge with IMC.
Writes verif/reports/summary_<tier>[_prefix][_<sim>].md and prints the table. Known-failing tests (testlist.json "known_fail") are reported separately."""
import argparse, json, os, subprocess, sys, concurrent.futures as cf, time, shutil
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ap = argparse.ArgumentParser()
ap.add_argument("--tier", default="smoke"); ap.add_argument("--sim", default="xsim", choices=["xsim", "xcelium"]); ap.add_argument("-j", type=int, default=12)
ap.add_argument("--prefix", action="store_true"); ap.add_argument("--cov", action="store_true"); ap.add_argument("--tests", default=""); ap.add_argument("--seeds", default="")
a = ap.parse_args()
tl = json.load(open(os.path.join(ROOT, "verif/scripts/testlist.json"))); tier = tl["tiers"][a.tier]
seeds = [int(x) for x in a.seeds.split(",")] if a.seeds else tier["seeds"]
sel = set(a.tests.split(",")) if a.tests else None
jobs = []
for t in tl["tests"]:
    if sel and t["test"] not in sel: continue
    if "only" in tier and t["test"] not in tier["only"]: continue
    for top, cfg in t["runs"]:
        if "cfgs" in tier and cfg not in tier["cfgs"]: continue
        if "tops" in tier and top not in tier["tops"]: continue
        if cfg in tier.get("skip_cfgs", []): continue
        for s in seeds: jobs.append((t["test"], top, cfg, s, [x.replace("@ROOT@", ROOT).replace("@HOSTTAG@", "prefix" if a.prefix else "fixed") for x in t.get("args", [])], t.get("known_fail")))
rr = os.path.join(ROOT, "build/verif/rtl_prefix") if a.prefix else ROOT
htag = "prefix" if a.prefix else "fixed"
# B4: record the host library frame log (fixed or pre-fix host tree) for u_b4_host_replay
host_root = os.path.join(ROOT, "build/verif/host_prefix") if a.prefix else os.path.join(ROOT, "host")
subprocess.run([os.path.join(ROOT, ".venv-rtl/bin/python"), "-I", os.path.join(ROOT, "verif/cocotb/b4_frames.py"), os.path.join(ROOT, f"build/verif/b4_{htag}.log")], env=dict(os.environ, HOST_ROOT=host_root), capture_output=True)
env = dict(os.environ); env["PATH"] = os.environ.get("VIVADO_BIN", "/home/CAD/2025.2/Vivado/bin") + ":" + env["PATH"]
if a.cov: env["COV"] = "1"
builds = sorted({(top, cfg) for _, top, cfg, _, _, _ in jobs})
def tag(top, cfg): return f"tb_top_{top}_{cfg}" + ("_prefix" if a.prefix else "")
def build(tc):
    top, cfg = tc; e = dict(env); e["TOPSEL"] = top
    if a.sim == "xsim":
        r = subprocess.run([f"{ROOT}/verif/scripts/xsim_build.sh", "tb_top", cfg, rr], env=e, capture_output=True, text=True)
    else:
        r = subprocess.run([f"{ROOT}/verif/uvm/scripts/run_xcelium.sh", "build", top, cfg, rr], env=e, capture_output=True, text=True)
    return tc, r.returncode, (r.stdout + r.stderr)[-300:]
def run(j):
    test, top, cfg, s, args, kf = j
    t0 = time.time()
    if a.sim == "xsim": cmd = [f"{ROOT}/verif/scripts/xsim_run.sh", tag(top, cfg), test, str(s)] + ["+" + x for x in args]
    else: cmd = [f"{ROOT}/verif/uvm/scripts/run_xcelium.sh", "run", tag(top, cfg), test, str(s)] + ["+" + x for x in args]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    line = (r.stdout.strip().splitlines() or ["FAIL (no output)"])[-1]
    return j, line, time.time() - t0
t0 = time.time()
print(f"{len(jobs)} runs, {len(builds)} builds, sim={a.sim}, tier={a.tier}, rtl={'prefix' if a.prefix else 'fixed'}", flush=True)
with cf.ThreadPoolExecutor(min(a.j, 8)) as ex:
    bres = list(ex.map(build, builds))
bad_b = [b for b in bres if b[1] != 0]
for b in bad_b: print("BUILD FAIL", b[0], b[2])
ok_builds = {b[0] for b in bres if b[1] == 0}
jobs = [j for j in jobs if (j[1], j[2]) in ok_builds]
res = []
with cf.ThreadPoolExecutor(a.j) as ex:
    for r in ex.map(run, jobs): res.append(r); print(r[1], f"({r[2]:.0f}s)", flush=True)
npass = sum(1 for r in res if r[1].startswith("PASS")); nfail = len(res) - npass
unexp = [r for r in res if not r[1].startswith("PASS") and not r[0][5]]
known = [r for r in res if not r[1].startswith("PASS") and r[0][5]]
suffix = ("_prefix" if a.prefix else "") + ("" if a.sim == "xsim" else "_xcelium")
out = os.path.join(ROOT, f"verif/reports/summary_{a.tier}{suffix}.md"); os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    f.write(f"# UVM regression summary: tier {a.tier}, {a.sim}, {'pre-fix' if a.prefix else 'fixed'} RTL ({time.strftime('%F %T')})\n\n")
    f.write(f"{len(res)} runs: {npass} pass, {len(unexp)} unexpected failures, {len(known)} known failures (listed in BUGS.md); wall {time.time() - t0:.0f} s\n\n| test | top | cfg | seed | result | known |\n|---|---|---|---|---|---|\n")
    for (test, top, cfg, s, args, kf), line, dt in sorted(res):
        f.write(f"| {test} | {top} | {cfg} | {s} | {line.split()[0]} | {kf or ''} |\n")
    if bad_b: f.write("\nBUILD FAILURES: " + ", ".join(str(b[0]) for b in bad_b) + "\n")
print(f"\n{npass}/{len(res)} pass; unexpected failures: {len(unexp)}; known failures: {len(known)}; wrote {out}")
sys.exit(1 if (unexp or bad_b) else 0)
