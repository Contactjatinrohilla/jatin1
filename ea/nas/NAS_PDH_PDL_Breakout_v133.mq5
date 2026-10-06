//+------------------------------------------------------------------+
//|                                 NAS_PDH_PDL_Breakout_v133.mq5    |
//|                                                                  |
//|  Nasdaq 100 CFD (NAS100 / US100 / USTEC / NDX100) breakouts.      |
//|  Two simple setups, both traded independently:                    |
//|                                                                  |
//|  1. PDH / PDL  - once a day: BUY STOP at yesterday's high,        |
//|                  SELL STOP at yesterday's low.                    |
//|  2. 4H STRADDLE - as soon as a new 4-hour candle opens: BUY STOP  |
//|                  at the high and SELL STOP at the low of the      |
//|                  candle that just closed. When the next 4H candle |
//|                  opens, the old 4H orders still waiting are       |
//|                  deleted and the new pair is placed (open trades  |
//|                  keep running with their SL / TP).                |
//|                                                                  |
//|  NO order is cancelled when another one fills: both sides of a    |
//|  level stay active, PDH and 4H trades can run at the same time.   |
//|  Stop loss and take profit go on the order; optional breakeven    |
//|  and trailing stop protect the profit. Everything is closed at    |
//|  the window end and 5 minutes before the broker's daily close -   |
//|  nothing is held overnight or over the weekend (unfilled PDH      |
//|  orders are only deleted then).                                   |
//|                                                                  |
//|  Built in (no inputs needed): short Sunday daily candles are      |
//|  skipped, broken history (impossible levels) is skipped, lot size |
//|  is reduced if margin is short, broker stop levels are respected. |
//|                                                                  |
//|  Distances are in INDEX POINTS: 50 = a 50-point Nasdaq move.      |
//|  Times are SERVER time (Market Watch clock).                      |
//|                                                                  |
//|  New in 1.30 (both can be switched off = exactly like 1.29):      |
//|  - Prop firm limits: stop for the day / week when the account     |
//|    has lost the daily / weekly %, and never place an order that   |
//|    could break a limit if every stop loss were hit.               |
//|  - Candle close confirmation: instead of stop orders on the       |
//|    levels, wait for an N-minute candle to CLOSE past a level,     |
//|    then place a LIMIT order back at the level.                    |
//|                                                                  |
//|  New in 1.31 (display only, trading is identical to 1.30):        |
//|  - a dotted line shows the stop loss of every open EA trade       |
//|    (red = BUY, orange = SELL) and follows breakeven / trailing.   |
//|  - optimisation of the confirmation candle: 1 to 60 minutes.      |
//|                                                                  |
//|  New in 1.32: InpEnterAtClose = true enters IMMEDIATELY at the    |
//|  market price when the confirmation candle closes, instead of     |
//|  a limit order back at the level. false = exactly like 1.31.      |
//|                                                                  |
//|  New in 1.33 (all off / 0 = exactly like 1.32):                   |
//|  - Killzones in New York time (Asian, London, NY AM): new orders  |
//|    only inside the killzones you switch on.                       |
//|  - Live time lock: no new orders if the broker clock does not     |
//|    match InpBrokerGMTWinter / InpBrokerDST (live trading only).   |
//|  - Prop firm day can start at any server hour.                    |
//+------------------------------------------------------------------+
#property copyright "NAS Breakout Simple"
#property version   "1.33"
#property description "PDH/PDL breakout + 4H straddle for Nasdaq 100 CFDs. every level traded. Optional prop firm loss limits and candle close confirmation."

#include <Trade\Trade.mqh>

// === V133 START ===
// Inputs in a logical order. Names and default values are unchanged, so old set files still load.
input group "=== 1. Setups ==="
input bool   InpUsePDH          = true;          // Trade yesterday's high / low breakout (PDH / PDL)
input bool   InpUseH4           = true;          // Trade the high / low of the last 4-hour candle

input group "=== 2. Trading hours and killzones ==="
input string InpWindow          = "00:00-23:55"; // Trading hours, server time HH:MM-HH:MM (all closed at the end)
input int    InpBrokerGMTWinter = 2;             // Broker clock in WINTER = GMT + this many hours
input bool   InpBrokerDST       = true;          // Broker clock moves 1 hour forward in summer (true/false)
input bool   InpKZAsian         = false;         // Asian killzone, 20:00-24:00 New York time
input bool   InpKZLondon        = false;         // London killzone, 02:00-05:00 New York time
input bool   InpKZNYAM          = false;         // NY AM killzone, 08:30-11:00 New York time (all off = no killzones)

