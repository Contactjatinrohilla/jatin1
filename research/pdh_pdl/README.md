# PDH/PDL breakout study

Reproduces every number in `reports/PDH_PDL_Research.md`.

```
pip install numpy pandas numba
PDH_DATA=/path/to/data ./fetch_data.sh                 # ~5 GB download, writes 13 .npz files
PDH_DATA=/path/to/data PDH_OUT=/tmp ./run_all.sh        # ~6 minutes, writes results/*.txt
```

| File | What it does |
|---|---|
| `bt.py` | M1 backtester: server-time days (New York + 7 h), PDH/PDL/ATR without look-ahead, stop / close / retest entries, pessimistic fills, costs in bps |
| `grid.py` + `summarize_grid.py` | entry method x stop x RR on all instruments, IS 2005-12 / VAL 2013-16 / OOS 2017-20 |
| `diag.py` | one change at a time on the stop-entry baseline, plus range/ATR and entry-hour breakdowns |
| `sens.py` | sensitivity of the two adopted filters and of SL/RR around the candidate, 2x cost stress |
| `cand.py` | full metrics of the candidate per instrument, per period and per year |
| `placebo.py` | shifted levels (are PDH/PDL special?) and long vs short |
| `convert.py`, `fetch_data.sh` | data download and conversion |
