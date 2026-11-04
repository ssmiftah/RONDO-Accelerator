// rondo_spi_phy: SPI mode-0 slave PHY, oversampled by clk (spec 5.1, 5.6).
//
// sclk/cs_n/mosi are synchronized with SYNC_STAGES flops; a rising SCLK edge is
// detected in clk domain, mosi sampled at that edge, and the NEXT miso bit presented one
// flop later (<= SYNC_STAGES+2 cycles after the real edge).
//
// TX model: the controller writes `tx_byte` into a one-byte hold register with
// `tx_load`. At the 8th rising edge of every byte the hold register moves into the shift
// register (and is cleared to 0, so an unwritten hold register transmits 0) and `tx_need`
// pulses one cycle later: the hold register is free for the byte after next.
// Loopback (opcode LB_OPCODE as first byte of a frame, spec 5.2) is done here so it works
// with no controller state: from byte 1 on, MISO byte k+1 = MOSI byte k.
module rondo_spi_phy #(
    parameter SYNC_STAGES = 2,
    parameter [7:0] LB_OPCODE = 8'h0E,
    parameter [7:0] ST_OPCODE = 8'h05
) (
    input        clk,
    input        rst_n,
    input        sclk,
    input        cs_n,
    input        mosi,
    output       cs_active,
    output       frame_start,       // 1-cycle pulse
    output       frame_end,         // 1-cycle pulse
    output [7:0] rx_byte,
    output       rx_valid,          // 1-cycle pulse, rx_byte stable for the next byte time
    input  [7:0] status8,           // STATUS opcode: every byte after the opcode = status8
    input  [7:0] tx_byte,
    input        tx_load,
    output       tx_need,           // 1-cycle pulse after hold moved into the shift register
    output       mid_byte_abort,    // 1-cycle pulse with frame_end when the frame ended mid-byte
    output       lb_mode,           // frame opcode was LB_OPCODE
    output reg   miso,
    output reg   miso_oe
);
    wire sclk_s, cs_s, mosi_s;
    rondo_sync #(.STAGES(SYNC_STAGES), .WIDTH(1)) u_ss (.clk(clk), .rst_n(rst_n), .d(sclk),  .q(sclk_s));
    rondo_sync #(.STAGES(SYNC_STAGES), .WIDTH(1)) u_cs (.clk(clk), .rst_n(rst_n), .d(cs_n),  .q(cs_s));
    rondo_sync #(.STAGES(SYNC_STAGES), .WIDTH(1)) u_ms (.clk(clk), .rst_n(rst_n), .d(mosi),  .q(mosi_s));

    // reset value of the CS synchronizer must be "deselected" so no frame starts in reset
    // (rondo_sync resets to 0 = selected); gate with a registered "seen high" flag.
    reg cs_seen_hi;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) cs_seen_hi <= 1'b0; else if (cs_s) cs_seen_hi <= 1'b1;
    wire cs_low = ~cs_s & cs_seen_hi;

    reg sclk_d, cs_low_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sclk_d <= 1'b0; cs_low_d <= 1'b0; end
        else begin sclk_d <= sclk_s; cs_low_d <= cs_low; end
    end
    wire rise = sclk_s & ~sclk_d;
    assign frame_start = cs_low & ~cs_low_d;
    assign frame_end   = ~cs_low & cs_low_d;
    assign cs_active   = cs_low;

    reg [2:0] bitcnt;
    reg [7:0] rx_sh, tx_sh, tx_hold, rx_q;
    reg       rxv_q, need_q, lb_q, st_q, first_byte;
    wire      byte_done = rise & cs_low & (bitcnt == 3'd7);
    wire [7:0] rx_now = {rx_sh[6:0], mosi_s};

    assign rx_byte  = rx_q;
    assign rx_valid = rxv_q;
    assign tx_need  = need_q;
    assign lb_mode  = lb_q;
    // Combinational, so it is high in the same cycle as frame_end (BUG-1: a registered
    // version arrived one cycle late and the controller missed it).
    assign mid_byte_abort = frame_end & (bitcnt != 3'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bitcnt <= 3'd0; rx_sh <= 8'd0; tx_sh <= 8'd0; tx_hold <= 8'd0; rx_q <= 8'd0;
            rxv_q <= 1'b0; need_q <= 1'b0; lb_q <= 1'b0; st_q <= 1'b0; first_byte <= 1'b1;
            miso <= 1'b0; miso_oe <= 1'b0;
        end else begin
            rxv_q <= 1'b0; need_q <= 1'b0;
            miso_oe <= cs_low;
            if (tx_load) tx_hold <= tx_byte;
            if (frame_start) begin
                bitcnt <= 3'd0; tx_sh <= 8'd0; tx_hold <= 8'd0; miso <= 1'b0;
                first_byte <= 1'b1; lb_q <= 1'b0; st_q <= 1'b0;
                if (tx_load) tx_hold <= tx_byte;
            end else if (frame_end) begin
                bitcnt <= 3'd0; miso <= 1'b0;
            end else if (rise & cs_low) begin
                rx_sh  <= rx_now;
                bitcnt <= bitcnt + 3'd1;
                if (bitcnt == 3'd7) begin
                    rx_q <= rx_now; rxv_q <= 1'b1; need_q <= 1'b1;
                    first_byte <= 1'b0;
                    if (first_byte && rx_now == LB_OPCODE) lb_q <= 1'b1;
                    if (first_byte && rx_now == ST_OPCODE) st_q <= 1'b1;
                    if ((first_byte && rx_now == LB_OPCODE) || (lb_q && !first_byte)) begin
                        tx_sh <= rx_now; miso <= rx_now[7];       // echo the byte just received
                    end else if ((first_byte && rx_now == ST_OPCODE) || (st_q && !first_byte)) begin
                        tx_sh <= status8; miso <= status8[7];     // STATUS8 sampled at byte start
                    end else begin
                        tx_sh <= tx_hold; miso <= tx_hold[7];
                        tx_hold <= tx_load ? tx_byte : 8'd0;
                    end
                end else begin
                    tx_sh <= {tx_sh[6:0], 1'b0};
                    miso  <= tx_sh[6];
                end
            end
        end
    end
endmodule
