# RTL bugs found by the verification (not fixed; the author decides)

## BUG-1: SPI_FRAME is not raised for a CS abort inside a byte when no byte of the current header/word has completed
* Files: rtl/chip/rondo_spi_phy.v:85 (`abort_q <= (bitcnt != 3'd0)` is registered, so `mid_byte_abort` is high one cycle AFTER `frame_end`),
  rtl/chip/rondo_spi_ctrl.v:132-141 (the controller consumes `mid_byte_abort` in the same cycle as `frame_end`, where it is still 0; additionally the M_OPC branch never flags an abort inside the opcode byte).
* Spec: section 5.3 rule 3 (line 555): "mid-header or mid-word: the partial header/word is discarded, ERR_STATUS.SPI_FRAME".
* Failing test: `u_spi_abort` (CHIP top, S, seed 1; fails at every seed, directed). Scenario: WRITE frame (CRC off, 3 words); CS rises after n SCLK edges.
  No SPI_FRAME for n = 1..7 (opcode byte incomplete), n = 49..52 (first byte of the first data word incomplete), n = 87 and 115 (first byte of word 2/3 incomplete). SPI_FRAME is correct whenever at least one byte of the current word was completed (e.g. n = 59), and
  the partial data is discarded correctly in every case (rbus access counts are right, no write is issued).
* Why the formal proofs did not see it: spi_ctrl_f.v models `mid_abort = abort_i && frame_end` (simultaneous), while the real PHY delivers it one cycle later; FV-PHY "ab" checks the PHY alone.
* Effect: a host that aborts a frame mid-byte at a word boundary gets no error flag (data integrity is not affected: the partial word is dropped).
* Suggested fix (author's decision): delay `frame_end` to the controller by one cycle, or make the PHY assert `mid_byte_abort` together with `frame_end` (combinationally from bitcnt), and flag M_OPC aborts.

## NOTE-1 (not an RTL bug): docs/CHIP_IMPL_LOG.md Task 7 says CAPS is edited in rondo_regs.v; the CAPS_V constant lives in rondo_dev.v:88 (rondo_regs.v only holds VERSION_V and GEOM*).

## NOTE-2 (candidate, NOT confirmed as an RTL bug): rondo_spi_ctrl may issue a READ request after the frame ended
* Found by an unbounded PDR task on the spi_ctrl harness (`verif/formal`, task `pdr`, CRC off, payload zero, GAPN 2): violation of `reqs <= N` / address-increment at depth 38 (spi_ctrl_f.v:120-121).
* Trace: a READ frame ends right after its 6 header bytes (frame_end at step 39, abort on a word boundary); two cycles later `rb_req_valid` rises (step 41, same cycle as the next frame_start), so the harness counts the request in the new frame.
  I.e. the speculative first read request of an aborted READ frame can be issued after CS rose when the rbus ready is delayed.
* Why it is not claimed as a bug: the harness lets frame_end follow the last byte within 1-2 cycles and CS stay high for 1 cycle; the real PHY needs several core cycles (R >= 6) between the last SCLK edge and CS, and the SPI link gives CS-high gaps of microseconds.
  Side effect on silicon, if reachable: one extra register read (no clear-on-read registers exist; *_LO reads latch a shadow). Needs the author's judgement or a CS-spacing assumption in the harness; the JG-only `spi_ctrl_jg_prove_full` task (untested here) would show whether the property holds with such an assumption.
