//+------------------------------------------------------------------+
//|                     SMC_Fib_Strategy.mq5   v1.00                  |
//|                                                                  |
//|  Market structure + imbalance + Fibonacci retracement            |
//|  (the "day trading plan": 4H bias, M15 entries; set InpEntryTF = |
//|  H4 and InpFibEntry = 0.71 for the "swing trading plan").        |
//|                                                                  |
//|  1. SWING POINTS  a high/low with InpSwingLen lower highs /       |
//|     higher lows on BOTH sides (external structure only).         |
//|  2. BREAK OF STRUCTURE (BOS)  a candle BODY closes beyond the     |
//|     last swing high (bullish) or swing low (bearish). Wicks do    |
//|     not count.                                                   |
//|  3. TRADING RANGE  bullish: lowest low between the broken swing   |
//|     high and the BOS candle (100%) up to the highest high after   |
//|     it (0%). The range is locked once InpLockBars candles have    |
//|     not made a new high (price started to retrace).               |
//|  4. IMBALANCE (FVG)  3-candle gap inside the impulse leg:         |
//|     bullish = candle 1 high < candle 3 low (bearish mirrored).    |
//|  5. ENTRY  limit order at the InpFibEntry retracement (0.67 =     |
//|     1:2, 0.71 = 1:2.45), SL at 100%, TP at 0% (InpTPFib).        |
//|  6. VALID until the SL or TP level is touched: if price takes out |
//|     the TP level (range high/low) before the entry fills, the     |
//|     order is deleted. Then SET AND FORGET - no breakeven, no      |
//|     trailing, no partials.                                       |
//|  Optional: liquidity sweep before the leg, imbalance close to     |
//|  the entry, 4H bias (trend and/or premium/discount).              |
//|                                                                  |
//|  All prices/distances are in PRICE units (gold: 1.0 = $1).       |
//+------------------------------------------------------------------+
#property copyright "SMC Fib Strategy v1.00"
#property version   "1.00"

#include <Trade\Trade.mqh>

enum ENUM_BIAS
  {
   BIAS_NONE        = 0, // No 4H filter
   BIAS_TREND       = 1, // Only with the 4H structure trend
   BIAS_PD          = 2, // Only buy in 4H discount / sell in 4H premium
   BIAS_TREND_OR_PD = 3  // With the 4H trend, or counter-trend from 4H discount/premium (video plan)
  };

enum ENUM_DIRECTION
  {
   DIR_BOTH = 0, // Buy and sell
   DIR_BUY  = 1, // Buy only
   DIR_SELL = 2  // Sell only
  };

input group "=== 1. Timeframes and structure ==="
input ENUM_TIMEFRAMES InpEntryTF      = PERIOD_M15; // Entry timeframe (structure, range, FVG)
input ENUM_TIMEFRAMES InpBiasTF       = PERIOD_H4;  // Bias timeframe
input int             InpSwingLen     = 5;          // Swing point: candles on each side (entry TF)
input int             InpBiasSwingLen = 3;          // Swing point: candles on each side (bias TF)
input int             InpLockBars     = 2;          // Lock the range after this many candles without a new extreme
input int             InpLookback     = 500;        // Candles of history used

input group "=== 2. Entry ==="
input double          InpFibEntry     = 0.67;       // Entry retracement (0.67 = 1:2, 0.71 = 1:2.45, 0.79 = 1:3.8)
input double          InpTPFib        = 0.0;        // TP level (0 = range extreme; -0.27 = extension)
input double          InpSLBuffer     = 0.0;        // Extra SL distance beyond 100% (price, e.g. 0.30 = spread)
input bool            InpRequireFVG   = true;       // Impulse leg must contain an imbalance
input double          InpMinFVG       = 0.0;        // Minimum imbalance size (price)
input bool            InpFVGNearEntry = false;      // Imbalance must be at/near the entry level
input double          InpFVGTol       = 0.10;       // ...near = within this fraction of the range
input bool            InpRequireSweep = false;      // Leg must start with a liquidity sweep of an older swing
input ENUM_BIAS       InpBias         = BIAS_TREND_OR_PD; // 4H bias filter
input ENUM_DIRECTION  InpDirection    = DIR_BOTH;   // Direction
input bool            InpReplacePending = true;     // A newer setup replaces an unfilled order of the same side
input bool            InpCancelOnOppBOS = true;     // Delete unfilled orders when structure breaks the other way
input int             InpExpiryBars   = 0;          // Delete unfilled orders after this many entry-TF candles (0 = never)
input bool            InpOnePosition  = true;       // No new orders while a position is open

