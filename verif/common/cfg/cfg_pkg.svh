// Parameter sets (plan 1.2). Select with -d CFG_<id> on xvlog; default S. Macros are consumed by tb_*_top.sv.
`ifndef RONDO_CFG_SVH
`define RONDO_CFG_SVH
`ifdef CFG_F
  `define C_WIDTH 64
  `define C_PDIM 40
  `define C_LANES 8
`else
  `define C_WIDTH 16
  `define C_PDIM 8
  `define C_LANES 2
`endif
`define C_NSLOT 8
`define C_NPAR 8
`define C_DEPTH 7
`define C_NXBUF 4
`define C_ACCSIG 8
`define C_HB_BIT 7
`ifdef CFG_F
 `undef C_HB_BIT
 `define C_HB_BIT 24
`endif
// feature knobs (defaults = spec)
`define C_DBG 1
`define C_TRACE 1
`define C_KAT 1
`define C_SPI_CRC 1
`define C_CLK_ALT 1
`define C_TILE 1
`define C_TILE_B 8
`define C_MBIST 0
`define C_SCAN 0
`define C_PG 0
`define C_LAYER 0
`define C_CNT_INIT 0
`ifdef CFG_S_TB2
 `undef C_TILE_B
 `define C_TILE_B 2
`endif
`ifdef CFG_S_MB
 `undef C_MBIST
 `define C_MBIST 1
`endif
`ifdef CFG_S_SCAN_PG
 `undef C_SCAN
 `undef C_PG
 `define C_SCAN 1
 `define C_PG 1
`endif
`ifdef CFG_S_MIN
 `undef C_DBG
 `undef C_TRACE
 `undef C_KAT
 `undef C_SPI_CRC
 `undef C_CLK_ALT
 `undef C_TILE
 `define C_DBG 0
 `define C_TRACE 0
 `define C_KAT 0
 `define C_SPI_CRC 0
 `define C_CLK_ALT 0
 `define C_TILE 0
`endif
`ifdef CFG_S_ACC24
 `undef C_ACCSIG
 `undef C_TILE
 `define C_ACCSIG 24
 `define C_TILE 0        // TILE=1 with ACCSIG_BF16=24 is an elaboration $fatal (D3); see scripts/elab_neg.sh
`endif
`ifdef CFG_S_KAN
 `undef C_LAYER
 `define C_LAYER 1
`endif
`ifdef CFG_S_CNT
 `undef C_CNT_INIT
 `define C_CNT_INIT (32'hFFFFFFFF - 49)
`endif
`endif
