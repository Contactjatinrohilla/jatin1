# PDH/PDL breakout: audit, controlled tests and one candidate strategy

**Short answer.** A plain PDH/PDL breakout has **no meaningful edge after costs** when you trade it on everything.
On the US equity indices, including the NAS100 the reference EA was built for, it **loses money even before
costs**, in every period from 2005 to 2020. One simple version (stop entry, no trades in the first 2 server hours,
skip days after a wide previous day, 1×ATR stop, close at day end) has a **small positive expectancy of about +0.01R
per trade**. That holds in all three chronological periods, but it is only about as large as the trading costs, and
it comes almost entirely from gold, crude oil, the Nikkei and Bitcoin. The EA implements that version
(`ea/pdh_pdl/PDH_PDL_Breakout.mq5`). Treat it as a hypothesis you must confirm on your own broker's data, not as a
proven money-maker.

---

## Step 1 – What the reference EA does (`ea/nas/NAS_PDH_PDL_Breakout.mq5` v1.23)

1. On the first tick of each server day it takes PDH/PDL from the previous D1 candle. Sunday stubs shorter than 6 h
   are skipped, or it can use the cash session instead.
2. At the window start (default 00:00, the first tick of the day) it places a BUY STOP at PDH + buffer and a SELL STOP
   at PDL − buffer. A side is skipped if price is already beyond its level.
3. First fill deletes the other order (OCO). At most one trade per day.
4. SL is a fixed number of index points (default 50), at the opposite level, or a % of yesterday's range. TP = RR × SL
   (default 2). Optional breakeven, continuous or stepped trailing.
5. Everything is closed at the window end (5 min before the session close) and at the Friday close.
6. Lot = 0.5 % of balance at the SL, using `OrderCalcProfit` and capped by free margin.
7. `OnTesterInit` opens optimisation ranges for SL, RR, buffer, BE and trailing (thousands of combinations), and
   `OnTester` ranks them by PF × √trades.

## Step 2 – Verified coding problems vs. strategy weaknesses

### Coding / execution problems (verified by reading the code)
| # | Problem | Effect |
|---|---|---|
| 1 | `NewDay()` never removes orders or positions left over from the previous day. If no tick arrives between the window end and midnight (early holiday close, data gap), yesterday's GTC stop orders stay live, and `CountPendings() > 0` then sets `g_ordersDone = true`. | Today's orders are **not placed** and **yesterday's stale levels can fill**. A position can also be carried overnight. (The sibling EA `NAS_Breakout_Simple` fixed this same bug in 1.27; this EA still has it.) |
| 2 | Orders are placed at the **first tick after 00:00 server**, which is the daily rollover. | The tests show entries in the first 2 server hours lose −0.05R per trade (t ≈ −3 in every period), even before counting the extra rollover spread, which the backtest does not model. Real rollover spreads are wider still. |
| 3 | The BUY STOP sits at PDH but triggers on **Ask**, while PDH comes from the **Bid** chart. | Longs fill when the bid is still a spread *below* PDH. They enter before a real breakout, so longs and shorts are treated differently. |
| 4 | Distances are fixed index points (SL 50, BE 50, trail 40 …). | The same input means a very different risk as the index moves from 7,000 to 20,000, and it cannot transfer to any other symbol. |
| 5 | The risk calculation ignores spread and commission. | Real loss at the stop is a bit larger than 0.5 %. (Small.) |
| 6 | Optimisation ranges cover SL × RR × buffer × BE × trail with PF × √trades as the objective. | Almost guarantees a curve-fitted "best" set. Nothing in the EA separates in-sample from out-of-sample. |
| 7 | `TradeDayAllowed` blocks Saturday and Sunday, and `PrevWeekday` assumes a Mon–Fri market. | Cannot be used on crypto weekends. |

Everything else checked was correct: no look-ahead in the D1 levels, restart detection through the deal history,
margin cap, tick-size rounding, stop/freeze-level checks, and `OrderCalcProfit`-based sizing.

