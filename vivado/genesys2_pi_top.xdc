# Pmod pins for rtl/chip/genesys2_pi_top.v (Raspberry Pi 5 SPI host, spec 13.25).
#
# VERIFIED against Digilent's Genesys-2-Master.xdc (https://github.com/Digilent/digilent-xdc, file Genesys-2-Master.xdc, Rev. H,
# fetched 2026-11-02): ja[0..7] = U27 U28 T26 T27 T22 T23 T20 T21 (Pmod JA pins 1,2,3,4,7,8,9,10), jb[0..1] = V29 V30
# (Pmod JB pins 1,2); all LVCMOS33. The spec's table (JA1 U27 ... JA10 T21) matches; JB1/JB2 taken from the master XDC.
#
# Pmod pin -> signal -> Raspberry Pi 5 header pin (BCM):
#   JA1  U27 ja_cs_n    (PULLUP)   24 (GPIO8, SPI0 CE0)
#   JA2  U28 ja_mosi               19 (GPIO10)
#   JA3  T26 ja_miso               21 (GPIO9)
#   JA4  T27 ja_sclk               23 (GPIO11)
#   JA7  T22 ja_irq                22 (GPIO25)
#   JA8  T23 ja_busy               18 (GPIO24)
#   JA9  T20 ja_rst_n   (PULLUP)   16 (GPIO23)
#   JA10 T21 ja_clkout             11 (GPIO17)
#   JB1  V29 jb_st_pass            15 (GPIO22)
#   JB2  V30 jb_bist_en (PULLDOWN) 13 (GPIO27)
#   JA5/JA11, JB5/JB11 = GND (Pi pins 6, 9, 14, 20); JA6/JA12 and JB6/JB12 = 3.3 V: do NOT connect to the Pi.
# Common ground between Pi and board is required. The Pi header is 3.3 V, the Pmod banks are 3.3 V: no level shifting.

set_property -dict { PACKAGE_PIN U27 IOSTANDARD LVCMOS33 PULLUP true   } [get_ports { ja_cs_n }]
set_property -dict { PACKAGE_PIN U28 IOSTANDARD LVCMOS33              } [get_ports { ja_mosi }]
set_property -dict { PACKAGE_PIN T26 IOSTANDARD LVCMOS33 DRIVE 8 SLEW FAST } [get_ports { ja_miso }]
set_property -dict { PACKAGE_PIN T27 IOSTANDARD LVCMOS33              } [get_ports { ja_sclk }]
set_property -dict { PACKAGE_PIN T22 IOSTANDARD LVCMOS33 DRIVE 8      } [get_ports { ja_irq }]
set_property -dict { PACKAGE_PIN T23 IOSTANDARD LVCMOS33 DRIVE 8      } [get_ports { ja_busy }]
set_property -dict { PACKAGE_PIN T20 IOSTANDARD LVCMOS33 PULLUP true   } [get_ports { ja_rst_n }]
set_property -dict { PACKAGE_PIN T21 IOSTANDARD LVCMOS33 DRIVE 8      } [get_ports { ja_clkout }]
set_property -dict { PACKAGE_PIN V29 IOSTANDARD LVCMOS33 DRIVE 8      } [get_ports { jb_st_pass }]
set_property -dict { PACKAGE_PIN V30 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { jb_bist_en }]

# All Pmod signals are asynchronous to the core clock (the SPI pins are oversampled by the RTL, spec 5.6).
set_false_path -from [get_ports { ja_cs_n ja_mosi ja_sclk ja_rst_n jb_bist_en }]
set_false_path -to   [get_ports { ja_miso ja_irq ja_busy ja_clkout jb_st_pass }]
