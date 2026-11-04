#!/usr/bin/env python3
"""Single source for every formal job. Emits, from the same tables:
  * SymbiYosys files   build/verif/formal/<tag>/<job>/<job>.sby              (run_formal.sh)
  * JasperGold scripts verif/formal/jg/<job>_<task>.tcl                      (run_jg.sh, UNTESTED here: no Cadence tools)
usage: gen_jobs.py [--rtl-root DIR] [--tag TAG]   (default: fixed tree, tag 'fixed'; --rtl-root build/verif/rtl_prefix --tag prefix)
File spec: 'R:<path>' = relative to the RTL root (rtl/chip/...), 'H:<path>' = relative to verif/formal/jobs/<job>/ , 'V:<path>' relative to verif/formal.
"""
import argparse, os, sys, textwrap
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
ap = argparse.ArgumentParser(); ap.add_argument("--rtl-root", default=ROOT); ap.add_argument("--tag", default="fixed"); ap.add_argument("--no-jg", action="store_true")
a = ap.parse_args(); RR = os.path.abspath(a.rtl_root)
PDR, YICES, Z3 = "abc pdr", "smtbmc yices", "smtbmc z3"
C = "R:rtl/chip/"; SVA = C + "sva/"

def T(mode, depth=None, eng=(YICES,), defs=(), expect="PASS", note="", jg_only=False):
    return dict(mode=mode, depth=depth, eng=list(eng), defs=list(defs), expect=expect, note=note, jg_only=jg_only)

JOBS = {
 "regs": dict(top="regs_f", prefix_defs=["PREFIX"], files=["H:regs_f.v", C+"rondo_regs.v", SVA+"rondo_sva_regs.v"], canary="cmd_start",
   tasks={"prove": T("prove", 12, (PDR, YICES)), "cover": T("cover", 16), "canary": T("bmc", 8, defs=["CANARY"], expect="FAIL")},
   note="k-induction (legacy depth 12) / PDR; legacy properties plus the fix-round shadow property"),
 "spi_ctrl": dict(top="spi_ctrl_f", files=["H:spi_ctrl_f.v", C+"rondo_spi_ctrl.v"], canary="issue && rb_req_we && reqs == 17'd0",
   tasks={"bmc_nocrc": T("bmc", 34, defs=["GAPN=2", "SPI_F_CRC=0", "SPI_F_DATA0"], note="BMC bounded (solver limit)"),
          "bmc_crc": T("bmc", 28, defs=["GAPN=2", "SPI_F_CRC=1", "SPI_F_DATA0"], note="BMC bounded (solver limit)"),
          "cover": T("cover", 160, defs=["GAPN=4"]),
          "pdr": T("prove", 40, (PDR,), defs=["GAPN=2", "SPI_F_CRC=0", "SPI_F_DATA0"], expect="ANY", note="attempt: unbounded proof (PDR); UNKNOWN is acceptable here, JG-only full-strength file covers this"),
          "mutant_nocrc": T("bmc", 34, defs=["GAPN=2", "SPI_F_CRC=0", "SPI_F_DATA0", "SPI_F_MUTANT"], expect="FAIL"),
          "canary": T("bmc", 34, defs=["GAPN=2", "SPI_F_CRC=0", "SPI_F_DATA0", "CANARY"], expect="FAIL")},
   note="F1: BMC only; see jg/ full-strength table"),
 "spi_phy": dict(top="spi_phy_f", files=["H:spi_phy_f.v", C+"rondo_spi_phy.v", C+"rondo_sync.v"], canary="1'b1",
   tasks={"bmc": T("bmc", 200), "cover": T("cover", 200), "canary": T("bmc", 20, defs=["CANARY"], expect="FAIL")}),
 "seq": dict(top="seq_f", prefix_defs=["PREFIX"], files=["H:seq_f.v", C+"rondo_seq.v", C+"rondo_cksum.v", SVA+"rondo_sva_seq.v"], canary="kat_fail",
   tasks={"bmc": T("bmc", 70), "cover": T("cover", 70), "canary": T("bmc", 70, defs=["CANARY"], expect="FAIL")}),
 "tile": dict(top="tile_f", files=["H:tile_f.v", C+"rondo_tile.v"], canary="ev_final",
   tasks={"bmc": T("bmc", 60), "cover": T("cover", 60), "canary": T("bmc", 60, defs=["CANARY"], expect="FAIL")}),
 "dev_bus": dict(top="dev_bus_f", files=["H:dev_bus_f.v", "H:rondo_layers_abs.v"] + [C + f for f in
        "rondo_kat_sigs.vh rondo_dev.v rondo_tile.v rondo_tbuf.v rondo_ps.v rondo_regs.v rondo_seq.v rondo_cksum.v rondo_wmem.v rondo_wpack.v rondo_sram_sp.v rondo_rbus_arb.v rondo_dbgmux.v rondo_trace.v rondo_kat.v".split()] + [SVA+"rondo_sva_rbus.v", SVA+"rondo_sva_seq.v"], canary="1'b1",
   tasks={"bmc": T("bmc", 60), "cover": T("cover", 60), "canary": T("bmc", 20, defs=["CANARY"], expect="FAIL")}),
}
JG_ONLY = {   # full-strength versions for JasperGold only (SBY could not do them); listed in verif/TOOLS.md
 "spi_ctrl": {"jg_prove_full": T("prove", None, defs=["GAPN=2"], note="UNBOUNDED proof, CRC free (anyconst), payload free (no SPI_F_DATA0), all properties; SBY: bmc 34/28 only", jg_only=True),
              "jg_prove_gap1": T("prove", None, defs=["GAPN=1"], note="tightest byte spacing that keeps the rbus handshake legal", jg_only=True),
              "jg_cover_full": T("cover", None, defs=["GAPN=2"], note="all covers with payload free and CRC free", jg_only=True)},
 "seq": {"jg_prove_unbounded": T("prove", None, note="SBY: BMC 70 only (needs invariants over the sequencer counters)", jg_only=True)},
 "tile": {"jg_prove_unbounded": T("prove", None, note="SBY: BMC 60 only", jg_only=True)},
 "dev_bus": {"jg_prove_unbounded": T("prove", None, note="SBY: BMC 60 only (integration backstop)", jg_only=True)},
 "spi_phy": {"jg_prove_unbounded": T("prove", None, note="SBY: BMC 200 only", jg_only=True)},
}
for _j, _t in JG_ONLY.items():
    JOBS[_j]["tasks"].update(_t)