### Strategy hypotheses for the poor results, and what the tests said
| Hypothesis | Result |
|---|---|
| H1: breakouts of PDH/PDL on NAS100 have no follow-through | **Confirmed.** Stop entry gross expectancy on NAS100 is −0.02 to −0.01R in all periods; SPX500 and US2000 are similar. US indices tend to *revert* at yesterday's extremes. |
| H2: costs are a large share of a small stop | **Confirmed.** At SL = 0.25×ATR, costs are 0.06–0.10R per trade, which turns a +0.03–0.06R gross edge into −0.05R. The earlier XAUUSD report found the same thing (costs ≈ 0.24R with a $1.80 stop). |
| H3: rollover / first-hours entries are bad | **Confirmed.** See problem #2. |
| H4: breakouts after a big previous day fail | **Confirmed.** Previous range > 1.3×ATR: −0.03 to −0.05R in all three periods. |
| H5: waiting for a candle close or a retest filters false breaks | **Rejected.** Both are worse than the plain stop order on 11–12 of 13 instruments (see Step 3). |
| H6: BE / trailing / a higher RR fixes it | Not needed. With a 1×ATR stop, about 90 % of trades end at the day end, so the exit barely matters. RR 1, 2 and "no TP" give almost the same result. No breakeven or trailing was added. |

## How the tests were done

* **Data:** free 1-minute mid prices from Oanda, 2005 – May 2020, for NAS100, SPX500, US2000, UK100, JP225,
  XAUUSD, WTI, EURUSD, GBPUSD, USDCAD, AUDUSD and EURJPY, plus Bitstamp BTCUSD 2014–2017. That is 13 instruments and
  about 15 years, including 2008, the 2011 euro crisis, the 2015 franc/oil shocks, 2018 and the March 2020 crash.
  Scripts are in `research/pdh_pdl/`, and `fetch_data.sh` + `run_all.sh` reproduce every number.
* **Server time:** bars are shifted to New York + 7 h (the usual UTC+2/UTC+3 MT5 server), so a "day" and its D1
  high/low match a typical broker.
* **No look-ahead:** PDH, PDL and ATR(14) come only from completed earlier days. Days with less than 6 h of data
  (Sunday stubs, holidays) are not used as level days. Levels older than 4 days are not traded.
* **Pessimistic fills:** stop entries fill at the worse of the bar open and the level. If SL and TP are inside the same
  minute bar, the SL counts. An SL touch on the entry bar counts as a loss.
* **Costs per trade:** round-trip spread + commission, plus slippage on every stop/market fill, all in basis points
  of price. For example: EURUSD 0.8 bp (≈ 0.9 pip) + 0.1 bp per fill; XAU 2 bp (≈ $0.30 at $1,500) + 0.3 bp;
  NAS100 1.5 bp + 0.3 bp; BTC 20 bp + 3 bp. Positions close before the rollover, so there is no swap. Every
  candidate was also run at **2× costs**.
* **Periods:** in-sample 2005–2012, validation 2013–2016, out-of-sample 2017–2020 (BTC: 2014–15 / 2016 / 2017).
  Choices were made on in-sample numbers. Validation and out-of-sample were only checked.
* **Unit:** R = the stop distance, so results are comparable across instruments. "Gross" = before costs.

## Step 3 – Entry methods compared (same stop, target and day-end exit)

Equal-weight mean net expectancy (R per trade) across the 13 instruments, SL = 1×ATR, TP = 2R
(full table: `research/pdh_pdl/results/1_entry_methods.txt`, 36 combinations):

| Entry | Gross IS | Net IS | Net VAL | Net OOS | instruments > 0 (IS/VAL/OOS) |
|---|---|---|---|---|---|
| **Stop order at PDH/PDL (direct)** | **+0.018** | **−0.001** | **−0.006** | **−0.000** | **7 / 5 / 6** |
| Breakout then retest (limit at level) | +0.010 | −0.006 | −0.020 | −0.012 | 3 / 3 / 3 |
| M15 candle closes beyond, enter next bar | +0.005 | −0.013 | −0.023 | −0.022 | 3 / 3 / 1 |
| H1 candle closes beyond, enter next bar | +0.004 | −0.014 | −0.027 | −0.026 | 3 / 2 / 1 |

