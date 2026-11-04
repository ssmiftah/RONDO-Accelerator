`ifndef TKAT
`define TKAT 100
`endif
// FV-KAT: rondo_kat engine at a tiny geometry (N_LANES 1, NPAR 2, NWORDS 2, NBWORDS 1, PDIM 1, NXBUF 1): BMC to completion + progress.
// Free rbus slave (accept <= 3 cycles, response 1..4 cycles later, free read data), abstract sequencer that either answers (done) or refuses
// (fixed RTL: seq_fail pulse; pre-fix RTL: nothing, which is the B2 hang). One cmd_start, no strap, MBIST = 0.
module kat_f (input clk, input cmd_go, input fmt_i, input rdy_i, input rsp_i, input [31:0] rdat_i, input [3:0] dly_i, input refuse_i, input [31:0] sig_i, input srst_i);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
`ifdef WITH_SRST
    wire srst = srst_i && !init;
`else
    wire srst = 1'b0;
`endif
    // fmt_applied is a constant of the run (anyconst-style input)
    reg kc = 1'b1; always @(posedge clk) kc <= 1'b0; reg fmt_q; always @(posedge clk) fmt_q <= fmt_i; wire fmt = fmt_i;
    wire rb_v, rb_we; wire [23:0] rb_a; wire [31:0] rb_d; wire seq_run, sig_clr, fmt_set, fmt_val, mb_start, kat_active, running_kat, st_pass, ev_sel, ev_fail, ev_ws, ev_crc, ev_inv; wire [7:0] seq_n; wire [31:0] seq_count, stst, got_b, got_f;
    wire seq_done, seq_fail_w;
    // ---- environment ----
    reg cmd_sent = 1'b0; wire cmd_start = cmd_go && !cmd_sent && !init && !srst;
    always @(posedge clk) if (cmd_start) cmd_sent <= 1'b1;
    reg [2:0] wr; reg [3:0] age; reg pend; wire acc = rb_v && rdy_i; wire rsp_v = rsp_i && pend && age >= 4'd1;
    always @(posedge clk) begin
        if (init) begin wr <= 0; age <= 0; pend <= 0; end
        else begin wr <= (rb_v && !rdy_i) ? wr + 3'd1 : 3'd0;
            if (acc) begin pend <= 1'b1; age <= 4'd0; end else if (pend) age <= (age == 4'd15) ? age : age + 4'd1;
            if (rsp_v) pend <= 1'b0; end
    end
    always @* if (!init) begin
        assume (!(rb_v && wr >= 3'd1 && !rdy_i));                       // A: ready within 1 cycle of waiting (spec 8.3; FV-DEV.rb)
        assume (!(pend && age >= 4'd3 && !rsp_i));                       // A: response within 3 cycles
        assume (!(rsp_i && !pend) || 1'b1);
        assume (dly_i >= 4'd1 && dly_i <= 4'd3);
    end
    // abstract sequencer: after seq_run, answers after dly cycles: done or (refuse) a refusal
    reg sw; reg [3:0] sc; reg refuse_r;
    always @(posedge clk) begin
        if (init || srst) sw <= 1'b0;
        else if (seq_run) begin sw <= 1'b1; sc <= 4'd0; refuse_r <= refuse_i; end
        else if (sw) begin sc <= sc + 4'd1; if (sc >= dly_i) sw <= 1'b0; end
    end
    wire answer = sw && sc >= dly_i;
    assign seq_done = answer && !refuse_r;
`ifdef PREFIX
    assign seq_fail_w = 1'b0;            // pre-fix: a refused launch is not reported
`else
    assign seq_fail_w = answer && refuse_r;
`endif
    rondo_kat #(.N_LANES(1), .NPAR(2), .NWORDS(2), .NBWORDS(1), .PDIM(1), .NXBUF(1), .WAW(1), .BAW(1), .XW(1), .FW(1), .HAS_BF16(1), .HAS_FP32(1), .MBIST(0),
                .SIG_BF16(32'h12345678), .SIG_FP32(32'h9ABCDEF0)) dut (
        .clk(clk), .rst_n(rst_n), .srst(srst), .cmd_start(cmd_start), .strap(1'b0), .fmt_applied(fmt), .seq_idle(1'b1),
        .rb_req_valid(rb_v), .rb_req_ready(rdy_i), .rb_req_we(rb_we), .rb_req_addr(rb_a), .rb_req_wdata(rb_d), .rb_rsp_valid(rsp_v), .rb_rsp_rdata(rdat_i),
        .seq_run(seq_run), .seq_n(seq_n), .seq_count(seq_count), .seq_done(seq_done),
`ifndef PREFIX
        .seq_fail(seq_fail_w),
`endif
        .seq_sig(sig_i), .sig_clr(sig_clr), .fmt_set_o(fmt_set), .fmt_val_o(fmt_val), .mbist_start_o(mb_start), .mbist_done(1'b0), .mbist_pass(1'b1),
        .kat_active(kat_active), .running_kat(running_kat), .st_status(stst), .got_bf16(got_b), .got_fp32(got_f), .st_pass(st_pass), .ev_selftest_done(ev_sel),
        .ev_kat_fail(ev_fail), .ev_wstale_set(ev_ws), .ev_crc_clr(ev_crc), .ev_inval(ev_inv), .mbist_running_in(1'b0));
    // fixed format during the run
    always @* if (!init) assume (kc || fmt_i == fmt_q);
    // ---- properties ----
    reg v_q, rdy_q, we_q, srst_q; reg [23:0] a_q; reg [31:0] d_q;
    always @(posedge clk) begin v_q <= rb_v; rdy_q <= rdy_i; we_q <= rb_we; a_q <= rb_a; d_q <= rb_d; srst_q <= srst; end
    reg [31:0] ref_l = 32'h1D872B41; reg [7:0] nw = 8'd0; reg [8:0] npc = 9'd0; reg seen_fail = 1'b0; reg ended = 1'b0; reg seen_run = 1'b0;
    wire [31:0] ref_n = (ref_l >> 1) ^ (ref_l[0] ? 32'h80200003 : 32'h0);
    wire [7:0] ee = 8'd125 + {6'd0, ref_n[30:29]};
    wire [31:0] exp_el = fmt ? {ref_n[31], ee, ref_n[28:6]} : {16'd0, ref_n[31], ee, ref_n[28:22]};
    reg [23:0] exp_a;
    always @* begin
        if (nw < 8'd4) exp_a = 24'h800000 + {16'd0, nw};
        else if (nw < 8'd6) exp_a = 24'h100000 + {16'd0, nw - 8'd4};
        else exp_a = 24'h010000 + {16'd0, nw - 8'd6};
    end
    wire wacc = rb_v && rb_we && rdy_i;
    always @(posedge clk) begin
        if (init) begin ref_l <= 32'h1D872B41; nw <= 0; npc <= 0; seen_fail <= 0; ended <= 0; seen_run <= 0; end
        else begin
            if (wacc) begin ref_l <= ref_n; nw <= nw + 8'd1; end
            if (seq_run) seen_run <= 1'b1;
            if (seq_fail_w) seen_fail <= 1'b1;
            if (cmd_start) npc <= 9'd0; else if (kat_active && npc != 9'h1FF) npc <= npc + 9'd1;
            if (cmd_sent && !kat_active) ended <= 1'b1;
        end
    end
    always @* if (!init) begin
        // rb1: valid held until ready, payload stable (unless a soft reset cancelled it)
        if (v_q && !rdy_q && !srst_q) begin assert (rb_v); assert (rb_we == we_q && rb_a == a_q && rb_d == d_q); end
        // k1/k2/k3: every engine write goes to the next address of the weight, bias, XBUF order with the next LFSR element
        if (wacc) assert (rb_a == exp_a);
`ifdef KAT_DATA
        if (wacc) assert (rb_d == exp_el);
`endif
        // k3: element exponent within [BIAS-2, BIAS+1] (follows from k2; checked directly)
`ifdef KAT_DATA
        if (wacc) assert (fmt ? (rb_d[30:23] >= 8'd125 && rb_d[30:23] <= 8'd128) : (rb_d[14:7] >= 8'd125 && rb_d[14:7] <= 8'd128));
`endif
        // prog: the KAT always ends (done or fail) within T_KAT cycles of the start, including when the launch is refused
        assert (npc <= 9'd`TKAT);
        // k4: a refused launch ends the run as a failure: no pass, ev_kat_fail pulses
        if (seen_fail && ended) assert (!st_pass);                     // a refused launch ends the run without a pass
        // k6: st_pass is never raised before the run has ended
        if (st_pass) assert (ended || !kat_active);
`ifdef WITH_SRST
        // srst: after a soft reset no new request is presented
        if (srst_q) assert (!rb_v);
`endif
    end
    always @* if (!init) begin
        cover (ev_sel && !seen_fail && st_pass);                      // a full pass is reachable (random read data may not match: that is the fail path)
        cover (ev_fail);
        cover (seen_fail && ended);
        cover (seen_run && ev_sel);
        cover (nw == 8'd7);
        cover (seq_fail_w);
`ifdef WITH_SRST
        cover (srst && kat_active);
`endif
    end

`ifdef CANARY
    always @* if (!init && (seen_run && ev_sel)) assert (1'b0);   // canary: reachable, must FAIL
`endif
endmodule
