# JasperGold script for job 'dev_bus', task 'canary' (expected: FAIL). UNTESTED here: no Cadence tools on this machine.
# Same RTL files, same harness (dev_bus_f.v), same top (dev_bus_f), same defines as the SymbiYosys task (verif/formal/gen_jobs.py is the single source).
# usage: VERIF_ROOT=<repo> [RTL_ROOT=<rtl root>] jg -no_gui -allow_unsupported_OS -tcl verif/formal/jg/dev_bus_canary.tcl
set VERIF_ROOT $::env(VERIF_ROOT)
set RTL_ROOT [expr {[info exists ::env(RTL_ROOT)] ? $::env(RTL_ROOT) : $VERIF_ROOT}]
clear -all
analyze -sv12 -define FORMAL -define CANARY +incdir+[file join $RTL_ROOT rtl/chip] \
  [file join $VERIF_ROOT verif/formal/jobs/dev_bus/dev_bus_f.v] [file join $VERIF_ROOT verif/formal/jobs/dev_bus/rondo_layers_abs.v] [file join $RTL_ROOT rtl/chip/rondo_dev.v] [file join $RTL_ROOT rtl/chip/rondo_tile.v] [file join $RTL_ROOT rtl/chip/rondo_tbuf.v] [file join $RTL_ROOT rtl/chip/rondo_ps.v] [file join $RTL_ROOT rtl/chip/rondo_regs.v] [file join $RTL_ROOT rtl/chip/rondo_seq.v] [file join $RTL_ROOT rtl/chip/rondo_cksum.v] [file join $RTL_ROOT rtl/chip/rondo_wmem.v] [file join $RTL_ROOT rtl/chip/rondo_wpack.v] [file join $RTL_ROOT rtl/chip/rondo_sram_sp.v] [file join $RTL_ROOT rtl/chip/rondo_rbus_arb.v] [file join $RTL_ROOT rtl/chip/rondo_dbgmux.v] [file join $RTL_ROOT rtl/chip/rondo_trace.v] [file join $RTL_ROOT rtl/chip/rondo_kat.v] [file join $RTL_ROOT rtl/chip/sva/rondo_sva_rbus.v] [file join $RTL_ROOT rtl/chip/sva/rondo_sva_seq.v]
elaborate -top dev_bus_f
clock clk
reset -none          ;# harnesses drive their own reset ('init' register with an initial value)
set_proofgrid_per_engine_max_jobs 4
set_prove_time_limit 4h
# bounded task in SBY (20 steps); JG engines may prove it outright
prove -all
report -summary
# expected: at least one assert falsified (canary / mutant)
exit
