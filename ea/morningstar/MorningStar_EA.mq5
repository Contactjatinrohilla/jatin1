//+------------------------------------------------------------------+
//|                                             MorningStar_EA.mq5    |
//|                                                                  |
//|  Looks for a 3-candle (or 4-candle) buying pattern on CLOSED      |
//|  candles of the chosen timeframe and opens one market BUY when    |
//|  the pattern completes.                                           |
//|                                                                  |
//|  C1 = bearish candle.                                             |
//|  C2 = low at/below C1's low, close inside C1's range.             |
//|  C3 = signal candle (close above C1's open, small upper wick)     |
//|       -> BUY. If C3 fails but closes inside C1's range, C4 gets   |
//|       one chance to be the signal candle. Never a 5th candle.     |
//|                                                                  |
//|  Stop loss below the signal candle, lot size from a dollar risk,  |
//|  take profit = risk x RR. Daily / weekly prop-firm loss limits.   |
//|  Optional TP1 / TP2: close a % of the position at risk x TP1 RR   |
//|  and risk x TP2 RR; the rest runs to the final take profit.       |
//|                                                                  |
//|  v1.04 RESEARCH: every pattern found is written to a CSV file     |
//|  (Common\Files) with its features and what price did afterwards,  |
//|  so tools/morningstar_edge.py can measure which signals have an   |
//|  edge. Optional filters (all OFF by default) apply the findings.  |
//|  Works on any symbol: all sizes come from the symbol's settings.  |
//+------------------------------------------------------------------+
#property copyright "MorningStar_EA"
#property version   "1.04"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS - the settings you can change in the EA window
//==================================================================
input group "Pattern"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M15; // Timeframe to look for the pattern on (M1 up to H4)
input double          InpEqualTolerance  = 0;          // How close C2's low must be to C1's low to count as "equal" (price)
input double          InpMaxUpperWickPct = 30;         // Max upper wick of signal candle, % of its size

input group "Filters (all OFF by default - switch on only what the research supports)"
input bool            InpRequireBullishSignal = false; // Signal candle must close above its own open
input double          InpMinSweepATR     = 0;          // C2 low must be below C1 low by this x ATR(14) (0 = off)
input int             InpTrendEMA        = 0;          // Only buy if signal close is above this EMA (0 = off)
input int             InpStartHour       = 0;          // Trade only from this server hour...
input int             InpEndHour         = 24;         // ...up to (not including) this hour (0 and 24 = all day)

input group "Risk"
input double          InpRiskUSD         = 100;        // Dollars lost if stop loss is hit
input double          InpRR              = 2.0;        // Take profit = risk x this number
input double          InpSLBufferPct     = 10;         // SL below signal candle low, % of its size
input bool            InpSLAtPatternLow  = false;      // true = SL below the LOWEST low of the pattern (usually C2) instead of the signal candle
input double          InpMaxLots         = 5.0;        // Safety cap on lot size

input group "Partial take profits (TP1 / TP2)"
input double          InpTP1_RR          = 1.0;        // TP1 level = risk x this number (0 = TP1 off)
input double          InpTP1_ClosePct    = 50;         // % of the ORIGINAL lots closed at TP1
input double          InpTP2_RR          = 1.5;        // TP2 level = risk x this number (0 = TP2 off)
input double          InpTP2_ClosePct    = 25;         // % of the ORIGINAL lots closed at TP2

input group "Prop firm limits"
input bool            InpUseLossLimits   = true;       // Use the daily / weekly loss limits
input double          InpDailyLossPct    = 2.5;        // Daily loss limit, % of start-of-day balance
input double          InpWeeklyLossPct   = 8.5;        // Weekly loss limit, % of start-of-week balance
input int             InpMaxTradesPerDay = 2;          // Max new trades per server day (0 = no limit)

input group "Research log"
input bool            InpLogSignals      = true;       // Write every pattern + its outcome to a CSV (Common\Files)
input int             InpLogMaxBars      = 100;        // Follow each logged signal for at most this many candles

input group "Other"
input long            InpMagic           = 880088;     // ID number that marks this EA's trades

//==================================================================
// GLOBAL VARIABLES - things the EA remembers between ticks
//==================================================================
CTrade   g_trade;                 // Helper object that sends orders

datetime g_lastBarTime   = 0;     // Open time of the newest candle we have already handled

datetime g_dayStart      = 0;     // Server time when the current day started (00:00)
datetime g_weekStart     = 0;     // Server time when the current week started (Monday 00:00)
double   g_dayStartBal   = 0;     // Account balance at the start of the day
double   g_weekStartBal  = 0;     // Account balance at the start of the week

bool     g_dailyHit      = false; // true = daily limit hit, no new trades until next day
bool     g_weeklyHit     = false; // true = weekly limit hit, no new trades until next Monday

ulong    g_origTicket    = 0;     // Position whose original lot size is remembered below
double   g_origLots      = 0;     // Lot size the position was opened with
ulong    g_warnTicket    = 0;     // Position + level of the last "lots too small" message
string   g_warnLevel     = "";    // (so that message is printed only once)

int      g_tradesToday   = 0;     // Trades this EA opened on this symbol today (server day)

int      g_hATR          = INVALID_HANDLE; // ATR(14) on InpTimeframe
int      g_hEMA50        = INVALID_HANDLE; // EMA 50 on InpTimeframe (research)
int      g_hEMA200       = INVALID_HANDLE; // EMA 200 on InpTimeframe (research)
int      g_hTrend        = INVALID_HANDLE; // EMA InpTrendEMA on InpTimeframe (filter)

const string EA_NAME     = "MorningStar_EA";

