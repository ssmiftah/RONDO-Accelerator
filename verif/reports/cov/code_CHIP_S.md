# Code coverage (xsim sbct), build CHIP_S, merged over the test list of cc_regress.sh (seed 1)

| file | statement % | branch % | condition % | toggle % | statements |
|---|---|---|---|---|---|
| rondo_chip_top.v | 100 | 100 | 100 | 49.61 | 11 |
| rondo_clk_mux.v | 100 | 83.3333 | 83.3333 | 100 | 10 |
| rondo_clkdiv.v | 100 | 100 | 100 | 81.81 | 6 |
| rondo_spi_slave.v | 0 | 0 | 0 | 100 | 0 |
| rondo_spi_phy.v | 100 | 90.9091 | 95 | 100 | 66 |
| rondo_spi_ctrl.v | 94.4444 | 91.0256 | 88.3721 | 79.1 | 180 |
| rondo_dev.v | 80 | 75.4386 | 92.3077 | 60.86 | 140 |
| rondo_regs.v | 98.8235 | 82.5581 | 64.6154 | 27.72 | 340 |
| rondo_seq.v | 96.8421 | 81.7204 | 73.2394 | 42.7 | 285 |
| rondo_cksum.v | 88.5246 | 71.4286 | 92.8571 | 74.81 | 61 |
| rondo_wmem.v | 100 | 100 | 100 | 99.62 | 3 |
| rondo_wpack.v | 99.2063 | 97.8261 | 88.8889 | 93.13 | 126 |
| rondo_layers.v | 0 | 100 | 100 | 77.04 | 0 |
| rondo_tile.v | 79.7101 | 54.902 | 66.2791 | 15.36 | 138 |
| rondo_tbuf.v | 0 | 0 | 0 | 88.23 | 0 |
| rondo_ps.v | 91.8919 | 75 | 83.3333 | 1.26 | 37 |
| rondo_trace.v | 68.6275 | 51.2195 | 29.1667 | 2.32 | 102 |
| rondo_kat.v | 89.7638 | 74.6479 | 80.9524 | 72.84 | 254 |
| rondo_rbus_arb.v | 95 | 70.8333 | 90 | 42.85 | 20 |
| rondo_reset_sync.v | 100 | 75 | 75 | 100 | 3 |
| rondo_icg.v | 100 | 100 | 100 | 100 | 2 |
| rondo_sync.v | 100 | 100 | 100 | 5.88 | 6 |
| rondo_sram_sp.v | 100 | 86.6667 | 0 | 35.94 | 100 |
| rondo_dbgmux.v | 100 | 100 | 100 | 100 | 9 |

rtl/chip (excluding sva, 24 files): statement 92.2% (weighted by statement count), branch 77.6%, condition 75.1%, toggle 64.6% (unweighted means of the per-file scores).
