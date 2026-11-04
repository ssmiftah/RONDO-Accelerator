module tb_chip_units_pack #(parameter N_LANES = 2, NPAR = 8, NWORDS = 56, NBWORDS = 7,
    parameter WAW = $clog2(NWORDS), BAW = $clog2(NBWORDS), LNW = $clog2(N_LANES), FW = 3) (
    input clk, rst_n, fmt,
    input wr_stb, rd_stb, region_bias, input [LNW-1:0] lane, input [WAW-1:0] caddr,
    input [FW-1:0] field, input [31:0] wdata,
    output rd_valid, output [31:0] rd_data, output err_partial, busy,
    input crc_clr, output [31:0] load_crc, output wr_done, input cache_inval, flush_staging,
    // layer-side read of the memories
    input [N_LANES*WAW-1:0] wm_addr, input [N_LANES*BAW-1:0] bm_addr, input [N_LANES-1:0] mem_act,
    output [N_LANES*NPAR*16-1:0] wm_q_h, wm_q_l, bm_q_h, bm_q_l, output wp_denied, ce_l_any,
    output reg [31:0] wmem_reads
);
    wire wp_en, wp_we, wp_bias; wire [LNW-1:0] wp_lane; wire [WAW-1:0] wp_addr; wire [1:0] wp_half;
    wire [NPAR*16-1:0] wp_wd_h, wp_wd_l, wp_rd_h, wp_rd_l;
    rondo_wpack #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u_pk (.*);
    rondo_wmem  #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u_mem (.*);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) wmem_reads <= 0; else if (wp_en && !wp_we) wmem_reads <= wmem_reads + 1;
endmodule
