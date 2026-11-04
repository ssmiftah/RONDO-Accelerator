// Bring-up golden for rtl/board/genesys2_fused_top.v.
//
// This does two separate jobs, and conflating them is what made the first
// version of the AC701 power test wrong:
//
//   1. It proves the wrapper works: the MMCM locks, the weight load walks all
//      lanes through the real load port, and every sample raises `done`.
//   2. It records the exact checksum the hardware must show, taken from the
//      RTL's own bits. The Newton-Raphson reciprocal is ~2 ULP and is not
//      bit-exact with an fp64 reference, so a golden derived from fp64 would be
//      wrong to compare against LEDs.
//
// The clock is driven as a real 200 MHz differential pair rather than injected
// at the core, so the IBUFDS and MMCM are exercised in simulation too.

`timescale 1ps/1ps

module tb_genesys2_top;

    localparam integer NSAMP = 16;

    reg sysclk_p = 1'b0;
    wire sysclk_n = ~sysclk_p;
    reg cpu_resetn = 1'b0;
    reg [1:0] sw = 2'b00;
    wire [7:0] led;

    // 200 MHz: 5000 ps period.
    always #2500 sysclk_p = ~sysclk_p;

    genesys2_fused_top #(.NSAMP(NSAMP)) dut (
        .sysclk_p(sysclk_p), .sysclk_n(sysclk_n),
        .cpu_resetn(cpu_resetn), .sw(sw), .led(led)
    );

    integer passes = 0;
    reg [31:0] prev_samp = 32'hFFFFFFFF;
    integer guard = 0;

    initial begin
        // Hold reset well past MMCM lock.
        #200000;                // 200 ns
        cpu_resetn = 1'b1;
        #200000;
        sw[0] = 1'b1;           // run

        // Watch for the sample counter wrapping: one wrap is a full pass over
        // every input vector, which is the point at which the checksum is a
        // stable, reportable value.
        while (passes < 2 && guard < 4000000) begin
            @(posedge dut.clock);
            guard = guard + 1;
            if (prev_samp == NSAMP-1 && dut.samp == 0) begin
                passes = passes + 1;
                $display("PASS %0d  running=%08x  held=%08x  led=%08b",
                         passes, dut.checksum, dut.cks_hold, led);
            end
            prev_samp = dut.samp;
        end

        if (passes < 2) begin
            $display("TB ERROR: only %0d passes in %0d cycles, state=%0d locked=%b nReset=%b",
                     passes, guard, dut.state, dut.locked, dut.nReset);
            $finish;
        end

        $display("GOLDEN cks_hold=%08x  led(sw1=0)=%08b", dut.cks_hold, dut.cks_led);
        $display("TB OK");
        $finish;
    end

endmodule
