`timescale 1ns/1ps
`include "cfg_pkg.svh"
// V1 smoke (no UVM): rondo_dev, one rbus write/read, one bf16 and one fp32 inference vs the C model; cycles/s measurement.
module smoke_dev;
  localparam W = `C_WIDTH, P = `C_PDIM, L = `C_LANES, NS = `C_NSLOT, NP = `C_NPAR, D = `C_DEPTH, NX = `C_NXBUF;
  localparam NLAD = W/L, NCH = NS*D, NGRP = NCH/NP, NB = NLAD/NS, NWORDS = NB*NGRP*P, NBW = NB*NGRP;
  localparam WAW = $clog2(NWORDS), BAW = $clog2(NBW), FW = $clog2(NP), XW = $clog2(P);
  localparam int WEIGHT_BASE = 24'h800000, BIAS_BASE = 24'h100000, XBUF_BASE = 24'h010000, ZBUF_BASE = 24'h020000;
  `include "rondo_dpi.svh"
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic rb_req_valid = 0, rb_req_we = 0; logic [23:0] rb_req_addr = 0; logic [31:0] rb_req_wdata = 0;
  wire rb_req_ready, rb_rsp_valid; logic rb_rsp_ready = 1; wire [31:0] rb_rsp_rdata; wire rb_rsp_err;
  wire irq, busy_pin, st_pass, clkout, clk_src, crc_en; wire [7:0] status8; wire [1:0] clk_div, pg_req, lclk_obs;
  rondo_dev #(.DEPTH(D), .WIDTH(W), .PDIM(P), .N_LANES(L), .NSLOT(NS), .NPAR(NP), .NXBUF(NX), .ACCSIG_BF16(`C_ACCSIG),
      .DBG(`C_DBG), .TRACE(`C_TRACE), .KAT(`C_KAT), .MBIST(`C_MBIST), .TILE(`C_TILE), .TILE_B(`C_TILE_B), .HB_BIT(`C_HB_BIT), .LAYER(`C_LAYER), .SCAN(`C_SCAN), .PG(`C_PG), .SPI_CRC(`C_SPI_CRC), .CLK_ALT(`C_CLK_ALT), .CNT_INIT(`C_CNT_INIT)) dut (
    .clk(clk), .rst_n(rst_n), .test_mode(1'b0), .rb_req_valid(rb_req_valid), .rb_req_ready(rb_req_ready), .rb_req_we(rb_req_we),
    .rb_req_addr(rb_req_addr), .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rb_rsp_valid), .rb_rsp_ready(rb_rsp_ready),
    .rb_rsp_rdata(rb_rsp_rdata), .rb_rsp_err(rb_rsp_err), .irq(irq), .busy_pin(busy_pin), .st_pass(st_pass), .status8(status8),
    .clkout(clkout), .clk_div(clk_div), .clk_src(clk_src), .crc_en(crc_en), .div_applied(2'b00), .src_applied(1'b0),
    .spi_err_frame(1'b0), .spi_err_crc(1'b0), .spi_frame_end(1'b0), .bist_strap(1'b0), .pg_req(pg_req), .lclk_obs(lclk_obs),
    .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());
  int errors = 0;
  task automatic rb(input bit we, input [23:0] a, input [31:0] d, output [31:0] q, output bit err);
    @(negedge clk); rb_req_valid = 1; rb_req_we = we; rb_req_addr = a; rb_req_wdata = d;
    do @(posedge clk); while (!rb_req_ready);
    #1; @(negedge clk); rb_req_valid = 0;
    while (!rb_rsp_valid) @(negedge clk);
    q = rb_rsp_rdata; err = rb_rsp_err;
  endtask
  task automatic wr(input [23:0] a, input [31:0] d); logic [31:0] q; bit e; rb(1, a, d, q, e); if (e) begin errors++; $display("wr err @%h", a); end endtask
  task automatic rd(input [23:0] a, output [31:0] q); bit e; rb(0, a, 0, q, e); endtask
  function automatic logic [31:0] rnd_el(input int is32, input int lo, input int hi);
    logic [31:0] s, e, m; s = $urandom_range(1); e = 127 + $urandom_range(hi - lo) + lo; m = $urandom;
    return is32 ? {s[0], e[7:0], m[22:0]} : {16'd0, s[0], e[7:0], m[6:0]};
  endfunction
  task automatic run_fmt(input int is32);
    logic [31:0] q, el; int lane, caddr, f, c; longint unsigned zc, zm; int mism = 0; longint cyc0; time t0;
    wr(24'h10, is32);                          // FORMAT
    q = 2; while (q[1]) rd(24'h0B, q);          // wait !ACTIVE (format switch)
    fpm_cfg(W, P, D, L, NS, NP, NX);
    for (lane = 0; lane < L; lane++) begin
      for (caddr = 0; caddr < NWORDS; caddr++) for (f = 0; f < NP; f++) begin
        el = rnd_el(is32, -4, -1); fpm_set_w(lane, caddr, f, el);
        wr(WEIGHT_BASE + (lane << (WAW + FW)) + (caddr << FW) + f, el);
      end
      for (caddr = 0; caddr < NBW; caddr++) for (f = 0; f < NP; f++) begin
        el = rnd_el(is32, -2, 1); fpm_set_b(lane, caddr, f, el);
        wr(BIAS_BASE + (lane << (BAW + FW)) + (caddr << FW) + f, el);
      end
    end
    for (c = 0; c < P; c++) begin el = rnd_el(is32, -3, 0); fpm_set_x(c, el); wr(XBUF_BASE + c, el); end
    wr(24'h11, 0);                             // XSEL
    wr(24'h0C, 32'h7F);                        // clear IRQ_STATUS
    wr(24'h0A, 1);                             // CTRL.START
    q = 0; while (!q[0]) begin rd(24'h0C, q); end   // IRQ_STATUS.DONE
    rd(24'h0B, q);
    fpm_run(is32, is32 ? 0 : `C_ACCSIG, is32 ? 8 : 6, is32 ? 2 : 1, (1 << L) - 1);
    for (int j = 0; j < W; j++) begin
      rd(ZBUF_BASE + j, q); zm = fpm_z(j);
      if ({32'd0, q} != (is32 ? zm : (zm & 64'hFFFF))) begin mism++; if (mism < 4) $display("z[%0d] rtl %h model %h", j, q, zm); end
    end
    $display("SMOKE fmt=%s mismatches=%0d", is32 ? "fp32" : "bf16", mism); errors += mism;
    rd(24'h2D, q); $display("  GUARD_HITS=%0d", q);
  endtask
  longint unsigned cyc = 0; always @(posedge clk) cyc++;
  initial begin
    logic [31:0] q; bit e; time t0; longint c0; string cd;
    if (!$value$plusargs("CORE_DIR=%s", cd)) cd = "."; void'(fpm_load_seed(8, 6, cd)); void'(fpm_load_seed(24, 8, cd)); void'(fpm_load_seed(24, 12, cd));
    repeat (5) @(negedge clk); rst_n = 1; repeat (5) @(negedge clk);
    rd(24'h00, q); if (q !== 32'h524F4E44) begin errors++; $display("CHIP_ID %h", q); end
    rd(24'h01, q); $display("VERSION %h", q);
    wr(24'h09, 32'hA5A5_1234); rd(24'h09, q); if (q !== 32'hA5A5_1234) errors++;
    rd(24'h02, q); $display("CAPS %h", q);
    c0 = cyc; run_fmt(0); $display("  cycles for bf16 load+run: %0d", cyc - c0);
    c0 = cyc; run_fmt(1); $display("  cycles for fp32 load+run: %0d", cyc - c0);
    $display("SMOKE %s errors=%0d", errors == 0 ? "PASS" : "FAIL", errors); $finish;
  end
  initial begin #50ms; $display("SMOKE TIMEOUT"); $finish; end
endmodule
