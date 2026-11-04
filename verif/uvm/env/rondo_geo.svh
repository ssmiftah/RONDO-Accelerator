// Geometry of the configured build (from cfg_pkg.svh macros) and address helpers (spec 7.1).
class rondo_geo;
  int W = `C_WIDTH, P = `C_PDIM, L = `C_LANES, NS = `C_NSLOT, NP = `C_NPAR, D = `C_DEPTH, NX = `C_NXBUF;
  int NLAD, NCH, NGRP, NB, NWORDS, NBWORDS, WAW, BAW, LNW, FW, XW, ZJW, TILE_B, LAYER, ACCSIG;
  bit has_tile, has_dbg, has_trace, has_kat, has_mbist, has_scan, has_pg, has_spicrc, has_clkalt;
  function new();
    NLAD = W / L; NCH = NS * D; NGRP = NCH / NP; NB = NLAD / NS; NWORDS = NB * NGRP * P; NBWORDS = NB * NGRP;
    WAW = $clog2(NWORDS); BAW = (NBWORDS < 2) ? 1 : $clog2(NBWORDS); LNW = (L < 2) ? 1 : $clog2(L); FW = $clog2(NP); XW = $clog2(P); ZJW = $clog2(W);
    TILE_B = `C_TILE_B; LAYER = `C_LAYER; ACCSIG = `C_ACCSIG;
    has_tile = (`C_TILE != 0) && (`C_LAYER == 0) && (NB == 1); has_dbg = `C_DBG != 0; has_trace = `C_TRACE != 0; has_kat = `C_KAT != 0;
    has_mbist = `C_MBIST != 0; has_scan = `C_SCAN != 0; has_pg = `C_PG != 0; has_spicrc = `C_SPI_CRC != 0; has_clkalt = `C_CLK_ALT != 0;
  endfunction
  function bit [23:0] w_addr(int lane, int caddr, int f); return WEIGHT_BASE + (lane << (WAW + FW)) + (caddr << FW) + f; endfunction
  function bit [23:0] b_addr(int lane, int caddr, int f); return BIAS_BASE + (lane << (BAW + FW)) + (caddr << FW) + f; endfunction
  function bit [23:0] x_addr(int entry, int i); return XBUF_BASE + (entry << XW) + i; endfunction
  function bit [23:0] tx_addr(int b, int i); return TX_BASE + (b << XW) + i; endfunction
  function bit [23:0] tz_addr(int b, int j); return TZ_BASE + (b << ZJW) + j; endfunction
  function bit [23:0] ps_addr(int b, int lane, int g, int f); return PS_BASE + (b << (LNW + BAW + FW)) + (lane << (BAW + FW)) + (g << FW) + f; endfunction
  // logical weight (j, k, c) -> (lane, caddr, field)  (packing.py weight_addr)
  function void weight_loc(int j, int k, int c, output int lane, output int caddr, output int f);
    int l, r, b, s, ch, g; l = j / NLAD; r = j % NLAD; b = r / NS; s = r % NS; ch = s * D + k; g = ch / NP; f = ch % NP;
    lane = l; caddr = (b * NGRP + g) * P + c;
  endfunction
  function void bias_loc(int j, int k, output int lane, output int caddr, output int f);
    int l, r, b, s, ch, g; l = j / NLAD; r = j % NLAD; b = r / NS; s = r % NS; ch = s * D + k; g = ch / NP; f = ch % NP;
    lane = l; caddr = b * NGRP + g;
  endfunction
endclass
