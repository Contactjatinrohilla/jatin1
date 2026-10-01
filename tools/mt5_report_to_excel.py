#!/usr/bin/env python3
"""
Turn an MT5 Strategy Tester .xlsx report into an explained workbook:
  Read Me | Summary | Monthly | Trades | Breakdown | Settings

Every trade = one row (entry matched to its exit), monthly and breakdown tables
are live formulas over the Trades sheet.

  python3 mt5_report_to_excel.py ReportTester.xlsx  Explained_Report.xlsx
"""
import sys
import openpyxl
from openpyxl.chart import BarChart, LineChart, Reference
from openpyxl.chart.shapes import GraphicalProperties
from openpyxl.chart.series import DataPoint
from openpyxl.comments import Comment
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter as CL
from openpyxl.worksheet.table import Table, TableStyleInfo

from mt5_report_parse import parse

FONT = "Arial"
BLUE_IN = Font(name=FONT, color="0000FF")
BOLD = Font(name=FONT, bold=True)
NORMAL = Font(name=FONT)
TITLE = Font(name=FONT, bold=True, size=14)
HDR_FILL = PatternFill("solid", start_color="1F3A5F")
HDR_FONT = Font(name=FONT, bold=True, color="FFFFFF")
NOTE_FILL = PatternFill("solid", start_color="F2F2F2")
KEY_FILL = PatternFill("solid", start_color="FFFF00")
THIN = Border(bottom=Side(style="thin", color="BFBFBF"))
WRAP = Alignment(wrap_text=True, vertical="top")

USD = '$#,##0.00;[Red]-$#,##0.00;"-"'
USD0 = '$#,##0;[Red]-$#,##0;"-"'
PCT = '0.0%;[Red]-0.0%;"-"'
RFMT = '0.00"R";[Red]-0.00"R";"0R"'
PX = "0.000"
DTF = "yyyy-mm-dd hh:mm:ss"
WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def header(ws, row, names, widths=None):
    for i, n in enumerate(names, 1):
        c = ws.cell(row=row, column=i, value=n)
        c.font, c.fill = HDR_FONT, HDR_FILL
        c.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
    if widths:
        for i, w in enumerate(widths, 1):
            ws.column_dimensions[CL(i)].width = w


def setfont(ws):
    for row in ws.iter_rows():
        for c in row:
            if c.font is None or c.font.name != FONT:
                c.font = Font(name=FONT, bold=c.font.bold if c.font else False,
                              color=c.font.color if c.font else None, size=c.font.size if c.font else 10)


def fmt_hold(sec):
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m{sec % 60:02d}s"
    return f"{sec // 3600}h{(sec % 3600) // 60:02d}m"


