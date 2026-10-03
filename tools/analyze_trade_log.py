#!/usr/bin/env python3
"""
Analyse the EA trade log (SB_trades_<symbol>.csv, written by v7.80+ in single tests)
and answer: are losing trades REAL reversals from the entry level, or is the stop
too tight / the entry too late, or does the data look wrong?

  python3 analyze_trade_log.py SB_trades_XAUUSD.T.csv

The CSV is in the terminal's Common\\Files folder
(MetaEditor: File > Open Common Data Folder > Files).
"""
import csv
import statistics as st
import sys
from collections import defaultdict


def f(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def load(path):
    with open(path, newline="", encoding="latin-1") as fh:
        rows = list(csv.DictReader(fh))
    out = []
    for r in rows:
        if r.get("exit_reason") in ("still_open", ""):
            continue
        d = dict(r)
        for k in ("level", "fill", "entry_slip", "spread_at_entry", "sl_dist", "tp_dist", "mfe", "mae", "mfe_r",
                  "mae_r", "min_to_mfe", "profit", "r", "hold_min", "post_best", "post_best_r"):
            d[k] = f(r.get(k))
        d["hour"] = int(r["open_time"][11:13]) if len(r.get("open_time", "")) >= 13 else -1
        d["tp_hit_after_exit"] = r.get("tp_hit_after_exit", "")
        out.append(d)
    return out


def classify(t):
    """What happened to one trade."""
    if t["exit_reason"] == "TP":
        return "win: TP"
    if t["r"] is not None and t["r"] > 0.05:
        return "win: other exit"
    mfe = t["mfe_r"] or 0
    post = t["post_best_r"]
    if t["exit_reason"] in ("SL",):
        if mfe < 0.25:
            if post is not None and t["tp_hit_after_exit"] == "1":
                return "loss: immediate reversal, then price went to TP (stop too tight / noise)"
            return "loss: immediate reversal (false breakout)"
        if mfe >= 1.0:
            return "loss: was +1R or more, gave it all back (needs breakeven/partial)"
        if t["tp_hit_after_exit"] == "1":
            return "loss: stopped, then price went to TP (stop too tight)"
        return "loss: went partly in favour, then reversed"
    if t["exit_reason"] == "BE_or_trail_stop":
        return "flat: breakeven / trailing stop"
    return f"other: {t['exit_reason']}"


def table(title, groups):
    print(f"\n{title}")
    print(f"  {'group':<34}{'trades':>7}{'win%':>7}{'avg R':>8}{'net $':>10}{'imm.rev%':>10}")
    for k in sorted(groups, key=lambda x: str(x)):
        g = groups[k]
        n = len(g)
        w = sum(1 for t in g if (t["r"] or 0) > 0.05)
        ar = st.mean(t["r"] or 0 for t in g)
        net = sum(t["profit"] or 0 for t in g)
        imm = sum(1 for t in g if t["exit_reason"] == "SL" and (t["mfe_r"] or 0) < 0.25)
        print(f"  {str(k):<34}{n:>7}{pct(w, n):>6.0f}%{ar:>+8.2f}{net:>10.0f}{pct(imm, n):>9.0f}%")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    T = load(sys.argv[1])
    if not T:
        sys.exit("No closed trades in the file.")
    n = len(T)
    print(f"{n} closed trades | net ${sum(t['profit'] or 0 for t in T):,.2f} | "
          f"win rate {pct(sum(1 for t in T if (t['r'] or 0) > 0.05), n):.0f}% | avg R {st.mean(t['r'] or 0 for t in T):+.3f}")

    # 1) what happened
    c = defaultdict(list)
    for t in T:
        c[classify(t)].append(t)
    print("\nWHAT HAPPENED TO EACH TRADE")
    for k, g in sorted(c.items(), key=lambda kv: -len(kv[1])):
        print(f"  {len(g):>5}  {pct(len(g), n):5.1f}%  net ${sum(t['profit'] or 0 for t in g):>9,.0f}  {k}")

    losers = [t for t in T if t["exit_reason"] == "SL"]
    winners = [t for t in T if t["exit_reason"] == "TP"]

    # 2) losers: how far did they go in our favour first?
    if losers:
        m = [t["mfe_r"] or 0 for t in losers]
        print(f"\nLOSING TRADES (full SL, {len(losers)}): best move in our favour before the stop")
        for lo, hi, lab in ((0, .1, "< 0.1R  (no follow-through at all)"), (.1, .25, "0.1-0.25R"), (.25, .5, "0.25-0.5R"),
                            (.5, 1, "0.5-1R"), (1, 99, ">= 1R   (was a winner first)")):
            k = sum(1 for x in m if lo <= x < hi)
            print(f"  {lab:<36}{k:>5}  {pct(k, len(losers)):5.1f}%")
        mins = [t["min_to_mfe"] for t in losers if t["min_to_mfe"] is not None]
        if mins:
            print(f"  median minutes from entry to that best point: {st.median(mins):.0f}")
        post = [t for t in losers if t["tp_hit_after_exit"] in ("0", "1")]
        if post:
            k = sum(1 for t in post if t["tp_hit_after_exit"] == "1")
            print(f"  after the stop, price still reached the TP within the post-exit window: {k} of {len(post)} "
                  f"({pct(k, len(post)):.0f}%)  -> high % = stop too tight / entry too early")
            pb = [t["post_best_r"] for t in post if t["post_best_r"] is not None]
            if pb:
                print(f"  median best move after the stop (from entry): {st.median(pb):+.2f}R")

    # 3) winners: how close to the stop did they come?
    if winners:
        m = [t["mae_r"] or 0 for t in winners]
        deep = sum(1 for x in m if x >= 0.8)
        print(f"\nWINNING TRADES (TP, {len(winners)}): worst move against us before winning")
        print(f"  median {st.median(m):.2f}R | came within 20% of the stop (>= 0.8R against): {deep} ({pct(deep, len(winners)):.0f}%)")

    # 4) execution / data
    sl = [t["entry_slip"] for t in T if t["entry_slip"] is not None]
    sd = [t["sl_dist"] for t in T if t["sl_dist"]]
    sp = [t["spread_at_entry"] for t in T if t["spread_at_entry"] is not None]
    if sl and sd:
        risk = st.median(sd)
        big = sum(1 for t in T if t["entry_slip"] is not None and t["sl_dist"] and t["entry_slip"] > 0.2 * t["sl_dist"])
        print(f"\nEXECUTION / DATA")
        print(f"  entry slippage vs level: median {st.median(sl):.3f}, worst {max(sl):.3f} (SL distance ~{risk:.2f}); "
              f"slippage > 20% of the stop: {big} trades")
        print(f"  spread at entry: median {st.median(sp):.3f}, max {max(sp):.3f}")
        neg = sum(1 for x in sl if x < -0.5 * risk)
        if neg:
            print(f"  WARNING {neg} trades filled far BETTER than the level - check for bad ticks / data gaps")
        zero = sum(1 for x in sp if x <= 0)
        if zero:
            print(f"  WARNING {zero} trades had zero or negative spread at entry - check the tick data")

    # 5) where
    for title, key in (("BY SETUP / SIDE", lambda t: f"{t['setup']} {t['side']}"),
                       ("BY ENTRY HOUR (server)", lambda t: f"{t['hour']:02d}:00"),):
        g = defaultdict(list)
        for t in T:
            g[key(t)].append(t)
        table(title, g)

    # 6) verdict
    print("\nREADING THIS")
    if losers:
        imm = pct(sum(1 for t in losers if (t["mfe_r"] or 0) < 0.25), len(losers))
        gave = pct(sum(1 for t in losers if (t["mfe_r"] or 0) >= 1.0), len(losers))
        noise = pct(sum(1 for t in losers if t["tp_hit_after_exit"] == "1"), len(losers))
        print(f"  {imm:.0f}% of losers never got 0.25R in our favour -> real false breakouts. "
              f"High (> 50%) = the ENTRY needs a filter (confirmation, trend, time of day).")
        print(f"  {gave:.0f}% of losers were +1R first -> breakeven at 1R would have saved them.")
        print(f"  {noise:.0f}% of losers hit the stop and THEN reached the TP -> stop too tight for the noise. "
              f"High (> 30%) = widen the SL or enter later.")
    print("  Data problems show up as big negative slippage, zero spreads, or trades at hours the market should be closed;"
          " run SB_DataCheck on the same symbol to confirm.")


if __name__ == "__main__":
    main()
