// affine_unit: generates one ladder's partial denominators on chip.
//
//     a[k] = w[k] . x + bias[k],   k = 0 .. DEPTH-1
//
// Front half of the fused datapath. Without it the coefficients must be produced
// elsewhere and streamed in, which is the memory traffic fusion removes: `a` is
// DEPTH values per ladder, while `x` is PDIM values shared across the bank.
//
// Two things are parameterised because the first version got both wrong:
//
//  * WEIGHTS LIVE IN A MEMORY, not in flops. They are stationary, so they are
//    loaded once through the w_we/w_addr/w_din port and read one word per cycle.
//    Holding DEPTH*PDIM coefficients in registers cost 9k flip-flops for a single
//    ladder and does not scale to a bank.
//  * NMAC sets how many multiply-accumulates run per cycle. The affine stage does
//    DEPTH*PDIM MACs against the scan's DEPTH-1 combines, so at NMAC=1 it is
//    ~PDIM times the scan's work and dominates. Widening it trades area for that.
//
// The NMAC MACs are chained combinationally, which keeps the accumulation order
// identical to the NMAC=1 case: results are bit-identical across NMAC, only the
// cycle count changes. Long chains cost timing, so keep NMAC small (2-8).
//
// Handshake: in_ready high when idle; pulse in_valid with x/bias held; out_valid
// pulses with the full `a` vector valid. Weight loads must be idle-time.

`include "cofr_defs.vh"

module affine_unit #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter PDIM  = 8,                      // input dimensionality p
    parameter NMAC  = 1,                      // MACs per cycle
    // derived -- do not override
    parameter CHUNKS = (PDIM + NMAC - 1) / NMAC,
    parameter NWORDS = DEPTH * CHUNKS,
    parameter WAW    = (NWORDS < 2) ? 1 : $clog2(NWORDS)
) (
    input                          clock,
    input                          nReset,
    // weight load (stationary; one NMAC-wide word per address)
    input                          w_we,
    input  [WAW-1:0]               w_addr,
    input  [NMAC*(EXP+SIG)-1:0]    w_din,
    // evaluate
    input                          in_valid,
    output                         in_ready,
    input  [PDIM*(EXP+SIG)-1:0]    x,
    input  [DEPTH*(EXP+SIG)-1:0]   bias,
    output                         out_valid,
    output [DEPTH*(EXP+SIG)-1:0]   a
);
    localparam integer W    = EXP + SIG;
    localparam integer XPAD = CHUNKS * NMAC;                // x zero-padded to a whole word
    localparam integer KW   = (DEPTH  < 2) ? 1 : $clog2(DEPTH);
    localparam integer CW     = (CHUNKS < 2) ? 1 : $clog2(CHUNKS);
    localparam [1:0] S_IDLE = 2'd0, S_MAC = 2'd1, S_DONE = 2'd2;

    // Stationary weights. Written once, read one word per cycle -- this is the
    // shape Yosys/Vivado infer as block RAM rather than flops.
    reg [NMAC*W-1:0] w_mem [0:NWORDS-1];
    reg [NMAC*W-1:0] w_word;

    reg [1:0]         state;
    reg [KW-1:0]      k;
    reg [CW-1:0]      c;
    reg [W-1:0]       acc;
    reg [DEPTH*W-1:0] a_reg;
    reg [XPAD*W-1:0]  x_reg;
    reg [DEPTH*W-1:0] bias_reg;
    reg               ovalid_r;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;
    assign a         = a_reg;

    wire [31:0] k32 = 32'(k);
    wire [31:0] c32 = 32'(c);

    // The memory read is registered, so present the address of the word wanted
    // NEXT cycle. In S_IDLE that is word 0, so the first MAC cycle is never stalled.
    wire        lastc_w = (c == CW'(CHUNKS - 1));
    wire        lastk_w = (k == KW'(DEPTH - 1));
    wire [31:0] nc = lastc_w ? 32'd0 : (c32 + 32'd1);
    wire [31:0] nk = lastc_w ? (lastk_w ? 32'd0 : (k32 + 32'd1)) : k32;
    wire [31:0] rd = (state == S_IDLE) ? 32'd0 : ((nk * CHUNKS) + nc);

    always @(posedge clock) begin
        if (w_we) w_mem[w_addr] <= w_din;
        w_word <= w_mem[rd[WAW-1:0]];
    end

    // NMAC chained FMAs. Chaining (not a tree) keeps the summation order the same
    // as NMAC=1, so the result is bit-identical whatever NMAC is set to.
    wire [W-1:0] chain [0:NMAC];
    assign chain[0] = acc;
    genvar m;
    generate
        for (m = 0; m < NMAC; m = m + 1) begin : g_mac
            wire [W-1:0] xm = x_reg[((c32 * NMAC) + m) * W +: W];
            fp_fma #(.EXP(EXP), .SIG(SIG)) u_mac (
                .a(w_word[m * W +: W]), .b(xm), .c(chain[m]), .p(chain[m + 1])
            );
        end
    endgenerate
    wire [W-1:0] mac = chain[NMAC];

    wire last_c = lastc_w;
    wire last_k = lastk_w;

    integer q;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; k <= '0; c <= '0; acc <= '0;
            a_reg <= '0; ovalid_r <= 1'b0;
        end else begin
            ovalid_r <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    x_reg <= '0;
                    for (q = 0; q < PDIM; q = q + 1)
                        x_reg[q * W +: W] <= x[q * W +: W];   // tail stays zero
                    bias_reg <= bias;
                    k <= '0; c <= '0;
                    acc   <= bias[0 +: W];
                    state <= S_MAC;
                end
                S_MAC: begin
                    if (last_c) begin
                        a_reg[k32 * W +: W] <= mac;
                        c <= '0;
                        if (last_k) begin
                            state <= S_DONE;
                        end else begin
                            k   <= k + KW'(1);
                            acc <= bias_reg[(k32 + 32'd1) * W +: W];
                        end
                    end else begin
                        acc <= mac;
                        c   <= c + CW'(1);
                    end
                end
                S_DONE: begin
                    ovalid_r <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
