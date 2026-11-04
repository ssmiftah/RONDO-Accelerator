// Activity stimulus for kscan_inter, for SAIF-based power.
//
// Drives back-to-back batches so the scan is busy rather than idle: power taken
// over a window that includes the fill and drain of a single batch would charge
// the design for cycles it does not spend in steady state.
//
// NUMER_NEG selects what is being measured. With 0 this is the continued
// fraction the paper is about; with 1 it is a Chebyshev basis, every coefficient
// driven to 2x and the seed to x. The two builds differ by one XOR, so running
// both through the same flow is how the claim that the second basis is free gets
// tested rather than asserted.
//
// Stimulus is read from a file rather than generated here, so the values are the
// same ones the functional test checked and the activity reflects real operands.
// Random bits would produce denormals and NaNs and a toggle rate no workload
// ever sees.

`timescale 1ns/1ps

module tb_kscan_power;
    parameter EXP       = 8;
    parameter SIG       = 24;
    parameter DEPTH     = 8;
    parameter NSLOT     = 8;
    parameter NUMER_NEG = 1;
    parameter NBATCH    = 64;      // batches driven back to back

    localparam integer W = EXP + SIG;

    reg clock = 1'b0, nReset = 1'b0, in_valid = 1'b0;
    wire in_ready, out_valid;
    reg  [NSLOT*DEPTH*W-1:0] a_all;
    wire [NSLOT*(DEPTH+1)*W-1:0] Kv_all;

`ifdef NETLIST
    kscan_inter dut (
`else
    kscan_inter #(.EXP(EXP), .SIG(SIG), .DEPTH(DEPTH), .NSLOT(NSLOT),
                  .NUMER_NEG(NUMER_NEG)) dut (
`endif
        .clock(clock), .nReset(nReset),
        .in_valid(in_valid), .in_ready(in_ready),
        .a_all(a_all), .out_valid(out_valid), .Kv_all(Kv_all)
    );

    always #5 clock = ~clock;              // 10 ns

    reg [31:0] xmem [0:NSLOT*NBATCH-1];    // one x per slot per batch
    reg [W-1:0] cks;
    integer b, s, k, guard;

    initial begin
        $readmemh("kscan_stim.mem", xmem);
        cks = '0;
        repeat (8) @(posedge clock);
        nReset = 1'b1;
        repeat (4) @(posedge clock);

        for (b = 0; b < NBATCH; b = b + 1) begin
            // a[k] = 2x for every level; a[DEPTH-1] = x seeds the first kind
            for (s = 0; s < NSLOT; s = s + 1)
                for (k = 0; k < DEPTH; k = k + 1)
                    a_all[((s*DEPTH)+k)*W +: W] =
                        (k == DEPTH-1) ? xmem[b*NSLOT + s]
                                       : {xmem[b*NSLOT+s][31],
                                          xmem[b*NSLOT+s][30:23] + 8'd1,
                                          xmem[b*NSLOT+s][22:0]};   // x*2
            @(posedge clock);
            in_valid = 1'b1;
            @(posedge clock);
            in_valid = 1'b0;
            guard = 0;
            while (out_valid !== 1'b1) begin
                @(posedge clock);
                guard = guard + 1;
                if (guard > 100000) begin
                    $display("TB ERROR: no out_valid on batch %0d", b);
                    $finish;
                end
            end
            for (s = 0; s < NSLOT*(DEPTH+1); s = s + 1)
                cks = cks ^ Kv_all[s*W +: W];
        end
        repeat (10) @(posedge clock);
        $display("TB_DONE %0d batches cks=%h", NBATCH, cks);
        $finish;
    end
endmodule
