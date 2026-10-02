# XAUUSD breakout EA: time, data and testing guide

## 1. The gold trading day in UTC

Most gold brokers and prop firms run their MT5 server on **UTC+2 in winter and UTC+3 in US summer time**.
That makes the server clock = **New York time + 7 hours**, so the daily candle closes at 17:00 New York.
Your Dukascopy data is in **UTC**, and that's why the times have to be shifted (see section 4).

US summer time: 2nd Sunday of March → 1st Sunday of November.
UK summer time: last Sunday of March → last Sunday of October.
India (IST = UTC+5:30) has no daylight saving time.

| Event | New York | **Server** (UTC+2/+3) | UTC summer | UTC winter | IST summer | IST winter |
|---|---|---|---|---|---|---|
| Daily break (gold closed) | 17:00–18:00 | **00:00–01:00** | 21:00–22:00 | 22:00–23:00 | 02:30–03:30 | 03:30–04:30 |
| New gold day opens | 18:00 | **01:00** | 22:00 | 23:00 | 03:30 | 04:30 |
| Tokyo session (09:00–18:00 Tokyo) | — | 03:00–12:00 / 02:00–11:00 | 00:00–09:00 | 00:00–09:00 | 05:30–14:30 | 05:30–14:30 |
| **London open** (08:00 London) | 03:00 | **10:00** | 07:00 | 08:00 | 12:30 | 13:30 |
| London PM gold fix (15:00 London) | 10:00 | **17:00** | 14:00 | 15:00 | 19:30 | 20:30 |
| **London close** (16:00 / 16:30 London) | 11:00 | **18:00 / 18:30** | 15:00 | 16:00 | 20:30 | 21:30 |
| New York open (08:00 NY) | 08:00 | **15:00** | 12:00 | 13:00 | 17:30 | 18:30 |
| US data releases (08:30 NY) | 08:30 | **15:30** | 12:30 | 13:30 | 18:00 | 19:00 |
| London / NY overlap | 08:00–11:00 | **15:00–18:00** | 12:00–15:00 | 13:00–16:00 | 17:30–20:30 | 18:30–21:30 |

**Useful fact:** on a UTC+2/+3 server, London 08:00 is **10:00 server time all year**. The exceptions are about
3 weeks in March and 1 week in late October, when the US and UK clocks change on different dates. During those
weeks London opens at 09:00 server time. (In 2026: 8–29 March and 25 October–1 November.)

Check your own broker: compare the Market Watch clock with the real UTC time. If the server is 2 or 3 hours ahead
of UTC, depending on the season, this table applies.

## 2. What the "London range" is

The London range is the **highest high and lowest low between London open and London close** on the current day.

| | London local | Server (UTC+2/+3) | UTC (summer / winter) |
|---|---|---|---|
| Range starts | 08:00 | 10:00 | 07:00 / 08:00 |
| Range ends | 16:00 | 18:00 | 15:00 / 16:00 |

After the range ends, a BUY STOP goes above the range high and a SELL STOP below the range low.

**What your old v6.03 actually did:** `InpLondonOpenUTC=8`, `InpLondonCloseUTC=16`, `TZ_FIXED`, offset `+3`, so it
always used server 11:00–19:00. On a real broker that is **London 09:00–17:00**, an hour late, because "8 UTC" is
09:00 London time in summer.
**In the Strategy Tester with raw Dukascopy data (UTC timestamps)** the same setting gave UTC 11:00–19:00, which is
**London 12:00–20:00**. That is the wrong session entirely, and the PDH/PDL levels were wrong too, because the D1
candles were cut at UTC midnight and included a small Sunday candle. Your backtests may not have matched the live
account for this reason alone.

The v7 EA uses server time directly: `InpRangeStart=10:00`, `InpRangeEnd=18:00`. To reproduce the old
behaviour, use `11:00` and `19:00`.

## 3. 2-digit vs 3-digit prices

| Source | Example price | 1 point | "120 points" |
|---|---|---|---|
| Typical broker / prop firm | 2650.**13** | $0.01 | **$1.20** |
| Dukascopy | 2650.**125** | $0.001 | **$0.12** |

