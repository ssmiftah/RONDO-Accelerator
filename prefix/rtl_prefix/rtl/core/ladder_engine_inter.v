// ladder_engine_inter: the interleaved lane.
//
//   ladder_scan_inter (NSLOT ladders on one pipelined FMA)
//     -> streaming results, one per cycle across the final rotation
//       -> recip_nr_pipe (II=1)
//
// Both halves are fully pipelined and both clock ~102-108 MHz post-route, versus
// ~30 MHz for ladder_engine_fast and ~18 MHz for the original ladder_engine
// (docs/TIMING_CORRECTION.md).
//
// The streaming handoff is what makes the composition free: the scan finishes one
// slot per cycle and the reciprocal accepts one per cycle, so no buffering,
// backpressure or rate matching is needed between them.
//
// Batch in (NSLOT ladders), stream out (NSLOT results, one per cycle).
// Unit numerators only, following ladder_scan_inter.

`include "cofr_defs.vh"

module ladder_engine_inter #(
    parameter EXP     = `COFR_EXP,
    parameter SIG     = `COFR_SIG,
    parameter DEPTH   = `COFR_DEPTH,
    parameter NSLOT   = 8,
    parameter TBITS   = 12,
    parameter FMA_LAT = 5,
    parameter [(`COFR_EXP+`COFR_SIG)-1:0] EPS = `COFR_EPS,
    parameter SEED_FILE = "recip_seed_e8s24_t12.mem",
    parameter GATE = 1,
    parameter NR_ITERS = 1       // C7
) (
    input                              clock,
    input                              nReset,
    input                              in_valid,
    output                             in_ready,
    input  [NSLOT*DEPTH*(EXP+SIG)-1:0] a_all,
    output                             out_valid,   // one result per cycle
    output [(EXP+SIG)-1:0]             f,
    output                             guard_hit,   // C2: pole-guard clamp pulse
    // C4 debug taps (plain wiring)
    output [NSLOT*(EXP+SIG)-1:0]       k0_all,
    output [NSLOT*(EXP+SIG)-1:0]       k1_all,
    output                             res_valid,
    output [(EXP+SIG)-1:0]             res_k0,
    output [(EXP+SIG)-1:0]             res_k1
);
    localparam integer W = EXP + SIG;

    wire               scan_ready, scan_done;
    wire               res_v;
    wire [W-1:0]       res_k0_w, res_k1_w;
    ladder_scan_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH),
                        .NSLOT(NSLOT), .FMA_LAT(FMA_LAT), .GATE(GATE)) u_scan (
        .clock(clock), .nReset(nReset),
        .in_valid(in_valid), .in_ready(scan_ready),
        .a_all(a_all),
        .out_valid(scan_done), .k0_all(k0_all), .k1_all(k1_all),
        .res_valid(res_v), .res_k0(res_k0_w), .res_k1(res_k1_w)
    );

    recip_nr_pipe #(.EXP(EXP), .SIG(SIG), .TBITS(TBITS),
                    .FMA_LAT(FMA_LAT), .EPS(EPS), .SEED_FILE(SEED_FILE),
                    .GATE(GATE), .NR_ITERS(NR_ITERS)) u_recip (
        .clock(clock), .nReset(nReset),
        .inValid(res_v), .inReady(),
        .k0(res_k0_w), .k1(res_k1_w),
        .outValid(out_valid), .f(f), .guard_hit(guard_hit)
    );

    assign in_ready  = scan_ready;
    assign res_valid = res_v;
    assign res_k0    = res_k0_w;
    assign res_k1    = res_k1_w;
endmodule
