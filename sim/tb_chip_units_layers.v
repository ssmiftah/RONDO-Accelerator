// rondo_wpack + rondo_wmem + rondo_layers (SMALL geometry) with manual control of the
// layer reset / clock-enable / format signals: the format-switch ordering unit test.
module tb_chip_units_layers #(parameter N_LANES = 2, WIDTH = 16, PDIM = 8, NPAR = 8, NSLOT = 8, DEPTH = 7,
    parameter NGROUP = NSLOT*DEPTH/NPAR, NWORDS = NGROUP*PDIM, NBWORDS = NGROUP,
    parameter WAW = $clog2(NWORDS), BAW = $clog2(NBWORDS), LNW = $clog2(N_LANES), FW = 3) (
    input clk, rst_n, fmt, dbg_fmt, input [1:0] core_rst_n, clk_en,
    input wr_stb, rd_stb, region_bias, input [LNW-1:0] lane, input [WAW-1:0] caddr,
    input [FW-1:0] field, input [31:0] wdata, output rd_valid, output [31:0] rd_data,
    input crc_clr, output [31:0] load_crc,
    input start, output busy, done, input [PDIM*32-1:0] x, output [WIDTH*32-1:0] z,
    input [N_LANES-1:0] lane_en, output [N_LANES-1:0] guard_hit,
    input [LNW-1:0] dbg_lane, input [2:0] dbg_sig, input [7:0] dbg_idx, output [31:0] dbg_data,
    output reg [31:0] cnt_b, cnt_f, output wp_denied, ce_l_any
);
    wire wp_en, wp_we, wp_bias; wire [LNW-1:0] wp_lane; wire [WAW-1:0] wp_addr; wire [1:0] wp_half;
    wire [NPAR*16-1:0] wp_wd_h, wp_wd_l, wp_rd_h, wp_rd_l;
    wire [N_LANES*WAW-1:0] wm_addr; wire [N_LANES*BAW-1:0] bm_addr; wire [N_LANES-1:0] mem_act;
    wire [N_LANES*NPAR*16-1:0] wm_q_h, wm_q_l, bm_q_h, bm_q_l;
    wire [1:0] lclk_obs;
    rondo_wpack #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u_pk (
        .clk(clk), .rst_n(rst_n), .fmt(fmt), .wr_stb(wr_stb), .rd_stb(rd_stb), .region_bias(region_bias),
        .lane(lane), .caddr(caddr), .field(field), .wdata(wdata), .rd_valid(rd_valid), .rd_data(rd_data),
        .err_partial(), .busy(), .wp_en(wp_en), .wp_we(wp_we), .wp_bias(wp_bias), .wp_lane(wp_lane),
        .wp_addr(wp_addr), .wp_half(wp_half), .wp_wd_h(wp_wd_h), .wp_wd_l(wp_wd_l), .wp_rd_h(wp_rd_h),
        .wp_rd_l(wp_rd_l), .crc_clr(crc_clr), .load_crc(load_crc), .wr_done(), .cache_inval(1'b0),
        .flush_staging(1'b0));
    rondo_wmem #(.N_LANES(N_LANES), .NPAR(NPAR), .NWORDS(NWORDS), .NBWORDS(NBWORDS)) u_mem (
        .clk(clk), .fmt(fmt), .wm_addr(wm_addr), .bm_addr(bm_addr), .mem_act(mem_act),
        .wm_q_h(wm_q_h), .wm_q_l(wm_q_l), .bm_q_h(bm_q_h), .bm_q_l(bm_q_l), .wp_en(wp_en), .wp_we(wp_we),
        .wp_bias(wp_bias), .wp_lane(wp_lane), .wp_addr(wp_addr), .wp_half(wp_half), .wp_wd_h(wp_wd_h),
        .wp_wd_l(wp_wd_l), .wp_rd_h(wp_rd_h), .wp_rd_l(wp_rd_l), .wp_denied(wp_denied), .ce_l_any(ce_l_any));
    rondo_layers #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR)) u_ly (
        .clk(clk), .core_rst_n(core_rst_n), .clk_en(clk_en), .test_mode(1'b0), .fmt(fmt), .dbg_fmt(dbg_fmt),
        .start(start), .busy(busy), .done(done), .x(x), .z(z), .lane_en(lane_en), .guard_hit(guard_hit),
        .wm_addr(wm_addr), .bm_addr(bm_addr), .mem_act(mem_act), .wm_q_h(wm_q_h), .wm_q_l(wm_q_l),
        .bm_q_h(bm_q_h), .bm_q_l(bm_q_l), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1),
        .ps_q_h({N_LANES*NPAR*16{1'b0}}), .ps_q_l({N_LANES*NPAR*16{1'b0}}), .ps_we(), .ps_waddr(), .ps_wd_h(), .ps_wd_l(), .kw_we(1'b0), .kw_lane({LNW{1'b0}}), .kw_addr('0),
        .kw_din({NPAR*16{1'b0}}), .dbg_lane(dbg_lane), .dbg_sig(dbg_sig), .dbg_idx(dbg_idx),
        .dbg_data(dbg_data), .dbg_live_sel(2'd0), .dbg_live_v(), .dbg_live_d(), .dbg_live_f(),
        .lclk_obs(lclk_obs), .pg_iso(2'b00), .pg_req());
    initial begin cnt_b = 0; cnt_f = 0; end
    always @(posedge lclk_obs[0]) cnt_b <= cnt_b + 1;
    always @(posedge lclk_obs[1]) cnt_f <= cnt_f + 1;
endmodule