The same EA input means a **10× different stop loss** depending on the data. If you backtested v6.03
(`InpSL_Pts=120`, trail 10) on 3-digit Dukascopy data, the backtest used a **$0.12 stop and a $0.01 trailing
distance**, which can't happen on your live account.

Two fixes, use both:
1. The converter rounds the data to **2 digits**, the same as your broker.
2. The v7 EA uses **USD price distance** inputs (`InpSL_USD = 5.00` = a $5 move), so the number of digits makes
   no difference. At startup it prints the conversion, for example `SL $5.00 = 500 points`.

## 4. Fixed spread from Dukascopy data

Your prop firm's spread is 12–47 points (2 digits) = **$0.12–$0.47**. To test with a fixed 25 points = **$0.25**:

```
python3 tools/dukascopy_to_mt5.py  XAUUSD_dukascopy.csv  XAUUSD_mt5.csv  --spread 0.25 --digits 2
```

The converter:
- takes the Dukascopy mid price and sets `bid = mid − 0.125` and `ask = bid + 0.25`, so every tick has a $0.25 spread
- rounds to 2 digits
- shifts UTC to server time (UTC+2 winter / UTC+3 US summer), so D1 candles, PDH/PDL and session times match the broker
- prints the **original** Dukascopy spread statistics, so you can see how wide it was

Other options: `--spread 0` keeps the original spread. `--tz none` is for files that are already in server time,
such as ticks exported from an MT5 custom symbol (detected automatically). Use `--tz fixed --offset 2` for a broker
on a fixed offset. If your account charges commission, add its price equivalent to the spread to keep testing
simple. For example, $7 per lot round-trip ≈ $0.07, so use `--spread 0.32`.

Input formats: the Dukascopy CSV export (`Gmt time,Ask,Bid,...`), dukascopy-node (`timestamp,askPrice,bidPrice`),
and MT5 tick exports (`<DATE> <TIME> <BID> <ASK>`). `.gz` files work too.

### Import into MT5
1. MT5 → **View → Symbols → Create Custom Symbol**. In **Copy from**, choose your broker's **XAUUSD** (this copies
   contract size 100, margin and profit settings). Name it e.g. `XAUUSD_DK`, set **Digits = 2**, click OK.
   If you already have a 3-digit Dukascopy symbol, make a new one. Don't mix the two.
2. Select the symbol → **Ticks** tab → **Import Ticks** → pick `XAUUSD_mt5.csv`. Check that the column preview shows
   Date / Time / Bid / Ask, then click Import.
3. Strategy Tester: symbol `XAUUSD_DK`, modelling **"Every tick based on real ticks"**, deposit and leverage the same
   as your account.

## 5. The simple v7 EA (`ea/XAUUSD_Simple_Breakout_v7.mq5`, base rules - see section 8 for v7.10 options)

The whole strategy:

| | Rule |
|---|---|
| Setup A | From 01:15 server: BUY STOP above **yesterday's high**, SELL STOP below **yesterday's low** |
| Setup B | At 18:00 server: BUY STOP above the **London range high** (10:00–18:00), SELL STOP below its low |
| Exit | Fixed SL ($), TP = SL × `InpRR`, optional breakeven at +1R. **No trailing stop** |
| One at a time | When any order fills, all other pending orders are deleted |
| Limits | Each setup at most once per day, max 2 trades per day, daily loss stop 2.5% |
| End of day | Unfilled orders deleted at 22:00; open trades closed at 22:15 (`InpCloseMode`: daily, Fridays only, or never). The close is moved earlier automatically if the broker session ends before it |
| Size | Risk % of balance; the lot size is calculated by the broker from the SL distance |

Removed compared with v6.03: the 4H module, confirmation modes, the micro breakeven/trailing, timezone models,
spread padding and simulated spread (the converter handles spread now).

## 6. How to test it (in this order)

1. **Check the data first.** Open a D1 chart of `XAUUSD_DK` and compare a few PDH/PDL values with your broker's
   chart. They should match within a few cents. There should be no Sunday candles.
