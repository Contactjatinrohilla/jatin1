//+------------------------------------------------------------------+
//|                                 NAS_PDH_PDL_Breakout_v137.mq5    |
//|                                                                  |
//|  Nasdaq 100 CFD (NAS100 / US100 / USTEC / NDX100) breakouts.      |
//|                                                                  |
//|  Three setups, traded independently:                             |
//|  1. PDH / PDL - yesterday's high and low.                        |
//|  2. 4H        - high and low of the last finished 4-hour candle. |
//|  3. KZ range  - high and low of each finished killzone, traded   |
//|                 any time in trading hours until the day ends.    |
//|  v1.36: PDH / 4H trade all trading hours, killzones only build   |
//|  the KZ ranges (InpKZFilterPDH4H = true = old v1.35 behaviour).  |
//|  v1.37: a level price has crossed is gone for the day (4H: until |
//|  the next 4H candle), also when the EA could not trade it then.  |
//|                                                                  |
//|  Entry: a stop order on the level, or (confirmation on) wait for |
//|  a candle to CLOSE past the level, then a limit order back at    |
//|  the level or a market order at once.                            |
//|  Every trade: fixed SL / TP in index points, lot from risk %,    |
//|  optional breakeven / trailing. Optional killzones (New York     |
//|  time), prop firm daily / weekly loss limits, live time lock.    |
//|  Nothing is held overnight: all closed at the window end and     |
//|  5 minutes before the broker's daily close.                      |
//|                                                                  |
//|  Distances are INDEX POINTS (50 = a 50-point Nasdaq move).       |
//|  Times are SERVER time unless they say New York.                 |
//+------------------------------------------------------------------+
#property copyright "NAS Breakout Simple"
#property version   "1.37"
#property description "PDH/PDL breakout + 4H straddle + killzone high/low breakout for Nasdaq 100 CFDs. Optional prop firm loss limits and candle close confirmation."

#include <Trade\Trade.mqh>

// === V133 START ===
// Inputs in a logical order. Names and default values are unchanged, so old set files still load.
input group "=== 1. Setups ==="
input bool   InpUsePDH          = true;          // Trade yesterday's high / low breakout (PDH / PDL)
input bool   InpUseH4           = true;          // Trade the high / low of the last 4-hour candle
// === V135 START ===
input bool   InpUseKZRange      = false;         // Trade the high / low of each finished killzone (needs a killzone on)
// === V135 END ===

input group "=== 2. Trading hours and killzones ==="
input string InpWindow          = "00:00-23:55"; // Trading hours, server time HH:MM-HH:MM (all closed at the end)
input int    InpBrokerGMTWinter = 2;             // Broker clock in WINTER = GMT + this many hours
input bool   InpBrokerDST       = true;          // Broker clock moves 1 hour forward in summer (true/false)
input bool   InpKZAsian         = false;         // Asian killzone, 20:00-24:00 New York time
input bool   InpKZLondon        = false;         // London killzone, 02:00-05:00 New York time
input bool   InpKZNYAM          = false;         // NY AM killzone, 08:30-11:00 New York time (all off = no killzones)
// === V136 START ===
input bool   InpKZFilterPDH4H   = false;         // PDH / 4H only inside killzones (false = all trading hours, true = old v1.35)
// === V136 END ===

input group "=== 3. Entry confirmation ==="
input bool   InpUseConfirm      = true;          // Wait for a candle to CLOSE past the level (false = stop order on the level)
input int    InpConfirmMinutes  = 15;            // Confirmation candle length, minutes (1-240)
input bool   InpEnterAtClose    = false;         // After confirmation: true = enter now at market, false = limit order at the level
// === V137 START ===
input bool   InpLevelOnce       = true;          // A level price already crossed is gone for the day, also if the EA could not trade it (false = v1.36)
// === V137 END ===

input group "=== 4. Stop loss and take profit (index points) ==="
input double InpSL              = 50.0;          // Stop loss distance, points
input bool   InpUseTP           = false;         // Use the fixed take profit below (false = SL x ratio)
input double InpFixedTP         = 100.0;         // Fixed take profit distance, points
input double InpRR              = 2.0;           // Take profit = stop loss x this ratio (0 = no take profit)
input bool   InpUseBE           = false;         // Use breakeven (move SL to entry + 1 point)
input double InpBEAt            = 5.0;           // Breakeven starts at this profit, points
input bool   InpUseTrail        = false;         // Use trailing stop
input double InpTrailAt         = 5.0;           // Trailing starts at this profit, points
input double InpTrailDist       = 5.0;           // Trailing: SL stays this far behind price, points

input group "=== 5. Risk and prop firm limits ==="
input double InpRiskPct         = 0.5;           // Risk per trade, % of balance (0.1-5)
input int    InpMaxTrades       = 0;             // Max trades per day, both setups together (0 = no limit)
input bool   InpUsePropRisk     = true;          // Use daily / weekly loss limits (true/false)
input double InpDailyLossPct    = 2.5;           // Max loss per day, % of the day's starting balance
input double InpWeeklyLossPct   = 8.5;           // Max loss per week, % of the week's starting balance
input int    InpPropResetHour   = 0;             // Hour the prop firm's day starts, server time (0-23)

// === V133 START ===
input group "=== 6. Chart ==="
input bool   InpShowLabels      = true;          // Show labels, killzone boxes and arrows on the chart
// === V133 END ===

input group "=== 7. Other ==="
input ulong  InpMagic           = 930001;        // Order ID number (PDH = this, 4H = +1, killzone range = +2)
// === V133 END ===

//--- fixed rules (kept out of the inputs on purpose)
#define MIN_DAY_HOURS   6.0     // daily candles shorter than this (Sunday stubs) are skipped
#define MAX_RANGE_PCT   10.0    // a level range above 10% of price = broken history, skipped
#define BE_LOCK         1.0     // breakeven puts the SL this many points past entry
#define MIN_MODIFY      1.0     // move the SL only when it improves by at least this
// === V133 START ===
// Killzones in New York time, minutes after New York midnight
#define KZ_ASIAN_START  (20 * 60)
#define KZ_ASIAN_END    (24 * 60)
#define KZ_LONDON_START (2 * 60)
#define KZ_LONDON_END   (5 * 60)
#define KZ_NYAM_START   (8 * 60 + 30)
#define KZ_NYAM_END     (11 * 60)
#define TIME_CHECK_SECS 3600    // live time lock: check the broker clock once per hour
#define TIME_TOLERANCE  1800    // live time lock: 30 minutes difference = mismatch
// === V133 END ===

CTrade   trade;
int      g_winStart = 0, g_winEnd = 0, g_dayEnd = 0;
datetime g_day = 0, g_h4 = 0;
double   g_pdh = 0, g_pdl = 0;
bool     g_pdhOk = false, g_pdhDone = false;
int      g_tradesToday = 0;
string   g_status = "";
// === V133 START ===
int      g_nyShift = 0;               // server time minus New York time today, in hours
bool     g_inKZ = false;              // was the last tick inside an enabled killzone?
bool     g_timeBad = false;           // live time lock: broker clock does not match the inputs
datetime g_nextTimeCheck = 0;         // live time lock: next check time
datetime g_propDay = 0;               // start of the current prop firm day
// === V133 END ===

datetime g_week = 0;                              // Monday 00:00 of the current week
double   g_dayStartBal = 0, g_weekStartBal = 0;   // balance at the start of the day / week
double   g_dayLossPct = 0, g_weekLossPct = 0;     // current loss in % (updated every tick)
bool     g_dayBlocked = false, g_weekBlocked = false;   // true = limit reached, no new orders

datetime g_cfLast = 0;                            // end time of the last confirmation candle we checked
bool     g_pdhBuyDone = false, g_pdhSellDone = false;   // each PDH side triggers once a day
double   g_h4Hi = 0, g_h4Lo = 0;                  // levels of the 4H candle that just closed
bool     g_h4Ok = false, g_h4BuyDone = false, g_h4SellDone = false;   // each 4H side triggers once per 4H candle
bool     g_h4Placed = false;                      // V137: 4H stop orders of the current levels already placed

//+------------------------------------------------------------------+
//|  Helpers                                                          |
//+------------------------------------------------------------------+
int ParseHHMM(const string text)
  {
   string s = text;
   string p[];
   StringTrimLeft(s);
   StringTrimRight(s);
   if(StringSplit(s, ':', p) != 2) return -1;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   return (h < 0 || h > 23 || m < 0 || m > 59) ? -1 : h * 60 + m;
  }

datetime DayStart(const datetime t) { return (datetime)((long)t - (long)t % 86400); }
int      MinuteOf(const datetime t) { return (int)(((long)t % 86400) / 60); }
int      Weekday(const datetime t)  { MqlDateTime s; TimeToStruct(t, s); return s.day_of_week; }

// === V133 START ===
//+------------------------------------------------------------------+
//|  New York time (TimingCheck.mq5 contains an exact copy of the    |
//|  3 functions NthSunday, UsSummerTime and ServerMinusNYHours)     |
//+------------------------------------------------------------------+
// The n-th Sunday of a month (n = 1 first, 2 second ...), at 00:00.
datetime NthSunday(const int year, const int month, const int n)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = year;
   s.mon  = month;
   s.day  = 1;
   datetime first = StructToTime(s);
   MqlDateTime f;
   TimeToStruct(first, f);
   return (datetime)((long)first + (long)((7 - f.day_of_week) % 7 + 7 * (n - 1)) * 86400);
  }

