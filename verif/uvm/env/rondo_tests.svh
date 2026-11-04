`define KAT_SIG_VALID ((`C_WIDTH == 16 && `C_PDIM == 8 && `C_LANES == 2) || (`C_WIDTH == 64 && `C_PDIM == 40 && `C_LANES == 8))
`define HAS_PIN 1
// ---------------------------------------------------------------------------------------------------------------------------
class u_bringup extends rondo_base_test;
  `uvm_component_utils(u_bringup)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d; bit [31:0] pats[$] = '{32'h0, 32'hFFFFFFFF, 32'hA5A5A5A5, 32'h5A5A5A5A, 32'h12345678, 32'h80000001};
    rd(R_CHIP_ID, d); if (d !== 32'h524F4E44) `uvm_error("BRINGUP", $sformatf("CHIP_ID %h", d))
    rd(R_VERSION, d); if (d !== `FIX_VERSION) `uvm_error("BRINGUP", $sformatf("VERSION %h", d))
    rd(R_CAPS, d); rd(R_GEOM0, d); rd(R_GEOM1, d); rd(R_GEOM2, d); rd(R_EPS_BF16, d); rd(R_EPS_FP32, d);
    foreach (pats[i]) begin wr(R_SCRATCH, pats[i]); rd(R_SCRATCH, d); if (d !== pats[i]) `uvm_error("BRINGUP", $sformatf("SCRATCH %h != %h", d, pats[i])) end
`ifdef TOP_CHIP
    begin // LOOPBACK 16 random bytes, STATUS8 signature
      rondo_bus_spi sb; spi_item it = spi_item::type_id::create("lb"); spi_item st = spi_item::type_id::create("st");
      $cast(sb, bus); it.kind = SPI_LOOPBACK; for (int i = 0; i < 16; i++) it.raw.push_back($urandom); sb.frame(it);
      if (it.rx[0] !== 8'h00) `uvm_error("BRINGUP", "LOOPBACK byte 0 != 0")
      for (int i = 0; i + 1 < it.tx.size(); i++) if (it.rx[i + 1] !== it.tx[i]) `uvm_error("BRINGUP", $sformatf("LOOPBACK byte %0d: got %h exp %h", i + 1, it.rx[i + 1], it.tx[i]))
      st.kind = SPI_STATUS; repeat (3) st.words.push_back(0); sb.frame(st);
      if (st.rx[0] !== 8'h00 || st.rx[1][1:0] !== 2'b10) `uvm_error("BRINGUP", $sformatf("STATUS8 %h %h (low bits must be 10)", st.rx[0], st.rx[1]))
    end
`endif
  endtask
endclass

class u_reg_access extends rondo_base_test;
  `uvm_component_utils(u_reg_access)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [7:0] rw_list[$] = '{R_TRC_CFG, R_TRC_TRIG, R_TILE_SLICE, R_SCRATCH, R_IRQ_EN, R_ERR_MASK, R_XSEL, R_SR_N, R_SR_COUNT, R_WDOG, R_LANE_EN, R_CLKOUT_CFG, R_PWR_CTRL, R_SPI_CFG, R_DBG_SEL};
    bit [7:0] ro_list[$] = '{R_TRC_STATUS, R_TILE_STATUS, R_TILE_CRC, R_TILE_GEOM, R_ST_STATUS, R_CHIP_ID, R_VERSION, R_CAPS, R_GEOM0, R_GEOM1, R_GEOM2, R_GEOM3, R_EPS_BF16, R_EPS_FP32, R_STATUS, R_LAST_CYCLES, R_INFER_LO, R_CHECKSUM, R_LOAD_CRC, R_GUARD};
    bit [7:0] holes[$] = '{8'h1A, 8'h1F, 8'h2F, 8'h32, 8'h3B, 8'h45, 8'h55, 8'h70, 8'hFF};
    bit [31:0] d;
    // every register: reset value (first read), then random walk
    foreach (rw_list[i]) rd(rw_list[i], d);
    foreach (ro_list[i]) rd(ro_list[i], d);
    for (int k = 0; k < 400; k++) begin
      int c = $urandom_range(5);
      case (c)
        0, 1: begin bit [7:0] r = rw_list[$urandom_range(rw_list.size() - 1)]; if (r == R_PWR_CTRL) d = $urandom & 32'h3; else if (r == R_SPI_CFG) d = 0; else d = $urandom;
              if (r == R_XSEL) d = $urandom_range(g.NX + 2); if (r == R_SR_N) d = $urandom_range(g.NX + 2); wr(r, d); rd(r, d); end
        2: begin bit [7:0] r = ro_list[$urandom_range(ro_list.size() - 1)]; wr(r, $urandom); end
        3: begin bit [7:0] r = holes[$urandom_range(holes.size() - 1)]; if ($urandom_range(1)) wr(r, $urandom); else rd(r, d); end
        4: begin wr(R_ERR_STATUS, $urandom); rd(R_ERR_STATUS, d); end
        5: begin bit [7:0] r = ro_list[$urandom_range(ro_list.size() - 1)]; rd(r, d); end
      endcase
    end
    rd(R_ERR_STATUS, d);
  endtask
endclass

class u_load_crc extends rondo_base_test;
  `uvm_component_utils(u_load_crc)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d, q[$];
    for (int f = 0; f < 2; f++) begin
      set_format(f[0]); wr(R_CTRL, ctlbits(CT_CRC_CLR));
      rd(R_LOAD_CRC, d); if (d !== 0) `uvm_error("LOAD", $sformatf("LOAD_CRC after CRC_CLR = %h", d))
      load_weights(f[0]); rd(R_LOAD_CRC, d); rd(R_STATUS, d);
      if (d[7]) `uvm_error("LOAD", "WSTALE still set after a load")
      // read-back sample of lane 0 / last lane (checked by the model's shadow)
      for (int l = 0; l < g.L; l++) begin bus.read_burst(g.w_addr(l, 0, 0), 24, q); bus.read_burst(g.b_addr(l, 0, 0), 16, q); end
      write_x(0, f[0]); bus.read_burst(g.x_addr(0, 0), g.P, q);
      wr(R_CTRL, ctlbits(CT_CRC_CLR)); rd(R_LOAD_CRC, d);
    end
  endtask
endclass

class u_infer extends rondo_base_test;
  `uvm_component_utils(u_infer)
  int mode = 2;        // 0 bf16, 1 fp32, 2 both
  bit [63:0] d_64;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task one(bit f, int n_inf);
    bit [31:0] z[$], d;
    set_format(f); load_weights(f);
    for (int e = 0; e < g.NX; e++) write_x(e, f);
    for (int i = 0; i < n_inf; i++) begin
      int e = $urandom_range(g.NX - 1);
      infer(e); read_z(z); rd(R_LAST_CYCLES, d); rd(R_GUARD, d); rd(R_NANINF, d); rd(R_CHECKSUM, d); rd64(R_INFER_LO, R_INFER_HI, d_64);
      if (z.size() != g.W) `uvm_error("INFER", "short z read")
    end
    rd(R_ERR_STATUS, d);
  endtask
  task body(); if (mode != 1) one(0, 3); if (mode != 0) one(1, 3); endtask
endclass
class u_infer_bf16 extends u_infer; `uvm_component_utils(u_infer_bf16) function new(string n, uvm_component p); super.new(n, p); mode = 0; endfunction endclass
class u_infer_fp32 extends u_infer; `uvm_component_utils(u_infer_fp32) function new(string n, uvm_component p); super.new(n, p); mode = 1; endfunction endclass

class u_infer_rand extends rondo_base_test;
  `uvm_component_utils(u_infer_rand)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] z[$], d; int nrounds = 40;
    void'($value$plusargs("NROUNDS=%d", nrounds));
    for (int r = 0; r < nrounds; r++) begin
      bit f = $urandom; int wl = -6 + $urandom_range(4), wh = wl + $urandom_range(5), bl = -3 + $urandom_range(3);
      if (r == 0 || ($urandom_range(3) == 0)) begin set_format(f); load_weights(f, wl, wh, bl, bl + 1 + $urandom_range(3)); for (int e = 0; e < g.NX; e++) write_x(e, f, -4 + $urandom_range(3), $urandom_range(3)); end
      else f = pv.fmt_applied;
      infer($urandom_range(g.NX - 1)); read_z(z);
      if ($urandom_range(1)) begin rd(R_GUARD, d); rd(R_NANINF, d); rd(R_LAST_CYCLES, d); end
    end
  endtask
endclass

class u_lane_mask extends rondo_base_test;
  `uvm_component_utils(u_lane_mask)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] z[$], d; int masks[$] = '{0, (1 << `C_LANES) - 1, 1, 2, 1 << (`C_LANES - 1), $urandom & ((1 << `C_LANES) - 1)};
    for (int f = 0; f < 2; f++) begin
      set_format(f[0]); load_weights(f[0]); write_x(0, f[0]);
      foreach (masks[i]) begin wr(R_LANE_EN, masks[i]); rd(R_LANE_EN, d); infer(0); read_z(z); rd(R_STATUS, d); rd(R_GUARD, d); rd(R_NANINF, d); end
      wr(R_LANE_EN, (1 << g.L) - 1);
    end
    // LANE_EN write while ACTIVE -> BUSY_WR
    wr(R_XSEL, 0); ctrl(CT_START); wr(R_LANE_EN, 1); wait_idle(); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
  endtask