//==================================================================
// CANDLE HELPERS - read one candle on the chosen timeframe
// "shift" 1 = the most recently CLOSED candle, 2 = the one before...
//==================================================================
double CandleOpen(int shift)  { return iOpen (_Symbol, InpTimeframe, shift); }
double CandleHigh(int shift)  { return iHigh (_Symbol, InpTimeframe, shift); }
double CandleLow(int shift)   { return iLow  (_Symbol, InpTimeframe, shift); }
double CandleClose(int shift) { return iClose(_Symbol, InpTimeframe, shift); }

// Range = High - Low
double CandleRange(int shift) { return CandleHigh(shift) - CandleLow(shift); }

// Upper wick = High - the higher of Open/Close
double UpperWick(int shift)
{
   return CandleHigh(shift) - MathMax(CandleOpen(shift), CandleClose(shift));
}

// Lower wick = the lower of Open/Close - Low (not used by any rule,
// kept here so the definition is easy to find if a rule needs it later)
double LowerWick(int shift)
{
   return MathMin(CandleOpen(shift), CandleClose(shift)) - CandleLow(shift);
}

// Bearish candle = Close below Open
bool IsBearish(int shift) { return CandleClose(shift) < CandleOpen(shift); }

//==================================================================
// PATTERN RULES - each rule in its own small function
//==================================================================

// Is a price inside C1's range? (C1.Low <= price <= C1.High)
bool IsInsideC1Range(double price, int c1Shift)
{
   return (price >= CandleLow(c1Shift) && price <= CandleHigh(c1Shift));
}

// Candle 1: must be bearish. Its size does not matter.
bool IsC1Valid(int c1Shift)
{
   return IsBearish(c1Shift);
}

// Candle 2: low at or below C1's low (with tolerance) AND close inside C1's range.
// It may be bullish or bearish.
bool IsC2Valid(int c2Shift, int c1Shift)
{
   bool lowOk   = CandleLow(c2Shift) <= CandleLow(c1Shift) + InpEqualTolerance;
   bool closeOk = IsInsideC1Range(CandleClose(c2Shift), c1Shift);
   return (lowOk && closeOk);
}

// Signal candle (C3 or C4):
//   - Close must be ABOVE C1's open
//   - Upper wick must be <= InpMaxUpperWickPct % of the candle's range
//   - A candle with zero range fails
//   - The lower wick can be any size
bool PassesSignalRules(int sigShift, int c1Shift)
{
   double range = CandleRange(sigShift);
   if(range <= 0)
      return false;

   bool closeOk = CandleClose(sigShift) > CandleOpen(c1Shift);
   bool wickOk  = UpperWick(sigShift) <= (InpMaxUpperWickPct / 100.0) * range;
   return (closeOk && wickOk);
}

// true when the candles at shifts 1..4 are loaded
bool CandlesReady()
{
   if(Bars(_Symbol, InpTimeframe) < 6)
      return false;
   for(int s = 1; s <= 4; s++)
      if(CandleOpen(s) <= 0 || CandleHigh(s) <= 0 || CandleLow(s) <= 0 || CandleClose(s) <= 0)
         return false; // candle data not ready yet
   return true;
}

// Checks both pattern cases on the latest closed candles.
// Returns 3 for a 3-candle pattern, 4 for a 4-candle pattern, 0 for none.
// In both cases the signal candle is shift 1.
// ASSUMPTION: if Case A and Case B are both true on the same bar, only ONE
// BUY is placed and it is reported as a 3-candle pattern (Case A is checked first).
int DetectPattern()
{
   // Make sure enough candle history is loaded (we need shifts 1..4)
   if(!CandlesReady())
      return 0;

   // Case A: C1 = shift 3, C2 = shift 2, C3 = shift 1
   if(IsC1Valid(3) && IsC2Valid(2, 3) && PassesSignalRules(1, 3))
      return 3;

   // Case B: C1 = shift 4, C2 = shift 3, C3 = shift 2, C4 = shift 1
   if(IsC1Valid(4) && IsC2Valid(3, 4)
      && !PassesSignalRules(2, 4)                 // C3 did NOT give the signal
      && IsInsideC1Range(CandleClose(2), 4)       // C3 closed inside C1's range (pattern still alive)
      && PassesSignalRules(1, 4))                 // C4 gives the signal
      return 4;

   return 0;
}

//==================================================================
// INDICATOR + STOP LOSS HELPERS
//==================================================================

// Value of an indicator buffer at a shift (0 if not available yet)
double IndValue(int handle, int shift)
{
   if(handle == INVALID_HANDLE)
      return 0;
   double buf[1];
   if(CopyBuffer(handle, 0, shift, 1, buf) != 1)
      return 0;
   return buf[0];
}

// Lowest low of the pattern candles (shift 1 .. C1)
double PatternLow(int patternType)
{
   double lo = CandleLow(1);
   for(int s = 2; s <= patternType; s++)
      lo = MathMin(lo, CandleLow(s));
   return lo;
}

// Stop loss price before rounding. Buffer is always a % of the signal candle's size.
//   atPatternLow = false -> below the signal candle's low (original rule)
//   atPatternLow = true  -> below the lowest low of the whole pattern
double RawStopLoss(int patternType, bool atPatternLow)
{
   double base = atPatternLow ? PatternLow(patternType) : CandleLow(1);
   return base - (InpSLBufferPct / 100.0) * CandleRange(1);
}

