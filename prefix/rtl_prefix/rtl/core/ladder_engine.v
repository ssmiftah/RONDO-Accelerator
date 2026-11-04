// ladder_engine: one iterative ladder, denominators -> f = K1/K0.
//
// Chains the folded scan (ladder_scan_iter) into the pole-guarded divider
// (recip_wrap) behind a single valid/ready interface. This is the reusable
// per-ladder lane for cofr_coproc (M2). Same result as ladder_top, but the
// iterative scan makes it FPGA-timing-friendly and DSP-light.
//
// Handshake: in_ready high when idle; pulse in_valid + a to start; out_valid
// pulses when f is valid. Latency = (DEPTH-1) scan cycles + divider latency.

`include "cofr_defs.vh"

module ladder_engine #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter GEN   = 0,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS
) (
    input                        clock,
    input                        nReset,
    input                        in_valid,
    output                       in_ready,
    input  [DEPTH*(EXP+SIG)-1:0] a,
    input  [DEPTH*(EXP+SIG)-1:0] b,   // partial numerators; used only when GEN=1
    output                       out_valid,
    output [(EXP+SIG)-1:0]       f
);
    localparam integer W = EXP + SIG;
    localparam [1:0] S_IDLE = 2'd0, S_SCAN = 2'd1, S_DIV = 2'd2;

    reg [1:0]   state;
    reg         scan_start, div_start, ovalid_r;
    reg [W-1:0] f_r, b0_r;

    wire        scan_ready, scan_ovalid;
    wire [W-1:0] k0, k1;
    ladder_scan_iter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .GEN(GEN)) u_scan (
        .clock   (clock),  .nReset  (nReset),
        .in_valid(scan_start), .in_ready(scan_ready),
        .a       (a), .b(b),
        .out_valid(scan_ovalid), .k0(k0), .k1(k1)
    );

    wire        div_ready, div_ovalid;
    wire [W-1:0] f_w;
    recip_wrap #(.EXP(EXP), .SIG(SIG), .EPS(EPS)) u_recip (
        .clock  (clock), .nReset (nReset),
        .inValid(div_start), .inReady(div_ready),
        .k0     (k0), .k1(k1),
        .outValid(div_ovalid), .f(f_w)
    );

    // Generalized output stage: f = (K1/K0) * b0. Combinational multiply; b0
    // latched at start. Unit numerators (GEN=0): pass the divide result through.
    wire [W-1:0] f_final;
    generate
        if (GEN != 0) begin : g_bmul
            fp_mul #(.EXP(EXP), .SIG(SIG)) u_bmul (.x(f_w), .y(b0_r), .p(f_final));
        end else begin : g_nomul
            assign f_final = f_w;
        end
    endgenerate

    assign in_ready  = (state == S_IDLE);
    assign out_valid = ovalid_r;
    assign f         = f_r;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            state      <= S_IDLE;
            scan_start <= 1'b0;
            div_start  <= 1'b0;
            ovalid_r   <= 1'b0;
        end else begin
            scan_start <= 1'b0;   // default: one-cycle pulses
            div_start  <= 1'b0;
            ovalid_r   <= 1'b0;
            case (state)
                S_IDLE: if (in_valid) begin
                    scan_start <= 1'b1;
                    b0_r       <= b[0 +: W];   // latch b0 for the output multiply
                    state      <= S_SCAN;
                end
                S_SCAN: if (scan_ovalid && div_ready) begin
                    div_start <= 1'b1;      // k0,k1 held stable by the scan regs
                    state     <= S_DIV;
                end
                S_DIV: if (div_ovalid) begin
                    f_r      <= f_final;    // (K1/K0)*b0 for GEN, else K1/K0
                    ovalid_r <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