endclass

class u_selfrun extends rondo_base_test;
  `uvm_component_utils(u_selfrun)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d; bit [63:0] d64; int srn[$] = '{1, 2, 4};
    for (int f = 0; f < 2; f++) begin
      set_format(f[0]); load_weights(f[0]); for (int e = 0; e < g.NX; e++) write_x(e, f[0]);
      foreach (srn[i]) begin
        int n = srn[i]; int counts[$] = '{1, n, 3 * n + 1};
        foreach (counts[j]) begin
          wr(R_SR_N, n); wr(R_SR_COUNT, counts[j]); ctrl(CT_CNT_CLR); ctrl(CT_SR_START); wait_idle(40000);
          rd(R_SR_DONE, d); if (d !== counts[j]) `uvm_error("SR", $sformatf("SR_DONE_CNT %0d != SR_COUNT %0d", d, counts[j]))
          rd(R_CHECKSUM, d); rd(R_SR_PASS, d); rd64(R_INFER_LO, R_INFER_HI, d64); rd64(R_SR_CYC_LO, R_SR_CYC_HI, d64); rd(R_IRQ_STATUS, d);
          if (d[0]) `uvm_error("SR", "IRQ_STATUS.DONE set by self-run inferences")
          wr(R_IRQ_STATUS, 32'h7F);
        end
      end
      // SR_COUNT = 0 stopped by SR_STOP after a random time
      wr(R_SR_N, 2); wr(R_SR_COUNT, 0); ctrl(CT_SR_START); cycles(200 + $urandom_range(600)); ctrl(CT_SR_STOP); wait_idle(40000);
      rd(R_SR_DONE, d); rd(R_CHECKSUM, d);
      ctrl(CT_SR_STOP);   // SR_STOP without a self-run: no effect
      cycles(20); rd(R_ERR_STATUS, d);
    end
  endtask
endclass

class u_counters extends rondo_base_test;
  `uvm_component_utils(u_counters)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d; bit [63:0] a, b, c, e;
    set_format(0); load_weights(0); write_x(0, 0);
    ctrl(CT_CNT_CLR); rd64(R_INFER_LO, R_INFER_HI, a); if (a > 2) `uvm_error("CNT", "INFER_CNT not cleared")
    infer(0); infer(0); rd64(R_INFER_LO, R_INFER_HI, b); rd64(R_TOTAL_LO, R_TOTAL_HI, c); rd64(R_BUSY_LO, R_BUSY_HI, e);
    if (b !== a + 2) `uvm_error("CNT", $sformatf("INFER_CNT %0d after two inferences from %0d", b, a))
    rd64(R_TOTAL_LO, R_TOTAL_HI, a); if (a <= c) `uvm_error("CNT", "TOTAL_CYC not monotonic")
    ctrl(CT_CKSUM_CLR); rd(R_CHECKSUM, d); if (d !== 0) `uvm_error("CNT", "CHECKSUM not cleared")
    ctrl(CT_GUARD_CLR); rd(R_GUARD, d); rd(R_NANINF, d);
  endtask
endclass

