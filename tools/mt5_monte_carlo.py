#!/usr/bin/env python3
"""
Monte Carlo analysis workbook from an MT5 Strategy Tester .xlsx report.

  Read Me | Summary | Risk Levels | Prop Challenge | Spread Stress | Fan Chart | Histograms | Sim Data

Simulations (fixed seed, so the workbook is reproducible):
  1. Reshuffle   - the same trades in a random order: same profit, different drawdown and streaks.
  2. Bootstrap   - draw the same number of trades with replacement: profit AND drawdown uncertainty.
  3. Risk levels - bootstrap the R multiples and risk a fixed % of balance per trade (compounding).
  4. Prop challenge - bootstrap whole trading days, apply target / daily loss / max loss rules.
  5. Spread stress  - bootstrap with an extra spread cost per trade (the test symbol had zero spread).

Percentiles on Summary / Risk Levels / Spread Stress are formulas over the raw results on 'Sim Data'.

  python3 mt5_monte_carlo.py ReportTester.xlsx  Monte_Carlo.xlsx  [simulations]
"""
import datetime as dt
import sys
from collections import defaultdict

import numpy as np
import openpyxl
from openpyxl.chart import BarChart, LineChart, Reference
from openpyxl.formatting.rule import CellIsRule
from openpyxl.styles import Font, PatternFill
from openpyxl.utils import get_column_letter as CL

from mt5_full_analysis import (BLUE_IN, BOLD, FONT, GREY, HDR_FILL, HDR_FONT, KEY_FILL, NOTE_FILL, PCT, RED_FILL,
                               GREEN_FILL, TITLE, USD, WRAP, contract_value, header, rows_from)
from mt5_report_parse import parse

SEED = 20261016
RISKS = [None, 0.25, 0.5, 1.0, 2.0]          # None = the backtest's own average risk %
PROP_RISKS = [0.25, 0.5, 0.75, 1.0, 1.5]
PCTS = [0.05, 0.25, 0.5, 0.75, 0.95]


def max_dd(bal, start):
    """bal: (sims, n) balances after each trade. Returns max drawdown $ and % of peak per sim."""
    full = np.concatenate([np.full((bal.shape[0], 1), start), bal], axis=1)
    peak = np.maximum.accumulate(full, axis=1)
    dd = peak - full
    return dd.max(axis=1), (dd / peak).max(axis=1)


def longest_loss_streak(p):
    out = np.zeros(p.shape[0], dtype=int)
    cur = np.zeros(p.shape[0], dtype=int)
    for j in range(p.shape[1]):
        cur = np.where(p[:, j] < 0, cur + 1, 0)
        out = np.maximum(out, cur)
    return out


def prop_sim(days, rng, sims, risk, target, daily, maxl, max_days):
    """days: list of per-day R arrays (in close order; empty = no trade). Fixed-fraction risk of current balance.
    Daily loss = closed loss from the start-of-day balance; max loss = static from the initial balance."""
    res = {"pass": 0, "daily": 0, "max": 0, "open": 0}
    pass_days = []
    idx = rng.integers(0, len(days), size=(sims, max_days))
    for s in range(sims):
        bal = 1.0
        outcome = "open"
        for d in range(max_days):
            start = bal
            for r in days[idx[s, d]]:
                bal += bal * risk * r
                if bal <= start * (1 - daily):
                    outcome = "daily"
                    break
                if bal <= 1 - maxl:
                    outcome = "max"
                    break
                if bal >= 1 + target:
                    outcome = "pass"
                    break
            if outcome != "open":
                if outcome == "pass":
                    pass_days.append(d + 1)
                break
        res[outcome] += 1
    return res, pass_days