input group "=== 3. Filters ==="
input double          InpMinRange     = 0.0;        // Skip ranges smaller than this (price, 0 = off)
input double          InpMaxRange     = 0.0;        // Skip ranges larger than this (price, 0 = off)
input double          InpMinSLSpreads = 10.0;       // Skip if SL distance < this x current spread (0 = off)
input double          InpMaxSpread    = 0.0;        // Do not place orders while spread > this (price, 0 = off)
input string          InpSession      = "";         // Place orders only in this server-time window, HH:MM-HH:MM ("" = always)
input bool            InpSessionCancel = false;     // Delete unfilled orders outside the window

input group "=== 4. Risk ==="
input double          InpRiskPct      = 0.5;        // Risk % of balance per trade
input int             InpMaxTradesDay = 3;          // Max filled trades per day
input double          InpMaxDailyLossPct = 3.0;     // Close all + stop for the day at this loss % (0 = off)
input ulong           InpMagic        = 810000;     // Magic number

input group "=== 5. Optimisation (Custom max) ==="
input int             InpMinTrades    = 50;         // Score 0 below this many trades
input double          InpScoreMaxDD   = 20.0;       // Score 0 above this equity drawdown % (0 = off)

input group "=== 6. Diagnostics ==="
input bool            InpTradeLog     = true;       // Write trades to Common\Files\SMC_trades_<symbol>.csv
input bool            InpDraw         = true;       // Draw BOS, ranges, levels and imbalances

//+------------------------------------------------------------------+
struct SSwing { double price; datetime time; };

struct SLeg
  {
   bool     active;
   bool     up;
   double   lo, hi;
   datetime originTime;     // candle of the 100% point
   datetime extremeTime;    // candle of the 0% point
   datetime bosTime;
   datetime swingTime;      // broken swing point
   double   bosLevel;
  };

struct SSetup
  {
   ulong    order;
   ulong    posId;
   bool     up;
   bool     filled;
   double   lo, hi, entry, sl, tp;
   datetime placed;
   datetime fillTime;
   double   fill;
   double   mfe, mae;
   double   fvgDist;        // imbalance distance from entry as fraction of range (0 = at entry, -1 = none)
   bool     sweep;
   string   bias;           // with / counter / none
   double   pdPct;          // entry position in the 4H range (0 = low, 1 = high)
  };

CTrade   g_trade;
SLeg     g_leg[2];          // 0 = bullish candidate, 1 = bearish candidate
SSwing   g_lastSH, g_lastSL;
bool     g_shBroken = true, g_slBroken = true;
SSwing   g_ph[], g_pl[];    // swing history
SSetup   g_set[];
datetime g_lastBar = 0, g_lastBiasBar = 0;
int      g_biasTrend = 0;   // +1 up, -1 down, 0 unknown
double   g_biasHi = 0, g_biasLo = 0;
int      g_sesS = -1, g_sesE = -1;
datetime g_day = 0;
int      g_tradesToday = 0;
double   g_dayStartBal = 0;
bool     g_halted = false;
int      g_log = INVALID_HANDLE;
int      g_cntSetups = 0, g_cntPlaced = 0, g_cntSkipped = 0;

//+------------------------------------------------------------------+
//|  Helpers                                                         |
//+------------------------------------------------------------------+
int ParseHHMM(string text)
  {
   string s = text;
   StringTrimLeft(s); StringTrimRight(s);
   string p[];
   if(StringSplit(s, ':', p) != 2) return -1;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * 60 + m;
  }

bool InSession()
  {
   if(g_sesS < 0) return true;
   int m = (int)((TimeCurrent() % 86400) / 60);
   return (g_sesS < g_sesE) ? (m >= g_sesS && m < g_sesE) : (m >= g_sesS || m < g_sesE);
  }

double Norm(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

double Spread() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID); }

void PushSwing(SSwing &arr[], double price, datetime t)
  {
   int n = ArraySize(arr);
   if(n >= 50) { for(int i = 1; i < n; i++) arr[i - 1] = arr[i]; n--; ArrayResize(arr, n); }
   ArrayResize(arr, n + 1);
   arr[n].price = price;
   arr[n].time  = t;
  }

// Chronological arrays (index 0 = oldest). Swing high at p: higher than the L candles before
// (strict) and not exceeded by the L candles after.
bool IsSwingHigh(const MqlRates &r[], int p, int L)
  {
   for(int k = 1; k <= L; k++)
      if(r[p - k].high >= r[p].high || r[p + k].high > r[p].high) return false;
   return true;
  }

bool IsSwingLow(const MqlRates &r[], int p, int L)
  {
   for(int k = 1; k <= L; k++)
      if(r[p - k].low <= r[p].low || r[p + k].low < r[p].low) return false;
   return true;
  }

