"""Pre-declared grid: entry method x stop size x reward:risk, every instrument,
split into chronological in-sample / validation / out-of-sample periods."""
import os
import sys, itertools, numpy as np, pandas as pd
import bt

INS = ["NAS100_USD", "SPX500_USD", "US2000_USD", "UK100_GBP", "JP225_USD", "XAU_USD", "WTICO_USD",
       "EUR_USD", "GBP_USD", "USD_CAD", "AUD_USD", "EUR_JPY", "BTC_USD"]
ENTRIES = {"stop": (0, 0), "closeM15": (1, 15), "closeH1": (1, 60), "retest": (2, 0)}
SLS = [0.25, 0.5, 1.0]
RRS = [1.0, 2.0, 0.0]


def period(ins, ts):
    y = pd.to_datetime(ts, unit="s").dt.year.values
    if ins == "BTC_USD":
        return np.select([y <= 2015, y == 2016], ["IS", "VAL"], "OOS")
    return np.select([y <= 2012, y <= 2016], ["IS", "VAL"], "OOS")


def main(cost_mult=1.0, extra=None, tag="grid"):
    rows, trades = [], []
    for ins in INS:
        D = bt.load(ins); lv = bt.levels(D)
        for (en, (e, tf)), sl, rr in itertools.product(ENTRIES.items(), SLS, RRS):
            kw = dict(entry=e, tf=tf, sl_atr=sl, rr=rr, cost_mult=cost_mult, **(extra or {}))
            T = bt.run(D, lv, **kw)
            if ins == "BTC_USD":
                T = T[T.time.dt.year >= 2014]
            T["per"] = period(ins, T.te)
            T["ins"] = ins; T["cfg"] = f"{en}|SL{sl}|RR{rr:g}"
            trades.append(T[["ins", "cfg", "per", "te", "side", "R", "Rg", "cost_R", "why"]])
        print(ins, flush=True)
    A = pd.concat(trades)
    A.to_pickle(os.path.join(os.environ.get('PDH_OUT', '/tmp'), f'{tag}.pkl'))
    return A


if __name__ == "__main__":
    main(float(sys.argv[1]) if len(sys.argv) > 1 else 1.0)
