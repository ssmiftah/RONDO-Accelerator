# Mutation sanity: regs/prove on x (rondo_regs), yosys mutate -list 30 -seed 1

30 mutants, killed 8 (27%), survived/other 22

| # | result | mutation |
|---|---|---|
| 0 | PASS | `mutate -mode cnot1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procdff$6398 -port Q -portbit 15 -ctrlbit 9 -wire irq_e` |
| 1 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5891_CMP0 -port A -portbit 4 -src /home/samit/` |
| 2 | FAIL | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5744 -port S -portbit 0 -src /home/samit/PhD/P` |
| 3 | PASS | `mutate -mode cnot1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 272 -ctrlbit 1545 -wire k` |
| 4 | FAIL | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5785 -port Y -portbit 3 -ctrlbit 5 -src /home/s` |
| 5 | FAIL | `mutate -mode const1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5928_CMP0 -port A -portbit 1 -src /home/samit/` |
| 6 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$4482 -port A -portbit 0 -src /home/samit/PhD/P` |
| 7 | PASS | `mutate -mode const1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5885_CMP0 -port A -portbit 1 -src /home/samit/` |
| 8 | PASS | `mutate -mode const1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 698 -wire sr_pass_cksum ` |
| 9 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5880 -port A -portbit 0 -wire clk_div -wirebit` |
| 10 | PASS | `mutate -mode cnot1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 298 -ctrlbit 827 -wire ka` |
| 11 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5477 -port A -portbit 20 -src /home/samit/PhD/` |
| 12 | PASS | `mutate -mode cnot1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5505 -port B -portbit 22 -ctrlbit 29 -src /home` |
| 13 | FAIL | `mutate -mode inv -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5100 -port Y -portbit 0 -src /home/samit/PhD/Proj` |
| 14 | PASS | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 1172 -ctrlbit 1453 -wire ` |
| 15 | PASS | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 801 -ctrlbit 236 -wire sr` |
| 16 | FAIL | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5460 -port A -portbit 13 -ctrlbit 4 -src /home/` |
| 17 | PASS | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procdff$6413 -port Q -portbit 5 -ctrlbit 16 -wire irq_s` |
| 18 | PASS | `mutate -mode const1 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 745 -wire sr_done_cnt -w` |
| 19 | ERROR | `mutate -mode inv -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $ternary$/home/samit/PhD/Projects/IBM_CoFrNets/CoFrNet-RPI` |
| 20 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$4302 -port A -portbit 0 -src /home/samit/PhD/P` |
| 21 | FAIL | `mutate -mode inv -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5434 -port Y -portbit 22 -src /home/samit/PhD/Pro` |
| 22 | PASS | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5693 -port Y -portbit 0 -ctrlbit 1 -src /home/s` |
| 23 | FAIL | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procdff$6487 -port Q -portbit 26 -ctrlbit 11 -wire shd0` |
| 24 | FAIL | `mutate -mode cnot0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procdff$6318 -port Q -portbit 28 -ctrlbit 12 -wire tile` |
| 25 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 400 -wire st_status -wir` |
| 26 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5299 -port B -portbit 18 -wire busy_cyc -wireb` |
| 27 | PASS | `mutate -mode inv -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$1704 -port B -portbit 0 -src /home/samit/PhD/Proj` |
| 28 | PASS | `mutate -mode const0 -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5883 -port B -portbit 420 -wire trc_status -wi` |
| 29 | PASS | `mutate -mode inv -module $paramod$1d10a6f619273ec7b8b6eb03cb13dfb5fee444c8\rondo_regs -cell $procmux$5503 -port B -portbit 27 -src /home/samit/PhD/Pro` |

Survivor arguments (benign/equivalent), to be filled by hand: see below.
