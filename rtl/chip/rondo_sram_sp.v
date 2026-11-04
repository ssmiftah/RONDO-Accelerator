// rondo_sram_sp: behavioral single-port synchronous SRAM, registered read data.
//
// *** The ONLY module to replace with foundry memory macros (spec 7.7). ***
// Port contract: on an enabled edge the old contents of `addr` appear on q at the next
// cycle (read-first) and, if we, d is written. q holds its value when not enabled.
// Under RONDO_FAULT_INJECT the testbench may force the `fault_*` wires of this module's
// instances (stuck-at, transition and coupling faults for MBIST tests); they are not
// present in the synthesized netlist.
module rondo_sram_sp #(
    parameter DEPTH = 280,
    parameter WIDTH = 128,
    parameter AW    = (DEPTH < 2) ? 1 : $clog2(DEPTH)
) (
    input              clk,
    input              en,
    input              we,
    input  [AW-1:0]    addr,
    input  [WIDTH-1:0] d,
    output reg [WIDTH-1:0] q
);
    reg [WIDTH-1:0] mem [0:DEPTH-1];
`ifdef RONDO_FAULT_INJECT
    // fault model (set by the testbench through hierarchical force/assignment):
    //   f_sa0 / f_sa1: per-bit stuck-at masks applied at the given address
    //   f_addr: address the faults apply to; f_tf: transition-fault mask (bit cannot go 0->1)
    //   f_cpl_aggr/f_cpl_vict: a write to address f_cpl_aggr flips bit mask f_cpl_vict at f_addr
    reg [WIDTH-1:0] f_sa0, f_sa1, f_tf, f_cpl_vict;
    reg [AW-1:0]    f_addr, f_cpl_aggr;
    reg             f_en, f_cpl_en;
    initial begin f_sa0 = 0; f_sa1 = 0; f_tf = 0; f_cpl_vict = 0; f_addr = 0; f_cpl_aggr = 0; f_en = 0; f_cpl_en = 0; end
    reg [WIDTH-1:0] wv;
    always @(posedge clk) begin
        if (en) begin
            q <= mem[addr];
            if (f_en && addr == f_addr) q <= (mem[addr] & ~f_sa0) | f_sa1;
            if (we) begin
                wv = d;
                if (f_en && addr == f_addr) begin
                    wv = (wv & ~f_sa0) | f_sa1;           // stuck-at
                    wv = wv & ~(f_tf & ~mem[addr]);        // bits in f_tf cannot rise 0->1
                end
                mem[addr] <= wv;
                if (f_cpl_en && addr == f_cpl_aggr) mem[f_addr] <= mem[f_addr] ^ f_cpl_vict;
            end
        end
    end
`else
    always @(posedge clk) begin
        if (en) begin
            q <= mem[addr];
            if (we) mem[addr] <= d;
        end
    end
`endif
endmodule
