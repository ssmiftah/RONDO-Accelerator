# JasperGold script for job 'arb', task 'cover' (expected: PASS). UNTESTED here: no Cadence tools on this machine.
# Same RTL files, same harness (arb_f.v), same top (arb_f), same defines as the SymbiYosys task (verif/formal/gen_jobs.py is the single source).
# usage: VERIF_ROOT=<repo> [RTL_ROOT=<rtl root>] jg -no_gui -allow_unsupported_OS -tcl verif/formal/jg/arb_cover.tcl
set VERIF_ROOT $::env(VERIF_ROOT)
set RTL_ROOT [expr {[info exists ::env(RTL_ROOT)] ? $::env(RTL_ROOT) : $VERIF_ROOT}]
clear -all
analyze -sv12 -define FORMAL +incdir+[file join $RTL_ROOT rtl/chip] \
  [file join $VERIF_ROOT verif/formal/jobs/arb/arb_f.v] [file join $RTL_ROOT rtl/chip/rondo_rbus_arb.v]
elaborate -top arb_f
clock clk
reset -none          ;# harnesses drive their own reset ('init' register with an initial value)
set_proofgrid_per_engine_max_jobs 4
set_prove_time_limit 4h

prove -all
report -summary
# expected: every assert proven (or bounded-proven), every cover covered
exit
