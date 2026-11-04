// recip_nr_pipe wrapper selecting the seed file by number (string defparams are not
// portable across simulators).
module tb_recip #(
    parameter EXP = 8, SIG = 24, TBITS = 12, NR_ITERS = 1, SEEDSEL = 1, FMA_LAT = 5,
    parameter EPSV = 32'h3C23D70A,
    parameter SEED_FILE = (SEEDSEL == 0) ? "recip_seed_e8s8_t6.mem" :
                          (SEEDSEL == 1) ? "recip_seed_e8s24_t12.mem" : "recip_seed_e8s24_t8.mem",
    parameter W = EXP + SIG
) (
    input clock, nReset, input inValid, input [W-1:0] k0, k1,
    output outValid, output [W-1:0] f, output guard_hit
);
    recip_nr_pipe #(.EXP(EXP), .SIG(SIG), .TBITS(TBITS), .FMA_LAT(FMA_LAT), .EPS(EPSV),
                    .SEED_FILE(SEED_FILE), .NR_ITERS(NR_ITERS)) u (
        .clock(clock), .nReset(nReset), .inValid(inValid), .inReady(), .k0(k0), .k1(k1),
        .outValid(outValid), .f(f), .guard_hit(guard_hit));
endmodule