//==================================================================
// FILTERS - extra conditions, all OFF by default.
// Returns true if the signal may be traded; otherwise "why" says which
// filter blocked it.
//==================================================================
bool FiltersPass(int patternType, string &why)
{
   int c1 = patternType;    // C1 shift is 3 or 4
   int c2 = patternType - 1;

   if(InpRequireBullishSignal && CandleClose(1) <= CandleOpen(1))
   {
      why = "signal candle is not bullish";
      return false;
   }
   if(InpMinSweepATR > 0)
   {
      double atr = IndValue(g_hATR, 1);
      if(atr <= 0 || CandleLow(c1) - CandleLow(c2) < InpMinSweepATR * atr)
      {
         why = "C2 did not sweep C1's low by " + DoubleToString(InpMinSweepATR, 2) + " x ATR";
         return false;
      }
   }
   if(InpTrendEMA > 0)
   {
      double ema = IndValue(g_hTrend, 1);
      if(ema <= 0 || CandleClose(1) <= ema)
      {
         why = "signal close is not above EMA " + IntegerToString(InpTrendEMA);
         return false;
      }
   }
   bool allDay = (InpStartHour == InpEndHour) || (InpStartHour <= 0 && InpEndHour >= 24);
   if(!allDay)
   {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      bool inside = (InpStartHour < InpEndHour)
                    ? (t.hour >= InpStartHour && t.hour < InpEndHour)
                    : (t.hour >= InpStartHour || t.hour < InpEndHour);   // window over midnight
      if(!inside)
      {
         why = "outside trading hours " + IntegerToString(InpStartHour) + "-" + IntegerToString(InpEndHour);
         return false;
      }
   }
   return true;
}

//==================================================================
// RESEARCH LOG
// Every pattern found (traded or not, filters or not) is followed as a
// "virtual" BUY at the Ask on the first tick after the signal candle.
// For two stop-loss styles (A = signal candle low, B = pattern low) it
// records the best profit reached BEFORE the stop was hit (MFE, in R),
// whether the stop was hit, and the result when the follow-up ended.
// With that, any take profit level can be tested afterwards:
//   MFE >= TP  -> win of TP R,  stop hit first -> -1 R.
// The file goes to the terminal's Common\Files folder.
//==================================================================
struct VSignal
{
   string   feat;          // feature columns, already formatted
   datetime barTime;       // open time of the entry candle
   double   entry;
   double   sl[2];
   double   risk[2];
   double   mfe[2];        // best (bid - entry) seen before the stop
   bool     done[2];
   int      hit[2];        // 1 = stop loss hit
   double   lastR[2];      // result in R when the follow-up ended
   int      bars[2];
};
VSignal  g_vs[];
int      g_logFile = INVALID_HANDLE;

string F3(double v) { return DoubleToString(v, 3); }

void OpenSignalLog()
{
   if(!InpLogSignals)
      return;
   string name = "MorningStar_signals_" + _Symbol + "_" + EnumToString(InpTimeframe) + ".csv";
   g_logFile = FileOpen(name, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(g_logFile == INVALID_HANDLE)
   {
      Print(EA_NAME, ": could not create research log ", name, " (error ", GetLastError(), ")");
      return;
   }
   FileWriteString(g_logFile,
      "time,weekday,hour,pattern,atr,c1_range_atr,c1_body_atr,sweep_atr,c2_close_pos,"
      "sig_bull,sig_body_pct,sig_uwick_pct,sig_range_atr,sig_close_vs_c1high_atr,"
      "riskA_atr,riskB_atr,spread_riskA,dist_ema50_atr,dist_ema200_atr,ema50_slope_atr,"
      "prior_move_atr,day_move_atr,"
      "entry,slA,mfeA_R,hitA,lastA_R,barsA,slB,mfeB_R,hitB,lastB_R,barsB\r\n");
   Print(EA_NAME, ": research log -> Common\\Files\\", name);
}

void WriteSignal(int i)
{
   if(g_logFile == INVALID_HANDLE)
      return;
   string line = g_vs[i].feat + "," + DoubleToString(g_vs[i].entry, _Digits);
   for(int k = 0; k < 2; k++)
      line += "," + DoubleToString(g_vs[i].sl[k], _Digits)
            + "," + F3(g_vs[i].mfe[k] / g_vs[i].risk[k])
            + "," + IntegerToString(g_vs[i].hit[k])
            + "," + F3(g_vs[i].lastR[k])
            + "," + IntegerToString(g_vs[i].bars[k]);
   FileWriteString(g_logFile, line + "\r\n");
   FileFlush(g_logFile);
}

// Called on the first tick of a new candle when a pattern was found
void LogSignal(int patternType)
{
   if(g_logFile == INVALID_HANDLE)
      return;
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0)
      return;

   int    c1  = patternType, c2 = patternType - 1;
   double atr = IndValue(g_hATR, 1);
   if(atr <= 0)
      return;                                   // indicator not ready yet

   VSignal v;
   v.barTime = iTime(_Symbol, InpTimeframe, 0);
   v.entry   = tick.ask;
   v.sl[0]   = RawStopLoss(patternType, false);
   v.sl[1]   = RawStopLoss(patternType, true);
   for(int k = 0; k < 2; k++)
   {
      v.risk[k]  = v.entry - v.sl[k];
      v.mfe[k]   = 0;
      v.done[k]  = (v.risk[k] <= 0);            // impossible stop -> nothing to follow
      v.hit[k]   = 0;
      v.lastR[k] = 0;
      v.bars[k]  = 0;
      if(v.risk[k] <= 0)
         v.risk[k] = 1e-10;
   }

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   double c1Range = CandleRange(c1);
   double sigRng  = CandleRange(1);
   double ema50   = IndValue(g_hEMA50, 1);
   double ema200  = IndValue(g_hEMA200, 1);
   double ema50b  = IndValue(g_hEMA50, 11);
   double dOpen   = iOpen(_Symbol, PERIOD_D1, 0);
   double prior0  = iClose(_Symbol, InpTimeframe, c1 + 1);
   double prior10 = iClose(_Symbol, InpTimeframe, c1 + 11);

   v.feat = TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES)
          + "," + IntegerToString(t.day_of_week)
          + "," + IntegerToString(t.hour)
          + "," + IntegerToString(patternType)
          + "," + DoubleToString(atr, _Digits)
          + "," + F3(c1Range / atr)
          + "," + F3((CandleOpen(c1) - CandleClose(c1)) / atr)
          + "," + F3((CandleLow(c1) - CandleLow(c2)) / atr)
          + "," + F3(c1Range > 0 ? (CandleClose(c2) - CandleLow(c1)) / c1Range : 0)
          + "," + IntegerToString(CandleClose(1) > CandleOpen(1) ? 1 : 0)
          + "," + F3(sigRng > 0 ? MathAbs(CandleClose(1) - CandleOpen(1)) / sigRng * 100 : 0)
          + "," + F3(sigRng > 0 ? UpperWick(1) / sigRng * 100 : 0)
          + "," + F3(sigRng / atr)
          + "," + F3((CandleClose(1) - CandleHigh(c1)) / atr)
          + "," + F3((v.entry - v.sl[0]) / atr)
          + "," + F3((v.entry - v.sl[1]) / atr)
          + "," + F3((tick.ask - tick.bid) / v.risk[0])
          + "," + F3(ema50  > 0 ? (CandleClose(1) - ema50)  / atr : 0)
          + "," + F3(ema200 > 0 ? (CandleClose(1) - ema200) / atr : 0)
          + "," + F3(ema50 > 0 && ema50b > 0 ? (ema50 - ema50b) / atr : 0)
          + "," + F3(prior0 > 0 && prior10 > 0 ? (prior0 - prior10) / atr : 0)
          + "," + F3(dOpen > 0 ? (CandleClose(1) - dOpen) / atr : 0);

   int n = ArraySize(g_vs);
   ArrayResize(g_vs, n + 1);
   g_vs[n] = v;
}

