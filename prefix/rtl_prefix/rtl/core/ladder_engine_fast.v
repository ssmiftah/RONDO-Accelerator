// ladder_engine_fast: the lane with both bottlenecks removed.
//
// Same interface and result as ladder_engine, but:
//   * ladder_scan_scalar  instead of ladder_scan_iter -- one FMA per step rather
//     than a full 2x2 matrix product, because a folded scan only ever applies
//     the transfer matrix to a vector (see that module's header).
//   * recip_nr            instead of recip_wrap -- pipelined table + Newton-Raphson
//     rather than a blocking radix-2 digit recurrence, which was 79% of the
//     original lane's latency (docs/DIVIDER.md).
//
// The lane is now scan-bound: the reciprocal accepts one operand per cycle, so
// the DEPTH-1 sequential scan steps set the rate.

`include "cofr_defs.vh"

module ladder_engine_fast #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter GEN   = 0,
    parameter TBITS = 12,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                        clock,
    input                        nReset,
    input                        in_valid,
    output                       in_ready,
    input  [DEPTH*(EXP+SIG)-1:0] a,
    input  [DEPTH*(EXP+SIG)-1:0] b,
    output                       out_valid,
    output [(EXP+SIG)-1:0]       f
);
    localparam integer W = EXP + SIG;

    wire        scan_ready, scan_ovalid;
    wire [W-1:0] k0, k1;
    ladder_scan_scalar #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .GEN(GEN)) u_scan (
        .clock(clock), .nReset(nReset),
        .in_valid(in_valid), .in_ready(scan_ready),
        .a(a), .b(b),
        .out_valid(scan_ovalid), .k0(k0), .k1(k1)
    );

    // b0 scaling for the generalized form, held while the reciprocal runs
    reg [W-1:0] b0_r;
    always @(posedge clock or negedge nReset) begin
        if (!nReset)          b0_r <= '0;
        else if (in_valid)    b0_r <= b[0 +: W];
    end

    wire        rec_valid;
    wire [W-1:0] f_w;
    recip_nr #(.EXP(EXP), .SIG(SIG), .TBITS(TBITS), .EPS(EPS), .SEED_FILE(SEED_FILE)) u_recip (
        .clock(clock), .nReset(nReset),
        .inValid(scan_ovalid), .inReady(),
        .k0(k0), .k1(k1),
        .outValid(rec_valid), .f(f_w)
    );

    wire [W-1:0] f_final;
    generate
        if (GEN != 0) begin : g_bmul
            fp_mul #(.EXP(EXP), .SIG(SIG)) u_b0 (.x(f_w), .y(b0_r), .p(f_final));
        end else begin : g_nomul
            assign f_final = f_w;
        end
    endgenerate

    reg [W-1:0] f_r;
    reg         ov_r;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin f_r <= '0; ov_r <= 1'b0; end
        else begin f_r <= f_final; ov_r <= rec_valid; end
    end

    assign in_ready  = scan_ready;
    assign out_valid = ov_r;
    assign f         = f_r;
endmodule
