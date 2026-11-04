// Formal harness: rondo_tile (input-tiling FSM) with an abstract sequencer/layer (launch -> done/fail after a free delay).
// Environment assumptions come from the chip: commands are single-cycle pulses, never issued while the chip is ACTIVE
// (tile busy); inval/host-PS events never occur during a run; a refused/accepted state change is the FSM's job.
module tile_f (input clk, input cmd_run, input cmd_abort, input srst, input inval_ext, input other_start, input ps_host_wr, input seq_done_i, input seq_fail_i, input [31:0] cfg, input [31:0] slice_reg, input [31:0] load_crc, input [0:0] ps_host_b);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    reg init2 = 1'b1;
    reg init3 = 1'b1;
    always @(posedge clk) begin init2 <= init; init3 <= init2; end      // state after the reset cycle is only defined from step 2 (async2sync)
    wire rst_n = !init;
    // [anyseq] -> input: cmd_run, cmd_abort, srst, inval_ext, other_start, ps_host_wr, seq_done_i, seq_fail_i
    // [anyseq] -> input: cfg, slice_reg, load_crc
    // [anyseq] -> input: ps_host_b
    wire launch, save, last, tx_en, xt_we, tz_we, busy, open_o, ev_slice, ev_final, ev_seq, ev_stale, slice_clr;
    wire [1:0] seed; wire [2:0] tx_addr; wire [1:0] xt_idx; wire [2:0] tz_addr; wire [31:0] tz_d, status, seq_crc;
    wire [0:0] b_cur; wire ent_valid; wire [7:0] ent_tag, s_cur_o;
    // abstract sequencer: after a launch, done (or fail) arrives 1..3 cycles later
    reg wait_q; reg [1:0] dly;
    always @(posedge clk) begin
        if (init || srst) wait_q <= 1'b0;
        else if (launch) begin wait_q <= 1'b1; dly <= 2'd0; end
        else if (wait_q) dly <= dly + 2'd1;
    end
    wire seq_done = wait_q && dly >= 2'd1 && seq_done_i && !seq_fail_i;
    wire seq_fail = wait_q && dly >= 2'd1 && seq_fail_i && !seq_done_i;
    always @* if (!init) begin
        assume ((cmd_run + cmd_abort + inval_ext + other_start + ps_host_wr + srst) <= 3'd1);   // one rbus access / event per cycle
        assume (!((cmd_run || cmd_abort || inval_ext || other_start || ps_host_wr) && busy));   // chip is ACTIVE during a run
        assume (!(seq_done && seq_fail));
        assume (cfg[15:8] >= 8'd1 && cfg[15:8] <= 8'd3);                                    // NSLICE range-checked by rondo_regs
        assume (cfg[23:16] >= 8'd1 && cfg[23:16] <= 8'd2);                                  // TBATCH 1..TILE_B
        assume (cfg[24] == 1'b0 || cfg[23:16] == 8'd1);                                     // KEEP forces TBATCH = 1
        assume (cfg == cfg_q);                                                              // TILE_CFG constant (blocked while OPEN/ACTIVE; sampled)
    end
    reg [31:0] cfg_q; always @(posedge clk) cfg_q <= cfg;
    rondo_tile #(.TB(2), .PDIM(2), .WIDTH(2), .TBW(1), .XW(1), .ZJW(1)) dut (
        .clk(clk), .rst_n(rst_n), .srst(srst), .cmd_run(cmd_run), .cmd_abort(cmd_abort), .cfg(cfg), .slice_reg(slice_reg),
        .load_crc(load_crc), .inval_ext(inval_ext), .other_start(other_start), .ps_host_wr(ps_host_wr), .ps_host_b(ps_host_b),
        .launch(launch), .seed(seed), .save(save), .last(last), .seq_done(seq_done), .seq_fail(seq_fail),
        .tx_en(tx_en), .tx_addr(tx_addr), .tx_q(32'd0), .xt_we(xt_we), .xt_idx(xt_idx), .tz_we(tz_we), .tz_addr(tz_addr),
        .tz_d(tz_d), .zbuf(64'd0), .b_cur(b_cur), .busy(busy), .open_o(open_o), .status(status), .seq_crc(seq_crc), .ent_valid(ent_valid), .ent_tag(ent_tag), .s_cur_o(s_cur_o),
        .ev_slice(ev_slice), .ev_final(ev_final), .ev_seq(ev_seq), .ev_stale(ev_stale), .slice_clr(slice_clr));
    wire keep = cfg[24];
    wire [1:0] vidx = keep ? 2'd0 : {1'b0, b_cur};
    always @* if (!init && !init2) begin
        // no restore launch without a valid PS entry carrying tag s-1 (keep: the single in-place entry)
        if (launch && seed != 2'd0) assert (ent_valid && ent_tag == s_cur_o - 8'd1);
        // a launch only happens inside an open sequence
        if (launch) assert (open_o);
        // partial slices never write TZ; the launch parameters are the idle defaults outside a run
        if (tz_we) assert (last);
        if (!busy) assert (last && !save && seed == 2'd0);
        // a refused run (stale / sequencing error) starts nothing
        if (ev_stale || ev_seq) assert (!launch);
        // events are mutually exclusive with a launch cycle; final and slice-done never together
        assert (!(ev_slice && ev_final));
    end
    reg srst_q; always @(posedge clk) srst_q <= srst;
    always @* if (!init && !init2 && !init3 && srst_q) assert (!busy && !open_o);          // soft reset closes the sequence (PS valid bits cleared: checked in simulation, T-TILE)
    always @* if (!init) begin
        cover (launch && seed == 2'd2);
        cover (ev_final);
        cover (ev_slice);
        cover (ev_stale);
        cover (tz_we);
        cover (launch && seed == 2'd1);
    end

`ifdef CANARY
    always @* if (!init && (ev_final)) assert (1'b0);   // canary: reachable, must FAIL
`endif
endmodule