// Called on every tick: update each followed signal with the current Bid
void UpdateSignals(bool newBar)
{
   if(g_logFile == INVALID_HANDLE)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0)
      return;

   for(int i = ArraySize(g_vs) - 1; i >= 0; i--)
   {
      int barsSince = newBar ? iBarShift(_Symbol, InpTimeframe, g_vs[i].barTime) : -1;
      for(int k = 0; k < 2; k++)
      {
         if(g_vs[i].done[k])
            continue;
         if(bid <= g_vs[i].sl[k])                       // stop loss reached
         {
            g_vs[i].done[k]  = true;
            g_vs[i].hit[k]   = 1;
            g_vs[i].lastR[k] = -1;
            g_vs[i].bars[k]  = iBarShift(_Symbol, InpTimeframe, g_vs[i].barTime);
            continue;
         }
         g_vs[i].mfe[k] = MathMax(g_vs[i].mfe[k], bid - g_vs[i].entry);
         if(barsSince >= InpLogMaxBars)                 // followed long enough
         {
            g_vs[i].done[k]  = true;
            g_vs[i].lastR[k] = (bid - g_vs[i].entry) / g_vs[i].risk[k];
            g_vs[i].bars[k]  = barsSince;
         }
      }
      if(g_vs[i].done[0] && g_vs[i].done[1])
      {
         WriteSignal(i);
         int last = ArraySize(g_vs) - 1;               // remove: move the last one here, shrink
         if(i != last)
            g_vs[i] = g_vs[last];
         ArrayResize(g_vs, last);
      }
   }
}

// At the end of a test: write signals still being followed (stop not hit)
void FlushSignals()
{
   if(g_logFile == INVALID_HANDLE)
      return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   for(int i = 0; i < ArraySize(g_vs); i++)
   {
      for(int k = 0; k < 2; k++)
         if(!g_vs[i].done[k])
         {
            g_vs[i].lastR[k] = (bid - g_vs[i].entry) / g_vs[i].risk[k];
            g_vs[i].bars[k]  = iBarShift(_Symbol, InpTimeframe, g_vs[i].barTime);
         }
      WriteSignal(i);
   }
   ArrayResize(g_vs, 0);
   FileClose(g_logFile);
   g_logFile = INVALID_HANDLE;
}

//==================================================================
// JOURNAL EXPLANATIONS - say in the Journal why a pattern did NOT trade.
// Only printed when C1 is bearish AND C2's low reached C1's low (the
// pattern had started), so the Journal is not flooded on every candle.
//==================================================================
string Px(double price) { return DoubleToString(price, _Digits); }

// Why a candle failed the signal candle rules
string SignalFailReason(int sigShift, int c1Shift)
{
   double range = CandleRange(sigShift);
   if(range <= 0)
      return "its range is 0";
   string why = "";
   if(CandleClose(sigShift) <= CandleOpen(c1Shift))
      why = "close " + Px(CandleClose(sigShift)) + " is not above C1 open " + Px(CandleOpen(c1Shift));
   double wickPct = UpperWick(sigShift) / range * 100.0;
   if(wickPct > InpMaxUpperWickPct)
      why += (why == "" ? "" : " and ") + "upper wick is " + DoubleToString(wickPct, 1)
             + "% of its size (max " + DoubleToString(InpMaxUpperWickPct, 1) + "%)";
   return why;
}

