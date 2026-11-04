// Formal harness: rondo_dev (layers abstracted) behind a legal rbus master: rbus timing bound, protocol rules, ACTIVE blocking,
// launch rule and format-switch ordering (the last two are asserted inside the abstract layer).
module dev_bus_f (input clk, input v_i, input we_i, input bist, input [23:0] a_i, input [31:0] d_i, input frame_end);
    reg init = 1'b1; always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    // [anyseq] -> input: v_i, we_i, bist // [anyseq] -> input: a_i // [anyseq] -> input: d_i
    // [anyseq] -> input: frame_end
    // legal master: valid held (with stable payload) until ready; one request at a time
    reg v_q, rdy_q, we_q; reg [23:0] a_q; reg [31:0] d_q; reg outstanding;
    wire rb_req_ready, rb_rsp_valid, rb_rsp_err; wire [31:0] rb_rsp_rdata;
    wire hold_prev = v_q && !rdy_q;
    wire v = hold_prev ? 1'b1 : (v_i && !outstanding);
    wire we = hold_prev ? we_q : we_i;
    wire [23:0] a = hold_prev ? a_q : {16'd0, a_i[7:0]} | (a_i[23] ? 24'h800000 : 24'd0);   // registers + weight region
    wire [31:0] d = hold_prev ? d_q : d_i;
    always @(posedge clk) begin
        if (init) begin v_q <= 0; rdy_q <= 0; outstanding <= 0; we_q <= 0; a_q <= 0; d_q <= 0; end
        else begin
            v_q <= v; rdy_q <= rb_req_ready; we_q <= we; a_q <= a; d_q <= d;
            if (v && rb_req_ready) outstanding <= 1'b1;
            if (rb_rsp_valid) outstanding <= 1'b0;
        end
    end
    wire irq, busy_pin, st_pass, clkout, clk_src, crc_en; wire [7:0] status8; wire [1:0] clk_div, pg_req, lclk_obs;
    rondo_dev #(.DEPTH(7), .WIDTH(16), .PDIM(8), .N_LANES(2), .NSLOT(8), .NPAR(8), .NXBUF(2), .KAT(0), .TRACE(0),
                .DBG(0), .MBIST(0), .TILE(0)) dut (
        .clk(clk), .rst_n(rst_n), .test_mode(1'b0), .rb_req_valid(v), .rb_req_ready(rb_req_ready), .rb_req_we(we),
        .rb_req_addr(a), .rb_req_wdata(d), .rb_rsp_valid(rb_rsp_valid), .rb_rsp_ready(1'b1), .rb_rsp_rdata(rb_rsp_rdata),
        .rb_rsp_err(rb_rsp_err), .irq(irq), .busy_pin(busy_pin), .st_pass(st_pass), .status8(status8), .clkout(clkout),
        .clk_div(clk_div), .clk_src(clk_src), .crc_en(crc_en), .div_applied(2'b00), .src_applied(1'b0),
        .spi_err_frame(1'b0), .spi_err_crc(1'b0), .spi_frame_end(frame_end), .bist_strap(1'b0), .pg_req(pg_req),
        .lclk_obs(lclk_obs), .checksum_o(), .fmt_o(), .heartbeat_o(), .err_any_o());
    wire [7:0] vr;
    rondo_sva_rbus #(.MAX_RSP(10), .MAX_TOTAL(24)) chk (.clk(clk), .rst_n(rst_n), .req_valid(v), .req_ready(rb_req_ready),
        .req_we(we), .req_addr(a), .req_wdata(d), .rsp_valid(rb_rsp_valid), .rsp_ready(1'b1), .viol(vr));
    always @* if (!init) begin
        assert (!vr[0] && !vr[1] && !vr[2] && !vr[3] && !vr[4] && !vr[5]);
        assert (status8[1:0] == 2'b10);
    end
    always @* if (!init) begin
        cover (rb_rsp_valid && !we_q && a_q == 24'd0 && !rb_rsp_err);
        cover (busy_pin);
        cover (irq);
        cover (rb_rsp_valid && rb_rsp_err);
    end

`ifdef CANARY
    always @* if (!init && (1'b1)) assert (1'b0);   // canary: reachable, must FAIL
`endif
endmodule