input group "=== 3. Entry confirmation ==="
input bool   InpUseConfirm      = true;          // Wait for a candle to CLOSE past the level (false = stop order on the level)
input int    InpConfirmMinutes  = 15;            // Confirmation candle length, minutes (1-240)
input bool   InpEnterAtClose    = false;         // After confirmation: true = enter now at market, false = limit order at the level

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

input group "=== 7. Other ==="
input ulong  InpMagic           = 930001;        // Order ID number (PDH = this, 4H = this + 1)
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

// === PROP RISK START ===
datetime g_week = 0;                              // Monday 00:00 of the current week
double   g_dayStartBal = 0, g_weekStartBal = 0;   // balance at the start of the day / week
double   g_dayLossPct = 0, g_weekLossPct = 0;     // current loss in % (updated every tick)
bool     g_dayBlocked = false, g_weekBlocked = false;   // true = limit reached, no new orders
// === PROP RISK END ===

// === CANDLE CONFIRM START ===
datetime g_cfLast = 0;                            // end time of the last confirmation candle we checked
bool     g_pdhBuyDone = false, g_pdhSellDone = false;   // each PDH side triggers once a day
double   g_h4Hi = 0, g_h4Lo = 0;                  // levels of the 4H candle that just closed
bool     g_h4Ok = false, g_h4BuyDone = false, g_h4SellDone = false;   // each 4H side triggers once per 4H candle
// === CANDLE CONFIRM END ===

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

bool Ours(const long magic, const string sym) { return sym == _Symbol && ((ulong)magic == InpMagic || (ulong)magic == InpMagic + 1); }

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

void HLine(const string name, const double price, const color clr)
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price)) return;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
     }
   else if(!ObjectMove(0, name, 0, 0, price)) return;
   ObjectSetString(0, name, OBJPROP_TEXT, name + " " + DoubleToString(price, _Digits));
  }

// === SL LINE START ===
int g_slCount = -1;   // number of this EA's open trades on the last tick (-1 = not known yet)

// One dotted line per open trade at its stop loss, named "SL <ticket>".
// Red = BUY, orange = SELL. Moves when breakeven / trailing moves the SL, deleted when the trade closes.
// Drawing only - it never touches an order or a trade.
void DrawSLLines()
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;             // nothing is drawn during optimisation
   int  n = 0;
   bool created = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)           // one loop over the open trades
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      n++;
      string name = "SL " + (string)t;
      double sl   = PositionGetDouble(POSITION_SL);
      if(sl <= 0.0)                                         // no stop loss = no line
        {
         if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
         continue;
        }
      if(ObjectFind(0, name) < 0)                           // new trade: create its line
        {
         if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, sl)) continue;
         bool buy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
         ObjectSetInteger(0, name, OBJPROP_COLOR, buy ? clrRed : clrOrange);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetString(0, name, OBJPROP_TEXT, name + " " + DoubleToString(sl, _Digits));
         created = true;
        }
      else if(MathAbs(ObjectGetDouble(0, name, OBJPROP_PRICE) - sl) > _Point / 2.0)   // SL moved: move the line
        {
         ObjectMove(0, name, 0, 0, sl);
         ObjectSetString(0, name, OBJPROP_TEXT, name + " " + DoubleToString(sl, _Digits));
        }
     }
   // Remove lines of closed trades - only when the number of trades changed or a new line appeared.
   if(n != g_slCount || created)
     {
      g_slCount = n;
      for(int k = ObjectsTotal(0, 0, OBJ_HLINE) - 1; k >= 0; k--)
        {
         string name = ObjectName(0, k, 0, OBJ_HLINE);
         if(StringFind(name, "SL ") != 0) continue;         // not one of our SL lines
         if(!PositionSelectByTicket((ulong)StringToInteger(StringSubstr(name, 3))))
            ObjectDelete(0, name);                          // its trade is closed
        }
     }
  }
// === SL LINE END ===

// True when hi/lo look like real prices (protects against broken history).
bool LevelsSane(const double hi, const double lo)
  {
   return lo > 0.0 && hi > lo && (hi - lo) <= hi * MAX_RANGE_PCT / 100.0;
  }

// === PROP RISK START ===
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
// === PROP RISK END ===

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