int IndexOf(const MqlRates &r[], int last, datetime t)
  {
   for(int i = last; i >= 0; i--) if(r[i].time <= t) return i;
   return 0;
  }

int OurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic) n++;
   return n;
  }

int FindSetupByOrder(ulong order) { for(int i = 0; i < ArraySize(g_set); i++) if(g_set[i].order == order) return i; return -1; }
int FindSetupByPos(ulong pos)     { for(int i = 0; i < ArraySize(g_set); i++) if(g_set[i].filled && g_set[i].posId == pos) return i; return -1; }

void RemoveSetup(int k)
  {
   int n = ArraySize(g_set);
   for(int i = k; i < n - 1; i++) g_set[i] = g_set[i + 1];
   ArrayResize(g_set, n - 1);
  }

// Deletes our unfilled order(s): side 0 = buys, 1 = sells, -1 = all.
void DeletePendings(int side, string why)
  {
   for(int i = ArraySize(g_set) - 1; i >= 0; i--)
     {
      if(g_set[i].filled) continue;
      if(side >= 0 && (side == 0) != g_set[i].up) continue;
      if(OrderSelect(g_set[i].order))
        {
         if(g_trade.OrderDelete(g_set[i].order)) PrintFormat("Order #%I64u deleted (%s)", g_set[i].order, why);
         else { PrintFormat("Order #%I64u delete FAILED (%s): %s", g_set[i].order, why, g_trade.ResultRetcodeDescription()); continue; }
        }
      RemoveSetup(i);
     }
  }

void ClosePositions(string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(g_trade.PositionClose(t)) PrintFormat("Position #%I64u closed (%s)", t, why);
     }
  }

//+------------------------------------------------------------------+
//|  4H bias: structure trend (direction of the last BOS) and the    |
//|  current dealing range (last swing high / swing low).            |
//+------------------------------------------------------------------+
void UpdateBias()
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, InpBiasTF, 1, 400, r);
   int L = InpBiasSwingLen;
   if(n < 2 * L + 5) return;
   double sh = 0, sl = 0;
   int    ish = -1, isl = -1;
   bool   shB = true, slB = true;
   int    trend = 0;
   for(int t = 2 * L; t < n; t++)
     {
      int p = t - L;
      if(IsSwingHigh(r, p, L)) { sh = r[p].high; ish = p; shB = false; }
      if(IsSwingLow(r, p, L))  { sl = r[p].low;  isl = p; slB = false; }
      if(!shB && r[t].close > sh) { shB = true; trend = 1; }
      if(!slB && r[t].close < sl) { slB = true; trend = -1; }
     }
   g_biasTrend = trend;
   if(ish < 0 || isl < 0) { g_biasHi = g_biasLo = 0; return; }
   // dealing range: from the last swing high / swing low, stretched by any price beyond them since
   g_biasHi = sh;
   g_biasLo = sl;
   for(int i = MathMin(ish, isl); i < n; i++) { g_biasHi = MathMax(g_biasHi, r[i].high); g_biasLo = MathMin(g_biasLo, r[i].low); }
  }

