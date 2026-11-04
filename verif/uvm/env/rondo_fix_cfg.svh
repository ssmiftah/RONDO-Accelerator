// Expected behaviours of the fixed RTL (CHIP_FIX_PLAN round, spec v2.1.1, VERSION 0x00020101). Single source for the UVM env and
// the formal harness defines. Verified against the RTL (rondo_regs.v lines 322-393, rondo_seq.v, rondo_kat.v, rondo_rbus_arb.v).
`ifndef RONDO_FIX_CFG_SVH
`define RONDO_FIX_CFG_SVH
`define FIX_VERSION           32'h00020101
// B1: PWR_CTRL write while a tile sequence is OPEN -> refused, ERR.TILE_SEQ, register unchanged (TILE builds only)
`define FIX_B1_PWR_WHILE_OPEN_TILE_SEQ 1
// B2: KAT_START with PWR_CTRL[1:0] != 0 -> START_BUSY (not KAT_FAIL), nothing launched; MBIST_START stays allowed with the core held
`define FIX_B2_KAT_HELD_START_BUSY    1
`define FIX_B2_MBIST_HELD_ALLOWED     1
// B2 defensive path: seq refuses a launched KAT (layer not ready / clock off) -> rondo_seq.kat_fail pulse -> rondo_kat ends with KAT_FAIL
`define FIX_B2_SEQ_KAT_FAIL_PULSE     1
// B3: TILE with ACCSIG_BF16 != 8 (and HAS_BF16) is an elaboration $fatal "rondo_dev: TILE=1 needs ACCSIG_BF16=8 ..."
`define FIX_B3_ELAB_FATAL             1
// B4: Rondo.set_clock lowers SCLK after CLK_CFG, before any further frame (host/transport side; checked by cocotb + u_b4_host_replay)
`define FIX_B4_HOST_LOWERS_SCLK       1
// B5: CAPS[3:2] = LAYER (0 CoFrNet, 1 KAN), CAPS[4] = HAS_BIAS = (LAYER == 0)
`define FIX_B5_CAPS_LAYER_FIELD       1
// B6: core_rst_n[f] comes from a flop (run_f) with async clear, test_mode mux only
`define FIX_B6_CORE_RST_FLOP          1
// B7: disabled lane writes qNaN when a start arrives in the done cycle (L_FIN arm, LANE_MASK && start && !busy_r)
`define FIX_B7_QNAN_DISABLED_LANE     1
// robustness: soft reset clears the 4 read shadows and the wpack read cache (flush_staging), and cancels unaccepted internal rbus requests
`define FIX_R_SRST_CLEARS_SHADOWS     1
`define FIX_R_SRST_CLEARS_RDCACHE     1
`define FIX_R_ARB_SRST_CANCEL         1
// F1: spi_ctrl formal is BMC (depth 34 CRC off / 28 CRC on, GAPN 2) + cover depth 160 (GAPN 4); no unbounded proof
`define FIX_F1_SPICTRL_BMC_ONLY       1
// misc: CNT_INIT zero-extended (post-regression correction in rondo_seq.v)
`endif
