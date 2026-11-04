// Power testbench for the Chebyshev KAN layer (kan_layer_bf16).
//
// Same structure as tb_fused_power: resident coefficients go in through the real
// load port (after synthesis the memories are BRAM primitives, so hierarchical
// $readmemh into them is not possible), then NSAMP back-to-back layer
// evaluations run while xsim logs a SAIF. run_saif.tcl opens the SAIF only after
// the load, so the activity is inference.
//
// cks is the XOR of every output word of every sample. workloads/kan_power.py
// compares it with the same XOR computed from a behavioural Verilator run of the
// identical stimulus, so a power number is only recorded for a netlist that
// provably computed the layer.

`timescale 1ns/1ps

module tb_kan_power_bf16;
    parameter W       = 16;   // bf16
    parameter DEPTH   = 7;
    parameter P_IN    = 40;
    parameter N_OUT   = 64;
    parameter N_LANES = 1;
    parameter NOB     = 8;
    parameter NMAC    = 8;
    parameter NBAS    = 1;
    parameter NSAMP   = 24;

    reg  clock = 1'b0;
    reg  nReset = 1'b0;
    reg  start = 1'b0;
    wire busy, done;
    reg  [P_IN*W-1:0] x;
    wire [N_OUT*W-1:0] y;

    localparam integer NOUTL    = N_OUT / N_LANES;
    localparam integer NGROUP   = NOB * (DEPTH + 1) / NMAC;
    localparam integer NBATCHES = NOUTL / NOB;
    localparam integer NWORDS   = NBATCHES * NGROUP * P_IN;

    reg              w_we = 1'b0;
    reg [31:0]       w_lane = 0, w_addr = 0;
    reg [NMAC*W-1:0] w_din = 0;

`ifdef NETLIST
    kan_layer_bf16 dut (
`else
    kan_layer_bf16 #(.DEPTH(DEPTH), .P_IN(P_IN), .N_OUT(N_OUT), .N_LANES(N_LANES),
                     .NOB(NOB), .NMAC(NMAC), .NBAS(NBAS)) dut (
`endif
        .clock(clock), .nReset(nReset),
        .w_we(w_we), .w_lane(w_lane[0 +: ((N_LANES < 2) ? 1 : $clog2(N_LANES))]),
        .w_addr(w_addr[0 +: ((NWORDS < 2) ? 1 : $clog2(NWORDS))]), .w_din(w_din),
        .start(start), .busy(busy), .done(done), .x(x), .y(y)
    );

    always #5 clock = ~clock;                 // same 10 ns stimulus clock as tb_fused_power

    reg [W-1:0]      xmem  [0:P_IN*NSAMP-1];
    reg [NMAC*W-1:0] wtmp  [0:NWORDS-1];
    reg [NMAC*W-1:0] wflat [0:N_LANES*NWORDS-1];
    reg [W-1:0] cks;
    integer s, i, guard, a, ln;

    initial begin
        for (ln = 0; ln < N_LANES; ln = ln + 1) begin
            $readmemh($sformatf("w_lane%0d.mem", ln), wtmp);
            for (a = 0; a < NWORDS; a = a + 1) wflat[ln*NWORDS + a] = wtmp[a];
        end
        $readmemh("xstim.mem", xmem);

        x = '0; cks = '0;
        repeat (8) @(posedge clock);
        nReset = 1'b1;
        repeat (4) @(posedge clock);

        for (i = 0; i < N_LANES; i = i + 1) begin
            w_lane = i;
            for (a = 0; a < NWORDS; a = a + 1) begin
                w_addr = a;
                w_din  = wflat[i*NWORDS + a];
                w_we   = 1'b1;
                @(posedge clock);
            end
            w_we = 1'b0;
        end
        $display("WEIGHTS_LOADED");
        repeat (4) @(posedge clock);

        for (s = 0; s < NSAMP; s = s + 1) begin
            for (i = 0; i < P_IN; i = i + 1)
                x[i*W +: W] = xmem[s*P_IN + i];
            @(posedge clock);
            start = 1'b1;
            @(posedge clock);
            start = 1'b0;
            guard = 0;
            while (done !== 1'b1) begin
                @(posedge clock);
                guard = guard + 1;
                if (guard > 200000) begin
                    $display("TB ERROR: no done on sample %0d", s);
                    $finish;
                end
            end
            for (i = 0; i < N_OUT; i = i + 1) cks = cks ^ y[i*W +: W];
            $display("sample %0d done in %0d cycles, cks=%h", s, guard, cks);
        end
        repeat (10) @(posedge clock);
        $display("TB_DONE %0d samples cks=%h", NSAMP, cks);
        $finish;
    end
endmodule