// One stop order at 'entry'. tag = "PDH" or "H4".
void PlaceStop(const bool buy, const double entry, const ulong magic, const string tag)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = BrokerMinDist();
   string side = buy ? "BUY" : "SELL";
   if(buy ? ask >= entry - gap : bid <= entry + gap)
     {
      PrintFormat("[%s] %s skipped: price already past %.*f", tag, side, _Digits, entry);   // V133: shorter log
      return;
     }
   if(InpSL <= gap) { PrintFormat("[%s] SL %g is smaller than the broker minimum %.2f", tag, InpSL, gap); return; }
   double sl  = Norm(buy ? entry - InpSL : entry + InpSL);
   double tpDist = (InpUseTP && InpFixedTP > 0.0) ? InpFixedTP : InpSL * InpRR;   // fixed TP wins over RR
   double tp  = (tpDist > 0.0) ? Norm(buy ? entry + tpDist : entry - tpDist) : 0.0;
   if(sl <= 0.0 || tp < 0.0) return;
   double lot = LotSize(buy, entry, sl);
   if(lot <= 0.0) return;
   // === PROP RISK START ===
   if(!PropOrderAllowed(buy, entry, sl, lot, tag)) return;
   // === PROP RISK END ===
   trade.SetExpertMagicNumber(magic);
   bool ok = buy ? trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag)
                 : trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag);
   if(ok) PrintFormat("[%s] %s STOP %.2f lots @ %.*f  SL %.*f  TP %s", tag, side, lot, _Digits, entry, _Digits, sl,
                      tp > 0.0 ? DoubleToString(tp, _Digits) : "none");
   else   PrintFormat("[%s] %s STOP rejected: %s", tag, side, trade.ResultRetcodeDescription());
  }

// Both sides of a straddle around hi / lo.
void Straddle(const double hi, const double lo, const ulong magic, const string tag)
  {
   if(!LevelsSane(hi, lo)) { PrintFormat("[%s] levels %.2f / %.2f look broken - skipped", tag, hi, lo); return; }
   PlaceStop(true,  Norm(hi), magic, tag);
   PlaceStop(false, Norm(lo), magic, tag);
  }

// === CANDLE CONFIRM START ===
//+------------------------------------------------------------------+
//|  Candle close confirmation                                        |
//+------------------------------------------------------------------+
// One LIMIT order exactly at 'entry', placed after a confirmed candle close.
// Stop loss, take profit and lot size are calculated exactly like PlaceStop, so the risk is identical.
void PlaceLimit(const bool buy, const double entry, const ulong magic, const string tag)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = BrokerMinDist();
   string side = buy ? "BUY" : "SELL";
   if(buy ? ask <= entry + gap : bid >= entry - gap)          // a limit order must wait on the far side of price
     {
      PrintFormat("[%s] %s LIMIT skipped: price already back at %.*f", tag, side, _Digits, entry);   // V133: shorter log
      return;
     }
   if(InpSL <= gap) { PrintFormat("[%s] SL %g is smaller than the broker minimum %.2f", tag, InpSL, gap); return; }
   double sl  = Norm(buy ? entry - InpSL : entry + InpSL);
   double tpDist = (InpUseTP && InpFixedTP > 0.0) ? InpFixedTP : InpSL * InpRR;   // fixed TP wins over RR
   double tp  = (tpDist > 0.0) ? Norm(buy ? entry + tpDist : entry - tpDist) : 0.0;
   if(sl <= 0.0 || tp < 0.0) return;
   double lot = LotSize(buy, entry, sl);
   if(lot <= 0.0) return;
   // === PROP RISK START ===
   if(!PropOrderAllowed(buy, entry, sl, lot, tag)) return;
   // === PROP RISK END ===
   trade.SetExpertMagicNumber(magic);
   bool ok = buy ? trade.BuyLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag)
                 : trade.SellLimit(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, tag);
   if(ok) PrintFormat("[%s] %s LIMIT %.2f lots @ %.*f  SL %.*f  TP %s", tag, side, lot, _Digits, entry, _Digits, sl,
                      tp > 0.0 ? DoubleToString(tp, _Digits) : "none");
   else   PrintFormat("[%s] %s LIMIT rejected: %s", tag, side, trade.ResultRetcodeDescription());
  }

