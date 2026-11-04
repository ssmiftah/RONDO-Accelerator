module tb_chip_units_mem #(parameter N_LANES = 2, NPAR = 8, NWORDS = 56, NBWORDS = 7,
    parameter WAW = $clog2(NWORDS), BAW = $clog2(NBWORDS), LNW = $clog2(N_LANES)) (
    input clk, fmt,
    input [N_LANES*WAW-1:0] wm_addr, input [N_LANES*BAW-1:0] bm_addr, input [N_LANES-1:0] mem_act,
    output [N_LANES*NPAR*16-1:0] wm_q_h, wm_q_l, bm_q_h, bm_q_l,
    input wp_en, wp_we, wp_bias, input [LNW-1:0] wp_lane, input [WAW-1:0] wp_addr, input [1:0] wp_half,
    input [NPAR*16-1:0] wp_wd_h, wp_wd_l, output [NPAR*16-1:0] wp_rd_h, wp_rd_l,
    output wp_denied, ce_l_any
);
    rondo_wmem #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u (.*);
endmodule
