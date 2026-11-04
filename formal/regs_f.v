// Formal harness: rondo_regs with free inputs (RO/W1C/self-clearing/irq properties via the protocol checker + local asserts)
module regs_f (input clk);
    (* anyseq *) wire reg_re, reg_we, srst, active, busy, sr_running, sr_stopping, zvalid, fmt_applied;
    (* anyseq *) wire [7:0] reg_idx;
    (* anyseq *) wire [31:0] reg_wdata;
    (* anyseq *) wire [15:0] err_in;
    (* anyseq *) wire [3:0] xptr_status;
    (* anyseq *) wire kat_running, mbist_running, trc_armed, wstale_clr, wstale_set;
    (* anyseq *) wire ev_done, ev_sr_done, ev_trc_done, ev_selftest_done, ev_tile_slice, ev_tile_final;
    (* anyseq *) wire [1:0] lane_en_applied;
    (* anyseq *) wire [63:0] infer_cnt, busy_cyc, total_cyc, sr_cyc;
    (* anyseq *) wire frame_end, tile_open;
    (* anyseq *) wire [1:0] div_applied; (* anyseq *) wire src_applied_in;
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    always @* assume (!(reg_re && reg_we));
    wire [31:0] reg_rdata, status_o, err_status_o, irq_status_o;
    wire [31:0] irq_en_w, shd0;
    wire [7:0] status8;
    wire irq, err_any, acc_err;
    wire [1:0] clk_div; wire clk_src; wire [3:0] clkout_k;
    wire fmt_set, fmt_val; wire [1:0] xsel; wire [7:0] sr_n; wire [31:0] sr_count, wdog_limit; wire [1:0] lane_en;
    wire pwr_core_hold, pwr_clk_off, pwr_pg_inactive, spi_crc_en, dbg_latch, tile_slice_wr;
    wire [25:0] dbg_sel; wire [31:0] trc_cfg, trc_trig_cyc, tile_cfg, tile_slice;
    wire cmd_start, cmd_soft_rst, cmd_sr_start, cmd_sr_stop, cmd_cnt_clr, cmd_cksum_clr, cmd_crc_clr, cmd_kat_start,
         cmd_mbist_start, cmd_trc_arm, cmd_trc_force, cmd_guard_clr, cmd_tile_run, cmd_tile_abort;
    rondo_regs #(.WIDTH(16), .PDIM(8), .N_LANES(2), .NXBUF(4), .WAW(6), .BAW(3), .LNW(1), .TILE(1)) dut (
        .clk(clk), .rst_n(rst_n), .srst(srst), .reg_re(reg_re), .reg_we(reg_we), .reg_idx(reg_idx), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .err_in(err_in), .active(active), .busy(busy), .sr_running(sr_running),
        .sr_stopping(sr_stopping), .zvalid(zvalid), .fmt_applied(fmt_applied), .xptr_status(xptr_status),
        .lane_en_applied(lane_en_applied), .kat_running(kat_running), .mbist_running(mbist_running), .trc_armed(trc_armed),
        .wstale_clr(wstale_clr), .wstale_set(wstale_set), .ev_done(ev_done), .ev_sr_done(ev_sr_done), .ev_trc_done(ev_trc_done),
        .ev_selftest_done(ev_selftest_done), .ev_tile_slice(ev_tile_slice), .ev_tile_final(ev_tile_final),
        .last_cycles(32'd0), .infer_cnt(infer_cnt), .busy_cyc(busy_cyc), .total_cyc(total_cyc), .sr_cyc(sr_cyc),
        .sr_done_cnt(32'd0), .checksum(32'd0), .sr_pass_cksum(32'd0), .load_crc(32'd0), .guard_hits(32'd0), .naninf_cnt(32'd0),
        .dbg_data(32'd0), .trc_status(32'd0), .st_status(32'd0), .kat_sig_bf16(32'd0), .kat_sig_fp32(32'd0),
        .kat_got_bf16(32'd0), .kat_got_fp32(32'd0), .mbist_status(32'd0), .mbist_fail_addr(32'd0), .mbist_fail_xor(32'd0),
        .tile_status(32'd0), .tile_seq_crc(32'd0), .div_applied(div_applied), .src_applied_in(src_applied_in),
        .frame_end(frame_end), .tile_open(tile_open), .fmt_set(fmt_set), .fmt_val(fmt_val), .xsel(xsel), .sr_n(sr_n),
        .sr_count(sr_count), .wdog_limit(wdog_limit), .lane_en(lane_en), .clk_div(clk_div), .clk_src(clk_src),
        .clkout_k(clkout_k), .pwr_core_hold(pwr_core_hold), .pwr_clk_off(pwr_clk_off), .pwr_pg_inactive(pwr_pg_inactive),
        .spi_crc_en(spi_crc_en), .dbg_sel(dbg_sel), .dbg_latch(dbg_latch), .trc_cfg(trc_cfg), .trc_trig_cyc(trc_trig_cyc),
        .tile_cfg(tile_cfg), .tile_slice(tile_slice), .tile_slice_wr(tile_slice_wr), .cmd_start(cmd_start),
        .cmd_soft_rst(cmd_soft_rst), .cmd_sr_start(cmd_sr_start), .cmd_sr_stop(cmd_sr_stop), .cmd_cnt_clr(cmd_cnt_clr),
        .cmd_cksum_clr(cmd_cksum_clr), .cmd_crc_clr(cmd_crc_clr), .cmd_kat_start(cmd_kat_start),
        .cmd_mbist_start(cmd_mbist_start), .cmd_trc_arm(cmd_trc_arm), .cmd_trc_force(cmd_trc_force),
        .cmd_guard_clr(cmd_guard_clr), .cmd_tile_run(cmd_tile_run), .cmd_tile_abort(cmd_tile_abort), .irq(irq),
        .status8(status8), .acc_err(acc_err), .err_any(err_any), .status_o(status_o), .err_status_o(err_status_o),
        .irq_status_o(irq_status_o), .irq_en_o(irq_en_w), .shd0_o(shd0));
    wire [7:0] viol;
    rondo_sva_regs chk (.clk(clk), .rst_n(rst_n), .reg_re(reg_re), .reg_we(reg_we), .reg_idx(reg_idx), .reg_wdata(reg_wdata),
        .reg_rdata(reg_rdata), .err_status(err_status_o), .err_in(err_in), .srst(srst), .irq_status_eff(irq_status_o),
        .irq_en(irq_en_w), .irq(irq), .pair0_val(infer_cnt), .pair1_val(busy_cyc), .viol(viol));
    // self-clearing command bits: a command pulse implies a CTRL write in the previous cycle, and is a single-cycle pulse
    reg we_ctrl_q, c_start_q;
    reg [31:0] w_q, shd0_q, hi_q; reg re_lo_q, srst_q;
    always @(posedge clk) begin
        shd0_q <= shd0; hi_q <= infer_cnt[63:32]; re_lo_q <= reg_re && reg_idx == 8'h21; srst_q <= srst;
        we_ctrl_q <= reg_we && reg_idx == 8'h0A; w_q <= reg_wdata; c_start_q <= cmd_start;
    end
    always @(posedge clk) if (!init) begin
        assert (!viol[0]); assert (!viol[1]); assert (!viol[2]); assert (!viol[3]); assert (!viol[4]);
        if (cmd_start) assert (we_ctrl_q && w_q[0]);
        if (cmd_soft_rst) assert (we_ctrl_q && w_q[1]);
        if (cmd_start && c_start_q) assert (we_ctrl_q);     // back-to-back pulses need back-to-back writes
        assert (!(cmd_start && cmd_sr_start));              // at most one start-class command per write
        assert (!(cmd_start && cmd_kat_start) && !(cmd_start && cmd_mbist_start) && !(cmd_sr_start && cmd_tile_run));
        if (reg_re && reg_idx == 8'h0A) assert (reg_rdata == 32'd0);
        if (reg_re && reg_idx == 8'h22) assert (reg_rdata == shd0);                       // HI returns the shadow
        if (shd0 != shd0_q) assert ((re_lo_q && shd0 == hi_q) || srst_q);   // shadow changes only at a LO read or a soft reset (spec 9.6)
        if (srst_q) assert (shd0 == 32'd0);                                               // the 64-bit read shadow is 0 in the cycle after a soft-reset cycle
        assert (!viol[4] || 1'b1);
        if (reg_re && reg_idx == 8'h00) assert (reg_rdata == 32'h524F4E44);
        if (reg_re && reg_idx == 8'h01) assert (reg_rdata == 32'h00020101);
    end
    always @(posedge clk) if (!init) begin
        cover (cmd_start);
        cover (cmd_soft_rst);
        cover (|err_status_o);
        cover (irq);
    end
endmodule