// True during US summer time: second Sunday of March to first Sunday of November.
bool UsSummerTime(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return t >= NthSunday(s.year, 3, 2) && t < NthSunday(s.year, 11, 1);
  }

// Hours to subtract from server time to get New York time.
// New York = GMT-5 in winter, GMT-4 in summer. Server = GMT + winter offset (+1 in summer if the broker uses DST).
int ServerMinusNYHours(const datetime t, const int gmtWinter, const bool brokerDST)
  {
   bool summer = UsSummerTime(t);
   int  server = gmtWinter + ((brokerDST && summer) ? 1 : 0);
   int  ny     = summer ? -4 : -5;
   return server - ny;
  }

bool KZUsed() { return InpKZAsian || InpKZLondon || InpKZNYAM; }

// Inside one of the killzones that are switched on? (uses today's cached New York shift - no heavy work)
bool InKillzone(const datetime now)
  {
   int ny = ((MinuteOf(now) - g_nyShift * 60) % 1440 + 1440) % 1440;   // New York minute of the day
   return (InpKZAsian  && ny >= KZ_ASIAN_START  && ny < KZ_ASIAN_END)  ||
          (InpKZLondon && ny >= KZ_LONDON_START && ny < KZ_LONDON_END) ||
          (InpKZNYAM   && ny >= KZ_NYAM_START   && ny < KZ_NYAM_END);
  }

// "HH:MM" of a New York minute converted to server time with the given shift.
string ServerHM(const int nyMinute, const int shift)
  {
   int m = ((nyMinute + shift * 60) % 1440 + 1440) % 1440;
   return StringFormat("%02d:%02d", m / 60, m % 60);
  }

// LIVE ONLY, once at startup and once per hour: does the broker's real GMT offset match the inputs?
// The Strategy Tester has no real clock, so nothing happens there.
void TimeLockCheck(const datetime now)
  {
   if(!KZUsed() || MQLInfoInteger(MQL_TESTER) || now < g_nextTimeCheck) return;
   g_nextTimeCheck = now + TIME_CHECK_SECS;
   long real     = (long)TimeTradeServer() - (long)TimeGMT();
   long expected = (long)(InpBrokerGMTWinter + ((InpBrokerDST && UsSummerTime(now)) ? 1 : 0)) * 3600;
   bool bad      = MathAbs((double)(real - expected)) >= TIME_TOLERANCE;
   if(bad && !g_timeBad)
      PrintFormat("TIME MISMATCH: broker clock is GMT%+.1f, your inputs give GMT%+.1f - no new orders, waiting orders deleted",
                  real / 3600.0, expected / 3600.0);
   if(!bad && g_timeBad) Print("Time OK again - trading continues");
   g_timeBad = bad;
  }

// Start of the prop firm day / week that contains t (the day starts at InpPropResetHour server time).
datetime PropDayStart(const datetime t)
  {
   long h = (long)InpPropResetHour * 3600;
   return (datetime)((long)DayStart((datetime)((long)t - h)) + h);
  }
// === V133 END ===

double Norm(const double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

// Broker minimum distance between price and an order / SL (stops and freeze level).
double BrokerMinDist()
  {
   long lv = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   return (double)(lv + 1) * _Point;
  }

bool Ours(const long magic, const string sym) { return sym == _Symbol && (ulong)magic >= InpMagic && (ulong)magic <= InpMagic + 2; }   // V135: + killzone range

int CountOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OrderGetTicket(i) > 0 && Ours(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) n++;
   return n;
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) n++;
   return n;
  }

// Deletes pending orders: magic 0 = all of ours, otherwise only that magic.
void DeleteOrders(const ulong magic, const string why)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !Ours(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
      if(magic != 0 && (ulong)OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(trade.OrderDelete(t)) PrintFormat("Order #%I64u deleted: %s", t, why);   // V133: shorter log
     }
  }

void CloseAll(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL)) && trade.PositionClose(t))
         PrintFormat("Trade #%I64u closed: %s", t, why);   // V133: shorter log
     }
  }

// Last minute of the broker's trading session on this weekday (1440 if unknown).
int SessionEnd(const int dow)
  {
   datetime from = 0, to = 0;
   long last = -1;
   for(uint i = 0; i < 10 && SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dow, i, from, to); i++)
      last = MathMax(last, (long)to / 60);
   return (last <= 0) ? 1440 : (int)MathMin((long)1440, last);
  }

// === V133 START ===
//+------------------------------------------------------------------+
//|  Chart drawing (never touches an order or a trade)                |
//|  Every object name starts with "NAS_", so your own drawings are   |
//|  never touched. Nothing is drawn during optimisation.             |
//+------------------------------------------------------------------+
#define PFX           "NAS_"
#define LBL_FONT      "Arial"
#define LBL_SIZE      7         // label font size
#define LBL_GAP       12        // minimum pixels between two labels (no overlap)
#define LBL_REFRESH   250       // move the labels at most every 250 ms
#define KEEP_DAYS     5         // killzone boxes and arrows older than this are deleted

int      g_slCount = -1;        // number of this EA's open trades on the last tick (-1 = not known yet)
uint     g_lastLabelMs = 0;     // last time the labels were moved
string   g_kzNow = "";          // name of the killzone we are in now ("" = none)

// === V134 START ===
// Draw only where someone can see it: live charts and Visual mode.
// A normal backtest (no Visual mode) and optimisation draw nothing - this keeps the tester fast.
bool CanDraw()   { return !MQLInfoInteger(MQL_OPTIMIZATION) && (!MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_VISUAL_MODE)); }
// === V134 END ===
bool ShowExtra() { return InpShowLabels && CanDraw(); }

// A horizontal line. Its description is the label text shown at the right edge.
void HLine(const string name, const double price, const color clr, const string text, const int style)
  {
   if(!CanDraw()) return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price)) return;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
   else if(!ObjectMove(0, name, 0, 0, price)) return;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
  }

// Short text with the price, e.g. "PDH 21450.50".
string PriceText(const string what, const double price) { return what + " " + DoubleToString(price, _Digits); }

// One dotted SL line (and, with labels on, a TP line) per open trade. Lines follow breakeven / trailing
// and are deleted when the trade closes. One loop over the open trades per tick.
void DrawTradeLines()
  {
   if(!CanDraw()) return;
   int  n = 0;
   bool created = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      n++;
      bool   buy  = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      string side = buy ? "BUY" : "SELL";
      for(int k = 0; k < 2; k++)                            // k = 0 stop loss, k = 1 take profit
        {
         if(k == 1 && !InpShowLabels) break;                // TP lines only with labels on
         string kind  = (k == 0) ? "SL" : "TP";
         string name  = PFX + kind + "_" + (string)t;
         double price = PositionGetDouble(k == 0 ? POSITION_SL : POSITION_TP);
         if(price <= 0.0)                                   // no SL / TP = no line
           {
            if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
            continue;
           }
         bool exists = ObjectFind(0, name) >= 0;
         if(exists && MathAbs(ObjectGetDouble(0, name, OBJPROP_PRICE) - price) <= _Point / 2.0) continue;   // not moved
         color clr = (k == 0) ? (buy ? clrRed : clrOrange) : (buy ? clrLimeGreen : clrDeepSkyBlue);
         HLine(name, price, clr, StringFormat("%s %s #%I64u %s", kind, side, t, DoubleToString(price, _Digits)), STYLE_DOT);
         if(!exists) created = true;
        }
     }
   if(n != g_slCount || created)                            // a trade closed or opened: remove lines of closed trades
     {
      g_slCount = n;
      for(int k = ObjectsTotal(0, 0, OBJ_HLINE) - 1; k >= 0; k--)
        {
         string name = ObjectName(0, k, 0, OBJ_HLINE);
         if(StringFind(name, PFX + "SL_") != 0 && StringFind(name, PFX + "TP_") != 0) continue;
         if(!PositionSelectByTicket((ulong)StringToInteger(StringSubstr(name, StringLen(PFX) + 3))))
            ObjectDelete(0, name);
        }
     }
  }