The stop order is the best in-sample entry for every stop size (0.25, 0.5, 1×ATR) and every RR (1, 2, none). Gross expectancy pooled over
all exits is higher for the stop order than for H1 close-confirmation on 12 of 13 instruments, and higher than all
three alternatives on 11 of 13 (exceptions: BTC, where the retest is slightly better, and US2000, where everything loses). Waiting for a close
gives a worse price after the move has started. The retest only fills on the breakouts that fail, which is
adverse selection.

**Decision: direct stop order.** It is also the simplest to execute.

Exit/stop size: small stops (0.25×ATR) have the biggest *gross* edge in R, but costs destroy it. The *absolute*
edge is about 0.015×ATR per trade whatever the stop, so a wider stop simply makes the costs a smaller share.
**SL = 1×ATR** was the most stable in-sample choice. **TP = 2R** is kept only as a cap. The day-end close does most of
the exiting.

## One variable at a time on the stop-entry baseline

(`results/2_one_variable_tests.txt`, `results/3_filter_sensitivity.txt`)

| Change (vs. stop, SL 1 ATR, TP 2R) | Net IS | Net VAL | Net OOS | Adopted? |
|---|---|---|---|---|
| baseline | −0.001 | −0.006 | −0.000 | |
| entry buffer 0.1 / 0.25 ATR beyond the level | −0.008 / −0.005 | −0.012 / −0.012 | −0.007 / −0.011 | no – worse |
| both sides allowed (no OCO) | −0.001 | −0.004 | −0.001 | no – same, more exposure |
| entries only 08:00–20:00 server | +0.001 | −0.007 | −0.000 | no – no gain |
| **no entries before 02:00 server** | **+0.007** | **+0.000** | **+0.007** | **yes** (also avoids rollover spreads) |
| long only | +0.015 | +0.003 | +0.009 | **no** – this is the 2005–2020 bull market, not a breakout edge |
| **skip if previous range > 1.0 × ATR** (with the 02:00 start) | **+0.021** | **+0.012** | **+0.013** | **yes** |

Sensitivity of the two adopted filters. Every nearby value stays positive in all three periods, so the choice sits on a
plateau, not a spike:

| Start hour × max range/ATR | 0.8 | 1.0 | 1.2 | off |
|---|---|---|---|---|
| 01:00 | +.023 / +.018 / +.009 | +.017 / +.012 / +.010 | +.011 / +.006 / +.008 | +.004 / .000 / +.001 |
| **02:00** | +.025 / +.019 / +.012 | **+.021 / +.012 / +.013** | +.014 / +.008 / +.015 | +.007 / .000 / +.007 |
| 03:00 | +.023 / +.022 / +.005 | +.019 / +.017 / +.010 | +.013 / +.014 / +.012 | +.006 / +.005 / +.004 |

(IS / VAL / OOS net R.) Stop and target around the candidate (SL 0.5–1.5 ATR × RR 1, 2, none) are all positive in
every period except one cell (SL 0.5 / RR 1 in VAL: −0.005).

A volatility filter based on yesterday's range *does* help. A session filter beyond "skip the rollover" does not.

## Step 4 – The candidate (what the new EA trades)

| Rule | Exact definition |
|---|---|
| Levels | PDH/PDL = high/low of the last complete server day (≥ 6 h of M1 data). Nothing from today. |
| ATR | Mean true range of the 14 complete days before today. |
| Day filter | No trade today if PDH − PDL > 1.0 × ATR, or if the levels are older than 4 calendar days. |
| Entry time | From 02:00 server time until the day end (default 23:50, earlier if the broker session ends earlier). |
| Entry | BUY STOP at PDH (+ current spread, so it triggers when the bid breaks PDH) and SELL STOP at PDL. A side is skipped for the day if its level was already touched before the order could be placed. |
| Stop loss | 1.0 × ATR from the order price. |
| Take profit | 2 × stop distance. |
| Time exit | Anything open at the day end is closed and unfilled orders are deleted. No overnight, no weekend. |
| Frequency | First fill cancels the other order. Max **one trade per symbol per day**, enforced from the deal history so restarts cannot duplicate it. |
| Simultaneous signals | If both stops fill in one fast move, the second position is closed at once. |
| Stale orders | Orders carry a broker-side expiry at the day end when the broker allows it, and the EA deletes anything from an earlier day on the first tick of the new day. |
| Risk | 0.5 % of balance at the stop (lot rounded *down*, never up). Lot is capped by free margin. Daily loss stop 2 % for all symbols on this magic. Max 3 open positions. Waits while spread > 10 % of the stop. |