//+------------------------------------------------------------------+
//|  Structure: one closed entry-TF candle (r[last]).                 |
//+------------------------------------------------------------------+
void ProcessBar(const MqlRates &r[], int last, bool live)
  {
   int L = InpSwingLen;
   if(last < 2 * L + 2) return;

   // 1) swing point confirmed L candles ago
   int p = last - L;
   if(IsSwingHigh(r, p, L)) { g_lastSH.price = r[p].high; g_lastSH.time = r[p].time; g_shBroken = false; PushSwing(g_ph, r[p].high, r[p].time); }
   if(IsSwingLow(r, p, L))  { g_lastSL.price = r[p].low;  g_lastSL.time = r[p].time; g_slBroken = false; PushSwing(g_pl, r[p].low,  r[p].time); }

   // 2) leg updates (new extreme / invalidated by breaking the 100% point)
   for(int d = 0; d < 2; d++)
     {
      if(!g_leg[d].active || r[last].time <= g_leg[d].bosTime) continue;
      if(g_leg[d].up)
        {
         if(r[last].low < g_leg[d].lo) { g_leg[d].active = false; continue; }
         if(r[last].high > g_leg[d].hi) { g_leg[d].hi = r[last].high; g_leg[d].extremeTime = r[last].time; }
        }
      else
        {
         if(r[last].high > g_leg[d].hi) { g_leg[d].active = false; continue; }
         if(r[last].low < g_leg[d].lo) { g_leg[d].lo = r[last].low; g_leg[d].extremeTime = r[last].time; }
        }
     }

   // 3) break of structure on a candle CLOSE
   if(!g_shBroken && g_lastSH.time > 0 && r[last].close > g_lastSH.price)
     {
      g_shBroken = true;
      int is = IndexOf(r, last, g_lastSH.time);
      int io = last;
      for(int i = last; i >= is; i--) if(r[i].low < r[io].low) io = i;
      int ie = io;
      for(int i = io; i <= last; i++) if(r[i].high >= r[ie].high) ie = i;
      g_leg[0].active = true; g_leg[0].up = true;
      g_leg[0].lo = r[io].low; g_leg[0].hi = r[ie].high;
      g_leg[0].originTime = r[io].time; g_leg[0].extremeTime = r[ie].time;
      g_leg[0].bosTime = r[last].time; g_leg[0].swingTime = g_lastSH.time; g_leg[0].bosLevel = g_lastSH.price;
      g_leg[1].active = false;
      if(live)
        {
         if(InpCancelOnOppBOS) DeletePendings(1, "bullish break of structure");
         DrawBOS(true, g_lastSH.time, r[last].time, g_lastSH.price);
        }
     }
   if(!g_slBroken && g_lastSL.time > 0 && r[last].close < g_lastSL.price)
     {
      g_slBroken = true;
      int is = IndexOf(r, last, g_lastSL.time);
      int io = last;
      for(int i = last; i >= is; i--) if(r[i].high > r[io].high) io = i;
      int ie = io;
      for(int i = io; i <= last; i++) if(r[i].low <= r[ie].low) ie = i;
      g_leg[1].active = true; g_leg[1].up = false;
      g_leg[1].hi = r[io].high; g_leg[1].lo = r[ie].low;
      g_leg[1].originTime = r[io].time; g_leg[1].extremeTime = r[ie].time;
      g_leg[1].bosTime = r[last].time; g_leg[1].swingTime = g_lastSL.time; g_leg[1].bosLevel = g_lastSL.price;
      g_leg[0].active = false;
      if(live)
        {
         if(InpCancelOnOppBOS) DeletePendings(0, "bearish break of structure");
         DrawBOS(false, g_lastSL.time, r[last].time, g_lastSL.price);
        }
     }

   // 4) lock the range once price has stopped making new extremes
   for(int d = 0; d < 2; d++)
     {
      if(!g_leg[d].active) continue;
      int ie = IndexOf(r, last, g_leg[d].extremeTime);
      if(last - ie < InpLockBars) continue;
      g_leg[d].active = false;
      if(live) OnRangeLocked(g_leg[d], r, last);
     }
  }

