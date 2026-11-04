// fp_fma_pipe: pipelined IEEE fp32 fused multiply-add, p = a*b + c.
//
// Same single-rounded result as fp_fma, but split into four registered stages so
// the clock is not held hostage by one ~33 ns combinational chain. Post-route
// timing showed the combinational version caps the lane at 18-30 MHz against an
// assumed 150-250 MHz (docs/TIMING_CORRECTION.md); this is the fix.
//
//   S1  recode the three operands
//   S2  preMul
//   S3  the multiply itself (maps to DSP48s)
//   S4  postMul
//   S5  round and decode
//
// Latency 5 cycles, initiation interval 1. Recode and preMul are separate
// stages because with them combined that path measured 11.1 ns and set the
// clock; splitting it is the difference between ~90 and ~150 MHz. HardFloat is deliberately factored
// into preMul / multiply / postMul / round for exactly this, so no arithmetic is
// reimplemented here -- only registers are inserted between existing blocks.
//
// NOTE ON USE: a sequential recurrence gains nothing from this on its own. The
// scan's dependency chain is the same logic whether it is one 33 ns cycle or four
// 8 ns ones. The gain comes from interleaving independent ladders through the
// pipeline, so the II=1 is actually used.

`include "cofr_defs.vh"
`include "HardFloat_consts.vi"
`include "HardFloat_specialize.vi"

module fp_fma_pipe #(
    parameter EXP = `COFR_EXP,
    parameter SIG = `COFR_SIG,
    // Data gating. Each stage's *data* registers load only when the stage
    // actually holds live data; the valid chain always advances. Registers then
    // hold their previous value through idle cycles, so the combinational cone
    // downstream of them stops toggling. Measured as I-16's largest single power
    // item: recip_nr_pipe's three FMAs run at 1/7 duty and burned 54% of a lane's
    // dynamic power because every stage toggled every cycle regardless.
    // Set GATE=0 to reproduce the ungated design for an A/B measurement.
    parameter GATE = 1
) (
    input                    clock,
    input                    nReset,
    input                    in_valid,
    input  [(EXP+SIG)-1:0]   a,
    input  [(EXP+SIG)-1:0]   b,
    input  [(EXP+SIG)-1:0]   c,
    output                   out_valid,
    output [(EXP+SIG)-1:0]   p
);
`include "HardFloat_localFuncs.vi"
    localparam integer RW  = EXP + SIG;              // recoded width - 1
    localparam integer CDW = clog2(SIG + 1);

    // ---------------- S1: recode -----------------------------------------
    wire [RW:0] ar_w, br_w, cr_w;
    fNToRecFN #(EXP, SIG) ea (.in(a), .out(ar_w));
    fNToRecFN #(EXP, SIG) eb (.in(b), .out(br_w));
    fNToRecFN #(EXP, SIG) ec (.in(c), .out(cr_w));

    // Stage enables. en_k is the valid entering stage k; with GATE=0 they are all
    // constant 1 and the design is bit-for-bit the original.
    wire en_0 = (GATE != 0) ? in_valid : 1'b1;

    reg [RW:0] ar, br, cr;
    reg        v_0;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_0 <= 1'b0; ar <= '0; br <= '0; cr <= '0; end
        else begin
            v_0 <= in_valid;
            if (en_0) begin ar <= ar_w; br <= br_w; cr <= cr_w; end
        end
    end
    wire en_1 = (GATE != 0) ? v_0 : 1'b1;

    // ---------------- S2: preMul ------------------------------------------
    wire [(SIG-1):0]        mulA_w, mulB_w;
    wire [(SIG*2-1):0]      mulC_w;
    wire [5:0]              cstate_w;
    wire signed [(EXP+1):0] sExp_w;
    wire [(CDW-1):0]        cdist_w;
    wire [(SIG+1):0]        highC_w;
    mulAddRecFNToRaw_preMul #(EXP, SIG) u_pre (
        `flControl_default, 2'b00, ar, br, cr, `round_near_even,
        mulA_w, mulB_w, mulC_w, cstate_w, sExp_w, cdist_w, highC_w);

    reg [(SIG-1):0]        mulA_1, mulB_1;
    reg [(SIG*2-1):0]      mulC_1;
    reg [5:0]              cstate_1;
    reg signed [(EXP+1):0] sExp_1;
    reg [(CDW-1):0]        cdist_1;
    reg [(SIG+1):0]        highC_1;
    reg                    v_1;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            v_1 <= 1'b0; mulA_1 <= '0; mulB_1 <= '0; mulC_1 <= '0;
            cstate_1 <= '0; sExp_1 <= '0; cdist_1 <= '0; highC_1 <= '0;
        end else begin
            v_1 <= v_0;
            if (en_1) begin
                mulA_1 <= mulA_w; mulB_1 <= mulB_w; mulC_1 <= mulC_w;
                cstate_1 <= cstate_w; sExp_1 <= sExp_w;
                cdist_1 <= cdist_w; highC_1 <= highC_w;
            end
        end
    end
    wire en_2 = (GATE != 0) ? v_1 : 1'b1;

    // ---------------- S3: the multiply (DSP territory) --------------------
    wire [SIG*2:0] mulRes_w = mulA_1 * mulB_1 + mulC_1;

    reg [SIG*2:0]          mulRes_2;
    reg [5:0]              cstate_2;
    reg signed [(EXP+1):0] sExp_2;
    reg [(CDW-1):0]        cdist_2;
    reg [(SIG+1):0]        highC_2;
    reg                    v_2;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            v_2 <= 1'b0; mulRes_2 <= '0; cstate_2 <= '0;
            sExp_2 <= '0; cdist_2 <= '0; highC_2 <= '0;
        end else begin
            v_2 <= v_1;
            if (en_2) begin
                mulRes_2 <= mulRes_w; cstate_2 <= cstate_1;
                sExp_2 <= sExp_1; cdist_2 <= cdist_1; highC_2 <= highC_1;
            end
        end
    end
    wire en_3 = (GATE != 0) ? v_2 : 1'b1;

    // ---------------- S4: postMul -----------------------------------------
    wire                    inv_w, isNaN_w, isInf_w, isZero_w, sign_w;
    wire signed [(EXP+1):0] oExp_w;
    wire [(SIG+2):0]        oSig_w;
    mulAddRecFNToRaw_postMul #(EXP, SIG) u_post (
        cstate_2, sExp_2, cdist_2, highC_2, mulRes_2, `round_near_even,
        inv_w, isNaN_w, isInf_w, isZero_w, sign_w, oExp_w, oSig_w);

    reg                    inv_3, isNaN_3, isInf_3, isZero_3, sign_3, v_3;
    reg signed [(EXP+1):0] oExp_3;
    reg [(SIG+2):0]        oSig_3;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin
            v_3 <= 1'b0; inv_3 <= 1'b0; isNaN_3 <= 1'b0; isInf_3 <= 1'b0;
            isZero_3 <= 1'b0; sign_3 <= 1'b0; oExp_3 <= '0; oSig_3 <= '0;
        end else begin
            v_3 <= v_2;
            if (en_3) begin
                inv_3 <= inv_w; isNaN_3 <= isNaN_w; isInf_3 <= isInf_w;
                isZero_3 <= isZero_w; sign_3 <= sign_w;
                oExp_3 <= oExp_w; oSig_3 <= oSig_w;
            end
        end
    end
    wire en_4 = (GATE != 0) ? v_3 : 1'b1;

    // ---------------- S5: round + decode ----------------------------------
    wire [RW:0] pr_w;
    wire [4:0]  fl_w;
    roundRawFNToRecFN #(EXP, SIG, 0) u_round (
        `flControl_default, inv_3, 1'b0, isNaN_3, isInf_3, isZero_3, sign_3,
        oExp_3, oSig_3, `round_near_even, pr_w, fl_w);
    wire [(EXP+SIG)-1:0] p_w;
    recFNToFN #(EXP, SIG) po (.in(pr_w), .out(p_w));

    reg [(EXP+SIG)-1:0] p_4;
    reg                 v_4;
    always @(posedge clock or negedge nReset) begin
        if (!nReset) begin v_4 <= 1'b0; p_4 <= '0; end
        else begin v_4 <= v_3; if (en_4) p_4 <= p_w; end
    end

    assign out_valid = v_4;
    assign p         = p_4;
endmodule
