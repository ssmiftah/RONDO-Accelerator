// genesys2_pi_top: FPGA prototype of the RONDO chip for a Digilent Genesys 2, driven by a Raspberry Pi 5 over SPI on Pmod JA/JB
// (spec 13.23, 13.25). Same rondo_spi_slave + rondo_dev as the chip; only the clocking differs (MMCM instead of the external
// oscillator, no clock mux / divider). Build with -verilog_define RONDO_FPGA (no clock gating) or RONDO_FPGA_BUFGCE.
//   FORMATS: 1 = bf16 only, 2 = fp32 only, 3 = both (the host reads CAPS[1:0]; one bitstream per format is acceptable, Q8).
module genesys2_pi_top #(
    parameter DEPTH = 7, WIDTH = 64, PDIM = 40, N_LANES = 8, NSLOT = 8, NPAR = 8, NXBUF = 4,
    parameter ACCSIG_BF16 = 8, TBITS_FP32 = 8, NR_ITERS_FP32 = 2,
    parameter FORMATS = 3,
    parameter DBG = 1, TRACE = 1, KAT = 1, MBIST = 0,
    parameter real CLK_DIV = 10.0,            // 1000 MHz VCO / 10 = 100 MHz
    parameter HB_BIT = 26                     // heartbeat toggles every 2^26 cycles (0.67 s at 100 MHz)
) (
    input        sysclk_p,
    input        sysclk_n,
    input        cpu_resetn,
    input  [1:0] sw,
    output [7:0] led,
    // Pmod JA (SPI + control), Pmod JB (self-test)
    input        ja_cs_n,
    input        ja_mosi,
    output       ja_miso,
    input        ja_sclk,
    output       ja_irq,
    output       ja_busy,
    input        ja_rst_n,
    output       ja_clkout,
    output       jb_st_pass,
    input        jb_bist_en
);
    // ---- clocking -------------------------------------------------------------------------------------------
    wire sysclk, clk_fb, clk_u, clock, locked;
    IBUFDS #(.DIFF_TERM("TRUE"), .IBUF_LOW_PWR("FALSE")) u_ibufds (.I(sysclk_p), .IB(sysclk_n), .O(sysclk));
    MMCME2_BASE #(.CLKIN1_PERIOD(5.000), .CLKFBOUT_MULT_F(5.000), .CLKOUT0_DIVIDE_F(CLK_DIV), .DIVCLK_DIVIDE(1)) u_mmcm (
        .CLKIN1(sysclk), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb), .CLKOUT0(clk_u), .LOCKED(locked), .PWRDWN(1'b0), .RST(1'b0),
        .CLKOUT1(), .CLKOUT2(), .CLKOUT3(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(), .CLKOUT0B(), .CLKOUT1B(), .CLKOUT2B(),
        .CLKOUT3B(), .CLKFBOUTB());
    BUFG u_bufg (.I(clk_u), .O(clock));

    // reset: board button, MMCM lock and the Pi's rst_n line (Pmod pull-up), synchronised into the core clock
    wire rst_in_n = cpu_resetn & locked & ja_rst_n;
    wire sys_rst_n;
    rondo_reset_sync #(.STAGES(2)) u_rs (.clk(clock), .arst_n(rst_in_n), .test_mode(1'b0), .rst_n_out(sys_rst_n));

    // strap: bist_en sampled while in reset
    reg strap;
    always @(posedge clock) if (!sys_rst_n) strap <= jb_bist_en;

    // ---- SPI slave + device -----------------------------------------------------------------------------------
    wire rb_req_valid, rb_req_ready, rb_req_we, rb_rsp_valid, rb_rsp_ready, rb_rsp_err;
    wire [23:0] rb_req_addr; wire [31:0] rb_req_wdata, rb_rsp_rdata;
    wire [7:0] status8; wire crc_en, err_frame, err_crc, frame_end, cs_active, miso_i, miso_oe;
    rondo_spi_slave #(.SYNC_STAGES(2), .CRC(1)) u_spi (
        .clk(clock), .rst_n(sys_rst_n), .spi_sclk(ja_sclk), .spi_cs_n(ja_cs_n), .spi_mosi(ja_mosi),
        .spi_miso(miso_i), .spi_miso_oe(miso_oe), .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready),
        .rb_req_we(rb_req_we), .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid),
        .rb_rsp_ready(rb_rsp_ready), .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err), .status8(status8),
        .crc_en(crc_en), .err_frame(err_frame), .err_crc(err_crc), .frame_end(frame_end), .cs_active(cs_active));
    assign ja_miso = miso_oe ? miso_i : 1'bz;                 // OBUFT, tri-stated while CS is deselected

    wire irq_d, busy_d, stp_d, clkout_d, fmt_o, hb_o, err_any_o; wire [31:0] cks; wire [1:0] cdiv, pg, lobs; wire csrc;
    rondo_dev #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM), .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR), .NXBUF(NXBUF),
        .ACCSIG_BF16(ACCSIG_BF16), .TBITS_FP32(TBITS_FP32), .NR_ITERS_FP32(NR_ITERS_FP32),
        .HAS_BF16((FORMATS & 1) != 0), .HAS_FP32((FORMATS & 2) != 0), .DBG(DBG), .TRACE(TRACE), .KAT(KAT), .MBIST(MBIST),
        .CLK_ALT(0), .HB_BIT(HB_BIT)) u_dev (
        .clk(clock), .rst_n(sys_rst_n), .test_mode(1'b0), .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready),
        .rb_req_we(rb_req_we), .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid),
        .rb_rsp_ready(rb_rsp_ready), .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err), .irq(irq_d), .busy_pin(busy_d),
        .st_pass(stp_d), .status8(status8), .clkout(clkout_d), .clk_div(cdiv), .clk_src(csrc), .crc_en(crc_en),
        .div_applied(2'b00), .src_applied(1'b0), .spi_err_frame(err_frame), .spi_err_crc(err_crc),
        .spi_frame_end(frame_end), .bist_strap(strap), .pg_req(pg), .lclk_obs(lobs), .checksum_o(cks), .fmt_o(fmt_o),
        .heartbeat_o(hb_o), .err_any_o(err_any_o));

    reg irq_r, busy_r, stp_r, clko_r;
    always @(posedge clock or negedge sys_rst_n) begin
        if (!sys_rst_n) begin irq_r <= 1'b0; busy_r <= 1'b0; stp_r <= 1'b0; clko_r <= 1'b0; end
        else begin irq_r <= irq_d; busy_r <= busy_d; stp_r <= stp_d; clko_r <= clkout_d; end
    end
    assign ja_irq = irq_r; assign ja_busy = busy_r; assign jb_st_pass = stp_r; assign ja_clkout = clko_r;

    // ---- LEDs: sw[1] = 0 -> checksum folded to a byte (as genesys2_fused_top); 1 -> status flags --------------------
    wire [7:0] cks_led = cks[7:0] ^ cks[15:8] ^ cks[23:16] ^ cks[31:24];
    assign led = sw[1] ? {hb_o, locked, ~sys_rst_n, busy_r, irq_r, stp_r, fmt_o, err_any_o} : cks_led;
endmodule
