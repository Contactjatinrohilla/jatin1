"""
PDH/PDL breakout research backtester (M1 bars, server time = New York + 7h).

Everything is measured in R (1R = the stop-loss distance) net of costs, so
results are comparable across instruments.  No look-ahead: PDH, PDL and ATR
come only from fully completed earlier server days.

Conservative fill rules on M1 OHLC (mid prices):
  * stop entry fills at max(open, level) for buys (gaps fill worse)
  * if SL and TP are both inside one bar, the SL is assumed hit first
  * on the entry bar, an SL touch counts as a loss (bar order unknown)
  * open trades are closed at the last bar of the server day (no swap)
Costs (bps of price): round-trip spread+commission on every trade, plus
slippage on every stop/market fill (stop entry, close entry, SL exit).
"""
import os
import numpy as np
import pandas as pd
from numba import njit

DATA = os.environ.get("PDH_DATA", os.path.join(os.path.dirname(__file__), "data"))

# round-trip spread+commission bps, slippage bps per stop/market fill
COSTS = {
    "EUR_USD": (0.8, 0.10), "GBP_USD": (1.2, 0.15), "USD_CAD": (1.4, 0.15),
    "AUD_USD": (1.4, 0.15), "EUR_JPY": (1.6, 0.20), "XAU_USD": (2.0, 0.30),
    "NAS100_USD": (1.5, 0.30), "SPX500_USD": (1.2, 0.30), "US2000_USD": (3.0, 0.50),
    "UK100_GBP": (1.5, 0.30), "JP225_USD": (3.0, 0.50), "WTICO_USD": (5.0, 1.00),
    "BTC_USD": (20.0, 3.00),
}


def load(ins):
    z = np.load(os.path.join(DATA, ins + ".npz"))
    utc = pd.to_datetime(z["t"], unit="s", utc=True)
    ny = utc.tz_convert("America/New_York").tz_localize(None)
    srv = (ny + pd.Timedelta(hours=7)).values.astype("datetime64[s]").astype(np.int64)
    o, h, l, c = (z[k].astype(np.float64) for k in "ohlc")
    order = np.argsort(srv, kind="stable")
    srv, o, h, l, c = srv[order], o[order], h[order], l[order], c[order]
    day = srv // 86400
    # day table
    starts = np.flatnonzero(np.r_[True, day[1:] != day[:-1]])
    ends = np.r_[starts[1:], len(day)]
    dH = np.maximum.reduceat(h, starts)
    dL = np.minimum.reduceat(l, starts)
    dC = c[ends - 1]
    nbars = ends - starts
    return dict(ins=ins, t=srv, o=o, h=h, l=l, c=c, day=day[starts], s=starts, e=ends,
                dH=dH, dL=dL, dC=dC, n=nbars)


def levels(D, min_bars=360, atr_n=14):
    """PDH/PDL/ATR for each day from the previous *full* day (>= min_bars M1 bars)."""
    full = D["n"] >= min_bars
    nd = len(D["day"])
    pdh = np.full(nd, np.nan); pdl = np.full(nd, np.nan); atr = np.full(nd, np.nan)
    tr = []
    prevC = np.nan; last = -1
    for i in range(nd):
        if last >= 0:
            pdh[i], pdl[i] = D["dH"][last], D["dL"][last]
            # stale levels (holiday gap > 4 calendar days) -> skip
            if D["day"][i] - D["day"][last] > 4:
                pdh[i] = pdl[i] = np.nan
            if len(tr) >= atr_n:
                atr[i] = np.mean(tr[-atr_n:])
        if full[i]:
            hi, lo = D["dH"][i], D["dL"][i]
            t = hi - lo if np.isnan(prevC) else max(hi, prevC) - min(lo, prevC)
            tr.append(t); prevC = D["dC"][i]; last = i
    return pdh, pdl, atr