class u_fmt_switch extends rondo_base_test;
  `uvm_component_utils(u_fmt_switch)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] z[$], d;
    for (int k = 0; k < 4; k++) begin
      bit f = (k % 2) == 0;
      set_format(f); rd(R_STATUS, d); if (d[7] !== 1'b1) `uvm_error("FMT", "WSTALE not set after FORMAT switch")
      if (d[8] !== f) `uvm_error("FMT", "STATUS.FORMAT does not follow")
      load_weights(f); write_x(0, f); infer(0); read_z(z);
      if (!bus.is_spi()) begin wr(R_XSEL, 0); ctrl(CT_START); wr(R_FORMAT, 0); wr(R_FORMAT, 1); wait_idle(); wr(R_ERR_STATUS, 32'hFFFFFFFF); rd(R_STATUS, d); end   // FORMAT writes while ACTIVE: BUSY_WR, no switch
    end
    set_format(0); set_format(0);          // same-value write still switches/clears
    rd(R_STATUS, d); if (d[7] !== 1'b1) `uvm_error("FMT", "WSTALE not set after a same-value FORMAT write")
    // FORMAT written while ACTIVE -> BUSY_WR, FORMAT = 2 -> RANGE
    load_weights(0); write_x(0, 0); wr(R_XSEL, 0); ctrl(CT_START); wr(R_FORMAT, 1); wait_idle(); rd(R_FORMAT, d); rd(R_ERR_STATUS, d);
    wr(R_ERR_STATUS, 32'hFFFFFFFF); wr(R_FORMAT, 2); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
  endtask
endclass

class u_soft_reset extends rondo_base_test;
  `uvm_component_utils(u_soft_reset)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] z[$], d; bit [63:0] d64;
    set_format(0); load_weights(0); for (int e = 0; e < g.NX; e++) write_x(e, 0);
    wr(R_SCRATCH, 32'hCAFEF00D); wr(R_XSEL, 1);
    infer(1); read_z(z); rd(R_CHECKSUM, d);
    for (int k = 0; k < 6; k++) begin
      case (k)
        0: begin ctrl(CT_SOFT_RST); end
        1: begin wr(R_XSEL, 0); ctrl(CT_START); cycles($urandom_range(40)); ctrl(CT_SOFT_RST); end
        2: begin wr(R_SR_N, 2); wr(R_SR_COUNT, 0); ctrl(CT_SR_START); cycles(100 + $urandom_range(300)); ctrl(CT_SOFT_RST); end
        3: begin ctrl(CT_SOFT_RST); end
        4: begin wr(R_XSEL, 0); ctrl(CT_START); cycles(150); ctrl(CT_SOFT_RST); end
        5: begin ctrl(CT_SOFT_RST); end
      endcase
      cycles(40); wait_idle();
      rd(R_SCRATCH, d); if (d !== 32'hCAFEF00D) `uvm_error("SRST", "SCRATCH not kept by soft reset")
      rd(R_ERR_STATUS, d); rd(R_STATUS, d); rd64(R_INFER_LO, R_INFER_HI, d64); rd(R_CHECKSUM, d);
      rd(R_LOAD_CRC, d);
      // XBUF and weights are kept: a new inference is bit-exact (checked by the model)
      infer(1); read_z(z);
    end
  endtask
endclass

// ---- KAT / power / bug scenarios -------------------------------------------------------------------------------------------
class u_kat_reg extends rondo_base_test;
  `uvm_component_utils(u_kat_reg)
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 40; endfunction
  // independent expected signature: LFSR stream (weights, biases, XBUF) -> C layer model, 2*NXBUF inferences, checksum
  function bit [31:0] kat_expected(bit f);
    int W = f ? 32 : 16; bit [31:0] s = 32'h1D872B41, cks = 0, r;
    fpm_cfg(g.W, g.P, g.D, g.L, g.NS, g.NP, g.NX);
    for (int l = 0; l < g.L; l++) for (int a = 0; a < g.NWORDS; a++) for (int fl = 0; fl < g.NP; fl++) begin s = fpm_lfsr_next(s); fpm_set_w(l, a, fl, fpm_kat_element(s, W)); end
    for (int l = 0; l < g.L; l++) for (int a = 0; a < g.NBWORDS; a++) for (int fl = 0; fl < g.NP; fl++) begin s = fpm_lfsr_next(s); fpm_set_b(l, a, fl, fpm_kat_element(s, W)); end
    for (int e = 0; e < g.NX; e++) begin
      for (int i = 0; i < g.P; i++) begin s = fpm_lfsr_next(s); end
    end
    // inputs: regenerate in order (x entries follow the biases)
    begin
      bit [31:0] s2 = 32'h1D872B41; bit [63:0] xe[int];
      for (int k = 0; k < g.L * g.NWORDS * g.NP + g.L * g.NBWORDS * g.NP; k++) s2 = fpm_lfsr_next(s2);
      for (int e = 0; e < g.NX; e++) for (int i = 0; i < g.P; i++) begin s2 = fpm_lfsr_next(s2); xe[e * g.P + i] = fpm_kat_element(s2, W); end
      for (int n = 0; n < 2 * g.NX; n++) begin
        int e = n % g.NX;
        for (int i = 0; i < g.P; i++) fpm_set_x(i, xe[e * g.P + i]);
        fpm_run(f, f ? 0 : g.ACCSIG, f ? 8 : 6, f ? 2 : 1, (1 << g.L) - 1);
        cks = fpm_cksum_update(cks, W);
      end
    end
    return cks;
  endfunction
  task body();
    bit [31:0] d, got, sigc, exp;
    for (int f = 0; f < 2; f++) begin
      set_format(f[0]); wr(R_IRQ_STATUS, 32'h7F);
      ctrl(CT_KAT_START); cycles(20); wait_idle(60000);
      rd(f ? R_KAT_GOT_F : R_KAT_GOT_B, got); rd(f ? R_KAT_SIG_F : R_KAT_SIG_B, sigc); rd(R_ST_STATUS, d); rd(R_IRQ_STATUS, d);
      exp = kat_expected(f[0]);
      if (got !== exp) `uvm_error("KAT", $sformatf("fmt %0d: KAT_GOT %h != independent model signature %h", f, got, exp))
      if (`KAT_SIG_VALID && sigc !== exp) `uvm_error("KAT", $sformatf("fmt %0d: KAT_SIG constant %h != model %h", f, sigc, exp))
      if (!d[0] && 0) `uvm_error("KAT", "")
      rd(R_ST_STATUS, d); if (!d[1] || !d[2]) `uvm_error("KAT", $sformatf("ST_STATUS %h: not done/pass", d))
      if (pins.st_pass !== 1'b1 && `HAS_PIN) `uvm_error("KAT", "st_pass pin not set after a passing KAT")
      rd(R_STATUS, d); if (d[7] !== 1'b1) `uvm_error("KAT", "WSTALE not set after KAT")
    end
  endtask
endclass

// B2: PWR_CTRL hold/clk-off then command: KAT refused with START_BUSY (fix), MBIST allowed, ACTIVE never hangs
class u_b2_kat_pwr extends rondo_base_test;
  `uvm_component_utils(u_b2_kat_pwr)
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 30; endfunction
  task body();
    bit [31:0] d, c0, c1; int pv_[$] = '{1, 2, 3};
    set_format(0); load_weights(0); write_x(0, 0);
    foreach (pv_[i]) begin
      wr(R_PWR_CTRL, pv_[i]); rd(R_PWR_CTRL, d);
      rd(R_LOAD_CRC, c0);
      ctrl(CT_KAT_START); cycles(200);
      rd(R_STATUS, d); if (d[1]) `uvm_error("B2", $sformatf("PWR_CTRL=%0d: ACTIVE still 1 200 cycles after KAT_START (hang)", pv_[i]))
      rd(R_ERR_STATUS, d); if (!d[ER_START_BUSY]) `uvm_error("B2", $sformatf("PWR_CTRL=%0d: KAT_START not refused with START_BUSY (ERR=%h)", pv_[i], d))
      wr(R_ERR_STATUS, 32'hFFFFFFFF);
      rd(R_LOAD_CRC, c1); if (c1 !== c0) `uvm_error("B2", "KAT ran (LOAD_CRC changed) although the core is held")
      ctrl(CT_START); cycles(50); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
      wait_idle(500);
`ifdef MBIST_ON
      ctrl(CT_MBIST_START); cycles(100); wait_idle(40000); rd(R_MB_STATUS, d);
`endif
      wr(R_PWR_CTRL, 0); wait_idle();
    end
  endtask
endclass

class u_tile_cfg;  endclass
class u_nop extends uvm_test;
  `uvm_component_utils(u_nop)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task run_phase(uvm_phase phase); phase.raise_objection(this); #100ns; phase.drop_objection(this); endtask
endclass
class u_nop2 extends rondo_base_test;
  `uvm_component_utils(u_nop2)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task run_phase(uvm_phase phase); phase.raise_objection(this); #100ns; phase.drop_objection(this); endtask
endclass
class u_nop3 extends uvm_test;
  `uvm_component_utils(u_nop3)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task run_phase(uvm_phase phase);
    string w; phase.raise_objection(this);
    void'($value$plusargs("WHAT=%s", w));
    `uvm_info("N3", {"start ", w}, UVM_LOW)
    if (w == "geo") begin rondo_geo g = new(); end
    if (w == "cov") begin rondo_cov c = rondo_cov::type_id::create("c"); end
    if (w == "bus") begin rondo_bus_spi b = rondo_bus_spi::type_id::create("b"); end
    if (w == "catch") begin expect_err_catcher c = new(); uvm_report_cb::add(null, c); end
    if (w == "env") begin rondo_env e = rondo_env::type_id::create("e", this); e.build_phase(phase); end
    if (w == "dpi") begin void'(fpm_load_seed(8, 6, ".")); fpm_cfg(16, 8, 7, 2, 8, 8, 4); end
    `uvm_info("N3", "done", UVM_LOW)
    phase.drop_objection(this);
  endtask
endclass

// ---- input tiling (spec 18): tiled == untiled bit-exact against the C model with PDIM' = S*PDIM ---------------------------------
class u_tile_basic extends rondo_base_test;
  `uvm_component_utils(u_tile_basic)
  int S = 3; bit keep = 0; bit b1 = 0; bit fmt_both = 1; int nb_list[$] = '{1, 2};
  bit [31:0] Wf[int]; bit [31:0] Bf[int]; bit [31:0] xs[int];     // keys: (j*D+k)*Pw + c ; j*D+k ; b*Pw + c
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 6; endfunction
  function int Pw(); return g.P * S; endfunction
  task gen_layer(bit f, int nb);
    Wf.delete(); Bf.delete(); xs.delete();
    for (int j = 0; j < g.W; j++) for (int k = 0; k < g.D; k++) begin
      Bf[j * g.D + k] = rnd_el(f, -2, 1);
      for (int c = 0; c < Pw(); c++) Wf[(j * g.D + k) * Pw() + c] = rnd_el(f, -4, -1);
    end
    for (int b = 0; b < nb; b++) for (int c = 0; c < Pw(); c++) xs[b * Pw() + c] = rnd_el(f, -3, 0);
  endtask
  task load_slice(bit f, int s);
    for (int l = 0; l < g.L; l++) begin
      bit [31:0] ws[$], bs[$]; bit [31:0] wm[int]; bit [31:0] bm[int];
      for (int j = l * g.NLAD; j < (l + 1) * g.NLAD; j++) for (int k = 0; k < g.D; k++) begin
        int ll, ca, ff;
        g.bias_loc(j, k, ll, ca, ff); bm[ca * g.NP + ff] = Bf[j * g.D + k];
        for (int c = 0; c < g.P; c++) begin g.weight_loc(j, k, c, ll, ca, ff); wm[ca * g.NP + ff] = Wf[(j * g.D + k) * Pw() + s * g.P + c]; end
      end
      for (int i = 0; i < g.NWORDS * g.NP; i++) ws.push_back(wm[i]);
      for (int i = 0; i < g.NBWORDS * g.NP; i++) bs.push_back(bm[i]);
      bus.write_burst(g.w_addr(l, 0, 0), ws); bus.write_burst(g.b_addr(l, 0, 0), bs);
    end
  endtask
  task expected_z(bit f, int nb, ref bit [63:0] ez[int]);
    int tb = f ? 8 : 6, nr = f ? 2 : 1; int saveP = g.P;
    fpm_cfg(g.W, Pw(), g.D, g.L, g.NS, g.NP, g.NX);
    for (int j = 0; j < g.W; j++) for (int k = 0; k < g.D; k++) begin
      fpm_set_b_logical(j, k, Bf[j * g.D + k]);
      for (int c = 0; c < Pw(); c++) fpm_set_w_logical(j, k, c, Wf[(j * g.D + k) * Pw() + c]);
    end
    for (int b = 0; b < nb; b++) begin
      for (int c = 0; c < Pw(); c++) fpm_set_x(c, xs[b * Pw() + c]);
      fpm_run(f, 0, tb, nr, (1 << g.L) - 1);
      for (int j = 0; j < g.W; j++) ez[b * g.W + j] = fpm_z(j);
    end
    fpm_cfg(g.W, g.P, g.D, g.L, g.NS, g.NP, g.NX);
  endtask
  task run_seq(bit f, int nb);
    bit [31:0] d, tz[$], cfgw; bit [31:0] crc_chain = 0, lc; bit [63:0] ez[int]; int mism = 0; int tbn = keep ? 1 : nb;
    bit [31:0] wm = f ? 32'hFFFFFFFF : 32'h0000FFFF;
    gen_layer(f, nb);
    cfgw = 32'd1 | (S << 8) | (tbn << 16) | (keep << 24);
    wr(R_TILE_CFG, cfgw); rd(R_TILE_CFG, d);
    for (int s = 0; s < S; s++) begin
      bit [31:0] txv[$];
      ctrl(CT_CRC_CLR); load_slice(f, s); rd(R_LOAD_CRC, lc); crc_chain = fpm_crc32_update(crc_chain, lc, 4);
      for (int b = 0; b < tbn; b++) begin txv.delete(); for (int i = 0; i < g.P; i++) txv.push_back(xs[b * Pw() + s * g.P + i]); bus.write_burst(g.tx_addr(b, 0), txv); end
      ctrl(CT_TILE_RUN); wait_idle(); rd(R_TILE_STATUS, d);
      if (s < S - 1) begin
        if (!d[0] || !d[1] || d[2]) `uvm_error("TILE", $sformatf("slice %0d: TILE_STATUS %h (expect OPEN, SLICE_DONE, !FINAL)", s, d))
        if (b1 && s == 0) begin
          bit [31:0] pw0;
          wr(R_PWR_CTRL, 1); rd(R_PWR_CTRL, pw0); rd(R_ERR_STATUS, d);
          if (pw0 !== 0) `uvm_error("B1", $sformatf("PWR_CTRL write while a tile sequence is OPEN was accepted (reads back %h)", pw0))
          if (!d[ER_TILE_SEQ]) `uvm_error("B1", $sformatf("PWR_CTRL write while OPEN did not set ERR.TILE_SEQ (ERR=%h)", d))
          wr(R_ERR_STATUS, 32'hFFFFFFFF);
          wr(R_PWR_CTRL, 0);
        end
      end else if (d[0] || !d[2]) `uvm_error("TILE", $sformatf("final slice: TILE_STATUS %h (expect !OPEN, FINAL)", d))
      wr(R_IRQ_STATUS, 32'h7F);
    end
    rd(R_TILE_CRC, d); if (!keep && d !== crc_chain) `uvm_error("TILE", $sformatf("TILE_SEQ_CRC %h != %h", d, crc_chain))
    expected_z(f, tbn, ez);
    for (int b = 0; b < tbn; b++) begin
      bus.read_burst(g.tz_addr(b, 0), g.W, tz);
      for (int j = 0; j < g.W; j++) if ((ez[b * g.W + j] & wm) !== (tz[j] & wm)) begin mism++; if (mism < 4) `uvm_error("TILE", $sformatf("fmt %0d S=%0d nb=%0d keep=%0d TZ[%0d][%0d] rtl=%h model=%h", f, S, tbn, keep, b, j, tz[j], ez[b * g.W + j])) end
    end
  endtask
  task body();
    ref_m.dp_enable = 0; ref_m.cmodel_en = 0;
    for (int f = 0; f < (fmt_both ? 2 : 1); f++) begin
      set_format(f[0]);
      foreach (nb_list[i]) begin
        if (keep || b1) begin run_seq(f[0], 1); if (!b1) run_seq(f[0], 1); end else run_seq(f[0], nb_list[i]);
      end
      begin bit [31:0] dd; bus.write(g.ps_addr(0, 0, 0, 0), 32'h1234); bus.read(g.ps_addr(0, 0, 0, 0), dd); end   // host access to the PS region when idle
    end
  endtask
  rondo_ref ref_m;
  function void start_of_simulation_phase(uvm_phase phase); super.start_of_simulation_phase(phase); ref_m = env.ref_m; endfunction
endclass
class u_tile_keep extends u_tile_basic; `uvm_component_utils(u_tile_keep) function new(string n, uvm_component p); super.new(n, p); keep = 1; endfunction endclass
class u_b1_keep_corehold extends u_tile_basic; `uvm_component_utils(u_b1_keep_corehold) function new(string n, uvm_component p); super.new(n, p); keep = 1; b1 = 1; endfunction endclass

// ---- error bits ----------------------------------------------------------------------------------------------------------------------
class u_err_all extends rondo_base_test;
  `uvm_component_utils(u_err_all)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task expect_bit(string what, int b, bit want = 1);
    bit [31:0] e, s; rd(R_ERR_STATUS, e);
    if (e[b] !== want) `uvm_error("ERR", $sformatf("%s: ERR_STATUS[%0d]=%0d expected %0d (ERR=%h)", what, b, e[b], want, e))
  endtask
  task clr(); wr(R_ERR_STATUS, 32'hFFFFFFFF); endtask
  task body();
    bit [31:0] d, s; bit [31:0] z[$];
    set_format(0); load_weights(0); write_x(0, 0); clr(); wr(R_ERR_MASK, 32'hFFFFFFFF);
    // ADDR, RO
    wr(8'h70, 1); expect_bit("hole write", ER_ADDR); clr(); rd(8'h7F, d); expect_bit("hole read", ER_ADDR); clr();
    wr(R_CHIP_ID, 0); expect_bit("RO write", ER_RO); clr();
    // RANGE
    wr(R_XSEL, g.NX); expect_bit("XSEL range", ER_RANGE); clr(); wr(R_SR_N, 0); expect_bit("SR_N range", ER_RANGE); clr(); wr(R_FORMAT, 2); expect_bit("FORMAT range", ER_RANGE); clr();
    // ERR_ANY: STATUS[31], IRQ.ERR, irq pin
    wr(R_ERR_MASK, 32'hFFFFFFFF); wr(R_IRQ_EN, 32'h7F); wr(R_CHIP_ID, 0); cycles(4); rd(R_STATUS, s);
    if (!s[31]) `uvm_error("ERR", "STATUS.ERR_ANY not set with the cause unmasked")
    rd(R_IRQ_STATUS, d); if (!d[2]) `uvm_error("ERR", "IRQ_STATUS.ERR not set")
    cycles(4); if (pins.irq !== 1'b1) `uvm_error("ERR", "irq pin not raised for an unmasked error")
    wr(R_ERR_MASK, 32'hFFFFFFFF & ~(32'h1 << ER_RO)); cycles(4); rd(R_STATUS, s); if (s[31]) `uvm_error("ERR", "masked error still in ERR_ANY")
    clr(); wr(R_ERR_MASK, 32'hFFFFFFFF); rd(R_STATUS, s); if (s[31]) `uvm_error("ERR", "ERR_ANY not cleared by W1C")
    // START_BUSY: two start bits; START while active; BUSY_WR: memory/format writes while ACTIVE
    ctrl(CT_START, CT_SR_START); wait_idle(); expect_bit("two start bits", ER_START_BUSY); clr();
    if (!bus.is_spi()) begin   // an ACTIVE window of ~100 cycles cannot be hit by a ~400-cycle SPI frame at S
    wr(R_XSEL, 0); ctrl(CT_START); ctrl(CT_START); expect_bit("START while ACTIVE", ER_START_BUSY); clr();
    bus.write(g.x_addr(0, 0), 32'h3F80); wr(R_LANE_EN, 3); expect_bit("memory/LANE_EN write while ACTIVE", ER_BUSY_WR); wait_idle(); clr(); end
    bus.read(g.w_addr(0, 0, 0), d);
    // PARTIAL: tag change with fields pending; commit with missing fields
    bus.write(g.w_addr(0, 3, 0), 32'h3C00); bus.write(g.w_addr(0, 3, 1), 32'h3C00); bus.write(g.w_addr(0, 4, 0), 32'h3C00); expect_bit("tag change with pending fields", ER_PARTIAL); clr();
    bus.write(g.w_addr(0, 5, 0), 32'h3C00); bus.write(g.w_addr(0, 5, g.NP - 1), 32'h3C00); expect_bit("commit with missing fields", ER_PARTIAL); clr();
    // WDOG: limit below the latency
    wr(R_WDOG, 20); load_weights(0); infer(0); expect_bit("watchdog", ER_WDOG); clr(); wr(R_WDOG, 0);
    // WSTALE_RUN: inference with stale weights (after FORMAT switch)
    set_format(1); clr(); infer(0); expect_bit("WSTALE_RUN", ER_WSTALE_RUN); clr();
    load_weights(1); write_x(0, 1);
    // TILE_SEQ: TILE_RUN with EN = 0
    ctrl(CT_TILE_RUN); expect_bit("TILE_RUN without TILE_CFG.EN", ER_TILE_SEQ); clr();
`ifdef TOP_CHIP
    begin // SPI_FRAME (mid-word abort), SPI_CRC (bad header CRC with CRC mode on)
      rondo_bus_spi sb; spi_item it = spi_item::type_id::create("it"); $cast(sb, bus);
      it.kind = SPI_WRITE; it.addr = {16'd0, R_SCRATCH}; it.words.push_back(32'h1); it.words.push_back(32'h2); it.abort_bit = 6 * 8 + 20; sb.frame(it);
      expect_bit("mid-word abort", ER_SPI_FRAME); clr();
      wr(R_SPI_CFG, 1); sb.cfg.crc = 1;
      it = spi_item::type_id::create("it2"); it.kind = SPI_WRITE; it.addr = {16'd0, R_SCRATCH}; it.words.push_back(32'hDEAD); it.corrupt = CR_HCRC; sb.frame(it);
      expect_bit("bad HCRC", ER_SPI_CRC); clr(); rd(R_SCRATCH, d); if (d === 32'hDEAD) `uvm_error("ERR", "write with a bad HCRC was executed")
      wr(R_SPI_CFG, 0); sb.cfg.crc = 0;
    end
`endif
    rd(R_ERR_STATUS, d);
  endtask
endclass

// ---- SPI protocol (CHIP): opcodes, burst lengths, CRC, abort -------------------------------------------------------------------------------
`ifdef TOP_CHIP
class u_spi_proto extends rondo_base_test;
  `uvm_component_utils(u_spi_proto)
  int lens[$] = '{1, 2, 3, 17, 32, 64, 256};
  rondo_bus_spi sb; int unsigned acc0;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void start_of_simulation_phase(uvm_phase phase); super.start_of_simulation_phase(phase); $cast(sb, bus); endfunction
  task chk_acc(string what, int exp);
    int got = env.ragt.mon.n_acc - acc0;
    if (got != exp) `uvm_error("SPI", $sformatf("%s: %0d rbus accesses, expected %0d", what, got, exp))
  endtask
  task frame_acc(spi_item it, string what, int exp); acc0 = env.ragt.mon.n_acc; sb.frame(it); chk_acc(what, exp); endtask
  task err_bits(output bit [31:0] e); rd(R_ERR_STATUS, e); endtask
  task body();
    bit [31:0] e, d, q[$]; spi_item it;
    // opcodes
    it = spi_item::type_id::create("st"); it.kind = SPI_STATUS; repeat (5) it.words.push_back(0); frame_acc(it, "STATUS", 0);
    if (it.rx[0] !== 8'h00 || it.rx[1][1:0] !== 2'b10) `uvm_error("SPI", "STATUS signature")
    it = spi_item::type_id::create("lb"); it.kind = SPI_LOOPBACK; for (int i = 0; i < 60; i++) it.raw.push_back($urandom); frame_acc(it, "LOOPBACK", 0);
    for (int i = 0; i + 1 < it.tx.size(); i++) if (it.rx[i + 1] !== it.tx[i]) begin `uvm_error("SPI", $sformatf("LOOPBACK byte %0d", i + 1)) break; end
    it = spi_item::type_id::create("n0"); it.kind = SPI_NOP; it.raw.push_back(8'h00); repeat (3) it.words.push_back(0); frame_acc(it, "NOP 00", 0);
    it = spi_item::type_id::create("nf"); it.kind = SPI_NOP; it.raw.push_back(8'hFF); repeat (3) it.words.push_back(0); frame_acc(it, "NOP FF", 0);
    err_bits(e); if (e[ER_SPI_FRAME] || e[ER_SPI_CRC]) `uvm_error("SPI", $sformatf("NOPs raised an SPI error (%h)", e))
    wr(R_ERR_STATUS, 32'hFFFFFFFF);
    it = spi_item::type_id::create("unk"); it.kind = SPI_NOP; it.raw.push_back(8'h77); repeat (3) it.words.push_back(0); frame_acc(it, "unknown opcode", 0);
    err_bits(e); if (!e[ER_SPI_FRAME]) `uvm_error("SPI", "unknown opcode did not raise SPI_FRAME"); wr(R_ERR_STATUS, 32'hFFFFFFFF);
    // burst lengths (WRITE then READ of the weight store), extra tail bytes return 0 and cause no access
    foreach (lens[i]) begin
      int n = lens[i]; bit [31:0] ws[$]; bit mode = $urandom_range(1);
      ws.delete(); for (int k = 0; k < n; k++) ws.push_back($urandom & 32'hFFFF);
      it = spi_item::type_id::create("bw"); it.kind = SPI_WRITE; it.addr = (n <= 32) ? g.x_addr(0, 0) : g.w_addr(0, 0, 0); it.words = ws; it.tail = (i % 3 == 0) ? 3 : 0; frame_acc(it, $sformatf("WRITE n=%0d", n), n);
      it = spi_item::type_id::create("br"); it.kind = SPI_READ; it.addr = (n <= 32) ? g.x_addr(0, 0) : g.w_addr(0, 0, 0); it.nwords_rd = n; it.tail = (i % 3 == 1) ? 3 : 0; frame_acc(it, $sformatf("READ n=%0d", n), n);
      foreach (it.rd_words[k]) if (it.rd_words[k] !== ws[k]) begin `uvm_error("SPI", $sformatf("READ n=%0d word %0d: %h != %h", n, k, it.rd_words[k], ws[k])) break; end
      if (it.tail) begin int off = it.tx.size() - it.tail; for (int k = 0; k < it.tail; k++) if (it.rx[off + k] !== 8'h00) `uvm_error("SPI", "bytes beyond the burst are not 0") end
    end
    // CRC mode: takes effect with the NEXT frame
    wr(R_SPI_CFG, 1); sb.cfg.crc = 1;
    foreach (lens[i]) if (lens[i] <= 17) begin
      int n = lens[i]; bit [31:0] ws[$]; for (int k = 0; k < n; k++) ws.push_back($urandom & 32'hFFFF);
      it = spi_item::type_id::create("cw"); it.kind = SPI_WRITE; it.addr = g.x_addr(0, 0); it.words = ws; frame_acc(it, $sformatf("CRC WRITE n=%0d", n), n);
      it = spi_item::type_id::create("cr"); it.kind = SPI_READ; it.addr = g.x_addr(0, 0); it.nwords_rd = n; frame_acc(it, $sformatf("CRC READ n=%0d", n), n);
      if (!it.rd_crc_ok) `uvm_error("SPI", "read DCRC mismatch")
      foreach (it.rd_words[k]) if (it.rd_words[k] !== ws[k]) begin `uvm_error("SPI", $sformatf("CRC READ n=%0d word %0d: %h != %h", n, k, it.rd_words[k], ws[k])) break; end
    end
    // bad header CRC: nothing executed, SPI_CRC
    it = spi_item::type_id::create("hc"); it.kind = SPI_WRITE; it.addr = g.w_addr(0, 0, 0); it.words.push_back(32'h1111); it.words.push_back(32'h2222); it.corrupt = CR_HCRC; frame_acc(it, "bad HCRC", 0);
    err_bits(e); if (!e[ER_SPI_CRC]) `uvm_error("SPI", "bad HCRC: SPI_CRC not set"); wr(R_ERR_STATUS, 32'hFFFFFFFF);
    // bad data CRC at word k: words before k executed, rest dropped
    for (int k = 0; k < 3; k++) begin
      it = spi_item::type_id::create("dc"); it.kind = SPI_WRITE; it.addr = g.w_addr(0, 0, 0); for (int w = 0; w < 4; w++) it.words.push_back($urandom & 32'hFFFF);
      it.corrupt = CR_DCRC; it.corrupt_word = k; frame_acc(it, $sformatf("bad DCRC at word %0d", k), k);
      err_bits(e); if (!e[ER_SPI_CRC]) `uvm_error("SPI", $sformatf("bad DCRC word %0d: SPI_CRC not set", k)); wr(R_ERR_STATUS, 32'hFFFFFFFF);
    end
    wr(R_SPI_CFG, 0); sb.cfg.crc = 0;
  endtask
endclass

class u_spi_abort extends u_spi_proto;
  `uvm_component_utils(u_spi_abort)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] e, d; spi_item it;
    // abort at every bit position of the header and the first words (CRC off: header = 48 bits, word = 32 bits)
    for (int bits = 1; bits <= 48 + 3 * 32; bits += (bits < 52 ? 1 : 7)) begin
      int words_done = (bits >= 48) ? (bits - 48) / 32 : 0; bit mid = (bits < 48) || (((bits - 48) % 32) != 0);
      it = spi_item::type_id::create("ab"); it.kind = SPI_WRITE; it.addr = g.w_addr(0, 0, 0); for (int w = 0; w < 3; w++) it.words.push_back($urandom & 32'hFFFF); it.abort_bit = bits;
      frame_acc(it, $sformatf("abort after %0d bits", bits), words_done);
      err_bits(e);
      if (bits % 8 != 0 || bits < 48 || ((bits - 48) % 32) != 0) begin if (!e[ER_SPI_FRAME]) `uvm_error("SPI", $sformatf("abort after %0d bits: SPI_FRAME not set", bits)) end
      else if (e[ER_SPI_FRAME]) `uvm_error("SPI", $sformatf("abort on a word boundary (%0d bits) raised SPI_FRAME", bits))
      wr(R_ERR_STATUS, 32'hFFFFFFFF);
    end
  endtask
endclass

class u_spi_r6 extends rondo_base_test;
  `uvm_component_utils(u_spi_r6)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    rondo_bus_spi sb; bit [31:0] d, q[$]; $cast(sb, bus);
    sb.cfg.allow_low_R = 1; sb.cfg.rand_R = 1; sb.cfg.R_set = '{6.0, 6.0, 7.0, 8.0};
    for (int i = 0; i < 40; i++) begin bit [31:0] v = $urandom; wr(R_SCRATCH, v); rd(R_SCRATCH, d); if (d !== v) `uvm_error("R6", $sformatf("SCRATCH %h != %h at R=6", d, v)) end
    set_format(0); load_weights(0); write_x(0, 0); infer(0); begin bit [31:0] z[$]; read_z(z); end
  endtask
endclass

class u_clk_div extends rondo_base_test;
  `uvm_component_utils(u_clk_div)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    rondo_bus_spi sb; bit [31:0] d, z[$]; $cast(sb, bus);
    set_format(0); load_weights(0); write_x(0, 0);
    for (int k = 0; k < 8; k++) begin
      int div = (k < 4) ? k : $urandom_range(3);
      wr(R_CLK_CFG, div);                                   // applied at CS rise (frame_end) when idle
      sb.cfg.core_period_ns = 2.0 * clkv.half0 * (1 << div);  // B4: lower SCLK before the next frame
      #(1500ns);                                            // switch latency of the divider (host waits)
      rd(R_CLK_CFG, d);
      if (d[17:16] !== div[1:0]) `uvm_error("CLK", $sformatf("DIV_APPLIED %0d after CLK_CFG.DIV=%0d (CLK_CFG=%h)", d[17:16], div, d))
      infer(0); read_z(z);
    end
    // CLK_CFG write while ACTIVE: BUSY_WR, unchanged (checked by the model through ERR_STATUS)
    wr(R_CLK_CFG, 0); sb.cfg.core_period_ns = 2.0 * clkv.half0; #(2000ns);
    wr(R_SR_N, 1); wr(R_SR_COUNT, 0); ctrl(CT_SR_START); cycles(100); wr(R_CLK_CFG, 3); ctrl(CT_SR_STOP); wait_idle(40000); rd(R_CLK_CFG, d);
    if (d[17:16] !== 2'd0) `uvm_error("CLK", "CLK_CFG applied while ACTIVE (self-run)")
    rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
    if (pv.clk_glitches != 0) `uvm_error("CLK", $sformatf("%0d glitches on clk_core", pv.clk_glitches))
  endtask
endclass

class u_clk_src extends rondo_base_test;
  `uvm_component_utils(u_clk_src)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    rondo_bus_spi sb; bit [31:0] d, z[$]; $cast(sb, bus);
    set_format(0); load_weights(0); write_x(0, 0);
    for (int k = 0; k < 6; k++) begin
      real ratio = 0.3 + 2.7 * real'($urandom_range(1000)) / 1000.0; int src = k % 2 == 0;
      `uvm_info("CLKSRC", $sformatf("k=%0d src=%0d ratio=%0.2f", k, src, ratio), UVM_LOW)
      if (src) clkv.half1 = clkv.half0 * ratio;                  // clk_alt period vs clk, changed only while clk_alt is not the core clock
      wr(R_CLK_CFG, (src ? 32'h10 : 32'h0));
      sb.cfg.core_period_ns = 2.0 * (src ? clkv.half1 : clkv.half0);
      #(3000ns);                                             // mux switch (6 slower-clock edges) and settle
      rd(R_CLK_CFG, d); if (d[20] !== src[0]) `uvm_error("CLK", $sformatf("SRC_APPLIED %0d expected %0d (ratio %0.2f)", d[20], src, ratio))
      infer(0); read_z(z);
    end
    wr(R_CLK_CFG, 0); sb.cfg.core_period_ns = 2.0 * clkv.half0; #(3000ns);
    if (pv.clk_glitches != 0) `uvm_error("CLK", $sformatf("%0d glitches on clk_core during source switches", pv.clk_glitches))
  endtask
endclass

class u_clkout extends rondo_base_test;
  `uvm_component_utils(u_clkout)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d; virtual spi_if sv;
    void'(uvm_config_db#(virtual spi_if)::get(this, "", "spi_vif", sv));
    for (int K = 0; K <= 5; K++) begin
      int edges = 0; int win = 8 * (K == 0 ? 8 : (1 << K)) * 2;
      wr(R_CLKOUT_CFG, K); cycles(8 * (1 << K) + 40);
      fork begin : cnt repeat (win * 4) begin @(posedge sv.core_clk); end end join_none
      begin
        int unsigned c0 = 0; bit prev = pins.clkout; int n = 0;
        repeat (win) begin @(posedge sv.core_clk); if (pins.clkout && !prev) edges++; prev = pins.clkout; n++; end
        if (K == 0) begin if (edges != 0) `uvm_error("CLKOUT", $sformatf("CLKOUT_CFG=0: %0d rising edges (must be off)", edges)) end
        else begin int expc = win / (1 << K); if (edges < expc - 1 || edges > expc + 1) `uvm_error("CLKOUT", $sformatf("K=%0d: %0d edges in %0d cycles, expected %0d", K, edges, win, expc)) end
      end
      disable cnt;
    end
  endtask
endclass
`endif

// ---- strap self-test (CHIP) --------------------------------------------------------------------------------------------------------------
class u_kat_strap extends rondo_base_test;
  `uvm_component_utils(u_kat_strap)
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 40; endfunction
  task run_phase(uvm_phase phase);
    bit [31:0] d; int n = 0; bit busy_seen = 0, was_high_throughout = 1;
    phase.raise_objection(this);
    pins.bist_en = 1'b1; pins.rst_n = 1'b0; cycles(8); pins.rst_n = 1'b1;
    // busy high from reset release through the self-test (strap sequence: [MBIST] KAT bf16, FORMAT fp32, KAT fp32, FORMAT bf16)
    cycles(30);
    while (n < 200000) begin
      @(posedge pv.clk); n++;
      if (pins.busy) busy_seen = 1; else if (busy_seen) break;
    end
    if (!busy_seen) `uvm_error("STRAP", "busy never rose with bist_en = 1")
    cycles(30);
    if (pins.st_pass !== 1'b1) `uvm_error("STRAP", "st_pass not set after the strap self-test")
    rd(R_ST_STATUS, d); if (!d[1] || !d[2]) `uvm_error("STRAP", $sformatf("ST_STATUS %h: not done/pass", d))
    rd(R_STATUS, d); if (d[8] !== 1'b0) `uvm_error("STRAP", "FORMAT not restored to bf16 after the strap sequence")
    rd(R_KAT_GOT_B, d); rd(R_KAT_GOT_F, d);
    phase.drop_objection(this);
  endtask
endclass

// ---- reset behaviour ------------------------------------------------------------------------------------------------------------------------------------
class u_reset_async extends rondo_base_test;
  `uvm_component_utils(u_reset_async)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d, z[$];
    for (int k = 0; k < 4; k++) begin
      set_format(k % 2); load_weights(k % 2); write_x(0, k % 2); wr(R_XSEL, 0);
      ctrl(CT_START); cycles($urandom_range(60));
      #($urandom_range(5000) * 1ps);
      pins.rst_n = 1'b0; #1ns;
      if (pins.irq !== 1'b0 || pins.busy !== 1'b0 || pins.st_pass !== 1'b0) `uvm_error("RST", "outputs not 0 right after an asynchronous reset assertion")
      cycles(8); pins.rst_n = 1'b1; cycles(20);
      rd(R_CHIP_ID, d); rd(R_SCRATCH, d); rd(R_STATUS, d); if (d[8] !== 1'b0) `uvm_error("RST", "FORMAT not reset to bf16")
    end
  endtask
endclass

// ---- constrained-random mix -------------------------------------------------------------------------------------------------------------------------------
class u_chip_rand extends rondo_base_test;
  `uvm_component_utils(u_chip_rand)
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 20; endfunction
  task body();
    int nops = 60; bit [31:0] d, z[$]; bit f = 0; bit loaded = 0;
    void'($value$plusargs("NOPS=%d", nops));
    set_format(0); load_weights(0); for (int e = 0; e < g.NX; e++) write_x(e, 0); loaded = 1;
    for (int i = 0; i < nops; i++) begin
      int r = $urandom_range(99);
      if (r < 20) begin infer($urandom_range(g.NX - 1)); read_z(z); end
      else if (r < 30) begin wr(R_SR_N, 1 + $urandom_range(g.NX - 1)); wr(R_SR_COUNT, 1 + $urandom_range(5)); ctrl(CT_SR_START); wait_idle(40000); rd(R_CHECKSUM, d); rd(R_SR_DONE, d); end
      else if (r < 50) begin
        bit [7:0] safe_w[$] = '{R_SCRATCH, R_IRQ_EN, R_ERR_MASK, R_SR_COUNT, R_CLKOUT_CFG, R_DBG_SEL, 8'h70, R_CHIP_ID, R_LAST_CYCLES, R_STATUS, 8'h7F};
        bit [7:0] idx = $urandom_range(8'h5F);
        if ($urandom_range(1)) begin bit [7:0] wi = safe_w[$urandom_range(safe_w.size() - 1)]; wr(wi, $urandom); end else rd(idx, d);
      end
      else if (r < 55) begin f = !f; set_format(f); load_weights(f); for (int e = 0; e < g.NX; e++) write_x(e, f); end
      else if (r < 58) begin ctrl(CT_SOFT_RST); cycles(30); wait_idle(); end
      else if (r < 68) begin write_x($urandom_range(g.NX - 1), pv.fmt_applied); end
      else if (r < 76) begin wr(R_LANE_EN, 1 + ($urandom_range((1 << g.L) - 2))); end
      else if (r < 82) begin wr(R_LANE_EN, (1 << g.L) - 1); rd(R_STATUS, d); rd(R_LAST_CYCLES, d); end
      else if (r < 90) begin rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, $urandom); end
      else begin load_weights(pv.fmt_applied); end
    end
  endtask
endclass

// ---- CAPS per build (B5) -----------------------------------------------------------------------------------------------------------------------
class u_caps extends rondo_base_test;
  `uvm_component_utils(u_caps)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d, e;
    env.ref_m.check_regs = 0;
    rd(R_CAPS, d); e = env.ref_m.caps_expected();
    if (d !== e) `uvm_error("CAPS", $sformatf("CAPS %h != formula %h (LAYER field %0d, HAS_BIAS %0d)", d, e, d[3:2], d[4]))
    if (d[3:2] !== `C_LAYER) `uvm_error("CAPS", "CAPS[3:2] != LAYER")
    if (d[4] !== (`C_LAYER == 0)) `uvm_error("CAPS", "CAPS[4] HAS_BIAS != (LAYER == 0)")
    rd(R_VERSION, d); if (d !== `FIX_VERSION) `uvm_error("CAPS", $sformatf("VERSION %h", d))
    // feature-off registers read 0 without error; unlisted ones raise ADDR
    if (!g.has_dbg) begin rd(R_DBG_DATA, d); if (d !== 0) `uvm_error("CAPS", "DBG register not 0 with DBG=0") end
    if (!g.has_kat && !g.has_mbist) begin rd(R_ST_STATUS, d); if (d !== 0) `uvm_error("CAPS", "ST_STATUS not 0 with KAT=MBIST=0") end
    if (`C_TILE == 0) begin rd(R_TILE_STATUS, d); if (d !== 0) `uvm_error("CAPS", "TILE register not 0 with TILE=0") end
    rd(R_ERR_STATUS, d);
  endtask
endclass

class u_mbist_clean extends rondo_base_test;
  `uvm_component_utils(u_mbist_clean)
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 60; endfunction
  task body();
    bit [31:0] d, st;
    ctrl(CT_MBIST_START); cycles(30); wait_idle(200000);
    rd(R_MB_STATUS, st); rd(R_MB_FADDR, d); rd(R_MB_FXOR, d); rd(R_ST_STATUS, d);
    if (!st[1] || st[2] || st[31:16] !== 0) `uvm_error("MBIST", $sformatf("clean MBIST: MBIST_STATUS %h (expect DONE, no FAIL, count 0)", st))
    if (pins.st_pass === 1'bx) `uvm_error("MBIST", "st_pass X")
    // MBIST with the core held is allowed (fix B2 keeps MBIST_START available) and completes
    wr(R_PWR_CTRL, 3); ctrl(CT_MBIST_START); cycles(30); wait_idle(200000); rd(R_MB_STATUS, st); rd(R_ERR_STATUS, d);
    if (d[ER_START_BUSY]) `uvm_error("MBIST", "MBIST_START refused with the core held")
    if (!st[1] || st[2]) `uvm_error("MBIST", $sformatf("MBIST under CORE_HOLD+CLK_OFF: MBIST_STATUS %h", st))
    wr(R_ERR_STATUS, 32'hFFFFFFFF); wr(R_PWR_CTRL, 0);
  endtask
endclass

// ---- B4: replay of the host library's frame log (verif/cocotb/b4_frames.py) at the SCLK values it used --------------------------------------------
`ifdef TOP_CHIP
class u_b4_host_replay extends rondo_base_test;
  `uvm_component_utils(u_b4_host_replay)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    string fn, kind; int fd, n = 0; int unsigned addr, data; real hz; rondo_bus_spi sb; spi_item it; string line; int code;
    if (!$value$plusargs("B4_LOG=%s", fn)) begin `uvm_fatal("B4", "+B4_LOG=<file> missing") end
    $cast(sb, bus); fd = $fopen(fn, "r");
    if (fd == 0) `uvm_fatal("B4", $sformatf("cannot open %s", fn))
    while (!$feof(fd)) begin
      line = ""; code = $fgets(line, fd); if (line.len() < 3) continue;
      it = spi_item::type_id::create("b4"); it.sclk_ns = 0.0;
      if (line[0] == "W") begin code = $sscanf(line, "W %h %h @%f", addr, data, hz); it.kind = SPI_WRITE; it.addr = addr; it.words.push_back(data); end
      else begin code = $sscanf(line, "R %h @%f", addr, hz); it.kind = SPI_READ; it.addr = addr; it.nwords_rd = 1; end
      it.sclk_ns = (1.0e9 / hz) * 0.5;       // host f_clk = 50 MHz, testbench clk = 100 MHz: same cycle counts
      it.crc = 0; it.R = 0; begin spi_one_seq s = spi_one_seq::type_id::create("s"); s.it = it; s.start(sb.seqr); end
      n++; cycles(4 * 1);
    end
    $fclose(fd); `uvm_info("B4", $sformatf("replayed %0d host frames; min measured R = %0.2f", n, env.sagt.mon.min_R), UVM_LOW)
    if (env.sagt.mon.n_low_R != 0) `uvm_error("B4", $sformatf("%0d replayed frames ran at R < 6", env.sagt.mon.n_low_R))
  endtask
endclass
`endif

// ---- every CTRL bit in idle / ACTIVE / tile-OPEN state (DEV: the ACTIVE window is hit through a long self-run) --------------------------------------------
class u_ctrl_combos extends rondo_base_test;
  `uvm_component_utils(u_ctrl_combos)
  function new(string n, uvm_component p); super.new(n, p); poll_gap = 4; endfunction
  task one_bit(int b, bit [31:0] extra = 0); wr(R_CTRL, (32'h1 << b) | extra); endtask
  task body();
    bit [31:0] d; bit [31:0] z[$];
    set_format(0); load_weights(0); for (int e = 0; e < g.NX; e++) write_x(e, 0);
    // idle: every single bit (soft reset last), start-class pairs, random combinations
    for (int b = 0; b <= 14; b++) begin
      if (b == CT_SOFT_RST || b == CT_KAT_START || b == CT_MBIST_START || b == CT_TILE_RUN || b == CT_SR_START) continue;
      one_bit(b); cycles(30); wait_idle(); if (b == CT_TRC_ARM || b == CT_TRC_FORCE) begin ctrl(CT_SOFT_RST); cycles(30); wait_idle(); end
      rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
    end
    wr(R_SR_N, 2); wr(R_SR_COUNT, 3); one_bit(CT_SR_START); wait_idle(40000); rd(R_SR_DONE, d);
    wr(R_ERR_STATUS, 32'hFFFFFFFF);
    repeat (4) begin wr(R_CTRL, (1 << CT_START) | (1 << CT_SR_START)); cycles(20); wait_idle(); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF); end
    // ACTIVE window: long self-run, then each bit while running
    if (!bus.is_spi()) begin
      wr(R_SR_N, 2); wr(R_SR_COUNT, 0); one_bit(CT_SR_START); cycles(60);
      for (int b = 0; b <= 14; b++) begin
        if (b == CT_SOFT_RST || b == CT_SR_STOP) continue;
        one_bit(b); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
        if (b == CT_TRC_ARM) begin end
      end
      wr(R_CTRL, (1 << CT_START) | (1 << CT_SR_START)); wr(R_ERR_STATUS, 32'hFFFFFFFF);
      one_bit(CT_SR_STOP); wait_idle(40000);
      wr(R_CTRL, (1 << CT_START) | (1 << CT_KAT_START)); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
      ctrl(CT_SOFT_RST); cycles(30); wait_idle();
    end
    // tile OPEN: configure a 2-slice sequence, run slice 0, write every bit with the sequence open
    if (g.has_tile) begin
      wr(R_TILE_CFG, 32'd1 | (2 << 8) | (1 << 16) | (1 << 24));
      for (int i = 0; i < g.P; i++) bus.write(g.tx_addr(0, i), rnd_el(0, -3, 0));
      one_bit(CT_TILE_RUN); wait_idle();
      for (int b = 0; b <= 14; b++) begin
        if (b == CT_TILE_RUN || b == CT_TILE_ABORT || b == CT_SOFT_RST) continue;
        one_bit(b); cycles(20); wait_idle(); rd(R_ERR_STATUS, d); wr(R_ERR_STATUS, 32'hFFFFFFFF);
        if (b == CT_TRC_ARM || b == CT_TRC_FORCE) begin end
      end
      wr(R_CTRL, (1 << CT_START) | (1 << CT_SR_START)); wr(R_ERR_STATUS, 32'hFFFFFFFF);
      ctrl(CT_SOFT_RST); cycles(30); wait_idle(); rd(R_TILE_STATUS, d);      // soft reset with the sequence open closes it
      one_bit(CT_TILE_RUN); wait_idle(); one_bit(CT_TILE_ABORT); cycles(10); wait_idle(); rd(R_TILE_STATUS, d);
      // PS region: host access when idle
      bus.write(g.ps_addr(0, 0, 0, 0), 32'h1234); bus.read(g.ps_addr(0, 0, 0, 0), d);
      ctrl(CT_SOFT_RST); cycles(30); wait_idle();
    end
    rd(R_ERR_STATUS, d);
  endtask
endclass

// ---- negative check of the scoreboards: a deliberately wrong expectation must be reported (the REF error is demoted to INFO by the catcher) ----------------
class u_neg_ref extends rondo_base_test;
  `uvm_component_utils(u_neg_ref)
  function new(string n, uvm_component p); super.new(n, p); endfunction
  task body();
    bit [31:0] d;
    wr(R_SCRATCH, 32'h1234); catcher.id_match = "REF"; catcher.active = 1; catcher.n = 0;
    env.ref_m.rg[R_SCRATCH] = 32'h4321;                    // corrupt the model
    rd(R_SCRATCH, d); cycles(5);
    catcher.active = 0;
    if (catcher.n != 1) `uvm_error("NEG", $sformatf("scoreboard reported %0d errors for a deliberately wrong expectation (expected exactly 1)", catcher.n))
    else `uvm_info("NEG", "negative check OK: wrong expectation detected by rondo_ref", UVM_LOW)
    // protocol checker negative: none available without RTL change; reg error path above is the scoreboard check
  endtask
endclass
