`ifndef GAPN
`define GAPN 8     // minimum byte spacing assumed from rondo_spi_phy (cover task shortens it to reach the burst covers)
`endif
// Formal harness: rondo_spi_ctrl with a protocol-legal byte-level PHY and a legal rbus responder.
module spi_ctrl_f (input clk);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    (* anyseq *) wire frame_start_i, frame_end_i, rx_valid_i, abort_i, ready_i, rsp_i, rsp_err;
    (* anyseq *) wire [7:0] rx_byte_i;
    (* anyseq *) wire [31:0] rsp_data;
    (* anyconst *) wire crc_mode;

    // ---- PHY assumptions ------------------------------------------------------------------------------------
    reg in_frame; reg [3:0] gap; reg cs_first;
    wire frame_start = frame_start_i && !in_frame;
    wire frame_end   = frame_end_i && in_frame && !frame_start;
    wire rx_valid    = rx_valid_i && in_frame && (gap == `GAPN) && !frame_start && !frame_end;
    wire mid_abort   = abort_i && frame_end;
    always @(posedge clk) begin
        if (init) begin in_frame <= 1'b0; gap <= 4'd0; end
        else begin
            if (frame_start) begin in_frame <= 1'b1; gap <= 4'd0; end
            else if (frame_end) in_frame <= 1'b0;
            if (rx_valid) gap <= 4'd0; else if (gap != `GAPN) gap <= gap + 4'd1;
        end
    end
    // ---- rbus responder assumptions -------------------------------------------------------------------------
    wire rb_req_valid, rb_req_we; wire [23:0] rb_req_addr; wire [31:0] rb_req_wdata;
    reg outstanding; reg [3:0] age; reg [2:0] wait_rdy;
    wire accept = rb_req_valid && ready_i;
    wire rsp_valid = rsp_i && outstanding && age >= 4'd1;
    always @* if (!init) begin
        assume (!(outstanding && age >= 4'd5 && !rsp_i));      // response within a bounded time
        assume (!(rb_req_valid && wait_rdy >= 3'd3 && !ready_i));
    end
    always @(posedge clk) begin
        if (init) begin outstanding <= 1'b0; age <= 4'd0; wait_rdy <= 3'd0; end
        else begin
            if (accept) begin outstanding <= 1'b1; age <= 4'd0; end
            else if (outstanding) age <= (age == 4'd15) ? age : age + 4'd1;
            if (rsp_valid) outstanding <= accept ? 1'b1 : 1'b0;
            if (rb_req_valid && !ready_i) wait_rdy <= wait_rdy + 3'd1; else wait_rdy <= 3'd0;
        end
    end

    wire [7:0] tx_byte; wire tx_load, err_frame, err_crc, frame_end_o, rsp_ready;
    rondo_spi_ctrl #(.CRC(1)) dut (
        .clk(clk), .rst_n(rst_n), .frame_start(frame_start), .frame_end(frame_end), .rx_valid(rx_valid),
        .rx_byte(rx_byte_i), .tx_need(rx_valid), .mid_byte_abort(mid_abort), .tx_byte(tx_byte), .tx_load(tx_load),
        .rb_req_valid(rb_req_valid), .rb_req_ready(ready_i), .rb_req_we(rb_req_we), .rb_req_addr(rb_req_addr),
        .rb_req_wdata(rb_req_wdata), .rb_rsp_valid(rsp_valid), .rb_rsp_ready(rsp_ready), .rb_rsp_rdata(rsp_data),
        .rb_rsp_err(rsp_err), .crc_en_in(crc_mode), .err_frame(err_frame), .err_crc(err_crc), .frame_end_o(frame_end_o));

    // ---- reference parse of the received bytes -----------------------------------------------------------------
    function [7:0] crc8b(input [7:0] c, input [7:0] d);
        integer i; reg [7:0] r;
        begin r = c ^ d; for (i = 0; i < 8; i = i + 1) r = r[7] ? ((r << 1) ^ 8'h07) : (r << 1); crc8b = r; end
    endfunction
    reg [3:0] bi; reg [7:0] opc; (* keep *) reg [7:0] ab1, ab2, ab3; wire [23:0] a0 = {ab1, ab2, ab3}; reg [15:0] nn; reg [7:0] hcrc; reg hdr_ok, hdr_bad;
    reg [31:0] word; reg [2:0] wb; reg [7:0] wcrc; reg dcrc_bad; reg [16:0] reqs, words_done; reg crc_f;
    wire is_rw = (opc == 8'h02) || (opc == 8'h03);
    wire [3:0] hdr_len = crc_f ? 4'd7 : 4'd6;
    always @(posedge clk) begin
        if (init) begin bi <= 0; opc <= 0; nn <= 0; ab1 <= 0; ab2 <= 0; ab3 <= 0; hcrc <= 0; hdr_ok <= 0; hdr_bad <= 0; word <= 0; wb <= 0; wcrc <= 0;
            dcrc_bad <= 0; reqs <= 0; words_done <= 0; crc_f <= 0; end
        else begin
            if (frame_start) begin bi <= 0; hdr_ok <= 0; hdr_bad <= 0; reqs <= 0; words_done <= 0; wb <= 0; dcrc_bad <= 0; crc_f <= crc_mode; end
            if (rx_valid) begin
                if (bi != 4'd15) bi <= bi + 4'd1;
                case (bi)
                    4'd0: begin opc <= rx_byte_i; hcrc <= crc8b(8'd0, rx_byte_i); end
                    4'd1: begin ab1 <= rx_byte_i; hcrc <= crc8b(hcrc, rx_byte_i); end
                    4'd2: begin ab2 <= rx_byte_i; hcrc <= crc8b(hcrc, rx_byte_i); end
                    4'd3: begin ab3 <= rx_byte_i; hcrc <= crc8b(hcrc, rx_byte_i); end
                    4'd4: begin nn[15:8] <= rx_byte_i; hcrc <= crc8b(hcrc, rx_byte_i); end
                    4'd5: begin nn[7:0] <= rx_byte_i; hcrc <= crc8b(hcrc, rx_byte_i); if (!crc_f) hdr_ok <= 1'b1; end
                    4'd6: if (crc_f) begin if (rx_byte_i == hcrc) hdr_ok <= 1'b1; else hdr_bad <= 1'b1; end
                    default: ;
                endcase
                if (bi >= hdr_len && opc == 8'h02 && hdr_ok) begin
                    if (wb < 3'd4) begin word <= {word[23:0], rx_byte_i}; wcrc <= (wb == 0) ? crc8b(8'd0, rx_byte_i) : crc8b(wcrc, rx_byte_i); wb <= wb + 3'd1;
                        if (wb == 3'd3 && !crc_f) begin wb <= 3'd0; words_done <= words_done + 17'd1; end end
                    else begin wb <= 3'd0; if (rx_byte_i == wcrc) words_done <= words_done + 17'd1; else dcrc_bad <= 1'b1; end
                end
            end
            if (issue) reqs <= reqs + 17'd1;
        end
    end

    wire issue = rb_req_valid && !v_q;
    reg v_q, rdy_q, we_q; reg [23:0] a_q; reg [31:0] d_q;
    always @(posedge clk) begin v_q <= rb_req_valid; rdy_q <= ready_i; we_q <= rb_req_we; a_q <= rb_req_addr; d_q <= rb_req_wdata; end
    always @* if (!init) begin
        // rbus master rules (spec 8.2): valid held until the transfer; payload stable meanwhile
        if (v_q && !rdy_q) begin assert (rb_req_valid); assert (rb_req_we == we_q && rb_req_addr == a_q && rb_req_wdata == d_q); end
        // never more than one outstanding request, and none for non-rw frames or before a good header
        if (accept) assert (!outstanding || rsp_valid);
        if (issue) begin
            assert (is_rw);
            assert (hdr_ok && !hdr_bad);
            assert (rb_req_we == (opc == 8'h02));
            assert (reqs <= {1'b0, nn});                       // at most N+1 requests: the (reqs+1)th is the (N+1)th at most
            assert (rb_req_addr == a0 + {7'd0, reqs});           // address increments by one per word
            if (opc == 8'h02) begin
                assert (words_done > reqs);                    // a write is only issued for a complete (and CRC-clean) word
                assert (!dcrc_bad);
            end
        end
    end
    always @* if (!init) begin
        cover (issue && rb_req_we && reqs == 17'd1);          // second word of a write burst
        cover (issue && !rb_req_we && reqs == 17'd1);         // second read of a burst
        cover (err_crc);
        cover (err_frame && frame_end_o);
        cover (frame_end && bi >= 4'd7);
    end
endmodule
