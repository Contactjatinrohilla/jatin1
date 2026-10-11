#!/usr/bin/env python3
"""
Find (or rule out) an edge in MorningStar_EA signals.

Input : the research CSV the EA writes in the Strategy Tester
        (MT5 data folder -> Common\\Files\\MorningStar_signals_<symbol>_<tf>.csv).
        Run the test with InpLogSignals = true. Every pattern the EA sees is
        logged - traded or not - with its features and what price did next.

What it reports
  1. Baseline: win rate and expectancy (average R per trade) for many take
     profit levels, for both stop styles:
        A = SL below the signal candle (EA default)
        B = SL below the pattern's lowest low (InpSLAtPatternLow = true)
  2. How far price goes before the stop (MFE) -> where a TP makes sense.
  3. Every feature split into 5 equal groups: which groups win, which lose.
  4. Filter search with a time split: filters are picked on the FIRST part
     of the data (in-sample) and then checked on the LATER part
     (out-of-sample). Only filters that also hold out-of-sample are worth
     using - anything else is curve fitting.

Results are in R: +1R = won the amount risked, -1R = stop loss hit.
Spread is included (virtual entry at the Ask, price followed on the Bid).
Commission and swap are NOT included.

Usage
  python3 morningstar_edge.py MorningStar_signals_NDX100_PERIOD_M30.csv
  python3 morningstar_edge.py file1.csv file2.csv --tp 1.5 --out report.md
"""
import argparse
import itertools
import sys

import numpy as np
import pandas as pd

TP_GRID = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0]

FEATURES = [
    "c1_range_atr", "c1_body_atr", "sweep_atr", "c2_close_pos",
    "sig_body_pct", "sig_uwick_pct", "sig_range_atr", "sig_close_vs_c1high_atr",
    "riskA_atr", "riskB_atr", "spread_riskA", "dist_ema50_atr", "dist_ema200_atr",
    "ema50_slope_atr", "prior_move_atr", "day_move_atr",
]
CATEGORIES = ["hour", "weekday", "pattern", "sig_bull"]

EXPLAIN = {
    "c1_range_atr": "size of C1 (x ATR)",
    "c1_body_atr": "body of C1 (x ATR)",
    "sweep_atr": "how far C2 went below C1's low (x ATR)",
    "c2_close_pos": "where C2 closed inside C1 (0 = at C1 low, 1 = at C1 high)",
    "sig_body_pct": "signal candle body, % of its size",
    "sig_uwick_pct": "signal candle upper wick, % of its size",
    "sig_range_atr": "signal candle size (x ATR)",
    "sig_close_vs_c1high_atr": "signal close minus C1 high (x ATR)",
    "riskA_atr": "stop distance A (x ATR)",
    "riskB_atr": "stop distance B (x ATR)",
    "spread_riskA": "spread as a fraction of stop distance A",
    "dist_ema50_atr": "signal close minus EMA50 (x ATR)",
    "dist_ema200_atr": "signal close minus EMA200 (x ATR)",
    "ema50_slope_atr": "EMA50 change over 10 candles (x ATR)",
    "prior_move_atr": "price move in the 10 candles before C1 (x ATR)",
    "day_move_atr": "signal close minus today's open (x ATR)",
    "hour": "server hour of entry",
    "weekday": "day of week (1 = Monday)",
    "pattern": "3-candle or 4-candle",
    "sig_bull": "signal candle bullish (1) or not (0)",
}


def outcome(df, style, tp):
    """Result in R of each signal for a fixed TP (no partial closes)."""
    mfe = df[f"mfe{style}_R"].to_numpy()
    hit = df[f"hit{style}"].to_numpy()
    last = df[f"last{style}_R"].to_numpy()
    return np.where(mfe >= tp, tp, np.where(hit == 1, -1.0, np.minimum(last, tp)))


def stats(r):
    r = np.asarray(r, dtype=float)
    n = len(r)
    if n == 0:
        return dict(n=0, win=np.nan, exp=np.nan, total=np.nan, pf=np.nan, maxdd=np.nan)
    eq = np.cumsum(r)
    dd = (np.maximum.accumulate(np.concatenate([[0], eq]))[1:] - eq).max()
    gains, losses = r[r > 0].sum(), -r[r < 0].sum()
    return dict(n=n, win=(r > 0).mean() * 100, exp=r.mean(), total=r.sum(),
                pf=(gains / losses) if losses > 0 else np.inf, maxdd=dd)


