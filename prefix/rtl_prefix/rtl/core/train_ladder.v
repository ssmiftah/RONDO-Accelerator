// train_ladder: forward + backward for one ladder in a single engine.
//
// Demonstrates the train-capable datapath (docs/ACCELERATOR_DESIGN.md sec 9): the
// forward continuants K[0..DEPTH] are computed once (kscan) and REUSED by the
// backward, which needs only ONE reciprocal (1/clamp_signed(K0)):
//
//   a --> kscan --> K[0..DEPTH]
//   K0=K[0] --> recip_wrap(1.0, K0) --> rK0 = 1/clamp_signed(K0)
//   f       = K1 * rK0                         (forward output)
//   grad_a  = grad_a_unit(K, rK0, grad_out)    (backward, closed form)
//
// Sequential (kscan then the multi-cycle divide). Handshake in_valid/in_ready ->
// out_valid, with f and grad_a valid together. Unit numerators; parameterized.

`include "cofr_defs.vh"

module train_ladder #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                        clock,
    input                        nReset,
    input                        in_valid,
    output                       in_ready,
    input  [DEPTH*(EXP+SIG)-1:0] a,
    input  [(EXP+SIG)-1:0]       grad_out,
    output                       out_valid,
    output [(EXP+SIG)-1:0]       f,
    output [DEPTH*(EXP+SIG)-1:0] grad_a
);
    localparam integer W    = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam [1:0] S_IDLE = 2'd0, S_SCAN = 2'd1, S_DIV = 2'd2;

    reg [1:0]   state;
    reg         scan_start, div_start, ovalid_r;
    reg [W-1:0] grad_out_r, f_r;
    reg [DEPTH*W-1:0] grad_a_r;

    // Forward: full continuant array
    wire                    scan_ready, scan_ovalid;
    wire [(DEPTH+1)*W-1:0]  Kv;
    kscan #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH)) u_kscan (   // GEN=0 (unit): b unused
        .clock(clock), .nReset(nReset),
        .in_valid(scan_start), .in_ready(scan_ready),
        .a(a), .b({(DEPTH*W){1'b0}}), .out_valid(scan_ovalid), .Kv(Kv)
    );
    wire [W-1:0] K0 = Kv[0    +: W];
    wire [W-1:0] K1 = Kv[1*W  +: W];

    // Reciprocal of the pole-guarded denominator: rK0 = 1/clamp_signed(K0)
    wire        div_ready, div_ovalid;
    wire [W-1:0] rK0;
    recip_wrap #(.EXP(EXP), .SIG(SIG), .EPS(EPS)) u_recip (
        .clock(clock), .nReset(nReset),
        .inValid(div_start), .inReady(div_ready),
        .k0(K0), .k1(F_ONE),                 // 1 / clamp_signed(K0)
        .outValid(div_ovalid), .f(rK0)
    );

    // Forward output f = K1 * rK0  (combinational)
    wire [W-1:0] f_comb;
    fp_mul #(.EXP(EXP), .SIG(SIG)) u_fmul (.x(K1), .y(rK0), .p(f_comb));

    // Backward gradient (combinational)
    wire [DEPTH*W-1:0] grad_a_comb;
    grad_a_unit #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH)) u_grad (
        .Kv(Kv), .rK0(rK0), .grad_out(grad_out_r), .grad_a(grad_a_comb)
    );

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;
    assign f         = f_r;
    assign grad_a    = grad_a_r;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state <= S_IDLE; scan_start <= 1'b0; div_start <= 1'b0; ovalid_r <= 1'b0;
        end else begin
            scan_start <= 1'b0; div_start <= 1'b0; ovalid_r <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    grad_out_r <= grad_out;
                    scan_start <= 1'b1;
                    state      <= S_SCAN;
                end
                S_SCAN: if (scan_ovalid && div_ready) begin
                    div_start <= 1'b1;   // K0/K1 held stable by kscan regs
                    state     <= S_DIV;
                end
                S_DIV: if (div_ovalid) begin
                    f_r      <= f_comb;
                    grad_a_r <= grad_a_comb;
                    ovalid_r <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
