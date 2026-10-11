"""Full metrics for the final candidate, per instrument and per year."""
import os
import numpy as np, pandas as pd, bt
from grid import INS, period
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 300)
CAND = dict(entry=0, sl_atr=1.0, rr=2.0, win=(120, 1440), max_rng_atr=1.0)
def all_trades(cost_mult=1.0, **over):
    out = []
    for ins in INS:
        D = bt.load(ins); lv = bt.levels(D)
        T = bt.run(D, lv, cost_mult=cost_mult, **{**CAND, **over})
        if ins == "BTC_USD": T = T[T.time.dt.year >= 2014]
        T["per"] = period(ins, T.te); T["ins"] = ins
        out.append(T)
    return pd.concat(out)
if __name__ == "__main__":
    A = all_trades()
    A.to_pickle(os.path.join(os.environ.get('PDH_OUT', '/tmp'), 'cand.pkl'))
    rows = []
    for (ins, per), x in list(A.groupby(["ins", "per"])) + [((i, "ALL"), x) for i, x in A.groupby("ins")]:
        s = bt.stats(x); s.update(ins=ins, per=per); rows.append(s)
    S = pd.DataFrame(rows).set_index(["ins", "per"]).sort_index()
    print(S[["n", "per_yr", "Eg", "costR", "E", "t", "win", "avgW", "avgL", "PF", "net", "maxDD", "RF", "E_ex_top5"]].round(3).to_string())
    A["yr"] = A.time.dt.year
    print(A.pivot_table(index="ins", columns="yr", values="R", aggfunc="sum").round(1).to_string())
    r = A.R; print("POOLED all trades: n=%d E=%.4f t=%.2f" % (len(r), r.mean(), r.mean() / r.std() * np.sqrt(len(r))))
    for p, x in A.groupby("per"):
        print(p, "n=%d E=%.4f t=%.2f" % (len(x), x.R.mean(), x.R.mean() / x.R.std() * np.sqrt(len(x))))