// Why one case failed. c1Shift = 3 for the 3-candle case, 4 for the 4-candle case.
string WhyCaseFailed(int c1Shift)
{
   int c2 = c1Shift - 1;
   int c3 = c1Shift - 2;
   if(!IsInsideC1Range(CandleClose(c2), c1Shift))
      return "C2 close " + Px(CandleClose(c2)) + " is outside C1 range "
             + Px(CandleLow(c1Shift)) + " - " + Px(CandleHigh(c1Shift));

   if(c1Shift == 3) // C3 is the last closed candle
   {
      string why = "C3 failed: " + SignalFailReason(c3, c1Shift);
      if(IsInsideC1Range(CandleClose(c3), c1Shift))
         why += " -> C3 closed inside C1 range, C4 will be checked on the next candle";
      else
         why += " -> C3 closed outside C1 range, pattern cancelled";
      return why;
   }

   // 4-candle case: C3 = shift 2, C4 = shift 1
   if(PassesSignalRules(c3, c1Shift))
      return "C3 already gave the signal one candle ago (3-candle pattern)";
   if(!IsInsideC1Range(CandleClose(c3), c1Shift))
      return "C3 close " + Px(CandleClose(c3)) + " was outside C1 range, pattern was cancelled";
   return "C4 failed: " + SignalFailReason(1, c1Shift) + " -> pattern cancelled";
}

void ExplainNoPattern()
{
   if(!CandlesReady())
      return;
   if(IsC1Valid(3) && CandleLow(2) <= CandleLow(3) + InpEqualTolerance)
      Print(EA_NAME, ": no 3-candle BUY (C1 = ", TimeToString(iTime(_Symbol, InpTimeframe, 3)),
            "): ", WhyCaseFailed(3));
   if(IsC1Valid(4) && CandleLow(3) <= CandleLow(4) + InpEqualTolerance)
      Print(EA_NAME, ": no 4-candle BUY (C1 = ", TimeToString(iTime(_Symbol, InpTimeframe, 4)),
            "): ", WhyCaseFailed(4));
}

//==================================================================
// NEW CANDLE DETECTION - true only once, on the first tick of a new candle
//==================================================================
bool IsNewBar()
{
   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == 0)
      return false;              // data not ready yet

   // If no time was saved on attach (data was not ready), save it now
   // and do NOT treat it as a new candle, so an old signal is never traded.
   if(g_lastBarTime == 0)
   {
      g_lastBarTime = barTime;
      return false;
   }

   if(barTime != g_lastBarTime)
   {
      g_lastBarTime = barTime;
      return true;
   }
   return false;
}

//==================================================================
// OPEN TRADE CHECKS - find / close this EA's trades on this symbol
//==================================================================
bool HasOpenTrade()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

// Closes all of this EA's trades. If a close fails (for example the
// market is closed) the trade is left open and the next tick tries again.
void CloseAllEATrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol
         || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      if(!g_trade.PositionClose(ticket))
         Print(EA_NAME, ": could not close trade #", ticket, " (retcode ",
               g_trade.ResultRetcode(), " ", g_trade.ResultRetcodeDescription(),
               "). Will retry on the next tick.");
   }
}

//==================================================================
// PROP FIRM LOSS LIMITS
//==================================================================

// Balance at a past moment, rebuilt from the trade history so it is
// correct even after MT5 restarts:
//   start balance = current balance - (profit + swap + commission + fee)
//                   of all BUY/SELL deals since that moment.
// Only DEAL_TYPE_BUY and DEAL_TYPE_SELL deals count, so deposits and
// withdrawals are ignored.
// ASSUMPTION: deals of ALL symbols and ALL EAs are counted, because the
// prop-firm limit is on the whole account balance. Opening deals are also
// counted (their profit is 0, but their commission already left the balance).
double BalanceAt(datetime fromTime)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(!HistorySelect(fromTime, TimeCurrent() + 86400))
      return balance;

   double sum   = 0;
   int    total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;
      if((datetime)HistoryDealGetInteger(ticket, DEAL_TIME) < fromTime)
         continue;

      ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;

      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT)
           + HistoryDealGetDouble(ticket, DEAL_SWAP)
           + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
           + HistoryDealGetDouble(ticket, DEAL_FEE);
   }
   return balance - sum;
}

// Works out the start of the current server day and week. When a new day
// (or week) begins, the start balance is recalculated and the "limit hit"
// flag for that period is cleared. The start balance does not change during
// the day, so it is only calculated when the day/week changes (and on attach).
void UpdateStartBalances()
{
   datetime now      = TimeCurrent();
   datetime dayStart = now - (now % 86400);           // today 00:00 server time

   MqlDateTime dt;
   TimeToStruct(dayStart, dt);
   int daysSinceMonday = (dt.day_of_week + 6) % 7;     // Monday=0 ... Sunday=6
   datetime weekStart  = dayStart - daysSinceMonday * 86400;

   if(dayStart != g_dayStart)
   {
      g_dayStart    = dayStart;
      g_dayStartBal = BalanceAt(dayStart);
      g_dailyHit    = false;                          // new server day: trading allowed again
      g_tradesToday = CountTradesToday();             // rebuilt from history (restart-safe)
   }
   if(weekStart != g_weekStart)
   {
      g_weekStart    = weekStart;
      g_weekStartBal = BalanceAt(weekStart);
      g_weeklyHit    = false;                         // new week: trading allowed again
   }
}

