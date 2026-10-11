"""One-variable-at-a-time tests on the stop-entry baseline."""
import os
import numpy as np, pandas as pd, bt
from grid import INS, period
pd.set_option('display.width', 250)
BASE = dict(entry=0, sl_atr=1.0, rr=2.0)

def summ(T):
    r = T.R
    return pd.Series(dict(n=len(r), Eg=T.Rg.mean(), E=r.mean(), t=r.mean() / r.std() * np.sqrt(len(r)) if len(r) > 1 else np.nan))

VARIANTS = {
    "base": {},
    "buf0.1": dict(buf_atr=0.1),
    "buf0.25": dict(buf_atr=0.25),
    "both_sides": dict(oco=False),
    "win08-20": dict(win=(8 * 60, 20 * 60)),
    "win02-24": dict(win=(2 * 60, 1440)),
    "long_only": dict(sides=1),
    "short_only": dict(sides=2),
}
rows = []; allT = []
for ins in INS:
    D = bt.load(ins); lv = bt.levels(D)
    for vn, kw in VARIANTS.items():
        T = bt.run(D, lv, **{**BASE, **kw})
        if ins == "BTC_USD": T = T[T.time.dt.year >= 2014]
        T["per"] = period(ins, T.te); T["ins"] = ins; T["v"] = vn
        allT.append(T)
A = pd.concat(allT)
A.to_pickle(os.path.join(os.environ.get('PDH_OUT', '/tmp'), 'diag.pkl'))
g = A.groupby(["v", "per", "ins"]).R.mean().groupby(["v", "per"]).agg(["mean", lambda x: (x > 0).sum()]).unstack("per")
print(g.round(3))

def m(x): return pd.Series(dict(n=len(x), E=x.R.mean(), t=x.R.mean() / x.R.std() * np.sqrt(len(x))))
B = A[A.v == "base"].copy()
B["prev_range_over_atr"] = pd.cut(B.rng_atr, [0, 0.6, 0.8, 1.0, 1.3, 10])
print("\nBase (stop, SL 1 ATR, TP 2R): pooled trades by previous-day range / ATR14")
print(B.groupby(["prev_range_over_atr", "per"], observed=True).apply(m).unstack("per").round(3).to_string())
B["entry_hour_server"] = pd.cut(B.hour, [-1, 1, 5, 9, 13, 17, 20, 24])
print("\nBase: pooled trades by entry hour (server time, day starts 00:00 = 17:00 New York)")
print(B.groupby(["entry_hour_server", "per"], observed=True).apply(m).unstack("per").round(3).to_string())
print("\nBase: exit reasons (1 SL, 2 TP, 3 end of day)")
print(B.groupby("why").R.agg(["size", "mean"]).round(3).to_string())
