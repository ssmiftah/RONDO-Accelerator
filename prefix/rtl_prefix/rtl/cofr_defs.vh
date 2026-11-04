// Central parameter defaults for the CoFrNet continuant coprocessor.
// Single source of truth for the scaling knobs; every module declares
// parameters that default to these, and a top-level / test runner can override
// them (e.g. DEPTH sweeps, or switching the numeric format).
//
// Changing the numeric format (e.g. to bf16 to save DSPs) means overriding
// COFR_EXP/COFR_SIG *and* COFR_EPS (epsilon re-encoded in the new format).

`ifndef COFR_DEFS_VH
`define COFR_DEFS_VH

// --- Numeric format: IEEE-754 single precision (fp32) by default ---
`define COFR_EXP   8      // exponent width
`define COFR_SIG   24     // significand width (incl. hidden bit); total width = EXP+SIG

// --- Ladder geometry (scaling knobs) ---
`define COFR_DEPTH 7      // continued-fraction depth d
`define COFR_WIDTH 1      // number of parallel ladders L (used from M2 on)

// --- Stability epsilon, encoded in the default format (0.01f) ---
// If COFR_EXP/COFR_SIG change, re-encode this to the new format.
`define COFR_EPS   32'h3C23D70A

`endif