// Number of trades this EA opened on this symbol since the start of the
// server day. Read from the trade history so it stays correct after a restart.
// Only OPENING deals count (a TP1/TP2 partial close is not a new trade).
int CountTradesToday()
{
   if(!HistorySelect(g_dayStart, TimeCurrent() + 86400))
      return g_tradesToday;

   int count = 0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if((datetime)HistoryDealGetInteger(deal, DEAL_TIME) < g_dayStart)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol
         || HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

// true when today's trade limit is used up
bool TradeLimitReached()
{
   return (InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay);
}

// Money lost so far today / this week (0 if in profit)
double DailyLossUsed()  { return MathMax(0.0, g_dayStartBal  - AccountInfoDouble(ACCOUNT_EQUITY)); }
double WeeklyLossUsed() { return MathMax(0.0, g_weekStartBal - AccountInfoDouble(ACCOUNT_EQUITY)); }
double DailyLossLimit() { return g_dayStartBal  * InpDailyLossPct  / 100.0; }
double WeeklyLossLimit(){ return g_weekStartBal * InpWeeklyLossPct / 100.0; }

// Runs on EVERY tick. If a limit is reached: Alert once, close all of this
// EA's trades (retrying on later ticks if needed) and block new trades.
void CheckLossLimits()
{
   UpdateStartBalances();
   if(!InpUseLossLimits)
      return;

   if(!g_dailyHit && DailyLossLimit() > 0 && DailyLossUsed() >= DailyLossLimit())
   {
      g_dailyHit = true;
      Alert(EA_NAME, " ", _Symbol, ": DAILY LOSS LIMIT HIT (",
            DoubleToString(DailyLossUsed(), 2), " of ", DoubleToString(DailyLossLimit(), 2),
            "). Closing trades. No new trades until the next server day.");
   }
   if(!g_weeklyHit && WeeklyLossLimit() > 0 && WeeklyLossUsed() >= WeeklyLossLimit())
   {
      g_weeklyHit = true;
      Alert(EA_NAME, " ", _Symbol, ": WEEKLY LOSS LIMIT HIT (",
            DoubleToString(WeeklyLossUsed(), 2), " of ", DoubleToString(WeeklyLossLimit(), 2),
            "). Closing trades. No new trades until next Monday.");
   }

   // While a limit is active, keep closing any of our trades still open
   if((g_dailyHit || g_weeklyHit) && HasOpenTrade())
      CloseAllEATrades();
}

//==================================================================
// PRICE / LOT ROUNDING HELPERS
//==================================================================

// Round a price to the nearest allowed tick
double RoundToTick(double price, double tickSize)
{
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
}

// Number of decimals in the lot step (0.01 -> 2, 0.1 -> 1, 1 -> 0)
int StepDigits(double step)
{
   int    digits = 0;
   double s      = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-9)
   {
      s *= 10.0;
      digits++;
   }
   return digits;
}

//==================================================================
// TRADE PLACEMENT - one market BUY, signal candle = shift 1
//==================================================================
void OpenBuy(int patternType)
{
   // The signal candle is always the last closed candle (shift 1)

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0)
   {
      Print(EA_NAME, ": trade skipped - no valid price available.");
      return;
   }
   double ask = tick.ask;
   double bid = tick.bid;

   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0)
      tickSize = _Point;   // ASSUMPTION: fall back to the point size if the broker reports 0

   // --- Stop loss: below the signal candle's low (or the pattern's low if
   //     InpSLAtPatternLow) by a % of the signal candle's size
   double sl = RoundToTick(RawStopLoss(patternType, InpSLAtPatternLow), tickSize);

   double slDist = ask - sl;
   if(slDist <= 0)
   {
      Print(EA_NAME, ": trade skipped - stop loss (", DoubleToString(sl, _Digits),
            ") is not below the Ask price (", DoubleToString(ask, _Digits), ").");
      return;
   }

   // --- Lot size from the dollar risk
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0)
      tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickValue <= 0)
   {
      Print(EA_NAME, ": trade skipped - broker reports a tick value of 0, cannot size the trade.");
      return;
   }

   double lossPerLot = (slDist / tickSize) * tickValue;   // money lost per 1 lot if SL is hit
   double lots       = InpRiskUSD / lossPerLot;

   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0)
      step = minLot;       // ASSUMPTION: if the broker reports no lot step, use the minimum lot

   // Cap first, then round DOWN to the lot step (so the cap is never exceeded)
   lots = MathMin(lots, InpMaxLots);
   if(maxLot > 0)
      lots = MathMin(lots, maxLot);
   if(step > 0)
      lots = MathFloor(lots / step + 1e-9) * step;     // tiny 1e-9 avoids 0.3 becoming 0.29999
   lots = NormalizeDouble(lots, StepDigits(step));

   if(lots < minLot || lots <= 0)
   {
      Print(EA_NAME, ": trade skipped - calculated lot size ", DoubleToString(lots, 4),
            " is below the broker minimum ", DoubleToString(minLot, 4),
            ". Risk $", DoubleToString(InpRiskUSD, 2), " is too small for a stop of ",
            DoubleToString(slDist, _Digits), " (1 lot would lose ", DoubleToString(lossPerLot, 2), ").");
      return;
   }

   // --- Take profit: risk distance x RR above the Ask
   double tp = RoundToTick(ask + slDist * InpRR, tickSize);

   // --- Broker minimum stop distance
   // ASSUMPTION: the broker measures a BUY's SL from Bid and TP from Ask/Bid,
   // so we use the SMALLER distance for each (SL from Bid, TP from Ask) to be safe.
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double slGap   = MathMin(ask, bid) - sl;
   double tpGap   = tp - MathMax(ask, bid);
   if(slGap < minDist || tpGap < minDist || tpGap <= 0)
   {
      Print(EA_NAME, ": trade skipped - SL or TP is too close to price. SL gap ",
            DoubleToString(slGap, _Digits), ", TP gap ", DoubleToString(tpGap, _Digits),
            ", broker minimum ", DoubleToString(minDist, _Digits), ".");
      return;
   }

   // --- Send the market BUY
   if(!g_trade.Buy(lots, _Symbol, ask, sl, tp, "MS"))
   {
      Print(EA_NAME, ": BUY failed - retcode ", g_trade.ResultRetcode(), " ",
            g_trade.ResultRetcodeDescription());
      return;
   }

   g_tradesToday++;                                   // counts toward the daily trade limit

   double entry = g_trade.ResultPrice();
   if(entry <= 0)
      entry = ask;

   Print(EA_NAME, ": BUY opened | ", patternType, "-candle pattern",
         " | entry ", DoubleToString(entry, _Digits),
         " | SL ",    DoubleToString(sl, _Digits),
         " | TP ",    DoubleToString(tp, _Digits),
         " | TP1 ",   (InpTP1_RR > 0 && InpTP1_ClosePct > 0) ? DoubleToString(entry + (entry - sl) * InpTP1_RR, _Digits) : "off",
         " | TP2 ",   (InpTP2_RR > 0 && InpTP2_ClosePct > 0) ? DoubleToString(entry + (entry - sl) * InpTP2_RR, _Digits) : "off",
         " | lots ",  DoubleToString(lots, StepDigits(step)),
         " | risk $", DoubleToString(lots * lossPerLot, 2));
}

