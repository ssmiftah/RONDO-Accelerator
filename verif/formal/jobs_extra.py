# Additional jobs (imported by gen_jobs.py). T/PDR/YICES/Z3/C/SVA are injected below.
import builtins
def _mk(g):
    T, PDR, YICES, Z3, C, SVA = g["T"], g["PDR"], g["YICES"], g["Z3"], g["C"], g["SVA"]
    return {
 "arb": dict(top="arb_f", files=["H:arb_f.v", C+"rondo_rbus_arb.v"], canary="o_v && o_int",
   tasks={"prove": T("prove", 20, (PDR, YICES)), "cover": T("cover", 30), "canary": T("bmc", 20, defs=["CANARY"], expect="FAIL")}),
 "kat": dict(top="kat_f", prefix_defs=["PREFIX"], files=["H:kat_f.v", C+"rondo_kat.v"], canary="seen_run && ev_sel",
   tasks={"prove": T("prove", 40, (PDR,), note="unbounded:_progress,_rb1,_address_order"), "bmc_data": T("bmc", 60, defs=["KAT_DATA"], note="LFSR_data/exponent:_bounded_(BMC_blows_up_beyond_~45_steps)"),
          "cover": T("cover", 80), "bmc_srst": T("bmc", 60, defs=["WITH_SRST"]), "canary": T("bmc", 80, defs=["CANARY"], expect="FAIL")}),
    }
