// Interfaces (standard SystemVerilog, tool-neutral).
interface rbus_if (input logic clk);
  logic        rst_n;
  logic        req_valid, req_ready, req_we;
  logic [23:0] req_addr;
  logic [31:0] req_wdata;
  logic        rsp_valid, rsp_ready, rsp_err;
  logic [31:0] rsp_rdata;
  clocking cb @(posedge clk);
    default input #1step output #1;
    output req_valid, req_we, req_addr, req_wdata, rsp_ready;
    input  req_ready, rsp_valid, rsp_rdata, rsp_err;
  endclocking
  clocking mcb @(posedge clk);
    default input #1step;
    input req_valid, req_ready, req_we, req_addr, req_wdata, rsp_valid, rsp_ready, rsp_rdata, rsp_err;
  endclocking
endinterface

interface spi_if (input logic core_clk);
  logic sclk = 1'b0, cs_n = 1'b1, mosi = 1'b0, miso, miso_oe;
endinterface

interface pins_if (input logic dummy);
  logic rst_n, bist_en, test_mode_pin, irq, busy, st_pass, clkout; logic [1:0] pg_req;
endinterface

// observation of internal events of rondo_dev (all signals driven by continuous assigns in the testbench top)
interface probe_if (input logic clk);
  logic sr_running, sr_stopping, zvalid, wstale_dummy;
  logic rst_n, active, layer_start, layer_busy, layer_done, zcap, fmt_applied, tile_open, srst, frame_end, seq_active, kat_active, mbist_active;
  logic [3:0] n_lane_en;      // lane_en_applied (low bits)
  logic [31:0] lane_en_applied, last_cycles_hw, guard_hits_hw, status8;
  logic o_req_valid, o_req_ready, o_req_we, o_req_int; logic [23:0] o_req_addr; logic [31:0] o_req_wdata;
  int unsigned clk_glitches = 0; logic clk_alt_dummy; logic [39:0] sva_viol;
endinterface

interface clk_if (input logic dummy);
  real half0 = 5.0;      // ns, clk
  real half1 = 7.3;      // ns, clk_alt
  bit  run1 = 1'b1;      // clk_alt running
endinterface
