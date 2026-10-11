"""Sensitivity of the two filters + exits around the candidate."""
import os
import itertools, numpy as np, pandas as pd, bt
from grid import INS, period
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 300)
rows = []
data = {ins: (lambda D: (D, bt.levels(D)))(bt.load(ins)) for ins in INS}
def go(name, cost_mult=1.0, **kw):
    for ins, (D, lv) in data.items():
        T = bt.run(D, lv, entry=0, cost_mult=cost_mult, **kw)
        if ins == "BTC_USD": T = T[T.time.dt.year >= 2014]
        T["per"] = period(ins, T.te)
        for p, x in T.groupby("per"):
            rows.append(dict(cfg=name, ins=ins, per=p, n=len(x), E=x.R.mean(), Eg=x.Rg.mean()))
for skip, mx in itertools.product([0, 1, 2, 3], [0, 0.8, 1.0, 1.2]):
    go(f"skip{skip}h|rng<{mx}", sl_atr=1.0, rr=2.0, win=(skip * 60, 1440), max_rng_atr=mx)
for sl, rr in itertools.product([0.5, 1.0, 1.5], [1.0, 2.0, 0.0]):
    go(f"cand|SL{sl}|RR{rr:g}", sl_atr=sl, rr=rr, win=(120, 1440), max_rng_atr=1.0)
go("cand|cost2x", cost_mult=2.0, sl_atr=1.0, rr=2.0, win=(120, 1440), max_rng_atr=1.0)
R = pd.DataFrame(rows)
R.to_pickle(os.path.join(os.environ.get('PDH_OUT', '/tmp'), 'sens.pkl'))
g = R.groupby(["cfg", "per"]).agg(E=("E", "mean"), npos=("E", lambda x: (x > 0).sum()), n=("n", "sum")).unstack("per")
print(g.round(3).to_string())
