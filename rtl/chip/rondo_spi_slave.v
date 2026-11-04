// rondo_spi_slave: SPI pins -> rbus master (rondo_spi_phy + rondo_spi_ctrl).
module rondo_spi_slave #(
    parameter SYNC_STAGES = 2,
    parameter CRC = 1
) (
    input         clk,
    input         rst_n,
    input         spi_sclk,
    input         spi_cs_n,
    input         spi_mosi,
    output        spi_miso,
    output        spi_miso_oe,
    // rbus master (rb_req_int is driven 0 by the user of this module)
    output        rb_req_valid,
    input         rb_req_ready,
    output        rb_req_we,
    output [23:0] rb_req_addr,
    output [31:0] rb_req_wdata,
    input         rb_rsp_valid,
    output        rb_rsp_ready,
    input  [31:0] rb_rsp_rdata,
    input         rb_rsp_err,
    input  [7:0]  status8,
    input         crc_en,
    output        err_frame,
    output        err_crc,
    output        frame_end,
    output        cs_active
);
    wire        frame_start, rx_valid, tx_need, mid_abort, lb_mode, tx_load;
    wire [7:0]  rx_byte, tx_byte;
    wire        phy_frame_end;

    rondo_spi_phy #(.SYNC_STAGES(SYNC_STAGES)) u_phy (
        .clk(clk), .rst_n(rst_n), .sclk(spi_sclk), .cs_n(spi_cs_n), .mosi(spi_mosi),
        .cs_active(cs_active), .frame_start(frame_start), .frame_end(phy_frame_end),
        .rx_byte(rx_byte), .rx_valid(rx_valid), .status8(status8),
        .tx_byte(tx_byte), .tx_load(tx_load), .tx_need(tx_need),
        .mid_byte_abort(mid_abort), .lb_mode(lb_mode),
        .miso(spi_miso), .miso_oe(spi_miso_oe));

    rondo_spi_ctrl #(.CRC(CRC)) u_ctrl (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .frame_end(phy_frame_end),
        .rx_valid(rx_valid), .rx_byte(rx_byte), .tx_need(tx_need),
        .mid_byte_abort(mid_abort), .tx_byte(tx_byte), .tx_load(tx_load),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we),
        .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata),
        .rb_rsp_valid(rb_rsp_valid), .rb_rsp_ready(rb_rsp_ready),
        .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err),
        .crc_en_in(crc_en), .err_frame(err_frame), .err_crc(err_crc), .frame_end_o(frame_end));
endmodule
