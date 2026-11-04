// rondo_spi_ctrl: SPI frame layer (spec 5.2-5.4) between rondo_spi_phy and an rbus master.
//
// Opcodes: 0x02 WRITE, 0x03 READ, 0x05 STATUS and 0x0E LOOPBACK (both datapaths live in
// the PHY), 0x00/0xFF NOP. Optional CRC-8 (poly 0x07) on header and data words.
// READ pipeline: the word buffer feeds the PHY's one-byte hold register; word n+1 is
// requested only after the last byte of word n moved into the PHY shift register and is
// pre-announced with a speculative 0xDE, so an rbus response that misses its slot shifts
// 0xDEADBEEF and sets err_frame (overrun, spec 5.3 rule 5).
module rondo_spi_ctrl #(
    parameter CRC = 1
) (
    input             clk,
    input             rst_n,
    // PHY side
    input             frame_start,
    input             frame_end,
    input             rx_valid,
    input      [7:0]  rx_byte,
    input             tx_need,
    input             mid_byte_abort,
    output reg [7:0]  tx_byte,
    output reg        tx_load,
    // rbus master
    output reg        rb_req_valid,
    input             rb_req_ready,
    output reg        rb_req_we,
    output reg [23:0] rb_req_addr,
    output reg [31:0] rb_req_wdata,
    input             rb_rsp_valid,
    output            rb_rsp_ready,
    input      [31:0] rb_rsp_rdata,
    input             rb_rsp_err,
    // configuration and status
    input             crc_en_in,
    output reg        err_frame,     // 1-cycle pulses
    output reg        err_crc,
    output reg        frame_end_o
);
    localparam [2:0] M_IDLE = 3'd0, M_OPC = 3'd1, M_HDR = 3'd2, M_WDATA = 3'd3,
                     M_RDATA = 3'd4, M_OTHER = 3'd5, M_IGN = 3'd6;
    localparam [7:0] OP_WRITE = 8'h02, OP_READ = 8'h03, OP_STATUS = 8'h05, OP_LB = 8'h0E;

    assign rb_rsp_ready = 1'b1;

    function [7:0] crc8b(input [7:0] c, input [7:0] d);
        integer i;
        reg [7:0] r;
        begin
            r = c ^ d;
            for (i = 0; i < 8; i = i + 1) r = r[7] ? ((r << 1) ^ 8'h07) : (r << 1);
            crc8b = r;
        end
    endfunction
    function [7:0] crc8w(input [31:0] w);
        crc8w = crc8b(crc8b(crc8b(crc8b(8'h00, w[31:24]), w[23:16]), w[15:8]), w[7:0]);
    endfunction

    reg [2:0]  mode;
    reg        crc_q;
    reg [3:0]  bi;                 // completed bytes in the frame (saturating at 15)
    reg        is_read;
    reg [7:0]  hcrc;
    reg [23:0] addr;
    reg [15:0] len;
    reg [16:0] rem;                // words left to issue
    reg [16:0] ntot;               // N+1 of the current burst (for the protocol checker)
    // write assembly
    reg [31:0] wsh;
    reg [2:0]  wpos;
    // read pipeline
    reg [31:0] wbuf;
    reg [7:0]  wcrc;
    reg [2:0]  hold_idx;
    reg        hv, spec, rd_pend, ign_rsp;
    reg [2:0]  dpos;
    reg [16:0] dleft;

    wire [2:0] lastb = crc_q ? 3'd4 : 3'd3;       // last byte index within a word
    wire [3:0] dstart = crc_q ? 4'd8 : 4'd7;      // frame byte index of the first data byte

    function [7:0] pick(input [31:0] w, input [7:0] c, input [2:0] i);
        case (i)
            3'd0: pick = w[31:24]; 3'd1: pick = w[23:16]; 3'd2: pick = w[15:8];
            3'd3: pick = w[7:0];   default: pick = c;
        endcase
    endfunction

    // issue an rbus request (sets err_frame if the previous one is still pending)
    task automatic issue(input we, input [31:0] wd);
        begin
            if (rb_req_valid && !rb_req_ready) err_frame <= 1'b1;
            else begin
                rb_req_valid <= 1'b1; rb_req_we <= we; rb_req_addr <= addr; rb_req_wdata <= wd;
                addr <= addr + 24'd1; rem <= rem - 17'd1;
            end
        end
    endtask

    reg hdr_done;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode <= M_IDLE; crc_q <= 1'b0; bi <= 4'd0; is_read <= 1'b0; hcrc <= 8'd0;
            addr <= 24'd0; len <= 16'd0; rem <= 17'd0; ntot <= 17'd0; wsh <= 32'd0; wpos <= 3'd0;
            wbuf <= 32'd0; wcrc <= 8'd0; hold_idx <= 3'd0; hv <= 1'b0; spec <= 1'b0;
            rd_pend <= 1'b0; ign_rsp <= 1'b0; dpos <= 3'd0; dleft <= 17'd0;
            tx_byte <= 8'd0; tx_load <= 1'b0; rb_req_valid <= 1'b0; rb_req_we <= 1'b0;
            rb_req_addr <= 24'd0; rb_req_wdata <= 32'd0; err_frame <= 1'b0; err_crc <= 1'b0;
            frame_end_o <= 1'b0;
        end else begin
            tx_load <= 1'b0; err_frame <= 1'b0; err_crc <= 1'b0; frame_end_o <= frame_end;
            if (rb_req_valid && rb_req_ready) rb_req_valid <= 1'b0;

            // ---- rbus response ------------------------------------------------
            if (rb_rsp_valid && rd_pend) begin
                rd_pend <= 1'b0;
                if (ign_rsp) ign_rsp <= 1'b0;
                else if (mode != M_RDATA) begin
                    // response of a read whose frame already ended (e.g. CS rose right after the header): drop it
                    // so it cannot load a stray byte into the next frame
                end else begin
                    wbuf <= rb_rsp_rdata; wcrc <= crc8w(rb_rsp_rdata);
                    hold_idx <= 3'd0; hv <= 1'b1; spec <= 1'b0;
                    tx_byte <= rb_rsp_rdata[31:24]; tx_load <= 1'b1;
                end
            end

            // ---- frame boundaries ---------------------------------------------
            if (frame_start) begin
                mode <= M_OPC; bi <= 4'd0; crc_q <= (CRC != 0) && crc_en_in;
                hv <= 1'b0; spec <= 1'b0; wpos <= 3'd0; dpos <= 3'd0;
            end else if (frame_end) begin
                if (mode == M_OPC || mode == M_HDR) begin
                    if (mode == M_HDR || mid_byte_abort) err_frame <= 1'b1;   // partial header or opcode byte (BUG-1)
                end else if (mode == M_WDATA) begin
                    if (rem != 17'd0 && (wpos != 3'd0 || mid_byte_abort)) err_frame <= 1'b1;
                end else if (mode == M_RDATA) begin
                    if (dleft != 17'd0 && (dpos != 3'd0 || mid_byte_abort) && bi >= dstart)
                        err_frame <= 1'b1;
                end
                if (mode == M_HDR && mid_byte_abort) err_frame <= 1'b1;
                mode <= M_IDLE; hv <= 1'b0; spec <= 1'b0;
            end

            // ---- received byte ------------------------------------------------
            if (rx_valid) begin
                if (bi != 4'd15) bi <= bi + 4'd1;
                case (mode)
                    M_OPC: begin
                        hcrc <= crc8b(8'd0, rx_byte);
                        is_read <= (rx_byte == OP_READ);
                        case (rx_byte)
                            OP_WRITE, OP_READ: mode <= M_HDR;
                            OP_STATUS, OP_LB, 8'h00, 8'hFF: mode <= M_OTHER;
                            default: begin mode <= M_IGN; err_frame <= 1'b1; end
                        endcase
                    end
                    M_HDR: begin
                        if (bi <= 4'd5) hcrc <= crc8b(hcrc, rx_byte);
                        case (bi)
                            4'd1: addr[23:16] <= rx_byte;
                            4'd2: addr[15:8]  <= rx_byte;
                            4'd3: addr[7:0]   <= rx_byte;
                            4'd4: len[15:8]   <= rx_byte;
                            4'd5: len[7:0]    <= rx_byte;
                            default: ;
                        endcase
                        hdr_done = 1'b0;
                        if (bi == 4'd5 && !crc_q) hdr_done = 1'b1;
                        if (bi == 4'd6 && crc_q) begin
                            if (rx_byte == hcrc) hdr_done = 1'b1;
                            else begin err_crc <= 1'b1; mode <= M_IGN; end
                        end
                        if (hdr_done) begin
                            // `addr`/`len` are registered: the last header byte is not yet
                            // visible, so use the received byte for len[7:0] when needed
                            ntot <= {1'b0, (bi == 4'd5) ? {len[15:8], rx_byte} : len} + 17'd1;
                            rem <= {1'b0, (bi == 4'd5) ? {len[15:8], rx_byte} : len} + 17'd1;
                            dleft <= {1'b0, (bi == 4'd5) ? {len[15:8], rx_byte} : len} + 17'd1;
                            wpos <= 3'd0; dpos <= 3'd0;
                            if (is_read) begin
                                mode <= M_RDATA;
                                // request word 0 next cycle (rem/addr settle first)
                                rd_pend <= 1'b0;
                            end else mode <= M_WDATA;
                        end
                    end
                    M_WDATA: if (rem != 17'd0) begin
                        if (wpos == 3'd3 && !crc_q) begin
                            issue(1'b1, {wsh[23:0], rx_byte});
                            wpos <= 3'd0;
                        end else if (wpos < 3'd4 && wpos != 3'd3) begin
                            wsh <= {wsh[23:0], rx_byte}; wpos <= wpos + 3'd1;
                        end else if (wpos == 3'd3) begin       // crc mode: 4th data byte
                            wsh <= {wsh[23:0], rx_byte}; wpos <= 3'd4;
                        end else begin                          // DCRC byte
                            wpos <= 3'd0;
                            if (rx_byte == crc8w(wsh)) issue(1'b1, wsh);
                            else begin err_crc <= 1'b1; mode <= M_IGN; end
                        end
                    end
                    M_RDATA: if (bi >= dstart && dleft != 17'd0) begin
                        if (dpos == lastb) begin dpos <= 3'd0; dleft <= dleft - 17'd1; end
                        else dpos <= dpos + 3'd1;
                    end
                    default: ;
                endcase
            end

            // ---- READ: first word request (one cycle after the header completed) ----
            if (mode == M_RDATA && !hv && !rd_pend && !ign_rsp && bi >= 4'd6 && rem != 17'd0
                && bi < dstart) begin
                issue(1'b0, 32'd0);
                rd_pend <= 1'b1; hv <= 1'b1; spec <= 1'b1; hold_idx <= 3'd0;
                tx_byte <= 8'hDE; tx_load <= 1'b1;
            end

            // ---- READ: hold register free (byte moved to the PHY shift register) ----
            if (tx_need && mode == M_RDATA && hv) begin
                hv <= 1'b0;
                if (spec) begin                        // missed its slot: DEADBEEF
                    err_frame <= 1'b1; spec <= 1'b0;
                    wbuf <= 32'hDEADBEEF; wcrc <= crc8w(32'hDEADBEEF);
                    ign_rsp <= rd_pend; hold_idx <= 3'd1; hv <= 1'b1;
                    tx_byte <= 8'hAD; tx_load <= 1'b1;
                end else if (hold_idx < lastb) begin
                    hold_idx <= hold_idx + 3'd1; hv <= 1'b1;
                    tx_byte <= pick(wbuf, wcrc, hold_idx + 3'd1); tx_load <= 1'b1;
                end else if (rem != 17'd0 && !rd_pend) begin
                    issue(1'b0, 32'd0);
                    rd_pend <= 1'b1; hv <= 1'b1; spec <= 1'b1; hold_idx <= 3'd0;
                    tx_byte <= 8'hDE; tx_load <= 1'b1;
                end
            end
        end
    end
endmodule
