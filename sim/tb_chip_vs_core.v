`timescale 1ns/1ps
// rondo_dev (SMALL) next to bare reference cores for both formats (unmodified-parameter
// fused_coproc_pipe, EXT_MEM=0, loaded directly): bit-exact z and cycle-exact LAST_CYCLES.
module tb_chip_vs_core #(
    parameter WIDTH = 16, PDIM = 8, N_LANES = 2, NSLOT = 8, NPAR = 8, DEPTH = 7, NXBUF = 4,
    parameter ACCSIG_BF16 = 8, TBITS_FP32 = 8, NR_ITERS_FP32 = 2,
    parameter KAT = 1, TRACE = 1, DBG = 1, MBIST = 0, TILE = 0, HAS_BF16 = 1, HAS_FP32 = 1,
    parameter [31:0] KAT_SIG_BF16 = 32'hFFFFFFFF, KAT_SIG_FP32 = 32'hFFFFFFFF,
    parameter CNT_INIT = 0, HB_BIT = 6,
    parameter NLAD = WIDTH / N_LANES, NGROUP = NSLOT * DEPTH / NPAR, NBATCHES = NLAD / NSLOT,
    parameter WAW = $clog2(NBATCHES*NGROUP*PDIM), BAW = $clog2(NBATCHES*NGROUP), LNW = $clog2(N_LANES)
) (
    input clk, rst_n, test_mode,
    // dev rbus (external port)
    input rb_req_valid, output rb_req_ready, input rb_req_we, input [23:0] rb_req_addr, input [31:0] rb_req_wdata,
    output rb_rsp_valid, input rb_rsp_ready, output [31:0] rb_rsp_rdata, output rb_rsp_err,
    output irq, busy_pin, st_pass, output [7:0] status8, output clkout, output [1:0] clk_div, output clk_src, crc_en,
    input spi_err_frame, spi_err_crc, spi_frame_end, bist_strap,
    output [1:0] lclk_obs, pg_req,
    // bare bf16 core
    input bf_w_we, input [LNW-1:0] bf_w_lane, input [WAW-1:0] bf_w_addr, input [NPAR*16-1:0] bf_w_din,
    input bf_b_we, input [BAW-1:0] bf_b_addr, input [NPAR*16-1:0] bf_b_din, input bf_start,
    input [PDIM*16-1:0] bf_x, output bf_busy, bf_done, output [WIDTH*16-1:0] bf_z, output [N_LANES-1:0] bf_guard,
    // bare fp32 core
    input fp_w_we, input [LNW-1:0] fp_w_lane, input [WAW-1:0] fp_w_addr, input [NPAR*32-1:0] fp_w_din,
    input fp_b_we, input [BAW-1:0] fp_b_addr, input [NPAR*32-1:0] fp_b_din, input fp_start,
    input [PDIM*32-1:0] fp_x, output fp_busy, fp_done, output [WIDTH*32-1:0] fp_z, output [N_LANES-1:0] fp_guard,
    output reg [31:0] bf_last, fp_last,
    output [39:0] sva_viol
);
    wire [1:0] div_applied = clk_div;
    rondo_dev #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR),
        .NXBUF(NXBUF), .ACCSIG_BF16(ACCSIG_BF16), .TBITS_FP32(TBITS_FP32), .NR_ITERS_FP32(NR_ITERS_FP32),
        .HAS_BF16(HAS_BF16), .HAS_FP32(HAS_FP32), .KAT(KAT), .TRACE(TRACE), .DBG(DBG), .MBIST(MBIST),
        .TILE(TILE), .KAT_SIG_BF16(KAT_SIG_BF16), .KAT_SIG_FP32(KAT_SIG_FP32), .CNT_INIT(CNT_INIT), .HB_BIT(HB_BIT)) u_dev (
        .clk(clk), .rst_n(rst_n), .test_mode(test_mode),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we), .rb_req_addr(rb_req_addr),
        .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid), .rb_rsp_ready(rb_rsp_ready),
        .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err), .irq(irq), .busy_pin(busy_pin), .st_pass(st_pass),
        .status8(status8), .clkout(clkout), .clk_div(clk_div), .clk_src(clk_src), .crc_en(crc_en),
        .div_applied(div_applied), .src_applied(clk_src), .spi_err_frame(spi_err_frame),
        .spi_err_crc(spi_err_crc), .spi_frame_end(spi_frame_end), .bist_strap(bist_strap),
        .pg_req(pg_req), .lclk_obs(lclk_obs),
        .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());

    fused_coproc_pipe #(.EXP(8), .SIG(8), .ACCSIG(ACCSIG_BF16), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM),
        .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(6), .EPS(32'h3C24),
        .SEED_FILE("recip_seed_e8s8_t6.mem")) u_bf (
        .clock(clk), .nReset(rst_n), .w_we(bf_w_we), .w_lane(bf_w_lane), .w_addr(bf_w_addr), .w_din(bf_w_din),
        .b_we(bf_b_we), .b_addr(bf_b_addr), .b_din(bf_b_din), .start(bf_start), .busy(bf_busy), .done(bf_done),
        .x(bf_x), .z(bf_z), .guard_hit(bf_guard), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*16{1'b0}}), .bm_q({N_LANES*NPAR*16{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0),
        .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());
    fused_coproc_pipe #(.EXP(8), .SIG(24), .ACCSIG(24), .DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM),
        .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .TBITS(TBITS_FP32), .EPS(32'h3C23D70A),
        .SEED_FILE(TBITS_FP32 == 12 ? "recip_seed_e8s24_t12.mem" : "recip_seed_e8s24_t8.mem"),
        .NR_ITERS(NR_ITERS_FP32)) u_fp (
        .clock(clk), .nReset(rst_n), .w_we(fp_w_we), .w_lane(fp_w_lane), .w_addr(fp_w_addr), .w_din(fp_w_din),
        .b_we(fp_b_we), .b_addr(fp_b_addr), .b_din(fp_b_din), .start(fp_start), .busy(fp_busy), .done(fp_done),
        .x(fp_x), .z(fp_z), .guard_hit(fp_guard), .lane_en({N_LANES{1'b1}}),
        .wm_addr(), .bm_addr(), .mem_act(), .wm_q({N_LANES*NPAR*32{1'b0}}), .bm_q({N_LANES*NPAR*32{1'b0}}),
        .dbg_lane({LNW{1'b0}}), .dbg_sig(3'd0), .dbg_idx(8'd0), .dbg_data(), .dbg_live_sel(2'd0),
        .dbg_live_v(), .dbg_live_d(), .dbg_live_f(), .tile_seed(2'b00), .tile_save(1'b0), .tile_last(1'b1), .ps_q('0), .ps_we(), .ps_waddr(), .ps_wdata(), .done_final());

`ifndef RONDO_NO_SVA
    // ---- protocol checkers (rtl/chip/sva) --------------------------------------------------------------------
    wire [7:0] v_rbus, v_regs, v_seq, v_wmem, v_spare;
    rondo_sva_rbus u_sva_rbus (.clk(clk), .rst_n(rst_n), .req_valid(rb_req_valid), .req_ready(rb_req_ready),
        .req_we(rb_req_we), .req_addr(rb_req_addr), .req_wdata(rb_req_wdata), .rsp_valid(rb_rsp_valid),
        .rsp_ready(rb_rsp_ready), .viol(v_rbus));
    rondo_sva_regs u_sva_regs (.clk(clk), .rst_n(rst_n), .reg_re(u_dev.reg_re_s), .reg_we(u_dev.reg_we_s),
        .reg_idx(u_dev.q_addr[7:0]), .reg_wdata(u_dev.q_wdata), .reg_rdata(u_dev.reg_rdata),
        .err_status(u_dev.reg_err_o), .err_in(u_dev.err_in), .srst(u_dev.srst),
        .irq_status_eff(u_dev.reg_irq_o), .irq_en(u_dev.u_regs.irq_en), .irq(u_dev.irq),
        .pair0_val(u_dev.infer_cnt), .pair1_val(u_dev.busy_cyc), .viol(v_regs));
    rondo_sva_seq #(.XW(PDIM*32), .ZW(WIDTH*32)) u_sva_seq (.clk(clk), .rst_n(rst_n),
        .start(u_dev.layer_start), .busy(u_dev.layer_busy), .done(u_dev.layer_done),
        .layer_rst_n(u_dev.fmt_applied ? u_dev.core_rst_n[1] : u_dev.core_rst_n[0]), .x(u_dev.x_live),
        .zbuf_sig(u_dev.zbuf_r), .zcap(u_dev.zcap), .zclr(u_dev.srst | u_dev.fsw_pulse), .mem_wr_ext(u_dev.pk_en & u_dev.pk_we & ~u_dev.q_int),
        .active(u_dev.active), .inactive_clk_en(u_dev.fmt_applied ? u_dev.clk_en[0] : u_dev.clk_en[1]),
        .inactive_rst_n(u_dev.fmt_applied ? u_dev.core_rst_n[0] : u_dev.core_rst_n[1]), .viol(v_seq));
    rondo_sva_wmem u_sva_wmem (.clk(clk), .rst_n(rst_n), .fmt(u_dev.fmt_applied), .ce_l_any(u_dev.ce_l_any),
        .wp_en(u_dev.u_mem.wp_en), .wp_half(u_dev.u_mem.wp_half), .wp_denied(u_dev.wp_denied), .viol(v_wmem));
    assign v_spare = 8'd0;
    assign sva_viol = {v_spare, v_wmem, v_seq, v_regs, v_rbus};
`else
    assign sva_viol = 40'd0;
`endif

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
