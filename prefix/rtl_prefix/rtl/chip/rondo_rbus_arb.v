// rondo_rbus_arb: one rbus master out of the external port (priority) and the internal
// KAT / MBIST masters (spec 8, 13.9). One outstanding access. Order of service when idle:
// external, KAT, MBIST. rb_req_int = 1 for internal masters.
module rondo_rbus_arb (
    input         clk,
    input         rst_n,
    // external master (SPI adapter)
    input         e_req_valid, output e_req_ready, input e_req_we, input [23:0] e_req_addr, input [31:0] e_req_wdata,
    output        e_rsp_valid, input e_rsp_ready, output [31:0] e_rsp_rdata, output e_rsp_err,
    // KAT master
    input         k_req_valid, output k_req_ready, input k_req_we, input [23:0] k_req_addr, input [31:0] k_req_wdata,
    output        k_rsp_valid, output [31:0] k_rsp_rdata, output k_rsp_err,
    // MBIST master
    input         m_req_valid, output m_req_ready, input m_req_we, input [23:0] m_req_addr, input [31:0] m_req_wdata,
    output        m_rsp_valid, output [31:0] m_rsp_rdata, output m_rsp_err,
    // merged master
    output        o_req_valid, input o_req_ready, output o_req_we, output [23:0] o_req_addr,
    output [31:0] o_req_wdata, output o_req_int,
    input         o_rsp_valid, output o_rsp_ready, input [31:0] o_rsp_rdata, input o_rsp_err
);
    localparam [1:0] OWN_E = 2'd0, OWN_K = 2'd1, OWN_M = 2'd2;
    localparam [1:0] A_IDLE = 2'd0, A_REQ = 2'd1, A_RSP = 2'd2;
    reg [1:0] st, own;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin st <= A_IDLE; own <= OWN_E; end
        else case (st)
            A_IDLE: begin
                if (e_req_valid) begin own <= OWN_E; st <= A_REQ; end
                else if (k_req_valid) begin own <= OWN_K; st <= A_REQ; end
                else if (m_req_valid) begin own <= OWN_M; st <= A_REQ; end
            end
            A_REQ: if (o_req_ready) st <= A_RSP;
            A_RSP: if (o_rsp_valid && o_rsp_ready) st <= A_IDLE;
            default: st <= A_IDLE;
        endcase
    end
    wire req_phase = (st == A_REQ);
    assign o_req_valid = req_phase;
    assign o_req_we    = (own == OWN_E) ? e_req_we    : (own == OWN_K) ? k_req_we    : m_req_we;
    assign o_req_addr  = (own == OWN_E) ? e_req_addr  : (own == OWN_K) ? k_req_addr  : m_req_addr;
    assign o_req_wdata = (own == OWN_E) ? e_req_wdata : (own == OWN_K) ? k_req_wdata : m_req_wdata;
    assign o_req_int   = (own != OWN_E);
    assign e_req_ready = req_phase && (own == OWN_E) && o_req_ready;
    assign k_req_ready = req_phase && (own == OWN_K) && o_req_ready;
    assign m_req_ready = req_phase && (own == OWN_M) && o_req_ready;
    wire rsp_phase = (st == A_RSP);
    assign e_rsp_valid = rsp_phase && (own == OWN_E) && o_rsp_valid;
    assign k_rsp_valid = rsp_phase && (own == OWN_K) && o_rsp_valid;
    assign m_rsp_valid = rsp_phase && (own == OWN_M) && o_rsp_valid;
    assign e_rsp_rdata = o_rsp_rdata; assign k_rsp_rdata = o_rsp_rdata; assign m_rsp_rdata = o_rsp_rdata;
    assign e_rsp_err = o_rsp_err; assign k_rsp_err = o_rsp_err; assign m_rsp_err = o_rsp_err;
    assign o_rsp_ready = rsp_phase && ((own == OWN_E) ? e_rsp_ready : 1'b1);
endmodule
