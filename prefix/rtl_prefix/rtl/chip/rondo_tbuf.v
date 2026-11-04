// rondo_tbuf: input-tile (TX) and final-output (TZ) SRAMs for input tiling (spec 18.3).
//
// TX: TB entries x 2^XW 32-bit words, entry b = the PDIM-element slice of input b.
// TZ: TB entries x 2^ZJW 32-bit words, entry b = the final z of input b (one word per ladder).
// Each is one rondo_sram_sp with a single port. The tile sequencer owns the ports while it is
// running (t_own = 1); the host owns them otherwise (rondo_dev blocks host accesses while the
// chip is ACTIVE, so there is no arbitration beyond this select). Read data has the usual
// one-cycle SRAM latency.
module rondo_tbuf #(
    parameter TBW = 3,
    parameter XW  = 6,
    parameter ZJW = 6
) (
    input                    clk,
    input                    t_own,
    // TX
    input                    t_tx_en,
    input  [TBW+XW-1:0]      t_tx_addr,
    input                    h_tx_en,
    input                    h_tx_we,
    input  [TBW+XW-1:0]      h_tx_addr,
    input  [31:0]            h_tx_d,
    output [31:0]            tx_q,
    // TZ
    input                    t_tz_we,
    input  [TBW+ZJW-1:0]     t_tz_addr,
    input  [31:0]            t_tz_d,
    input                    h_tz_en,
    input  [TBW+ZJW-1:0]     h_tz_addr,
    output [31:0]            tz_q
);
    wire                 tx_en = t_own ? t_tx_en : h_tx_en;
    wire                 tx_we = t_own ? 1'b0 : h_tx_we;
    wire [TBW+XW-1:0]    tx_a  = t_own ? t_tx_addr : h_tx_addr;
    rondo_sram_sp #(.DEPTH(1 << (TBW + XW)), .WIDTH(32)) u_tx (.clk(clk), .en(tx_en), .we(tx_we), .addr(tx_a),
        .d(h_tx_d), .q(tx_q));

    wire                 tz_en = t_own ? t_tz_we : h_tz_en;
    wire                 tz_we = t_own & t_tz_we;
    wire [TBW+ZJW-1:0]   tz_a  = t_own ? t_tz_addr : h_tz_addr;
    rondo_sram_sp #(.DEPTH(1 << (TBW + ZJW)), .WIDTH(32)) u_tz (.clk(clk), .en(tz_en), .we(tz_we), .addr(tz_a),
        .d(t_tz_d), .q(tz_q));
endmodule
