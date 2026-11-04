// Negative tests for the protocol checkers: every checker driven directly with legal and then deliberately broken
// stimulus (the "mutant" is the stimulus).
module tb_chip_sva (
    input clk, rst_n,
    // spi
    input cs_active, miso, miso_oe, rise, frame_start, frame_end, rb_req_valid_s, rb_req_ready_s, frame_is_rw, hdr_done,
    input [16:0] n_total,
    output [7:0] v_spi,
    // rbus
    input req_valid, req_ready, req_we, input [23:0] req_addr, input [31:0] req_wdata, input rsp_valid, rsp_ready,
    output [7:0] v_rbus,
    // regs
    input reg_re, reg_we, input [7:0] reg_idx, input [31:0] reg_wdata, reg_rdata, err_status, input [15:0] err_in,
    input srst, input [31:0] irq_status_eff, irq_en, input irq, input [63:0] pair0,
    output [7:0] v_regs,
    // seq
    input start, busy, done, layer_rst_n, input [63:0] x, input [127:0] zbuf, input zcap, zclr, mem_wr_ext, active,
    input inact_clk_en, inact_rst_n,
    output [7:0] v_seq,
    // wmem
    input fmt, ce_l_any, wp_en, input [1:0] wp_half, input wp_denied,
    output [7:0] v_wmem
);
    rondo_sva_spi u_spi (.clk(clk), .rst_n(rst_n), .cs_active(cs_active), .miso(miso), .miso_oe(miso_oe), .rise(rise),
        .frame_start(frame_start), .frame_end(frame_end), .rb_req_valid(rb_req_valid_s), .rb_req_ready(rb_req_ready_s),
        .frame_is_rw(frame_is_rw), .hdr_done(hdr_done), .n_total(n_total), .lb_mode(1'b0), .rx_valid(1'b0),
        .rx_byte(8'd0), .tx_load_sh(1'b0), .tx_sh_byte(8'd0), .viol(v_spi));
    rondo_sva_rbus #(.MAX_RSP(6), .MAX_TOTAL(12)) u_rbus (.clk(clk), .rst_n(rst_n), .req_valid(req_valid), .req_ready(req_ready),
        .req_we(req_we), .req_addr(req_addr), .req_wdata(req_wdata), .rsp_valid(rsp_valid), .rsp_ready(rsp_ready), .viol(v_rbus));
    rondo_sva_regs u_regs (.clk(clk), .rst_n(rst_n), .reg_re(reg_re), .reg_we(reg_we), .reg_idx(reg_idx), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .err_status(err_status), .err_in(err_in), .srst(srst), .irq_status_eff(irq_status_eff),
        .irq_en(irq_en), .irq(irq), .pair0_val(pair0), .pair1_val(64'd0), .viol(v_regs));
    rondo_sva_seq #(.XW(64), .ZW(128)) u_seq (.clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .layer_rst_n(layer_rst_n), .x(x), .zbuf_sig(zbuf), .zcap(zcap), .zclr(zclr), .mem_wr_ext(mem_wr_ext), .active(active),
        .inactive_clk_en(inact_clk_en), .inactive_rst_n(inact_rst_n), .viol(v_seq));
    rondo_sva_wmem u_wmem (.clk(clk), .rst_n(rst_n), .fmt(fmt), .ce_l_any(ce_l_any), .wp_en(wp_en), .wp_half(wp_half),
        .wp_denied(wp_denied), .viol(v_wmem));
endmodule
