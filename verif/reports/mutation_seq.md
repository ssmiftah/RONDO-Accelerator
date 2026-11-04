# Mutation sanity: seq/bmc on x (rondo_seq), yosys mutate -list 30 -seed 1, depth 50

30 mutants, killed 7 (23%), survived/other 23

| # | result | mutation |
|---|---|---|
| 0 | PASS | `mutate -mode inv -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4272 -port B -portbit 0 -src rondo_seq.v:330.25-33` |
| 1 | PASS | `mutate -mode cnot1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$3927 -port A -portbit 1 -ctrlbit 2 -src rondo_se` |
| 2 | PASS | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell u_ck -port zbuf -portbit 125 -ctrlbit 84 -wire zbuf -wire` |
| 3 | FAIL | `mutate -mode inv -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4801 -port Q -portbit 26 -wire infer_cnt -wirebit ` |
| 4 | PASS | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4422 -port A -portbit 12 -ctrlbit 7 -src rondo_s` |
| 5 | FAIL | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4926 -port Q -portbit 0 -wire sr_running -wireb` |
| 6 | PASS | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4376 -port A -portbit 47 -ctrlbit 12 -src rondo_` |
| 7 | PASS | `mutate -mode const0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4148 -port S -portbit 0 -src rondo_seq.v:272.34` |
| 8 | PASS | `mutate -mode const0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4941 -port Q -portbit 25 -wire lat -wirebit 25 ` |
| 9 | PASS | `mutate -mode const0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4846 -port Q -portbit 0 -wire kat_done -wirebit` |
| 10 | PASS | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4328 -port A -portbit 1 -src rondo_seq.v:278.33` |
| 11 | PASS | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4315 -port A -portbit 4 -ctrlbit 3 -wire sr_pass` |
| 12 | PASS | `mutate -mode cnot1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4331 -port B -portbit 3 -ctrlbit 20 -src rondo_s` |
| 13 | FAIL | `mutate -mode inv -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4741 -port Q -portbit 0 -wire lt[1] -wirebit 0 -sr` |
| 14 | PASS | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4851 -port Q -portbit 0 -wire kat_fail -wirebit` |
| 15 | PASS | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $eq$rondo_seq.v:325$1677 -port A -portbit 0 -src rondo_s` |
| 16 | FAIL | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $logic_and$rondo_seq.v:262$1642 -port A -portbit 0 -wire` |
| 17 | PASS | `mutate -mode inv -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4484 -port A -portbit 0 -wire zvalid -wirebit 0 -s` |
| 18 | PASS | `mutate -mode inv -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $gt$rondo_seq.v:247$1630 -port B -portbit 3 -src rondo_seq.` |
| 19 | PASS | `mutate -mode const0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4315 -port A -portbit 22 -wire sr_pass_cksum -w` |
| 20 | FAIL | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4896 -port Q -portbit 2 -ctrlbit 1 -wire st -wir` |
| 21 | FAIL | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4445 -port Y -portbit 10 -ctrlbit 26 -src rondo_` |
| 22 | PASS | `mutate -mode cnot0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4055 -port Y -portbit 1 -ctrlbit 6 -src rondo_se` |
| 23 | PASS | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procdff$4861 -port Q -portbit 0 -wire tile_fail_p -wire` |
| 24 | PASS | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$3692 -port B -portbit 56 -src rondo_seq.v:232.1` |
| 25 | PASS | `mutate -mode inv -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell u_ck -port checksum -portbit 6 -wire checksum -wirebit 6 -s` |
| 26 | PASS | `mutate -mode const0 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4317 -port A -portbit 8 -src rondo_seq.v:255.17` |
| 27 | FAIL | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4167 -port B -portbit 31 -wire sr_count -wirebi` |
| 28 | PASS | `mutate -mode cnot1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $procmux$4474 -port A -portbit 4 -ctrlbit 5 -src rondo_se` |
| 29 | PASS | `mutate -mode const1 -module $paramod$31b7f0c4ffc48346ae62ed7c8c52986761478528\rondo_seq -cell $add$rondo_seq.v:210$1613 -port B -portbit 0 -wire guard` |

Survivor arguments (benign/equivalent), to be filled by hand: see below.
