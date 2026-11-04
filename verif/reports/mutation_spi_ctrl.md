# Mutation sanity: spi_ctrl/bmc_nocrc on x (rondo_spi_ctrl), yosys mutate -list 20 -seed 1, depth 33

20 mutants, killed 6 (30%), survived/other 14

| # | result | mutation |
|---|---|---|
| 0 | PASS | `mutate -mode cnot0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$4732 -port Y -portbit 11 -ctrlbit 13 -src r` |
| 1 | PASS | `mutate -mode inv -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$4635 -port Y -portbit 0 -src rondo_spi_ctrl.v` |
| 2 | PASS | `mutate -mode const0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6578 -port Q -portbit 22 -wire rb_req_wdat` |
| 3 | PASS | `mutate -mode cnot0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$5119 -port Y -portbit 2 -ctrlbit 1 -src ron` |
| 4 | PASS | `mutate -mode inv -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6583 -port Q -portbit 3 -wire tx_byte -wirebi` |
| 5 | PASS | `mutate -mode cnot1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $eq$rondo_spi_ctrl.v:194$2021 -port A -portbit 2 -ct` |
| 6 | FAIL | `mutate -mode const1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6648 -port Q -portbit 13 -wire rem -wirebi` |
| 7 | PASS | `mutate -mode cnot1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6643 -port Q -portbit 2 -ctrlbit 12 -wire l` |
| 8 | PASS | `mutate -mode const1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6668 -port Q -portbit 8 -wire wbuf -wirebi` |
| 9 | FAIL | `mutate -mode cnot0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$5189 -port A -portbit 16 -ctrlbit 4 -src ro` |
| 10 | PASS | `mutate -mode const0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$4954 -port Y -portbit 16 -src rondo_spi_ct` |
| 11 | FAIL | `mutate -mode cnot0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$5226 -port A -portbit 4 -ctrlbit 22 -src ro` |
| 12 | FAIL | `mutate -mode cnot0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6608 -port Q -portbit 0 -ctrlbit 1 -wire bi` |
| 13 | FAIL | `mutate -mode cnot0 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6643 -port Q -portbit 8 -ctrlbit 11 -wire l` |
| 14 | PASS | `mutate -mode inv -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$2239 -port Y -portbit 2 -src rondo_spi_ctrl.v` |
| 15 | FAIL | `mutate -mode const1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$5162 -port A -portbit 30 -src rondo_spi_ct` |
| 16 | PASS | `mutate -mode const1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procmux$4878 -port B -portbit 15 -src rondo_spi_ct` |
| 17 | PASS | `mutate -mode cnot1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6658 -port Q -portbit 4 -ctrlbit 16 -wire w` |
| 18 | PASS | `mutate -mode inv -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $ternary$rondo_spi_ctrl.v:50$1739 -port B -portbit 1 -` |
| 19 | PASS | `mutate -mode const1 -module $paramod\rondo_spi_ctrl\CRC=s32'00000000000000000000000000000001 -cell $procdff$6578 -port Q -portbit 3 -wire rb_req_wdata` |

Survivor arguments (benign/equivalent), to be filled by hand: see below.