2. **Test each setup on its own.** Run `InpUsePDH=true, InpUseRange=false`, then the reverse, on 2023–2024. Note
   the profit factor, max drawdown, number of trades, and average win vs average loss.
3. **Small, coarse optimisation only.** `InpSL_USD` 3 / 5 / 8 / 12, `InpRR` 1.5 / 2 / 3, `InpBE_R` 0 / 1.
   Pick a setting from a *stable area* of results, not the single best result.
4. **Unseen data.** Run the chosen setting on 2025–2026 without changing anything. If the profit factor stays
   above about 1.2 and the drawdown stays within your prop limits, it is worth trading on a demo account.
5. **Demo forward test** for 4–8 weeks, then compare its trades with the tester run for the same dates.

## 7. Optimising without fooling yourself

Lesson from `Final_optimization_2` (v5.30, 2021–2026, +$113,640 at only **23% real ticks**): the same PDH setups
on the same days made **+$15,654 per lot** there and **−$10,325 per lot** in the 100%-real-tick test. Every dollar
of profit came from trades closed within 60 seconds. With a 10-point trail, a backtest result mostly depends on how
the price moves inside each 1-minute candle, and generated ticks invent exactly that.

Rules:
1. **History quality must say 100% real ticks.** On anything less, the result is not a test of the strategy.
   For older years, use the Dukascopy custom symbol (section 4).
2. **Use exits that don't depend on how price moves inside one candle**: SL of several dollars, TP ≥ 1.5R,
   breakeven ≥ 1R, no micro-trail. A setting whose median trade lasts a few seconds is not a strategy.
