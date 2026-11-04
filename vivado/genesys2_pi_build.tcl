# Bitstream for the RONDO Pi prototype (genesys2_pi_top) on the Genesys 2 (XC7K325T-2FFG900C).
# Copy of genesys2_build.tcl with a verilog define and the FORMATS generic. Non-project mode.
# argv: <top> <outdir> <srclist> <formats 1|2|3> <define> <synth_only 0|1>
set part xc7k325tffg900-2
set top    [lindex $argv 0]
set outdir [lindex $argv 1]
set flist  [lindex $argv 2]
set formats [lindex $argv 3]
set vdef   [lindex $argv 4]
set synth_only [lindex $argv 5]
file mkdir $outdir

if {[llength [get_parts $part]] == 0} {
    puts "FATAL: part $part is not installed in this Vivado."
    exit 1
}
set fh [open $flist r]
foreach f [split [string trim [read $fh]] "\n"] {
    if {$f ne ""} { read_verilog -sv $f }
}
close $fh

set root [file normalize [file join [file dirname [info script]] ..]]
set incdirs [list $root/rtl $root/rtl/core $root/rtl/chip \
                  $root/rtl/third_party/HardFloat/source $root/rtl/third_party/HardFloat/source/RISCV]

read_xdc $root/vivado/genesys2.xdc
read_xdc $root/vivado/$top.xdc
puts "RESULT EXTRA_XDC=$top.xdc"

synth_design -top $top -part $part -include_dirs $incdirs -verilog_define $vdef \
             -generic FORMATS=$formats
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/util_synth.rpt
puts "RESULT SYNTH_DONE formats=$formats"
if {$synth_only} { quit }

opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $outdir/post_route.dcp
report_utilization    -file $outdir/util_route.rpt
report_timing_summary -file $outdir/timing.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "RESULT WNS=$wns WHS=$whs"
if {$wns < 0 || $whs < 0} { puts "RESULT TIMING_FAILED -- bitstream written anyway, do not trust results" }
write_bitstream -force $outdir/$top.bit
puts "RESULT BITSTREAM=$outdir/$top.bit"
quit