// Labels at the right edge of the chart for every EA line, sorted top to bottom and
// pushed apart so they never overlap. Runs at most every 250 ms, only with labels on.
void DrawRightLabels()
  {
   if(!ShowExtra() || GetTickCount() - g_lastLabelMs < LBL_REFRESH) return;
   g_lastLabelMs = GetTickCount();
   string names[];
   int    ys[];
   int    n = 0;
   for(int k = ObjectsTotal(0, 0, OBJ_HLINE) - 1; k >= 0; k--)   // collect our lines and their pixel height
     {
      string line = ObjectName(0, k, 0, OBJ_HLINE);
      if(StringFind(line, PFX) != 0) continue;
      int x = 0, y = 0;
      if(!ChartTimePriceToXY(0, 0, TimeCurrent(), ObjectGetDouble(0, line, OBJPROP_PRICE), x, y)) continue;
      ArrayResize(names, n + 1);
      ArrayResize(ys, n + 1);
      int j = n++;
      while(j > 0 && ys[j - 1] > y) { ys[j] = ys[j - 1]; names[j] = names[j - 1]; j--; }   // keep sorted by height
      ys[j] = y;
      names[j] = line;
     }
   for(int i = 0; i < n; i++)
     {
      int y = (i > 0 && ys[i] < ys[i - 1] + LBL_GAP) ? ys[i - 1] + LBL_GAP : ys[i];   // push down: no overlap
      ys[i] = y;
      string lbl = PFX + "LBL_" + names[i];
      if(ObjectFind(0, lbl) < 0)
        {
         if(!ObjectCreate(0, lbl, OBJ_LABEL, 0, 0, 0)) continue;
         ObjectSetInteger(0, lbl, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
         ObjectSetInteger(0, lbl, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
         ObjectSetInteger(0, lbl, OBJPROP_XDISTANCE, 5);
         ObjectSetInteger(0, lbl, OBJPROP_FONTSIZE, LBL_SIZE);
         ObjectSetString(0, lbl, OBJPROP_FONT, LBL_FONT);
         ObjectSetInteger(0, lbl, OBJPROP_SELECTABLE, false);
        }
      ObjectSetInteger(0, lbl, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, lbl, OBJPROP_COLOR, ObjectGetInteger(0, names[i], OBJPROP_COLOR));
      ObjectSetString(0, lbl, OBJPROP_TEXT, ObjectGetString(0, names[i], OBJPROP_TEXT));
     }
   for(int k = ObjectsTotal(0, 0, OBJ_LABEL) - 1; k >= 0; k--)   // labels whose line is gone
     {
      string lbl = ObjectName(0, k, 0, OBJ_LABEL);
      if(StringFind(lbl, PFX + "LBL_") == 0 && ObjectFind(0, StringSubstr(lbl, StringLen(PFX) + 4)) < 0) ObjectDelete(0, lbl);
     }
  }

// Which enabled killzone are we in now? Returns its name ("" = none) and its New York start / end minute.
string KZNow(const datetime now, int &nyStart, int &nyEnd, color &clr)
  {
   int ny = ((MinuteOf(now) - g_nyShift * 60) % 1440 + 1440) % 1440;
   if(InpKZAsian  && ny >= KZ_ASIAN_START  && ny < KZ_ASIAN_END)  { nyStart = KZ_ASIAN_START;  nyEnd = KZ_ASIAN_END;  clr = C'20,30,70'; return "Asian KZ"; }
   if(InpKZLondon && ny >= KZ_LONDON_START && ny < KZ_LONDON_END) { nyStart = KZ_LONDON_START; nyEnd = KZ_LONDON_END; clr = C'20,60,30'; return "London KZ"; }
   if(InpKZNYAM   && ny >= KZ_NYAM_START   && ny < KZ_NYAM_END)   { nyStart = KZ_NYAM_START;   nyEnd = KZ_NYAM_END;   clr = C'70,35,20'; return "NY AM KZ"; }
   return "";
  }

// === V135 START ===
//+------------------------------------------------------------------+
//|  Killzone range setup                                             |
//|  When a switched-on killzone ends, its highest and lowest price   |
//|  become new levels. Every finished killzone's levels stay active  |
//|  until the day ends, and are traded any time in trading hours.    |
//|  Magic number = InpMagic + 2.                                     |
//+------------------------------------------------------------------+
#define RG_COUNT 3                             // 0 = Asian, 1 = London, 2 = NY AM
string   g_rgKZ = "";                          // killzone we are in now ("" = none)
datetime g_rgT1 = 0, g_rgT2 = 0;               // its start / end, server time
double   g_rgHi[RG_COUNT], g_rgLo[RG_COUNT];   // levels of each finished killzone today
datetime g_rgSet[RG_COUNT];                    // when those levels became valid (= killzone end)
bool     g_rgOk[RG_COUNT], g_rgPlaced[RG_COUNT];
// === V136 START ===
// What happened to each side of each range today (replaces the v1.35 "done" flags, same once-a-day rule).
#define SIDE_LIVE     0         // level active, not triggered yet
#define SIDE_ORDER    1         // triggered, order placed
#define SIDE_TRADED   2         // order filled = traded
#define SIDE_NOORDER  3         // triggered but no order (price already past, risk / margin check)
#define SIDE_CROSSED  4         // V137: price crossed it while the EA could not trade - gone for today
int      g_rgBuyState[RG_COUNT], g_rgSellState[RG_COUNT];
ulong    g_rgBuyTicket[RG_COUNT], g_rgSellTicket[RG_COUNT];   // order of each side (0 = none)
// === V136 END ===

int    RangeIndex(const string kz) { return kz == "Asian KZ" ? 0 : kz == "London KZ" ? 1 : 2; }
string RangeName(const int i)      { return i == 0 ? "Asian KZ" : i == 1 ? "London KZ" : "NY AM KZ"; }
string RangeTag(const int i)       { return i == 0 ? "KZ-AS" : i == 1 ? "KZ-LN" : "KZ-NY"; }
// === V136 START ===
string RangeShort(const int i)     { return i == 0 ? "Asian" : i == 1 ? "London" : "NY AM"; }
bool   RangeOn(const int i)        { return i == 0 ? InpKZAsian : i == 1 ? InpKZLondon : InpKZNYAM; }

// A side of range k was triggered: remember its order (0 = none was placed).
void RangeSide(const int k, const bool buy, const ulong ticket)
  {
   int st = (ticket > 0) ? SIDE_ORDER : SIDE_NOORDER;
   if(buy) { g_rgBuyState[k]  = st; g_rgBuyTicket[k]  = ticket; }
   else    { g_rgSellState[k] = st; g_rgSellTicket[k] = ticket; }
  }

// Fill of one of our orders: if it belongs to a killzone range, mark that side traded. Returns the range (-1 = none).
int RangeFilled(const ulong order)
  {
   for(int k = 0; k < RG_COUNT; k++)
     {
      if(order > 0 && order == g_rgBuyTicket[k])  { g_rgBuyState[k]  = SIDE_TRADED; return k; }
      if(order > 0 && order == g_rgSellTicket[k]) { g_rgSellState[k] = SIDE_TRADED; return k; }
     }
   return -1;
  }
// === V136 END ===

// New day: all killzone ranges are finished.
void ClearKZRanges()
  {
   for(int i = 0; i < RG_COUNT; i++)
     {
      g_rgOk[i] = false;
      g_rgBuyState[i] = g_rgSellState[i] = SIDE_LIVE;      // V136
      g_rgBuyTicket[i] = g_rgSellTicket[i] = 0;
      if(CanDraw()) { ObjectDelete(0, PFX + "KZH" + (string)i); ObjectDelete(0, PFX + "KZL" + (string)i); }
     }
  }

// A killzone finished: its high / low from finished 1-minute candles become levels until the day ends.
void SetKZRange(const string name, const datetime t1, const datetime t2)
  {
   int k = RangeIndex(name);
   g_rgOk[k] = false;
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, t1, t2 - 1, r);
   if(n <= 0) { PrintFormat("[KZ] %s: no price data - no range", name); return; }
   double hi = r[0].high, lo = r[0].low;
   for(int i = 1; i < n; i++) { hi = MathMax(hi, r[i].high); lo = MathMin(lo, r[i].low); }
   if(!LevelsSane(hi, lo)) { PrintFormat("[KZ] %s range %.2f / %.2f looks broken - skipped", name, hi, lo); return; }
   g_rgHi[k] = hi; g_rgLo[k] = lo; g_rgSet[k] = t2;
   g_rgOk[k] = true; g_rgPlaced[k] = false;
   g_rgBuyState[k] = g_rgSellState[k] = SIDE_LIVE;          // V136
   g_rgBuyTicket[k] = g_rgSellTicket[k] = 0;
   PrintFormat("[KZ] %s finished: high %.*f, low %.*f (traded until the day ends)", name, _Digits, hi, _Digits, lo);
   HLine(PFX + "KZH" + (string)k, hi, clrGold,   PriceText(RangeShort(k) + " High", hi), STYLE_DASH);   // V136: "London High"
   HLine(PFX + "KZL" + (string)k, lo, clrViolet, PriceText(RangeShort(k) + " Low", lo),  STYLE_DASH);
  }

// Every tick (cheap): notice when a killzone starts and when it ends.
void KZRangeUpdate(const datetime now)
  {
   int a = 0, b = 0;
   color c = clrNONE;
   string kz = KZNow(now, a, b, c);
   if(kz == g_rgKZ) return;                                 // same killzone, or still outside
   if(g_rgKZ != "" && g_rgT1 >= g_day)                      // the previous killzone just ended
      SetKZRange(g_rgKZ, g_rgT1, g_rgT2);                   // V136: never one from an earlier day (market stopped inside it)
   g_rgKZ = kz;
   if(kz != "")                                             // a killzone just started: remember its times
     {
      int ny = ((MinuteOf(now) - g_nyShift * 60) % 1440 + 1440) % 1440;
      g_rgT1 = (datetime)((long)now - (long)(ny - a) * 60 - (long)now % 60);
      g_rgT2 = (datetime)((long)g_rgT1 + (long)(b - a) * 60);
     }
  }

// Stop-order mode: place the stop orders of each new range once. (Confirmation mode uses ConfirmCheck.)
void KZRangeOrders()
  {
   for(int k = 0; k < RG_COUNT; k++)
     {
      if(!g_rgOk[k] || g_rgPlaced[k]) continue;
      g_rgPlaced[k] = true;
      if(InpUseConfirm)
         PrintFormat("[%s] waiting for a %d-min close above %.*f or below %.*f", RangeTag(k), InpConfirmMinutes, _Digits, g_rgHi[k], _Digits, g_rgLo[k]);
      else                                                  // V136: one stop order per side, tickets remembered
        {
         if(g_rgBuyState[k] == SIDE_LIVE)  RangeSide(k, true,  PlaceStop(true,  Norm(g_rgHi[k]), InpMagic + 2, RangeTag(k)));   // V137: only sides
         if(g_rgSellState[k] == SIDE_LIVE) RangeSide(k, false, PlaceStop(false, Norm(g_rgLo[k]), InpMagic + 2, RangeTag(k)));   // not crossed yet
        }
     }
  }

// Names of today's active ranges, for the chart text.
string KZRangeText()
  {
   string t = "";
   for(int k = 0; k < RG_COUNT; k++) if(g_rgOk[k]) t += (t == "" ? "" : ", ") + RangeName(k);
   return t == "" ? "waiting" : t;
  }

// === V136 START ===
// One side for the chart text: "live", "order waiting", "TRADED", ...
string SideText(const int st, const ulong ticket)
  {
   if(st == SIDE_TRADED)  return "TRADED";
   if(st == SIDE_NOORDER) return "used, no order";
   if(st == SIDE_CROSSED) return "crossed, gone";        // V137
   if(st == SIDE_ORDER)   return OrderSelect(ticket) ? "order waiting" : "order removed";
   return "live";
  }

// One chart-text line per switched-on killzone: its high / low and what each side did today.
string KZRangeLines()
  {
   string t = "";
   for(int k = 0; k < RG_COUNT; k++)
     {
      if(!RangeOn(k)) continue;
      if(!g_rgOk[k]) { t += StringFormat("\n  %s: waiting (killzone not finished)", RangeShort(k)); continue; }
      t += StringFormat("\n  %s: High %s BUY %s | Low %s SELL %s", RangeShort(k),
                        DoubleToString(g_rgHi[k], _Digits), SideText(g_rgBuyState[k], g_rgBuyTicket[k]),
                        DoubleToString(g_rgLo[k], _Digits), SideText(g_rgSellState[k], g_rgSellTicket[k]));
     }
   return t;
  }
// === V136 END ===
// === V135 END ===

// When a killzone starts: a shaded box behind the candles for the whole killzone, with its name.
void DrawKillzone(const datetime now)
  {
   if(!CanDraw()) return;
   int a = 0, b = 0;
   color clr = clrNONE;
   string kz = KZUsed() ? KZNow(now, a, b, clr) : "";
   if(kz == g_kzNow) return;                                // only when the killzone changes
   g_kzNow = kz;
   if(kz == "" || !ShowExtra()) return;
   int ny = ((MinuteOf(now) - g_nyShift * 60) % 1440 + 1440) % 1440;
   datetime t1 = (datetime)((long)now - (long)(ny - a) * 60 - (long)now % 60);   // killzone start
   datetime t2 = (datetime)((long)t1 + (long)(b - a) * 60);                   // killzone end
   string box = PFX + "KZ_" + (string)(long)t1;
   double top = SymbolInfoDouble(_Symbol, SYMBOL_BID) * 2.0;                 // tall enough to fill the chart
   if(ObjectFind(0, box) < 0 && ObjectCreate(0, box, OBJ_RECTANGLE, 0, t1, 0.0, t2, top))
     {
      ObjectSetInteger(0, box, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, box, OBJPROP_FILL, true);
      ObjectSetInteger(0, box, OBJPROP_BACK, true);         // behind the candles
      ObjectSetInteger(0, box, OBJPROP_SELECTABLE, false);
     }
   string txt = PFX + "KZT_" + (string)(long)t1;
   double y = ChartGetDouble(0, CHART_PRICE_MAX);           // name at the top of the visible chart
   if(y <= 0.0) y = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ObjectFind(0, txt) < 0 && ObjectCreate(0, txt, OBJ_TEXT, 0, t1, y))
     {
      ObjectSetString(0, txt, OBJPROP_TEXT, kz);
      ObjectSetString(0, txt, OBJPROP_FONT, LBL_FONT);
      ObjectSetInteger(0, txt, OBJPROP_FONTSIZE, LBL_SIZE);
      ObjectSetInteger(0, txt, OBJPROP_COLOR, clrSilver);
      ObjectSetInteger(0, txt, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, txt, OBJPROP_SELECTABLE, false);
     }
  }

