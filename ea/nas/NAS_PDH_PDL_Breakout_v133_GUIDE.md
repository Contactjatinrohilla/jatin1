# NAS_PDH_PDL_Breakout v1.33 – Beginner's Guide

Files:
- `NAS_PDH_PDL_Breakout_v133.mq5` – the EA (Expert Advisor = automatic trading program)
- `TimingCheck.mq5` – a read-only script that checks your broker's clock (it never trades)

Words used below:
- **Point** – one index point of Nasdaq (50 points = a 50-point move).
- **Server time** – your broker's clock (Market Watch window).
- **New York time** – the clock in New York, where the US stock market opens at 09:30.
- **Stop loss (SL)** – price where a losing trade is closed. **Take profit (TP)** – price where a winning trade is closed.

---

## 1. Every input on one page

| # | Input | Start value | What it does | Raise it → | Lower it → |
|---|---|---|---|---|---|
| **1. Setups** |||||
| | InpUsePDH | true | Trade yesterday's high / low (PDH / PDL) | – | – |
| | InpUseH4 | true | Trade the high / low of the last 4-hour candle | – | – |
| **2. Trading hours and killzones** |||||
| | InpWindow | 00:00-23:55 | Hours the EA may trade (server time). Everything is closed at the end time | Longer day, more trades | Shorter day, fewer trades |
| | InpBrokerGMTWinter | 2 | Your broker's clock = GMT + this, in winter. Run TimingCheck to find it | – (must be correct, not bigger/smaller) | – |
| | InpBrokerDST | true | Broker moves its clock 1 hour forward in summer | – | – |
| | InpKZAsian | false | Only trade 20:00-24:00 New York time (when on) | – | – |
| | InpKZLondon | false | Only trade 02:00-05:00 New York time (when on) | – | – |
| | InpKZNYAM | false | Only trade 08:30-11:00 New York time (when on). All 3 off = no killzones | – | – |
| **3. Entry confirmation** |||||
| | InpUseConfirm | true | true = wait for a candle to CLOSE past the level; false = stop order right on the level | – | – |
| | InpConfirmMinutes | 15 | Length of that candle, minutes (1-240) | Stronger proof, fewer and later trades | Faster, more trades, more fake breakouts |
| | InpEnterAtClose | false | After confirmation: true = enter at once at market; false = limit order back at the level | – | – |
| **4. Stop loss and take profit (points)** |||||
| | InpSL | 50 | Stop loss distance | Fewer stop-outs, smaller lot (same % risk) | More stop-outs, bigger lot |
| | InpUseTP | false | Use the fixed take profit below instead of the ratio | – | – |
| | InpFixedTP | 100 | Fixed take profit distance | Bigger wins, reached less often | Smaller wins, reached more often |
| | InpRR | 2.0 | Take profit = SL × this (0 = no take profit) | Bigger wins, fewer winners | Smaller wins, more winners |
| | InpUseBE | false | Move SL to entry + 1 point after some profit | – | – |
| | InpBEAt | 5 | Profit (points) that starts breakeven | Trades get more room | More trades end at breakeven |
| | InpUseTrail | false | Use a trailing stop | – | – |
| | InpTrailAt | 5 | Profit (points) that starts trailing | Trails later, more room | Trails sooner |
| | InpTrailDist | 5 | SL stays this far behind price | Fewer early exits, gives back more | Locks profit tighter, exits on small pullbacks |
| **5. Risk and prop firm limits** |||||
| | InpRiskPct | 0.5 | % of balance lost if a trade hits its stop loss | Bigger wins and losses | Smaller wins and losses |
| | InpMaxTrades | 0 | Max trades per day, both setups (0 = no limit) | – | Fewer trades per day |
| | InpUsePropRisk | true | Use the daily / weekly loss limits | – | – |
| | InpDailyLossPct | 2.5 | Stop for the day at this loss % | More room, bigger bad days | Stops sooner. Keep it BELOW your firm's real limit |
| | InpWeeklyLossPct | 8.5 | Stop for the week at this loss % | More room | Stops sooner |
| | InpPropResetHour | 0 | Server hour when your prop firm's day starts (0-23) | – (must match your firm) | – |
| **6. Chart** |||||
| | InpShowLabels | true | Labels, TP lines, killzone boxes and arrows (false = only lines + chart text) | – | – |
| **7. Other** |||||
| | InpMagic | 930001 | Order ID (PDH = this, 4H = this + 1). Change only if two copies run on the same symbol | – | – |

Old set files still load: names and default values of all v132 inputs are unchanged; new inputs get their defaults.

