// ladder_scan_scalar: continuant scan on ONE fp FMA. Drop-in for ladder_scan_iter.
//
// Same result (K0,K1 = first column of M_0 @ ... @ M_{DEPTH-1}) and the same
// DEPTH-1 cycles, but one FMA per cycle instead of a full 2x2 matrix multiply.
//
// Why this is correct, and why the 2x2 was never needed here: the ladder is a
// product of transfer matrices applied to [1,0]^T. Accumulating the *matrix*
// product needs a full 2x2 multiply (8 FMA) each step. Accumulating onto the
// *vector* instead needs only
//
//     K[k] = a[k]*K[k+1] + b[k+1]*K[k+2]
//
// which is one FMA, because the companion matrix's second row just shifts.
// Associativity buys the option of a parallel-prefix tree, and a tree does need
// full 2x2 products -- it combines two arbitrary partial products. A folded lane
// never does that, so it should not pay for it. `kscan` already uses this form
// for the backward pass; this is the same recurrence with two rolling registers
// instead of the whole K array.
//
// Handshake: in_ready high when idle; assert in_valid + a for one cycle;
// out_valid pulses with K0,K1 valid.

`include "cofr_defs.vh"

module ladder_scan_scalar #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter GEN   = 0            // 0 = unit numerators (b ignored); 1 = generalized
) (
    input                        clock,
    input                        nReset,
    input                        in_valid,
    output                       in_ready,
    input  [DEPTH*(EXP+SIG)-1:0] a,
    input  [DEPTH*(EXP+SIG)-1:0] b,
    output                       out_valid,
    output [(EXP+SIG)-1:0]       k0,
    output [(EXP+SIG)-1:0]       k1
);
    localparam integer W      = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer KW     = (DEPTH < 3) ? 1 : $clog2(DEPTH);
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_DONE = 2'd2;

    reg [1:0]         state;
    reg [KW-1:0]      k;                 // current index, counts DEPTH-2 down to 0
    reg [W-1:0]       lo, hi;            // lo = K[k+1], hi = K[k+2]
    reg [DEPTH*W-1:0] a_reg, b_reg;
    reg               ovalid_r;

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;
    assign k0        = lo;               // after the last step lo = K[0], hi = K[1]
    assign k1        = hi;

    wire [31:0]  k32 = 32'(k);
    wire [W-1:0] a_k = a_reg[k32 * W +: W];

    // GEN=0: K[k] = a[k]*lo + hi.  GEN=1: K[k] = a[k]*lo + b[k+1]*hi, so the
    // b-scaling is one extra multiply chained into the FMA's addend.
    wire [W-1:0] addend;
    generate
        if (GEN != 0) begin : g_bmul
            wire [W-1:0] b_k1 = b_reg[(k32 + 32'd1) * W +: W];
            fp_mul #(.EXP(EXP), .SIG(SIG)) u_bmul (.x(b_k1), .y(hi), .p(addend));
        end else begin : g_nob
            assign addend = hi;
        end
    endgenerate

    wire [W-1:0] mac;
    fp_fma #(.EXP(EXP), .SIG(SIG)) u_mac (.a(a_k), .b(lo), .c(addend), .p(mac));

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; k <= '0; lo <= '0; hi <= '0; ovalid_r <= 1'b0;
            a_reg <= '0; b_reg <= '0;   // else X propagates through the
                                        // combinational FMA before first load
        end else begin
            ovalid_r <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    a_reg <= a;
                    b_reg <= b;
                    lo    <= a[(DEPTH-1) * W +: W];      // K[DEPTH-1] = a[DEPTH-1]
                    hi    <= F_ONE;                      // K[DEPTH]   = 1
                    if (DEPTH < 2) begin
                        state <= S_DONE;                 // no steps to run
                    end else begin
                        k     <= KW'(DEPTH - 2);
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    lo <= mac;                           // K[k]
                    hi <= lo;                            // K[k+1]
                    if (k == '0) state <= S_DONE;
                    else         k <= k - KW'(1);
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
