// ladder_engine_naive: the ladder evaluated as written, one division per level.
//
// This is the baseline the continuant reformulation is measured against. It
// exists only for that comparison and is not part of the accelerator.
//
// The continued fraction, evaluated bottom-up exactly as the mathematics states
// it:
//
//     t = a[d-1]
//     for k = d-2 .. 0:  t = a[k] + 1/t
//     f = 1/t
//
// which is d reciprocals, each a blocking multi-cycle HardFloat divSqrtRecFN.
// The continuant form computes the same value with **one** division regardless
// of depth (docs/ACCELERATOR_DESIGN.md), which is the claim this module lets us
// price.
//
// Two costs are being measured, not one:
//   - cycles: d blocking divisions in series versus 1
//   - numerical exposure: d opportunities to divide by something near zero
//     versus exactly 1. W3 characterised the single pole; here every level has
//     one, and the pole guard has to be applied d times.
//
// Reuses recip_wrap (division + pole guard) and fp_fma (the add, as
// fma(1.0, q, a[k])) so the comparison isolates the algorithm rather than the
// quality of the arithmetic units.

`include "cofr_defs.vh"

module ladder_engine_naive #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                          clock,
    input                          nReset,
    input                          in_valid,
    output                         in_ready,
    input  [DEPTH*(EXP+SIG)-1:0]   a,
    output                         out_valid,
    output [(EXP+SIG)-1:0]         f
);
    localparam integer W      = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam integer KW     = (DEPTH < 3) ? 2 : ($clog2(DEPTH) + 1);

    localparam [2:0] S_IDLE = 3'd0, S_RECIP = 3'd1, S_WAIT = 3'd2,
                     S_ADD  = 3'd3, S_FINAL = 3'd4, S_WAIT2 = 3'd5,
                     S_DONE = 3'd6;

    reg [2:0]              state;
    reg signed [KW-1:0]    k;
    reg [DEPTH*W-1:0]      a_reg;
    reg [W-1:0]            t;
    reg [W-1:0]            f_reg;

    wire [31:0] k32 = 32'(k);
    wire [W-1:0] a_k = a_reg[k32 * W +: W];

    // 1/t with the pole guard: recip_wrap(k0=t, k1=1.0)
    reg          rv;
    wire         r_ready, r_valid;
    wire [W-1:0] r_out;
    recip_wrap #(.EXP(EXP), .SIG(SIG), .EPS(EPS)) u_recip (
        .clock(clock), .nReset(nReset),
        .inValid(rv), .inReady(r_ready),
        .k0(t), .k1(F_ONE),
        .outValid(r_valid), .f(r_out)
    );

    // t = a[k] + q   as fma(1.0, q, a[k])
    reg  [W-1:0] q;
    wire [W-1:0] sum;
    fp_fma #(.EXP(EXP), .SIG(SIG)) u_add (.a(F_ONE), .b(q), .c(a_k), .p(sum));

    assign in_ready  = (state == S_IDLE);
    assign out_valid = (state == S_DONE);
    assign f         = f_reg;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; k <= '0; a_reg <= '0; t <= '0;
            q <= '0; f_reg <= '0; rv <= 1'b0;
        end else begin
            rv <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    a_reg <= a;
                    t     <= a[(DEPTH-1) * W +: W];      // t = a[d-1]
                    k     <= KW'(DEPTH - 2);
                    state <= (DEPTH < 2) ? S_FINAL : S_RECIP;
                end
                S_RECIP: if (r_ready) begin              // issue 1/t
                    rv    <= 1'b1;
                    state <= S_WAIT;
                end
                S_WAIT: if (r_valid) begin
                    q     <= r_out;
                    state <= S_ADD;
                end
                S_ADD: begin                             // t = a[k] + 1/t
                    t <= sum;
                    if (k == 0) state <= S_FINAL;
                    else begin k <= k - KW'(1); state <= S_RECIP; end
                end
                S_FINAL: if (r_ready) begin              // f = 1/t
                    rv    <= 1'b1;
                    state <= S_WAIT2;
                end
                S_WAIT2: if (r_valid) begin
                    f_reg <= r_out;
                    state <= S_DONE;                     // f_reg valid next cycle
                end
                S_DONE: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
