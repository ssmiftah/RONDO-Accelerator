// Formal harness: rondo_seq with an abstract layer (busy/done after start, bounded latency).
module seq_f (input clk);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    (* anyseq *) wire c_start, c_soft, c_sr, c_stop, c_cnt, c_cks, c_guard, fmt_set, fmt_val, hold, clkoff, go, kat_run, wstale;
    (* anyseq *) wire [1:0] xsel; (* anyseq *) wire [7:0] sr_n; (* anyseq *) wire [31:0] sr_count, wdog;
    (* anyseq *) wire [1:0] ghit_i;
    always @* if (!init) begin
        assume (!(c_start && c_sr));                  // regs never raises two start-class commands together
        assume (!(kat_run && (c_start || c_sr)));
        assume (!(fmt_set && seq_active));            // rondo_regs blocks FORMAT writes while ACTIVE
        assume (!((c_start || c_sr || kat_run) && seq_active));
        assume (!seq_active || (hold == hold_q && clkoff == clkoff_q));   // PWR_CTRL writes are blocked while ACTIVE
        assume (sr_n >= 8'd1 && sr_n <= 8'd4);
        assume (sr_count <= 32'd3);
    end
    reg hold_q, clkoff_q; reg [31:0] cnt_cap;
    always @(posedge clk) begin hold_q <= hold; clkoff_q <= clkoff; if (c_sr) cnt_cap <= sr_count; end
    wire layer_start, zcap, srst, sr_running, sr_stopping, zvalid, fsw_pulse, seq_active, fmt_applied;
    wire [1:0] core_rst_n, clk_en; wire [1:0] xptr; wire [1:0] lane_applied; wire [3:0] xps;
    wire [31:0] last_cycles, sr_done_cnt, checksum, sr_pass, guard_hits, naninf; wire [63:0] infer_cnt, busy_cyc, total_cyc, sr_cyc;
    wire ev_done, ev_sr_done, ev_wdog, ev_naninf, ev_guard, ev_ws, ev_sb, kat_done; wire [31:0] kat_sig; wire [1:0] pg_req;
    // abstract layer
    reg lbusy, ldone; reg [3:0] lcnt;
    wire layer_rst = fmt_applied ? core_rst_n[1] : core_rst_n[0];
    always @(posedge clk) begin
        if (init || !layer_rst) begin lbusy <= 1'b0; ldone <= 1'b0; lcnt <= 4'd0; end
        else begin
            ldone <= 1'b0;
            if (layer_start && !lbusy) begin lbusy <= 1'b1; lcnt <= 4'd0; end
            else if (lbusy) begin
                lcnt <= lcnt + 4'd1;
                if (lcnt >= 4'd6 && (go || lcnt >= 4'd10)) begin lbusy <= 1'b0; ldone <= 1'b1; end
            end
        end
    end
    wire [1:0] ghit = lbusy ? ghit_i : 2'b00;
    rondo_seq #(.WIDTH(4), .N_LANES(2), .NXBUF(4), .CKSUM_PAR(0), .PG(0)) dut (
        .clk(clk), .rst_n(rst_n), .test_mode(1'b0), .cmd_start(c_start), .cmd_soft_rst(c_soft), .cmd_sr_start(c_sr),
        .cmd_sr_stop(c_stop), .cmd_cnt_clr(c_cnt), .cmd_cksum_clr(c_cks), .cmd_guard_clr(c_guard), .tile_launch(1'b0), .tile_last(1'b1), .tile_done_p(), .tile_fail_p(), .fmt_set(fmt_set),
        .fmt_val(fmt_val), .xsel(xsel), .sr_n(sr_n), .sr_count(sr_count), .wdog_limit(wdog), .lane_en(2'b11),
        .pwr_core_hold(hold), .pwr_clk_off(clkoff), .pwr_pg_inactive(1'b0), .pg_req(pg_req), .wstale(wstale),
        .kat_run(kat_run), .kat_n(8'd2), .kat_count(32'd2), .kat_done(kat_done), .kat_sig(kat_sig), .kat_clr(1'b0),
        .layer_start(layer_start), .layer_busy(lbusy), .layer_done(ldone), .guard_hit(ghit), .core_rst_n(core_rst_n),
        .clk_en(clk_en), .fmt_applied(fmt_applied), .xptr(xptr), .zcap(zcap), .zbuf(128'd0), .lane_en_applied(lane_applied),
        .seq_active(seq_active), .sr_running(sr_running), .sr_stopping(sr_stopping), .zvalid(zvalid), .srst(srst),
        .fsw_pulse(fsw_pulse), .xptr_status(xps), .last_cycles(last_cycles), .infer_cnt(infer_cnt), .busy_cyc(busy_cyc),
        .total_cyc(total_cyc), .sr_cyc(sr_cyc), .sr_done_cnt(sr_done_cnt), .checksum(checksum), .sr_pass_cksum(sr_pass),
        .guard_hits(guard_hits), .naninf_cnt(naninf), .ev_done(ev_done), .ev_sr_done(ev_sr_done), .ev_wdog(ev_wdog),
        .ev_naninf(ev_naninf), .ev_guard(ev_guard), .ev_wstale_run(ev_ws), .ev_start_busy(ev_sb));
    // protocol checker (launch rule 10.2, inactive layer rules)
    wire [7:0] viol;
    rondo_sva_seq #(.XW(8), .ZW(8)) chk (.clk(clk), .rst_n(rst_n), .start(layer_start), .busy(lbusy), .done(ldone),
        .layer_rst_n(layer_rst), .x(8'd0), .zbuf_sig(8'd0), .zcap(1'b0), .zclr(1'b0), .mem_wr_ext(1'b0), .active(seq_active),
        .inactive_clk_en(fmt_applied ? clk_en[0] : clk_en[1]), .inactive_rst_n(fmt_applied ? core_rst_n[0] : core_rst_n[1]),
        .viol(viol));
    reg [63:0] inf_q, busy_q, tot_q; reg cnt_clr_q, srst_q; reg [31:0] sd_q; reg sr_q;
    always @(posedge clk) begin inf_q <= infer_cnt; busy_q <= busy_cyc; tot_q <= total_cyc; cnt_clr_q <= c_cnt; srst_q <= srst; sd_q <= sr_done_cnt; sr_q <= sr_running; end
    always @* if (!init) begin
        assert (!viol[0] && !viol[1] && !viol[2] && !viol[3] && !viol[7]);
        // counters are monotonic except for the clear commands / soft reset
        if (!cnt_clr_q && !srst_q && !srst && !c_soft) begin
            assert (infer_cnt >= inf_q); assert (busy_cyc >= busy_q); assert (total_cyc >= tot_q);
        end
        // at most one layer is running; the layer never runs while its reset is low
        assert (!(core_rst_n == 2'b11));
        // a self-run never completes more inferences than SR_COUNT (when non-zero)
        if (cnt_cap != 32'd0 && sr_running) assert (sr_done_cnt <= cnt_cap);
        // layer_start is a single-cycle pulse and only issued when idle
        assert (!(layer_start && lbusy));
    end
    always @* if (!init) begin
        cover (ev_done);
        cover (ev_sr_done && sr_done_cnt == 32'd2);
        cover (sr_running && sr_stopping);
        cover (fsw_pulse);
        cover (hold && seq_active);
        cover (srst);
    end
endmodule