---

## 2. Step-by-step instructions

### a) Compiling in MetaEditor (F7)
1. MT5 → **File → Open Data Folder**.
2. Copy `NAS_PDH_PDL_Breakout_v133.mq5` into **MQL5 → Experts**, and `TimingCheck.mq5` into **MQL5 → Scripts**.
3. In MT5 press **F4** (opens MetaEditor). In its **Navigator** (left) open each file (double-click).
4. Press **F7** for each file. At the bottom, the **Errors** tab must say **0 errors**.
5. If you see errors: do not change anything yourself – copy the whole Errors list (with line numbers) and send it to me.
6. Back in MT5: Navigator (Ctrl+N) → right-click **Expert Advisors → Refresh** (and **Scripts → Refresh**).
7. If the Compile button is grey and Pause / Stop buttons are lit, a debug session is running – click the red **Stop** button first.

### b) Downloading full M1 history
1. MT5 → **Tools → Options → Charts** → set **Max bars in chart** to **Unlimited** → OK → **restart MT5**.
2. **View → Symbols** (Ctrl+U) → **Bars** tab.
3. Choose your Nasdaq symbol (e.g. NDX100.m), timeframe **M1**, dates **2020.01.01** to **today** → click **Request**.
4. Wait until the bars appear (it can take several minutes). Close the window.

### c) Running TimingCheck and reading the summary
1. Open a **Nasdaq chart** (any timeframe).
2. Navigator → **Scripts** → drag **TimingCheck** onto the chart.
3. In the window: InpBrokerGMTWinter and InpBrokerDST = **the same values as in your EA**; leave the dates → **OK**.
4. Open **View → Toolbox** (Ctrl+T) → **Experts** tab. You will see one line per week, then **SUMMARY**:
   - "**Your settings are correct**" → nothing to do.
   - "**Change your EA to InpBrokerGMTWinter = X and InpBrokerDST = Y**" → set those in the EA.
   - "All mismatches are in March, October or November…" → your broker follows European clock dates; the killzones are 1 hour off for 2-3 weeks each spring and autumn only.
   - "Usual daily trading break …" and one line per killzone; "**WARNING: falls inside the broker's daily break**" means that killzone cannot trade properly.
   - "No M1 data for …" → that month is missing; do step b again.
5. The same results are saved in **File → Open Data Folder → MQL5 → Files → `TimingCheck_<symbol>.csv`** (opens in Excel).

### d) Identical-results test (v132 vs v133)
1. Strategy Tester (**Ctrl+R**) → **Settings**: Expert **v132**, your symbol, the same dates (e.g. 6 months), **Every tick based on real ticks**, Optimization **Disabled**, Visual mode **off**.
2. **Inputs** → right-click → **Load** your usual set file → **Start**.
3. **Backtest** tab: write down **Total Net Profit, Total Trades, Profit Factor, Balance Drawdown Maximal**, and in the **Deals** list the first 3 and last 3 deals.
4. Change only **Expert** to **v133**, load the same set file, check **killzones all false**, **prop reset hour 0** → **Start**.
5. All numbers and those deals must be **exactly the same**. Also try **InpShowLabels = false** – still the same. (Only the Journal text differs – shorter messages.)

### e) Checking the labels and killzone boxes in visual mode
1. Settings: Expert **v133**, about 1 week, tick **Visual mode**.
2. Inputs: **InpShowLabels = true**, **InpUseConfirm = true**, **InpKZNYAM = true** (to see a box) → **Start**, slow it with the speed slider.
3. Check: right-edge labels "PDH…", "PDL…", "4H High…", "4H Low…"; dotted SL / TP lines with "SL BUY #…" / "TP BUY #…" when a trade opens; shaded "NY AM KZ" box; arrow + "Confirmed BUY/SELL"; chart text top-left, one item per line.
4. To save these settings for every visual test: right-click the chart → **Templates → Save Template** → name **tester**.

### f) Testing an improvement ON vs OFF
No Part 4 improvements were chosen, so v133 has none to test. For any future change, use the same method:
1. Run the same dates and settings with the feature **OFF**, then **ON** (and 2-3 values if it has a number).
2. Compare **Net Profit, Profit Factor, Balance Drawdown Maximal, Total Trades, Maximal consecutive losses**.
3. Use **Forward: 1/3** in Settings and trust only settings that also do well in the **Forward** results.
4. Prefer settings where nearby values are also good; then run **4+ weeks on a demo account**.

No setting can guarantee profit. Backtests and demo forward tests only show whether a change helped on past and recent data.
