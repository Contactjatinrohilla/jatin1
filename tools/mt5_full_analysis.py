#!/usr/bin/env python3
"""
Full analysis workbook from an MT5 Strategy Tester .xlsx report (any symbol, market or pending orders).

  Read Me | Summary | Yearly | Monthly | Calendar | Weekly | Daily | Trades | Breakdown |
  Drawdowns & Streaks | MT5 Report | Settings

Every trade = one row (entry deal matched to its exit deal). Yearly / monthly / weekly / daily
tables and breakdowns are live formulas over the Trades sheet. P&L is booked on the CLOSE date
(that is when the balance changes and what prop-firm daily loss limits use).

  python3 mt5_full_analysis.py ReportTester.xlsx  Full_Analysis.xlsx  [daily_loss_pct] [max_dd_pct]
"""
import datetime as dt
import statistics as st
import sys
from collections import defaultdict

import openpyxl
from openpyxl.chart import BarChart, LineChart, Reference
from openpyxl.chart.series import DataPoint
from openpyxl.chart.shapes import GraphicalProperties
from openpyxl.comments import Comment
from openpyxl.formatting.rule import ColorScaleRule, CellIsRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter as CL
from openpyxl.worksheet.table import Table, TableStyleInfo

from mt5_report_parse import parse

FONT = "Arial"
BLUE_IN = Font(name=FONT, color="0000FF")
BOLD = Font(name=FONT, bold=True)
NORMAL = Font(name=FONT)
TITLE = Font(name=FONT, bold=True, size=14)
GREY = Font(name=FONT, italic=True, color="595959")
HDR_FILL = PatternFill("solid", start_color="1F3A5F")
HDR_FONT = Font(name=FONT, bold=True, color="FFFFFF")
NOTE_FILL = PatternFill("solid", start_color="F2F2F2")
KEY_FILL = PatternFill("solid", start_color="FFFF00")
RED_FILL = PatternFill("solid", start_color="F8CBAD")
GREEN_FILL = PatternFill("solid", start_color="C6EFCE")
THIN = Border(bottom=Side(style="thin", color="BFBFBF"))
WRAP = Alignment(wrap_text=True, vertical="top")

USD = '$#,##0.00;[Red]-$#,##0.00;"-"'
PCT = '0.00%;[Red]-0.00%;"-"'
RFMT = '0.00"R";[Red]-0.00"R";"0R"'
PTS = '0.00;[Red]-0.00;"-"'
DTF = "yyyy-mm-dd hh:mm:ss"
DF = "yyyy-mm-dd"
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


def header(ws, row, names, widths=None, col=1):
    for i, n in enumerate(names, col):
        c = ws.cell(row=row, column=i, value=n)
        c.font, c.fill = HDR_FONT, HDR_FILL
        c.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
    if widths:
        for i, w in enumerate(widths, col):
            ws.column_dimensions[CL(i)].width = w
    ws.row_dimensions[row].height = 32


def exit_reason(x, o, e):
    c = x["comment"] or ""
    if c.startswith("tp"):
        return "Take profit"
    if not c.startswith("sl "):
        return "Closed by EA (guard)"
    stop = float(c[3:])
    tol = max(0.011, abs(e["price"]) * 1e-6)
    if o.get("sl") and abs(stop - o["sl"]) <= tol:
        return "Initial stop loss"
    buy = e["type"] == "buy"
    if abs(stop - e["price"]) <= tol or (buy and stop > e["price"]) or (not buy and stop < e["price"]):
        return "Breakeven stop"
    return "Moved stop (loss side)"


def rows_from(trades):
    out = []
    for t in trades:
        e, x, o = t["entry"], t["exit"], t["order"]
        buy = e["type"] == "buy"
        net = x["profit"] + x["swap"] + x["comm"] + e["comm"]
        mv = (x["price"] - e["price"]) * (1 if buy else -1)
        out.append(dict(e=e, x=x, o=o, buy=buy, net=round(net, 2), gross=x["profit"], comm=x["comm"] + e["comm"],
                        swap=x["swap"], mv=mv, sld=abs(e["price"] - o["sl"]) if o.get("sl") else 0,
                        tpd=abs(o["tp"] - e["price"]) if o.get("tp") else 0, why=exit_reason(x, o, e)))
    return out


def contract_value(rows):
    """$ per 1.00 point per 1.00 lot, read from the trades themselves."""
    v = [r["gross"] / (r["mv"] * r["e"]["vol"]) for r in rows if abs(r["mv"]) > 0.5 and r["e"]["vol"]]
    return round(st.median(v), 4) if v else 1.0


def drawdowns(rows, deposit):
    """Closed-trade drawdown periods: peak, trough, recovery."""
    bal, peak, peak_t = deposit, deposit, None
    periods, cur = [], None
    for r in rows:
        bal += r["net"]
        t = r["x"]["time"]
        if bal >= peak:
            if cur:
                cur["recovered"] = t
                periods.append(cur)
                cur = None
            peak, peak_t = bal, t
        else:
            dd = peak - bal
            if not cur:
                cur = dict(start=peak_t, peak=peak, depth=0, trough=None, trades=0, recovered=None)
            cur["trades"] += 1
            if dd > cur["depth"]:
                cur["depth"], cur["trough"], cur["trough_bal"] = dd, t, bal
    if cur:
        periods.append(cur)
    return sorted(periods, key=lambda p: -p["depth"])


def streaks(rows):
    best = dict(win=(0, 0.0, None), loss=(0, 0.0, None))
    n, s, kind, start = 0, 0.0, None, None
    for r in rows:
        k = "win" if r["net"] > 0 else "loss" if r["net"] < 0 else None
        if k and k == kind:
            n, s = n + 1, s + r["net"]
        else:
            n, s, kind, start = (1, r["net"], k, r["x"]["time"]) if k else (0, 0.0, None, None)
        if k and n > best[k][0]:
            best[k] = (n, s, start)
    return best