@njit(cache=True)
def _sim(t, o, h, l, c, s, e, pdh, pdl, atr, entry, tf, sl_atr, rr, buf_atr, oco,
         win_a, win_b, retest_max, sides, trail_start, trail_dist, out):
    # out columns: day, side, t_entry, entry, exit, dist, reason(1 SL 2 TP 3 EOD), fill_kind(0 stop/mkt 1 limit), bars_held
    k = 0
    for d in range(len(s)):
        if np.isnan(pdh[d]) or np.isnan(atr[d]) or atr[d] <= 0 or e[d] - s[d] < 60:
            continue
        a = atr[d]
        dist = sl_atr * a
        buf = buf_atr * a
        H = pdh[d] + buf
        L = pdl[d] - buf
        first = s[d]
        last = e[d] - 1
        # which sides are armed: price must open inside the levels
        armL = (sides != 2) and o[first] < H
        armS = (sides != 1) and o[first] > L
        brokeL = -1; brokeS = -1    # bar index of first break (for retest)
        pos = 0; ep = 0.0; sl = 0.0; tp = 0.0; ent_i = -1; kind = 0
        doneL = False; doneS = False
        for i in range(first, last + 1):
            mod = (t[i] % 86400) // 60
            inwin = mod >= win_a and mod < win_b
            # ---- manage open position
            if pos != 0:
                hitSL = (l[i] <= sl) if pos == 1 else (h[i] >= sl)
                hitTP = False
                if tp > 0:
                    hitTP = (h[i] >= tp) if pos == 1 else (l[i] <= tp)
                xp = 0.0; why = 0
                if hitSL:
                    # gap through the stop fills at the open
                    xp = min(o[i], sl) if pos == 1 else max(o[i], sl)
                    if i == ent_i:
                        xp = sl
                    why = 1
                elif hitTP and i != ent_i:
                    xp = max(o[i], tp) if pos == 1 else min(o[i], tp)
                    why = 2
                elif i == last:
                    xp = c[i]; why = 3
                # trailing stop: moved after this bar's exit checks, used from the next bar on
                if why == 0 and trail_start > 0:
                    if pos == 1 and h[i] - ep >= trail_start and h[i] - trail_dist > sl:
                        sl = h[i] - trail_dist
                    if pos == -1 and ep - l[i] >= trail_start and l[i] + trail_dist < sl:
                        sl = l[i] + trail_dist
                if why > 0:
                    out[k, 0] = d; out[k, 1] = pos; out[k, 2] = t[ent_i]; out[k, 3] = ep
                    out[k, 4] = xp; out[k, 5] = dist; out[k, 6] = why; out[k, 7] = kind
                    out[k, 8] = i - ent_i
                    k += 1
                    pos = 0
                    if oco:
                        doneL = True; doneS = True
                continue
            if i == last:
                break
            # ---- entries (only when flat)
            for side in (1, -1):
                if pos != 0:
                    break
                if side == 1 and (not armL or doneL):
                    continue
                if side == -1 and (not armS or doneS):
                    continue
                lvl = H if side == 1 else L
                broke = (h[i] >= lvl) if side == 1 else (l[i] <= lvl)
                fill = False; px = 0.0; kd = 0
                if entry == 0:                     # stop order at the level
                    if broke and inwin:
                        px = max(o[i], lvl) if side == 1 else min(o[i], lvl)
                        fill = True
                    elif broke:
                        if side == 1: doneL = True
                        else: doneS = True
                elif entry == 1:                   # TF candle closes beyond the level
                    endtf = (i + 1 > last) or (t[i + 1] // (tf * 60) != t[i] // (tf * 60))
                    if endtf:
                        beyond = (c[i] > lvl) if side == 1 else (c[i] < lvl)
                        if beyond:
                            if inwin and i + 1 < last:
                                px = o[i + 1]
                                fill = True
                            else:
                                if side == 1: doneL = True
                                else: doneS = True
                else:                              # break then retest (limit at level)
                    bk = brokeL if side == 1 else brokeS
                    if bk < 0:
                        if broke:
                            if side == 1: brokeL = i
                            else: brokeS = i
                    else:
                        back = (l[i] <= lvl) if side == 1 else (h[i] >= lvl)
                        expired = retest_max > 0 and (t[i] - t[bk]) > retest_max * 60
                        if expired:
                            if side == 1: doneL = True
                            else: doneS = True
                        elif back and inwin:
                            px = min(o[i], lvl) if side == 1 else max(o[i], lvl)
                            fill = True; kd = 1
                if fill:
                    ent = i + 1 if entry == 1 else i
                    pos = side; ep = px; ent_i = ent; kind = kd
                    sl = ep - side * dist
                    tp = ep + side * dist * rr if rr > 0 else 0.0
                    if side == 1: doneL = True
                    else: doneS = True
                    if oco:
                        doneL = True; doneS = True
                    if entry == 1:
                        break    # entered at next bar open; managed from next bar
                    # same-bar stop check for stop/limit fills
                    adverse = (l[i] <= sl) if side == 1 else (h[i] >= sl)
                    if adverse:
                        out[k, 0] = d; out[k, 1] = pos; out[k, 2] = t[i]; out[k, 3] = ep
                        out[k, 4] = sl; out[k, 5] = dist; out[k, 6] = 1; out[k, 7] = kind; out[k, 8] = 0
                        k += 1
                        pos = 0
    return k


def run(D, lv, entry=0, tf=60, sl_atr=0.5, rr=1.0, buf_atr=0.0, oco=True, win=(0, 1440),
        retest_max=0, sides=0, cost_mult=1.0, max_rng_atr=0.0, trail=(0.0, 0.0)):
    pdh, pdl, atr = lv
    if max_rng_atr > 0:
        pdh = np.where((pdh - pdl) > max_rng_atr * atr, np.nan, pdh)
    out = np.zeros((2 * len(D["s"]) + 10, 9))
    k = _sim(D["t"], D["o"], D["h"], D["l"], D["c"], D["s"], D["e"], pdh, pdl, atr,
             entry, tf, sl_atr, rr, buf_atr, oco, win[0], win[1], retest_max, sides,
             trail[0] * 1.0, trail[1] * 1.0, out)
    T = pd.DataFrame(out[:k], columns=["d", "side", "te", "ep", "xp", "dist", "why", "kind", "bars"])
    spread, slip = COSTS[D["ins"]]
    gross = T.side * (T.xp - T.ep)
    nslip = (T.kind == 0).astype(float) + (T.why == 1).astype(float)
    cost = T.ep * (spread + slip * nslip) * 1e-4 * cost_mult
    T["Rg"] = gross / T.dist
    T["R"] = (gross - cost) / T.dist
    T["cost_R"] = cost / T.dist
    T["time"] = pd.to_datetime(T.te, unit="s")
    di = T.d.values.astype(int)
    T["rng_atr"] = (pdh[di] - pdl[di]) / atr[di]
    T["hour"] = (T.te.values.astype(np.int64) % 86400) // 3600
    return T


def stats(T, col="R"):
    n = len(T)
    if n == 0:
        return dict(n=0)
    r = T[col].values
    eq = np.cumsum(r)
    dd = np.max(np.maximum.accumulate(np.r_[0, eq]) - np.r_[0, eq])
    win = r[r > 0]; los = r[r <= 0]
    pf = win.sum() / -los.sum() if los.sum() < 0 else np.inf
    yrs = max((T.te.max() - T.te.min()) / (365.25 * 86400), 1e-9)
    srt = np.sort(r)[::-1]
    top = max(1, int(0.05 * n))
    return dict(n=n, per_yr=n / yrs, E=r.mean(), se=r.std(ddof=1) / np.sqrt(n) if n > 1 else np.nan,
                t=r.mean() / (r.std(ddof=1) / np.sqrt(n)) if n > 1 and r.std() > 0 else np.nan,
                win=len(win) / n, avgW=win.mean() if len(win) else 0, avgL=los.mean() if len(los) else 0,
                PF=pf, net=eq[-1], maxDD=dd, RF=eq[-1] / dd if dd > 0 else np.inf,
                E_ex_top5=srt[top:].mean(), Eg=T.Rg.mean(), costR=T.cost_R.mean())
