`timescale 1ns/1ps
`include "uvm_macros.svh"
`include "cfg_pkg.svh"
import uvm_pkg::*;
import rondo_pkg::*;
// One top for both configurations: -d TOP_DEV  (rondo_dev, rbus agent drives the external port, fast)
//                                   -d TOP_CHIP (rondo_chip_top, SPI agent drives the pins)
module tb_top;
  localparam W = `C_WIDTH, P = `C_PDIM, L = `C_LANES;
  logic clk = 0, clk_alt = 0;
  clk_if clkc (.dummy(1'b0));
  initial forever begin #(clkc.half0) clk = ~clk; end
  initial forever begin if (clkc.run1) begin #(clkc.half1) clk_alt = ~clk_alt; end else #1; end
  wire dev_clk;
  rbus_if rbus (.clk(dev_clk));
  pins_if pins (.dummy(1'b0));
  spi_if  spi (.core_clk(dev_clk));
  probe_if probe (.clk(dev_clk));
`ifdef TOP_CHIP
  rondo_chip_top #(.DEPTH(`C_DEPTH), .WIDTH(W), .PDIM(P), .N_LANES(L), .NSLOT(`C_NSLOT), .NPAR(`C_NPAR), .NXBUF(`C_NXBUF),
      .ACCSIG_BF16(`C_ACCSIG), .DBG(`C_DBG), .TRACE(`C_TRACE), .KAT(`C_KAT), .MBIST(`C_MBIST), .SCAN(`C_SCAN), .PG(`C_PG),
      .SPI_CRC(`C_SPI_CRC), .CLK_ALT(`C_CLK_ALT), .HB_BIT(`C_HB_BIT), .TILE(`C_TILE), .TILE_B(`C_TILE_B), .LAYER(`C_LAYER), .CNT_INIT(`C_CNT_INIT)) dut (
    .clk(clk), .clk_alt(clk_alt), .rst_n(pins.rst_n), .spi_sclk(spi.sclk), .spi_cs_n(spi.cs_n), .spi_mosi(spi.mosi), .spi_miso(spi.miso),
    .spi_miso_oe(spi.miso_oe), .irq(pins.irq), .busy(pins.busy), .st_pass(pins.st_pass), .bist_en(pins.bist_en), .clkout(pins.clkout),
    .test_mode_pin(pins.test_mode_pin), .pg_req(pins.pg_req));
  `define DEVP dut.u_dev
  assign probe.clk_alt_dummy = 1'b0;
  // passive monitor view of the device's external rbus port (the SPI slave is the master)
  assign rbus.rst_n = dut.sys_rst_n;
  assign rbus.req_valid = dut.u_dev.rb_req_valid;  assign rbus.req_ready = dut.u_dev.rb_req_ready; assign rbus.req_we = dut.u_dev.rb_req_we;
  assign rbus.req_addr = dut.u_dev.rb_req_addr;   assign rbus.req_wdata = dut.u_dev.rb_req_wdata;
  assign rbus.rsp_valid = dut.u_dev.rb_rsp_valid; assign rbus.rsp_ready = dut.u_dev.rb_rsp_ready;
  assign rbus.rsp_rdata = dut.u_dev.rb_rsp_rdata; assign rbus.rsp_err = dut.u_dev.rb_rsp_err;
  assign dev_clk = dut.clk_core;
`else
  wire irq_w, busy_w, stp_w, clkout_w, clk_src_w, crc_en_w; wire [7:0] status8_w; wire [1:0] clk_div_w, pg_w, lclk_w;
  assign rbus.rst_n = pins.rst_n;
  wire [31:0] rd_w;
  wire req_ready_w, rsp_valid_w, rsp_err_w;
  rondo_dev #(.DEPTH(`C_DEPTH), .WIDTH(W), .PDIM(P), .N_LANES(L), .NSLOT(`C_NSLOT), .NPAR(`C_NPAR), .NXBUF(`C_NXBUF), .ACCSIG_BF16(`C_ACCSIG),
      .DBG(`C_DBG), .TRACE(`C_TRACE), .KAT(`C_KAT), .MBIST(`C_MBIST), .SCAN(`C_SCAN), .PG(`C_PG), .SPI_CRC(`C_SPI_CRC), .CLK_ALT(`C_CLK_ALT),
      .HB_BIT(`C_HB_BIT), .TILE(`C_TILE), .TILE_B(`C_TILE_B), .LAYER(`C_LAYER), .CNT_INIT(`C_CNT_INIT)) dut (
    .clk(clk), .rst_n(pins.rst_n), .test_mode(1'b0), .rb_req_valid(rbus.req_valid), .rb_req_ready(rbus.req_ready), .rb_req_we(rbus.req_we),
    .rb_req_addr(rbus.req_addr), .rb_req_wdata(rbus.req_wdata), .rb_rsp_valid(rbus.rsp_valid), .rb_rsp_ready(rbus.rsp_ready),
    .rb_rsp_rdata(rbus.rsp_rdata), .rb_rsp_err(rbus.rsp_err), .irq(pins.irq), .busy_pin(pins.busy), .st_pass(pins.st_pass), .status8(status8_w),
    .clkout(pins.clkout), .clk_div(clk_div_w), .clk_src(clk_src_w), .crc_en(crc_en_w), .div_applied(2'b00), .src_applied(1'b0),
    .spi_err_frame(1'b0), .spi_err_crc(1'b0), .spi_frame_end(1'b0), .bist_strap(pins.bist_en), .pg_req(pins.pg_req), .lclk_obs(lclk_w),
    .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());
  `define DEVP dut
  assign dev_clk = clk;
  assign pins.test_mode_pin = 1'b0;
`endif
  wire sva_rst_n = rbus.rst_n;
`ifndef NO_SVA
    wire [7:0] v_rbus, v_regs, v_seq, v_wmem, v_spare;
    rondo_sva_rbus u_sva_rbus (.clk(dev_clk), .rst_n(sva_rst_n), .req_valid(rbus.req_valid), .req_ready(rbus.req_ready),
        .req_we(rbus.req_we), .req_addr(rbus.req_addr), .req_wdata(rbus.req_wdata), .rsp_valid(rbus.rsp_valid),
        .rsp_ready(rbus.rsp_ready), .viol(v_rbus));
    rondo_sva_regs u_sva_regs (.clk(dev_clk), .rst_n(sva_rst_n), .reg_re(`DEVP.reg_re_s), .reg_we(`DEVP.reg_we_s),
        .reg_idx(`DEVP.q_addr[7:0]), .reg_wdata(`DEVP.q_wdata), .reg_rdata(`DEVP.reg_rdata),
        .err_status(`DEVP.reg_err_o), .err_in(`DEVP.err_in), .srst(`DEVP.srst),
        .irq_status_eff(`DEVP.reg_irq_o), .irq_en(`DEVP.u_regs.irq_en), .irq(`DEVP.irq),
        .pair0_val(`DEVP.infer_cnt), .pair1_val(`DEVP.busy_cyc), .viol(v_regs));
    rondo_sva_seq #(.XW(`C_PDIM*32), .ZW(`C_WIDTH*32)) u_sva_seq (.clk(dev_clk), .rst_n(sva_rst_n),
        .start(`DEVP.layer_start), .busy(`DEVP.layer_busy), .done(`DEVP.layer_done),
        .layer_rst_n(`DEVP.fmt_applied ? `DEVP.core_rst_n[1] : `DEVP.core_rst_n[0]), .x(`DEVP.x_live),
        .zbuf_sig(`DEVP.zbuf_r), .zcap(`DEVP.zcap), .zclr(`DEVP.srst | `DEVP.fsw_pulse), .mem_wr_ext(`DEVP.pk_en & `DEVP.pk_we & ~`DEVP.q_int),
        .active(`DEVP.active), .inactive_clk_en(`DEVP.fmt_applied ? `DEVP.clk_en[0] : `DEVP.clk_en[1]),
        .inactive_rst_n(`DEVP.fmt_applied ? `DEVP.core_rst_n[0] : `DEVP.core_rst_n[1]), .viol(v_seq));
    rondo_sva_wmem u_sva_wmem (.clk(dev_clk), .rst_n(sva_rst_n), .fmt(`DEVP.fmt_applied), .ce_l_any(`DEVP.ce_l_any),
        .wp_en(`DEVP.u_mem.wp_en), .wp_half(`DEVP.u_mem.wp_half), .wp_denied(`DEVP.wp_denied), .viol(v_wmem));
  assign probe.sva_viol = {8'd0, v_wmem, v_seq, v_regs, v_rbus};
`else
  assign probe.sva_viol = 40'd0;
`endif
`ifdef TOP_CHIP
  // time-based clock glitch check on clk_core: no pulse narrower than the shortest source half period (reset window exempt)
  real t_last = 0.0; bit seen_edge = 0; real w_ns;
  initial probe.clk_glitches = 0;
  always @(dev_clk) begin
    w_ns = $realtime - t_last;
    if (seen_edge && pins.rst_n && sva_rst_n && (w_ns < 0.9 * ((clkc.half0 < clkc.half1) ? clkc.half0 : clkc.half1))) probe.clk_glitches = probe.clk_glitches + 1;
    t_last = $realtime; seen_edge = 1;
  end
`endif
  // internal observation (same names in both tops through DEVP)
  assign probe.rst_n = rbus.rst_n;
  assign probe.active = `DEVP.active;       assign probe.seq_active = `DEVP.seq_active;
  assign probe.layer_start = `DEVP.layer_start; assign probe.layer_busy = `DEVP.layer_busy; assign probe.layer_done = `DEVP.layer_done;
  assign probe.zcap = `DEVP.zcap;           assign probe.fmt_applied = `DEVP.fmt_applied; assign probe.tile_open = (`C_TILE != 0) ? `DEVP.tl_open : 1'b0;
  assign probe.sr_running = `DEVP.sr_running; assign probe.sr_stopping = `DEVP.sr_stopping; assign probe.zvalid = `DEVP.zvalid;
  assign probe.srst = `DEVP.srst;           assign probe.kat_active = `DEVP.kat_active;   assign probe.mbist_active = `DEVP.mbist_active;
  assign probe.lane_en_applied = 32'(`DEVP.lane_en_applied);
  assign probe.o_req_valid = `DEVP.o_req_valid; assign probe.o_req_ready = `DEVP.o_req_ready; assign probe.o_req_we = `DEVP.o_req_we;
  assign probe.o_req_int = `DEVP.o_req_int; assign probe.o_req_addr = `DEVP.o_req_addr; assign probe.o_req_wdata = `DEVP.o_req_wdata;
  initial begin
    uvm_config_db#(virtual rbus_if)::set(null, "*", "rbus_vif", rbus);
    uvm_config_db#(virtual pins_if)::set(null, "*", "pins_vif", pins);
    uvm_config_db#(virtual spi_if)::set(null, "*", "spi_vif", spi);
    uvm_config_db#(virtual probe_if)::set(null, "*", "probe_vif", probe);
    uvm_config_db#(virtual clk_if)::set(null, "*", "clk_vif", clkc);
    run_test();
  end
`ifdef TOP_CHIP
  initial begin pins.rst_n = 1'b0; pins.bist_en = 1'b0; end
`else
  initial begin pins.rst_n = 1'b0; pins.bist_en = 1'b0; end
`endif
endmodule
