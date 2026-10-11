"""Placebo: move the levels by a fraction of ATR (negative = inside the range).
If PDH/PDL matter, the exact levels should beat shifted ones. Also long vs short."""
import os, numpy as np, pandas as pd
from cand import all_trades
pd.set_option('display.width', 250)
rows = []
for b in [-0.25, -0.1, 0.0, 0.1, 0.25]:
    A = all_trades(buf_atr=b)
    g = A.groupby(['per', 'ins']).R.mean().groupby('per').mean()
    rows.append(dict(level_shift_atr=b, IS=g.IS, VAL=g.VAL, OOS=g.OOS, trades=len(A)))
    if b == 0.0:
        LS = A.pivot_table(index='ins', columns='side', values='R', aggfunc='mean').rename(columns={-1.0: 'short', 1.0: 'long'})
print("Equal-weight mean net expectancy (R) of the candidate with shifted levels")
print(pd.DataFrame(rows).round(4).to_string(index=False))
print("\nCandidate: net expectancy (R) long vs short")
print(LS.round(3).to_string())
