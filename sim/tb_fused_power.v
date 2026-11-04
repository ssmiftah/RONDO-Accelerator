// Power testbench for the complete layer (fused_coproc_pipe).
//
// Drives back-to-back inferences with realistic weights and inputs so xsim can
// record switching activity into a SAIF. This is the first power measurement of
// the *whole* layer -- every earlier one covered the ladder engine only, which is
// now the smaller half of the design.
//
// Weights go in through the real load port, not by hierarchical $readmemh: after
// synthesis the affine bank's arrays are BRAM primitives and those hierarchical
// names no longer exist in the netlist this must run on.
//
// The SAIF is opened only after loading finishes (see run_saif.tcl), so the
// recorded activity is inference, not weight load. In deployment the weights are
// already resident; charging their load to the power figure would measure the
// wrong thing.

`timescale 1ns/1ps

module tb_fused_power;
    parameter W       = 32;
    parameter DEPTH   = 7;
    parameter WIDTH   = 16;
    parameter PDIM    = 40;
    parameter N_LANES = 2;
    parameter NSLOT   = 8;
    parameter NPAR    = 8;
    parameter NSAMP   = 24;

    reg  clock = 1'b0;
    reg  nReset = 1'b0;
    reg  start = 1'b0;
    wire busy, done;
    reg  [PDIM*W-1:0] x;
    wire [WIDTH*W-1:0] z;

    localparam integer NLAD     = WIDTH / N_LANES;
    localparam integer NCH      = NSLOT * DEPTH;
    localparam integer NGROUP   = NCH / NPAR;
    localparam integer NBATCHES = NLAD / NSLOT;
    localparam integer NWORDS   = NBATCHES * NGROUP * PDIM;
    localparam integer NBWORDS  = NBATCHES * NGROUP;

    reg                  w_we = 1'b0, b_we = 1'b0;
    reg [31:0]           w_lane = 0, w_addr = 0, b_addr = 0;
    reg [NPAR*W-1:0]     w_din = 0, b_din = 0;

    // The post-synthesis netlist has no parameters -- they are baked in -- so the
    // override list must be omitted there. Build the netlist run with -d NETLIST.
`ifdef NETLIST
    fused_coproc_pipe dut (
`else
    fused_coproc_pipe #(.DEPTH(DEPTH), .WIDTH(WIDTH), .PDIM(PDIM),
                        .N_LANES(N_LANES), .NSLOT(NSLOT), .NPAR(NPAR)) dut (
`endif
        .clock(clock), .nReset(nReset),
        .w_we(w_we), .w_lane(w_lane[0 +: ((N_LANES < 2) ? 1 : $clog2(N_LANES))]),
        .w_addr(w_addr[0 +: ((NWORDS < 2) ? 1 : $clog2(NWORDS))]), .w_din(w_din),
        .b_we(b_we), .b_addr(b_addr[0 +: ((NBWORDS < 2) ? 1 : $clog2(NBWORDS))]),
        .b_din(b_din),
        .start(start), .busy(busy), .done(done), .x(x), .z(z)
    );

    always #5 clock = ~clock;                 // 10 ns -> 100 MHz

    reg [31:0]       xmem [0:PDIM*NSAMP-1];
    // One image per lane. Loading lane 1's weights into every lane above 1,
    // as an earlier version did, leaves most of the array computing on the
    // wrong coefficients.
    //
    // Flat, not [lane][word]: xsim does not honour $readmemh into a slice of
    // a two-dimensional unpacked array. It warns "Too many words specified"
    // and loads almost nothing, which still yields non-zero outputs and so
    // survives a checksum test. Read each lane into a 1-D temporary and copy.
    reg [NPAR*W-1:0] wtmp  [0:NWORDS-1];
    reg [NPAR*W-1:0] btmp  [0:NBWORDS-1];
    reg [NPAR*W-1:0] wflat [0:N_LANES*NWORDS-1];
    reg [NPAR*W-1:0] bflat [0:N_LANES*NBWORDS-1];
    reg [31:0] cks;
    integer s, i, guard, a, ln;

    initial begin
        for (ln = 0; ln < N_LANES; ln = ln + 1) begin
            $readmemh($sformatf("w_lane%0d.mem", ln), wtmp);
            $readmemh($sformatf("b_lane%0d.mem", ln), btmp);
            for (a = 0; a < NWORDS;  a = a + 1) wflat[ln*NWORDS  + a] = wtmp[a];
            for (a = 0; a < NBWORDS; a = a + 1) bflat[ln*NBWORDS + a] = btmp[a];
        end
        $readmemh("xstim.mem", xmem);

        x = '0; cks = 32'd0;
        repeat (8) @(posedge clock);
        nReset = 1'b1;
        repeat (4) @(posedge clock);

        // ---- load resident weights through the real port ----------------
        for (i = 0; i < N_LANES; i = i + 1) begin
            w_lane = i;
            for (a = 0; a < NWORDS; a = a + 1) begin
                w_addr = a;
                w_din  = wflat[i*NWORDS + a];
                w_we   = 1'b1;
                @(posedge clock);
            end
            w_we = 1'b0;
            for (a = 0; a < NBWORDS; a = a + 1) begin
                b_addr = a;
                b_din  = bflat[i*NBWORDS + a];
                b_we   = 1'b1;
                @(posedge clock);
            end
            b_we = 1'b0;
        end
        $display("WEIGHTS_LOADED");
        repeat (4) @(posedge clock);

        for (s = 0; s < NSAMP; s = s + 1) begin
            for (i = 0; i < PDIM; i = i + 1)
                x[i*W +: W] = xmem[s*PDIM + i];
            @(posedge clock);
            start = 1'b1;
            @(posedge clock);
            start = 1'b0;
            guard = 0;
            while (done !== 1'b1) begin
                @(posedge clock);
                guard = guard + 1;
                if (guard > 100000) begin
                    $display("TB ERROR: no done on sample %0d", s);
                    $finish;
                end
            end
            for (i = 0; i < WIDTH; i = i + 1) cks = cks ^ z[i*W +: W];
            $display("sample %0d done in %0d cycles, cks=%h", s, guard, cks);
        end
        repeat (10) @(posedge clock);
        $display("TB_DONE %0d samples cks=%h", NSAMP, cks);
        $finish;
    end
endmodule
