# v7.71 XAUUSD report - entry / exit / trailing analysis

Test: XAUUSD.T_S20-30, 100% real ticks, 2022-04-04 .. 2022-06-27 (the test stopped after 3 months), 267 trades,
SL $1.80, RR 1, breakeven +0.80 -> +0.30, trailing start 1.0 / distance 0.5 / step 1.0, PDH + RANGE 07:00-09:00 + 4H 08-20.
Result -$1,031 (-20.6%), PF 0.62, expectancy -0.179R (standard error 0.053R -> clearly negative, not bad luck).

Scripts: tools/report_v7_71/ (build.py pairs entries/exits from the report, an*.py make the tables).

## 1. Why it loses (the structural reason)
| | per trade |
|---|---|
| spread (S20-30) | ~$0.25 = 0.14R |
| entry slippage past the level | $0.12 = 0.07R |
| stop overshoot on SL exits | $0.12 x 44% = 0.03R |
| **total cost** | **~0.24R** |
| actual expectancy | -0.18R |

Gross edge before costs is about zero. Outcome odds match a random walk: price reached +$0.80 first in 55.8% of
trades; a random walk with this spread does it 58-60% of the time. With a $1.80 stop the costs are a quarter of the
risk; with a $14 stop the same costs are 0.03R.

Exits: TP 68 (avg +0.99R), breakeven 81 (+0.14R), stop 118 (-1.07R). 50 of 118 stops filled worse than -$1.90.

## 2. Trailing never ran
TrailStep 1.0 is larger than the gap between the trail level (+0.5) and the breakeven SL (+0.3), so the first trail
move needed price at +$1.8 = the TP. 0 trades were closed by trailing. Fixed in v7.84 (the step applies only after
the first trail move).

## 3. Time of entry - the one strong pattern
| | trades | avg R | net $ |
|---|---|---|---|
| filled < 30 min after the level appeared | 116 | -0.28 | -694 |
| 30-60 min | 56 | -0.11 | -141 |
| 60-180 min | 73 | -0.05 | -75 |
| 4H: first 30 min of the H4 candle | 68 | **-0.36** | **-530** |
| 4H: 30-60 min | 40 | -0.08 | -76 |
| 4H: 1-4 h into the candle | 53 | **+0.10** | +111 |

Over half of the total loss is 4H straddles filling in the first 30 minutes of a new H4 candle (08:00, 12:00, 16:00
server). The "worst hours" (08-09, 12, 16) are these fills plus RANGE breakouts right after the 09:00 range end -
the cause is "fresh level", not the clock hour.

Session (server time): Asia 01-07 -0.28R (22), 08-09 -0.26R (86), 10-11 +0.07R (22), 12-15 -0.18R (71),
16 -0.20R (49), 17-21 +0.12R (17). Only 08-09 and 12-16 have enough trades to mean anything.

## 4. What does NOT separate winners from losers (do not add filters for these)
- Direction: BUY -0.13R, SELL -0.22R; difference is inside the noise (and gold fell in this period).
- Hour x direction: groups of 4-30 trades, standard error 0.15-0.4R - noise.
- Day of week: all five days -0.10 to -0.24R.
- Month: Apr -0.21R, May -0.11R, Jun -0.24R - consistently negative.
- Level width: <$10 -0.20R, $20+ -0.10R (weak, not reliable).
- With / against the previous-day breakout, after a win / after a loss, same direction as the last trade: no real difference.

## 5. Recommended model (v7.84 + preset v7_84_recommended.set)
- Entry: unchanged straddles, but orders only from 60 min after the level appears (InpEntryDelayMin = 60).
- SL $14 (earlier optimisation: $11-16 profitable, < $10 loses), TP 2R.
- Breakeven at +1R (= SL), lock +$0.50.
- No trailing until the trade log shows winners giving back profit.
- Max 3 trades/day; second fill on the same tick is closed (one trade at a time).
Validate on the full 2022-2026 period, then on 2025-2026 alone, before trusting it.

## 6. What this report cannot answer
The MT5 report has no per-trade MFE/MAE, so "how far winners run" and "how far losers go first" are only bounded:
stopped trades never reached +$0.80; breakeven trades reached +$0.80 but not +$1.80. The EA already writes
SB_trades_<symbol>.csv (MFE, MAE, post-exit move); send it from the full-period run.