// A small arrow and "Confirmed BUY / SELL" where a candle-close confirmation happened.
void DrawConfirm(const bool buy, const double level, const string tag)
  {
   if(!ShowExtra()) return;
   datetime t = TimeCurrent();
   string id  = (string)(long)t + "_" + tag + (buy ? "B" : "S");
   string arw = PFX + "CF_" + id, txt = PFX + "CFT_" + id;
   color  clr = buy ? clrDeepSkyBlue : clrOrangeRed;
   if(ObjectCreate(0, arw, buy ? OBJ_ARROW_UP : OBJ_ARROW_DOWN, 0, t, level))
     {
      ObjectSetInteger(0, arw, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, arw, OBJPROP_ANCHOR, buy ? ANCHOR_TOP : ANCHOR_BOTTOM);
      ObjectSetInteger(0, arw, OBJPROP_SELECTABLE, false);
     }
   if(ObjectCreate(0, txt, OBJ_TEXT, 0, t, level))
     {
      ObjectSetString(0, txt, OBJPROP_TEXT, buy ? "Confirmed BUY" : "Confirmed SELL");
      ObjectSetString(0, txt, OBJPROP_FONT, LBL_FONT);
      ObjectSetInteger(0, txt, OBJPROP_FONTSIZE, LBL_SIZE);
      ObjectSetInteger(0, txt, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, txt, OBJPROP_ANCHOR, buy ? ANCHOR_LEFT_UPPER : ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, txt, OBJPROP_SELECTABLE, false);
     }
  }

// Once a day: delete killzone boxes and arrows older than 5 days, so the chart does not fill up.
void DeleteOldDrawings(const datetime now)
  {
   if(!CanDraw()) return;
   datetime limit = (datetime)((long)now - KEEP_DAYS * 86400);
   for(int k = ObjectsTotal(0) - 1; k >= 0; k--)
     {
      string name = ObjectName(0, k);
      if(StringFind(name, PFX + "KZ") != 0 && StringFind(name, PFX + "CF") != 0) continue;
      if((datetime)ObjectGetInteger(0, name, OBJPROP_TIME, 0) < limit) ObjectDelete(0, name);
     }
  }

// Chart text, top-left corner: one item per line.
void ShowChartText()
  {
   if(!CanDraw()) return;
   // === V134 START ===
   static datetime last = 0;                                // update the text once per second, not on every tick
   if(TimeCurrent() == last) return;
   last = TimeCurrent();
   // === V134 END ===
   string kz   = !KZUsed() ? "off" : (g_kzNow != "" ? g_kzNow + " (now)" : "outside killzones");
   string text = StringFormat("NAS Breakout | %s", _Symbol) +
                 StringFormat("\nSetups: PDH %s | 4H %s | KZ range %s", InpUsePDH ? "on" : "off", InpUseH4 ? "on" : "off",
                              InpUseKZRange ? KZRangeText() : "off") +   // V135
                 StringFormat("\nKillzone: %s", kz) +
                 StringFormat("\nPDH / 4H killzone filter (InpKZFilterPDH4H): %s", InpKZFilterPDH4H ? "ON - only inside killzones" : "OFF - all trading hours") +   // V136
                 (InpUseKZRange ? "\nKillzone ranges:" + KZRangeLines() : "") +                                                // V136
                 StringFormat("\nPDH: BUY %s | SELL %s    4H: BUY %s | SELL %s", g_pdhBuyDone ? "used" : "live", g_pdhSellDone ? "used" : "live",
                              g_h4BuyDone ? "used" : "live", g_h4SellDone ? "used" : "live") +   // V137 (used = traded or crossed)
                 StringFormat("\nCrossed level = gone for the day (InpLevelOnce): %s", InpLevelOnce ? "ON" : "OFF") +                  // V137
                 StringFormat("\nTrades today: %d | open now: %d", g_tradesToday, CountPositions());
   if(InpUsePropRisk)
      text += StringFormat("\nDaily loss %.1f%% / %.1f%% | Weekly %.1f%% / %.1f%%",
                           MathMax(0.0, g_dayLossPct), InpDailyLossPct, MathMax(0.0, g_weekLossPct), InpWeeklyLossPct);
   if(g_timeBad)          text += "\n!! TIME MISMATCH - check InpBrokerGMTWinter / InpBrokerDST";
   else if(PropBlocked()) text += "\n!! LOSS LIMIT REACHED - no new orders";
   text += "\nStatus: " + g_status;
   Comment(text);
  }
// === V133 END ===

// True when hi/lo look like real prices (protects against broken history).
bool LevelsSane(const double hi, const double lo)
  {
   return lo > 0.0 && hi > lo && (hi - lo) <= hi * MAX_RANGE_PCT / 100.0;
  }

//+------------------------------------------------------------------+
//|  Prop firm daily / weekly loss limits                             |
//+------------------------------------------------------------------+
// Monday 00:00 (server time) of the week that contains t.
datetime WeekStart(const datetime t) { return (datetime)((long)DayStart(t) - (long)((Weekday(t) + 6) % 7) * 86400); }

// Money made or lost by all trades closed since 'from' (profit + swap + commission + fee).
// Deposits and withdrawals are not trades, so they are not counted.
double TradeResultSince(const datetime from)
  {
   double sum = 0.0;
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      sum += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
             HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
     }
   return sum;
  }