3. **Optimise with `Custom max`** (the v7 EA's `OnTester` score = (PF − 1) × √trades ÷ max DD %). It ignores
   settings with fewer than `InpMinTrades` trades, PF ≤ 1 or a loss.
4. **Small grid, stable area:** `InpSL_USD` 3–15 step 1, `InpRR` 1.5–3 step 0.5, `InpBE_R` 0 / 1 / 1.5. Choose a
   setting whose neighbours also score well, not the single top result.
5. **Walk-forward:** optimise on 2023–2024, then run the chosen setting unchanged on 2025–2026.
6. **Stress test:** rerun the chosen setting with a wider spread (`--spread 0.40`) and on a second data feed
   (broker XAUUSD vs Dukascopy). The result has to stay profitable in all of them.
7. **Fixed lots hide risk.** With a fixed 0.5 lot, drawdown % shrinks as the balance grows. Judge drawdown with
   risk-% sizing, or in $ against the starting balance.

## 8. v7.10: editable entries, filters and Custom max

All new inputs default to the v7.01 behaviour, so you can switch on one change at a time and compare.

### Entry (section 2 of the inputs)
| Input | Options | What it tests |
|---|---|---|
| `InpEntryMode` | 0 STOP · 1 STOP-LIMIT · 2 CLOSE · 3 RETEST | How to enter a breakout (optimisable) |
| `InpMaxSlip_USD` | 0.50 | STOP-LIMIT: maximum fill distance past the level. A $5 news-spike fill is skipped instead of taken |
| `InpConfirmTF` | M5 | Candle used by CLOSE / RETEST |
| `InpMaxChase_USD` | 3.00 | CLOSE / RETEST: ignore a close more than this past the level (don't chase spikes) |
| `InpDirection` | Both / Buy / Sell | One-direction test |
| `InpBuffer_USD` | 0.00 | Entry this far beyond the level |

- **STOP**: the original. Fills instantly, but can fill far away in a spike.
- **STOP-LIMIT**: the same trigger, but the fill is capped. If the broker doesn't allow stop-limits, the EA warns
  and uses plain stops.
- **CLOSE**: waits for an M5 (or `InpConfirmTF`) candle to close beyond the level, then buys/sells at market.
  This avoids wick-only fake breakouts.
- **RETEST**: after that close, places a limit order back at the level, so the entry is at the level instead of
  after the move.

### Filters (section 4)
| Input | Example | Effect |
|---|---|---|
| `InpTradeMon` … `InpTradeFri` | false on Monday | Skip weekdays |
| `InpNoTrade1` / `InpNoTrade2` | `15:15-16:00` | No new entries in the window (US data = 15:30 server). `InpWindowCancel` deletes pending orders there; they're placed again after the window. `InpWindowClose` also closes trades |
| `InpNoTradeDates` | `2026.02.06,2026.03.06` | Skip whole days (NFP, CPI, FOMC). Format `yyyy.mm.dd` |
| `InpMinLevelRange_USD` / `InpMaxLevelRange_USD` | 5 / 60 | Skip a setup when its high-low range is too small or too wide |

### Custom max (section 6)
In the Strategy Tester choose **Optimisation: Custom max**, then pick the target with `InpScore`:

| `InpScore` | Maximises |
|---|---|
| 0 Robust (default) | (PF − 1) × √trades ÷ max DD % |
| 1 Profit factor | PF |
| 2 Recovery factor | net profit ÷ max drawdown |
| 3 Net profit | profit |
| 4 Sharpe ratio | Sharpe |
| 5 Average R | expectancy per trade in R |
| 6 Return / DD | return % ÷ max DD % |

Every target is set to **0** when the run has fewer than `InpMinTrades` trades, isn't profitable, has max DD above
`InpScoreMaxDD` %, or has any single trade worse than `−InpScoreWorstR` R. The last check rules out settings that
only look good because of news spikes. The journal prints one `SCORE …` line per pass, giving the reason for any 0.

### Testing the custom entries step by step
1. Load `ea/presets/v7_31_opt1_exits.set (and opt2_trail / opt3_entry)` (Strategy Tester → Inputs → right-click → Load). It optimises
   `InpEntryMode` 0–3, `InpCloseMode` 0–1, `InpSL_USD` 3–12, `InpRR` 1.5–3 and `InpBE_R` 0–1.5 (1,280 combinations).
2. Settings: 100% real ticks (or the Dukascopy custom symbol), 2023–2024, **Custom max**, `InpScore = 0`.
3. In the Optimisation Results tab, sort by result and look for an entry mode whose **neighbouring** SL/RR values
   also score well.
4. Run the best two or three settings on 2025–2026 without changing anything.
5. Repeat step 4 with `InpNoTrade1 = 15:15-16:00` to see whether avoiding US data helps.

### v7.11: close time fix
The first v7.10 test on XAUUSD.m (`code1.1.xlsx`) shows no ticks after about 22:30 server time, so the old
23:30 close never ran: 200 trades were held overnight and 39 over a weekend. New defaults are `InpTradeEnd=22:00`
and `InpCloseTime=22:15`. The EA also moves the close to 5 minutes before the symbol's session end if that is
earlier. `InpCloseMode = 1` deliberately holds trades overnight and closes only on Friday. In that test, overnight
trades did better than same-day ones, so compare 0 vs 1. The EA also warns when `InpBE_R ≥ InpRR`, because
breakeven can then never trigger.

## 9. v7.20: trailing stop and 4H straddle (both off by default)

### Trailing stop (section 3)
| Input | Default | Meaning |
|---|---|---|
| `InpTrailMode` | 0 Off | 1 = distance in R (`InpTrailDist_R` × SL), 2 = ATR (`InpTrailATR_Mult` × ATR(`InpTrailATR_Period`) on `InpTrailATR_TF`) |
| `InpTrailStart_R` | 1.0 | Start trailing once the trade is this many R in profit |
| `InpTrailDist_R` | 1.0 | R mode: with SL $10, the stop follows $10 behind price |
| `InpTrailMinDist_USD` | 2.00 | Never closer than this, so the old 10-point micro-trail can't happen |
| `InpTrailStep_USD` | 0.50 | Move the SL only in steps of at least $0.50 |

The SL only ever moves in the trade's favour. Breakeven and the trail work together; the tighter of the two wins.
**A trail can't act if it starts at or after the TP.** For a "let winners run" test, use `InpRR = 0` (no TP) or a
larger RR such as 3–4. The EA warns when the trail can never act.

Suggested tests (compare with Code3):
1. `InpTrailMode=1, InpTrailStart_R=1, InpTrailDist_R=1, InpRR=0`, with the daily close kept on.
2. The same with `InpCloseMode=1` (hold overnight) so trends can run.
3. `InpTrailMode=2, InpTrailATR_TF=H1, InpTrailATR_Mult=2, InpRR=0`.

### 4H straddle (section 1)
| Input | Default | Meaning |
|---|---|---|
| `InpUse4H` | false | Setup C: BUY STOP above / SELL STOP below the previous completed H4 candle |
| `InpH4From` / `InpH4To` | 08:00 / 20:00 | Only H4 candles opening in this window (08:00, 12:00, 16:00 server) |

- A new straddle is placed at every allowed H4 candle open. Its unfilled orders are deleted when the next H4 candle opens.
- It follows every other rule: entry mode, one trade at a time, max trades per day, no-trade windows, level-size
  filter, daily close. Magic number = `InpMagic + 3`.
- In the old v5.x EA, 4H generated 86% of all trades and lost on real ticks with micro-stops. Test it on its own
  first (`InpUsePDH=false, InpUseRange=false, InpUse4H=true`). The H4 range is often only a few dollars, so also try
  `InpMinLevelRange_USD` (for example 5) and `InpEntryMode=2` (close confirmation).
- With 4H on, `InpMaxTradesDay` (2) limits how many 4H trades can happen. Raise it to 3–4 if you want more.

## 10. v7.21: confirmation on/off per setup

`InpEntryMode` sets the entry for every setup: **0 STOP / 1 STOP-LIMIT = confirmation OFF**, **2 CLOSE /
3 RETEST = confirmation ON**. Each setup can override it:

| Input | Options |
|---|---|
| `InpEntryPDH` | 0 Same as Entry mode · 1 OFF: stop · 2 OFF: stop-limit · 3 ON: close · 4 ON: retest |
| `InpEntryRange` | same |
| `InpEntryH4` | same |

Example: confirmation only for 4H, none for PDH/RANGE → `InpEntryMode=0`, `InpEntryH4=3`.
At startup the journal prints each setup's entry and whether confirmation is ON or OFF.

## 11. Ready-made settings files (v7.21)

| File | Use | Passes |
|---|---|---|
| `v7_31_baseline.set` | Single test: Code3 settings + breakeven fixed at 1R + 0.5% risk | 1 |
| `v7_31_opt1_exits.set` | Optimise SL 6–14 × TP 1.5–3R × breakeven 0/1 | 40 |
| `v7_31_opt2_trail.set` | No TP; optimise trail mode R/ATR × start 0.5–1.5R × distance 0.5–1.5R | 18 |
| `v7_31_opt3_entry.set` | Optimise entry mode 0–3 × close mode daily/Friday | 8 |

Tester settings for the optimisations: XAUUSD.m, **Every tick based on real ticks**, 2023.04.01–2026.08.30,
**Forward = 1/3** (MT5 then tests the last third as unseen data automatically), Optimisation = **Slow complete
algorithm**, criterion = **Custom max**. Only trust settings that are good in both the Back and Forward results.
`InpScoreMaxDD` is 20 in these files so the current strategy (≈15–18% DD) still gets a score. Lower it to 10 once
the drawdown improves.

### v7.22: chart drawing
Level lines now start when the level is **known**: PDH/PDL at `InpPDHStart`, the range at `InpRangeEnd`, 4H at the
candle open. Each line has a label ("PDH 1987.50", "RANGE low 1966.72"). The range window is shown as a shaded box
from `InpRangeStart` to `InpRangeEnd`, drawn only after the range has ended. Before this, the range line was drawn
from `InpRangeStart`, which looked like the EA knew the levels in advance. Trading was never affected: orders are only
placed after the range ends, from finished 1-minute candles.

### v7.23: range times in India time (IST) or UTC
`InpRangeTZ` = 0 Server · 1 IST · 2 UTC sets the time zone of `InpRangeStart` / `InpRangeEnd`. The EA converts them
to server time every day using `InpServerUTCWinter` (2) and `InpServerDST` (0 = US summer-time dates, used by most
gold brokers). IST has no summer time, so the same IST window moves by one hour in server time:

| IST | Summer (2nd Sun Mar → 1st Sun Nov) | Winter |
|---|---|---|
| 12:30–14:30 | 10:00–12:00 server | 09:00–11:00 server |

Preset: `v7_31_range_IST_1230_1430.set`. Check your broker first: during summer, the Market Watch clock should
show **IST − 2:30**; in winter **IST − 3:30**. If it doesn't, change `InpServerUTCWinter` / `InpServerDST`.
Note: 12:30 IST = 07:00 UTC, which is the London open in summer but one hour before it in winter.

## 12. v7.30: multiple take profits and earlier trailing

**Why the ATR trail felt late:** with gold above $4,000, ATR(H1) is often $15–25, so `ATR × 2` put the stop $30–50
behind price. A +$40 trade could reverse all the way back. Use `InpTrailMaxDist_USD` (e.g. 8–10) to cap it, or one
of the new modes.

### New trailing modes (`InpTrailMode`)
| Mode | How the stop follows | Inputs |
|---|---|---|
| 3 LOCK | Keeps a fixed % of the open profit. At +$40 with 50% the stop is +$20 | `InpTrailLockPct` |
| 4 CANDLE | Behind the low (buy) / high (sell) of the last N closed candles | `InpTrailCandleTF` (M15), `InpTrailCandleBars` (2), `InpTrailCandleBuf_USD` (0.5) |

All modes start at `InpTrailStart_R` and stay between `InpTrailMinDist_USD` ($2) and `InpTrailMaxDist_USD` (0 = no limit).

### Multiple take profits (section 3b)
| Input | Example | Meaning |
|---|---|---|
| `InpTP1_R` / `InpTP1_Pct` | 1.0 / 50 | At +1R close 50% of the original lot |
| `InpTP1_MoveBE` | true | Then move the SL to entry (the rest can't lose) |
| `InpTP2_R` / `InpTP2_Pct` | 2.0 / 25 | At +2R close another 25% |
| `InpTP2_LockTP1` | true | Then move the SL to the TP1 price (+1R locked) |
| `InpRR` | 0 | Final 25%: no fixed TP, it rides the trail (or set e.g. 3 for a final TP) |

TP1/TP2 must be below `InpRR` unless `InpRR = 0`. **Small lots can't be split:** with 0.5% risk on $5,000 and a $10
SL the lot is 0.02, so 50% = 0.01 works, but 25% = 0.005 rounds to 0 and that partial is skipped (the journal says
so). Use a bigger balance in the tester, or `InpTP1_Pct = 50` with no TP2. The Custom max statistics count a trade's
partial closes as one trade.

Presets: `v7_31_multiTP_early_trail.set` (TP1 50% @1R → BE, TP2 25% @2R → lock TP1, rest LOCK 50% trail, max $10)
and `v7_31_opt4_tp_trail.set` (TP1 0.5–1.5R × trail LOCK/CANDLE × lock 40–70%, 24 passes).

## 13. v7.31: don't re-trade a level that was already broken

Before, the EA only checked whether price was beyond a level **at the moment it placed the order**. If price broke
PDL during the blackout before `InpPDHStart`, inside a no-trade window, or while another trade was open, and then
came back, the EA still placed the SELL STOP. That repeat trigger is a failed breakout and often ends in the SL.

`InpSkipBroken = true` (default) checks the M1 history first. A side is skipped when price has already reached its
entry level since:

| Setup | Checked since |
|---|---|
| PDH | start of the server day (covers the 01:00–01:15 blackout) |
| RANGE | range end |
| 4H | the H4 candle open |

The journal shows `SELL skipped: price already traded down to … since … - broken level, not re-entered`.
`InpBrokenTol_USD` also counts a near miss (e.g. 0.30 = within 30 cents) as broken. It applies to STOP / STOP-LIMIT
entries. CLOSE / RETEST already need a fresh candle close beyond the level. Set `InpSkipBroken = false` to reproduce
earlier test results exactly.
