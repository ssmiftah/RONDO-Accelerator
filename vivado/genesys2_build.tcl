# Bitstream for the Genesys 2 (Kintex-7 XC7K325T-2FFG900C).
#
# Non-project mode. Vivado resolves $readmemh relative to its launch directory,
# so scripts/g2_build.sh cds into build/genesys2 where the ROM images and the
# reciprocal seed table live before invoking this.
#
# argv: <top> <outdir> <srclist>

set part xc7k325tffg900-2

set top    [lindex $argv 0]
set outdir [lindex $argv 1]
set flist  [lindex $argv 2]
file mkdir $outdir

if {[llength [get_parts $part]] == 0} {
    puts "FATAL: part $part is not installed in this Vivado."
    puts "FATAL: add it with /home/samit/CAD/.xinstall/2025.2/xsetup"
    puts "FATAL:   -> Add Design Tools or Devices -> Kintex-7"
    exit 1
}

set fh [open $flist r]
foreach f [split [string trim [read $fh]] "\n"] {
    if {$f ne ""} { read_verilog -sv $f }
}
close $fh

set incdirs [list ../../rtl ../../rtl/core \
                  ../../rtl/third_party/HardFloat/source \
                  ../../rtl/third_party/HardFloat/source/RISCV]

read_xdc ../../vivado/genesys2.xdc
# Per-top constraints, when the top has pins the shared file cannot carry.
if {[file exists ../../vivado/$top.xdc]} {
    read_xdc ../../vivado/$top.xdc
    puts "RESULT EXTRA_XDC=$top.xdc"
}

synth_design -top $top -part $part -include_dirs $incdirs
write_checkpoint -force $outdir/post_synth.dcp
report_utilization -file $outdir/util_synth.rpt

opt_design

# Fail fast on I/O constraints.
#
# Vivado's NSTD-1 / UCIO-1 checks run at write_bitstream, so a missing
# PACKAGE_PIN costs a full place-and-route before it surfaces. That happened
# three times on this design. This check is the same question asked in seconds.
set unconstrained {}
foreach pt [get_ports] {
    # A port with no net is one opt_design has already disconnected; it will be
    # stripped before write_bitstream and needs no pin.
    if {[llength [get_nets -quiet -of_objects $pt]] == 0} { continue }
    if {[get_property -quiet PACKAGE_PIN $pt] eq ""} { lappend unconstrained $pt }
}
if {[llength $unconstrained]} {
    puts "FATAL unconstrained top-level ports: $unconstrained"
    puts "FATAL add them to vivado/genesys2.xdc, or to vivado/$top.xdc if they"
    puts "FATAL exist only in this top. XDC has no `if`: a guarded constraint is"
    puts "FATAL skipped with a CRITICAL WARNING and silently never applies."
    exit 1
}

place_design
phys_opt_design
route_design

write_checkpoint -force $outdir/post_route.dcp
report_utilization       -file $outdir/util_route.rpt
report_timing_summary    -file $outdir/timing.rpt
report_power             -file $outdir/power_vectorless.rpt

# The one number that decides whether the bitstream is trustworthy.
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts "RESULT WNS=$wns WHS=$whs"
if {$wns < 0 || $whs < 0} {
    puts "RESULT TIMING_FAILED -- bitstream written anyway, do not trust results"
}

write_bitstream -force $outdir/$top.bit
puts "RESULT BITSTREAM=$outdir/$top.bit"
quit