// Starting balances = balance now minus everything traded since the start of the day / week.
// Runs only at startup and when a new prop day begins (the deal history is never read on every tick).
void PropStartBalances(const datetime today)
  {
   if(!InpUsePropRisk) return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayStartBal = bal - TradeResultSince(today);
   g_dayBlocked  = false;                                   // a new day starts unblocked
   // === V133 START ===
   long h = (long)InpPropResetHour * 3600;                  // the week starts on Monday at the reset hour
   datetime week = (datetime)((long)WeekStart((datetime)((long)today - h)) + h);
   // === V133 END ===
   if(week != g_week)                                       // a new week (or the EA just started)
     {
      g_week = week;
      g_weekStartBal = bal - TradeResultSince(week);
      g_weekBlocked  = false;
     }
   // === V133 START ===
   PrintFormat("Prop: day start %.2f (max loss %.2f) | week start %.2f (max loss %.2f)",
               g_dayStartBal, g_dayStartBal * InpDailyLossPct / 100.0, g_weekStartBal, g_weekStartBal * InpWeeklyLossPct / 100.0);
   // === V133 END ===
  }

bool PropBlocked() { return InpUsePropRisk && (g_dayBlocked || g_weekBlocked); }

// Every tick: compare equity with the starting balances. Limit reached = close everything and stop.
void PropCheckEquity()
  {
   if(!InpUsePropRisk || g_dayStartBal <= 0.0 || g_weekStartBal <= 0.0) return;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);           // includes trades that are still open
   g_dayLossPct  = (g_dayStartBal  - eq) / g_dayStartBal  * 100.0;
   g_weekLossPct = (g_weekStartBal - eq) / g_weekStartBal * 100.0;
   if(!g_dayBlocked && g_dayLossPct >= InpDailyLossPct)
     {
      g_dayBlocked = true;
      PrintFormat("DAILY LOSS LIMIT REACHED (%.2f%%, limit %.2f%%) - EA trades closed, no new orders until the next day",
                  g_dayLossPct, InpDailyLossPct);   // V133: shorter log
     }
   if(!g_weekBlocked && g_weekLossPct >= InpWeeklyLossPct)
     {
      g_weekBlocked = true;
      PrintFormat("WEEKLY LOSS LIMIT REACHED (%.2f%%, limit %.2f%%) - EA trades closed, no new orders until Monday",
                  g_weekLossPct, InpWeeklyLossPct);   // V133: shorter log
     }
   if(PropBlocked() && (CountOrders() > 0 || CountPositions() > 0))
     {
      DeleteOrders(0, "loss limit reached");                // waiting orders first, so none can fill
      CloseAll("loss limit reached");
     }
  }

// Money lost if a trade of 'vol' lots goes from price 'from' to its stop loss 'sl' (0 if that is not a loss).
double LossToSL(const bool buy, const double vol, const double from, const double sl)
  {
   double p = 0.0;
   if(sl <= 0.0 || !OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, vol, from, sl, p)) return 0.0;
   return (p < 0.0) ? -p : 0.0;
  }

// Before a new order: if it AND all of this EA's open trades and waiting orders hit their
// stop losses, would the daily or weekly limit be broken? Then the order is not placed.
bool PropOrderAllowed(const bool buy, const double entry, const double sl, const double lot, const string tag)
  {
   if(!InpUsePropRisk) return true;
   if(PropBlocked()) { PrintFormat("[%s] skipped: loss limit reached", tag); return false; }   // V133: shorter log
   double risk = LossToSL(buy, lot, entry, sl);             // the new order
   for(int i = PositionsTotal() - 1; i >= 0; i--)           // open trades: from the current price to their SL
      if(PositionGetTicket(i) > 0 && Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL)))
         risk += LossToSL(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY, PositionGetDouble(POSITION_VOLUME),
                          PositionGetDouble(POSITION_PRICE_CURRENT), PositionGetDouble(POSITION_SL));
   for(int i = OrdersTotal() - 1; i >= 0; i--)              // waiting orders: from their entry to their SL
      if(OrderGetTicket(i) > 0 && Ours(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL)))
        {
         long ot = OrderGetInteger(ORDER_TYPE);
         bool b = (ot == ORDER_TYPE_BUY_STOP || ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_BUY_STOP_LIMIT);
         risk += LossToSL(b, OrderGetDouble(ORDER_VOLUME_CURRENT), OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL));
        }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayRoom  = g_dayStartBal  * InpDailyLossPct  / 100.0 - (g_dayStartBal  - eq);   // money left before the daily limit
   double weekRoom = g_weekStartBal * InpWeeklyLossPct / 100.0 - (g_weekStartBal - eq);   // money left before the weekly limit
   if(risk > dayRoom || risk > weekRoom)
     {
      PrintFormat("[%s] %s skipped: could lose %.2f if all SLs hit, only %.2f (day) / %.2f (week) left",
                  tag, buy ? "BUY" : "SELL", risk, dayRoom, weekRoom);   // V133: shorter log
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  Orders                                                          |
//+------------------------------------------------------------------+
// Lot for InpRiskPct % risk between entry and sl, reduced if margin is short. 0 = skip.
double LotSize(const bool buy, const double entry, const double sl)
  {
   double loss = 0.0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, loss) || loss == 0.0) return 0.0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0) step = vmin;
   double lots = MathFloor(AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0 / MathAbs(loss) / step + 1e-9) * step;
   lots = MathMin(lots, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));

   double margin = 0.0;
   if(OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, margin) && margin > 0.0)
     {
      double maxLots = MathFloor(AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9 / margin / step + 1e-9) * step;
      if(lots > maxLots) { PrintFormat("Lot reduced %.2f -> %.2f (not enough margin)", lots, maxLots); lots = maxLots; }
     }
   if(lots < vmin) { PrintFormat("Skipped: lot %.4f is below the broker minimum %.2f", lots, vmin); return 0.0; }   // V133: shorter log
   return NormalizeDouble(lots, (int)MathMax(0.0, MathRound(-MathLog10(step))));
  }

// === V133 START ===
// Shared by all 3 order types: stop loss, take profit, lot size and the prop check.
// False = do not place the order (the reason is printed).
bool OrderPlan(const bool buy, const double entry, const string tag, double &sl, double &tp, double &lot)
  {
   double gap = BrokerMinDist();
   if(InpSL <= gap) { PrintFormat("[%s] SL %g is smaller than the broker minimum %.2f", tag, InpSL, gap); return false; }
   sl = Norm(buy ? entry - InpSL : entry + InpSL);
   double tpDist = (InpUseTP && InpFixedTP > 0.0) ? InpFixedTP : InpSL * InpRR;   // fixed TP wins over the ratio
   tp = (tpDist > 0.0) ? Norm(buy ? entry + tpDist : entry - tpDist) : 0.0;
   if(sl <= 0.0) return false;
   lot = LotSize(buy, entry, sl);
   if(lot <= 0.0) return false;
   return PropOrderAllowed(buy, entry, sl, lot, tag);
  }

// Log the result of an order request.
void LogOrder(const bool ok, const string tag, const string what, const double lot, const double entry, const double sl, const double tp)
  {
   if(ok) PrintFormat("[%s] %s %.2f lots @ %.*f  SL %.*f  TP %s", tag, what, lot, _Digits, entry, _Digits, sl,
                      tp > 0.0 ? DoubleToString(tp, _Digits) : "none");
   else   PrintFormat("[%s] %s rejected: %s", tag, what, trade.ResultRetcodeDescription());
  }
// === V133 END ===

// One stop order at 'entry'. tag = "PDH" or "H4". V136: returns the order ticket (0 = no order).
ulong PlaceStop(const bool buy, const double entry, const ulong magic, const string tag)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = BrokerMinDist();
   string side = buy ? "BUY" : "SELL";
   if(buy ? ask >= entry - gap : bid <= entry + gap)
     {
      PrintFormat("[%s] %s skipped: price already past %.*f", tag, side, _Digits, entry);
      return 0;
     }
   double sl = 0.0, tp = 0.0, lot = 0.0;
   if(!OrderPlan(buy, entry, tag, sl, tp, lot)) return 0;   // V133: shared calculation
   trade.SetExpertMagicNumber(magic);
   bool ok = buy ? trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag)
                 : trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag);
   LogOrder(ok, tag, side + " STOP", lot, entry, sl, tp);
   if(!ok) return 0;                                        // V136: the order ticket
   return trade.ResultOrder();
  }

//+------------------------------------------------------------------+
//|  Candle close confirmation                                        |
//+------------------------------------------------------------------+
// One LIMIT order exactly at 'entry', placed after a confirmed candle close.
// Stop loss, take profit and lot size are calculated exactly like PlaceStop, so the risk is identical.
ulong PlaceLimit(const bool buy, const double entry, const ulong magic, const string tag)   // V136: returns the ticket
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = BrokerMinDist();
   string side = buy ? "BUY" : "SELL";
   if(buy ? ask <= entry + gap : bid >= entry - gap)          // a limit order must wait on the far side of price
     {
      PrintFormat("[%s] %s LIMIT skipped: price already back at %.*f", tag, side, _Digits, entry);
      return 0;
     }
   double sl = 0.0, tp = 0.0, lot = 0.0;
   if(!OrderPlan(buy, entry, tag, sl, tp, lot)) return 0;   // V133: shared calculation
   trade.SetExpertMagicNumber(magic);
   bool ok = buy ? trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag)
                 : trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag);
   LogOrder(ok, tag, side + " LIMIT", lot, entry, sl, tp);
   if(!ok) return 0;                                        // V136: the order ticket
   return trade.ResultOrder();
  }

