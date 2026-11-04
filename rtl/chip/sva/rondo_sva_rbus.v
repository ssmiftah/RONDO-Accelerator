// rbus interface rules (spec 8.2, 8.3). viol bits:
//  0 valid dropped before ready, 1 payload changed while waiting, 2 response without request, 3 request while a response is
//  outstanding (more than one outstanding), 4 response later than MAX_RSP cycles after acceptance, 5 access took more than
//  MAX_TOTAL cycles from valid rising to response, 6 valid high in reset
module rondo_sva_rbus #(
    parameter MAX_RSP = 10, MAX_TOTAL = 24
) (
    input clk, input rst_n,
    input req_valid, input req_ready, input req_we, input [23:0] req_addr, input [31:0] req_wdata,
    input rsp_valid, input rsp_ready,
    output reg [7:0] viol
);
    reg v_q, rdy_q, we_q; reg [23:0] a_q; reg [31:0] d_q;
    reg outstanding; reg [7:0] age, total; reg in_flight;
    wire acc = req_valid && req_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            viol <= 8'd0; v_q <= 1'b0; rdy_q <= 1'b0; we_q <= 1'b0; a_q <= 24'd0; d_q <= 32'd0;
            outstanding <= 1'b0; age <= 8'd0; total <= 8'd0; in_flight <= 1'b0;
        end else begin
            v_q <= req_valid; rdy_q <= req_ready; we_q <= req_we; a_q <= req_addr; d_q <= req_wdata;
            if (v_q && !rdy_q && !req_valid) viol[0] <= 1'b1;
            if (v_q && !rdy_q && req_valid && (req_we !== we_q || req_addr !== a_q || (req_we && req_wdata !== d_q))) viol[1] <= 1'b1;
            if (rsp_valid && !outstanding) viol[2] <= 1'b1;
            if (acc && outstanding && !rsp_valid) viol[3] <= 1'b1;
            if (acc) begin outstanding <= 1'b1; age <= 8'd0; end
            else if (outstanding) age <= age + 8'd1;
            if (rsp_valid && rsp_ready) outstanding <= acc ? 1'b1 : 1'b0;
            if (outstanding && age > MAX_RSP && !rsp_valid) viol[4] <= 1'b1;
            if (req_valid && !in_flight) begin in_flight <= 1'b1; total <= 8'd0; end
            else if (in_flight) total <= total + 8'd1;
            if (rsp_valid && rsp_ready) in_flight <= 1'b0;
            if (in_flight && total > MAX_TOTAL && !rsp_valid) viol[5] <= 1'b1;
            if (req_valid && !rst_n) viol[6] <= 1'b1;
        end
    end
endmodule