def fmt(st):
    return (f"{st['n']:>5} | {st['win']:5.1f}% | {st['exp']:+.3f} | {st['total']:+8.1f} | "
            f"{st['pf']:5.2f} | {st['maxdd']:6.1f}")


HDR = "    n | win %  | exp R  |  total R |  PF   | maxDD R"


def load(paths):
    frames = []
    for p in paths:
        d = pd.read_csv(p)
        d["source"] = p
        frames.append(d)
    df = pd.concat(frames, ignore_index=True)
    df["time"] = pd.to_datetime(df["time"], format="%Y.%m.%d %H:%M")
    df = df.sort_values("time").reset_index(drop=True)
    # impossible stops (risk <= 0) cannot be traded
    df = df[(df["riskA_atr"] > 0)].reset_index(drop=True)
    return df


def section_baseline(df, out):
    out.append("## 1. Baseline (every signal, no filters)\n")
    out.append(f"Signals: {len(df)}  from {df['time'].min()} to {df['time'].max()}\n")
    best = {}
    for style, name in (("A", "SL below signal candle"), ("B", "SL below pattern low")):
        sub = df[df[f"risk{style}_atr"] > 0]
        out.append(f"\n**Stop {style}: {name}**\n")
        out.append("```\n  TP R | " + HDR)
        rows = []
        for tp in TP_GRID:
            st = stats(outcome(sub, style, tp))
            rows.append((tp, st))
            out.append(f"{tp:6.2f} | " + fmt(st))
        out.append("```")
        b = max(rows, key=lambda x: x[1]["exp"])
        best[style] = b
        out.append(f"Best TP for stop {style}: {b[0]}R -> {b[1]['exp']:+.3f} R per trade\n")
    return best


def section_mfe(df, out):
    out.append("## 2. How far price goes before the stop is hit\n")
    out.append("```\nlevel |  stop A  |  stop B")
    for lvl in [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5]:
        a = (df["mfeA_R"] >= lvl).mean() * 100
        b = (df["mfeB_R"] >= lvl).mean() * 100
        out.append(f"{lvl:5.2f}R | {a:6.1f}% | {b:6.1f}%")
    out.append("```")
    out.append("Break-even win rate for a TP of X R is 1/(1+X): 1R -> 50%, 1.5R -> 40%, "
               "2R -> 33%, 3R -> 25%. A level is only worth targeting if the % above "
               "is clearly higher than that.\n")


def section_features(df, style, tp, out):
    out.append(f"## 3. Features (stop {style}, TP {tp}R)\n")
    out.append("Each feature is cut into 5 equal-sized groups (lowest values first). "
               "Look for a feature whose expectancy rises or falls steadily across the "
               "groups - a single good group in the middle is usually noise.\n")
    r = outcome(df, style, tp)
    for f in FEATURES:
        if f not in df or df[f].nunique() < 5:
            continue
        try:
            bins = pd.qcut(df[f], 5, duplicates="drop")
        except ValueError:
            continue
        out.append(f"\n**{f}** - {EXPLAIN.get(f, '')}\n```\n{'range':>24} | " + HDR)
        for iv, idx in df.groupby(bins, observed=True).groups.items():
            out.append(f"{str(iv):>24} | " + fmt(stats(r[df.index.get_indexer(idx)])))
        out.append("```")
    for c in CATEGORIES:
        out.append(f"\n**{c}** - {EXPLAIN.get(c, '')}\n```\n{'value':>6} | " + HDR)
        for v, idx in df.groupby(c).groups.items():
            out.append(f"{v:>6} | " + fmt(stats(r[df.index.get_indexer(idx)])))
        out.append("```")


def candidate_filters(df):
    """(name, function(df) -> bool mask) for single-condition filters."""
    cands = []
    for f in FEATURES:
        if f not in df or df[f].nunique() < 5:
            continue
        for q in (0.2, 0.4, 0.6, 0.8):
            t = round(float(df[f].quantile(q)), 3)
            cands.append((f"{f} >= {t}", lambda d, f=f, t=t: d[f] >= t))
            cands.append((f"{f} <= {t}", lambda d, f=f, t=t: d[f] <= t))
    cands.append(("sig_bull == 1", lambda d: d["sig_bull"] == 1))
    cands.append(("pattern == 3", lambda d: d["pattern"] == 3))
    cands.append(("pattern == 4", lambda d: d["pattern"] == 4))
    for start in range(0, 24, 2):
        for length in (4, 6, 8):
            end = start + length
            cands.append((f"hour {start:02d}-{end % 24:02d}",
                          lambda d, s=start, e=end: ((d["hour"] - s) % 24) < (e - s)))
    return cands


