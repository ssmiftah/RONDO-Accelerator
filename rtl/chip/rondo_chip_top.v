// rondo_chip_top: the RONDO chip (spec 3, 4, 13.22). Pins only; no pads, no PLL.
//   clk / clk_alt -> rondo_clk_mux -> rondo_clkdiv -> clk_core (everything runs on it)
//   rst_n -> rondo_reset_sync -> sys_rst_n
//   SPI pins -> rondo_spi_slave -> rondo_dev (registers, memories, both layers)
// All outputs come from flops and are 0 during reset.
module rondo_chip_top #(
    parameter DEPTH = 7, WIDTH = 64, PDIM = 40, N_LANES = 8, NSLOT = 8, NPAR = 8,
    parameter NXBUF = 4, CKSUM_PAR = 0,
    parameter ACCSIG_BF16 = 8, TBITS_FP32 = 8, NR_ITERS_FP32 = 2,
    parameter HAS_BF16 = 1, HAS_FP32 = 1, LAYER = 0,
    parameter DBG = 1, TRACE = 1, TRACE_DEPTH = 64, KAT = 1, MBIST = 0, SCAN = 0, PG = 0,
    parameter SPI_CRC = 1, CLK_ALT = 1, HB_BIT = 24, TILE = 1, TILE_B = 8,
    parameter CNT_INIT = 0,
    parameter [31:0] KAT_SIG_BF16 = 32'hFFFFFFFF, KAT_SIG_FP32 = 32'hFFFFFFFF,
    parameter SYNC_STAGES = 2,
    parameter F_CLK_HZ = 50_000_000            // documentation only
) (
    input  clk,
    input  clk_alt,
    input  rst_n,
    input  spi_sclk,
    input  spi_cs_n,
    input  spi_mosi,
    output spi_miso,
    output spi_miso_oe,
    output irq,
    output busy,
    output st_pass,
    input  bist_en,
    output clkout,
    input  test_mode_pin,                      // only meaningful if SCAN=1 (tied low otherwise)
    output [1:0] pg_req
);
    wire test_mode = (SCAN != 0) ? test_mode_pin : 1'b0;
    wire sys_rst_n, clk_core, clk_srcnet;
    wire [1:0] clk_div, div_applied;
    wire       clk_sel;

    rondo_reset_sync #(.STAGES(SYNC_STAGES)) u_rs (.clk(clk_core), .arst_n(rst_n), .test_mode(test_mode),
                                                   .rst_n_out(sys_rst_n));
    generate
        if (CLK_ALT != 0) begin : g_mux
            rondo_clk_mux u_mux (.clk0(clk), .clk1(clk_alt), .sel(clk_sel), .rst_n(sys_rst_n),
                                 .test_mode(test_mode), .clk_out(clk_srcnet));
        end else begin : g_nomux
            assign clk_srcnet = clk;
        end
    endgenerate
    rondo_clkdiv u_div (.clk_in(clk_srcnet), .rst_n(sys_rst_n), .div(clk_div), .test_mode(test_mode),
                        .clk_out(clk_core), .div_applied(div_applied));

    // bist_en strap: sampled while sys_rst_n is low, held after the release
    reg strap;
    always @(posedge clk_core) begin
        if (!sys_rst_n) strap <= bist_en;
    end

    // SPI slave <-> device
    wire rb_req_valid, rb_req_ready, rb_req_we, rb_rsp_valid, rb_rsp_ready, rb_rsp_err;
    wire [23:0] rb_req_addr;
    wire [31:0] rb_req_wdata, rb_rsp_rdata;
    wire [7:0] status8;
    wire crc_en, err_frame, err_crc, frame_end, cs_active, miso_i, miso_oe_i;
    wire dev_irq, dev_busy, dev_st_pass, dev_clkout;
    wire [1:0] dev_pg;
    wire [1:0] lclk_obs;
    rondo_spi_slave #(.SYNC_STAGES(SYNC_STAGES), .CRC(SPI_CRC)) u_spi (
        .clk(clk_core), .rst_n(sys_rst_n), .spi_sclk(spi_sclk), .spi_cs_n(spi_cs_n), .spi_mosi(spi_mosi),
        .spi_miso(miso_i), .spi_miso_oe(miso_oe_i),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we),
        .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid),
        .rb_rsp_ready(rb_rsp_ready), .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err),
        .status8(status8), .crc_en(crc_en), .err_frame(err_frame), .err_crc(err_crc),
        .frame_end(frame_end), .cs_active(cs_active));

    rondo_dev #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR),
        .NXBUF(NXBUF), .CKSUM_PAR(CKSUM_PAR), .ACCSIG_BF16(ACCSIG_BF16), .TBITS_FP32(TBITS_FP32),
        .NR_ITERS_FP32(NR_ITERS_FP32), .HAS_BF16(HAS_BF16), .HAS_FP32(HAS_FP32), .LAYER(LAYER), .DBG(DBG),
        .TRACE(TRACE), .TRACE_DEPTH(TRACE_DEPTH), .KAT(KAT), .MBIST(MBIST), .SCAN(SCAN), .PG(PG),
        .SPI_CRC(SPI_CRC), .CLK_ALT(CLK_ALT), .HB_BIT(HB_BIT), .TILE(TILE), .TILE_B(TILE_B),
        .CNT_INIT(CNT_INIT), .KAT_SIG_BF16(KAT_SIG_BF16), .KAT_SIG_FP32(KAT_SIG_FP32)) u_dev (
        .clk(clk_core), .rst_n(sys_rst_n), .test_mode(test_mode),
        .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we),
        .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid),
        .rb_rsp_ready(rb_rsp_ready), .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err),
        .irq(dev_irq), .busy_pin(dev_busy), .st_pass(dev_st_pass), .status8(status8), .clkout(dev_clkout),
        .clk_div(clk_div), .clk_src(clk_sel), .crc_en(crc_en), .div_applied(div_applied),
        .src_applied(clk_sel), .spi_err_frame(err_frame), .spi_err_crc(err_crc), .spi_frame_end(frame_end),
        .bist_strap(strap), .pg_req(dev_pg), .lclk_obs(lclk_obs),
        .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());

    // output flops (all outputs registered; 0 in reset)
    reg irq_r, busy_r, stp_r, clkout_r;
    always @(posedge clk_core or negedge sys_rst_n) begin
        if (!sys_rst_n) begin irq_r <= 1'b0; busy_r <= 1'b0; stp_r <= 1'b0; clkout_r <= 1'b0; end
        else begin irq_r <= dev_irq; busy_r <= dev_busy; stp_r <= dev_st_pass; clkout_r <= dev_clkout; end
    end
    assign irq     = irq_r;
    assign busy    = busy_r;
    assign st_pass = stp_r;
    assign clkout  = clkout_r;
    assign pg_req  = dev_pg;

    // test mode pin sharing (SCAN=1): scan_out = spi_miso with the output enable forced on
    generate
        if (SCAN != 0) begin : g_scan
            wire scan_en = bist_en;
            wire scan_in = spi_mosi;
            reg  scan_out_q;                       // stand-in for the chain tail (replaced by DFT insertion)
            always @(posedge clk) scan_out_q <= scan_in & scan_en;
            assign spi_miso    = test_mode ? scan_out_q : miso_i;
            assign spi_miso_oe = test_mode ? 1'b1 : miso_oe_i;
        end else begin : g_noscan
            assign spi_miso    = miso_i;
            assign spi_miso_oe = miso_oe_i;
        end
    endgenerate
endmodule
