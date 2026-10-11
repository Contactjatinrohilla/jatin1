"""CSV folder of M1 bars (time,open,high,low,close in UTC) -> one .npz file."""
import sys, glob, os, numpy as np, pandas as pd
src, dst = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(src, "**", "*.csv"), recursive=True))
dfs = []
for f in files:
    d = pd.read_csv(f)
    d.columns = [c.lower() for c in d.columns]
    tcol = "time" if "time" in d.columns else "date"
    d["t"] = pd.to_datetime(d[tcol]).values.astype("datetime64[s]").astype(np.int64)
    dfs.append(d[["t", "open", "high", "low", "close"]])
d = pd.concat(dfs).dropna().drop_duplicates("t").sort_values("t")
np.savez_compressed(dst, t=d.t.values.astype(np.int64), o=d.open.values, h=d.high.values, l=d.low.values, c=d.close.values)
print(dst, len(d), pd.to_datetime(d.t.iloc[0], unit="s"), pd.to_datetime(d.t.iloc[-1], unit="s"))