//==================================================================
// PARTIAL TAKE PROFITS (TP1 / TP2)
// Checked on every tick. Nothing is stored between restarts: the EA works
// out what is already done by comparing the position's current lots with
// the lots it was opened with (read from the trade history).
//   TP1 price = entry + risk x InpTP1_RR -> closed lots brought up to TP1 %
//   TP2 price = entry + risk x InpTP2_RR -> closed lots brought up to TP1 % + TP2 %
//   The rest stays open until the final TP (InpRR) or the stop loss.
// "risk" = entry price - stop loss price (the SL is never moved by this EA).
//==================================================================

// Lot size the position was opened with (from history, remembered per position)
double OriginalLots(ulong ticket, double currentLots)
{
   if(ticket == g_origTicket && g_origLots > 0)
      return g_origLots;

   double lots = currentLots;   // fallback if history cannot be read
   long   posId = PositionGetInteger(POSITION_IDENTIFIER);
   if(HistorySelectByPosition(posId))
   {
      for(int i = 0; i < HistoryDealsTotal(); i++)
      {
         ulong deal = HistoryDealGetTicket(i);
         if(deal > 0 && (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            lots = HistoryDealGetDouble(deal, DEAL_VOLUME);
            break;
         }
      }
   }
   g_origTicket = ticket;
   g_origLots   = lots;
   return lots;
}

// Round a lot size DOWN to the symbol's lot step
double FloorToStep(double lots)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      return lots;
   return NormalizeDouble(MathFloor(lots / step + 1e-9) * step, StepDigits(step));
}

void ManagePartialTPs()
{
   bool tp1On = (InpTP1_RR > 0 && InpTP1_ClosePct > 0);
   bool tp2On = (InpTP2_RR > 0 && InpTP2_ClosePct > 0);
   if(!tp1On && !tp2On)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol
         || PositionGetInteger(POSITION_MAGIC) != InpMagic
         || PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double lots  = PositionGetDouble(POSITION_VOLUME);
      double risk  = entry - sl;
      if(sl <= 0 || risk <= 0)
         continue;                               // no usable stop loss -> cannot place TP levels

      double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double orig    = OriginalLots(ticket, lots);
      double closed  = orig - lots;              // lots already closed
      double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double eps     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP) / 2.0;

      // Total lots that should be closed by now, based on how far price has gone.
      // If price jumps past both levels at once, both portions are closed together.
      bool   hit1   = tp1On && bid >= entry + risk * InpTP1_RR;
      bool   hit2   = tp2On && bid >= entry + risk * InpTP2_RR;
      if(!hit1 && !hit2)
         continue;
      double target = (hit1 ? orig * InpTP1_ClosePct / 100.0 : 0)
                    + (hit2 ? orig * InpTP2_ClosePct / 100.0 : 0);
      string level  = hit2 ? "TP2" : "TP1";

      double toClose = FloorToStep(target - closed);
      if(toClose < eps)
         continue;                               // this level's part is already closed

      if(toClose < minLot - 1e-9)
      {
         // Print only once per position and level, not on every tick
         if(g_warnTicket != ticket || g_warnLevel != level)
         {
            Print(EA_NAME, ": ", level, " reached but ", DoubleToString(toClose, 4),
                  " lots is below the broker minimum ", DoubleToString(minLot, 4),
                  " - nothing closed. Use a bigger position or a bigger close %.");
            g_warnTicket = ticket;
            g_warnLevel  = level;
         }
         continue;
      }

      // ASSUMPTION: if what would remain is smaller than the broker's minimum
      // lot, the whole position is closed instead.
      if(lots - toClose < minLot - 1e-9)
         toClose = lots;

      bool ok = (toClose >= lots) ? g_trade.PositionClose(ticket)
                                  : g_trade.PositionClosePartial(ticket, toClose);
      if(ok)
         Print(EA_NAME, ": ", level, " hit at ", Px(bid), " - closed ",
               DoubleToString(toClose, 2), " of ", DoubleToString(orig, 2), " lots.");
      else
         Print(EA_NAME, ": ", level, " partial close failed (retcode ", g_trade.ResultRetcode(), " ",
               g_trade.ResultRetcodeDescription(), "). Will retry on the next tick.");
   }
}

