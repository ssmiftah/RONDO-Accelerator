// ladder_scan_iter: iterative (folded) continuant scan -- the FPGA-timing path.
//
// Same result as ladder_scan (K0,K1 = first column of M_0 @ ... @ M_{DEPTH-1}),
// but reuses ONE mat2x2_mul over DEPTH-1 cycles instead of a combinational chain
// of DEPTH-1 instances. This breaks the long combinational path (meets timing)
// and uses ~1/(DEPTH-1) the DSP48s. Latency DEPTH-1 cycles; its throughput is
// hidden behind the multi-cycle divider downstream (see docs/ACCELERATOR_DESIGN.md).
//
// Handshake: in_ready high when idle; assert in_valid + a for one cycle to start;
// out_valid pulses with K0,K1 valid. Parameterized in format (EXP,SIG) and DEPTH.

`include "cofr_defs.vh"

module ladder_scan_iter #(
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
    input  [DEPTH*(EXP+SIG)-1:0] b,   // partial numerators; used only when GEN=1
    output                       out_valid,
    output [(EXP+SIG)-1:0]       k0,
    output [(EXP+SIG)-1:0]       k1
);
    localparam integer W    = EXP + SIG;
    localparam [EXP-1:0] BIAS = (1 << (EXP - 1)) - 1;
    localparam [W-1:0] F_ONE  = {1'b0, BIAS, {(SIG-1){1'b0}}};
    localparam [W-1:0] F_ZERO = {W{1'b0}};
    localparam integer CW = (DEPTH < 3) ? 1 : $clog2(DEPTH);
    // Transfer matrix M_k has top-right = b[k+1] (unit: 1). The last matrix's
    // top-right is a don't-care; b[DEPTH] does not exist, so use 1 there.
    localparam integer INIT_BSEL = (DEPTH > 1) ? 1 : 0;  // b index for M_0 (=b[1])

    reg [DEPTH*W-1:0] a_reg, b_reg;
    reg [W-1:0]       P00, P01, P10, P11;
    reg [CW-1:0]      cnt;
    reg               busy, done_r;

    // Combine current running product P with M_cnt = [[a_cnt, b_{cnt+1}], [1, 0]].
    // not_last = cnt is not the final matrix (index DEPTH-1). Built via generate
    // so there is no width-mismatched compare, nor (at DEPTH==1) a runtime
    // comparison that is constant under unsigned arithmetic.
    wire not_last;
    generate
        if (DEPTH > 1) assign not_last = (cnt < CW'(DEPTH - 1));
        else           assign not_last = 1'b0;
    endgenerate
    wire [W-1:0]   a_cnt = a_reg[cnt*W +: W];
    wire [CW-1:0]  bidx  = not_last ? (cnt + CW'(1)) : {CW{1'b0}};   // b index (bounded)
    wire [W-1:0]   tr    = (GEN != 0 && not_last) ? b_reg[bidx*W +: W] : F_ONE;
    wire [W-1:0] n00, n01, n10, n11;
    mat2x2_mul #(.EXP(EXP), .SIG(SIG)) u_mm (
        .l00(P00), .l01(P01), .l10(P10), .l11(P11),
        .r00(a_cnt), .r01(tr), .r10(F_ONE), .r11(F_ZERO),
        .p00(n00), .p01(n01), .p10(n10), .p11(n11)
    );

    assign in_ready  = ~busy;
    assign out_valid = done_r;
    assign k0 = P00;
    assign k1 = P10;

    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            busy   <= 1'b0;
            done_r <= 1'b0;
            cnt    <= {CW{1'b0}};
        end else begin
            done_r <= 1'b0;
            if (!busy) begin
                if (in_valid) begin
                    a_reg <= a;
                    b_reg <= b;
                    // P = M_0 = [[a_0, b_1], [1, 0]]  (b_1 = 1 for unit numerators)
                    P00 <= a[0 +: W];
                    P01 <= (GEN != 0 && DEPTH > 1) ? b[INIT_BSEL*W +: W] : F_ONE;
                    P10 <= F_ONE;
                    P11 <= F_ZERO;
                    if (DEPTH == 1) begin
                        done_r <= 1'b1;         // K0=a_0, K1=1 immediately
                    end else begin
                        busy <= 1'b1;
                        cnt  <= CW'(1);
                    end
                end
            end else begin
                // fold M_cnt into P
                P00 <= n00; P01 <= n01; P10 <= n10; P11 <= n11;
                if (cnt == CW'(DEPTH - 1)) begin
                    busy   <= 1'b0;
                    done_r <= 1'b1;
                end else begin
                    cnt <= cnt + CW'(1);
                end
            end
        end
    end
endmodule