def notes(rows, deposit, cv, daily_lim, dd_lim, inputs=()):
    n = len(rows)
    net = sum(r["net"] for r in rows)
    wins = [r for r in rows if r["net"] > 0]
    losses = [r for r in rows if r["net"] < 0]
    gp, gl = sum(r["net"] for r in wins), -sum(r["net"] for r in losses)
    risk = lambda r: r["sld"] * r["e"]["vol"] * cv  # noqa: E731
    R = [r["net"] / risk(r) for r in rows if risk(r)]
    by = defaultdict(list)
    for r in rows:
        by[r["why"]].append(r)
    out = [f"1. Result: {n} trades, net ${net:,.0f} ({100 * net / deposit:.1f}% on ${deposit:,.0f}), profit factor "
           f"{gp / gl if gl else 0:.2f}, win rate {100 * len(wins) / n:.1f}%, average {st.mean(R):+.3f}R per trade."]
    out.append("2. Exits: " + " | ".join(f"{k} {len(v)} ({100 * len(v) / n:.0f}%), net ${sum(r['net'] for r in v):,.0f}"
                                         for k, v in sorted(by.items(), key=lambda kv: -len(kv[1]))) + ".")
    be = by.get("Breakeven stop", [])
    if be:
        out.append(f"3. Breakeven stops: {len(be)} trades ({100 * len(be) / n:.0f}%) reached +1R then came back to entry; "
                   f"together they cost ${-sum(r["net"] for r in be):,.0f} (exit slippage, swap, commission). They are counted as "
                   f"losses by MT5, which is why the win rate looks low while the system is profitable.")
    sl = by.get("Initial stop loss", [])
    if sl:
        slR = [r["net"] / risk(r) for r in sl if risk(r)]
        out.append(f"4. Full stop losses average {st.mean(slR):.2f}R (worst {min(slR):.2f}R). Take profits average "
                   f"{st.mean([r['net'] / risk(r) for r in by.get('Take profit', []) if risk(r)] or [0]):.2f}R.")
    day = defaultdict(float)
    for r in rows:
        day[r["x"]["time"].date()] += r["net"]
    worst_d = min(day, key=day.get)
    month = defaultdict(float)
    for r in rows:
        month[r["x"]["time"].strftime("%Y-%m")] += r["net"]
    up_m = sum(v > 0 for v in month.values())
    out.append(f"5. {len(day)} trading days, {100 * sum(v > 0 for v in day.values()) / len(day):.0f}% of them green; "
               f"worst day {worst_d} ${day[worst_d]:,.0f}; {up_m} of {len(month)} months profitable; best month "
               f"{max(month, key=month.get)} (${max(month.values()):,.0f}), worst {min(month, key=month.get)} "
               f"(${min(month.values()):,.0f}).")
    dds = drawdowns(rows, deposit)
    if dds:
        d = dds[0]
        out.append(f"6. Deepest closed-trade drawdown ${d['depth']:,.0f} ({100 * d['depth'] / d['peak']:.2f}% of the peak), "
                   f"from {d['start']:%Y-%m-%d} to the low on {d['trough']:%Y-%m-%d}"
                   + (f", recovered {d['recovered']:%Y-%m-%d}." if d["recovered"] else ", not recovered by the end.")
                   + f" Max limit used here: {dd_lim:.0%} - "
                   + ("far away." if d["depth"] / d["peak"] < dd_lim / 2 else
                      "close to it." if d["depth"] / d["peak"] < dd_lim else "BREACHED."))
    side = defaultdict(float)
    for r in rows:
        side["BUY" if r["buy"] else "SELL"] += r["net"]
    hr = defaultdict(float)
    for r in rows:
        hr[r["e"]["time"].hour] += r["net"]
    bh = sorted(hr, key=hr.get)
    out.append(f"7. Longs ${side['BUY']:,.0f} vs shorts ${side['SELL']:,.0f}. Best entry hours (server): "
               + ", ".join(f"{h:02d}:00 ${hr[h]:,.0f}" for h in bh[::-1][:3]) + "; worst: "
               + ", ".join(f"{h:02d}:00 ${hr[h]:,.0f}" for h in bh[:3]) + ".")
    holds = [(r["x"]["time"] - r["e"]["time"]).total_seconds() / 60 for r in rows]
    out.append(f"8. Median hold {st.median(holds):.0f} min, {sum(h < 1 for h in holds)} trades closed within 1 minute "
               f"(those are mostly decided by noise/spread). Commission total ${sum(r['comm'] for r in rows):,.2f}, "
               f"swap ${sum(r['swap'] for r in rows):,.2f}.")
    top = bh[-1]
    rest = [r for r in rows if r["e"]["time"].hour != top]
    rgp = sum(r["net"] for r in rest if r["net"] > 0)
    rgl = -sum(r["net"] for r in rest if r["net"] < 0)
    out.append(f"9. Concentration: entries in the {top:02d}:00 server hour made ${hr[top]:,.0f} = {100 * hr[top] / net:.0f}% "
               f"of the total profit from {n - len(rest)} trades. All other hours together: {len(rest)} trades, net "
               f"${net - hr[top]:,.0f}, profit factor {rgp / rgl if rgl else 0:.2f}. Check that this hour is tradable "
               f"live (session open gaps, spread on this zero-spread test symbol).")
    rp = st.mean(risk(r) / (deposit + sum(x["net"] for x in rows[:i])) for i, r in enumerate(rows))
    want = next((float(v.split("=", 1)[1]) for v in inputs if isinstance(v, str) and v.startswith("RiskPercent=")), None)
    if want:
        out.append(f"10. Position size: the trades risked {100 * rp:.2f}% of balance on average (SL distance x lots x "
                   f"${cv:g}), while RiskPercent = {want:g}%. "
                   + ("The EA sizes positions much smaller than the setting - check its tick value / lot step / "
                      "margin cap on this symbol; returns and drawdowns scale with it." if rp * 100 < want * 0.7 else
                      "That matches the setting."))
    return out