try:
    sys.path.insert(0, HERE); import jobs_extra; JOBS.update(jobs_extra._mk(globals()))
except ImportError:
    pass

def resolve(job, spec, rr=RR):
    k, p = spec.split(":", 1)
    return {"R": os.path.join(rr, p), "H": os.path.join(HERE, "jobs", job, p), "V": os.path.join(HERE, p)}[k]

def with_canary(job, spec):
    return spec

out = os.path.join(ROOT, "build", "verif", "formal", a.tag); os.makedirs(out, exist_ok=True)
for name, j in JOBS.items():
    d = os.path.join(out, name); os.makedirs(d, exist_ok=True)
    files = [resolve(name, f) for f in j["files"]]
    # canary: appended to the harness copy
    harness = files[0]; txt = open(harness).read()
    if "canary" in j and "CANARY" not in txt:
        cond = j["canary"]
        add = f"\n`ifdef CANARY\n    always @* if (!init && ({cond})) assert (1'b0);   // canary: reachable, must FAIL\n`endif\n"
        idx = txt.rindex("endmodule"); txt = txt[:idx] + add + txt[idx:]
        if harness.startswith(HERE): open(harness, "w").write(txt)     # committed once (the JG scripts use the same file)
    hcopy = os.path.join(d, os.path.basename(harness)); open(hcopy, "w").write(txt)
    files[0] = hcopy
    sby_tasks = {t: s_ for t, s_ in j["tasks"].items() if not s_["jg_only"]}
    lines = ["[tasks]"] + list(sby_tasks) + ["", "[options]"]
    for t, s in sby_tasks.items():
        lines.append(f"{t}: mode {s['mode']}")
        if s["depth"]: lines.append(f"{t}: depth {s['depth']}")
        if s["mode"] == "prove" and s["depth"]: pass
    lines += ["", "[engines]"]
    for t, s in sby_tasks.items():
        for e in s["eng"]: lines.append(f"{t}: {e}")
    lines += ["", "[script]"]
    for t, s in sby_tasks.items():
        defs = " ".join("-D" + x for x in ["FORMAL"] + s["defs"] + (j.get("prefix_defs", []) if a.tag == "prefix" else []))
        lines.append(f"{t}: read_verilog -sv -formal {defs} " + " ".join(os.path.basename(f) for f in files if not f.endswith(".vh")))
    lines += ["prep -top " + j["top"], "async2sync", "", "[files]"] + files
    open(os.path.join(d, name + ".sby"), "w").write("\n".join(lines) + "\n")
    meta = ["# job task mode depth expect note"] + [f"{name} {t} {s['mode']} {s['depth'] or 0} {s['expect']} {s['note'].replace(' ', '_') or '-'}" for t, s in sby_tasks.items()]
    open(os.path.join(d, "tasks.txt"), "w").write("\n".join(meta) + "\n")
    if a.no_jg: continue
    jg = os.path.join(HERE, "jg"); os.makedirs(jg, exist_ok=True)
    jgfiles = [f"[file join $::env(VERIF_ROOT) verif/formal/jobs/{name}/{os.path.basename(harness)}]" if f.startswith(HERE) else "" for f in []]
    for t, s in j["tasks"].items():
        if s["mode"] == "bmc" and t == "canary": pass
        fl = []
        for spec in j["files"]:
            k, p = spec.split(":", 1)
            if p.endswith(".vh"): continue      # include-only file: found through +incdir+ (check round fix), not analyzed as a unit
            fl.append({"R": f"[file join $RTL_ROOT {p}]", "H": f"[file join $VERIF_ROOT verif/formal/jobs/{name}/{p}]", "V": f"[file join $VERIF_ROOT verif/formal/{p}]"}[k])
        defs = " ".join("-define " + x for x in ["FORMAL"] + s["defs"] + (j.get("prefix_defs", []) if a.tag == "prefix" else []))
        canary = ""
        tcl = f"""# JasperGold script for job '{name}', task '{t}' (expected: {s['expect']}). UNTESTED here: no Cadence tools on this machine.
# Same RTL files, same harness ({os.path.basename(harness)}), same top ({j['top']}), same defines as the SymbiYosys task (verif/formal/gen_jobs.py is the single source).
# usage: VERIF_ROOT=<repo> [RTL_ROOT=<rtl root>] jg -no_gui -allow_unsupported_OS -tcl verif/formal/jg/{name}_{t}.tcl
set VERIF_ROOT $::env(VERIF_ROOT)
set RTL_ROOT [expr {{[info exists ::env(RTL_ROOT)] ? $::env(RTL_ROOT) : $VERIF_ROOT}}]
clear -all
analyze -sv12 {defs} +incdir+[file join $RTL_ROOT rtl/chip] \\
  {' '.join(fl)}
elaborate -top {j['top']}
clock clk
reset -none          ;# harnesses drive their own reset ('init' register with an initial value)
set_proofgrid_per_engine_max_jobs 4
set_prove_time_limit 4h
{'# bounded task in SBY (' + str(s['depth']) + ' steps); JG engines may prove it outright' if s['mode'] == 'bmc' else ''}
prove -all
report -summary
# expected: {'every assert proven (or bounded-proven), every cover covered' if s['expect'] == 'PASS' else ('at least one assert falsified (canary / mutant)' if s['expect'] == 'FAIL' else 'any')}
exit
"""
        open(os.path.join(jg, f"{name}_{t}.tcl"), "w").write(tcl)
print("generated", len(JOBS), "jobs ->", out)