// === ENTER AT CLOSE START ===
// Enter immediately at the current market price (BUY at Ask, SELL at Bid).
// Stop loss and take profit are the same DISTANCE as always, measured from the real entry price,
// and the lot size uses the same risk %, so the risk per trade stays identical.
void PlaceMarket(const bool buy, const ulong magic, const string tag)
  {
   double entry = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = BrokerMinDist();
   string side = buy ? "BUY" : "SELL";
   if(InpSL <= gap) { PrintFormat("[%s] SL %g is smaller than the broker minimum %.2f", tag, InpSL, gap); return; }
   double sl  = Norm(buy ? entry - InpSL : entry + InpSL);
   double tpDist = (InpUseTP && InpFixedTP > 0.0) ? InpFixedTP : InpSL * InpRR;   // fixed TP wins over RR
   double tp  = (tpDist > 0.0) ? Norm(buy ? entry + tpDist : entry - tpDist) : 0.0;
   if(sl <= 0.0 || tp < 0.0) return;
   double lot = LotSize(buy, entry, sl);
   if(lot <= 0.0) return;
   // === PROP RISK START ===
   if(!PropOrderAllowed(buy, entry, sl, lot, tag)) return;
   // === PROP RISK END ===
   trade.SetExpertMagicNumber(magic);
   bool ok = buy ? trade.Buy(lot, _Symbol, 0.0, sl, tp, tag)
                 : trade.Sell(lot, _Symbol, 0.0, sl, tp, tag);
   if(ok) PrintFormat("[%s] %s at market %.2f lots @ %.*f  SL %.*f  TP %s", tag, side, lot, _Digits, entry, _Digits, sl,
                      tp > 0.0 ? DoubleToString(tp, _Digits) : "none");
   else   PrintFormat("[%s] %s at market rejected: %s", tag, side, trade.ResultRetcodeDescription());
  }
// === ENTER AT CLOSE END ===

// Start time of the confirmation candle that contains time t (candles are counted from server midnight;
// the last candle of the day is shorter if the minutes do not divide 24 hours evenly).
datetime CandleStart(const datetime t)
  {
   long len = (long)InpConfirmMinutes * 60;
   long day = (long)DayStart(t);
   return (datetime)(day + ((long)t - day) / len * len);
  }

// A side is confirmed: log it and place the limit order back at the level.
void Confirmed(const bool buy, const double level, const double close, const ulong magic, const string tag)
  {
   PrintFormat("[%s] %s confirmed: %d-min candle closed %.*f, %s %.*f", tag, buy ? "BUY" : "SELL",
               InpConfirmMinutes, _Digits, close, buy ? "above" : "below", _Digits, level);   // V133: shorter log
   // === ENTER AT CLOSE START ===
   if(InpEnterAtClose) { PlaceMarket(buy, magic, tag); return; }   // enter now at market price
   // === ENTER AT CLOSE END ===
   PlaceLimit(buy, Norm(level), magic, tag);
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

// Called every tick, but does real work only once per confirmation candle, right after it has finished.
// Uses only finished 1-minute candles - never the one still forming.
void ConfirmCheck()
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

   // PDH / PDL: only candles that finished today, each side once a day
   if(InpUsePDH && g_pdhOk && end > g_day)
     {
      if(!g_pdhBuyDone && close > g_pdh && prev <= g_pdh)  { g_pdhBuyDone  = true; Confirmed(true,  g_pdh, close, InpMagic, "PDH"); }
      if(!g_pdhSellDone && close < g_pdl && prev >= g_pdl) { g_pdhSellDone = true; Confirmed(false, g_pdl, close, InpMagic, "PDH"); }
     }
   // 4H: only candles that finished after the current 4H candle opened, each side once per 4H candle
   if(InpUseH4 && g_h4Ok && end > g_h4)
     {
      if(!g_h4BuyDone && close > g_h4Hi && prev <= g_h4Hi)  { g_h4BuyDone  = true; Confirmed(true,  g_h4Hi, close, InpMagic + 1, "H4"); }
      if(!g_h4SellDone && close < g_h4Lo && prev >= g_h4Lo) { g_h4SellDone = true; Confirmed(false, g_h4Lo, close, InpMagic + 1, "H4"); }
     }
  }
// === CANDLE CONFIRM END ===

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
      HLine("PDH", g_pdh, clrDodgerBlue);
      HLine("PDL", g_pdl, clrOrangeRed);
     }
   else PrintFormat("=== %s | no PDH/PDL today (holiday or missing history)", TimeToString(today, TIME_DATE));   // V133: shorter log
   // === CANDLE CONFIRM START ===
   g_pdhBuyDone = g_pdhSellDone = false;                    // both PDH sides can trigger again today
   // === CANDLE CONFIRM END ===
   // === V133 START ===
   g_nyShift = ServerMinusNYHours(today, InpBrokerGMTWinter, InpBrokerDST);   // server - New York, for today
   // (the prop starting balances are now read in OnTick when a new prop day starts)
   // === V133 END ===
  }

