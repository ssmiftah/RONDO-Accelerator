`timescale 1ns/1ps
// rondo_dev with LAYER=1 (KAN, bf16, SMALL) next to a bare kan_layer_pipe loaded directly.
module tb_chip_kan (
    input clk, rst_n,
    input rb_req_valid, output rb_req_ready, input rb_req_we, input [23:0] rb_req_addr, input [31:0] rb_req_wdata,
    output rb_rsp_valid, input rb_rsp_ready, output [31:0] rb_rsp_rdata, output rb_rsp_err,
    output irq, busy_pin, output [7:0] status8,
    input k_w_we, input [0:0] k_w_lane, input [5:0] k_w_addr, input [127:0] k_w_din, input [127:0] k_x, input k_start,
    output k_busy, k_done, output [255:0] k_y
);
    wire [1:0] cd; wire cs, ce, co, sp; wire [1:0] pg, lo;
    rondo_dev #(.DEPTH(7), .WIDTH(16), .PDIM(8), .N_LANES(2), .NSLOT(8), .NPAR(8), .NXBUF(4), .LAYER(1), .HAS_FP32(0),
                .KAT(0), .TRACE(0), .DBG(0), .MBIST(0), .HB_BIT(6)) u_dev (
        .clk(clk), .rst_n(rst_n), .test_mode(1'b0), .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready),
        .rb_req_we(rb_req_we), .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid),
        .rb_rsp_ready(rb_rsp_ready), .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err), .irq(irq), .busy_pin(busy_pin),
        .st_pass(sp), .status8(status8), .clkout(co), .clk_div(cd), .clk_src(cs), .crc_en(ce), .div_applied(2'b00),
        .src_applied(1'b0), .spi_err_frame(1'b0), .spi_err_crc(1'b0), .spi_frame_end(1'b0), .bist_strap(1'b0),
        .pg_req(pg), .lclk_obs(lo), .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());
    kan_layer_pipe #(.EXP(8), .SIG(8)) u_kan (.clock(clk), .nReset(rst_n), .w_we(k_w_we), .w_lane(k_w_lane),
        .w_addr(k_w_addr), .w_din(k_w_din), .start(k_start), .busy(k_busy), .done(k_done), .x(k_x), .y(k_y));
endmodule