//+------------------------------------------------------------------+
//|  A locked range: check the plan, place the limit order.          |
//+------------------------------------------------------------------+
void OnRangeLocked(SLeg &leg, const MqlRates &r[], int last)
  {
   g_cntSetups++;
   bool   up    = leg.up;
   double range = leg.hi - leg.lo;
   double entry = up ? leg.hi - InpFibEntry * range : leg.lo + InpFibEntry * range;
   double sl    = up ? leg.lo - InpSLBuffer : leg.hi + InpSLBuffer;
   double tp    = up ? leg.hi - InpTPFib * range : leg.lo + InpTPFib * range;
   entry = Norm(entry); sl = Norm(sl); tp = Norm(tp);
   string side = up ? "BUY" : "SELL";

   // imbalance inside the impulse leg (origin .. extreme)
   int io = IndexOf(r, last, leg.originTime), ie = IndexOf(r, last, leg.extremeTime);
   double best = -1, zLo = 0, zHi = 0;
   datetime zT = 0;
   for(int c = io + 2; c <= ie; c++)
     {
      int a = c - 2;
      double lo, hi;
      if(up) { lo = r[a].high; hi = r[c].low; }
      else   { lo = r[c].high; hi = r[a].low; }
      if(hi - lo <= MathMax(InpMinFVG, _Point)) continue;
      double dist = (entry >= lo && entry <= hi) ? 0 : MathMin(MathAbs(entry - lo), MathAbs(entry - hi));
      if(best < 0 || dist < best) { best = dist; zLo = lo; zHi = hi; zT = r[a + 1].time; }
     }
   double fvgFrac = (best < 0) ? -1 : best / range;

   // liquidity sweep: the leg's 100% point took out the previous swing on that side
   bool sweep = false;
   if(up) { for(int i = ArraySize(g_pl) - 1; i >= 0; i--) if(g_pl[i].time < leg.originTime) { sweep = leg.lo < g_pl[i].price; break; } }
   else   { for(int i = ArraySize(g_ph) - 1; i >= 0; i--) if(g_ph[i].time < leg.originTime) { sweep = leg.hi > g_ph[i].price; break; } }

   // 4H bias
   double pd = (g_biasHi > g_biasLo) ? (entry - g_biasLo) / (g_biasHi - g_biasLo) : 0.5;
   bool withTrend = up ? g_biasTrend == 1 : g_biasTrend == -1;
   bool goodPD = up ? pd < 0.5 : pd > 0.5;
   string bias = (g_biasTrend == 0) ? "none" : withTrend ? "with" : "counter";

   string why = "";
   if(InpDirection == DIR_BUY && !up)                       why = "direction";
   else if(InpDirection == DIR_SELL && up)                  why = "direction";
   else if(InpRequireFVG && best < 0)                       why = "no imbalance in the leg";
   else if(InpFVGNearEntry && (best < 0 || fvgFrac > InpFVGTol)) why = StringFormat("imbalance not near entry (%.2f of range)", fvgFrac);
   else if(InpRequireSweep && !sweep)                       why = "no liquidity sweep";
   else if(InpBias == BIAS_TREND && !withTrend)                  why = "against 4H trend";
   else if(InpBias == BIAS_PD && !goodPD)                   why = StringFormat("not in 4H %s (%.0f%%)", up ? "discount" : "premium", pd * 100);
   else if(InpBias == BIAS_TREND_OR_PD && !withTrend && !goodPD) why = StringFormat("counter-trend outside 4H %s (%.0f%%)", up ? "discount" : "premium", pd * 100);
   else if(InpMinRange > 0 && range < InpMinRange)          why = StringFormat("range %g < min", range);
   else if(InpMaxRange > 0 && range > InpMaxRange)          why = StringFormat("range %g > max", range);
   else if(InpMinSLSpreads > 0 && MathAbs(entry - sl) < InpMinSLSpreads * Spread())
                                                            why = StringFormat("SL %g < %g x spread %g", MathAbs(entry - sl), InpMinSLSpreads, Spread());
   else if(InpMaxSpread > 0 && Spread() > InpMaxSpread)     why = "spread too wide";
   else if(!InSession())                                    why = "outside session";
   else if(g_halted)                                        why = "daily loss stop";
   else if(g_tradesToday >= InpMaxTradesDay)                why = "max trades today";
   else if(InpOnePosition && OurPositions() > 0)            why = "a position is open";

   PrintFormat("[%s] range %s-%s  %.*f - %.*f (%g) | entry %.*f SL %.*f TP %.*f | FVG %s | sweep %s | 4H %s, %.0f%% of range%s",
               side, TimeToString(leg.originTime, TIME_DATE | TIME_MINUTES), TimeToString(leg.extremeTime, TIME_MINUTES),
               _Digits, leg.lo, _Digits, leg.hi, range, _Digits, entry, _Digits, sl, _Digits, tp,
               best < 0 ? "none" : StringFormat("%.2f of range from entry", fvgFrac), sweep ? "yes" : "no", bias, pd * 100,
               why == "" ? "" : " -> SKIPPED: " + why);
   if(why != "") { g_cntSkipped++; return; }

   if(InpReplacePending) DeletePendings(up ? 0 : 1, "replaced by a newer setup");

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(up ? (ask - entry <= minDist) : (entry - bid <= minDist))
     {
      PrintFormat("[%s] SKIPPED: price already retraced past the entry", side);
      g_cntSkipped++;
      return;
     }

   double lot = CalcLot(up, entry, sl);
   if(lot <= 0) { PrintFormat("[%s] SKIPPED: lot calculation failed / min lot too risky", side); g_cntSkipped++; return; }
   bool ok = up ? g_trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "SMC_B")
                : g_trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "SMC_S");
   if(!ok || g_trade.ResultOrder() == 0)
     {
      PrintFormat("[%s] limit order REJECTED: %u %s", side, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return;
     }
   g_cntPlaced++;
   int n = ArraySize(g_set);
   ArrayResize(g_set, n + 1);
   g_set[n].order = g_trade.ResultOrder(); g_set[n].posId = 0; g_set[n].up = up; g_set[n].filled = false;
   g_set[n].lo = leg.lo; g_set[n].hi = leg.hi; g_set[n].entry = entry; g_set[n].sl = sl; g_set[n].tp = tp;
   g_set[n].placed = TimeCurrent(); g_set[n].fillTime = 0; g_set[n].fill = 0; g_set[n].mfe = 0; g_set[n].mae = 0;
   g_set[n].fvgDist = fvgFrac; g_set[n].sweep = sweep; g_set[n].bias = bias; g_set[n].pdPct = pd;
   PrintFormat("[%s] LIMIT %.2f lot @ %.*f  SL %.*f  TP %.*f  (RR 1:%.2f)", side, lot, _Digits, entry, _Digits, sl, _Digits, tp,
               MathAbs(tp - entry) / MathAbs(entry - sl));
   DrawSetup(g_set[n], leg.originTime, r[last].time, zT, zLo, zHi);
  }

