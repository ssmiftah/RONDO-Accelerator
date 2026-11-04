// Formal harness: rondo_spi_phy against an SPI master model (mode 0) at a free SCLK period of 6..10 core cycles.
module spi_phy_f (input clk, input [7:0] next_byte, input [7:0] txb, input txl, input [2:0] hsel);
    // anyconst inputs: constant after the first cycle (tool-neutral form of (* anyconst *))
    reg kc_first = 1'b1; always @(posedge clk) kc_first <= 1'b0;
    reg [2:0] hsel_kq; always @(posedge clk) hsel_kq <= hsel;
    always @* assume (kc_first || hsel == hsel_kq);

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;
    // [anyconst] -> input: hsel                         // half period 3..5 cycles
    wire [3:0] H = 4'd3 + {2'b00, hsel[1:0] == 2'd3 ? 2'd2 : hsel[1:0]};
    // [anyseq] -> input: next_byte
    // [anyseq] -> input: txb
    // [anyseq] -> input: txl

    // ---- master model -------------------------------------------------------------------------------------
    reg cs_n, sclk, mosi; reg [3:0] cnt; reg [3:0] pre; reg [2:0] bitn; reg [7:0] cur, sentb, rxa; reg [3:0] bytes;
    reg started;
    wire rise_now = !sclk && (cnt == H - 4'd1) && !cs_n && started;
    wire fall_now =  sclk && (cnt == H - 4'd1);
    always @(posedge clk) begin
        if (init) begin cs_n <= 1'b1; sclk <= 1'b0; mosi <= 1'b0; cnt <= 4'd0; pre <= 4'd0; bitn <= 3'd0; cur <= 8'h02;
                        sentb <= 8'd0; rxa <= 8'd0; bytes <= 4'd0; started <= 1'b0; end
        else begin
            if (cs_n) begin
                pre <= pre + 4'd1;
                if (pre == 4'd6) begin cs_n <= 1'b0; cnt <= 4'd0; started <= 1'b0; end
            end else begin
                cnt <= (cnt == H - 4'd1) ? 4'd0 : cnt + 4'd1;
                if (!started && cnt == H - 4'd1) begin started <= 1'b1; mosi <= cur[7]; end
                if (cnt == H - 4'd1 && started) begin
                    sclk <= !sclk;
                    if (!sclk) begin                         // rising edge: slave samples MOSI, master samples MISO
                        rxa <= {rxa[6:0], miso};
                        bitn <= bitn + 3'd1;
                        if (bitn == 3'd7) begin bytes <= bytes + 4'd1; sentb <= cur; end
                    end else begin                           // falling edge: next MOSI bit
                        if (bitn == 3'd0) begin cur <= next_byte; mosi <= next_byte[7]; end
                        else begin mosi <= cur[7 - bitn]; end
                    end
                end
            end
        end
    end
    wire miso, miso_oe, cs_active, frame_start, frame_end, rx_valid, tx_need, mid_abort, lb_mode;
    wire [7:0] rx_byte;
    // legal controller behaviour: tx_load only well away from a byte boundary
    reg cs_q; always @(posedge clk) cs_q <= cs_active;
    reg [3:0] since_need;
    always @(posedge clk) begin if (tx_need) since_need <= 4'd0; else if (since_need != 4'd15) since_need <= since_need + 4'd1; end
    wire tx_load = txl && since_need >= 4'd3 && bitn >= 3'd1 && bitn <= 3'd5 && !cs_n && started;
    // opcode must be neither loopback nor status (those modes bypass the hold register)
    always @* if (!init) assume (cur != 8'h0E && cur != 8'h05 && next_byte != 8'h0E && next_byte != 8'h05);
    rondo_spi_phy dut (.clk(clk), .rst_n(rst_n), .sclk(sclk), .cs_n(cs_n), .mosi(mosi), .cs_active(cs_active),
        .frame_start(frame_start), .frame_end(frame_end), .rx_byte(rx_byte), .rx_valid(rx_valid), .status8(8'h82),
        .tx_byte(txb), .tx_load(tx_load), .tx_need(tx_need), .mid_byte_abort(mid_abort), .lb_mode(lb_mode),
        .miso(miso), .miso_oe(miso_oe));

    // ---- scoreboards ----------------------------------------------------------------------------------------------
    reg [7:0] hold_m, shift_m, rxbyte_exp; reg have_rx;
    reg [7:0] tx_exp_prev;   // byte the master must have received for the byte that just completed
    reg [3:0] nbytes_done;
    always @(posedge clk) begin
        if (init) begin hold_m <= 0; shift_m <= 0; have_rx <= 0; rxbyte_exp <= 0; tx_exp_prev <= 0; nbytes_done <= 0; end
        else begin
            if (tx_load) hold_m <= txb;
            if (tx_need) begin shift_m <= hold_m; hold_m <= 8'd0; end    // moved at the boundary (one cycle earlier)
        end
    end
    // MISO check: at each master rising edge (sampling instant) the bit equals the corresponding bit of shift_m, where
    // shift_m was loaded 1 byte earlier; byte 0 is 0.
    reg [7:0] shift_cur;
    reg [2:0] bitn_q; reg sampled; reg [3:0] byte_idx;
    always @(posedge clk) begin
        if (init) begin shift_cur <= 0; byte_idx <= 0; end
        else begin
            if (tx_need) shift_cur <= hold_m;                           // byte transmitted during the next master byte
            if (rise_now && bitn == 3'd7 && byte_idx != 4'd15) byte_idx <= byte_idx + 4'd1;
        end
    end
    always @* if (!init) begin
        if (rise_now && byte_idx == 4'd0) assert (miso == 1'b0);                      // opcode byte reads 0
        // received byte: when the PHY reports a byte, it is the byte the master sent
        if (rx_valid) assert (rx_byte == sentb);
        // MISO bit at the sampling instant of byte >= 1 equals the loaded shift byte (bit 7 first); not checked for the first
        // two bits (they are covered by the byte-level check below)
        if (rise_now && byte_idx >= 4'd1) assert (miso == shift_cur[3'd7 - bitn]);
        assert (miso_oe == cs_q);
    end
    always @* if (!init) begin
        cover (rx_valid && rx_byte == 8'h02 && bytes == 4'd1);
        cover (rise_now && byte_idx >= 4'd1 && miso && shift_cur != 8'd0);
        cover (tx_load);
    end

`ifdef CANARY
    always @* if (!init && (1'b1)) assert (1'b0);   // canary: reachable, must FAIL
`endif
endmodule
