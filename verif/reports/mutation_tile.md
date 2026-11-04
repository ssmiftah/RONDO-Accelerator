# Mutation sanity: tile/bmc on x (rondo_tile), yosys mutate -list 30 -seed 1

30 mutants, killed 4 (13%), survived/other 26

| # | result | mutation |
|---|---|---|
| 0 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $shiftx$rondo_tile.v:109$1036 -port Y -portbit 0 -wire ` |
| 1 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $logic_and$rondo_tile.v:167$1456 -port B -portbit 0 -wi` |
| 2 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $auto$opt_expr.cc:702:replace_const_cells$9577 -port Y ` |
| 3 | PASS | `mutate -mode cnot0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $shiftx$rondo_tile.v:118$1043 -port A -portbit 38 -ctrlb` |
| 4 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $shiftx$rondo_tile.v:118$1043 -port A -portbit 19 -wire` |
| 5 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $logic_not$rondo_tile.v:164$1315 -port A -portbit 0 -sr` |
| 6 | PASS | `mutate -mode cnot1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $auto$opt_expr.cc:702:replace_const_cells$9593 -port Y -` |
| 7 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $ternary$rondo_tile.v:91$1630 -port Y -portbit 13 -src ` |
| 8 | PASS | `mutate -mode cnot0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8920 -port B -portbit 4 -ctrlbit 1 -src rondo_t` |
| 9 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8773 -port B -portbit 31 -src rondo_tile.v:166` |
| 10 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$9110_CMP0 -port Y -portbit 0 -wire launch -wir` |
| 11 | PASS | `mutate -mode cnot1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8686 -port B -portbit 2 -ctrlbit 6 -src rondo_t` |
| 12 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8686 -port Y -portbit 1 -src rondo_tile.v:157.` |
| 13 | PASS | `mutate -mode cnot1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8700 -port Y -portbit 3 -ctrlbit 1 -src rondo_t` |
| 14 | FAIL | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$9110_CMP0 -port Y -portbit 0 -wire launch -wir` |
| 15 | PASS | `mutate -mode cnot0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $shiftx$rondo_tile.v:118$1043 -port Y -portbit 27 -ctrlb` |
| 16 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8771 -port A -portbit 26 -src rondo_tile.v:167` |
| 17 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $xor$rondo_tile.v:90$1680 -port Y -portbit 13 -src rond` |
| 18 | PASS | `mutate -mode cnot1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8930 -port A -portbit 5 -ctrlbit 4 -src rondo_t` |
| 19 | PASS | `mutate -mode inv -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $auto$opt_expr.cc:702:replace_const_cells$9589 -port Y -po` |
| 20 | FAIL | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procdff$9214 -port Q -portbit 0 -wire ev_seq -wirebit ` |
| 21 | FAIL | `mutate -mode inv -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procdff$9229 -port Q -portbit 0 -wire st -wirebit 0 -src ` |
| 22 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8650 -port B -portbit 0 -src rondo_tile.v:161.` |
| 23 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $add$rondo_tile.v:216$1845 -port Y -portbit 4 -src rond` |
| 24 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8661 -port Y -portbit 0 -src rondo_tile.v:211.` |
| 25 | FAIL | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$1863 -port Y -portbit 4 -wire ent_tag -wirebit` |
| 26 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8576 -port S -portbit 0 -src rondo_tile.v:151.` |
| 27 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procdff$9244 -port Q -portbit 0 -wire status -wirebit ` |
| 28 | PASS | `mutate -mode const0 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procmux$8778 -port A -portbit 6 -src rondo_tile.v:164.` |
| 29 | PASS | `mutate -mode const1 -module $paramod$aafbb6df5dade28b2168118273c71c3f563894ba\rondo_tile -cell $procdff$9284 -port Q -portbit 0 -wire xt_idx -wirebit ` |

Survivor arguments (benign/equivalent), to be filled by hand: see below.