// Enter immediately at the current market price (BUY at Ask, SELL at Bid).
// Stop loss and take profit are the same DISTANCE as always, measured from the real entry price,
// and the lot size uses the same risk %, so the risk per trade stays identical.
ulong PlaceMarket(const bool buy, const ulong magic, const string tag)   // V136: returns the ticket
  {
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp = 0.0, lot = 0.0;
   if(!OrderPlan(buy, entry, tag, sl, tp, lot)) return 0;   // V133: shared calculation
   trade.SetExpertMagicNumber(magic);
   bool ok = buy ? trade.Buy(lot, _Symbol, 0.0, sl, tp, tag)
                 : trade.Sell(lot, _Symbol, 0.0, sl, tp, tag);
   LogOrder(ok, tag, buy ? "BUY at market" : "SELL at market", lot, entry, sl, tp);
   if(!ok) return 0;                                        // V136: the order ticket
   return trade.ResultOrder();
  }

// Start time of the confirmation candle that contains time t (candles are counted from server midnight;
// the last candle of the day is shorter if the minutes do not divide 24 hours evenly).
datetime CandleStart(const datetime t)
  {
   long len = (long)InpConfirmMinutes * 60;
   long day = (long)DayStart(t);
   return (datetime)(day + ((long)t - day) / len * len);
  }

// A side is confirmed: log it and place the limit order back at the level. V136: returns the ticket (0 = no order).
ulong Confirmed(const bool buy, const double level, const double close, const ulong magic, const string tag)
  {
   PrintFormat("[%s] %s confirmed: %d-min candle closed %.*f, %s %.*f", tag, buy ? "BUY" : "SELL",
               InpConfirmMinutes, _Digits, close, buy ? "above" : "below", _Digits, level);   // V133: shorter log
   DrawConfirm(buy, level, tag);                            // V133: arrow + "Confirmed BUY / SELL"
   if(InpEnterAtClose) return PlaceMarket(buy, magic, tag);  // enter now at market price
   return PlaceLimit(buy, Norm(level), magic, tag);
  }

// A new 4H candle opened: remember the levels of the one that just closed, both sides ready again.
void ConfirmNewH4(const double hi, const double lo)
  {
   g_h4Hi = hi;
   g_h4Lo = lo;
   g_h4BuyDone = g_h4SellDone = false;
   g_h4Ok = LevelsSane(hi, lo);
   if(!g_h4Ok) PrintFormat("[H4] levels %.2f / %.2f look broken - skipped", hi, lo);
  }

// === V137 START ===
// Price crossed a level while the EA could not trade it: that level is gone (no order, now or later).
void LevelGone(const string tag, const bool buy, const double level)
  {
   PrintFormat("[%s] %s level %.*f crossed while trading was not allowed - gone for today", tag, buy ? "BUY" : "SELL", _Digits, level);
  }
// === V137 END ===

// Called every tick, but does real work only once per confirmation candle, right after it has finished.
// Uses only finished 1-minute candles - never the one still forming.
// V137: called on EVERY tick (also outside trading hours, killzones or limits). tradePdhH4 / tradeKZ = may
// those setups place an order now? A cross when they may not = that level is gone (InpLevelOnce = true).
void ConfirmCheck(const bool tradePdhH4, const bool tradeKZ)
  {
   datetime end = CandleStart(TimeCurrent());               // the finished candle ends where the current one starts
   if(end == g_cfLast) return;                              // this candle was already checked
   g_cfLast = end;
   datetime start = CandleStart(end - 1);                   // start of the finished candle
   MqlRates c[], p[];
   // close of the finished candle = close of its last 1-minute candle
   if(CopyRates(_Symbol, PERIOD_M1, end - 1, 1, c) != 1 || c[0].time < start) return;   // no prices in it (market closed)
   // close of the candle before it = close of the last 1-minute candle before it started
   if(CopyRates(_Symbol, PERIOD_M1, start - 1, 1, p) != 1) return;
   double close = c[0].close, prev = p[0].close;

   bool pdhH4 = tradePdhH4 || InpLevelOnce;                 // V137: also watch the levels when we may not trade
   bool kz    = tradeKZ    || InpLevelOnce;

   // PDH / PDL: only candles that finished today, each side once a day
   if(pdhH4 && InpUsePDH && g_pdhOk && end > g_day)
     {
      if(!g_pdhBuyDone && close > g_pdh && prev <= g_pdh)
        { g_pdhBuyDone  = true; if(tradePdhH4) Confirmed(true,  g_pdh, close, InpMagic, "PDH"); else LevelGone("PDH", true,  g_pdh); }
      if(!g_pdhSellDone && close < g_pdl && prev >= g_pdl)
        { g_pdhSellDone = true; if(tradePdhH4) Confirmed(false, g_pdl, close, InpMagic, "PDH"); else LevelGone("PDH", false, g_pdl); }
     }
   // 4H: only candles that finished after the current 4H candle opened, each side once per 4H candle
   if(pdhH4 && InpUseH4 && g_h4Ok && end > g_h4)
     {
      if(!g_h4BuyDone && close > g_h4Hi && prev <= g_h4Hi)
        { g_h4BuyDone  = true; if(tradePdhH4) Confirmed(true,  g_h4Hi, close, InpMagic + 1, "H4"); else LevelGone("H4", true,  g_h4Hi); }
      if(!g_h4SellDone && close < g_h4Lo && prev >= g_h4Lo)
        { g_h4SellDone = true; if(tradePdhH4) Confirmed(false, g_h4Lo, close, InpMagic + 1, "H4"); else LevelGone("H4", false, g_h4Lo); }
     }
   // === V135 START ===
   // Killzone ranges: only candles that finished after the range was set, each side once per range per day
   if(kz && InpUseKZRange)
      for(int k = 0; k < RG_COUNT; k++)
        {
         if(!g_rgOk[k] || end <= g_rgSet[k]) continue;
         if(g_rgBuyState[k] == SIDE_LIVE && close > g_rgHi[k] && prev <= g_rgHi[k])     // V136: ticket remembered
           {
            if(tradeKZ) RangeSide(k, true, Confirmed(true, g_rgHi[k], close, InpMagic + 2, RangeTag(k)));
            else      { g_rgBuyState[k] = SIDE_CROSSED; LevelGone(RangeTag(k), true, g_rgHi[k]); }   // V137
           }
         if(g_rgSellState[k] == SIDE_LIVE && close < g_rgLo[k] && prev >= g_rgLo[k])
           {
            if(tradeKZ) RangeSide(k, false, Confirmed(false, g_rgLo[k], close, InpMagic + 2, RangeTag(k)));
            else      { g_rgSellState[k] = SIDE_CROSSED; LevelGone(RangeTag(k), false, g_rgLo[k]); }   // V137
           }
        }
   // === V135 END ===
  }

// === V137 START ===
// Stop-order mode (confirmation off), every tick: a level price has reached is gone. If our stop order
// was waiting there it filled (that is our trade); if not, the level is never traded later today.
void MarkCrossedStops()
  {
   if(InpUseConfirm || !InpLevelOnce) return;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;
   if(InpUsePDH && g_pdhOk)
     {
      if(!g_pdhBuyDone  && ask >= g_pdh) g_pdhBuyDone  = true;
      if(!g_pdhSellDone && bid <= g_pdl) g_pdhSellDone = true;
     }
   if(InpUseH4 && g_h4Ok)
     {
      if(!g_h4BuyDone  && ask >= g_h4Hi) g_h4BuyDone  = true;
      if(!g_h4SellDone && bid <= g_h4Lo) g_h4SellDone = true;
     }
   if(InpUseKZRange)
      for(int k = 0; k < RG_COUNT; k++)
        {
         if(!g_rgOk[k]) continue;
         if(g_rgBuyState[k]  == SIDE_LIVE && ask >= g_rgHi[k]) g_rgBuyState[k]  = SIDE_CROSSED;   // no order was waiting
         if(g_rgSellState[k] == SIDE_LIVE && bid <= g_rgLo[k]) g_rgSellState[k] = SIDE_CROSSED;
        }
  }

// Stop-order mode: the stop orders of one level pair, skipping sides that are already gone.
void StraddleLive(const double hi, const double lo, const bool buyGone, const bool sellGone, const ulong magic, const string tag)
  {
   if(!LevelsSane(hi, lo)) { PrintFormat("[%s] levels %.2f / %.2f look broken - skipped", tag, hi, lo); return; }
   if(buyGone && sellGone) { PrintFormat("[%s] both levels already crossed today - no orders", tag); return; }
   if(!buyGone)  PlaceStop(true,  Norm(hi), magic, tag);
   if(!sellGone) PlaceStop(false, Norm(lo), magic, tag);
  }