double CalcLot(bool isBuy, double entry, double sl)
  {
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double lossPerLot = 0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, lossPerLot)) return 0;
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0) return 0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   double lot = MathFloor(risk / lossPerLot / step + 1e-9) * step;
   if(lot < vmin)
     {
      if(vmin * lossPerLot > risk * 1.10) return 0;
      lot = vmin;
     }
   lot = MathMin(lot, vmax);
   return NormalizeDouble(lot, (int)MathMax(0, MathRound(-MathLog10(step))));
  }

//+------------------------------------------------------------------+
//|  Unfilled orders: valid until the TP level is taken out           |
//+------------------------------------------------------------------+
void ManagePendings()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i = ArraySize(g_set) - 1; i >= 0; i--)
     {
      if(g_set[i].filled) continue;
      if(!OrderSelect(g_set[i].order))
        {
         if(!PositionSelectByTicket(g_set[i].order)) RemoveSetup(i);   // cancelled/expired outside the EA
         continue;
        }
      string why = "";
      if(g_set[i].up && bid > g_set[i].hi)        why = "range high taken out before entry - missed";
      else if(!g_set[i].up && bid < g_set[i].lo)  why = "range low taken out before entry - missed";
      else if(InpExpiryBars > 0 && TimeCurrent() - g_set[i].placed >= (long)InpExpiryBars * PeriodSeconds(InpEntryTF)) why = "expired";
      else if(InpSessionCancel && !InSession())   why = "outside session";
      if(why == "") continue;
      if(g_trade.OrderDelete(g_set[i].order)) { PrintFormat("Order #%I64u deleted (%s)", g_set[i].order, why); RemoveSetup(i); }
     }
  }

void UpdateExcursions()
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < ArraySize(g_set); i++)
     {
      if(!g_set[i].filled) continue;
      double fav = g_set[i].up ? bid - g_set[i].fill : g_set[i].fill - ask;
      g_set[i].mfe = MathMax(g_set[i].mfe, fav);
      g_set[i].mae = MathMax(g_set[i].mae, -fav);
     }
  }

//+------------------------------------------------------------------+
//|  Day state                                                       |
//+------------------------------------------------------------------+
void RecountToday()
  {
   g_tradesToday = 0;
   double closed = 0;
   if(!HistorySelect(g_day, TimeCurrent() + 60)) return;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      closed += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) + HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN && HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol &&
         (ulong)HistoryDealGetInteger(d, DEAL_MAGIC) == InpMagic) g_tradesToday++;
     }
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - closed;
  }

//+------------------------------------------------------------------+
//|  Drawing                                                         |
//+------------------------------------------------------------------+
bool CanDraw() { return InpDraw && !MQLInfoInteger(MQL_OPTIMIZATION); }

void Line(string name, datetime t1, double p1, datetime t2, double p2, color c, int style, string text)
  {
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TREND, 0, t1, p1, t2, p2);
   ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, text);
  }

void DrawBOS(bool up, datetime t1, datetime t2, double price)
  {
   if(!CanDraw()) return;
   Line("SMC_BOS_" + TimeToString(t2), t1, price, t2, price, up ? clrLime : clrOrangeRed, STYLE_SOLID, "BOS");
  }

void DrawSetup(const SSetup &s, datetime t1, datetime t2, datetime fvgT, double fvgLo, double fvgHi)
  {
   if(!CanDraw()) return;
   string id = TimeToString(t2);
   datetime t3 = t2 + 40 * PeriodSeconds(InpEntryTF);
   Line("SMC_E_" + id, t1, s.entry, t3, s.entry, clrDodgerBlue, STYLE_DASH, StringFormat("%.0f%% entry", InpFibEntry * 100));
   Line("SMC_S_" + id, t1, s.sl, t3, s.sl, clrRed, STYLE_DOT, "SL 100%");
   Line("SMC_T_" + id, t1, s.tp, t3, s.tp, clrLimeGreen, STYLE_DOT, "TP");
   if(fvgT > 0 && ObjectFind(0, "SMC_F_" + id) < 0)
     {
      ObjectCreate(0, "SMC_F_" + id, OBJ_RECTANGLE, 0, fvgT, fvgHi, t3, fvgLo);
      ObjectSetInteger(0, "SMC_F_" + id, OBJPROP_COLOR, C'70,70,70');
      ObjectSetInteger(0, "SMC_F_" + id, OBJPROP_FILL, true);
      ObjectSetInteger(0, "SMC_F_" + id, OBJPROP_BACK, true);
      ObjectSetInteger(0, "SMC_F_" + id, OBJPROP_SELECTABLE, false);
     }
  }