//+------------------------------------------------------------------+
//|  Breakeven and trailing                                           |
//+------------------------------------------------------------------+
void ManageStops()
  {
   bool be = InpUseBE && InpBEAt > 0.0, trail = InpUseTrail && InpTrailAt > 0.0;
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
   else if(!InpUsePDH && !InpUseH4)                   err = "switch on at least one setup";
   else if(InpSL <= 0.0 || InpRR < 0.0 || InpFixedTP < 0.0) err = "SL must be > 0, TP and RR >= 0";
   else if(InpUseTP && InpFixedTP <= 0.0)                  err = "fixed TP must be > 0";
   else if(InpUseBE && InpBEAt <= 0.0)                  err = "breakeven must be > 0";
   else if(InpUseTrail && (InpTrailAt <= 0.0 || InpTrailDist <= 0.0)) err = "trailing start and distance must be > 0";
   else if(InpRiskPct <= 0.0 || InpRiskPct > 5.0)     err = "risk must be > 0 and <= 5";
   else if(InpMaxTrades < 0)                          err = "max trades must be >= 0 (0 = no limit)";
   // === PROP RISK START ===
   else if(InpUsePropRisk && (InpDailyLossPct <= 0.0 || InpWeeklyLossPct <= 0.0)) err = "daily and weekly loss limits must be > 0";
   // === PROP RISK END ===
   // === CANDLE CONFIRM START ===
   else if(InpUseConfirm && (InpConfirmMinutes < 1 || InpConfirmMinutes > 240)) err = "confirmation candle must be 1 to 240 minutes";
   // === CANDLE CONFIRM END ===
   // === V133 START ===
   else if(InpBrokerGMTWinter < -12 || InpBrokerGMTWinter > 14) err = "broker GMT offset must be -12 to 14";
   else if(InpPropResetHour < 0 || InpPropResetHour > 23)      err = "prop reset hour must be 0 to 23";
   // === V133 END ===
   if(err != "") { Print("INVALID INPUT: ", err); return INIT_PARAMETERS_INCORRECT; }

   // === SL LINE START ===
   ObjectsDeleteAll(0, "SL ");                              // remove SL lines left from an earlier run
   g_slCount = -1;
   // === SL LINE END ===
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
   // === PROP RISK START ===
   PrintFormat("Loss limits: %s", InpUsePropRisk ? StringFormat("%g%% a day, %g%% a week", InpDailyLossPct, InpWeeklyLossPct) : "off");
   // === PROP RISK END ===
   // === CANDLE CONFIRM START ===
   PrintFormat("Entry: %s", InpUseConfirm ? StringFormat("%d-min candle close, then %s", InpConfirmMinutes,
               InpEnterAtClose ? "market order" : "limit order at the level") : "stop order on the level");
   // === CANDLE CONFIRM END ===
   // === V133 START ===
   int sh = ServerMinusNYHours(TimeCurrent(), InpBrokerGMTWinter, InpBrokerDST);
   if(KZUsed())
      PrintFormat("Killzones (server time now = New York + %dh):%s%s%s", sh,
                  InpKZAsian  ? " Asian "  + ServerHM(KZ_ASIAN_START, sh)  + "-" + ServerHM(KZ_ASIAN_END, sh)  : "",
                  InpKZLondon ? " London " + ServerHM(KZ_LONDON_START, sh) + "-" + ServerHM(KZ_LONDON_END, sh) : "",
                  InpKZNYAM   ? " NY AM "  + ServerHM(KZ_NYAM_START, sh)   + "-" + ServerHM(KZ_NYAM_END, sh)   : "");
   else Print("Killzones: off (trades the whole window)");
   if(InpUsePropRisk) PrintFormat("Prop firm day starts at %02d:00 server time", InpPropResetHour);
   // === V133 END ===
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   // === SL LINE START ===
   ObjectsDeleteAll(0, "SL ");                              // no SL lines stay on the chart
   // === SL LINE END ===
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
   bool inKZ = !KZUsed() || InKillzone(now);                // killzones off = always "inside"
   if(KZUsed() && inKZ && !g_inKZ)                          // a killzone just started:
     {
      g_pdhDone = false;                                    // place the PDH stop orders again
      if(!InpUseConfirm) g_h4 = 0;                          // place the 4H stop orders again
     }
   g_inKZ = inKZ;
   // === V133 END ===

   ManageStops();

   // === PROP RISK START ===
   PropCheckEquity();                                       // one equity comparison per tick
   // === PROP RISK END ===

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
   // === PROP RISK START ===
   else if(PropBlocked())
      g_status = "loss limit reached - no new orders";
   // === PROP RISK END ===
   // === V133 START ===
   else if(g_timeBad)                                       // live time lock: open trades keep their SL / TP
     {
      if(CountOrders() > 0) DeleteOrders(0, "time mismatch");
      g_status = "TIME MISMATCH - check InpBrokerGMTWinter / InpBrokerDST";
     }
   else if(!inKZ)                                           // outside the killzones: no waiting orders
     {
      if(CountOrders() > 0) DeleteOrders(0, "outside killzones");
      g_status = "outside killzones - waiting";
     }
   // === V133 END ===
   else
     {
      // 1) PDH / PDL - once a day
      if(InpUsePDH && !g_pdhDone && g_pdhOk)
        {
         g_pdhDone = true;
         // === CANDLE CONFIRM START ===
         if(InpUseConfirm)
            PrintFormat("[PDH] waiting for a %d-min close above %.*f or below %.*f", InpConfirmMinutes, _Digits, g_pdh, _Digits, g_pdl);
         else
            Straddle(g_pdh, g_pdl, InpMagic, "PDH");        // original: stop orders on the levels
         // === CANDLE CONFIRM END ===
        }
      // 2) 4H straddle - as soon as each new 4H candle opens: old 4H orders out, new pair in
      datetime h4 = iTime(_Symbol, PERIOD_H4, 0);
      if(InpUseH4 && h4 > 0 && h4 != g_h4)
        {
         g_h4 = h4;
         DeleteOrders(InpMagic + 1, "new 4H candle - old 4H order replaced");
         // === CANDLE CONFIRM START ===
         g_h4Ok = false;                                    // old 4H levels are finished
         // === CANDLE CONFIRM END ===
         double hi = iHigh(_Symbol, PERIOD_H4, 1), lo = iLow(_Symbol, PERIOD_H4, 1);
         if(hi > 0.0 && lo > 0.0)
           {
            HLine("H4 high", hi, clrLime);
            HLine("H4 low", lo, clrMagenta);
            // === CANDLE CONFIRM START ===
            if(InpUseConfirm)
               ConfirmNewH4(hi, lo);                        // remember the levels, wait for a candle close
            else
               Straddle(hi, lo, InpMagic + 1, "H4");        // original: stop orders on the levels
            // === CANDLE CONFIRM END ===
           }
        }
      // === CANDLE CONFIRM START ===
      if(InpUseConfirm) ConfirmCheck();                     // real work only once per finished candle
      // === CANDLE CONFIRM END ===
      g_status = StringFormat("%d open, waiting for breakouts", CountPositions());
     }

   // === SL LINE START ===
   DrawSLLines();                                           // update the stop loss lines once per tick
   // === SL LINE END ===

   if(!MQLInfoInteger(MQL_OPTIMIZATION))
     {
      string text = StringFormat("NAS Breakout Simple | %s\nPDH %.*f  PDL %.*f | trades today %d | %s",
                                 _Symbol, _Digits, g_pdh, _Digits, g_pdl, g_tradesToday, g_status);
      // === PROP RISK START ===
      if(InpUsePropRisk)
         text += StringFormat("\nDaily loss %.1f%% / %.1f%% | Weekly %.1f%% / %.1f%%%s", MathMax(0.0, g_dayLossPct), InpDailyLossPct,
                              MathMax(0.0, g_weekLossPct), InpWeeklyLossPct, PropBlocked() ? " | LIMIT REACHED" : "");
      // === PROP RISK END ===
      Comment(text);
     }
  }

// Fills and closes are only logged - no order is cancelled when another one fills.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(!Ours(HistoryDealGetInteger(trans.deal, DEAL_MAGIC), HistoryDealGetString(trans.deal, DEAL_SYMBOL))) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   string tag = ((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == InpMagic) ? "PDH" : "H4";
   if(entry == DEAL_ENTRY_IN)
     {
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
   // === CONFIRM RANGE START ===
   Range("InpConfirmMinutes", 1, 1, 60);                   // confirmation candle: 1 to 60 minutes, step 1
   Print("Optimisation ranges: SL / TP start 2, trail distance start 5, step 2 (RR 0..5 step 0.5); confirmation minutes 1..60 step 1; breakeven and trail start use the Inputs table");
   // === CONFIRM RANGE END ===
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