// Every tick: a new 4H candle = new 4H levels (also while no orders are allowed, so a cross
// during that time is seen). The old 4H orders still waiting are deleted.
void UpdateH4Levels()
  {
   if(!InpUseH4) return;
   datetime h4 = iTime(_Symbol, PERIOD_H4, 0);
   if(h4 <= 0 || h4 == g_h4) return;
   g_h4 = h4;
   DeleteOrders(InpMagic + 1, "new 4H candle - old 4H order replaced");
   g_h4Ok = false;                                          // old 4H levels are finished
   g_h4Placed = false;
   double hi = iHigh(_Symbol, PERIOD_H4, 1), lo = iLow(_Symbol, PERIOD_H4, 1);
   if(hi <= 0.0 || lo <= 0.0) return;
   HLine(PFX + "H4H", hi, clrLime, PriceText("4H High", hi), STYLE_DASH);
   HLine(PFX + "H4L", lo, clrMagenta, PriceText("4H Low", lo), STYLE_DASH);
   ConfirmNewH4(hi, lo);                                    // levels + both sides ready again
  }
// === V137 END ===

//+------------------------------------------------------------------+
//|  Daily levels                                                    |
//+------------------------------------------------------------------+
// Yesterday's daily candle (short Sunday candles skipped). False if none.
bool PrevDay(const datetime today, double &hi, double &lo)
  {
   MqlRates d[];
   int n = CopyRates(_Symbol, PERIOD_D1, 0, 6, d);
   for(int i = n - 1; i >= 0; i--)
     {
      if(d[i].time >= today) continue;
      MqlRates m[];
      int k = CopyRates(_Symbol, PERIOD_M1, d[i].time, d[i].time + 86399, m);
      double hours = (k > 0) ? (double)(m[k - 1].time - m[0].time + 60) / 3600.0 : (Weekday(d[i].time) == 0 ? 0.0 : 24.0);
      if(hours < MIN_DAY_HOURS) continue;                  // Sunday stub
      hi = d[i].high;
      lo = d[i].low;
      return true;
     }
   return false;
  }

void NewDay(const datetime today)
  {
   // Safety net: if the market stopped before the day-end time there was no tick to clean up,
   // so yesterday's orders / trades are removed here (otherwise they pile up day after day).
   if(g_day != 0 && (CountOrders() > 0 || CountPositions() > 0))
     {
      PrintFormat("Removing %d order(s) and %d trade(s) left from %s", CountOrders(), CountPositions(), TimeToString(g_day, TIME_DATE));   // V133: shorter log
      DeleteOrders(0, "left from yesterday");
      CloseAll("left from yesterday");
     }
   g_day = today;
   g_pdhDone = false;
   g_tradesToday = 0;
   g_dayEnd = (int)MathMin(g_winEnd, SessionEnd(Weekday(today)) - 5);
   g_pdhOk = PrevDay(today, g_pdh, g_pdl) && LevelsSane(g_pdh, g_pdl);
   if(g_pdhOk)
     {
      PrintFormat("=== %s | PDH %.*f | PDL %.*f | closes %02d:%02d", TimeToString(today, TIME_DATE),
                  _Digits, g_pdh, _Digits, g_pdl, g_dayEnd / 60, g_dayEnd % 60);   // V133: shorter log
      HLine(PFX + "PDH", g_pdh, clrDodgerBlue, PriceText("PDH", g_pdh), STYLE_DASH);   // V133: NAS_ names + label text
      HLine(PFX + "PDL", g_pdl, clrOrangeRed, PriceText("PDL", g_pdl), STYLE_DASH);
     }
   else PrintFormat("=== %s | no PDH/PDL today (holiday or missing history)", TimeToString(today, TIME_DATE));   // V133: shorter log
   g_pdhBuyDone = g_pdhSellDone = false;                    // both PDH sides can trigger again today
   // === V133 START ===
   g_nyShift = ServerMinusNYHours(today, InpBrokerGMTWinter, InpBrokerDST);   // server - New York, for today
   DeleteOldDrawings(today);                                // killzone boxes / arrows older than 5 days
   ClearKZRanges();                                         // V135: killzone ranges last until the day ends
   // (the prop starting balances are now read in OnTick when a new prop day starts)
   // === V133 END ===
  }

//+------------------------------------------------------------------+
//|  Breakeven and trailing                                           |
//+------------------------------------------------------------------+
void ManageStops()
  {
   bool be = InpUseBE, trail = InpUseTrail;                 // V133: start-up already checks the values are > 0
   if(!be && !trail) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double gap = BrokerMinDist();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      bool   buy    = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double px     = buy ? bid : ask;
      double profit = buy ? bid - open : open - ask;
      double target = sl;
      if(be && profit >= InpBEAt)
         target = buy ? MathMax(target, open + BE_LOCK) : (target == 0.0 ? open - BE_LOCK : MathMin(target, open - BE_LOCK));
      if(trail && profit >= InpTrailAt)
         target = buy ? MathMax(target, px - InpTrailDist) : (target == 0.0 ? px + InpTrailDist : MathMin(target, px + InpTrailDist));
      if(buy)  target = MathMin(target, px - gap);           // broker minimum distance
      else     target = MathMax(target, px + gap);
      target = Norm(target);
      if(sl != 0.0 && (buy ? target < sl + MIN_MODIFY : target > sl - MIN_MODIFY)) continue;   // not a real improvement
      if(trade.PositionModify(t, target, PositionGetDouble(POSITION_TP)))
         PrintFormat("SL moved %.*f -> %.*f (profit %.1f points)", _Digits, sl, _Digits, target, profit);
     }
  }

