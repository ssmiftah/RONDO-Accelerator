# Genesys 2 (Digilent), Kintex-7 XC7K325T-2FFG900C.
#
# Every PACKAGE_PIN and IOSTANDARD below is copied verbatim from Digilent's
# Genesys-2-Master.xdc (github.com/Digilent/digilent-xdc). They are NOT guessed:
# a wrong LOC or IOSTANDARD on a clock or a bank can damage the board.
#
# Only the pins this design uses are constrained. sw[0] is `run`, sw[1] selects
# the LED view, cpu_resetn is the active-low reset pushbutton.
#
# Note the bank split on the switches: sw[0] and sw[1] sit in a 1.2 V bank and
# must be LVCMOS12, while the LEDs and cpu_resetn are 3.3 V. Copying one
# IOSTANDARD across all of them is the obvious mistake and it does not build.

# ---- 200 MHz differential system clock -------------------------------------
set_property -dict { PACKAGE_PIN AD12  IOSTANDARD LVDS     } [get_ports { sysclk_p }]
set_property -dict { PACKAGE_PIN AD11  IOSTANDARD LVDS     } [get_ports { sysclk_n }]
create_clock -period 5.000 -name sysclk -waveform {0.000 2.500} [get_ports sysclk_p]

# ---- reset pushbutton -------------------------------------------------------
set_property -dict { PACKAGE_PIN R19   IOSTANDARD LVCMOS33 } [get_ports { cpu_resetn }]

# ---- LEDs -------------------------------------------------------------------
set_property -dict { PACKAGE_PIN T28   IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN V19   IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN U30   IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN U29   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]
set_property -dict { PACKAGE_PIN V20   IOSTANDARD LVCMOS33 } [get_ports { led[4] }]
set_property -dict { PACKAGE_PIN V26   IOSTANDARD LVCMOS33 } [get_ports { led[5] }]
set_property -dict { PACKAGE_PIN W24   IOSTANDARD LVCMOS33 } [get_ports { led[6] }]
set_property -dict { PACKAGE_PIN W23   IOSTANDARD LVCMOS33 } [get_ports { led[7] }]

# ---- switches: sw[0] = run, sw[1] = LED view -------------------------------
# Switches used by only one top live in vivado/genesys2_<top>.xdc, which the
# build script reads when it exists. They cannot be guarded with a Tcl `if` here:
# XDC files do not support control flow, and Vivado skips the whole block with
# only a CRITICAL WARNING, so the constraint silently never applies and the run
# fails DRC after place and route has already completed.
set_property -dict { PACKAGE_PIN G19   IOSTANDARD LVCMOS12 } [get_ports { sw[0] }]
set_property -dict { PACKAGE_PIN G25   IOSTANDARD LVCMOS12 } [get_ports { sw[1] }]

# ---- timing exceptions ------------------------------------------------------
# run, the LED view select and the reset button are asynchronous to the core
# clock and are either synchronised in RTL or read by a human eye.
set_false_path -from [get_ports { sw[0] sw[1] cpu_resetn }]
set_false_path -to   [get_ports { led[*] }]

# ---- configuration ----------------------------------------------------------
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO     [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