def build(src, dst, sims=5000):
    info, inputs, results, trades = parse(src)
    rows = rows_from(trades)
    cv = contract_value(rows)
    dep = float(info.get("Initial Deposit") or info.get("Deposit deal") or 100000)
    p = np.array([r["net"] for r in rows])
    risk_usd = np.array([r["sld"] * r["e"]["vol"] * cv for r in rows])
    R = np.where(risk_usd > 0, p / np.where(risk_usd > 0, risk_usd, 1), 0)
    lots = np.array([r["e"]["vol"] for r in rows])
    n = len(p)
    bal_actual = dep + np.cumsum(p)
    act_dd_usd, act_dd_pct = max_dd(bal_actual[None, :], dep)
    act_streak = longest_loss_streak(p[None, :])[0]
    act_risk = float(np.mean(risk_usd / np.concatenate([[dep], bal_actual[:-1]])))
    first, last = rows[0]["e"]["time"].date(), rows[-1]["x"]["time"].date()
    years = max(0.1, (last - first).days / 365.25)
    rng = np.random.default_rng(SEED)

    # 1. reshuffle
    perm = np.argsort(rng.random((sims, n)), axis=1)
    ps = p[perm]
    rs_dd_usd, rs_dd_pct = max_dd(dep + np.cumsum(ps, axis=1), dep)
    rs_streak = longest_loss_streak(ps)
    # 2. bootstrap $
    bi = rng.integers(0, n, size=(sims, n))
    pb = p[bi]
    bb = dep + np.cumsum(pb, axis=1)
    bs_net = pb.sum(axis=1)
    bs_dd_usd, bs_dd_pct = max_dd(bb, dep)
    fan = np.percentile(bb, [5, 25, 50, 75, 95], axis=0)
    # 3. risk levels (compounding, R bootstrap with the same draws)
    rb = R[bi]
    risk_cols = []
    for rk in RISKS:
        f = act_risk if rk is None else rk / 100
        eq = dep * np.cumprod(1 + f * rb, axis=1)
        _, ddp = max_dd(eq, dep)
        risk_cols.append((f, eq[:, -1] / dep - 1, ddp))
    # 5. spread stress (same draws as bootstrap)
    spreads = [1.0, 2.0]
    spread_cols = []
    for sp in spreads:
        cost = sp * lots * cv
        pc = pb - cost[bi]
        _, ddp = max_dd(dep + np.cumsum(pc, axis=1), dep)
        spread_cols.append((sp, pc.sum(axis=1), ddp, float(p.sum() - cost.sum())))
    # 4. prop challenge: bootstrap whole weekdays (days without trades included)
    by_day = defaultdict(list)
    for r_, rw in zip(R, rows):
        by_day[rw["x"]["time"].date()].append(r_)
    d, wdays = first, []
    while d <= last:
        if d.weekday() < 5:
            wdays.append(np.array(by_day.get(d, [])))
        d += dt.timedelta(days=1)
    prop = {}
    for phase, target in (("Phase 1 (8% target)", 0.08), ("Phase 2 (5% target)", 0.05)):
        for rk in PROP_RISKS:
            prop[(phase, rk)] = prop_sim(wdays, rng, min(sims, 2000), rk / 100, target, 0.05, 0.10, 260)

    # ------------------------------------------------------------ workbook
    wb = openpyxl.Workbook()
    sd = wb.active
    sd.title = "Sim Data"
    cols = ["Sim #", "Reshuffle: max DD $", "Reshuffle: max DD %", "Reshuffle: longest losing streak",
            "Bootstrap: net profit $", "Bootstrap: max DD $", "Bootstrap: max DD %"]
    for f, _, _ in risk_cols:
        cols += [f"Risk {100 * f:.2f}%: return", f"Risk {100 * f:.2f}%: max DD %"]
    for sp, *_ in spread_cols:
        cols += [f"Spread {sp:g} pt: net $", f"Spread {sp:g} pt: max DD %"]
    header(sd, 1, cols, [7] + [14] * (len(cols) - 1))
    sd.row_dimensions[1].height = 45
    data = [np.arange(1, sims + 1), rs_dd_usd, rs_dd_pct, rs_streak, bs_net, bs_dd_usd, bs_dd_pct]
    for _, ret, ddp in risk_cols:
        data += [ret, ddp]
    for _, net, ddp, _ in spread_cols:
        data += [net, ddp]
    fmts = ["0", USD, PCT, "0", USD, USD, PCT] + [PCT, PCT] * len(risk_cols) + [USD, PCT] * len(spread_cols)
    for i in range(sims):
        for j, col in enumerate(data):
            c = sd.cell(row=i + 2, column=j + 1, value=round(float(col[i]), 6))
            c.number_format = fmts[j]
    sd.freeze_panes = "B2"
    L = sims + 1
    S = lambda j: f"'Sim Data'!${CL(j)}$2:${CL(j)}${L}"   # noqa: E731

    # ------------------------------------------------------------ Summary
    ws = wb.create_sheet("Summary", 0)
    for c, w in zip("ABCDEFGHI", (3, 44, 14, 14, 14, 14, 14, 16, 60)):
        ws.column_dimensions[c].width = w
    ws["B1"] = "Monte Carlo analysis"
    ws["B1"].font = TITLE
    ws["B2"] = f"{info.get('Expert', '')} | {info.get('Symbol', '')} | {info.get('Period', '')} | {n} trades"
    ws["B3"] = (f"{sims:,} simulations per test (prop challenge: {min(sims, 2000):,}), random seed {SEED}. "
                f"Raw results on 'Sim Data'; the percentiles below are formulas over them.")
    ws["B3"].font = GREY
    ws["B5"], ws["C5"] = "Starting balance", dep
    ws["B6"], ws["C6"] = "Max drawdown limit to test against", 0.10
    for a, f in (("C5", USD), ("C6", PCT)):
        ws[a].font, ws[a].number_format, ws[a].fill = BLUE_IN, f, KEY_FILL
    ws["I5"] = "From the report."
    ws["I6"] = "Change it: the 'chance of reaching it' rows recalculate."
    for a in ("I5", "I6"):
        ws[a].font = GREY

    r = 8
    ws.cell(row=r, column=2, value="1. RESHUFFLE - same trades, random order").font = BOLD
    ws.cell(row=r, column=9, value="Profit is identical in every run; only the ORDER changes. Shows how deep the "
                                   "drawdown and how long the losing streaks could have been with the same trades.").alignment = WRAP
    ws.row_dimensions[r].height = 30
    r += 1
    header(ws, r, ["Metric", "Backtest", "Best 5%", "25%", "Median", "75%", "Worst 5%"], col=2)
    blocks = [
        ("Max drawdown $", float(act_dd_usd[0]), 2, USD, False),
        ("Max drawdown %", float(act_dd_pct[0]), 3, PCT, False),
        ("Longest losing streak (trades)", int(act_streak), 4, "0", False),
    ]

    def pct_rows(r, items):
        for name, actual, j, nf, higher_better in items:
            ws.cell(row=r, column=2, value=name)
            c = ws.cell(row=r, column=3, value=actual)
            c.number_format, c.font = nf, BLUE_IN
            qs = [0.95, 0.75, 0.5, 0.25, 0.05] if higher_better else [0.05, 0.25, 0.5, 0.75, 0.95]
            for k, q in enumerate(qs):
                c = ws.cell(row=r, column=4 + k, value=f"=PERCENTILE({S(j)},{q})")
                c.number_format = nf
            r += 1
        return r

    r = pct_rows(r + 1, blocks)
    ws.cell(row=r, column=2, value="Runs with a deeper drawdown than the backtest")
    ws.cell(row=r, column=3, value=f'=COUNTIF({S(3)},">"&C11)/{sims}').number_format = PCT
    ws.cell(row=r, column=9, value="Low % = the backtest order was unlucky; high % = the backtest was lucky and real "
                                   "drawdowns will likely be deeper.").alignment = WRAP
    r += 1
    ws.cell(row=r, column=2, value="Chance the drawdown reaches the limit (C6)")
    ws.cell(row=r, column=3, value=f'=COUNTIF({S(3)},">="&$C$6)/{sims}').number_format = PCT
    r += 2

    ws.cell(row=r, column=2, value="2. BOOTSTRAP - trades drawn at random with replacement").font = BOLD
    ws.cell(row=r, column=9, value=f"Each run draws {n} trades from the backtest's trades (some twice, some not at all). "
                                   "Shows how much the profit itself could vary over a period of the same length.").alignment = WRAP
    ws.row_dimensions[r].height = 30
    r += 1
    header(ws, r, ["Metric", "Backtest", "Worst 5%", "25%", "Median", "75%", "Best 5%"], col=2)
    r = pct_rows(r + 1, [("Net profit $", float(p.sum()), 5, USD, False)])
    header(ws, r, ["Metric", "Backtest", "Best 5%", "25%", "Median", "75%", "Worst 5%"], col=2)
    r = pct_rows(r + 1, [("Max drawdown $", float(act_dd_usd[0]), 6, USD, False),
                         ("Max drawdown %", float(act_dd_pct[0]), 7, PCT, False)])
    rb_net = r
    ws.cell(row=r, column=2, value="Chance of ending with a loss")
    ws.cell(row=r, column=3, value=f'=COUNTIF({S(5)},"<0")/{sims}').number_format = PCT
    r += 1
    ws.cell(row=r, column=2, value="Chance the drawdown reaches the limit (C6)")
    ws.cell(row=r, column=3, value=f'=COUNTIF({S(7)},">="&$C$6)/{sims}').number_format = PCT
    r += 2

    ws.cell(row=r, column=2, value="FINDINGS").font = TITLE
    loss_p = float((bs_net < 0).mean())
    best_risk = None
    for f, ret, ddp in risk_cols[1:]:
        if np.percentile(ddp, 95) < 0.10:
            best_risk = (f, ret, ddp)
    p1 = {rk: prop[("Phase 1 (8% target)", rk)][0] for rk in PROP_RISKS}
    tot1 = min(sims, 2000)
    best_prop = max(PROP_RISKS, key=lambda k: p1[k]["pass"])
    notes = [
        f"1. Order luck: the backtest's max drawdown {act_dd_pct[0]:.2%} vs a median of {np.median(rs_dd_pct):.2%} and a "
        f"worst-5% of {np.percentile(rs_dd_pct, 95):.2%} when the same trades are reshuffled. "
        f"{(rs_dd_pct > act_dd_pct[0]).mean():.0%} of orders give a deeper drawdown. Plan for the worst-5% figure, not the backtest's.",
        f"2. Profit uncertainty: over {n} trades (~{years:.1f} years) the net profit ranges from "
        f"${np.percentile(bs_net, 5):,.0f} (worst 5%) to ${np.percentile(bs_net, 95):,.0f} (best 5%), median "
        f"${np.median(bs_net):,.0f}. Chance of a net loss over the whole period: {loss_p:.1%}.",
        f"3. Losing streaks: expect up to {int(np.percentile(rs_streak, 95))} losses in a row (worst 5%), the backtest had "
        f"{act_streak}. With a 32% win rate long streaks are normal, not a sign the EA is broken.",
        f"4. Risk per trade: the backtest risked only {act_risk:.2%} per trade. "
        + (f"At {100 * best_risk[0]:.2f}% the median return over the period is {np.median(best_risk[1]):.0%} with a worst-5% "
           f"drawdown of {np.percentile(best_risk[2], 95):.1%} - the highest tested level that stays under 10%. "
           if best_risk else "")
        + "See 'Risk Levels'.",
        f"5. Prop challenge (8% target, 5% daily, 10% max, max 260 trading days): pass rate "
        + ", ".join(f"{p1[k]['pass'] / tot1:.0%} at {k:g}%" for k in PROP_RISKS)
        + f". Best: {best_prop:g}% risk. See 'Prop Challenge' for fail reasons and days needed.",
        f"6. Spread: this test ran on a zero-spread symbol. Paying {spread_cols[0][0]:g} point per trade would cut the net "
        f"profit to ${spread_cols[0][3]:,.0f}, {spread_cols[1][0]:g} points to ${spread_cols[1][3]:,.0f} "
        f"(from ${p.sum():,.0f}). Test the EA on the broker's real-spread symbol before trusting these numbers.",
    ]
    for t in notes:
        r += 1
        ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=9)
        c = ws.cell(row=r, column=2, value=t)
        c.alignment = WRAP
        ws.row_dimensions[r].height = 45

    # ------------------------------------------------------------ Risk Levels
    wr = wb.create_sheet("Risk Levels", 1)
    for c, w in zip("ABCDEFGHIJ", (34, 13, 13, 13, 13, 13, 13, 14, 14, 50)):
        wr.column_dimensions[c].width = w
    wr["A1"] = "What if the EA risked a different % per trade? (compounding, bootstrap of R multiples)"
    wr["A1"].font = TITLE
    wr["A2"] = (f"Each run draws {n} trades' R multiples (~{years:.1f} years) and risks a fixed % of the CURRENT balance "
                f"per trade. The first row is the backtest's own average risk ({act_risk:.2%}).")
    wr["A2"].font = GREY
    header(wr, 4, ["Risk per trade", "Return: worst 5%", "25%", "Median", "75%", "Best 5%", "Max DD: median",
                   "Max DD: worst 5%", "Chance DD >= limit", "Note"])
    for i, (f, _, _) in enumerate(risk_cols):
        r = 5 + i
        jr, jd = 8 + 2 * i, 9 + 2 * i
        c = wr.cell(row=r, column=1, value=f)
        c.number_format, c.font = PCT, BLUE_IN
        for k, q in enumerate([0.05, 0.25, 0.5, 0.75, 0.95]):
            wr.cell(row=r, column=2 + k, value=f"=PERCENTILE({S(jr)},{q})").number_format = '0.0%;[Red]-0.0%'
        wr.cell(row=r, column=7, value=f"=PERCENTILE({S(jd)},0.5)").number_format = PCT
        wr.cell(row=r, column=8, value=f"=PERCENTILE({S(jd)},0.95)").number_format = PCT
        wr.cell(row=r, column=9, value=f'=COUNTIF({S(jd)},">="&Summary!$C$6)/{sims}').number_format = PCT
        wr.cell(row=r, column=10, value=f'=IF(H{r}<Summary!$C$6/2,"Comfortable",IF(H{r}<Summary!$C$6,"Tight","Too risky"))')
    wr.conditional_formatting.add("I5:I9", CellIsRule(operator="greaterThan", formula=["0.05"], fill=RED_FILL))
    wr.conditional_formatting.add("I5:I9", CellIsRule(operator="lessThanOrEqual", formula=["0.05"], fill=GREEN_FILL))
    wr["A11"] = "Return = over the whole simulated period, not per year. Max DD is measured on the closed balance."
    wr["A11"].font = GREY

    # ------------------------------------------------------------ Prop Challenge
    wp = wb.create_sheet("Prop Challenge", 2)
    for c, w in zip("ABCDEFGHIJ", (22, 12, 11, 13, 13, 13, 14, 14, 14, 40)):
        wp.column_dimensions[c].width = w
    wp["A1"] = "Prop-firm challenge simulation"
    wp["A1"].font = TITLE
    wp["A2"] = (f"{tot1:,} challenges per row. Each simulated day is a random weekday from the backtest (with all its "
                f"trades, or none). Rules: profit target, 5% daily loss from the start-of-day balance, 10% max loss from "
                f"the initial balance, at most 260 trading days. Values computed by the simulation.")
    wp["A2"].font = GREY
    wp.merge_cells("A2:J2")
    wp["A2"].alignment = WRAP
    wp.row_dimensions[2].height = 45
    header(wp, 4, ["Phase", "Risk per trade", "Pass", "Failed: daily loss", "Failed: max loss", "Not finished",
                   "Days to pass: median", "Days: fastest 25%", "Days: slowest 25%", "Verdict"])
    r = 5
    for (phase, rk), (res, pdays) in prop.items():
        vals = [phase, rk / 100, res["pass"] / tot1, res["daily"] / tot1, res["max"] / tot1, res["open"] / tot1,
                float(np.median(pdays)) if pdays else "", float(np.percentile(pdays, 25)) if pdays else "",
                float(np.percentile(pdays, 75)) if pdays else ""]
        for k, v in enumerate(vals, 1):
            c = wp.cell(row=r, column=k, value=v)
            c.font = BLUE_IN
            c.number_format = PCT if k in (2, 3, 4, 5, 6) else "0"
        wp.cell(row=r, column=10, value=f'=IF(C{r}>=0.7,"Good odds",IF(C{r}>=0.5,"Coin flip +","Poor odds"))')
        r += 1
    wp.conditional_formatting.add(f"C5:C{r - 1}", CellIsRule(operator="greaterThanOrEqual", formula=["0.7"], fill=GREEN_FILL))
    wp.conditional_formatting.add(f"C5:C{r - 1}", CellIsRule(operator="lessThan", formula=["0.5"], fill=RED_FILL))
    wp.cell(row=r + 1, column=1, value="Days are trading days (weekdays), including days without a trade.").font = GREY

    # ------------------------------------------------------------ Spread Stress
    wsp = wb.create_sheet("Spread Stress", 3)
    for c, w in zip("ABCDEFGHI", (30, 14, 14, 14, 14, 14, 14, 16, 16)):
        wsp.column_dimensions[c].width = w
    wsp["A1"] = "What if every trade paid a spread? (bootstrap with a cost per trade)"
    wsp["A1"].font = TITLE
    wsp["A2"] = f"Cost per trade = spread points x lots x ${cv:g} per point per lot. Same random draws as the bootstrap."
    wsp["A2"].font = GREY
    header(wsp, 4, ["Spread (points)", "Net if the backtest paid it", "Net: worst 5%", "25%", "Median", "75%",
                    "Best 5%", "Chance of a loss", "Max DD: worst 5%"])
    wsp.cell(row=5, column=1, value=0).font = BLUE_IN
    wsp.cell(row=5, column=2, value=float(p.sum())).font = BLUE_IN
    jcols = [(5, 7)] + [(8 + 2 * len(risk_cols) + 2 * i, 9 + 2 * len(risk_cols) + 2 * i) for i in range(len(spread_cols))]
    for i, (jn, jd) in enumerate(jcols):
        r = 5 + i
        if i:
            wsp.cell(row=r, column=1, value=spread_cols[i - 1][0]).font = BLUE_IN
            wsp.cell(row=r, column=2, value=round(spread_cols[i - 1][3], 2)).font = BLUE_IN
        wsp.cell(row=r, column=2).number_format = USD
        for k, q in enumerate([0.05, 0.25, 0.5, 0.75, 0.95]):
            wsp.cell(row=r, column=3 + k, value=f"=PERCENTILE({S(jn)},{q})").number_format = USD
        wsp.cell(row=r, column=8, value=f'=COUNTIF({S(jn)},"<0")/{sims}').number_format = PCT
        wsp.cell(row=r, column=9, value=f"=PERCENTILE({S(jd)},0.95)").number_format = PCT
    wsp["A9"] = (f"Average lot size {lots.mean():.2f}: each 1 point of spread costs about ${lots.mean() * cv:.2f} per trade, "
                 f"${lots.sum() * cv:,.0f} over all {n} trades.")
    wsp["A9"].font = GREY

    # ------------------------------------------------------------ Fan chart
    wf = wb.create_sheet("Fan Chart", 4)
    header(wf, 1, ["Trade #", "Backtest", "Worst 5%", "25%", "Median", "75%", "Best 5%"], [8, 13, 13, 13, 13, 13, 13])
    step = max(1, n // 300)
    idxs = list(range(0, n, step)) + ([n - 1] if (n - 1) % step else [])
    for i, k in enumerate(idxs):
        vals = [k + 1, float(bal_actual[k])] + [float(fan[q][k]) for q in range(5)]
        for j, v in enumerate(vals, 1):
            c = wf.cell(row=i + 2, column=j, value=round(v, 2))
            c.font = BLUE_IN
            if j > 1:
                c.number_format = USD
    lf = len(idxs) + 1
    lc = LineChart()
    lc.title = "Balance: backtest vs bootstrap percentile bands"
    lc.height, lc.width = 12, 28
    lc.add_data(Reference(wf, min_col=2, max_col=7, min_row=1, max_row=lf), titles_from_data=True)
    lc.set_categories(Reference(wf, min_col=1, min_row=2, max_row=lf))
    colors = ["1F3A5F", "EB6834", "9DB9E0", "2A78D6", "9DB9E0", "3BA55C"]
    for s_, col in zip(lc.series, colors):
        s_.graphicalProperties.line.solidFill = col
        s_.smooth = False
    lc.y_axis.numFmt = "$#,##0"
    lc.y_axis.majorGridlines = None
    lc.x_axis.title = "Trade #"
    lc.y_axis.delete = lc.x_axis.delete = False
    lc.x_axis.tickLblSkip = max(1, lf // 15)
    wf.add_chart(lc, "I2")

    # ------------------------------------------------------------ Histograms (formulas)
    wh = wb.create_sheet("Histograms", 5)
    wh["A1"] = "How often each result came up"
    wh["A1"].font = TITLE

    def hist(top, col, j, lo, hi, nb, nf, title, label):
        header(wh, top, [label, "Runs", "Share"], col=col)
        width = (hi - lo) / nb
        for b in range(nb):
            r = top + 1 + b
            a, z = lo + b * width, lo + (b + 1) * width
            c = wh.cell(row=r, column=col, value=a)
            c.number_format = nf
            crit = f'{S(j)},">="&{CL(col)}{r}' + (f',{S(j)},"<"&{CL(col)}{r + 1}' if b < nb - 1 else "")
            wh.cell(row=r, column=col + 1, value=f"=COUNTIFS({crit})")
            wh.cell(row=r, column=col + 2, value=f"={CL(col + 1)}{r}/{sims}").number_format = PCT
        bc = BarChart()
        bc.title, bc.legend = title, None
        bc.height, bc.width = 8, 18
        bc.add_data(Reference(wh, min_col=col + 1, min_row=top, max_row=top + nb), titles_from_data=True)
        bc.set_categories(Reference(wh, min_col=col, min_row=top + 1, max_row=top + nb))
        bc.series[0].graphicalProperties.solidFill = "2A78D6"
        bc.y_axis.majorGridlines = None
        bc.y_axis.delete = bc.x_axis.delete = False
        bc.gapWidth = 20
        return bc

    lo, hi = float(np.floor(rs_dd_pct.min() * 200) / 200), float(np.ceil(rs_dd_pct.max() * 200) / 200)
    wh.add_chart(hist(3, 1, 3, lo, hi, 20, "0.00%", "Reshuffle: max drawdown %", "Max DD % from"), "E3")
    lo2, hi2 = float(np.floor(bs_net.min() / 1000) * 1000), float(np.ceil(bs_net.max() / 1000) * 1000)
    wh.add_chart(hist(27, 1, 5, lo2, hi2, 20, '$#,##0;[Red]-$#,##0', "Bootstrap: net profit $", "Net $ from"), "E27")
    for c, w in zip("ABC", (14, 8, 8)):
        wh.column_dimensions[c].width = w

    # ------------------------------------------------------------ Read Me
    wrm = wb.create_sheet("Read Me", 0)
    wrm.column_dimensions["A"].width = 20
    wrm.column_dimensions["B"].width = 110
    wrm["A1"] = "Monte Carlo analysis: how to read it"
    wrm["A1"].font = TITLE
    lines = [
        ("Why", "A backtest is ONE path. Monte Carlo replays the same trades thousands of times in other orders and "
                "combinations to show the range of drawdowns, streaks and profits you could realistically get."),
        ("Summary", "Reshuffle and bootstrap results with percentiles, and the main findings."),
        ("Risk Levels", "Return and drawdown if the EA risked 0.25% / 0.5% / 1% / 2% of balance per trade."),
        ("Prop Challenge", "Pass / fail rates for an 8% (phase 1) and 5% (phase 2) target with 5% daily and 10% max loss."),
        ("Spread Stress", "The same simulation with 1 and 2 points of spread cost per trade."),
        ("Fan Chart", "The backtest balance against the 5/25/50/75/95% bands of the bootstrap."),
        ("Histograms", "Distribution of max drawdown and of net profit."),
        ("Sim Data", "One row per simulation run (raw results). The percentile formulas read from here."),
        ("", ""),
        ("Percentiles", "Worst 5% = 1 run in 20 was worse than this. Median = half the runs were better, half worse."),
        ("Limits", "Monte Carlo assumes future trades look like the backtest's trades and are independent of each other. "
                   "It cannot show risks the backtest never contained (regime change, real spread, slippage, outages)."),
        ("Colours", "Blue = values from the simulation or the report. Black = formulas. Yellow = inputs you may change."),
    ]
    for i, (a, b) in enumerate(lines, 3):
        wrm.cell(row=i, column=1, value=a).font = BOLD
        c = wrm.cell(row=i, column=2, value=b)
        c.alignment = WRAP

    for sh in wb.worksheets:
        for row in sh.iter_rows():
            for c in row:
                if c.font is None or c.font.name != FONT:
                    c.font = Font(name=FONT, bold=c.font.bold, italic=c.font.italic, color=c.font.color,
                                  size=c.font.size)
    wb.active = 1
    wb.save(dst)
    return notes


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = build(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 5000)
    print("\n".join(out))