## Step 5 – Evidence for the candidate, and its limits

Net results per instrument (`results/4_candidate.txt`). E = mean net R per trade, t = t-statistic, DD = max drawdown
in R:

| Instrument | trades/yr | E IS | E VAL | E OOS | E all | t all | PF | DD (R) | Recovery | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|
| XAUUSD | 124 | +0.071 | +0.061 | −0.009 | +0.049 | 3.5 | 1.25 | 20 | 4.2 | positive, but flat/negative 2017–18 |
| WTI oil | 118 | +0.017 | +0.066 | +0.030 | +0.033 | 2.5 | 1.17 | 14 | 4.3 | positive in every period |
| JP225 | 90 | +0.020 | +0.037 | +0.030 | +0.029 | 2.1 | 1.17 | 11 | 3.3 | positive in every period |
| BTCUSD (2014–17) | 144 | +0.118 | +0.061 | +0.130 | +0.105 | 4.5 | 1.74 | 3 | 23 | strong, but long-only bull market, high costs, short history |
| EURJPY | 121 | +0.002 | +0.009 | +0.049 | +0.014 | 1.2 | 1.08 | 17 | 1.6 | weak |
| USDCAD / AUDUSD / UK100 / GBPUSD | 115–127 | ≈ +0.01 to +0.03 | − to + | − to + | +0.002 to +0.010 | < 0.8 | ≈ 1.0–1.05 | 24–34 | < 0.7 | no edge |
| EURUSD | 126 | −0.003 | +0.006 | −0.001 | −0.000 | 0.0 | 1.00 | 15 | — | no edge |
| **NAS100** | 118 | −0.018 | −0.027 | +0.007 | **−0.015** | −1.2 | 0.93 | 43 | — | **negative – do not trade** |
| SPX500 | 115 | −0.003 | −0.021 | −0.002 | −0.008 | −0.6 | 0.97 | 23 | — | negative |
| US2000 | 123 | −0.008 | −0.019 | −0.025 | −0.014 | −1.1 | 0.93 | 40 | — | negative |

All 13 pooled: 21,990 trades, **+0.011R per trade (t = 3.1)**. By period: IS +0.014 (t 2.8), VAL +0.010 (t 1.4),
**OOS +0.007 (t 0.9, not significant on its own)**.

What else the tests show:
* **At 2× costs the pooled edge is gone** (IS +0.003, VAL −0.012, OOS −0.009). The edge is roughly the size of the
  costs. Broker choice and execution decide whether this makes or loses money.
* **The result depends on big days.** Removing each instrument's best 5 % of trades turns every instrument
  except BTC negative. That is normal for breakout/trend strategies (many small day-end exits, a few trend days pay
  for them), but it means long flat or losing stretches are expected. Worst calendar year, all 13 pooled: −25R.
* **Placebo test** (`results/5_placebo_long_short.txt`): moving the levels by ±0.1 or ±0.25 ATR lowers the result,
  and moving them 0.25 ATR *inside* the range turns it negative. The exact PDH/PDL works best, so the levels carry
  some information. The effect is small.
* **Long vs short:** gold and oil earn on both sides (+0.05 / +0.05, +0.03 / +0.03R), which looks like real breakout
  behaviour. BTC (+0.19 long vs +0.01 short) and JP225 are mostly long-side, so part of their result is market
  drift, not the breakout.