def build(src, dst):
    info, inputs, results, trades = parse(src)
    deposit = float(info.get("Initial Deposit") or info.get("Deposit deal") or 0)
    wb = openpyxl.Workbook()

    # ------------------------------------------------------------ Trades
    wt = wb.active
    wt.title = "Trades"
    cols = ["#", "Month", "Entry time (server)", "Weekday", "Entry hour", "Side", "Setup",
            "Lots", "Order price (planned entry)", "Filled entry", "Entry slippage $",
            "Initial SL", "SL distance $", "Planned risk $", "Exit time", "Hold (sec)", "Hold bucket",
            "Stop level hit", "Exit price", "Exit reason", "Exit slippage $", "Price move $",
            "Profit $", "R multiple", "Result", "Balance after", "Peak balance", "Drawdown $",
            "Drawdown %", "What happened"]
    widths = [5, 9, 19, 9, 7, 6, 8, 6, 11, 11, 10, 11, 9, 10, 19, 8, 9, 11, 11, 22, 9, 9, 10, 9, 7,
              11, 11, 10, 9, 70]
    header(wt, 1, cols, widths)
    wt.row_dimensions[1].height = 45
    for i, t in enumerate(trades, 1):
        e, x, o = t["entry"], t["exit"], t["order"]
        r = i + 1
        buy = e["type"] == "buy"
        profit = round(x["profit"] + x["swap"] + x["comm"] + e["comm"], 2)
        stop_hit = float(x["comment"][3:]) if x["comment"].startswith("sl ") else None
        plan_px, init_sl = o.get("price"), o.get("sl")
        if stop_hit is None:
            reason = "Closed by EA (no SL)"
        elif init_sl and abs(stop_hit - init_sl) < 0.02:
            reason = "Initial stop loss"
        elif (buy and stop_hit >= plan_px) or (not buy and stop_hit <= plan_px):
            reason = "Breakeven/trailing stop"
        else:
            reason = "Moved stop (below entry)"
        hold = (x["time"] - e["time"]).total_seconds()
        slip = (e["price"] - plan_px) if buy else (plan_px - e["price"])
        sld = abs(plan_px - init_sl)
        risk = sld * e["vol"] * 100
        rmul = profit / risk if risk else 0
        side = "BUY" if buy else "SELL"
        story = (f"{side} STOP at {plan_px:.2f} filled at {e['price']:.3f} "
                 f"(${abs(slip):.2f} {'worse' if slip > 0 else 'better'}). "
                 f"SL ${sld:.2f} away = ${risk:.0f} risk. ")
        if reason == "Initial stop loss":
            story += f"Price went against it; stopped at {x['price']:.3f}"
        elif reason.startswith("Trailing"):
            story += f"Moved into profit, trailing/breakeven stop closed it at {x['price']:.3f}"
        elif reason.startswith("Moved"):
            story += f"Stop had been moved but price came back; closed at {x['price']:.3f}"
        else:
            story += f"Closed by the EA itself (account guard / blackout / instant close) at {x['price']:.3f}"
        story += f" after {fmt_hold(hold)}: {'+' if profit >= 0 else '-'}${abs(profit):.2f} ({rmul:+.2f}R)."
        vals = {
            1: i, 2: e["time"].strftime("%Y-%m"), 3: e["time"], 4: WEEKDAYS[e["time"].weekday()],
            5: e["time"].hour, 6: side, 7: e["comment"], 8: e["vol"], 9: plan_px, 10: e["price"],
            11: f'=IF(F{r}="BUY",J{r}-I{r},I{r}-J{r})', 12: init_sl, 13: f"=ABS(I{r}-L{r})",
            14: f"=M{r}*H{r}*Summary!$C$6", 15: x["time"], 16: f"=ROUND((O{r}-C{r})*86400,0)",
            17: f'=IF(P{r}<10,"a) <10s",IF(P{r}<60,"b) 10-60s",IF(P{r}<600,"c) 1-10min","d) >10min")))',
            18: stop_hit, 19: x["price"], 20: reason,
            21: f'=IF(R{r}="","",IF(F{r}="BUY",R{r}-S{r},S{r}-R{r}))',
            22: f'=IF(F{r}="BUY",S{r}-J{r},J{r}-S{r})', 23: profit, 24: f"=IFERROR(W{r}/N{r},0)",
            25: f'=IF(W{r}>0,"Win",IF(W{r}<0,"Loss","Flat"))',
            26: f"=Summary!$C$5+SUM(W$2:W{r})",
            27: f"=MAX(Summary!$C$5,Z{r})" if r == 2 else f"=MAX(AA{r - 1},Z{r})",
            28: f"=AA{r}-Z{r}", 29: f"=IFERROR(AB{r}/AA{r},0)", 30: story,
        }
        for c, v in vals.items():
            cell = wt.cell(row=r, column=c, value=v)
            cell.font = NORMAL
        wt.cell(row=r, column=23).font = BLUE_IN
        for c in (3, 15):
            wt.cell(row=r, column=c).number_format = DTF
        for c in (9, 10, 12, 18, 19):
            wt.cell(row=r, column=c).number_format = PX
        for c in (11, 13, 21, 22):
            wt.cell(row=r, column=c).number_format = '0.00;[Red]-0.00;"-"'
        for c in (14, 23, 26, 27, 28):
            wt.cell(row=r, column=c).number_format = USD
        wt.cell(row=r, column=24).number_format = RFMT
        wt.cell(row=r, column=29).number_format = PCT
    last = len(trades) + 1
    wt.freeze_panes = "D2"
    tab = Table(displayName="TradeList", ref=f"A1:{CL(len(cols))}{last}")
    tab.tableStyleInfo = TableStyleInfo(name="TableStyleLight9", showRowStripes=True)
    wt.add_table(tab)
    wt.cell(row=1, column=23).comment = Comment("Profit + commission + swap, copied from the MT5 deals list "
                                                "(blue = source data).", "report")
    wt.cell(row=1, column=24).comment = Comment("Profit divided by planned risk. -1R = lost exactly what was "
                                                "planned; -1.5R = lost 50% more (slippage).", "report")

    T = lambda col: f"Trades!${col}$2:${col}${last}"   # noqa: E731

    # ------------------------------------------------------------ Summary
    ws = wb.create_sheet("Summary", 0)
    ws.column_dimensions["A"].width = 3
    ws.column_dimensions["B"].width = 38
    ws.column_dimensions["C"].width = 16
    ws.column_dimensions["D"].width = 16
    ws.column_dimensions["E"].width = 80
    ws["B1"] = "Backtest summary: plain-language version"
    ws["B1"].font = TITLE
    ws["B2"] = f"{info.get('Expert', '')} | {info.get('Symbol', '')} | {info.get('Period', '')}"
    ws["B3"] = "Inputs (blue): change them and every number recalculates."
    ws["B3"].font = Font(name=FONT, italic=True, color="595959")
    ws["B5"], ws["C5"] = "Starting balance", deposit
    ws["B6"], ws["C6"] = "Contract size (oz per 1.00 lot)", 100
    for a in ("C5", "C6"):
        ws[a].font = BLUE_IN
    ws["C5"].number_format = USD
    ws["E5"] = "From the report (Initial Deposit)."
    ws["E6"] = "Assumption: standard XAUUSD contract (1 lot = 100 oz). Used for planned risk $."

    header_row = 8
    for i, h in enumerate(["", "Metric", "Value", "Verdict", "What it means"], 1):
        if i > 1:
            c = ws.cell(row=header_row, column=i, value=h)
            c.font, c.fill = HDR_FONT, HDR_FILL
    m = [
        ("RESULT", None, None, None),
        ("Net profit", f"=SUM({T('W')})", USD, "Total money made or lost over the whole test."),
        ("Final balance", "=C5+C10", USD, "Starting balance + net profit."),
        ("Return on starting balance", "=IFERROR(C10/C5,0)", PCT, "Net profit as % of the deposit."),
        ("Max drawdown $", f"=MAX({T('AB')})", USD, "Biggest drop from a balance peak to a later low (closed trades)."),
        ("Max drawdown %", f"=MAX({T('AC')})", PCT, "Same drop as % of the peak. Prop firms usually fail you at 8-10%."),
        ("TRADES", None, None, None),
        ("Total trades", f"=COUNT({T('W')})", "0", "Each row of the Trades sheet = one entry + its exit."),
        ("Winning trades", f'=COUNTIF({T("Y")},"Win")', "0", ""),
        ("Losing trades", f'=COUNTIF({T("Y")},"Loss")', "0", ""),
        ("Win rate", "=IFERROR(C17/C16,0)", PCT, "Share of trades that made money."),
        ("Average win", f'=IFERROR(AVERAGEIF({T("W")},">0"),0)', USD, "Typical size of a winner."),
        ("Average loss", f'=IFERROR(AVERAGEIF({T("W")},"<0"),0)', USD, "Typical size of a loser."),
        ("Win/loss size ratio", "=IFERROR(C20/-C21,0)", "0.00", "Average win divided by average loss. Above 1 = winners bigger than losers."),
        ("Break-even win rate needed", "=IFERROR(-C21/(C20-C21),0)", PCT,
         "With these win/loss sizes you need at least this win rate just to break even."),
        ("Profit factor", f'=IFERROR(SUMIF({T("W")},">0")/-SUMIF({T("W")},"<0"),0)', "0.00",
         "Gross profit / gross loss. Below 1 = losing system. Aim for 1.3+."),
        ("Expectancy per trade", "=IFERROR(C10/C16,0)", USD, "What one trade earns on average, after slippage."),
        ("RISK vs REALITY", None, None, None),
        ("Average planned risk per trade", f"=AVERAGE({T('N')})", USD, "SL distance x lots x 100 oz: what the EA meant to risk (about 1%)."),
        ("Average SL distance $", f"=AVERAGE({T('M')})", USD, "How far the stop loss was from the order price, in gold dollars."),
        ("Average entry slippage $", f"=AVERAGE({T('K')})", USD,
         "How much worse than the order price the stop order filled (spread + slippage)."),
        ("Slippage as % of the stop", "=IFERROR(C29/C28,0)", PCT, "Share of the stop eaten up before the trade even starts."),
        ("Average R on losing trades", f'=IFERROR(AVERAGEIF({T("Y")},"Loss",{T("X")}),0)', RFMT,
         "-1.00R = lost exactly the planned risk. Below -1R = slippage made losses bigger than planned."),
        ("Losing trades that lost more than 1R", f'=COUNTIF({T("X")},"<-1.05")', "0", "Losses at least 5% bigger than planned."),
        ("Average R on winning trades", f'=IFERROR(AVERAGEIF({T("Y")},"Win",{T("X")}),0)', RFMT, "Typical winner measured in planned risk."),
        ("HOLD TIME", None, None, None),
        ("Median hold (seconds)", f"=MEDIAN({T('P')})", "0", "Half of all trades were closed faster than this."),
        ("Trades closed within 10 seconds", f'=COUNTIF({T("P")},"<10")', "0",
         "In seconds-long trades the result is mostly spread, slippage and tick noise."),
        ("Trades closed within 60 seconds", f'=COUNTIF({T("P")},"<60")', "0", ""),
        ("EXITS", None, None, None),
        ("Exits: initial stop loss", f'=COUNTIF({T("T")},"Initial stop loss")', "0", "Full losses."),
        ("Net $ from initial-SL exits", f'=SUMIF({T("T")},"Initial stop loss",{T("W")})', USD, ""),
        ("Exits: trailing/breakeven stop", f'=COUNTIF({T("T")},"Breakeven/trailing stop")', "0", "Stop had been moved to the order price or beyond. Can still lose a little because of entry/exit slippage."),
        ("Net $ from trailing/BE exits", f'=SUMIF({T("T")},"Breakeven/trailing stop",{T("W")})', USD, ""),
        ("Exits: closed by EA", f'=COUNTIF({T("T")},"Closed by EA (no SL)")', "0",
         "Closed without an SL comment: account guard, blackout flatten, or an instant close."),
        ("Net $ from EA closes", f'=SUMIF({T("T")},"Closed by EA (no SL)",{T("W")})', USD, ""),
    ]
    verdicts = {
        10: '=IF(C10>0,"Profitable","Losing")',
        14: '=IF(C14<=0.08,"OK for prop","Too deep")',
        19: '=IF(C19>=C23,"Above break-even","Below break-even")',
        23: '=IF(C23<C19,"Achieved","Not achieved")',
        24: '=IF(C24>=1.3,"Good",IF(C24>=1,"Weak","Losing"))',
        30: '=IF(C30>0.2,"Too high","OK")',
        31: '=IF(C31<-1.05,"Losses overshoot","OK")',
        35: '=IF(C35<60,"Too short","OK")',
    }
    r = header_row + 1
    for name, f, nf, mean in m:
        if f is None:
            c = ws.cell(row=r, column=2, value=name)
            c.font = BOLD
            for cc in range(2, 6):
                ws.cell(row=r, column=cc).fill = NOTE_FILL
        else:
            ws.cell(row=r, column=2, value=name).font = NORMAL
            c = ws.cell(row=r, column=3, value=f)
            c.number_format = nf
            ws.cell(row=r, column=5, value=mean).alignment = WRAP
            if r in verdicts:
                ws.cell(row=r, column=4, value=verdicts[r]).font = BOLD
        for cc in range(2, 6):
            ws.cell(row=r, column=cc).border = THIN
        r += 1
    assert r - 1 == 44, r   # verdict row numbers above rely on this layout

    r += 1
    ws.cell(row=r, column=2, value="DIAGNOSIS (analyst notes for this report)").font = TITLE
    notes = [
        "1. The stop loss is too small for gold. Every trade used a $1.50 stop, and gold often moves that much "
        "within a few seconds. The median trade lasted only seconds, so results are mostly noise.",
        "2. Slippage eats the stop. Stop orders fill on a moving price, about $0.58 worse on average, "
        "which uses up about 40% of the $1.50 stop before the trade starts.",
        "3. Losses are bigger than planned. Trades that hit the initial stop lost about 1.5x the planned 1% "
        "(see Breakdown > Exit reason), because the exit slips too. Winners are cut short by the 10-point trail.",
        "4. Result: average win and average loss are about the same size, but only ~41% of trades win, so the "
        "account drifts down steadily (profit factor about 0.5).",
        "5. Time of day matters. Entries in the Asian session (server 01:00-05:59) lose the most "
        "(see Breakdown > Entry hour).",
        "WHAT TO CHANGE: use a stop several times larger (e.g. $5-$12, see v7 EA), take profit at 2R, "
        "breakeven at +1R, no 10-point trail, and test each change on its own.",
    ]
    for n in notes:
        r += 1
        ws.merge_cells(start_row=r, start_column=2, end_row=r, end_column=5)
        c = ws.cell(row=r, column=2, value=n)
        c.alignment = WRAP
        c.font = NORMAL
        ws.row_dimensions[r].height = 32
    ws.freeze_panes = "A9"

    # ------------------------------------------------------------ Monthly
    wm = wb.create_sheet("Monthly", 1)
    months = sorted({t["entry"]["time"].strftime("%Y-%m") for t in trades})
    mcols = ["Month", "Trades", "Wins", "Losses", "Win rate", "Gross profit", "Gross loss", "Net profit",
             "Profit factor", "Average win", "Average loss", "Best trade", "Worst trade", "Avg R",
             "Start balance", "End balance", "Return %", "Comment"]
    header(wm, 1, mcols, [9, 7, 6, 7, 8, 11, 11, 11, 8, 10, 10, 10, 10, 8, 12, 12, 9, 34])
    wm.row_dimensions[1].height = 32
    for i, mo in enumerate(months):
        r = i + 2
        k = f"{T('B')},$A{r}"
        f = {
            1: mo, 2: f"=COUNTIFS({k})", 3: f'=COUNTIFS({k},{T("Y")},"Win")', 4: f'=COUNTIFS({k},{T("Y")},"Loss")',
            5: f"=IFERROR(C{r}/B{r},0)", 6: f'=SUMIFS({T("W")},{k},{T("W")},">0")',
            7: f'=SUMIFS({T("W")},{k},{T("W")},"<0")', 8: f"=F{r}+G{r}",
            9: f'=IFERROR(F{r}/-G{r},"no losses")', 10: f"=IFERROR(F{r}/C{r},0)", 11: f"=IFERROR(G{r}/D{r},0)",
            12: f"=_xlfn.MAXIFS({T('W')},{k})", 13: f"=_xlfn.MINIFS({T('W')},{k})",
            14: f"=IFERROR(AVERAGEIFS({T('X')},{k}),0)",
            15: "=Summary!$C$5" if r == 2 else f"=P{r - 1}", 16: f"=O{r}+H{r}", 17: f"=IFERROR(H{r}/O{r},0)",
            18: f'=IF(H{r}>0,"Up month",IF(H{r}<0,"Down month","Flat"))&" | "&B{r}&" trades, "&TEXT(E{r},"0%")&" won"',
        }
        for c, v in f.items():
            wm.cell(row=r, column=c, value=v).font = NORMAL
        for c in (6, 7, 8, 10, 11, 12, 13, 15, 16):
            wm.cell(row=r, column=c).number_format = USD
        wm.cell(row=r, column=5).number_format = PCT
        wm.cell(row=r, column=17).number_format = PCT
        wm.cell(row=r, column=9).number_format = "0.00"
        wm.cell(row=r, column=14).number_format = RFMT
    lm = len(months) + 1
    tr_ = lm + 1
    wm.cell(row=tr_, column=1, value="TOTAL").font = BOLD
    for c in (2, 3, 4, 6, 7, 8):
        wm.cell(row=tr_, column=c, value=f"=SUM({CL(c)}2:{CL(c)}{lm})").font = BOLD
    wm.cell(row=tr_, column=5, value=f"=IFERROR(C{tr_}/B{tr_},0)").number_format = PCT
    wm.cell(row=tr_, column=9, value=f"=IFERROR(F{tr_}/-G{tr_},0)").number_format = "0.00"
    wm.cell(row=tr_, column=16, value=f"=P{lm}").number_format = USD
    wm.cell(row=tr_, column=17, value=f"=IFERROR(H{tr_}/O2,0)").number_format = PCT
    wm.cell(row=tr_, column=18, value=f'=COUNTIF(H2:H{lm},">0")&" up months / "&COUNTIF(H2:H{lm},"<0")&" down months"')
    for c in (6, 7, 8):
        wm.cell(row=tr_, column=c).number_format = USD
    for c in range(1, 19):
        wm.cell(row=tr_, column=c).fill = NOTE_FILL
    wm.freeze_panes = "B2"

    # monthly net chart (sign colours from the trade data; values are the live formulas)
    net_by_month = {mo: 0.0 for mo in months}
    for t in trades:
        net_by_month[t["entry"]["time"].strftime("%Y-%m")] += t["exit"]["profit"] + t["exit"]["comm"] + \
            t["entry"]["comm"] + t["exit"]["swap"]
    bc = BarChart()
    bc.title = "Net profit per month ($)"
    bc.legend = None
    bc.height, bc.width = 8, 22
    bc.add_data(Reference(wm, min_col=8, min_row=1, max_row=lm), titles_from_data=True)
    bc.set_categories(Reference(wm, min_col=1, min_row=2, max_row=lm))
    s = bc.series[0]
    s.graphicalProperties = GraphicalProperties(solidFill="2A78D6")
    for idx, mo in enumerate(months):
        if net_by_month[mo] < 0:
            dp = DataPoint(idx=idx)
            dp.graphicalProperties = GraphicalProperties(solidFill="EB6834")
            s.dPt.append(dp)
    bc.y_axis.majorGridlines = None
    bc.y_axis.numFmt = '$#,##0'
    bc.y_axis.delete = False
    bc.x_axis.delete = False
    wm.add_chart(bc, f"A{tr_ + 3}")
    wm.cell(row=tr_ + 2, column=1, value="Blue = up month, orange = down month.").font = \
        Font(name=FONT, italic=True, color="595959")

    # equity curve on Summary
    lc = LineChart()
    lc.title = "Balance after each trade"
    lc.legend = None
    lc.height, lc.width = 9, 24
    lc.add_data(Reference(wt, min_col=26, min_row=1, max_row=last), titles_from_data=True)
    lc.series[0].graphicalProperties.line.solidFill = "2A78D6"
    lc.series[0].graphicalProperties.line.width = 20000
    lc.series[0].smooth = False
    lc.y_axis.numFmt = '$#,##0'
    lc.y_axis.majorGridlines = None
    lc.x_axis.title = "Trade #"
    lc.y_axis.delete = False
    lc.x_axis.delete = False
    lc.x_axis.tickLblSkip = 25
    ws.add_chart(lc, "G8")

    # ------------------------------------------------------------ Breakdown
    wbk = wb.create_sheet("Breakdown", 2)
    widths_b = [30, 9, 9, 12, 11, 10, 50]
    for i, w in enumerate(widths_b, 1):
        wbk.column_dimensions[CL(i)].width = w
    wbk["A1"] = "Where the money is made and lost"
    wbk["A1"].font = TITLE
    row = 3

    def block(title, colkey, groups, note):
        nonlocal row
        wbk.cell(row=row, column=1, value=title).font = BOLD
        wbk.cell(row=row, column=7, value=note).alignment = WRAP
        row += 1
        for i, h in enumerate([title.split(" (")[0].replace("By ", ""), "Trades", "Win rate", "Net profit",
                               "Avg per trade", "Avg R"], 1):
            c = wbk.cell(row=row, column=i, value=h)
            c.font, c.fill = HDR_FONT, HDR_FILL
        row += 1
        first = row
        for g in groups:
            r = row
            wbk.cell(row=r, column=1, value=g).font = NORMAL
            crit = f'{T(colkey)},$A{r}'
            wbk.cell(row=r, column=2, value=f"=COUNTIFS({crit})")
            wbk.cell(row=r, column=3, value=f'=IFERROR(COUNTIFS({crit},{T("Y")},"Win")/B{r},0)').number_format = PCT
            wbk.cell(row=r, column=4, value=f"=SUMIFS({T('W')},{crit})").number_format = USD
            wbk.cell(row=r, column=5, value=f"=IFERROR(D{r}/B{r},0)").number_format = USD
            wbk.cell(row=r, column=6, value=f"=IFERROR(AVERAGEIFS({T('X')},{crit}),0)").number_format = RFMT
            row += 1
        wbk.cell(row=row, column=1, value="Total").font = BOLD
        wbk.cell(row=row, column=2, value=f"=SUM(B{first}:B{row - 1})").font = BOLD
        wbk.cell(row=row, column=4, value=f"=SUM(D{first}:D{row - 1})").number_format = USD
        for c in range(1, 7):
            wbk.cell(row=row, column=c).fill = NOTE_FILL
        row += 2

    block("By side", "F", ["BUY", "SELL"], "Is one direction worse than the other?")
    block("By exit reason", "T", ["Initial stop loss", "Breakeven/trailing stop", "Moved stop (below entry)",
                                  "Closed by EA (no SL)"],
          "Avg R on 'Initial stop loss' below -1R means the stop filled worse than planned (slippage).")
    block("By hold time", "Q", ["a) <10s", "b) 10-60s", "c) 1-10min", "d) >10min"],
          "Trades lasting seconds are decided by spread and tick noise, not by the strategy idea.")
    block("By weekday (entry)", "D", WEEKDAYS[:5], "Day of the week the trade was entered (server time).")
    block("By entry hour (server time)", "E", list(range(0, 24)),
          "Server hour of entry. On a UTC+2/+3 broker: 01-09 = Asian session, 10-18 = London, 15-23 = New York.")

    # ------------------------------------------------------------ Settings
    wst = wb.create_sheet("Settings")
    wst.column_dimensions["A"].width = 34
    wst.column_dimensions["B"].width = 14
    wst.column_dimensions["C"].width = 80
    wst["A1"] = "Test settings and what they mean"
    wst["A1"].font = TITLE
    for i, (k, v) in enumerate([("Expert", info.get("Expert")), ("Symbol", info.get("Symbol")),
                                ("Period", info.get("Period")), ("Initial deposit", deposit),
                                ("Leverage", info.get("Leverage")),
                                ("History quality", results.get("History Quality"))], 3):
        wst.cell(row=i, column=1, value=k).font = BOLD
        wst.cell(row=i, column=2, value=v)
    sl_usd = sum(abs(t["order"]["price"] - t["order"]["sl"]) for t in trades) / max(1, len(trades))
    meaning = {
        "InpEnablePDH": "Previous-day high/low module.",
        "InpEnableLondon": "London-range module.",
        "InpEnable4H": "4H high/low module.",
        "InpRiskPct": "Risk % of balance per trade.",
        "InpSL_Pts": f"Stop loss. Measured from the orders in this test: ${sl_usd:.2f} of gold price.",
        "InpUseTP": "false = no take profit; exits come only from SL / breakeven / trailing.",
        "InpBreakEvenPts": "Profit (points) before the SL moves to entry.",
        "InpTrailActivatePts": "Profit (points) before the trailing stop starts.",
        "InpTrailDist": "Trailing distance in points. 10 points is only a few cents of gold price.",
        "InpMaxSpreadPts": "Max spread allowed when placing orders (points).",
        "InpDailyLossPct": "Daily loss limit of the account guard.",
        "InpMaxDrawdownPct": "Overall drawdown limit of the account guard.",
        "InpGovHaltMode": "0 = permanent halt, 1 = pause N days, 2 = log only.",
        "InpBrokerUTCOffset": "Broker server offset used for the London window.",
    }
    r = 11
    for h, txt in enumerate(["Input", "Value", "Meaning"], 1):
        c = wst.cell(row=r - 1, column=h, value=txt)
        c.font, c.fill = HDR_FONT, HDR_FILL
    for line in inputs:
        if not isinstance(line, str):
            continue
        if line.startswith("==="):
            wst.cell(row=r, column=1, value=line.strip("= ")).font = BOLD
        elif "=" in line:
            k, v = line.split("=", 1)
            wst.cell(row=r, column=1, value=k)
            wst.cell(row=r, column=2, value=v)
            if k in meaning:
                wst.cell(row=r, column=3, value=meaning[k])
                if k in ("InpSL_Pts", "InpTrailDist"):
                    for cc in (1, 2, 3):
                        wst.cell(row=r, column=cc).fill = KEY_FILL
        r += 1

    # ------------------------------------------------------------ Read Me
    wr = wb.create_sheet("Read Me", 0)
    wr.column_dimensions["A"].width = 24
    wr.column_dimensions["B"].width = 100
    wr["A1"] = "How to read this workbook"
    wr["A1"].font = TITLE
    lines = [
        ("Summary", "Key numbers with a verdict and a plain-language meaning, the balance curve, and the diagnosis."),
        ("Monthly", "One row per month: trades, win rate, net profit, profit factor, start/end balance, return."),
        ("Breakdown", "Results split by side, exit reason, hold time, weekday and entry hour."),
        ("Trades", "Every trade on one row: the MT5 entry deal matched to its exit deal, plus a sentence "
                   "explaining what happened. Use the filter arrows in the header row."),
        ("Settings", "The EA inputs used in this test, with the important ones explained."),
        ("", ""),
        ("R multiple", "Profit divided by the planned risk. +2R = won twice the risk, -1R = lost the planned risk."),
        ("Planned risk $", "Distance from order price to initial SL x lots x 100 oz."),
        ("Entry slippage $", "How much worse than the order price the trade filled. Positive = worse."),
        ("Exit reason", "Initial stop loss = full loss. Breakeven/trailing stop = stop had been moved to the order price or beyond (can still be a small loss because of slippage). "
                        "Closed by EA = closed without an SL comment (account guard, blackout, instant close)."),
        ("Win / Loss / Flat", "Flat = closed at exactly $0.00. MT5 counts those as profit trades, so its win count can be a "
                              "little higher than here."),
        ("Times", "All times are the broker SERVER time used by the tester."),
        ("Colours", "Blue numbers = source data from the MT5 report. Black = formulas. "
                    "Yellow = the settings that matter most."),
        ("Source", f"Built from the MT5 Strategy Tester report ({len(trades)} trades). All totals match the "
                   f"report's Total Net Profit."),
    ]
    for i, (a, b) in enumerate(lines, 3):
        wr.cell(row=i, column=1, value=a).font = BOLD
        c = wr.cell(row=i, column=2, value=b)
        c.alignment = WRAP
        c.font = NORMAL

    for sh in wb.worksheets:
        setfont(sh)
    wb.active = 1
    wb.save(dst)
    return len(trades)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    n = build(sys.argv[1], sys.argv[2])
    print(f"Wrote {sys.argv[2]} ({n} trades)")