def section_search(df, style, tp, split, min_n, out):
    cut = int(len(df) * split)
    ins, oos = df.iloc[:cut], df.iloc[cut:]
    out.append(f"## 4. Filter search (stop {style}, TP {tp}R)\n")
    out.append(f"In-sample: {ins['time'].min():%Y-%m-%d} to {ins['time'].max():%Y-%m-%d} "
               f"({len(ins)} signals). Out-of-sample: {oos['time'].min():%Y-%m-%d} to "
               f"{oos['time'].max():%Y-%m-%d} ({len(oos)} signals).\n")
    base_is, base_oos = stats(outcome(ins, style, tp)), stats(outcome(oos, style, tp))
    out.append(f"No filter: in-sample {base_is['exp']:+.3f} R/trade, "
               f"out-of-sample {base_oos['exp']:+.3f} R/trade\n")

    cands = candidate_filters(ins)
    min_oos = max(10, int(min_n * (1 - split) / split))
    results = []
    for name, fn in cands:
        m = fn(ins)
        if m.sum() < min_n:
            continue
        results.append((name, fn, stats(outcome(ins[m], style, tp))))
    results.sort(key=lambda x: x[2]["exp"], reverse=True)
    top = results[:15]

    # pairs of the best single filters
    pairs = []
    for (n1, f1, _), (n2, f2, _) in itertools.combinations(top, 2):
        if n1.split()[0] == n2.split()[0]:
            continue
        m = f1(ins) & f2(ins)
        if m.sum() < min_n:
            continue
        pairs.append((f"{n1}  AND  {n2}", lambda d, f1=f1, f2=f2: f1(d) & f2(d),
                      stats(outcome(ins[m], style, tp))))
    pairs.sort(key=lambda x: x[2]["exp"], reverse=True)

    def table(title, rows):
        out.append(f"\n**{title}** (min {min_n} in-sample trades)\n```")
        out.append(f"{'filter':<58} | IS n | IS exp | OOS n | OOS exp | OOS win% | holds?")
        for name, fn, st in rows:
            mo = fn(oos)
            so = stats(outcome(oos[mo], style, tp))
            holds = ("YES" if so["n"] >= min_oos and so["exp"] > 0
                     else ("few trades" if so["n"] < min_oos else "no"))
            out.append(f"{name:<58} | {st['n']:>4} | {st['exp']:+.3f} | {so['n']:>5} | "
                       f"{so['exp']:+.3f} | {so['win']:7.1f}% | {holds}")
        out.append("```")

    table("Best single filters", top)
    table("Best pairs of filters", pairs[:15])
    out.append("\nRead this table carefully: a filter is only interesting if it is "
               "positive out-of-sample with a reasonable number of trades AND it "
               "makes sense (you can explain why it should work). Testing hundreds "
               "of filters will always find some that look good in-sample by luck.\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("csv", nargs="+")
    ap.add_argument("--tp", type=float, default=None, help="TP (R) for sections 3-4 (default: best baseline)")
    ap.add_argument("--sl", choices=["A", "B"], default=None, help="stop style for sections 3-4 (default: best)")
    ap.add_argument("--split", type=float, default=0.6, help="in-sample fraction (default 0.6)")
    ap.add_argument("--min-trades", type=int, default=40, help="min in-sample trades per filter")
    ap.add_argument("--out", help="write the report to this file (markdown)")
    a = ap.parse_args()

    df = load(a.csv)
    if len(df) < 50:
        print(f"Only {len(df)} signals - run a longer test (several years) first.")
    out = ["# MorningStar_EA edge report\n"]
    best = section_baseline(df, out)
    section_mfe(df, out)
    style = a.sl or max(best, key=lambda k: best[k][1]["exp"])
    tp = a.tp or best[style][0]
    section_features(df, style, tp, out)
    section_search(df, style, tp, a.split, a.min_trades, out)

    text = "\n".join(out)
    if a.out:
        with open(a.out, "w") as fh:
            fh.write(text)
        print(f"Report written to {a.out}")
    else:
        print(text)


if __name__ == "__main__":
    sys.exit(main())
