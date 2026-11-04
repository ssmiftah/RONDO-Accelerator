// SPI agent: mode 0, MSB first, SCLK from a time base (ns) derived from the divided core clock; R = core cycles per SCLK period.
function automatic bit [7:0] spi_crc8(bit [7:0] c, bit [7:0] d);
  bit [7:0] r = c ^ d;
  for (int i = 0; i < 8; i++) r = r[7] ? ((r << 1) ^ 8'h07) : (r << 1);
  return r;
endfunction

typedef enum {SPI_WRITE, SPI_READ, SPI_STATUS, SPI_LOOPBACK, SPI_NOP, SPI_RAW} spi_kind_e;
typedef enum {CR_NONE, CR_HCRC, CR_DCRC} spi_corrupt_e;

class spi_cfg extends uvm_object;
  `uvm_object_utils(spi_cfg)
  real core_period_ns = 10.0;       // current f_core period (updated by sequences after CLK_CFG)
  real R = 8.0;                      // SCLK period in core cycles
  bit  crc = 0;                      // CRC mode of the NEXT frame (sequences keep this equal to SPI_CFG)
  bit  rand_R = 1; real R_set[$] = '{8.0, 9.0, 12.0, 13.0, 16.0, 33.0};
  int  cs_setup = 3;                 // SCLK-half-periods between CS fall and first SCLK rise (min 1)
  bit  allow_low_R = 0;              // R < 8 allowed (R = 6 corner test)
  function new(string n = "spi_cfg"); super.new(n); endfunction
endclass

class spi_item extends uvm_sequence_item;
  spi_kind_e kind = SPI_RAW; bit [23:0] addr; bit [31:0] words[$]; int unsigned nwords_rd; bit crc; spi_corrupt_e corrupt = CR_NONE; int corrupt_word = 0;
  int abort_bit = -1;          // CS rises after this many SCLK rising edges (-1: complete frame)
  int tail = 0;                // extra bytes after the burst
  bit [7:0] raw[$]; bit [7:0] opcode_override; bit use_opcode; real R;
  bit [7:0] tx[$], rx[$]; int hdr_len, data_off; bit [31:0] rd_words[$]; bit rd_crc_ok = 1;
  bit [7:0] st8; real sclk_ns = 0.0;      // > 0: SCLK period in ns, overrides R (host replay)
  `uvm_object_utils(spi_item)
  function new(string name = "spi_item"); super.new(name); endfunction
  function void build();
    tx.delete();
    case (kind)
      SPI_WRITE, SPI_READ: begin
        int n = (kind == SPI_WRITE) ? words.size() : nwords_rd; bit [7:0] h[6];
        bit [7:0] op = use_opcode ? opcode_override : ((kind == SPI_WRITE) ? 8'h02 : 8'h03);
        h = '{op, addr[23:16], addr[15:8], addr[7:0], 8'((n - 1) >> 8), 8'((n - 1) & 255)};
        foreach (h[i]) tx.push_back(h[i]);
        if (crc) begin bit [7:0] c = 0; foreach (h[i]) c = spi_crc8(c, h[i]); if (corrupt == CR_HCRC) c ^= 8'h5A; tx.push_back(c); end
        hdr_len = tx.size();
        if (kind == SPI_WRITE) begin
          foreach (words[i]) begin
            bit [7:0] c = 0;
            for (int b = 3; b >= 0; b--) begin tx.push_back(words[i][8*b +: 8]); c = spi_crc8(c, words[i][8*b +: 8]); end
            if (crc) begin if (corrupt == CR_DCRC && i == corrupt_word) c ^= 8'hA5; tx.push_back(c); end
          end
        end else begin
          tx.push_back(8'h00); data_off = tx.size();                       // dummy byte
          for (int i = 0; i < n * (crc ? 5 : 4); i++) tx.push_back(8'h00);
        end
        repeat (tail) tx.push_back(8'h00);
      end
      SPI_STATUS: begin tx.push_back(8'h05); repeat (words.size() + 1) tx.push_back(8'h00); end
      SPI_LOOPBACK: begin tx.push_back(8'h0E); foreach (raw[i]) tx.push_back(raw[i]); end
      SPI_NOP: begin tx.push_back(raw.size() ? raw[0] : 8'h00); repeat (words.size()) tx.push_back(8'h00); end
      SPI_RAW: tx = raw;
    endcase
  endfunction
  function void parse_rx();
    rd_words.delete(); rd_crc_ok = 1;
    if (kind == SPI_READ) begin
      int p = data_off; int n = nwords_rd;
      for (int i = 0; i < n; i++) begin
        bit [31:0] w = 0; bit [7:0] c = 0;
        if (p + 3 >= rx.size()) break;
        for (int b = 0; b < 4; b++) begin w = {w[23:0], rx[p + b]}; c = spi_crc8(c, rx[p + b]); end
        p += 4;
        if (crc) begin if (p >= rx.size() || rx[p] != c) rd_crc_ok = 0; p++; end
        rd_words.push_back(w);
      end
    end
  endfunction
endclass

class spi_txn extends uvm_sequence_item;
  bit [7:0] mosi[$], miso[$]; int nbits; real r_meas; bit complete; longint unsigned t_start;
  `uvm_object_utils(spi_txn)
  function new(string n = "spi_txn"); super.new(n); endfunction
endclass

class spi_driver extends uvm_driver#(spi_item);
  `uvm_component_utils(spi_driver)
  virtual spi_if vif; spi_cfg cfg;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual spi_if)::get(this, "", "spi_vif", vif)) `uvm_fatal("NOVIF", "spi_vif")
    if (!uvm_config_db#(spi_cfg)::get(this, "", "spi_cfg", cfg)) cfg = spi_cfg::type_id::create("cfg");
  endfunction
  task run_phase(uvm_phase phase);
    vif.sclk = 1'b0; vif.cs_n = 1'b1; vif.mosi = 1'b0;
    forever begin seq_item_port.get_next_item(req); drive(req); seq_item_port.item_done(); end
  endtask
  task drive(spi_item it);
    real R = it.R; real half; int nbits_total; int sent = 0; bit stop = 0;
    if (R <= 0) R = cfg.rand_R ? cfg.R_set[$urandom_range(cfg.R_set.size() - 1)] : cfg.R;
    if (R < 8.0 && !cfg.allow_low_R) R = 8.0;
    half = (it.sclk_ns > 0.0) ? it.sclk_ns / 2.0 : R * cfg.core_period_ns / 2.0;
    it.R = R; it.build(); it.rx.delete();
    nbits_total = it.tx.size() * 8;
    #(half * 0.37 * $urandom_range(3));          // random phase relative to the core clock
    vif.cs_n = 1'b0; #(half * cfg.cs_setup);
    for (int bi = 0; bi < nbits_total && !stop; bi++) begin
      bit [7:0] b = it.tx[bi / 8]; bit mb; int pos = 7 - (bi % 8);
      vif.mosi = b[pos];
      #(half);
      vif.sclk = 1'b1;
      #(0.01); mb = vif.miso;
      if (bi % 8 == 0) it.rx.push_back(8'h00);
      it.rx[bi / 8][pos] = mb;
      sent++;
      if (it.abort_bit >= 0 && sent >= it.abort_bit) begin stop = 1; end
      #(half);
      vif.sclk = 1'b0;
    end
    #(half * 2);
    vif.cs_n = 1'b1; vif.mosi = 1'b0;
    #(half * 4);
    it.parse_rx();
  endtask
endclass

class spi_monitor extends uvm_monitor;
  `uvm_component_utils(spi_monitor)
  virtual spi_if vif; virtual probe_if pv; uvm_analysis_port#(spi_txn) ap; int unsigned n_low_R = 0, n_warn_R = 0; real min_R = 1e9;
  function new(string n, uvm_component p); super.new(n, p); ap = new("ap", this); endfunction
  function void build_phase(uvm_phase phase);
    if (!uvm_config_db#(virtual spi_if)::get(this, "", "spi_vif", vif)) `uvm_fatal("NOVIF", "spi_vif")
  endfunction
  longint unsigned core_cycles = 0;
  task count_cycles(); forever begin @(posedge vif.core_clk); core_cycles++; end endtask
  task run_phase(uvm_phase phase);
    fork count_cycles(); join_none
    forever begin
      spi_txn t; bit [7:0] cm = 0, cs = 0; int nb = 0; longint unsigned first_rise = 0, last_rise = 0; int nrise = 0;
      @(negedge vif.cs_n);
      t = spi_txn::type_id::create("t");
      while (!vif.cs_n) begin
        @(vif.sclk or vif.cs_n);
        if (vif.cs_n) break;
        if (vif.sclk) begin
          cm = {cm[6:0], vif.mosi}; cs = {cs[6:0], vif.miso}; nb++; nrise++;
          if (nrise == 1) first_rise = core_cycles; last_rise = core_cycles;
          if (nb % 8 == 0) begin t.mosi.push_back(cm); t.miso.push_back(cs); end
        end
      end
      t.nbits = nb; t.complete = (nb % 8 == 0);
      if (nrise > 2) begin
        t.r_meas = real'(last_rise - first_rise) / real'(nrise - 1);
        if (t.r_meas < min_R) min_R = t.r_meas;
        if (t.r_meas < 5.5) begin n_low_R++; `uvm_error("SPI_MON", $sformatf("SCLK period %0.2f core cycles (R < 6): not a legal link rate", t.r_meas)) end
        else if (t.r_meas < 7.5) begin n_warn_R++; `uvm_warning("SPI_MON", $sformatf("SCLK period %0.2f core cycles (R < 8 is below the normative minimum)", t.r_meas)) end
      end
      ap.write(t);
    end
  endtask
endclass

typedef uvm_sequencer#(spi_item) spi_sequencer;
class spi_agent extends uvm_agent;
  `uvm_component_utils(spi_agent)
  spi_driver drv; spi_sequencer seqr; spi_monitor mon;
  function new(string n, uvm_component p); super.new(n, p); endfunction
  function void build_phase(uvm_phase phase);
    mon = spi_monitor::type_id::create("mon", this);
    drv = spi_driver::type_id::create("drv", this); seqr = spi_sequencer::type_id::create("seqr", this);
  endfunction
  function void connect_phase(uvm_phase phase); drv.seq_item_port.connect(seqr.seq_item_export); endfunction
endclass

class spi_one_seq extends uvm_sequence#(spi_item);
  `uvm_object_utils(spi_one_seq)
  spi_item it;
  function new(string n = "spi_one_seq"); super.new(n); endfunction
  task body(); start_item(it); finish_item(it); endtask
endclass

class rondo_bus_spi extends rondo_bus;
  `uvm_object_utils(rondo_bus_spi)
  spi_sequencer seqr; spi_cfg cfg; int unsigned max_words = 255; int unsigned n_frames = 0; bit rd_crc_ok = 1;
  function new(string name = "rondo_bus_spi"); super.new(name); endfunction
  function bit is_spi(); return 1; endfunction
  task frame(spi_item it);
    spi_one_seq s = spi_one_seq::type_id::create("s"); it.crc = cfg.crc; it.R = 0; s.it = it; s.start(seqr); n_frames++;
  endtask
  task write(bit [23:0] a, bit [31:0] d); bit [31:0] q[$]; q.push_back(d); write_burst(a, q); endtask
  task read(bit [23:0] a, output bit [31:0] d); bit [31:0] q[$]; read_burst(a, 1, q); d = q[0]; endtask
  task write_burst(bit [23:0] a, ref bit [31:0] d[$]);
    int p = 0;
    while (p < d.size()) begin
      spi_item it = spi_item::type_id::create("it"); int n = d.size() - p; if (n > max_words) n = max_words;
      it.kind = SPI_WRITE; it.addr = a + p; for (int i = 0; i < n; i++) it.words.push_back(d[p + i]);
      frame(it); p += n;
    end
  endtask
  task read_burst(bit [23:0] a, int n, ref bit [31:0] d[$]);
    int p = 0; d.delete();
    while (p < n) begin
      spi_item it = spi_item::type_id::create("it"); int m = n - p; if (m > max_words) m = max_words;
      it.kind = SPI_READ; it.addr = a + p; it.nwords_rd = m; frame(it);
      if (!it.rd_crc_ok) rd_crc_ok = 0;
      foreach (it.rd_words[i]) d.push_back(it.rd_words[i]);
      p += m;
    end
  endtask
endclass
