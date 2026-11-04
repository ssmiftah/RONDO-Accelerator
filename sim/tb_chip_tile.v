`timescale 1ns/1ps
// rondo_dev (SMALL, TILE=1) next to bare UNTILED reference cores with PDIM = PW (the wide layer, no tiling)
// for both formats: tiled chip results must equal the wide-core results bit for bit (spec 18.8 T-TILE).
module tb_chip_tile #(
    parameter WIDTH = 16, PDIM = 8, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7, NXBUF = 4, PW = 24, TILE_B = 3,
    parameter ACCSIG_BF16 = 8, TBITS_FP32 = 8, NR_ITERS_FP32 = 2,
    parameter KAT = 1, TRACE = 1, DBG = 1, MBIST = 0, HAS_BF16 = 1, HAS_FP32 = 1,
    parameter CNT_INIT = 0, HB_BIT = 6,
    parameter NLAD = WIDTH / N_LANES, NGROUP = NSLOT * DEPTH / NPAR, NBATCHES = NLAD / NSLOT,
    parameter WAW = $clog2(NBATCHES*NGROUP*PW), BAW = $clog2(NBATCHES*NGROUP), LNW = $clog2(N_LANES)
) (
    input clk, rst_n, test_mode,
    input rb_req_valid, output rb_req_ready, input rb_req_we, input [23:0] rb_req_addr, input [31:0] rb_req_wdata,
    output rb_rsp_valid, input rb_rsp_ready, output [31:0] rb_rsp_rdata, output rb_rsp_err,
    output irq, busy_pin, st_pass, output [7:0] status8, output clkout, output [1:0] clk_div, output clk_src, crc_en,
    input spi_err_frame, spi_err_crc, spi_frame_end, bist_strap,
    output [1:0] lclk_obs, pg_req,
    input bf_w_we, input [LNW-1:0] bf_w_lane, input [WAW-1:0] bf_w_addr, input [NPAR*16-1:0] bf_w_din,
    input bf_b_we, input [BAW-1:0] bf_b_addr, input [NPAR*16-1:0] bf_b_din, input bf_start,
    input [PW*16-1:0] bf_x, output bf_busy, bf_done, output [WIDTH*16-1:0] bf_z, output [N_LANES-1:0] bf_guard,
    input fp_w_we, input [LNW-1:0] fp_w_lane, input [WAW-1:0] fp_w_addr, input [NPAR*32-1:0] fp_w_din,
    input fp_b_we, input [BAW-1:0] fp_b_addr, input [NPAR*32-1:0] fp_b_din, input fp_start,
    input [PW*32-1:0] fp_x, output fp_busy, fp_done, output [WIDTH*32-1:0] fp_z, output [N_LANES-1:0] fp_guard,
    output reg [31:0] bf_last, fp_last,
    output [7:0] sva_viol
);
    wire [1:0] div_applied = clk_div;
    rondo_dev #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR),
        .NXBUF(NXBUF), .ACCSIG_BF16(ACCSIG_BF16), .TBITS_FP32(TBITS_FP32), .NR_ITERS_FP32(NR_ITERS_FP32),
        .HAS_BF16(HAS_BF16), .HAS_FP32(HAS_FP32), .KAT(KAT), .TRACE(TRACE), .DBG(DBG), .MBIST(MBIST),
        .TILE(1), .TILE_B(TILE_B), .CNT_INIT(CNT_INIT), .HB_BIT(HB_BIT)) u_dev (
        .clk(clk), .rst_n(rst_n), .test_mode(test_mode),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we), .rb_req_addr(rb_req_addr),
        .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid), .rb_rsp_ready(rb_rsp_ready),
        .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err), .irq(irq), .busy_pin(busy_pin), .st_pass(st_pass),
        .status8(status8), .clkout(clkout), .clk_div(clk_div), .clk_src(clk_src), .crc_en(crc_en),
        .div_applied(div_applied), .src_applied(clk_src), .spi_err_frame(spi_err_frame),
        .spi_err_crc(spi_err_crc), .spi_frame_end(spi_frame_end), .bist_strap(bist_strap),
        .pg_req(pg_req), .lclk_obs(lclk_obs),
        .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());

    fused_coproc_pipe #(.EXP(8), .SIG(8), .ACCSIG(ACCSIG_BF16), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PW),
        .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(6), .EPS(32'h3C24),
        .SEED_FILE("recip_seed_e8s8_t6.mem")) u_bf (
        .clock(clk), .nReset(rst_n), .w_we(bf_w_we), .w_lane(bf_w_lane), .w_addr(bf_w_addr), .w_din(bf_w_din),
        .b_we(bf_b_we), .b_addr(bf_b_addr), .b_din(bf_b_din), .start(bf_start), .busy(bf_busy), .done(bf_done),
        .x(bf_x), .z(bf_z), .guard_hit(bf_guard), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*16{1'b0}}), .bm_q({N_LANES*NPAR*16{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0),
        .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());
    fused_coproc_pipe #(.EXP(8), .SIG(24), .ACCSIG(24), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PW),
        .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS_FP32), .EPS(32'h3C23D70A),
        .SEED_FILE(TBITS_FP32 == 12 ? "recip_seed_e8s24_t12.mem" : "recip_seed_e8s24_t8.mem"),
        .NR_ITERS(NR_ITERS_FP32)) u_fp (
        .clock(clk), .nReset(rst_n), .w_we(fp_w_we), .w_lane(fp_w_lane), .w_addr(fp_w_addr), .w_din(fp_w_din),
        .b_we(fp_b_we), .b_addr(fp_b_addr), .b_din(fp_b_din), .start(fp_start), .busy(fp_busy), .done(fp_done),
        .x(fp_x), .z(fp_z), .guard_hit(fp_guard), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*32{1'b0}}), .bm_q({N_LANES*NPAR*32{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0),
        .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());

    wire [7:0] vt;
    rondo_sva_tile u_sva_tile (.clk(clk), .rst_n(rst_n), .layer_start(u_dev.layer_start), .tl_busy(u_dev.tl_busy),
        .tl_seed(u_dev.tl_seed), .tl_last(u_dev.tl_last), .tl_keep(u_dev.g_tile.u_tile.keep),
        .entry_valid(u_dev.tl_ent_valid), .entry_tag(u_dev.tl_ent_tag),
        .s_cur(u_dev.tl_s_cur), .zcap(u_dev.zcap), .tl_tz_we(u_dev.tl_tz_we), .ps_layer_we(|u_dev.ps_we_w),
        .ps_host_wr(u_dev.ps_h_wr), .active(u_dev.active),
        .cmd_start_class(u_dev.cmd_start | u_dev.cmd_sr_start | u_dev.cmd_kat_start),
        .tile_blocked(u_dev.tl_busy | u_dev.tl_open), .viol(vt));
    assign sva_viol = vt;

    // cycle counters in the sense of LAST_CYCLES (edges after the start-sampling edge up to the
    // edge after which done = 1)
    reg run_b, run_f; reg [31:0] cnt_b, cnt_f;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin run_b <= 0; run_f <= 0; cnt_b <= 0; cnt_f <= 0; bf_last <= 0; fp_last <= 0; end
        else begin
            if (bf_start) begin run_b <= 1; cnt_b <= 0; end
            else if (run_b) begin if (bf_done) begin bf_last <= cnt_b; run_b <= 0; end else cnt_b <= cnt_b + 1; end
            if (fp_start) begin run_f <= 1; cnt_f <= 0; end
            else if (run_f) begin if (fp_done) begin fp_last <= cnt_f; run_f <= 0; end else cnt_f <= cnt_f + 1; end
        end
    end
endmodule