//+------------------------------------------------------------------+
//|  Trade log                                                       |
//+------------------------------------------------------------------+
void LogTrade(const SSetup &s, ulong deal, double profit)
  {
   if(g_log == INVALID_HANDLE) return;
   double risk = MathAbs(s.fill - s.sl);
   if(risk <= 0) risk = MathAbs(s.entry - s.sl);
   datetime tc = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   double   pc = HistoryDealGetDouble(deal, DEAL_PRICE);
   long     rs = HistoryDealGetInteger(deal, DEAL_REASON);
   MqlDateTime t; TimeToStruct(s.fillTime, t);
   FileWrite(g_log, s.up ? "BUY" : "SELL", TimeToString(s.placed, TIME_DATE | TIME_MINUTES),
             TimeToString(s.fillTime, TIME_DATE | TIME_SECONDS), t.hour, t.day_of_week,
             DoubleToString(s.hi - s.lo, _Digits), DoubleToString(s.entry, _Digits), DoubleToString(s.fill, _Digits),
             DoubleToString(s.sl, _Digits), DoubleToString(s.tp, _Digits), DoubleToString(risk, _Digits),
             TimeToString(tc, TIME_DATE | TIME_SECONDS), DoubleToString(pc, _Digits),
             rs == DEAL_REASON_SL ? "SL" : rs == DEAL_REASON_TP ? "TP" : "other", DoubleToString(profit, 2),
             DoubleToString((s.up ? pc - s.fill : s.fill - pc) / risk, 3), DoubleToString(s.mfe / risk, 3),
             DoubleToString(s.mae / risk, 3), DoubleToString((double)(tc - s.fillTime) / 60.0, 1),
             DoubleToString(s.fvgDist, 3), s.sweep ? 1 : 0, s.bias, DoubleToString(s.pdPct, 3));
   FileFlush(g_log);
  }

//+------------------------------------------------------------------+
//|  Events                                                          |
//+------------------------------------------------------------------+
int Fail(string why) { Print("INVALID INPUT: ", why); Alert("SMC Fib Strategy - invalid input: ", why); return INIT_PARAMETERS_INCORRECT; }

