// Register-file rules (spec 15.2). viol bits:
//  0 RO register changed by a write, 1 an ERR_STATUS bit cleared other than by W1C or soft reset, 2 CTRL read not zero,
//  3 irq pin != registered |(status & enable) one cycle later, 4 *_HI read differs from the HI captured at the preceding LO read
module rondo_sva_regs (
    input clk, input rst_n,
    input reg_re, input reg_we, input [7:0] reg_idx, input [31:0] reg_wdata, input [31:0] reg_rdata,
    input [31:0] err_status, input [15:0] err_in, input srst,
    input [31:0] irq_status_eff, input [31:0] irq_en, input irq,
    input [63:0] pair0_val, input [63:0] pair1_val,
    output reg [7:0] viol
);
    reg [31:0] err_q, wdata_q; reg we_q, srst_q; reg [7:0] idx_q; reg [15:0] set_q;
    reg [31:0] ro_val; reg ro_pend; reg [7:0] ro_idx;
    reg irq_exp;
    reg [31:0] hi_exp0; reg hi_wait0;
    wire is_ro = (reg_idx <= 8'h08);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            viol <= 8'd0; err_q <= 32'd0; wdata_q <= 32'd0; we_q <= 1'b0; srst_q <= 1'b0; idx_q <= 8'd0; set_q <= 16'd0;
            ro_pend <= 1'b0; ro_val <= 32'd0; ro_idx <= 8'd0; irq_exp <= 1'b0; hi_exp0 <= 32'd0; hi_wait0 <= 1'b0;
        end else begin
            err_q <= err_status; wdata_q <= reg_wdata; we_q <= reg_we && reg_idx == 8'h0E; srst_q <= srst; set_q <= err_in;
            // ERR_STATUS: new = (old & ~(w1c)) | set  (set pulses of the cycle before; soft reset clears)
            // a bit may only be cleared by a W1C write of 1 to it (or by a soft reset)
            if (!srst_q && !srst && ((err_q & ~err_status) & ~(we_q ? wdata_q : 32'd0)) !== 32'd0)
                viol[1] <= 1'b1;
            // RO registers (CHIP_ID .. EPS_FP32) are constants: a read after a write to them returns the same value
            if (reg_re && reg_idx == 8'h00 && reg_rdata !== 32'h524F4E44) viol[0] <= 1'b1;
            if (reg_re && reg_idx == 8'h01 && reg_rdata !== 32'h00020101) viol[0] <= 1'b1;
            if (reg_re && reg_idx == 8'h07 && reg_rdata !== 32'h00003C24) viol[0] <= 1'b1;
            if (reg_re && reg_idx == 8'h08 && reg_rdata !== 32'h3C23D70A) viol[0] <= 1'b1;
`ifndef FORMAL
            // simulation only: any RO register (CAPS/GEOM too) reads back the same value every time
            if (reg_re && is_ro) begin
                if (ro_pend && ro_idx == reg_idx && ro_val !== reg_rdata) viol[0] <= 1'b1;
                ro_val <= reg_rdata; ro_idx <= reg_idx; ro_pend <= 1'b1;
            end
`endif
            if (reg_re && reg_idx == 8'h0A && reg_rdata !== 32'd0) viol[2] <= 1'b1;
            irq_exp <= |(irq_status_eff[6:0] & irq_en[6:0]);
            if (irq !== irq_exp) viol[3] <= 1'b1;
            // 64-bit pair coherence: LO read at index 0x21 then HI read at 0x22 returns HI as of the LO read
`ifndef FORMAL
            if (reg_re && reg_idx == 8'h21) begin hi_exp0 <= pair0_val[63:32]; hi_wait0 <= 1'b1; end
            else if (reg_re && reg_idx == 8'h22 && hi_wait0) begin
                if (reg_rdata !== hi_exp0) viol[4] <= 1'b1;
                hi_wait0 <= 1'b0;
            end
`endif
        end
    end
endmodule
