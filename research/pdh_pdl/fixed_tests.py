"""Fixed SL/TP (price distance): stop vs candle-close confirmation, with and without trailing."""
import numpy as np, bt
CASES = [("NAS100_USD", 50, 100), ("XAU_USD", 5, 10), ("EUR_USD", 0.002, 0.004)]
for ins, sl, tp in CASES:
    D = bt.load(ins); pdh, pdl, atr = bt.levels(D)
    one = np.where(np.isnan(atr), np.nan, 1.0)          # atr = 1 -> sl_atr is a fixed price distance
    for name, kw in [("stop", dict(entry=0)), ("closeM15", dict(entry=1, tf=15)), ("closeH1", dict(entry=1, tf=60))]:
        for tr in [(0, 0), (sl, sl), (sl * 0.5, sl * 0.5), (sl, sl * 0.5)]:
            T = bt.run(D, (pdh, pdl, one), sl_atr=sl, rr=tp / sl, win=(120, 1440), trail=tr, **kw)
            out = []
            for a, b in [(2005, 2012), (2013, 2016), (2017, 2020)]:
                x = T[(T.time.dt.year >= a) & (T.time.dt.year <= b)]
                s = bt.stats(x); out.append("%+.3f(PF %.2f)" % (s["E"], s["PF"]))
            print(f"{ins:11s} SL {sl:g} TP {tp:g} {name:8s} trail start/dist {tr[0]:g}/{tr[1]:g}: " + "  ".join(out), flush=True)
