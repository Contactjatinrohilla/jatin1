# Backtest analysis: PDH_PDL_Breakout v2.30 on NDX100.m (FundingPips, 2023-04 to 2026-10)

Settings: M1 close confirmation, SL 50 / TP 100 points, breakeven 50 → +1, trailing 50/50, risk 0.5 %, 100 % real ticks.

## Result
634 trades, net **+$261** on $100k, **PF 1.004**, max drawdown 10.3 %, Z-score −0.82.
Mean −0.016R per trade (t = −0.4). This is **no edge**: the outcome is indistinguishable from zero.
By year: 2023 +$9,062, 2024 −$5,587, 2025 −$855, 2026 −$2,359. The 2023 gain was given back.

| Exit | Trades | Result |
|---|---|---|
| Take profit (+100) | 118 | +$56,462 |
| Full stop loss (−50) | 305 | −$70,371 |
| SL moved by breakeven/trailing | 177 | +$13,515 (avg +17 pts) |
| Closed by the EA | 34 | +$654 |

## Bug found: the day-end close never happened
All 34 "EA" closes happened at **01:00–01:07 the next day**, never at the 23:50 day end. The NDX100.m tick stream
stops before 23:50 server time, so the `mins >= DayEnd` check never ran. Every trade still open at the close was held
overnight, and six over a weekend or holiday (up to 64 h). That cost **−$670 of swap** plus overnight gap risk. Entries
were also accepted up to 23:10, minutes before the market closed.

Fix in v2.31:
* Each day the EA reads the last M1 bar of the previous 3 same weekdays (median), and closes **10 min before** the
  market's usual last tick if that is earlier than DayEnd or the session table. This also handles shorter Friday
  sessions.
* **No new entries in the last 30 minutes** before the day end. Unfilled orders are deleted then, and their broker-side
  expiry is set to that time too.

## Other findings (no code change)
* **Risk is capped by margin, not by the 0.5 % input.** The test account needs about 1:1 margin on NDX (margin level
  fell to 110 %), so the free-margin cap cut the lot. The money risked per stop fell from $311 (2023) to $162 (2026) as
  the index rose. The EA logs "Lot reduced … to fit the free margin" when this happens.
* **A fixed 50-point stop shrank from 0.38 % to 0.18 % of price** as NDX went from ~13,000 to ~28,000. It is now well
  inside normal intraday noise. Win rate fell from 55 % (2023) to 46–47 %.
* **Hours:** entries 02:00–09:00 server lost −$8.8k (−0.19R, 192 trades) and 09:00–18:00 made +$8.8k. But in
  2005–2020 US-index data the 02–09 window was *not* worse than the rest (−0.07 to +0.02R). The pattern does not
  repeat, so it was not turned into a filter.
* **Long vs short:** long −$2.6k, short +$2.8k. That is noise at this sample size.
* **M1 confirmation** reacts to every 1-minute close. In the 15-year study, M15/H1 confirmation was already worse than
  the plain stop order.
