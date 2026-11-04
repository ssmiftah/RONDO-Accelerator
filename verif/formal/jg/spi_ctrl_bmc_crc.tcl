# JasperGold script for job 'spi_ctrl', task 'bmc_crc' (expected: PASS). UNTESTED here: no Cadence tools on this machine.
# Same RTL files, same harness (spi_ctrl_f.v), same top (spi_ctrl_f), same defines as the SymbiYosys task (verif/formal/gen_jobs.py is the single source).
# usage: VERIF_ROOT=<repo> [RTL_ROOT=<rtl root>] jg -no_gui -allow_unsupported_OS -tcl verif/formal/jg/spi_ctrl_bmc_crc.tcl
set VERIF_ROOT $::env(VERIF_ROOT)
set RTL_ROOT [expr {[info exists ::env(RTL_ROOT)] ? $::env(RTL_ROOT) : $VERIF_ROOT}]
clear -all
analyze -sv12 -define FORMAL -define GAPN=2 -define SPI_F_CRC=1 -define SPI_F_DATA0 +incdir+[file join $RTL_ROOT rtl/chip] \
  [file join $VERIF_ROOT verif/formal/jobs/spi_ctrl/spi_ctrl_f.v] [file join $RTL_ROOT rtl/chip/rondo_spi_ctrl.v]
elaborate -top spi_ctrl_f
clock clk
reset -none          ;# harnesses drive their own reset ('init' register with an initial value)
set_proofgrid_per_engine_max_jobs 4
set_prove_time_limit 4h
# bounded task in SBY (28 steps); JG engines may prove it outright
prove -all
report -summary
# expected: every assert proven (or bounded-proven), every cover covered
exit
