// kscan: scalar continuant recurrence producing the FULL K[0..DEPTH] array.
//
//   K[DEPTH] = 1,  K[DEPTH-1] = a[DEPTH-1]
//   K[k]     = a[k]*K[k+1] + K[k+2]   for k = DEPTH-2 .. 0     (unit numerators)
//
// This is the training-oriented forward: it emits every continuant (needed by
// grad_a_unit for the backward pass) and costs only ONE FMA per cycle -- cheaper
// than the 2x2 matrix fold (8 FMA/cycle), which is instead preferred when the
// scan is parallelized for inference throughput. K0=K[0], K1=K[1] give f=K1/K0.
//
// Iterative: DEPTH-1 cycles. Handshake in_valid/in_ready -> out_valid. Unit
// numerators (matches the verified unit forward); parameterized in format,DEPTH.

`include "cofr_defs.vh"

module kscan #(
    parameter EXP   = `COFR_EXP,
    parameter SIG   = `COFR_SIG,
    parameter DEPTH = `COFR_DEPTH,
    parameter GEN   = 0             // 0 = unit numerators (b ignored); 1 = generalized
) (
    input                          clock,
    input                          nReset,
    input                          in_valid,
    output                         in_ready,
    input  [DEPTH*(EXP+SIG)-1:0]   a,
    input  [DEPTH*(EXP+SIG)-1:0]   b,   // partial numerators; used only when GEN=1
    output                         out_valid,
    output [((DEPTH+1)*(EXP+SIG))-1:0] Kv   // Kv[i] = K[i], i = 0..DEPTH
);
    localparam integer W    = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    // cnt counts iterations (max DEPTH-2) but also indexes K[0:DEPTH]; size it
    // wide enough for the array index (clog2(DEPTH+1)) so the K[cnt] selects are
    // clean under strict (Verilator) width checking.
    localparam integer CW = (DEPTH < 2) ? 1 : $clog2(DEPTH + 1);

    reg [DEPTH*W-1:0] a_reg, b_reg;
    reg [W-1:0]       K [0:DEPTH];
    reg [CW-1:0]      cnt;
    reg               busy, done_r;

    // K[cnt] = a[cnt]*K[cnt+1] + b[cnt+1]*K[cnt+2]   (b[cnt+1]=1 for unit)
    // Sized index helpers (CW-wide, always in range 0..DEPTH) so the K[] selects
    // and b[] part-select bases are width-clean under strict (Verilator) checking.
    wire [CW-1:0] cnt_p1 = cnt + CW'(1);   // K[cnt+1], b[cnt+1]
    wire [CW-1:0] cnt_p2 = cnt + CW'(2);   // K[cnt+2]
    wire [W-1:0] a_cnt = a_reg[cnt*W +: W];
    wire [W-1:0] bK2, nK;
    generate
        if (GEN != 0) begin : g_num
            fp_mul #(.EXP(EXP), .SIG(SIG)) u_bmul (
                .x(b_reg[cnt_p1*W +: W]), .y(K[cnt_p2]), .p(bK2)
            );
        end else begin : g_unit
            assign bK2 = K[cnt_p2];
        end
    endgenerate
    fp_fma #(.EXP(EXP), .SIG(SIG)) u_fma (
        .a(a_cnt), .b(K[cnt_p1]), .c(bK2), .p(nK)
    );

    assign in_ready  = ~busy;
    assign out_valid = done_r;

    genvar gi;
    generate
        for (gi = 0; gi <= DEPTH; gi = gi + 1) begin : pack
            assign Kv[gi*W +: W] = K[gi];
        end
    endgenerate

    integer j;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            busy   <= 1'b0;
            done_r <= 1'b0;
            cnt    <= {CW{1'b0}};
        end else begin
            done_r <= 1'b0;
            if (!busy) begin
                if (in_valid) begin
                    a_reg      <= a;
                    b_reg      <= b;
                    K[DEPTH]   <= F_ONE;               // boundary K[DEPTH]=1
                    K[DEPTH-1] <= a[(DEPTH-1)*W +: W]; // K[DEPTH-1]=a[DEPTH-1]
                    if (DEPTH == 1) begin
                        done_r <= 1'b1;                // K=[a0, 1] ready
                    end else begin
                        busy <= 1'b1;
                        cnt  <= CW'(DEPTH - 2);   // width-cast: DEPTH-2 fits CW, always ≥0 here
                    end
                end
            end else begin
                K[cnt] <= nK;
                if (cnt == 0) begin
                    busy   <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    cnt <= cnt - 1'b1;
                end
            end
        end
    end
endmodule
