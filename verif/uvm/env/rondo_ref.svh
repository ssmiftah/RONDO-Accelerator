// Transaction-level reference model (written from the spec; host/rondo_host/model.py is the readable cross-reference).
// Observe-then-predict: timing-dependent state (ACTIVE, tile OPEN, fmt) is sampled by rbus_monitor at request time (item.tag).
// Datapath results come from the C port of sim/fpmodel.py (DPI), never from the RTL or a backdoor.
class rondo_ref extends uvm_component;
  `uvm_component_utils(rondo_ref)
  uvm_analysis_imp#(rbus_item, rondo_ref) imp;
  virtual probe_if pv; rondo_geo g;
  // ---- configuration of the checks ----
  bit rg_trc_armed = 0; bit dbg = 0; bit dp_enable = 1; bit cmodel_en = 1; bit check_regs = 1; bit enabled = 1; int unsigned n_checked = 0, n_err = 0;
  string core_dir = ".";
  // ---- architectural state ----
  bit [31:0] rg [256]; bit [31:0] err_pred; bit [31:0] irq_pred; bit fmt, fmt_pend;
  bit [31:0] xb [int]; bit xb_ok [int];           // XBUF (entry*2^XW + i), width-masked at write
  bit [31:0] wsh [int]; bit wsh_ok [int];         // weight elements (lane,caddr,field) flattened key
  bit [31:0] bsh [int]; bit bsh_ok [int];
  bit [31:0] stg [int]; bit [31:0] stg_n; int stg_tag; bit stg_have;
  bit [31:0] crc; bit [63:0] infer_cnt; bit infer_known = 1; bit [31:0] cks, sr_pass, sr_done; bit cks_known = 1; bit wstale = 1;
  bit [31:0] guard_hits, naninf; bit [31:0] last_cycles; bit last_known = 0;
  bit [63:0] zq [int]; bit z_ok; bit zvalid_m;
  // weight staging (declared before first use; was duplicated further down, check round)
  bit [31:0] e_partial = 0; bit [31:0] sg_v [int]; bit sg_m [int]; int sg_n = 0; bit sg_bias; int sg_lane, sg_caddr; bit sg_have = 0;
  int sr_i; int sr_n_l; bit sr_mode;
  // ---- coverage hooks (sampled by the coverage collector) ----
  rondo_cov cov;
  function new(string n, uvm_component p); super.new(n, p); imp = new("imp", this); g = new(); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual probe_if)::get(this, "", "probe_vif", pv)) `uvm_fatal("NOVIF", "probe_vif")
    void'(uvm_config_db#(rondo_cov)::get(this, "", "cov", cov));
    do_reset();
  endfunction
  function void start_of_simulation_phase(uvm_phase phase);
    void'($value$plusargs("CORE_DIR=%s", core_dir)); dbg = $test$plusargs("REFDBG");
    void'(fpm_load_seed(8, 6, core_dir)); void'(fpm_load_seed(24, 8, core_dir)); void'(fpm_load_seed(24, 12, core_dir));
    fpm_cfg(g.W, g.P, g.D, g.L, g.NS, g.NP, g.NX);
  endfunction
  // ----------------------------------------------------------------------------------------------------------------
  function void do_reset();
    foreach (rg[i]) rg[i] = 0;
    rg[R_IRQ_EN] = 32'h7F; rg[R_ERR_MASK] = 32'hFFFFFDFF; rg[R_SR_N] = 1; rg[R_LANE_EN] = (1 << g.L) - 1;
    err_pred = 0; irq_pred = 0; fmt = 0; fmt_pend = 0; xb.delete(); xb_ok.delete(); wsh.delete(); wsh_ok.delete(); bsh.delete(); bsh_ok.delete();
    stg.delete(); stg_have = 0; stg_n = 0; sg_v.delete(); sg_m.delete(); sg_have = 0; crc = 0; infer_cnt = 0; infer_known = 1; cks = 0; sr_pass = 0; sr_done = 0; cks_known = 1; wstale = 1;
    guard_hits = 0; naninf = 0; last_cycles = 0; last_known = 0; z_ok = 0; zvalid_m = 0; sr_mode = 0; sr_i = 0;
  endfunction
  function void soft_reset();     // spec 9.6: keeps config regs, XBUF, weights, LOAD_CRC; clears counters, errors, ZBUF, checksum, staging
    rg_trc_armed = 0;
    err_pred = 0; irq_pred = 0; infer_cnt = 0; infer_known = 1; cks = 0; sr_pass = 0; sr_done = 0; cks_known = 1; guard_hits = 0; naninf = 0;
    last_cycles = 0; last_known = 0; z_ok = 0; zvalid_m = 0; sr_mode = 0; stg.delete(); stg_have = 0; stg_n = 0; sg_v.delete(); sg_m.delete(); sg_have = 0;
  endfunction
  function void fmt_switch_effects();   // spec 9.5 / 12.4
    xb.delete(); xb_ok.delete(); z_ok = 0; zvalid_m = 0; cks = 0; sr_pass = 0; last_cycles = 0; last_known = 0; crc = 0; wstale = 1; cks_known = 1;
    wsh.delete(); wsh_ok.delete(); bsh.delete(); bsh_ok.delete(); stg.delete(); stg_have = 0; sg_v.delete(); sg_m.delete(); sg_have = 0;   // weights must be reloaded (H half not valid in the other format)
  endfunction
  function int wbits(); return fmt ? 32 : 16; endfunction
  function bit [31:0] wmask(); return fmt ? 32'hFFFFFFFF : 32'h0000FFFF; endfunction
  function int unsigned xpw(); return (g.NX < 2) ? 1 : $clog2(g.NX); endfunction
  // ----------------------------------------------------------------------------------------------------------------
  function void rep_err(string what, bit [31:0] a, bit [31:0] got, bit [31:0] exp);
    n_err++; `uvm_error("REF", $sformatf("%s addr=%h got=%h expected=%h", what, a, got, exp))
  endfunction
  function bit [31:0] crc32_el(bit [31:0] c, bit [31:0] v);
    return fpm_crc32_update(c, v & wmask(), wbits() / 8);
  endfunction
  // ---- the main entry: one completed rbus access -----------------------------------------------------------------
  function void write(rbus_item it);
    bit act = it.tag[0], topen = it.tag[1], busyint = it.tag[2];
    bit [31:0] e_new = 0; bit pred_err = 0; bit known_resp = 0; bit [31:0] exp_rd = 0; bit chk_rd = 0;
    bit [23:0] a = it.addr; bit [31:0] w = it.wdata; bit fmt_before = fmt;
    if (!enabled) return;
    if (a[23:8] == 0) begin
      bit [7:0] idx = a[7:0];
      bit mapped = 0, ro = 0, off = 0;
      reg_class(idx, mapped, ro, off);
      if (!mapped && !off) begin e_new[ER_ADDR] = 1; pred_err = 1; known_resp = 1; if (!it.we) begin exp_rd = 0; chk_rd = 1; end end
      else if (it.we) begin
        known_resp = 1;
        if (off) begin e_new[ER_ADDR] = 1; pred_err = 1; end
        else if (ro && idx != R_CTRL) begin e_new[ER_RO] = 1; pred_err = 1; end
        else reg_write(idx, w, act, topen, e_new, pred_err);
      end else begin
        known_resp = 1; reg_read_check(idx, it.rdata, act, chk_rd, exp_rd);
        if (idx == R_ERR_STATUS) begin
          bit [31:0] tm = (1<<ER_BUSY_WR)|(1<<ER_ADDR)|(1<<ER_RO)|(1<<ER_START_BUSY)|(1<<ER_RANGE)|(1<<ER_TILE_SEQ);
          if ((it.rdata & tm) !== (err_pred & tm)) rep_err("ERR_STATUS(tracked bits)", a, it.rdata & tm, err_pred & tm);
          n_checked++;
        end else if (chk_rd) begin
          n_checked++; if (it.rdata !== exp_rd) rep_err($sformatf("reg %0h", idx), a, it.rdata, exp_rd);
        end
        if (idx == R_ERR_STATUS) known_resp = 1;
      end
    end else mem_access(it, act, topen, e_new, pred_err, known_resp, chk_rd, exp_rd);
    e_new |= e_partial; e_partial = 0;       // PARTIAL is an event of the staging unit: sets ERR_STATUS, not rsp_err
    if (dbg && (e_new != 0)) `uvm_info("REFDBG", $sformatf("%s -> e_new=%h pred_err=%0d act=%0d topen=%0d", it.convert2string(), e_new, pred_err, act, topen), UVM_LOW)
    err_pred |= e_new;
    if (known_resp && (it.err !== pred_err)) begin n_err++; `uvm_error("REF", $sformatf("rsp_err got=%0d expected=%0d for %s (act=%0d)", it.err, pred_err, it.convert2string(), act)) end
    if (cov != null) cov.sample_access(it, act, topen, e_new, fmt_before, fmt);
  endfunction
  // ---- register classification (matches rondo_regs: mapped / read-only / listed-but-feature-off) ------------------------
  function void reg_class(bit [7:0] idx, output bit mapped, output bit ro, output bit off);
    mapped = 0; ro = 0; off = 0;
    case (idx)
      8'h00,8'h01,8'h02,8'h03,8'h04,8'h05,8'h06,8'h07,8'h08: begin mapped = 1; ro = 1; end
      8'h09,8'h0A,8'h0C,8'h0D,8'h0E,8'h0F,8'h10,8'h11,8'h12,8'h13,8'h14,8'h15,8'h16,8'h17,8'h18,8'h19: mapped = 1;
      8'h0B: begin mapped = 1; ro = 1; end
      8'h20,8'h21,8'h22,8'h23,8'h24,8'h25,8'h26,8'h27,8'h28,8'h29,8'h2A,8'h2B,8'h2C,8'h2D,8'h2E: begin mapped = 1; ro = 1; end
      8'h30: if (g.has_dbg) mapped = 1; else off = 1;
      8'h31: if (g.has_dbg) begin mapped = 1; ro = 1; end else off = 1;
      8'h38,8'h39: if (g.has_trace) mapped = 1; else off = 1;
      8'h3A: if (g.has_trace) begin mapped = 1; ro = 1; end else off = 1;
      8'h40,8'h41,8'h42,8'h43,8'h44: if (g.has_kat || g.has_mbist) begin mapped = 1; ro = 1; end else off = 1;
      8'h48,8'h49,8'h4A: if (g.has_mbist) begin mapped = 1; ro = 1; end else off = 1;
      8'h50,8'h54: if (`C_TILE != 0) mapped = 1; else off = 1;
      8'h51,8'h52,8'h53: if (`C_TILE != 0) begin mapped = 1; ro = 1; end else off = 1;
      default: ;
    endcase
  endfunction
  function bit [31:0] caps_expected();
    bit [31:0] c = 0;
    c[0] = 1; c[1] = 1; c[4] = (g.LAYER == 0); c[3:2] = g.LAYER[1:0]; c[5] = 1; c[6] = 0; c[7] = 1; c[8] = g.has_dbg; c[9] = g.has_trace; c[10] = g.has_kat;
    c[11] = g.has_mbist; c[12] = g.has_scan; c[13] = 1; c[14] = g.has_spicrc; c[15] = g.has_clkalt; c[16] = g.has_pg; c[17] = (`C_TILE != 0);
    if (g.LAYER == 1) begin c[1] = 0; c[5] = 0; c[7] = 0; c[8] = 0; c[13] = 0; c[17] = 0; end   // KAN: no FP32/GUARD/READBACK/DBG/LANE_MASK/TILE (host/rondo_host/model.py, spec 13.24)
    return c;
  endfunction
  function void reg_read_check(bit [7:0] idx, bit [31:0] rd, bit act, output bit chk, output bit [31:0] exp);
    chk = 1; exp = 0;
    if (!check_regs) begin chk = 0; return; end
    case (idx)
      R_CHIP_ID: exp = 32'h524F4E44;
      R_VERSION: exp = `FIX_VERSION;
      R_EPS_BF16: exp = 32'h3C24;
      R_EPS_FP32: exp = 32'h3C23D70A;
      R_GEOM0: exp = {g.P[15:0], g.W[15:0]};
      R_GEOM1: exp = {8'(g.NP), 8'(g.NS), 8'(g.L), 8'(g.D)};
      R_GEOM2: exp = {8'(g.LNW), 8'(g.BAW), 8'(g.WAW), 8'(g.NX)};
      R_GEOM3: exp = {4'd2, 4'd1, 4'd8, 4'd6, 8'd5, 8'(g.ACCSIG)};
      R_SCRATCH, R_ERR_MASK, R_SR_COUNT, R_WDOG: exp = rg[idx];
      R_IRQ_EN: exp = rg[idx] & 32'h7F;
      R_FORMAT: exp = {31'd0, fmt_pend};
      R_XSEL: exp = rg[idx];
      R_SR_N: exp = rg[idx] & 32'hFF;
      R_LANE_EN: exp = rg[idx] & ((1 << g.L) - 1);
      R_CLKOUT_CFG: exp = rg[idx] & 32'hF;
      R_PWR_CTRL: exp = rg[idx] & 32'h7;
      R_SPI_CFG: exp = rg[idx] & 32'h1;
      R_DBG_SEL: exp = g.has_dbg ? (rg[idx] & 32'h3FFFFFF) : 0;
      R_CTRL: exp = 0;
      R_TILE_CFG: exp = (`C_TILE != 0) ? rg[idx] : 0;
      R_TRC_CFG, R_TRC_TRIG: exp = g.has_trace ? rg[idx] : 0;
      R_CAPS: exp = caps_expected();
      R_LOAD_CRC: begin if (act) chk = 0; else exp = crc; end
      R_INFER_LO: begin if (!infer_known) chk = 0; else exp = infer_cnt[31:0]; end
      R_CHECKSUM: begin if (!cks_known || act) chk = 0; else exp = cks; end
      R_SR_PASS: begin if (!cks_known || act) chk = 0; else exp = sr_pass; end
      R_SR_DONE: begin if (act) chk = 0; else exp = sr_done; end
      R_LAST_CYCLES: begin if (!last_known || act) chk = 0; else exp = last_cycles; end
      R_GUARD: begin if (act || !infer_known) chk = 0; else exp = guard_hits; end
      R_NANINF: begin if (act || !infer_known) chk = 0; else exp = naninf; end
      default: chk = 0;
    endcase
  endfunction
  function void reg_write(bit [7:0] idx, bit [31:0] w, bit act, bit topen, ref bit [31:0] e, ref bit perr);
    case (idx)
      R_SCRATCH: rg[idx] = w;
      R_IRQ_STATUS: irq_pred &= ~(w & 32'h7B);
      R_IRQ_EN: rg[idx] = w & 32'h7F;
      R_ERR_STATUS: err_pred &= ~w;
      R_ERR_MASK: rg[idx] = w;
      R_FORMAT: begin
        if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
        else if (g.has_tile && topen) begin e[ER_TILE_SEQ] = 1; perr = 1; end
        else if (w > 1) begin e[ER_RANGE] = 1; perr = 1; end
        else begin fmt_pend = w[0]; fmt = w[0]; fmt_switch_effects(); end
      end
      R_XSEL: if (w >= g.NX) begin e[ER_RANGE] = 1; perr = 1; end else rg[idx] = w;
      R_SR_N: if (w < 1 || w > g.NX) begin e[ER_RANGE] = 1; perr = 1; end else rg[idx] = w & 32'hFF;
      R_SR_COUNT, R_WDOG: rg[idx] = w;
      R_LANE_EN: begin
        if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
        else if (g.has_tile && topen) begin e[ER_TILE_SEQ] = 1; perr = 1; end
        else rg[idx] = w & ((1 << g.L) - 1);
      end
      R_CLK_CFG: if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
      R_CLKOUT_CFG: rg[idx] = w & 32'hF;
      R_PWR_CTRL: begin
        if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
        else if (g.has_tile && topen) begin e[ER_TILE_SEQ] = 1; perr = 1; end          // fix B1
        else rg[idx] = w & 32'h7;
      end
      R_SPI_CFG: rg[idx] = w & 1;
      R_DBG_SEL: rg[idx] = w & 32'h3FFFFFF;
      R_TRC_CFG: begin if (rg_trc_armed) begin e[ER_BUSY_WR] = 1; perr = 1; end else rg[idx] = w; end
      R_TRC_TRIG: rg[idx] = w;
      R_TILE_SLICE: begin if (!(rg[R_TILE_CFG][25] && topen) || act) begin e[ER_TILE_SEQ] = 1; perr = 1; end else rg[idx] = w & 32'hFF; end
      R_TILE_CFG: begin
        if (act || topen) begin e[ER_TILE_SEQ] = 1; perr = 1; end
        else if (w[0] && w[15:8] == 0) begin e[ER_RANGE] = 1; perr = 1; end
        else if (w[0] && (w[23:16] == 0 || (!w[24] && w[23:16] > g.TILE_B))) begin e[ER_RANGE] = 1; perr = 1; end
        else rg[idx] = {6'd0, w[25], w[24], (w[24] ? 8'd1 : w[23:16]), w[15:8], 7'd0, w[0]};
      end
      R_CTRL: ctrl_write(w, act, topen, e, perr);
      default: ;
    endcase
  endfunction
  function void ctrl_write(bit [31:0] w, bit act, bit topen, ref bit [31:0] e, ref bit perr);
    int nstart; bit hold = rg[R_PWR_CTRL][0] | rg[R_PWR_CTRL][1];
    if (w[CT_SOFT_RST]) begin soft_reset(); return; end
    if (w[CT_TRC_ARM] && g.has_trace) rg_trc_armed = 1;
    if (w[CT_CNT_CLR]) begin infer_cnt = 0; last_cycles = 0; last_known = 0; infer_known = 1; end
    if (w[CT_CKSUM_CLR]) begin cks = 0; sr_pass = 0; cks_known = 1; end
    if (w[CT_CRC_CLR]) crc = 0;
    if (w[CT_GUARD_CLR]) begin guard_hits = 0; naninf = 0; end
    if (w[CT_TILE_ABORT] && !g.has_tile) begin e[ER_ADDR] = 1; perr = 1; end
    if ((w[CT_TRC_ARM] || w[CT_TRC_FORCE]) && !g.has_trace) begin e[ER_ADDR] = 1; perr = 1; end
    if (w[CT_DBG_LATCH] && !g.has_dbg) begin e[ER_ADDR] = 1; perr = 1; end
    nstart = w[CT_START] + w[CT_SR_START] + w[CT_KAT_START] + w[CT_MBIST_START] + w[CT_TILE_RUN];
    if (nstart != 0) begin
      if (act) begin e[ER_START_BUSY] = 1; perr = 1; end
      else begin
        bit hs = 0, hsr = 0, hk = 0, hm = 0, ht = 0;
        if (nstart > 1) begin e[ER_START_BUSY] = 1; perr = 1; end
        if (w[CT_START]) hs = 1; else if (w[CT_SR_START]) hsr = 1; else if (w[CT_KAT_START]) hk = 1; else if (w[CT_MBIST_START]) hm = 1; else ht = 1;
        if ((hs || hsr) && g.has_tile && (rg[R_TILE_CFG][0] || topen)) begin e[ER_TILE_SEQ] = 1; perr = 1; hs = 0; hsr = 0; end
        if ((hk || hm) && g.has_tile && topen) begin e[ER_TILE_SEQ] = 1; perr = 1; hk = 0; hm = 0; end
        if ((hs || hsr) && hold) begin e[ER_START_BUSY] = 1; end                                // launch refused later by rondo_seq (layer held / clock off): event, the write itself succeeds
        if (hk && hold) begin e[ER_START_BUSY] = 1; perr = 1; hk = 0; end                         // fix B2
        if (hk && !g.has_kat) begin e[ER_ADDR] = 1; perr = 1; hk = 0; end
        if (hm && !g.has_mbist) begin e[ER_ADDR] = 1; perr = 1; hm = 0; end
        if (ht && !`C_TILE) begin e[ER_ADDR] = 1; perr = 1; ht = 0; end
        else if (ht && !rg[R_TILE_CFG][0]) begin e[ER_TILE_SEQ] = 1; perr = 1; ht = 0; end
        if (hk) begin kat_invalidate(); end
        if (hm) begin kat_invalidate(); end
      end
    end
  endfunction
  function void kat_invalidate();     // KAT/MBIST overwrite weights/XBUF, clear LOAD_CRC, set WSTALE; checksum untouched but counters mixed
    xb.delete(); xb_ok.delete(); wsh.delete(); wsh_ok.delete(); bsh.delete(); bsh_ok.delete(); crc = 0; wstale = 1; infer_known = 0; z_ok = 0; zvalid_m = 0;
  endfunction
  // ---- memory regions ----------------------------------------------------------------------------------------------
  function void mem_access(rbus_item it, bit act, bit topen, ref bit [31:0] e, ref bit perr, ref bit known, ref bit chk, ref bit [31:0] exp);
    bit [23:0] a = it.addr; bit [31:0] w = it.wdata;
    int key; known = 0;
    if (a[23:16] == 8'h01) begin : xb_r   // XBUF
      int ent = a[15:0] >> g.XW, i = a[15:0] & ((1 << g.XW) - 1);
      if (a[15:0] >= (g.NX << g.XW) || (ent >= g.NX)) return;           // out-of-range entries: not modelled
      key = a[15:0];
      if (it.we) begin
        known = 1;
        if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
        else begin xb[key] = w & wmask(); xb_ok[key] = 1; end
      end else begin
        known = 1;
        if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
        else if (xb_ok.exists(key)) begin chk = 1; exp = xb[key]; end
        if (chk) begin n_checked++; if (it.rdata !== exp) rep_err("XBUF readback", a, it.rdata, exp); end
      end
    end else if (a[23:16] == 8'h02) begin  // ZBUF (RO)
      int j = a[15:0];
      if (j >= g.W) return;
      known = 1;
      if (it.we) begin e[ER_RO] = 1; perr = 1; end
      else if (z_ok && zvalid_m && dp_enable) begin
        bit [31:0] ez = fpm_z(j) & wmask(); n_checked++;
        if (it.rdata !== ez) rep_err($sformatf("ZBUF[%0d] vs C model", j), a, it.rdata, ez);
      end
    end else if (a[23] == 1'b1) begin     // WEIGHT
      int unsigned off = a - WEIGHT_BASE; int lane = off >> (g.WAW + g.FW); int caddr = (off >> g.FW) & ((1 << g.WAW) - 1); int f = off & ((1 << g.FW) - 1);
      if (lane >= g.L || caddr >= g.NWORDS) return;
      known = 1;
      if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
      else if (it.we) begin
        weight_write(0, lane, caddr, f, w);
      end else begin
        key = (lane * g.NWORDS + caddr) * g.NP + f;
        if (wsh_ok.exists(key)) begin n_checked++; exp = wsh[key] & wmask(); if (it.rdata !== exp) rep_err("WEIGHT readback", a, it.rdata, exp); end
      end
    end else if (a[23:20] == 4'h1) begin  // BIAS
      int unsigned off = a - BIAS_BASE; int lane = off >> (g.BAW + g.FW); int caddr = (off >> g.FW) & ((1 << g.BAW) - 1); int f = off & ((1 << g.FW) - 1);
      if (lane >= g.L || caddr >= g.NBWORDS) return;
      known = 1;
      if (act) begin e[ER_BUSY_WR] = 1; perr = 1; end
      else if (it.we) begin
        weight_write(1, lane, caddr, f, w);
      end else begin
        key = (lane * g.NBWORDS + caddr) * g.NP + f;
        if (bsh_ok.exists(key)) begin n_checked++; exp = bsh[key] & wmask(); if (it.rdata !== exp) rep_err("BIAS readback", a, it.rdata, exp); end
      end
    end
  endfunction
  // weight/bias element write (natural ascending order only): LOAD_CRC over every accepted write, C model updated at once, WSTALE cleared
  // staging (spec 7.6): fields collect per tag {region, lane, caddr}; a tag change with fields pending -> PARTIAL and the staging is dropped;
  // the word commits when field NPAR-1 arrives; fields never written are filled with 0 and raise PARTIAL.
  function void commit_word();
    bit miss = 0;
    for (int ff = 0; ff < g.NP; ff++) begin
      int key = sg_bias ? (sg_lane * g.NBWORDS + sg_caddr) * g.NP + ff : (sg_lane * g.NWORDS + sg_caddr) * g.NP + ff;
      bit [31:0] v = sg_m.exists(ff) ? sg_v[ff] : 32'd0; if (!sg_m.exists(ff)) miss = 1;
      if (sg_bias) begin bsh[key] = v; bsh_ok[key] = 1; if (cmodel_en) fpm_set_b(sg_lane, sg_caddr, ff, v); end
      else begin wsh[key] = v; wsh_ok[key] = 1; if (cmodel_en) fpm_set_w(sg_lane, sg_caddr, ff, v); end
    end
    if (miss) e_partial[ER_PARTIAL] = 1;
    sg_v.delete(); sg_m.delete(); sg_have = 0;
  endfunction
  function void weight_write(bit is_bias, int lane, int caddr, int f, bit [31:0] w);
    bit [31:0] v = w & wmask();
    crc = crc32_el(crc, w); wstale = 0;
    if (sg_have && (sg_bias != is_bias || sg_lane != lane || sg_caddr != caddr) && sg_m.size() != 0) begin
      e_partial[ER_PARTIAL] = 1; sg_v.delete(); sg_m.delete(); sg_have = 0;
    end
    sg_bias = is_bias; sg_lane = lane; sg_caddr = caddr; sg_have = 1; sg_v[f] = v; sg_m[f] = 1;
    if (f == g.NP - 1) commit_word();
  endfunction
  // ---- datapath events from the probe ----------------------------------------------------------------------------------
  int run_entry = 0; int run_lanes = 0; bit run_fmt; bit run_selfrun; longint unsigned start_cyc, cyc_now = 0; int run_cycles = 0;
  bit [31:0] run_cks_before;
  task run_phase(uvm_phase phase);
    bit sr_prev = 0; bit prev_start = 0, prev_done = 0, prev_rst = 0; bit in_run = 0; longint unsigned s_cyc = 0;
    forever begin
      @(posedge pv.clk); cyc_now++;
      if (!pv.rst_n) begin if (prev_rst == 1) do_reset(); prev_rst = 0; in_run = 0; continue; end
      prev_rst = 1;
      if (pv.sr_running && !sr_prev) begin cks = 0; sr_pass = 0; sr_done = 0; cks_known = 1; sr_mode = 1; sr_i = 0; sr_n_l = rg[R_SR_N]; end
      sr_prev = pv.sr_running;
      if (pv.srst && !prev_start) begin /* soft reset observed through the bus write; nothing to do */ end
      if (pv.layer_start && !pv.kat_active && !pv.mbist_active) begin
        run_fmt = pv.fmt_applied; run_lanes = pv.lane_en_applied; run_selfrun = pv.sr_running; in_run = 1; s_cyc = cyc_now;
        run_entry = run_selfrun ? (sr_i % ((sr_n_l == 0) ? 1 : sr_n_l)) : rg[R_XSEL];
        if (dp_enable) compute_z();
      end else if (pv.layer_start) begin in_run = 0; infer_known = 0; end
      if (pv.layer_done && !pv.kat_active && !pv.mbist_active && in_run) begin
        run_cycles = int'(cyc_now - s_cyc) - 1; in_run = 0;
        last_cycles = run_cycles; last_known = 1; infer_cnt++; z_ok = dp_enable; zvalid_m = 1;
        if (dp_enable) begin
          int hits = 0, ni = 0;
          for (int j = 0; j < g.W; j++) begin
            int lane = j / g.NLAD; if (!((run_lanes >> lane) & 1)) continue;
            hits += fpm_hit(j);
            if (((run_fmt ? (fpm_z(j) >> 23) : (fpm_z(j) >> 7)) & 8'hFF) == 8'hFF) ni++;
          end
          guard_hits += hits; naninf += ni;
          cks = fpm_cksum_update(cks, run_fmt ? 32 : 16); cks_known = 1;
        end else cks_known = 0;
        if (run_selfrun) begin sr_i++; sr_done++; if (sr_i == sr_n_l) sr_pass = cks; end
        if (cov != null) cov.sample_run(run_fmt, run_lanes, run_selfrun, run_entry, run_cycles);
      end
      prev_start = pv.layer_start; prev_done = pv.layer_done;
    end
  endtask
  function void compute_z();
    int fm = run_fmt ? 1 : 0;
    for (int i = 0; i < g.P; i++) begin
      int key = (run_entry << g.XW) + i; bit [31:0] v = xb_ok.exists(key) ? xb[key] : 32'd0;
      fpm_set_x(i, v);
    end
    fpm_run(fm, fm ? 0 : g.ACCSIG, fm ? 8 : 6, fm ? 2 : 1, run_lanes);
  endfunction
endclass