* **Hindsight warning:** a portfolio of the three best instruments (XAU + WTI + JP225) made +182R with a 16R max
  drawdown (≈ +12R/yr). I picked those three after seeing all periods, so that number is optimistic. If you pick
  instruments from in-sample results only (t > 1.5: XAU, BTC, AUDUSD, USDCAD), the later periods average
  +0.026R, and BTC carries most of it.
* **In money terms:** at 0.5 % risk, gold alone ≈ +3 % a year with a 10 % max drawdown over 14 years. Modest, and it
  needs low costs.

**Honest conclusion:** a basic PDH/PDL breakout does **not** have a reliable cross-asset edge after realistic costs.
The candidate shows a small, consistent, statistically weak edge on instruments that trend intraday (gold, oil,
Nikkei, crypto) and none on FX majors or US indices. Trading NAS100 with any version of this idea is not supported
by the evidence.

## What this study cannot tell you, and what to send next

The data is Oanda mid-price M1 bars, not your broker's bid/ask ticks, and it ends in May 2020. The cost model is an
assumption, and rollover spread spikes are not modelled. Before risking money, run the new EA in the MT5 Strategy
Tester with **"Every tick based on real ticks"** on your broker's symbols, and send me:

1. The **full tester report** (Ctrl+S, `.html` or `.xlsx`) for each symbol for **2020-06 → today**. That is a true
   out-of-sample period this study never saw. Priority: XAUUSD, a WTI symbol, JP225, BTCUSD, EURUSD (control) and
   NAS100 (expected negative).
2. The same with `MaxRangeATR = 0` and `EntryStart = 00:00`, which switches both filters off. If the filters do not help
   on your data either, drop them.
3. The **Journal/Experts log** of one run. Every skipped day and order prints its reason.
4. Your broker's **commission per lot**, **swap**, and the symbols' **typical spread at 02:00–04:00 server time**.
5. A **demo forward test** of at least 3 months to measure real slippage on the stop fills (the `FILLED` log line
   prints slippage + spread for each fill).

Decision rule fixed in advance: keep a symbol only if its 2020–today test has a profit factor > 1.1 with at least
150 trades **and** stays positive when you add one extra spread of cost. Otherwise drop it. Do **not** re-optimise
the inputs on that period.

## Files

* `ea/pdh_pdl/PDH_PDL_Breakout.mq5`: the new EA (9 inputs). The reference EA is unchanged in `ea/nas/`.
* `research/pdh_pdl/`: backtester (`bt.py`), study scripts, `fetch_data.sh`, `run_all.sh`, and `results/` (raw output
  of every table above).

## Update: EA v2.10 uses fixed SL/TP (no ATR)

At your request, the EA now uses a **fixed stop loss and take profit in price distance** (`InpSL`, `InpTP`, set per
symbol) and the ATR range filter has been removed. Everything else is unchanged: 02:00 start, OCO, one trade per day,
day-end close, risk sizing and the protections.

The same backtest with fixed distances (02:00 start, no range filter, net of costs):

| Symbol | SL / TP | 2010–2016 | 2017–2020 |
|---|---|---|---|
| NAS100 | 50 / 100 pts | −0.004R (PF 0.98) | +0.037R (PF 1.10, t 0.9) |
| NAS100 | 25 / 50 pts | −0.008R (PF 0.98) | +0.013R (PF 1.02) |
| XAUUSD | $5 / $10 | +0.047R (PF 1.08) | −0.078R (PF 0.86) |
| XAUUSD | $10 / $20 | +0.031R (PF 1.08) | −0.025R (PF 0.92) |
| EURUSD | 20 / 40 pips | +0.004R (PF 1.01) | −0.036R (PF 0.94) |

None of these is statistically different from zero, and the sign flips between periods. A fixed distance also means
a different risk as prices move (50 NAS points was ~1 % of price in 2016 and ~0.25 % today), so values that work in one
year will not mean the same thing a few years later. Re-check SL/TP on recent data for each symbol and keep them in
proportion to the symbol's normal daily range.