def build(src, dst, daily_lim=0.025, dd_lim=0.10):
    info, inputs, results, trades = parse(src)
    rows = rows_from(trades)
    deposit = float(info.get("Initial Deposit") or info.get("Deposit deal") or 0)
    cv = contract_value(rows)
    sym = info.get("Symbol", "")
    wb = openpyxl.Workbook()
    n = len(rows)
    last = n + 1

    # ------------------------------------------------------------ Trades
    wt = wb.active
    wt.title = "Trades"
    cols = ["#", "Entry time", "Close time", "Close date", "Week (Mon)", "Month", "Year", "Weekday", "Entry hour",
            "Side", "Setup", "Lots", "Entry price", "Initial SL", "Take profit", "SL distance (pts)",
            "TP distance (pts)", "Planned risk $", "Exit price", "Exit reason", "Points made", "Commission $",
            "Swap $", "Net profit $", "R multiple", "Result", "Hold (min)", "Hold bucket", "SL bucket (pts)",
            "Balance after", "Peak balance", "Drawdown $", "Drawdown %"]
    header(wt, 1, cols, [5, 18, 18, 11, 11, 8, 6, 8, 6, 6, 13, 6, 11, 11, 11, 9, 9, 10, 11, 20, 9, 10, 8, 11, 9, 7,
                         8, 11, 11, 12, 12, 10, 9])
    wt.row_dimensions[1].height = 45
    for i, rw in enumerate(rows, 1):
        e, x, o = rw["e"], rw["x"], rw["o"]
        r = i + 1
        ct = x["time"]
        vals = {
            1: i, 2: e["time"], 3: ct, 4: f"=INT(C{r})", 5: f"=D{r}-WEEKDAY(D{r},3)", 6: ct.strftime("%Y-%m"),
            7: ct.year, 8: WEEKDAYS[e["time"].weekday()], 9: e["time"].hour, 10: "BUY" if rw["buy"] else "SELL",
            11: e["comment"], 12: e["vol"], 13: e["price"], 14: o.get("sl"), 15: o.get("tp"),
            16: f"=ABS(M{r}-N{r})", 17: f'=IF(O{r}="","",ABS(O{r}-M{r}))', 18: f"=P{r}*L{r}*Summary!$C$6",
            19: x["price"], 20: rw["why"], 21: f'=IF(J{r}="BUY",S{r}-M{r},M{r}-S{r})', 22: round(rw["comm"], 2),
            23: round(rw["swap"], 2), 24: rw["net"], 25: f"=IFERROR(X{r}/R{r},0)",
            26: f'=IF(X{r}>0,"Win",IF(X{r}<0,"Loss","Flat"))', 27: f"=ROUND((C{r}-B{r})*1440,1)",
            28: f'=IF(AA{r}<1,"a) <1 min",IF(AA{r}<10,"b) 1-10 min",IF(AA{r}<60,"c) 10-60 min",'
                f'IF(AA{r}<240,"d) 1-4 h","e) 4 h+"))))',
            29: f'=IF(P{r}<10,"a) <10",IF(P{r}<20,"b) 10-20",IF(P{r}<40,"c) 20-40",IF(P{r}<80,"d) 40-80","e) 80+"))))',
            30: f"=Summary!$C$5+SUM(X$2:X{r})",
            31: f"=MAX(Summary!$C$5,AD{r})" if r == 2 else f"=MAX(AE{r - 1},AD{r})",
            32: f"=AE{r}-AD{r}", 33: f"=IFERROR(AF{r}/AE{r},0)",
        }
        for c, v in vals.items():
            wt.cell(row=r, column=c, value=v).font = NORMAL
        for c in (22, 23, 24):
            wt.cell(row=r, column=c).font = BLUE_IN
        for c in (2, 3):
            wt.cell(row=r, column=c).number_format = DTF
        for c in (4, 5):
            wt.cell(row=r, column=c).number_format = DF
        for c in (13, 14, 15, 19):
            wt.cell(row=r, column=c).number_format = "0.00"
        for c in (16, 17, 21):
            wt.cell(row=r, column=c).number_format = PTS
        for c in (18, 22, 23, 24, 30, 31, 32):
            wt.cell(row=r, column=c).number_format = USD
        wt.cell(row=r, column=25).number_format = RFMT
        wt.cell(row=r, column=33).number_format = PCT
    wt.freeze_panes = "C2"
    tab = Table(displayName="TradeList", ref=f"A1:{CL(len(cols))}{last}")
    tab.tableStyleInfo = TableStyleInfo(name="TableStyleLight9", showRowStripes=True)
    wt.add_table(tab)
    wt["X1"].comment = Comment("Profit + commission + swap from the MT5 deals list (blue = source data).", "report")
    wt["Y1"].comment = Comment("Net profit / planned risk (SL distance x lots x $ per point per lot).", "report")
    wt["T1"].comment = Comment("Take profit = TP hit. Initial stop loss = SL at its original level. Breakeven stop = SL "
                               "had been moved to entry or beyond. Moved stop (loss side) = SL moved but still below "
                               "entry.", "report")
    T = lambda col: f"Trades!${col}$2:${col}${last}"   # noqa: E731
    NET = T("X")

    days = sorted({r["x"]["time"].date() for r in rows})
    weeks = sorted({r["x"]["time"].date() - dt.timedelta(days=r["x"]["time"].weekday()) for r in rows})
    months = sorted({r["x"]["time"].strftime("%Y-%m") for r in rows})
    years = sorted({r["x"]["time"].year for r in rows})
    nd, nwk = len(days), len(weeks)
    DF_, MF_ = f"Daily!F2:F{nd + 1}", f"Monthly!F2:F{len(months) + 1}"

    # ------------------------------------------------------------ Summary
    ws = wb.create_sheet("Summary", 0)
    for c, w in zip("ABCDEF", (3, 40, 16, 18, 16, 70)):
        ws.column_dimensions[c].width = w
    ws["B1"] = "Backtest analysis"
    ws["B1"].font = TITLE
    ws["B2"] = f"{info.get('Expert', '')} | {sym} | {info.get('Period', '')} | {results.get('History Quality', '')}"
    ws["B3"] = "Blue cells are inputs: change them and every sheet recalculates."
    ws["B3"].font = GREY
    if "pips" in str(info.get("Currency", "")).lower():
        ws["B4"] = ("WARNING: this test ran with 'Profit in pips' - every $ figure (MT5's and this workbook's) is in pip "
                    "units, not account money. R multiples, win rate, profit factor and counts are still valid.")
        ws["B4"].font = Font(name=FONT, bold=True, color="C00000")
    inp = [("Starting balance", deposit, USD, "From the report (Initial Deposit)."),
           ("$ per 1.00 point per 1.00 lot", cv, "0.00",
            f"Measured from the trades (profit / points / lots, median). {sym}: 1 lot moving 1 point = ${cv:g}."),
           ("Daily loss limit (prop rule)", daily_lim, PCT, "Used for the breach checks on Daily. Matches the EA input DailyLossPct when present."),
           ("Max drawdown limit (prop rule)", dd_lim, PCT, "Typical prop-firm overall limit.")]
    for i, (k, v, f, note) in enumerate(inp, 5):
        ws.cell(row=i, column=2, value=k)
        c = ws.cell(row=i, column=3, value=v)
        c.font, c.number_format, c.fill = BLUE_IN, f, KEY_FILL
        ws.cell(row=i, column=6, value=note).font = GREY
    hr = 10
    for i, h in enumerate(["Metric", "Value", "MT5 report", "Verdict", "What it means"], 2):
        c = ws.cell(row=hr, column=i, value=h)
        c.font, c.fill = HDR_FONT, HDR_FILL
    res = lambda k: results.get(k, "")  # noqa: E731
    m = [
        ("RESULT",),
        ("Net profit", f"=SUM({NET})", USD, res("Total Net Profit"), '=IF(C12>0,"Profitable","Losing")',
         "Total money made over the whole test, after commission and swap."),
        ("Final balance", "=C5+C12", USD, "", "", ""),
        ("Return on starting balance", "=IFERROR(C12/C5,0)", PCT, "", "", ""),
        ("Gross profit", f'=SUMIF({NET},">0")', USD, res("Gross Profit"), "", "Sum of all winning trades."),
        ("Gross loss", f'=SUMIF({NET},"<0")', USD, res("Gross Loss"), "", "Sum of all losing trades."),
        ("Profit factor", "=IFERROR(C15/-C16,0)", "0.00", res("Profit Factor"),
         '=IF(C17>=1.5,"Strong",IF(C17>=1.2,"Good",IF(C17>=1,"Weak","Losing")))',
         "Gross profit / gross loss. 1.2+ is decent for an intraday system, 1.5+ strong."),
        ("Expectancy per trade $", "=IFERROR(C12/C20,0)", USD, res("Expected Payoff"), "", "What one trade earns on average."),
        ("TRADES",),
        ("Total trades", f"=COUNT({NET})", "0", res("Total Trades"), "", ""),
        ("Wins", f'=COUNTIF({T("Z")},"Win")', "0", res("Profit Trades (% of total)"), "", ""),
        ("Losses", f'=COUNTIF({T("Z")},"Loss")', "0", res("Loss Trades (% of total)"), "", "Includes breakeven stops that lost a little to slippage."),
        ("Win rate", "=IFERROR(C21/C20,0)", PCT, "", "", ""),
        ("Average win", f'=IFERROR(AVERAGEIF({NET},">0"),0)', USD, res("Average profit trade"), "", ""),
        ("Average loss", f'=IFERROR(AVERAGEIF({NET},"<0"),0)', USD, res("Average loss trade"), "", ""),
        ("Win/loss size ratio", "=IFERROR(C24/-C25,0)", "0.00", "", "", "Average win / average loss."),
        ("Break-even win rate needed", "=IFERROR(-C25/(C24-C25),0)", PCT, "",
         '=IF(C23>C27,"Above break-even","Below break-even")', "Win rate needed to break even with these win/loss sizes."),
        ("Largest win", f"=MAX({NET})", USD, res("Largest profit trade"), "", ""),
        ("Largest loss", f"=MIN({NET})", USD, res("Largest loss trade"), "", ""),
        ("Long trades / net", f'=COUNTIF({T("J")},"BUY")', "0", res("Long Trades (won %)"), f'=SUMIF({T("J")},"BUY",{NET})', "Verdict column = net $ of longs."),
        ("Short trades / net", f'=COUNTIF({T("J")},"SELL")', "0", res("Short Trades (won %)"), f'=SUMIF({T("J")},"SELL",{NET})', "Verdict column = net $ of shorts."),
        ("RISK (R multiples)",),
        ("Average planned risk per trade $", f"=AVERAGE({T('R')})", USD, "", "", "SL distance x lots x $ per point."),
        ("Average planned risk % of balance", f"=IFERROR(AVERAGE({T('R')})/AVERAGE({T('AD')}),0)", PCT, "", "", "Compare with the EA's RiskPercent."),
        ("Average SL distance (points)", f"=AVERAGE({T('P')})", PTS, "", "", ""),
        ("Average R per trade", f"=AVERAGE({T('Y')})", RFMT, "", '=IF(C36>0,"Positive edge","No edge")', "Expectancy in units of risk."),
        ("Total R", f"=SUM({T('Y')})", RFMT, "", "", ""),
        ("Average R of full stop losses", f'=IFERROR(AVERAGEIF({T("T")},"Initial stop loss",{T("Y")}),0)', RFMT, "",
         '=IF(C38<-1.05,"Losses overshoot","OK")', "-1.00R = lost exactly the plan. Below -1.05R = slippage."),
        ("Average R of take profits", f'=IFERROR(AVERAGEIF({T("T")},"Take profit",{T("Y")}),0)', RFMT, "", "", ""),
        ("DRAWDOWN & PROP RULES",),
        ("Max closed-trade drawdown $", f"=MAX({T('AF')})", USD, res("Balance Drawdown Maximal"), "", "Peak-to-low of the balance."),
        ("Max closed-trade drawdown %", f"=MAX({T('AG')})", PCT, res("Equity Drawdown Maximal"),
         '=IF(C42<=C8/2,"Safe",IF(C42<=C8,"Close to limit","Breach"))', "MT5 report column shows the equity drawdown (includes open trades)."),
        ("Worst day $", f"=MIN({DF_})", USD, "", "", "See Daily sheet."),
        ("Worst day % of start balance", f"=MIN(Daily!N2:N{nd + 1})", PCT, "", '=IF(-C44>=C7,"Breach","OK")', "Compared with the daily loss limit."),
        ("Days breaching daily loss limit", f'=COUNTIF(Daily!O2:O{nd + 1},"BREACH")', "0", "", "", ""),
        ("Worst week $", f"=MIN(Weekly!F2:F{nwk + 1})", USD, "", "", ""),
        ("Worst month $", f"=MIN({MF_})", USD, "", "", ""),
        ("Recovery factor", "=IFERROR(C12/C41,0)", "0.00", res("Recovery Factor"), "", "Net profit / max drawdown. 3+ is good."),
        ("CONSISTENCY",),
        ("Trading days", f"=COUNT(Daily!A2:A{nd + 1})", "0", "", "", "Days with at least one closed trade."),
        ("Green days %", f'=IFERROR(COUNTIF({DF_},">0")/C50,0)', PCT, "", "", ""),
        ("Average day $", "=IFERROR(C12/C50,0)", USD, "", "", ""),
        ("Months profitable", f'=COUNTIF({MF_},">0")&" of "&COUNT({MF_})', "@", "", "", ""),
        ("Average month $", f"=AVERAGE({MF_})", USD, "", "", ""),
        ("Best day share of total profit", f"=IFERROR(MAX({DF_})/C12,0)", PCT, "",
         '=IF(C55>0.3,"Too concentrated","OK")', "Prop consistency rules often require the best day < 30-50% of total profit."),
        ("Median hold (minutes)", f"=MEDIAN({T('AA')})", "0.0", res("Average position holding time"), "", "MT5 column = average."),
        ("Sharpe ratio (MT5)", "", "", res("Sharpe Ratio"), "", "As reported by MT5."),
        ("Z-score (MT5)", "", "", res("Z-Score"), "", "Near +/-2 = wins/losses cluster in streaks; near 0 = random order."),
    ]
    r = hr + 1
    for item in m:
        if len(item) == 1:
            ws.cell(row=r, column=2, value=item[0]).font = BOLD
            for cc in range(2, 7):
                ws.cell(row=r, column=cc).fill = NOTE_FILL
        else:
            name, f, nf, mt5, verdict, mean = item
            ws.cell(row=r, column=2, value=name)
            if f:
                c = ws.cell(row=r, column=3, value=f)
                c.number_format = nf
            ws.cell(row=r, column=4, value=mt5).font = GREY
            v = ws.cell(row=r, column=5, value=verdict)
            v.font = BOLD
            if isinstance(verdict, str) and "SUMIF" in verdict:
                v.number_format = USD
            ws.cell(row=r, column=6, value=mean).alignment = WRAP
        for cc in range(2, 7):
            ws.cell(row=r, column=cc).border = THIN
        r += 1
    assert r - 1 == 58, r   # row numbers inside the formulas above rely on this layout
    r += 1
    ws.cell(row=r, column=2, value="FINDINGS (computed from this report)").font = TITLE
    for t in notes(rows, deposit, cv, daily_lim, dd_lim, inputs):
        r += 1
        ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=6)
        c = ws.cell(row=r, column=2, value=t)
        c.alignment = WRAP
        ws.row_dimensions[r].height = 45
    ws.freeze_panes = "A11"

    # ------------------------------------------------------------ period sheets (formulas)
    def period_sheet(name, keycol, keys, keyfmt, extra_first=None, idx=1):
        sh = wb.create_sheet(name, idx)
        heads = ["Period", "Trades", "Wins", "Losses", "Win rate", "Net profit", "Gross profit", "Gross loss",
                 "Profit factor", "Best trade", "Worst trade", "Total R", "Start balance", "Return %",
                 "Limit check", "End balance", "Cumulative net"]
        if extra_first:
            heads[0] = extra_first
        header(sh, 1, heads, [12, 7, 6, 7, 8, 12, 12, 12, 8, 11, 11, 8, 13, 9, 11, 13, 13])
        for i, k in enumerate(keys):
            r = i + 2
            crit = f"{T(keycol)},$A{r}"
            f = {
                1: k, 2: f"=COUNTIFS({crit})", 3: f'=COUNTIFS({crit},{T("Z")},"Win")',
                4: f'=COUNTIFS({crit},{T("Z")},"Loss")', 5: f"=IFERROR(C{r}/B{r},0)", 6: f"=SUMIFS({NET},{crit})",
                7: f'=SUMIFS({NET},{crit},{NET},">0")', 8: f'=SUMIFS({NET},{crit},{NET},"<0")',
                9: f'=IFERROR(G{r}/-H{r},"no loss")', 10: f"=_xlfn.MAXIFS({NET},{crit})",
                11: f"=_xlfn.MINIFS({NET},{crit})", 12: f"=SUMIFS({T('Y')},{crit})",
                13: "=Summary!$C$5" if r == 2 else f"=P{r - 1}", 14: f"=IFERROR(F{r}/M{r},0)",
                16: f"=M{r}+F{r}", 17: f"=P{r}-Summary!$C$5",
            }
            if name == "Daily":
                f[15] = f'=IF(-N{r}>=Summary!$C$7,"BREACH","")'
            elif name == "Weekly":
                f[15] = f'=IF(F{r}<0,"down week","")'
            else:
                f[15] = f'=IF(F{r}>0,"up","down")'
            for c, v in f.items():
                sh.cell(row=r, column=c, value=v).font = NORMAL
            if keyfmt:
                sh.cell(row=r, column=1).number_format = keyfmt
            for c in (6, 7, 8, 10, 11, 13, 16, 17):
                sh.cell(row=r, column=c).number_format = USD
            for c in (5, 14):
                sh.cell(row=r, column=c).number_format = PCT
            sh.cell(row=r, column=9).number_format = "0.00"
            sh.cell(row=r, column=12).number_format = RFMT
        lr = len(keys) + 1
        tr_ = lr + 2
        sh.cell(row=tr_, column=1, value="TOTAL").font = BOLD
        for c in (2, 3, 4, 6, 7, 8, 12):
            sh.cell(row=tr_, column=c, value=f"=SUM({CL(c)}2:{CL(c)}{lr})").font = BOLD
        sh.cell(row=tr_, column=5, value=f"=IFERROR(C{tr_}/B{tr_},0)").number_format = PCT
        sh.cell(row=tr_, column=9, value=f"=IFERROR(G{tr_}/-H{tr_},0)").number_format = "0.00"
        sh.cell(row=tr_, column=14, value=f"=IFERROR(F{tr_}/M2,0)").number_format = PCT
        sh.cell(row=tr_, column=15, value=f'=COUNTIF(F2:F{lr},">0")&" up / "&COUNTIF(F2:F{lr},"<0")&" down"')
        for c in (6, 7, 8):
            sh.cell(row=tr_, column=c).number_format = USD
        sh.cell(row=tr_, column=12).number_format = RFMT
        for c in range(1, 18):
            sh.cell(row=tr_, column=c).fill = NOTE_FILL
        sh.conditional_formatting.add(f"F2:F{lr}", CellIsRule(operator="lessThan", formula=["0"], fill=RED_FILL))
        sh.conditional_formatting.add(f"F2:F{lr}", CellIsRule(operator="greaterThan", formula=["0"], fill=GREEN_FILL))
        sh.freeze_panes = "B2"
        return sh, lr, tr_

    netby = lambda key: {k: sum(r["net"] for r in rows if key(r) == k) for k in {key(r) for r in rows}}  # noqa: E731

    def bar(sh, lr, at, title, signs, cat_col=1):
        bc = BarChart()
        bc.title, bc.legend = title, None
        bc.height, bc.width = 8, 24
        bc.add_data(Reference(sh, min_col=6, min_row=1, max_row=lr), titles_from_data=True)
        bc.set_categories(Reference(sh, min_col=cat_col, min_row=2, max_row=lr))
        s = bc.series[0]
        s.graphicalProperties = GraphicalProperties(solidFill="2A78D6")
        for i, v in enumerate(signs):
            if v < 0:
                dp = DataPoint(idx=i)
                dp.graphicalProperties = GraphicalProperties(solidFill="EB6834")
                s.dPt.append(dp)
        bc.y_axis.numFmt = "$#,##0"
        bc.y_axis.majorGridlines = None
        bc.y_axis.delete = bc.x_axis.delete = False
        sh.add_chart(bc, at)

    sd, lrd, _ = period_sheet("Daily", "D", [dt.datetime.combine(d, dt.time()) for d in days], DF, "Date", 1)
    sd.cell(row=1, column=18, value="Weekday").font = HDR_FONT
    sd.cell(row=1, column=18).fill = HDR_FILL
    sd.column_dimensions["R"].width = 8
    for i in range(len(days)):
        sd.cell(row=i + 2, column=18, value=f'=TEXT(A{i + 2},"ddd")')
    sd.cell(row=1, column=15).comment = Comment("BREACH = the day's net loss reached the daily loss limit "
                                                "(Summary C7) of the start-of-day balance.", "report")

    sw, lrw, trw = period_sheet("Weekly", "E", [dt.datetime.combine(w, dt.time()) for w in weeks], DF, "Week (Mon)", 1)
    nw = netby(lambda r: r["x"]["time"].date() - dt.timedelta(days=r["x"]["time"].weekday()))
    bar(sw, lrw, f"S2", "Net profit per week ($)", [nw[w] for w in weeks])

    sm, lrm, trm = period_sheet("Monthly", "F", months, None, "Month", 1)
    nm = netby(lambda r: r["x"]["time"].strftime("%Y-%m"))
    bar(sm, lrm, f"A{trm + 3}", "Net profit per month ($)", [nm[m_] for m_ in months])

    sy, lry, try_ = period_sheet("Yearly", "G", years, "0", "Year", 1)
    ny = netby(lambda r: r["x"]["time"].year)
    bar(sy, lry, f"A{try_ + 3}", "Net profit per year ($)", [ny[y] for y in years])
    sy.cell(row=try_ + 1, column=1, value="Partial years: the test period decides the first and last year's length.").font = GREY

    # ------------------------------------------------------------ Calendar (year x month)
    sc = wb.create_sheet("Calendar", 3)
    sc["A1"] = "Net profit by month ($) - green = profit, red = loss"
    sc["A1"].font = TITLE
    header(sc, 3, ["Year"] + MONTHS + ["Year total", "Return %"], [8] + [11] * 12 + [13, 10])
    for i, y in enumerate(years):
        r = 4 + i
        sc.cell(row=r, column=1, value=y).font = BOLD
        for mi in range(12):
            c = sc.cell(row=r, column=2 + mi, value=f'=SUMIFS({NET},{T("F")},"{y}-{mi + 1:02d}")')
            c.number_format = USD
        sc.cell(row=r, column=14, value=f"=SUM(B{r}:M{r})").number_format = USD
        sc.cell(row=r, column=15, value=f"=IFERROR(N{r}/Summary!$C$5,0)").number_format = PCT
    ly = 3 + len(years)
    sc.conditional_formatting.add(f"B4:M{ly}", ColorScaleRule(start_type="min", start_color="F8696B", mid_type="num",
                                                              mid_value=0, mid_color="FFFFFF", end_type="max",
                                                              end_color="63BE7B"))
    r0 = ly + 3
    sc.cell(row=r0 - 1, column=1, value="Trades per month").font = BOLD
    header(sc, r0, ["Year"] + MONTHS + ["Year total"])
    for i, y in enumerate(years):
        r = r0 + 1 + i
        sc.cell(row=r, column=1, value=y).font = BOLD
        for mi in range(12):
            sc.cell(row=r, column=2 + mi, value=f'=COUNTIFS({T("F")},"{y}-{mi + 1:02d}")')
        sc.cell(row=r, column=14, value=f"=SUM(B{r}:M{r})")
    r1 = r0 + len(years) + 3
    sc.cell(row=r1 - 1, column=1, value="Win rate per month").font = BOLD
    header(sc, r1, ["Year"] + MONTHS)
    for i, y in enumerate(years):
        r = r1 + 1 + i
        sc.cell(row=r, column=1, value=y).font = BOLD
        for mi in range(12):
            k = f'{T("F")},"{y}-{mi + 1:02d}"'
            c = sc.cell(row=r, column=2 + mi, value=f'=IFERROR(COUNTIFS({k},{T("Z")},"Win")/COUNTIFS({k}),"")')
            c.number_format = "0%"

    # ------------------------------------------------------------ Breakdown
    wbk = wb.create_sheet("Breakdown", 7)
    for i, w in enumerate([24, 8, 9, 13, 12, 9, 9, 60], 1):
        wbk.column_dimensions[CL(i)].width = w
    wbk["A1"] = "Where the money is made and lost"
    wbk["A1"].font = TITLE
    pos = [3]

    def block(title, colkey, groups, note):
        row = pos[0]
        wbk.cell(row=row, column=1, value=title).font = BOLD
        wbk.cell(row=row, column=8, value=note).alignment = WRAP
        row += 1
        header(wbk, row, [title.replace("By ", ""), "Trades", "Win rate", "Net profit", "Avg per trade", "Avg R",
                          "Profit factor"])
        row += 1
        first = row
        for g in groups:
            crit = f"{T(colkey)},$A{row}"
            wbk.cell(row=row, column=1, value=g)
            wbk.cell(row=row, column=2, value=f"=COUNTIFS({crit})")
            wbk.cell(row=row, column=3, value=f'=IFERROR(COUNTIFS({crit},{T("Z")},"Win")/B{row},0)').number_format = PCT
            wbk.cell(row=row, column=4, value=f"=SUMIFS({NET},{crit})").number_format = USD
            wbk.cell(row=row, column=5, value=f"=IFERROR(D{row}/B{row},0)").number_format = USD
            wbk.cell(row=row, column=6, value=f"=IFERROR(AVERAGEIFS({T('Y')},{crit}),0)").number_format = RFMT
            wbk.cell(row=row, column=7, value=f'=IFERROR(SUMIFS({NET},{crit},{NET},">0")/-SUMIFS({NET},{crit},{NET},"<0"),"-")').number_format = "0.00"
            row += 1
        wbk.cell(row=row, column=1, value="Total").font = BOLD
        wbk.cell(row=row, column=2, value=f"=SUM(B{first}:B{row - 1})").font = BOLD
        wbk.cell(row=row, column=4, value=f"=SUM(D{first}:D{row - 1})").number_format = USD
        for c in range(1, 8):
            wbk.cell(row=row, column=c).fill = NOTE_FILL
        wbk.conditional_formatting.add(f"D{first}:D{row - 1}", CellIsRule(operator="lessThan", formula=["0"], fill=RED_FILL))
        pos[0] = row + 2

    block("By side", "J", ["BUY", "SELL"], "Is one direction worse than the other?")
    block("By setup", "K", sorted({r["e"]["comment"] or "" for r in rows}), "Entry comment written by the EA.")
    block("By exit reason", "T", ["Take profit", "Initial stop loss", "Breakeven stop", "Moved stop (loss side)",
                                  "Closed by EA (guard)"],
          "Breakeven stop = price reached the breakeven trigger, then came back to entry. Small losses there are slippage/commission.")
    block("By weekday (entry)", "H", WEEKDAYS[:5], "Day of the week the trade was entered (server time).")
    block("By entry hour (server)", "I", sorted({r["e"]["time"].hour for r in rows}),
          "Server hour of entry. Hours with a clearly negative total are candidates for a no-trade window.")
    block("By hold time", "AB", ["a) <1 min", "b) 1-10 min", "c) 10-60 min", "d) 1-4 h", "e) 4 h+"],
          "How long trades stayed open.")
    block("By SL distance (points)", "AC", ["a) <10", "b) 10-20", "c) 20-40", "d) 40-80", "e) 80+"],
          "ATR-based stops: very small stops are easily hit by noise, very large ones mean volatile days.")
    block("By year", "G", years, "Same as the Yearly sheet, for side-by-side reading.")
    # R distribution
    row = pos[0]
    wbk.cell(row=row, column=1, value="R distribution").font = BOLD
    wbk.cell(row=row, column=8, value="How many trades ended in each R range.").alignment = WRAP
    header(wbk, row + 1, ["R range", "Trades", "Share", "Net profit"])
    bins = [(-99, -1.05, "worse than -1.05R"), (-1.05, -0.95, "-1R (full stop)"), (-0.95, -0.05, "-0.95R to -0.05R"),
            (-0.05, 0.05, "about 0R (breakeven)"), (0.05, 1, "0 to +1R"), (1, 2, "+1R to +2R"), (2, 3, "+2R to +3R"),
            (3, 99, "+3R and more")]
    for i, (lo, hi, lab) in enumerate(bins):
        r = row + 2 + i
        wbk.cell(row=r, column=1, value=lab)
        crit = f'{T("Y")},">={lo}",{T("Y")},"<{hi}"'
        wbk.cell(row=r, column=2, value=f"=COUNTIFS({crit})")
        wbk.cell(row=r, column=3, value=f"=IFERROR(B{r}/Summary!$C$20,0)").number_format = PCT
        wbk.cell(row=r, column=4, value=f"=SUMIFS({NET},{crit})").number_format = USD

    # ------------------------------------------------------------ Drawdowns & streaks (computed values)
    sdd = wb.create_sheet("Drawdowns & Streaks", 8)
    for i, w in enumerate([6, 20, 20, 20, 14, 10, 9, 12], 1):
        sdd.column_dimensions[CL(i)].width = w
    sdd["A1"] = "Top 10 drawdown periods (closed trades)"
    sdd["A1"].font = TITLE
    sdd["A2"] = "Computed from the trade list when the workbook was built (values, not formulas)."
    sdd["A2"].font = GREY
    header(sdd, 4, ["#", "Started (peak)", "Lowest point", "Recovered", "Depth $", "Depth %", "Trades", "Days to recover"])
    for i, d in enumerate(drawdowns(rows, deposit)[:10], 1):
        r = 4 + i
        vals = [i, d["start"], d["trough"], d["recovered"] or "not recovered", round(d["depth"], 2),
                d["depth"] / d["peak"], d["trades"],
                (d["recovered"] - d["start"]).days if d["recovered"] and d["start"] else ""]
        for c, v in enumerate(vals, 1):
            cell = sdd.cell(row=r, column=c, value=v)
            cell.font = BLUE_IN
        for c in (2, 3, 4):
            sdd.cell(row=r, column=c).number_format = DTF
        sdd.cell(row=r, column=5).number_format = USD
        sdd.cell(row=r, column=6).number_format = PCT
    s = streaks(rows)
    r = 17
    sdd.cell(row=r, column=1, value="Longest streaks").font = TITLE
    header(sdd, r + 1, ["", "Streak", "Trades", "Net $", "Started"])
    for i, (k, lab) in enumerate((("win", "Winning"), ("loss", "Losing")), 1):
        cnt, amt, start = s[k]
        for c, v in enumerate(["", lab, cnt, round(amt, 2), start], 1):
            sdd.cell(row=r + 1 + i, column=c, value=v).font = BLUE_IN
        sdd.cell(row=r + 1 + i, column=4).number_format = USD
        sdd.cell(row=r + 1 + i, column=5).number_format = DTF
    # consecutive losing days
    dnet = defaultdict(float)
    for rw in rows:
        dnet[rw["x"]["time"].date()] += rw["net"]
    best_run, run, run_sum, best_sum, run_start, best_start = 0, 0, 0.0, 0.0, None, None
    for d in sorted(dnet):
        if dnet[d] < 0:
            run, run_sum = run + 1, run_sum + dnet[d]
            run_start = run_start or d
            if run > best_run:
                best_run, best_sum, best_start = run, run_sum, run_start
        else:
            run, run_sum, run_start = 0, 0.0, None
    sdd.cell(row=r + 4, column=2, value="Losing days in a row").font = BLUE_IN
    for c, v in ((3, best_run), (4, round(best_sum, 2)), (5, best_start)):
        sdd.cell(row=r + 4, column=c, value=v).font = BLUE_IN
    sdd.cell(row=r + 4, column=4).number_format = USD
    sdd.cell(row=r + 4, column=5).number_format = DF
    # equity chart (balance after each trade)
    lc = LineChart()
    lc.title, lc.legend = "Balance after each trade", None
    lc.height, lc.width = 9, 26
    lc.add_data(Reference(wt, min_col=30, min_row=1, max_row=last), titles_from_data=True)
    lc.series[0].graphicalProperties.line.solidFill = "2A78D6"
    lc.series[0].smooth = False
    lc.y_axis.numFmt = "$#,##0"
    lc.y_axis.majorGridlines = None
    lc.x_axis.title = "Trade #"
    lc.y_axis.delete = lc.x_axis.delete = False
    lc.x_axis.tickLblSkip = max(1, n // 20)
    ws.add_chart(lc, "H10")
    dc = LineChart()
    dc.title, dc.legend = "Drawdown % after each trade", None
    dc.height, dc.width = 7, 26
    dc.add_data(Reference(wt, min_col=33, min_row=1, max_row=last), titles_from_data=True)
    dc.series[0].graphicalProperties.line.solidFill = "EB6834"
    dc.series[0].smooth = False
    dc.y_axis.numFmt = "0.0%"
    dc.y_axis.majorGridlines = None
    dc.y_axis.delete = dc.x_axis.delete = False
    dc.x_axis.tickLblSkip = max(1, n // 20)
    ws.add_chart(dc, "H30")

    # ------------------------------------------------------------ MT5 report figures
    smt = wb.create_sheet("MT5 Report")
    smt.column_dimensions["A"].width = 36
    smt.column_dimensions["B"].width = 24
    smt["A1"] = "Figures exactly as the MT5 Strategy Tester reported them"
    smt["A1"].font = TITLE
    for i, (k, v) in enumerate(results.items(), 3):
        smt.cell(row=i, column=1, value=k)
        smt.cell(row=i, column=2, value=v).font = BLUE_IN

    # ------------------------------------------------------------ Settings
    wst = wb.create_sheet("Settings")
    wst.column_dimensions["A"].width = 34
    wst.column_dimensions["B"].width = 30
    wst["A1"] = "Test settings and EA inputs"
    wst["A1"].font = TITLE
    r = 3
    for k in ("Expert", "Symbol", "Period", "Company", "Currency", "Initial Deposit", "Leverage"):
        wst.cell(row=r, column=1, value=k).font = BOLD
        wst.cell(row=r, column=2, value=info.get(k))
        r += 1
    wst.cell(row=r, column=1, value="History quality").font = BOLD
    wst.cell(row=r, column=2, value=results.get("History Quality"))
    r += 2
    header(wst, r, ["Input", "Value"])
    for line in inputs:
        if not isinstance(line, str):
            continue
        r += 1
        if line.startswith("==="):
            wst.cell(row=r, column=1, value=line.strip("= ")).font = BOLD
        elif "=" in line:
            k, v = line.split("=", 1)
            wst.cell(row=r, column=1, value=k)
            wst.cell(row=r, column=2, value=v).font = BLUE_IN

    # ------------------------------------------------------------ Read Me
    wr = wb.create_sheet("Read Me", 0)
    wr.column_dimensions["A"].width = 22
    wr.column_dimensions["B"].width = 110
    wr["A1"] = "How to read this workbook"
    wr["A1"].font = TITLE
    lines = [
        ("Summary", "Key numbers next to the MT5 report's own figures, verdicts, findings, balance and drawdown charts."),
        ("Yearly / Monthly / Weekly / Daily", "One row per period: trades, wins, win rate, net, profit factor, best/worst "
                                              "trade, total R, start/end balance and return. Daily flags days that hit the "
                                              "daily loss limit."),
        ("Calendar", "Year x month grid of net profit (colour scale), trades per month and win rate per month."),
        ("Trades", "Every trade on one row: entry deal matched to its exit, SL/TP, planned risk, exit reason, R, hold "
                   "time, balance and drawdown. Use the filter arrows in the header row."),
        ("Breakdown", "Results split by side, setup, exit reason, weekday, entry hour, hold time, SL size, year, and the "
                      "R distribution."),
        ("Drawdowns & Streaks", "The 10 deepest drawdown periods with dates and recovery time, longest win/loss streaks."),
        ("MT5 Report / Settings", "The tester's original statistics and the EA inputs used."),
        ("", ""),
        ("Dates", "Profit is booked on the trade's CLOSE date/time (broker server time)."),
        ("R multiple", "Net profit / planned risk. Planned risk = SL distance x lots x $ per point per lot (Summary C6)."),
        ("Win / Loss", "Breakeven stops that close a few dollars negative (slippage/commission) count as losses, as in MT5."),
        ("Colours", "Blue = data from the MT5 report or inputs you may change. Black = formulas. Yellow = inputs."),
        ("Source", f"MT5 Strategy Tester report: {info.get('Expert', '')} on {sym}, {n} trades. Net profit here matches "
                   f"the report's Total Net Profit ({results.get('Total Net Profit')})."),
    ]
    for i, (a, b) in enumerate(lines, 3):
        wr.cell(row=i, column=1, value=a).font = BOLD
        c = wr.cell(row=i, column=2, value=b)
        c.alignment = WRAP

    for sh in wb.worksheets:
        for row in sh.iter_rows():
            for c in row:
                if c.font is None or c.font.name != FONT:
                    c.font = Font(name=FONT, bold=c.font.bold, italic=c.font.italic, color=c.font.color,
                                  size=c.font.size)
    wb.active = 1
    wb.save(dst)
    return n


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    a = sys.argv
    n = build(a[1], a[2], float(a[3]) if len(a) > 3 else 0.025, float(a[4]) if len(a) > 4 else 0.10)
    print(f"Wrote {a[2]} ({n} trades)")
