"""Prints the entry-method comparison tables from grid.py output."""
import sys, numpy as np, pandas as pd
pd.set_option('display.width', 250); pd.set_option('display.max_rows', 300)
A = pd.read_pickle(sys.argv[1])
g = A.groupby(['cfg', 'per', 'ins']).agg(E=('R', 'mean'), Eg=('Rg', 'mean')).reset_index()
p = g.groupby(['cfg', 'per'])[['E', 'Eg']].mean().unstack('per')
p.columns = [a + '_' + b for a, b in p.columns]
pos = g.assign(pos=g.E > 0).groupby(['cfg', 'per']).pos.sum().unstack('per'); pos.columns = ['npos_' + c for c in pos.columns]
print("Equal-weight mean expectancy (R) across 13 instruments; Eg = gross (before costs); npos = instruments with E > 0")
print(p.join(pos)[['Eg_IS', 'Eg_VAL', 'Eg_OOS', 'E_IS', 'E_VAL', 'E_OOS', 'npos_IS', 'npos_VAL', 'npos_OOS']]
      .sort_values('E_IS', ascending=False).round(3).to_string())
print("\nGross expectancy by entry method (all stop/RR combos pooled), per instrument, full period:")
A['entry'] = A.cfg.str.split('|').str[0]
print(A.groupby(['ins', 'entry']).Rg.mean().unstack().round(3).to_string())
