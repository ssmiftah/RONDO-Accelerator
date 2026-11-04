`timescale 1ns/1ps
module tb_chip_spi (
    input clk, rst_n, spi_sclk, spi_cs_n, spi_mosi,
    output spi_miso, spi_miso_oe,
    output rb_req_valid, input rb_req_ready, output rb_req_we, output [23:0] rb_req_addr,
    output [31:0] rb_req_wdata, input rb_rsp_valid, output rb_rsp_ready,
    input [31:0] rb_rsp_rdata, input rb_rsp_err,
    input [7:0] status8, input crc_en,
    output reg [15:0] err_frame_cnt, err_crc_cnt, frame_cnt,
    output cs_active,
    output [7:0] sva_viol
);
    wire err_frame, err_crc, frame_end;
    rondo_spi_slave #(.SYNC_STAGES(2), .CRC(1)) u (
        .clk(clk), .rst_n(rst_n), .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi),
        .spi_miso(spi_miso), .spi_miso_oe(spi_miso_oe),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we),
        .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid),
        .rb_rsp_ready(rb_rsp_ready), .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err),
        .status8(status8), .crc_en(crc_en), .err_frame(err_frame), .err_crc(err_crc),
        .frame_end(frame_end), .cs_active(cs_active));
    wire rw = (u.u_ctrl.mode == 3'd2) || (u.u_ctrl.mode == 3'd3) || (u.u_ctrl.mode == 3'd4);
    wire hd = (u.u_ctrl.mode == 3'd3) || (u.u_ctrl.mode == 3'd4);
    rondo_sva_spi u_sva (.clk(clk), .rst_n(rst_n), .cs_active(cs_active), .miso(spi_miso), .miso_oe(spi_miso_oe),
        .rise(u.u_phy.rise), .frame_start(u.u_phy.frame_start), .frame_end(u.u_phy.frame_end),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .frame_is_rw(rw), .hdr_done(hd),
        .n_total(u.u_ctrl.ntot), .lb_mode(1'b0), .rx_valid(1'b0), .rx_byte(8'd0), .tx_load_sh(1'b0),
        .tx_sh_byte(8'd0), .viol(sva_viol));
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin err_frame_cnt <= 0; err_crc_cnt <= 0; frame_cnt <= 0; end
        else begin
            if (err_frame) err_frame_cnt <= err_frame_cnt + 1;
            if (err_crc)   err_crc_cnt   <= err_crc_cnt + 1;
            if (frame_end) frame_cnt     <= frame_cnt + 1;
        end
    end
endmodule
