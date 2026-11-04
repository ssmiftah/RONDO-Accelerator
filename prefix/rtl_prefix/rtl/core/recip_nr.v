// recip_nr: pipelined pole-guarded reciprocal, f = k1 / guard(k0).
//
// Drop-in replacement for recip_wrap. The difference that matters is throughput:
// recip_wrap wraps HardFloat's divSqrtRecFN_small, a radix-2 digit recurrence
// that takes ~SIG+3 cycles and BLOCKS the lane. At depth 7 that one division is
// ~79% of the lane's latency -- the bottleneck sits inside the very operation
// the design exists to perform once instead of d times.
//
// This computes the reciprocal multiplicatively instead:
//
//     x0 = seed(b)                 table lookup on the top TBITS fraction bits
//     x1 = x0 * (2 - b*x0)         one Newton-Raphson iteration
//     f  = k1 * x1
//
// Each NR iteration doubles the correct bits, so a TBITS-bit seed needs
// ceil(log2(SIG/TBITS)) iterations. At fp32 with TBITS=12 one iteration reaches
// 2 ULP (validated against the same model in sim/test_recip_nr.py).
//
// Newton-Raphson rather than Goldschmidt: NR is self-correcting, so an error in
// one iteration is damped by the next, whereas Goldschmidt accumulates. Given
// how the guard band behaves near a pole (docs/WORKLOAD_RESULTS.md, W3) that is
// worth having.
//
// Fully pipelined: accepts a new operand every cycle, latency LAT cycles.
//
// The seed table is format-specific; regenerate with rtl/core/gen_recip_table.py.
// Only the normal-number path is implemented, which the pole guard guarantees:
// |b| >= EPS, so b is never zero, denormal, infinite or NaN.

`include "cofr_defs.vh"

module recip_nr #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter TBITS = 12,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem"
) (
    input                    clock,
    input                    nReset,
    input                    inValid,
    output                   inReady,
    input  [(EXP+SIG)-1:0]   k0,
    input  [(EXP+SIG)-1:0]   k1,
    output                   outValid,
    output [(EXP+SIG)-1:0]   f
);
    localparam integer W    = EXP + SIG;
    localparam integer FR   = SIG - 1;                 // fraction bits
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    // exponent of 1/b: for b = 2^(E-BIAS) * 1.m the reciprocal is
    // 2^(-(E-BIAS)-1) * (2/1.m), and 2/1.m lies in (1,2], so the stored
    // fraction is that of 2/1.m and the exponent field is 2*BIAS-1-E.
    localparam [EXP+1:0] ESUM = (2 * BIAS) - 1;
    localparam [W-1:0] F_TWO = {1'b0, BIAS + 1'b1, {FR{1'b0}}};   // 2.0
    localparam integer LAT = 5;

    assign inReady = 1'b1;                              // fully pipelined

    // ---------------- S0: pole guard, and hold k1 alongside ----------------
    wire            s0_sign = k0[W-1];
    wire [W-2:0]    s0_mag  = k0[W-2:0];
    wire            s0_small = (s0_mag < EPS[W-2:0]);
    wire [W-1:0]    s0_b = {s0_sign, s0_small ? EPS[W-2:0] : s0_mag};

    reg [W-1:0] b_1, k1_1;
    reg         v_1;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_1 <= 1'b0; b_1 <= '0; k1_1 <= '0; end
        else begin v_1 <= inValid; b_1 <= s0_b; k1_1 <= k1; end
    end

    // ---------------- S1: seed x0 from the table ---------------------------
    (* rom_style = "block" *) reg [FR-1:0] seed_rom [0:(1<<TBITS)-1];
    initial $readmemh(SEED_FILE, seed_rom);

    wire [EXP-1:0]   b1_exp  = b_1[W-2 -: EXP];
    wire [FR-1:0]    b1_frac = b_1[FR-1:0];
    wire [TBITS-1:0] tidx    = b1_frac[FR-1 -: TBITS];
    wire [EXP+1:0]   e0_full = ESUM - {2'b00, b1_exp};
    // The guard bounds |b| away from zero, and K0 is finite, so e0 stays in
    // range for any input the datapath can produce; clamp defensively anyway.
    wire [EXP-1:0]   e0 = (e0_full[EXP+1] || e0_full == '0) ? {{(EXP-1){1'b0}}, 1'b1}
                        : (e0_full > {2'b00, {EXP{1'b1}}} - 1) ? {EXP{1'b1}} - 1'b1
                        : e0_full[EXP-1:0];

    reg [W-1:0] x0_2, b_2, k1_2;
    reg         v_2;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_2 <= 1'b0; x0_2 <= '0; b_2 <= '0; k1_2 <= '0; end
        else begin
            v_2  <= v_1;
            x0_2 <= {b_1[W-1], e0, seed_rom[tidx]};
            b_2  <= b_1;
            k1_2 <= k1_1;
        end
    end

    // ---------------- S2: t = 2 - b*x0  (one fused multiply-add) -----------
    wire [W-1:0] nb_2 = {~b_2[W-1], b_2[W-2:0]};        // -b
    wire [W-1:0] t_w;
    fp_fma #(.EXP(EXP), .SIG(SIG)) u_fma (.a(nb_2), .b(x0_2), .c(F_TWO), .p(t_w));

    reg [W-1:0] t_3, x0_3, k1_3;
    reg         v_3;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_3 <= 1'b0; t_3 <= '0; x0_3 <= '0; k1_3 <= '0; end
        else begin v_3 <= v_2; t_3 <= t_w; x0_3 <= x0_2; k1_3 <= k1_2; end
    end

    // ---------------- S3: x1 = x0 * t --------------------------------------
    wire [W-1:0] x1_w;
    fp_mul #(.EXP(EXP), .SIG(SIG)) u_mul_nr (.x(x0_3), .y(t_3), .p(x1_w));

    reg [W-1:0] x1_4, k1_4;
    reg         v_4;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_4 <= 1'b0; x1_4 <= '0; k1_4 <= '0; end
        else begin v_4 <= v_3; x1_4 <= x1_w; k1_4 <= k1_3; end
    end

    // ---------------- S4: f = k1 * x1 --------------------------------------
    wire [W-1:0] f_w;
    fp_mul #(.EXP(EXP), .SIG(SIG)) u_mul_out (.x(k1_4), .y(x1_4), .p(f_w));

    reg [W-1:0] f_5;
    reg         v_5;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_5 <= 1'b0; f_5 <= '0; end
        else begin v_5 <= v_4; f_5 <= f_w; end
    end

    assign outValid = v_5;
    assign f        = f_5;
endmodule
