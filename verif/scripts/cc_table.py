#!/usr/bin/env python3
"""Per-file code-coverage table for rtl/chip from the xcrg HTML code report. usage: cc_table.py <ccrun dir DEV_S|CHIP_S ...>  -> verif/reports/cov/code_<name>.md"""
import re, html, sys, os, subprocess
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
out_all = []
for name in sys.argv[1:]:
    d = os.path.join(ROOT, "build/verif/ccrun", name)
    subprocess.run(["xcrg", "-cc_dir", ".", "-cc_db", "snap", "-report_format", "text", "-report_dir", "rep"], cwd=d, capture_output=True, env=dict(os.environ, PATH=os.environ.get("VIVADO_BIN", "/home/CAD/2025.2/Vivado/bin") + ":" + os.environ["PATH"]))
    t = open(os.path.join(d, "rep/codeCoverageReport/files.html")).read()
    rows = []
    for r in re.findall(r"<tr[^>]*>(.*?)</tr>", t, flags=re.S):
        c = [html.unescape(re.sub(r"<[^>]+>", "", x)).strip() for x in re.findall(r"<t[dh][^>]*>(.*?)</t[dh]>", r, flags=re.S)]
        c = [x for x in c if x != ""]
        if len(c) == 10 and c[0].isdigit(): rows.append(c)
    sel = [c for c in rows if "/rtl/chip/" in c[1] and "/sva/" not in c[1]]
    L = [f"# Code coverage (xsim sbct), build {name}, merged over the test list of cc_regress.sh (seed 1)", "", "| file | statement % | branch % | condition % | toggle % | statements |", "|---|---|---|---|---|---|"]
    for c in sel: L.append(f"| {os.path.basename(c[1])} | {c[4]} | {c[7]} | {c[8]} | {c[9]} | {c[6]} |")
    def wavg(i, w=6): 
        tot = sum(float(c[w]) for c in sel if float(c[w]) > 0)
        return sum(float(c[i]) * float(c[w]) for c in sel if float(c[w]) > 0) / max(tot, 1)
    def mean(i): return sum(float(c[i]) for c in sel) / len(sel)
    L += ["", f"rtl/chip (excluding sva, {len(sel)} files): statement {wavg(4):.1f}% (weighted by statement count), branch {mean(7):.1f}%, condition {mean(8):.1f}%, toggle {mean(9):.1f}% (unweighted means of the per-file scores)."]
    open(os.path.join(ROOT, f"verif/reports/cov/code_{name}.md"), "w").write("\n".join(L) + "\n"); print("\n".join(L[-1:]))