//+------------------------------------------------------------------+
//|  Events                                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   string w[];
   if(StringSplit(InpWindow, '-', w) == 2) { g_winStart = ParseHHMM(w[0]); g_winEnd = ParseHHMM(w[1]); }
   else g_winStart = g_winEnd = -1;
   string err = "";
   if(g_winStart < 0 || g_winEnd <= g_winStart)       err = "Window must be HH:MM-HH:MM with start before end";
   else if(!InpUsePDH && !InpUseH4 && !InpUseKZRange) err = "switch on at least one setup";      // V135
   else if(InpUseKZRange && !KZUsed())                err = "killzone range needs at least one killzone switched on";   // V135
   else if(InpSL <= 0.0 || InpRR < 0.0 || InpFixedTP < 0.0) err = "SL must be > 0, TP and RR >= 0";
   else if(InpUseTP && InpFixedTP <= 0.0)                  err = "fixed TP must be > 0";
   else if(InpUseBE && InpBEAt <= 0.0)                  err = "breakeven must be > 0";
   else if(InpUseTrail && (InpTrailAt <= 0.0 || InpTrailDist <= 0.0)) err = "trailing start and distance must be > 0";
   else if(InpRiskPct <= 0.0 || InpRiskPct > 5.0)     err = "risk must be > 0 and <= 5";
   else if(InpMaxTrades < 0)                          err = "max trades must be >= 0 (0 = no limit)";
   else if(InpUsePropRisk && (InpDailyLossPct <= 0.0 || InpWeeklyLossPct <= 0.0)) err = "daily and weekly loss limits must be > 0";
   else if(InpUseConfirm && (InpConfirmMinutes < 1 || InpConfirmMinutes > 240)) err = "confirmation candle must be 1 to 240 minutes";
   // === V133 START ===
   else if(InpBrokerGMTWinter < -12 || InpBrokerGMTWinter > 14) err = "broker GMT offset must be -12 to 14";
   else if(InpPropResetHour < 0 || InpPropResetHour > 23)      err = "prop reset hour must be 0 to 23";
   // === V133 END ===
   if(err != "") { Print("INVALID INPUT: ", err); return INIT_PARAMETERS_INCORRECT; }

   // === V133 START ===
   if(CanDraw()) ObjectsDeleteAll(0, PFX);                  // remove EA drawings left from an earlier run
   g_slCount = -1;
   g_kzNow = "";
   if(ShowExtra()) ChartSetInteger(0, CHART_SHIFT, true);   // free space on the right for the labels
   // === V133 END ===
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(200);
   // === V133 START === short start-up summary, one topic per line
   PrintFormat("NAS Breakout on %s | PDH %s | 4H %s | hours %s", _Symbol, InpUsePDH ? "on" : "off", InpUseH4 ? "on" : "off", InpWindow);
   PrintFormat("SL %g | %s | breakeven %s | trailing %s", InpSL,
               InpUseTP ? StringFormat("TP %g", InpFixedTP) : InpRR > 0.0 ? StringFormat("TP = SL x %g", InpRR) : "no TP",
               InpUseBE ? StringFormat("at %g", InpBEAt) : "off",
               InpUseTrail ? StringFormat("from %g, %g behind", InpTrailAt, InpTrailDist) : "off");
   PrintFormat("Risk %.2f%% per trade | max trades/day %s", InpRiskPct, InpMaxTrades > 0 ? IntegerToString(InpMaxTrades) : "no limit");
   // === V133 END ===
   PrintFormat("Loss limits: %s", InpUsePropRisk ? StringFormat("%g%% a day, %g%% a week", InpDailyLossPct, InpWeeklyLossPct) : "off");
   PrintFormat("Entry: %s", InpUseConfirm ? StringFormat("%d-min candle close, then %s", InpConfirmMinutes,
               InpEnterAtClose ? "market order" : "limit order at the level") : "stop order on the level");
   // === V133 START ===
   int sh = ServerMinusNYHours(TimeCurrent(), InpBrokerGMTWinter, InpBrokerDST);
   if(KZUsed())
      PrintFormat("Killzones (server time now = New York + %dh):%s%s%s", sh,
                  InpKZAsian  ? " Asian "  + ServerHM(KZ_ASIAN_START, sh)  + "-" + ServerHM(KZ_ASIAN_END, sh)  : "",
                  InpKZLondon ? " London " + ServerHM(KZ_LONDON_START, sh) + "-" + ServerHM(KZ_LONDON_END, sh) : "",
                  InpKZNYAM   ? " NY AM "  + ServerHM(KZ_NYAM_START, sh)   + "-" + ServerHM(KZ_NYAM_END, sh)   : "");
   else Print("Killzones: off (trades the whole window)");
   PrintFormat("Crossed levels: %s", InpLevelOnce ? "gone for the day once price crossed them (also when the EA could not trade)" : "v1.36 rule");   // V137
   // === V136 START ===
   if(KZUsed())
      PrintFormat("PDH / 4H: %s | killzone ranges: %s", InpKZFilterPDH4H ? "only inside killzones (filter ON)" : "all trading hours (filter OFF)",
                  InpUseKZRange ? "on, traded all trading hours after each killzone ends" : "off");
   // === V136 END ===
   if(InpUsePropRisk) PrintFormat("Prop firm day starts at %02d:00 server time", InpPropResetHour);
   // === V133 END ===
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   ObjectsDeleteAll(0, PFX);                                // V133: remove every EA drawing
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime today = DayStart(now);
   int mins = MinuteOf(now);
   if(today != g_day) NewDay(today);

   // === V133 START ===
   if(InpUsePropRisk)                                       // new prop day: read the starting balances once
     {
      datetime pd = PropDayStart(now);
      if(pd != g_propDay) { g_propDay = pd; PropStartBalances(pd); }
     }
   TimeLockCheck(now);                                      // live only, once per hour
   // === V136 START ===
   // Killzones limit PDH / 4H only when InpKZFilterPDH4H is on (old v1.35 behaviour).
   // Off (default): PDH / 4H trade all trading hours, killzones only build the killzone ranges.
   bool kzFilter = InpKZFilterPDH4H && KZUsed();
   bool inKZ = !kzFilter || InKillzone(now);                // no filter = always "inside"
   // === V136 END ===
   if(kzFilter && inKZ && !g_inKZ)                          // a killzone just started (filter on only):
     {
      g_pdhDone = false;                                    // place the PDH stop orders again
      if(!InpUseConfirm) g_h4Placed = false;                // place the 4H stop orders again (V137: same levels, crossed sides stay gone)
     }
   g_inKZ = inKZ;
   // === V133 END ===
   // === V135 START ===
   if(InpUseKZRange) KZRangeUpdate(now);                    // killzone ended = new range levels
   // === V135 END ===
   // === V137 START ===
   UpdateH4Levels();                                        // new 4H candle = new 4H levels (always)
   MarkCrossedStops();                                      // stop mode: a level price reached is gone
   bool tradePdhH4 = false, tradeKZ = false;                // may these setups place orders on this tick?
   // === V137 END ===

   ManageStops();

   PropCheckEquity();                                       // one equity comparison per tick

   // end of the trading day: nothing stays open
   if(mins >= g_dayEnd || mins < g_winStart)
     {
      DeleteOrders(0, "outside the window");
      if(mins >= g_dayEnd && CountPositions() > 0) CloseAll("window end");
      g_status = "outside the window";
     }
   else if(InpMaxTrades > 0 && g_tradesToday >= InpMaxTrades)
     {
      DeleteOrders(0, "max trades for today reached");
      g_status = "max trades for today reached";
     }
   else if(PropBlocked())
      g_status = "loss limit reached - no new orders";
   // === V133 START ===
   else if(g_timeBad)                                       // live time lock: open trades keep their SL / TP
     {
      if(CountOrders() > 0) DeleteOrders(0, "time mismatch");
      g_status = "TIME MISMATCH - check InpBrokerGMTWinter / InpBrokerDST";
     }
   else if(!inKZ)                                           // outside the killzones: no waiting orders
     {
      // === V135 START ===
      if(!InpUseKZRange)
        {
         if(CountOrders() > 0) DeleteOrders(0, "outside killzones");
        }
      else                                                  // PDH / 4H wait for a killzone, killzone ranges keep trading
        {
         DeleteOrders(InpMagic, "outside killzones");
         DeleteOrders(InpMagic + 1, "outside killzones");
         KZRangeOrders();
         tradeKZ = true;                                    // V137: ranges only (confirmation checked below)
        }
      // === V135 END ===
      g_status = "outside killzones - waiting";
     }
   // === V133 END ===
   else
     {
      // 1) PDH / PDL - once a day
      if(InpUsePDH && !g_pdhDone && g_pdhOk)
        {
         g_pdhDone = true;
         if(InpUseConfirm)
            PrintFormat("[PDH] waiting for a %d-min close above %.*f or below %.*f", InpConfirmMinutes, _Digits, g_pdh, _Digits, g_pdl);
         else
            StraddleLive(g_pdh, g_pdl, g_pdhBuyDone, g_pdhSellDone, InpMagic, "PDH");   // V137: crossed sides skipped
        }
      // 2) 4H - levels follow each new 4H candle (UpdateH4Levels); stop mode places the pair once per candle
      if(InpUseH4 && g_h4Ok && !g_h4Placed)                 // V137
        {
         g_h4Placed = true;
         if(InpUseConfirm)
            PrintFormat("[H4] waiting for a %d-min close above %.*f or below %.*f", InpConfirmMinutes, _Digits, g_h4Hi, _Digits, g_h4Lo);
         else
            StraddleLive(g_h4Hi, g_h4Lo, g_h4BuyDone, g_h4SellDone, InpMagic + 1, "H4");
        }
      if(InpUseKZRange) KZRangeOrders();                    // V135: 3) killzone ranges
      tradePdhH4 = tradeKZ = true;                          // V137: confirmation checked below
      g_status = StringFormat("%d open, waiting for breakouts", CountPositions());
     }
   // === V137 START ===
   // Every tick, whatever the state above: each finished confirmation candle is checked once.
   // A cross while orders are not allowed = that level is gone for today (InpLevelOnce).
   if(InpUseConfirm) ConfirmCheck(tradePdhH4, tradeKZ);
   // === V137 END ===

   // === V133 START === drawing only - never changes a trade
   DrawTradeLines();                                        // SL / TP lines, once per tick
   DrawKillzone(now);                                       // box when a killzone starts
   DrawRightLabels();                                       // right-edge labels, at most every 250 ms
   ShowChartText();
   // === V133 END ===
  }

// Fills and closes are only logged - no order is cancelled when another one fills.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(!Ours(HistoryDealGetInteger(trans.deal, DEAL_MAGIC), HistoryDealGetString(trans.deal, DEAL_SYMBOL))) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   ulong  mg  = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string tag = (mg == InpMagic) ? "PDH" : (mg == InpMagic + 1) ? "H4" : "KZ";   // V135
   if(entry == DEAL_ENTRY_IN)
     {
      // === V136 START === killzone range fill: mark that side traded, name the range in the log
      if(mg == InpMagic + 2)
        {
         int k = RangeFilled((ulong)HistoryDealGetInteger(trans.deal, DEAL_ORDER));
         if(k >= 0) tag = RangeTag(k);
        }
      // === V136 END ===
      g_tradesToday++;
      PrintFormat("[%s] FILLED %s @ %.*f (trade %d today)", tag, HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY ? "BUY" : "SELL",
                  _Digits, HistoryDealGetDouble(trans.deal, DEAL_PRICE), g_tradesToday);
     }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      long why = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      PrintFormat("[%s] CLOSED by %s, result %+.2f", tag, why == DEAL_REASON_SL ? "stop loss / trailing" : why == DEAL_REASON_TP ? "take profit" : "EA",
                  HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                  HistoryDealGetDouble(trans.deal, DEAL_COMMISSION));
     }
  }

//+------------------------------------------------------------------+
//|  Optimisation                                                    |
//+------------------------------------------------------------------+
// SL and TP: start 2, step 2; trail distance: start 5, step 2 - whatever the Inputs table shows.
// Breakeven and trail start are NOT overridden: the table's Start (5 by default), Step and Stop are used as typed.
// Tick the "Use ..." switch too (or set it to true) so the optimised value is actually used.
void Range(const string name, const double start, const double step, const double stop)
  {
   bool on = false;
   double v = 0, a = 0, b = 0, c = 0;
   if(ParameterGetRange(name, on, v, a, b, c) && !ParameterSetRange(name, on, v, start, step, stop))
      PrintFormat("Could not set the range of %s", name);
  }

int OnTesterInit()
  {
   Range("InpSL",         2.0, 2.0, 200.0);
   Range("InpFixedTP",    2.0, 2.0, 400.0);
   Range("InpRR",         0.0, 0.5, 5.0);
   Range("InpTrailDist",  5.0, 2.0, 150.0);
   Range("InpConfirmMinutes", 1, 1, 60);                   // confirmation candle: 1 to 60 minutes, step 1
   Print("Optimisation ranges: SL / TP start 2, trail distance start 5, step 2 (RR 0..5 step 0.5); confirmation minutes 1..60 step 1; breakeven and trail start use the Inputs table");
   return INIT_SUCCEEDED;
  }

void OnTesterDeinit() { }

// Custom max: profit factor x square root of trades (0 below 30 trades).
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES), pf = TesterStatistics(STAT_PROFIT_FACTOR);
   return (trades < 30.0 || pf <= 0.0) ? 0.0 : pf * MathSqrt(trades);
  }
//+------------------------------------------------------------------+
