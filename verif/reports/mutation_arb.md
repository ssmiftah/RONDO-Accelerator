# Mutation sanity: arb/prove on x (rondo_rbus_arb), yosys mutate -list 30 -seed 1

30 mutants, killed 26 (87%), survived/other 4

| # | result | mutation |
|---|---|---|
| 0 | PASS | `mutate -mode const0 -module rondo_rbus_arb -cell $procmux$240 -port B -portbit 0 -src rondo_rbus_arb.v:32.26-32.46 -src rondo_rbus_arb.v:32.22-32.84` |
| 1 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:44$213 -port Y -portbit 5 -wire o_req_wdata -wirebit 5 -src rondo_rbus_arb.` |
| 2 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:43$208 -port B -portbit 20 -wire k_req_addr -wirebit 20 -src rondo_rbus_arb` |
| 3 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $procmux$251 -port B -portbit 1 -src rondo_rbus_arb.v:36.24-36.50 -src rondo_rbus_arb.v:36.20-36.65` |
| 4 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:44$212 -port A -portbit 2 -wire m_req_wdata -wirebit 2 -src rondo_rbus_arb.` |
| 5 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:44$212 -port B -portbit 25 -wire k_req_wdata -wirebit 25 -src rondo_rbus_arb.v` |
| 6 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $procmux$258 -port Y -portbit 1 -src rondo_rbus_arb.v:34.24-34.62 -src rondo_rbus_arb.v:34.20-35.54` |
| 7 | FAIL | `mutate -mode cnot0 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:43$209 -port A -portbit 4 -ctrlbit 21 -src rondo_rbus_arb.v:43.26-43.98` |
| 8 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:44$212 -port B -portbit 7 -wire k_req_wdata -wirebit 7 -src rondo_rbus_arb.` |
| 9 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:50$227 -port B -portbit 0 -src rondo_rbus_arb.v:50.26-50.68` |
| 10 | PASS | `mutate -mode const0 -module rondo_rbus_arb -cell $procdff$424 -port Q -portbit 1 -wire st -wirebit 1 -src rondo_rbus_arb.v:24.15-24.17 -src rondo_rbus` |
| 11 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:43$209 -port Y -portbit 13 -wire o_req_addr -wirebit 13 -src rondo_rbus_arb` |
| 12 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:47$220 -port B -portbit 0 -src rondo_rbus_arb.v:47.26-47.68` |
| 13 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:43$209 -port B -portbit 1 -wire e_req_addr -wirebit 1 -src rondo_rbus_arb.v:9.` |
| 14 | FAIL | `mutate -mode const0 -module rondo_rbus_arb -cell $logic_or$rondo_rbus_arb.v:34$195 -port Y -portbit 0 -src rondo_rbus_arb.v:34.43-34.61` |
| 15 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:51$229 -port Y -portbit 0 -src rondo_rbus_arb.v:51.26-51.53` |
| 16 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:44$213 -port B -portbit 1 -wire e_req_wdata -wirebit 1 -src rondo_rbus_arb.` |
| 17 | FAIL | `mutate -mode const0 -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:55$236 -port Y -portbit 0 -wire o_rsp_ready -wirebit 0 -src rondo_rbus_ar` |
| 18 | PASS | `mutate -mode inv -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:51$230 -port B -portbit 0 -src rondo_rbus_arb.v:51.26-51.68` |
| 19 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:42$204 -port B -portbit 0 -wire k_req_we -wirebit 0 -src rondo_rbus_arb.v:1` |
| 20 | FAIL | `mutate -mode inv -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:43$209 -port B -portbit 9 -wire e_req_addr -wirebit 9 -src rondo_rbus_arb.v:9.` |
| 21 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:55$236 -port Y -portbit 0 -wire o_rsp_ready -wirebit 0 -src rondo_rbus_ar` |
| 22 | FAIL | `mutate -mode cnot1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:43$209 -port Y -portbit 23 -ctrlbit 18 -wire o_req_addr -wirebit 23 -src ron` |
| 23 | PASS | `mutate -mode const0 -module rondo_rbus_arb -cell $logic_not$rondo_rbus_arb.v:34$194 -port Y -portbit 0 -src rondo_rbus_arb.v:34.51-34.61` |
| 24 | FAIL | `mutate -mode cnot0 -module rondo_rbus_arb -cell $procmux$264 -port A -portbit 0 -ctrlbit 1 -src rondo_rbus_arb.v:31.26-31.46 -src rondo_rbus_arb.v:31.` |
| 25 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $logic_and$rondo_rbus_arb.v:50$227 -port Y -portbit 0 -wire e_rsp_valid -wirebit 0 -src rondo_rbus_ar` |
| 26 | FAIL | `mutate -mode const0 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:44$212 -port A -portbit 26 -wire m_req_wdata -wirebit 26 -src rondo_rbus_ar` |
| 27 | FAIL | `mutate -mode const1 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:42$204 -port A -portbit 0 -wire m_req_we -wirebit 0 -src rondo_rbus_arb.v:1` |
| 28 | FAIL | `mutate -mode const0 -module rondo_rbus_arb -cell $ternary$rondo_rbus_arb.v:55$235 -port B -portbit 0 -wire e_rsp_ready -wirebit 0 -src rondo_rbus_arb.` |
| 29 | FAIL | `mutate -mode cnot0 -module rondo_rbus_arb -cell $procdff$424 -port Q -portbit 0 -ctrlbit 1 -wire st -wirebit 0 -src rondo_rbus_arb.v:24.15-24.17 -src ` |

Survivor arguments (benign/equivalent), to be filled by hand: see below.