//==================================================================
// CHART DISPLAY - text in the top-left corner
//==================================================================
void UpdateDisplay()
{
   string status;
   if(g_weeklyHit)          status = "WEEKLY LIMIT HIT";
   else if(g_dailyHit)      status = "DAILY LIMIT HIT";
   else if(HasOpenTrade())  status = "Trade open";
   else if(TradeLimitReached()) status = "DAILY TRADE LIMIT REACHED";
   else                     status = "Waiting for pattern";

   string tradesMax = (InpMaxTradesPerDay > 0) ? IntegerToString(InpMaxTradesPerDay) : "no limit";

   string limitsNote = InpUseLossLimits ? "" : "  (limits OFF)";

   // Note: amounts are in the account currency (the spec calls them "$")
   Comment(EA_NAME, "\n",
           "Symbol: ",    _Symbol, "   Timeframe: ", EnumToString(InpTimeframe), "\n",
           "Risk: $",     DoubleToString(InpRiskUSD, 2), "   RR: ", DoubleToString(InpRR, 2), "\n",
           "TP1: ", DoubleToString(InpTP1_ClosePct, 0), "% at ", DoubleToString(InpTP1_RR, 2), "R   ",
           "TP2: ", DoubleToString(InpTP2_ClosePct, 0), "% at ", DoubleToString(InpTP2_RR, 2), "R\n",
           "Daily loss used: $",  DoubleToString(DailyLossUsed(), 2),
           " of $",               DoubleToString(DailyLossLimit(), 2), limitsNote, "\n",
           "Weekly loss used: $", DoubleToString(WeeklyLossUsed(), 2),
           " of $",               DoubleToString(WeeklyLossLimit(), 2), limitsNote, "\n",
           "Trades today: ", g_tradesToday, " of ", tradesMax, "\n",
           "Status: ", status);
}

//==================================================================
// EA START
//==================================================================
int OnInit()
{
   // Only timeframes from M1 up to H4 are allowed
   if(PeriodSeconds(InpTimeframe) > 4 * 3600)
   {
      Alert(EA_NAME, ": timeframe ", EnumToString(InpTimeframe),
            " is not allowed. Use M1 up to H4.");
      return INIT_PARAMETERS_INCORRECT;
   }

   // TP1 + TP2 cannot close more than the whole position
   if(InpTP1_ClosePct < 0 || InpTP2_ClosePct < 0 || InpTP1_ClosePct + InpTP2_ClosePct > 100)
   {
      Alert(EA_NAME, ": TP1 % + TP2 % must be between 0 and 100.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTP1_RR > 0 && InpTP2_RR > 0 && InpTP2_RR <= InpTP1_RR)
      Print(EA_NAME, ": NOTE - TP2 RR (", InpTP2_RR, ") is not above TP1 RR (", InpTP1_RR, ").");
   if((InpTP1_RR >= InpRR) || (InpTP2_RR >= InpRR))
      Print(EA_NAME, ": NOTE - a TP1/TP2 level is at or beyond the final TP (RR ", InpRR,
            "), so it will never be reached before the final TP closes the trade.");

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   // The EA reads candles from InpTimeframe, NOT from the chart. Warn if they differ.
   if(PeriodSeconds(InpTimeframe) != PeriodSeconds(_Period))
      Print(EA_NAME, ": NOTE - pattern timeframe is ", EnumToString(InpTimeframe),
            " but the chart is ", EnumToString(_Period),
            ". The EA trades patterns on ", EnumToString(InpTimeframe), " candles only.");

   // Indicators used by the filters and the research log
   g_hATR    = iATR(_Symbol, InpTimeframe, 14);
   g_hEMA50  = iMA(_Symbol, InpTimeframe, 50,  0, MODE_EMA, PRICE_CLOSE);
   g_hEMA200 = iMA(_Symbol, InpTimeframe, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(InpTrendEMA > 0)
      g_hTrend = iMA(_Symbol, InpTimeframe, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   OpenSignalLog();

   // Save the current candle time so an old signal is not traded on attach
   g_lastBarTime = iTime(_Symbol, InpTimeframe, 0);

   // Rebuild start-of-day / start-of-week balance from history
   g_dayStart  = 0;
   g_weekStart = 0;
   g_dailyHit  = false;
   g_weeklyHit = false;
   UpdateStartBalances();

   UpdateDisplay();
   return INIT_SUCCEEDED;
}

//==================================================================
// EA STOP
//==================================================================
void OnDeinit(const int reason)
{
   FlushSignals();
   if(g_hATR    != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hEMA50  != INVALID_HANDLE) IndicatorRelease(g_hEMA50);
   if(g_hEMA200 != INVALID_HANDLE) IndicatorRelease(g_hEMA200);
   if(g_hTrend  != INVALID_HANDLE) IndicatorRelease(g_hTrend);
   Comment("");
}

//==================================================================
// EVERY TICK
//==================================================================
void OnTick()
{
   // 1. Loss limits are checked on every tick
   CheckLossLimits();

   // 1b. Partial take profits (TP1 / TP2) are checked on every tick
   ManagePartialTPs();

   // 2. Pattern is checked only once, on the first tick of a new candle
   bool   newBar = IsNewBar();
   string why    = "";
   if(newBar)
   {
      int patternType = DetectPattern();
      if(patternType > 0)
         LogSignal(patternType);           // research log: every pattern, before any filter
      if(patternType == 0)
         ExplainNoPattern();               // Journal note if a pattern started but failed
      else if(!FiltersPass(patternType, why))
         Print(EA_NAME, ": ", patternType, "-candle pattern found but SKIPPED by filter - ", why, ".");
      else if(InpUseLossLimits && g_weeklyHit)
         Print(EA_NAME, ": ", patternType, "-candle pattern found but SKIPPED - weekly loss limit hit.");
      else if(InpUseLossLimits && g_dailyHit)
         Print(EA_NAME, ": ", patternType, "-candle pattern found but SKIPPED - daily loss limit hit.");
      else if(TradeLimitReached())
         Print(EA_NAME, ": ", patternType, "-candle pattern found but SKIPPED - daily trade limit reached (",
               g_tradesToday, " of ", InpMaxTradesPerDay, ").");
      else if(HasOpenTrade())              // only one open trade at a time
         Print(EA_NAME, ": ", patternType, "-candle pattern found but SKIPPED - a trade from this EA is already open.");
      else
         OpenBuy(patternType);
   }

   // 2b. Research log: follow every logged signal with the current price
   UpdateSignals(newBar);

   // 3. Refresh the on-chart text
   UpdateDisplay();
}
//+------------------------------------------------------------------+