int OnInit()
  {
   if(InpFibEntry <= 0 || InpFibEntry >= 1)       return Fail("FibEntry must be between 0 and 1");
   if(InpTPFib >= InpFibEntry || InpTPFib < -2)   return Fail("TPFib must be below FibEntry (0 = range extreme)");
   if(InpSwingLen < 1 || InpBiasSwingLen < 1)     return Fail("swing lengths must be >= 1");
   if(InpLockBars < 1)                            return Fail("LockBars must be >= 1");
   if(InpLookback < 4 * InpSwingLen + 20)         return Fail("Lookback too small");
   if(InpRiskPct <= 0 || InpRiskPct > 5)          return Fail("RiskPct must be > 0 and <= 5");
   if(InpMaxTradesDay < 1)                        return Fail("MaxTradesDay must be >= 1");
   if(InpSLBuffer < 0 || InpMinFVG < 0 || InpFVGTol < 0 || InpMinRange < 0 || InpMaxRange < 0 || InpMinSLSpreads < 0 || InpMaxSpread < 0)
      return Fail("distances and filters must be >= 0");
   if(InpMaxRange > 0 && InpMaxRange <= InpMinRange) return Fail("MaxRange must be above MinRange");
   if(InpSession != "")
     {
      string p[];
      if(StringSplit(InpSession, '-', p) != 2) return Fail("Session must be HH:MM-HH:MM");
      g_sesS = ParseHHMM(p[0]); g_sesE = ParseHHMM(p[1]);
      if(g_sesS < 0 || g_sesE < 0 || g_sesS == g_sesE) return Fail("Session must be HH:MM-HH:MM");
     }
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   ArrayResize(g_set, 0); ArrayResize(g_ph, 0); ArrayResize(g_pl, 0);
   g_leg[0].active = false; g_leg[1].active = false;
   g_lastSH.time = 0; g_lastSL.time = 0; g_shBroken = true; g_slBroken = true;
   g_lastBar = 0; g_lastBiasBar = 0; g_day = 0;

   // unfilled orders from a previous run are not tracked - remove them
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic && g_trade.OrderDelete(t))
         PrintFormat("Old order #%I64u deleted on start", t);
     }

   if(InpTradeLog && !MQLInfoInteger(MQL_OPTIMIZATION))
     {
      string name = "SMC_trades_" + _Symbol + ".csv";
      g_log = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
      if(g_log != INVALID_HANDLE)
         FileWrite(g_log, "side", "placed", "fill_time", "hour", "weekday", "range", "entry", "fill", "sl", "tp", "risk", "close_time",
                   "close_price", "exit", "profit", "r", "mfe_r", "mae_r", "hold_min", "fvg_dist", "sweep", "bias", "pd_pct");
     }
   PrintFormat("SMC Fib Strategy | entry %s, bias %s | entry %.0f%%, TP %.0f%%, SL 100%% + %g | swing %d, lock %d | FVG %s%s | sweep %s | bias %s | risk %.2f%%",
               EnumToString(InpEntryTF), EnumToString(InpBiasTF), InpFibEntry * 100, InpTPFib * 100, InpSLBuffer, InpSwingLen, InpLockBars,
               InpRequireFVG ? "required" : "optional", InpFVGNearEntry ? StringFormat(" near entry (%.0f%%)", InpFVGTol * 100) : "",
               InpRequireSweep ? "required" : "optional", EnumToString(InpBias), InpRiskPct);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("Setups found %d | orders placed %d | skipped %d", g_cntSetups, g_cntPlaced, g_cntSkipped);
   if(g_log != INVALID_HANDLE) { FileClose(g_log); g_log = INVALID_HANDLE; }
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - (long)now % 86400);
   if(day != g_day) { g_day = day; g_halted = false; RecountToday(); }

   UpdateExcursions();

   if(!g_halted && InpMaxDailyLossPct > 0 && g_dayStartBal > 0 &&
      (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBal) / g_dayStartBal * 100.0 <= -InpMaxDailyLossPct)
     {
      g_halted = true;
      PrintFormat("DAILY LOSS STOP %.2f%% - closing everything until tomorrow", InpMaxDailyLossPct);
     }
   if(g_halted) { DeletePendings(-1, "daily loss stop"); ClosePositions("daily loss stop"); }

   ManagePendings();

   datetime biasBar = iTime(_Symbol, InpBiasTF, 0);
   if(biasBar > 0 && biasBar != g_lastBiasBar) { g_lastBiasBar = biasBar; UpdateBias(); }

   datetime bar = iTime(_Symbol, InpEntryTF, 0);
   if(bar <= 0 || bar == g_lastBar) return;
   MqlRates r[];
   if(g_lastBar == 0)
     {
      // warm-up: build the structure from history without trading
      int n = CopyRates(_Symbol, InpEntryTF, 1, InpLookback, r);
      if(n < 4 * InpSwingLen + 20) return;
      for(int last = 2 * InpSwingLen + 2; last < n; last++) ProcessBar(r, last, false);
      g_lastBar = bar;
      PrintFormat("Structure ready: last swing high %.*f (%s), last swing low %.*f (%s), 4H trend %d",
                  _Digits, g_lastSH.price, TimeToString(g_lastSH.time), _Digits, g_lastSL.price, TimeToString(g_lastSL.time), g_biasTrend);
      return;
     }
   g_lastBar = bar;
   int n = CopyRates(_Symbol, InpEntryTF, 1, InpLookback, r);
   if(n < 4 * InpSwingLen + 20) return;
   ProcessBar(r, n - 1, true);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol || (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      g_tradesToday++;
      int k = FindSetupByOrder((ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER));
      if(k < 0) return;
      g_set[k].filled   = true;
      g_set[k].posId    = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      g_set[k].fill     = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      g_set[k].fillTime = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
      PrintFormat("FILLED %s @ %.*f", g_set[k].up ? "BUY" : "SELL", _Digits, g_set[k].fill);
      if(InpOnePosition) DeletePendings(g_set[k].up ? 1 : 0, "a position opened");
     }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      if(PositionSelectByTicket(pos)) return;   // partly closed
      int k = FindSetupByPos(pos);
      if(k < 0) return;
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                      HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      PrintFormat("CLOSED %s %+.2f", g_set[k].up ? "BUY" : "SELL", profit);
      LogTrade(g_set[k], trans.deal, profit);
      RemoveSetup(k);
     }
  }

double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double dd     = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   if(trades < InpMinTrades || profit <= 0 || pf <= 1.0) return 0;
   if(InpScoreMaxDD > 0 && dd > InpScoreMaxDD) return 0;
   return (pf - 1.0) * MathSqrt(trades) / MathMax(dd, 1.0);
  }
//+------------------------------------------------------------------+
