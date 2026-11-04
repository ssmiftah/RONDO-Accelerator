// FV-ARB: rondo_rbus_arb. Free masters (rule 2 assumed for K/M, proven by FV-KAT.rb1 / FV-MB.m5 / sim SVA), free slave with bounded latency.
// Tool-neutral: every free signal is a module input.
module arb_f (input clk,
    input e_v, input e_we, input [23:0] e_a, input [31:0] e_d, input e_rr,
    input k_v, input k_we, input [23:0] k_a, input [31:0] k_d,
    input m_v, input m_we, input [23:0] m_a, input [31:0] m_d,
    input srst, input o_rdy, input o_rv, input [31:0] o_rd, input o_re);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    wire e_rdy, e_rv, e_rerr, k_rdy, k_rv, k_rerr, m_rdy, m_rv, m_rerr, o_v, o_we, o_int, o_rr; wire [23:0] o_a; wire [31:0] o_d, e_rd, k_rd, m_rd;
    rondo_rbus_arb dut (.clk(clk), .rst_n(rst_n), .srst(srst),
        .e_req_valid(e_v), .e_req_ready(e_rdy), .e_req_we(e_we), .e_req_addr(e_a), .e_req_wdata(e_d), .e_rsp_valid(e_rv), .e_rsp_ready(e_rr), .e_rsp_rdata(e_rd), .e_rsp_err(e_rerr),
        .k_req_valid(k_v), .k_req_ready(k_rdy), .k_req_we(k_we), .k_req_addr(k_a), .k_req_wdata(k_d), .k_rsp_valid(k_rv), .k_rsp_rdata(k_rd), .k_rsp_err(k_rerr),
        .m_req_valid(m_v), .m_req_ready(m_rdy), .m_req_we(m_we), .m_req_addr(m_a), .m_req_wdata(m_d), .m_rsp_valid(m_rv), .m_rsp_rdata(m_rd), .m_rsp_err(m_rerr),
        .o_req_valid(o_v), .o_req_ready(o_rdy), .o_req_we(o_we), .o_req_addr(o_a), .o_req_wdata(o_d), .o_req_int(o_int),
        .o_rsp_valid(o_rv), .o_rsp_ready(o_rr), .o_rsp_rdata(o_rd), .o_rsp_err(o_re));
    // ---- environment ------------------------------------------------------------------------------------------
    reg ev_q, kv_q, mv_q, srst_q, ekr_q, kr_q, mr_q; reg [23:0] ea_q, ka_q, ma_q; reg [31:0] ed_q, kd_q, md_q; reg ewe_q, kwe_q, mwe_q;
    always @(posedge clk) begin ev_q <= e_v; kv_q <= k_v; mv_q <= m_v; srst_q <= srst; ekr_q <= e_rdy; kr_q <= k_rdy; mr_q <= m_rdy;
        ea_q <= e_a; ka_q <= k_a; ma_q <= m_a; ed_q <= e_d; kd_q <= k_d; md_q <= m_d; ewe_q <= e_we; kwe_q <= k_we; mwe_q <= m_we; end
    // slave: ready within 3 cycles of valid, response 1..5 cycles after acceptance, one response per request, none otherwise
    reg [2:0] wr; reg [3:0] age; reg pend; reg [2:0] erw;
    always @(posedge clk) erw <= (e_rv && !e_rr) ? erw + 3'd1 : 3'd0;
    wire acc = o_v && o_rdy;
    always @(posedge clk) begin
        if (init) begin wr <= 0; age <= 0; pend <= 0; end
        else begin
            wr <= (o_v && !o_rdy) ? wr + 3'd1 : 3'd0;
            if (acc) begin pend <= 1'b1; age <= 4'd0; end else if (pend) age <= (age == 4'd15) ? age : age + 4'd1;
            if (o_rv && o_rr) pend <= 1'b0;
        end
    end
    always @* if (!init) begin
        // A: master rule 2 for the internal masters: valid held until ready, payload stable, except when a soft reset cancels it;
        //    proven by FV-KAT.rb1 / FV-MB.m5 (kat/mbist) and checked in sim by sva_chip.rbus
        if (kv_q && !kr_q && !srst_q) begin assume (k_v); assume (k_we == kwe_q && k_a == ka_q && k_d == kd_q); end
        if (mv_q && !mr_q && !srst_q) begin assume (m_v); assume (m_we == mwe_q && m_a == ma_q && m_d == md_q); end
        // A: external master rule 2: the SPI adapter holds valid until ready (proven by FV-CTRL.rb1)
        if (ev_q && !ekr_q) begin assume (e_v); assume (e_we == ewe_q && e_a == ea_q && e_d == ed_q); end
        // A: slave: ready within 3 cycles, response only for an accepted request, within 5 cycles (spec 8.3 bound; FV-DEV.rb)
        assume (!(o_v && wr >= 3'd3 && !o_rdy));
        assume (!o_rv || pend);
        assume (!(pend && age >= 4'd5 && !o_rv));
        // A: the external master accepts a response within 3 cycles (spi_ctrl rsp_ready; FV-CTRL.rd)
        assume (!(e_rv && erw >= 3'd3 && !e_rr));
    end
    // ---- properties ---------------------------------------------------------------------------------------------
    reg o_v_q, o_rdy_q, o_we_q; reg [23:0] o_a_q; reg [31:0] o_d_q; reg o_int_q;
    always @(posedge clk) begin o_v_q <= o_v; o_rdy_q <= o_rdy; o_we_q <= o_we; o_a_q <= o_a; o_d_q <= o_d; o_int_q <= o_int; end
    reg [7:0] ewait; always @(posedge clk) if (init || !e_v || e_rdy) ewait <= 0; else if (ewait != 8'hFF) ewait <= ewait + 8'd1;
    reg [3:0] nrsp_e, nrsp_k, nrsp_m;   // outstanding bookkeeping
    reg owner_k_q, owner_m_q;
    always @* if (!init) begin
        // a1: request valid is held with stable payload while waiting (rule 2 on the merged port), except an internal master cancelled by srst/valid drop
        if (o_v_q && !o_rdy_q && !(o_int_q && (srst_q || !(kv_q || mv_q)))) begin assert (o_v); assert (o_we == o_we_q && o_a == o_a_q && o_d == o_d_q); end
        // a2: responses are routed to the owner only and only while it was granted
        assert ((e_rv + k_rv + m_rv) <= 2'd1);
        if (e_rv) assert (!o_int);
        if (k_rv || m_rv) assert (o_int);
        // a3: o_req_int marks the internal owner during the request
        if (e_rdy) assert (!o_int);
        if (k_rdy || m_rdy) assert (o_int);
        // a_ready: a ready only for the owner that is presented
        assert ((e_rdy + k_rdy + m_rdy) <= 2'd1);
        if (e_rdy || k_rdy || m_rdy) assert (o_v && o_rdy);
        // a5: bounded wait for the external master: at most one internal access (<= 3 + 5 + 2) plus its own accept (3), generous bound 24 (spec 8.3)
        assert (ewait <= 8'd24);
        // srst: an internal request that was not yet accepted when srst was seen is not granted in the following cycle
        if (srst_q && o_v && o_int && !o_v_q) assert (1'b0);   // srst in the previous (idle) cycle: no internal request is granted now
    end
    reg [1:0] own_after_srst; always @(posedge clk) own_after_srst <= {srst, o_v && o_int};
    always @* if (!init) begin
        cover (k_rv); cover (m_rv); cover (e_rv); cover (e_v && o_v && o_int);      // external waiting behind an internal access
        cover (srst && o_v && o_int && !o_rdy);                                        // srst cancels a pending internal request
        cover (ewait >= 8'd5);
    end


    // payload and response routing (data integrity)
    always @* if (!init) begin
        if (e_rdy) begin assert (o_we == e_we && o_a == e_a && o_d == e_d); end
        if (k_rdy) begin assert (o_we == k_we && o_a == k_a && o_d == k_d); end
        if (m_rdy) begin assert (o_we == m_we && o_a == m_a && o_d == m_d); end
        if (e_rv) begin assert (e_rd == o_rd && e_rerr == o_re); assert (o_rr == e_rr); end
        if (k_rv) begin assert (k_rd == o_rd && k_rerr == o_re); assert (o_rr); end
        if (m_rv) begin assert (m_rd == o_rd && m_rerr == o_re); assert (o_rr); end
        // request valid implies the selected master presents a request (or is being cancelled, internal only)
        if (o_v && !o_int) assert (e_v);
        // a response is only forwarded to a master that was granted: no response without an outstanding request
        if (o_v) assert (!(e_rv || k_rv || m_rv));
    end
`ifdef CANARY
    always @* if (!init && (o_v && o_int)) assert (1'b0);   // canary: reachable, must FAIL
`endif
endmodule
