//+------------------------------------------------------------------+
//|                                           PDH_PDL_Breakout.mq5    |
//|                                                                  |
//|  One simple previous-day high / low breakout, any symbol.         |
//|  Rules (chosen from the study in research/pdh_pdl, see            |
//|  reports/PDH_PDL_Research.md - read it before trading):           |
//|                                                                  |
//|   Levels  PDH / PDL = high / low of the last COMPLETE server day  |
//|           with at least 6 hours of M1 data (Sunday stubs are       |
//|           skipped). ATR = average true range of the 14 complete    |
//|           days before today. Nothing from today is used.           |
//|   Filter  No trade today if PDH - PDL > MaxRangeATR x ATR.         |
//|   Entry   From EntryStart (default 02:00 server, after the         |
//|           rollover spreads) a BUY STOP at PDH and a SELL STOP at   |
//|           PDL. A side is skipped if today's price already touched  |
//|           its level before the order could be placed.              |
//|   Exit    SL = SL_ATR x ATR from the order price, TP = RR x SL.    |
//|           Anything still open at DayEnd is closed; unfilled        |
//|           orders are deleted. No overnight / weekend holding.      |
//|   Limits  First fill cancels the other order (OCO). At most one    |
//|           trade per symbol per server day, also after restarts.    |
//|           Optional account-wide daily loss stop and max positions. |
//|                                                                  |
//|  All distances scale with ATR, so the same inputs work on FX,     |
//|  gold, indices and crypto. Position size comes from the money     |
//|  lost at the stop (OrderCalcProfit = tick value, contract size    |
//|  and account currency handled by the terminal).                   |
//|  All times are SERVER time (Market Watch clock). The study used   |
//|  a server day that ends at 17:00 New York (UTC+2 / UTC+3).        |
//+------------------------------------------------------------------+
#property copyright "PDH PDL Breakout"
#property version   "2.00"
#property description "Previous-day high/low breakout with ATR stops. Research and limits: reports/PDH_PDL_Research.md"

#include <Trade\Trade.mqh>

input group "=== Risk ==="
input double InpRiskPct         = 0.5;     // Risk per trade, % of balance
input double InpMaxDailyLossPct = 2.0;     // No new entries today after this % loss, all symbols with this magic (0 = off)
input int    InpMaxPositions    = 3;       // Max open positions with this magic, all symbols (0 = no limit)

input group "=== Strategy ==="
input double InpSL_ATR          = 1.0;     // Stop loss = daily ATR(14) x this
input double InpRR              = 2.0;     // Take profit = stop distance x this
input double InpMaxRangeATR     = 1.0;     // Skip the day if yesterday's range > ATR x this (0 = off)
input string InpEntryStart      = "02:00"; // No orders before this server time (rollover spreads)
input string InpDayEnd          = "23:50"; // Close trades and delete orders at this server time
input double InpMaxSpreadPctSL  = 10.0;    // Wait while the spread is above this % of the stop distance
input ulong  InpMagic           = 7710001; // Magic number

//--- fixed rules (part of the tested strategy, not meant to be tuned)
#define ATR_DAYS        14      // days in the ATR
#define MIN_DAY_M1_BARS 360     // a day needs >= 6 h of M1 bars to count as complete
#define MAX_LEVEL_AGE   4       // calendar days; older levels (long holiday) are not traded
#define MAX_ATTEMPTS    5       // order send attempts per side per day

//--- side state for today
#define SIDE_WAIT    0          // not placed yet
#define SIDE_PLACED  1          // pending order is live
#define SIDE_DONE    2          // filled, skipped or given up for today

CTrade   g_trade;
int      g_startMin = 0, g_endMin = 0;   // inputs in minutes after server midnight
datetime g_day = 0;                      // current server day
int      g_dayEnd = 0;                   // today's real day end (minutes)
bool     g_levelsOk = false;
datetime g_lastLevelTry = 0;
double   g_pdh = 0.0, g_pdl = 0.0, g_atr = 0.0;
datetime g_levelDay = 0;
bool     g_dayClosed = false;            // no more entries today (traded, filtered, loss stop, day end)
int      g_side[2];                      // 0 = buy, 1 = sell
int      g_attempts[2];
datetime g_lastAttempt[2];
string   g_status = "";
string   g_lastWait = "";
datetime g_lastComment = 0;
datetime g_lastLossCheck = 0;
bool     g_enteredToday = false;         // an entry happened today on this symbol (history / fills)
bool     g_noExpiry = false;             // broker rejected a specified expiry -> GTC + EA deletion

//+------------------------------------------------------------------+
//|  Helpers                                                          |
//+------------------------------------------------------------------+
int ParseHHMM(const string text)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   string p[];
   if(StringSplit(s, ':', p) != 2) return -1;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * 60 + m;
  }

datetime DayStart(const datetime t)  { return (datetime)((long)t - (long)t % 86400); }
int      MinuteOfDay(const datetime t) { return (int)(((long)t % 86400) / 60); }
string   HHMM(const int mins)          { return StringFormat("%02d:%02d", mins / 60, mins % 60); }

int DayOfWeek(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;
  }

double NormPrice(const double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

double Spread() { return SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID); }

// Broker minimum distance between price and an order / SL / TP.
double MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stops, freeze) + 1) * _Point;
  }

bool IsOurs(const long magic, const string symbol) { return (ulong)magic == InpMagic && symbol == _Symbol; }

// Prints a "waiting" reason once, not on every tick.
void Wait(const string why)
  {
   g_status = "waiting: " + why;
   if(why != g_lastWait) { Print("Waiting: ", why); g_lastWait = why; }
  }

int CountPositions(const bool allSymbols)
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(allSymbols || PositionGetString(POSITION_SYMBOL) == _Symbol) n++;
     }
   return n;
  }

// Ticket of our pending order on this symbol for one side (0 = none).
ulong FindPending(const bool buy)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !IsOurs(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
      long type = OrderGetInteger(ORDER_TYPE);
      if(buy && type == ORDER_TYPE_BUY_STOP) return t;
      if(!buy && type == ORDER_TYPE_SELL_STOP) return t;
     }
   return 0;
  }

// Deletes our pending orders on this symbol (only those placed before 'before' when it is set).
void DeletePendings(const string why, const datetime before = 0)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !IsOurs(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
      if(before > 0 && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= before) continue;
      if(g_trade.OrderDelete(t)) PrintFormat("Order #%I64u deleted (%s)", t, why);
      else PrintFormat("Order #%I64u could NOT be deleted (%s): %u %s - retrying next tick", t, why,
                       g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

void CloseAll(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(g_trade.PositionClose(t)) PrintFormat("Position #%I64u closed (%s)", t, why);
      else PrintFormat("Position #%I64u could NOT be closed (%s): %u %s - retrying next tick", t, why,
                       g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

// Last minute of the broker's trading session on this weekday (1440 if unknown / 24h).
int SessionEndMinute(const int dow)
  {
   datetime from = 0, to = 0;
   long last = -1;
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dow, i, from, to)) break;
      last = MathMax(last, (long)to / 60);
     }
   return (last <= 0) ? 1440 : (int)MathMin((long)1440, last);
  }

// True if the broker's trade session is open right now.
bool SessionOpenNow()
  {
   datetime now = TimeCurrent();
   int mins = MinuteOfDay(now);
   datetime from = 0, to = 0;
   bool any = false;
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)DayOfWeek(now), i, from, to)) break;
      any = true;
      if(mins >= (int)((long)from / 60) && mins < (int)((long)to / 60)) return true;
     }
   return !any;   // no session table -> assume open
  }

// Entries today for this symbol (restart-safe: read from the account history).
bool EnteredToday()
  {
   if(!HistorySelect(g_day, TimeCurrent() + 60)) return false;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d > 0 && IsOurs(HistoryDealGetInteger(d, DEAL_MAGIC), HistoryDealGetString(d, DEAL_SYMBOL)) &&
         HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN) return true;
     }
   return false;
  }

// Today's result (closed + floating) of everything with this magic, in % of the day's starting balance.
double TodayLossPct()
  {
   double closed = 0.0, floating = 0.0;
   if(HistorySelect(g_day, TimeCurrent() + 60))
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0 || (ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagic) continue;
         closed += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                   HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
        }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0 || (ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   double startBal = AccountInfoDouble(ACCOUNT_BALANCE) - closed;
   if(startBal <= 0.0) return 0.0;
   return -(closed + floating) / startBal * 100.0;
  }

//+------------------------------------------------------------------+
//|  Levels: PDH, PDL and ATR from complete earlier days only         |
//+------------------------------------------------------------------+
bool DayIsComplete(const datetime dayTime)
  {
   int n = Bars(_Symbol, PERIOD_M1, dayTime, dayTime + 86399);
   return (n <= 0) ? true : (n >= MIN_DAY_M1_BARS);   // no M1 history: trust the D1 candle
  }

bool ComputeLevels(const datetime today)
  {
   MqlRates d[];
   int n = CopyRates(_Symbol, PERIOD_D1, 0, 3 * ATR_DAYS, d);   // oldest first
   if(n <= 0) { g_status = "no daily history yet"; return false; }

   // complete days before today, newest first
   int idx[];
   ArrayResize(idx, 0);
   for(int i = n - 1; i >= 0; i--)
     {
      if(d[i].time >= today) continue;
      if(!DayIsComplete(d[i].time)) continue;
      int k = ArraySize(idx);
      ArrayResize(idx, k + 1);
      idx[k] = i;
      if(k + 1 >= ATR_DAYS + 1) break;
     }
   if(ArraySize(idx) < ATR_DAYS + 1)
     {
      g_status = StringFormat("only %d complete daily candles - need %d", ArraySize(idx), ATR_DAYS + 1);
      return false;
     }
   // ATR over the ATR_DAYS newest complete days (true range uses the previous complete day's close)
   double sum = 0.0;
   for(int k = 0; k < ATR_DAYS; k++)
     {
      double prevClose = d[idx[k + 1]].close;
      sum += MathMax(d[idx[k]].high, prevClose) - MathMin(d[idx[k]].low, prevClose);
     }
   g_atr      = sum / ATR_DAYS;
   g_pdh      = d[idx[0]].high;
   g_pdl      = d[idx[0]].low;
   g_levelDay = d[idx[0]].time;
   return true;
  }

void DrawLevel(const string name, const double price, const color clr)
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price)) return;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
   else ObjectMove(0, name, 0, 0, price);
   ObjectSetString(0, name, OBJPROP_TEXT, name + " " + DoubleToString(price, _Digits));
  }

//+------------------------------------------------------------------+
//|  New server day                                                   |
//+------------------------------------------------------------------+
void NewDay(const datetime today)
  {
   // anything left from an earlier day (no tick arrived after its day end) is removed first
   if(FindPending(true) > 0 || FindPending(false) > 0) DeletePendings("left over from an earlier day", today);
   if(CountPositions(false) > 0)
     {
      bool old = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
         if(PositionGetTicket(i) > 0 && IsOurs(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL)) &&
            (datetime)PositionGetInteger(POSITION_TIME) < today) old = true;
      if(old) CloseAll("left over from an earlier day");
     }

   g_day        = today;
   g_dayClosed  = false;
   g_levelsOk   = false;
   g_lastLevelTry = 0;
   g_lastWait   = "";
   for(int s = 0; s < 2; s++) { g_side[s] = SIDE_WAIT; g_attempts[s] = 0; g_lastAttempt[s] = 0; }
   g_dayEnd     = (int)MathMin(g_endMin, SessionEndMinute(DayOfWeek(today)) - 5);
   if(g_dayEnd < g_endMin)
      PrintFormat("Session ends early today - day end moved to %s", HHMM(g_dayEnd));

   // restart safety: already traded today / orders already live
   g_enteredToday = EnteredToday();
   if(g_enteredToday)
     {
      g_dayClosed = true;
      g_status = "already traded today";
      Print("Already traded on this symbol today - no new entries until tomorrow");
     }
   if(FindPending(true) > 0)  g_side[0] = SIDE_PLACED;
   if(FindPending(false) > 0) g_side[1] = SIDE_PLACED;
  }

// Levels and the once-per-day filter. Retried (once a minute) until history is available.
void PrepareLevels()
  {
   if(g_levelsOk || g_dayClosed) return;
   if(TimeCurrent() - g_lastLevelTry < 60) return;
   g_lastLevelTry = TimeCurrent();
   if(!ComputeLevels(g_day)) { Wait(g_status); return; }

   g_levelsOk = true;
   double range = g_pdh - g_pdl;
   PrintFormat("=== %s | levels from %s | PDH %.*f  PDL %.*f  range %.*f = %.2f x ATR(%d) %.*f",
               TimeToString(g_day, TIME_DATE), TimeToString(g_levelDay, TIME_DATE), _Digits, g_pdh, _Digits, g_pdl,
               _Digits, range, g_atr > 0 ? range / g_atr : 0.0, ATR_DAYS, _Digits, g_atr);
   DrawLevel("PDH", g_pdh, clrDodgerBlue);
   DrawLevel("PDL", g_pdl, clrOrangeRed);

   if((long)(g_day - DayStart(g_levelDay)) > (long)MAX_LEVEL_AGE * 86400)
     { g_dayClosed = true; g_status = "levels too old"; Print("No trade today: previous complete day is more than ", MAX_LEVEL_AGE, " days ago (holiday / missing data)"); return; }
   if(g_atr <= 0.0 || g_pdh <= g_pdl || g_pdl <= 0.0)
     { g_dayClosed = true; g_status = "bad levels"; Print("No trade today: invalid levels or ATR - check the symbol's history"); return; }
   if(InpMaxRangeATR > 0.0 && range > InpMaxRangeATR * g_atr)
     {
      g_dayClosed = true;
      g_status = "skipped: wide previous day";
      PrintFormat("No trade today: yesterday's range is %.2f x ATR (> %.2f) - breakouts after wide days tested negative",
                  range / g_atr, InpMaxRangeATR);
      return;
     }
   g_status = "levels ready";
  }

//+------------------------------------------------------------------+
//|  Orders                                                           |
//+------------------------------------------------------------------+
// Lot size so that a stop-out loses InpRiskPct % of the balance (never more). 0 = cannot trade.
double LotForRisk(const bool buy, const double entry, const double sl, string &why)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double p1 = 0.0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, p1) || p1 >= 0.0)
     { why = "OrderCalcProfit failed"; return 0.0; }
   double lossPerLot = -p1;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vlim = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(step <= 0.0) step = vmin;
   double lots = MathFloor(riskMoney / lossPerLot / step + 1e-9) * step;
   if(lots < vmin)
     {
      why = StringFormat("risk %.2f %s needs %.4f lots, below the minimum %.2f - lot NOT rounded up",
                         riskMoney, AccountInfoString(ACCOUNT_CURRENCY), riskMoney / lossPerLot, vmin);
      return 0.0;
     }
   lots = MathMin(lots, vmax);
   if(vlim > 0.0) lots = MathMin(lots, vlim);
   double m1 = 0.0;
   if(OrderCalcMargin(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, m1) && m1 > 0.0)
     {
      double maxByMargin = MathFloor(AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9 / m1 / step + 1e-9) * step;
      if(maxByMargin < vmin) { why = "not enough free margin for the minimum lot"; return 0.0; }
      if(lots > maxByMargin)
        {
         PrintFormat("Lot reduced from %.2f to %.2f to fit the free margin (risk is now below %.2f%%)", lots, maxByMargin, InpRiskPct);
         lots = maxByMargin;
        }
     }
   int volDigits = (int)MathMax(0.0, MathRound(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
  }

// Tries to place one side's stop order. Updates g_side[s].
void PlaceSide(const int s)
  {
   bool   buy  = (s == 0);
   string name = buy ? "BUY STOP @ PDH" : "SELL STOP @ PDL";
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // already broken today before an order was live? (chart = bid prices, like the D1 levels)
   double hi[], lo[];
   if(CopyHigh(_Symbol, PERIOD_M1, g_day, TimeCurrent(), hi) > 0 && CopyLow(_Symbol, PERIOD_M1, g_day, TimeCurrent(), lo) > 0)
     {
      double dayHi = hi[ArrayMaximum(hi)], dayLo = lo[ArrayMinimum(lo)];
      if(buy && MathMax(dayHi, bid) >= g_pdh)
        { g_side[s] = SIDE_DONE; PrintFormat("%s skipped: PDH was already reached today (high %.*f) before the order", name, _Digits, MathMax(dayHi, bid)); return; }
      if(!buy && MathMin(dayLo, bid) <= g_pdl)
        { g_side[s] = SIDE_DONE; PrintFormat("%s skipped: PDL was already reached today (low %.*f) before the order", name, _Digits, MathMin(dayLo, bid)); return; }
     }

   // a buy stop triggers on Ask: add the spread so it fills when the bid breaks PDH
   double entry = buy ? NormPrice(g_pdh + (ask - bid)) : NormPrice(g_pdl);
   double dist  = InpSL_ATR * g_atr;
   double minD  = MinStopDistance();
   if(dist <= minD) { g_side[s] = SIDE_DONE; PrintFormat("%s skipped: stop distance %.*f is inside the broker minimum %.*f", name, _Digits, dist, _Digits, minD); return; }
   if(buy ? entry - ask < minD : bid - entry < minD) { Wait(name + " too close to price for a stop order"); return; }

   double sl = NormPrice(buy ? entry - dist : entry + dist);
   double tp = NormPrice(buy ? entry + dist * InpRR : entry - dist * InpRR);
   if(sl <= 0.0 || tp <= 0.0) { g_side[s] = SIDE_DONE; PrintFormat("%s skipped: SL/TP at or below zero", name); return; }

   string why = "";
   double lot = LotForRisk(buy, entry, sl, why);
   if(lot <= 0.0) { g_side[s] = SIDE_DONE; PrintFormat("%s skipped: %s", name, why); return; }

   // expire at the day end on the broker side too, if the broker allows it
   ENUM_ORDER_TYPE_TIME ttype = ORDER_TIME_GTC;
   datetime expiry = 0;
   if(!g_noExpiry && (SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_SPECIFIED) != 0)
     { ttype = ORDER_TIME_SPECIFIED; expiry = g_day + g_dayEnd * 60; }

   g_attempts[s]++;
   g_lastAttempt[s] = TimeCurrent();
   bool ok = buy ? g_trade.BuyStop(lot, entry, _Symbol, sl, tp, ttype, expiry, "PDH breakout")
                 : g_trade.SellStop(lot, entry, _Symbol, sl, tp, ttype, expiry, "PDL breakout");
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      g_side[s] = SIDE_PLACED;
      g_lastWait = "";
      PrintFormat("%s placed: %.2f lots @ %.*f  SL %.*f  TP %.*f  (stop %.*f = %.2f ATR, risk %.2f%%)",
                  name, lot, _Digits, entry, _Digits, sl, _Digits, tp, _Digits, dist, InpSL_ATR, InpRiskPct);
      return;
     }
   if(rc == TRADE_RETCODE_INVALID_EXPIRATION && ttype == ORDER_TIME_SPECIFIED)
     {
      g_noExpiry = true;
      g_attempts[s]--;
      PrintFormat("%s: broker refused the order expiry - using GTC, the EA deletes the order at the day end", name);
      return;
     }
   PrintFormat("%s REJECTED (attempt %d/%d): %u %s", name, g_attempts[s], MAX_ATTEMPTS, rc, g_trade.ResultRetcodeDescription());
   if(g_attempts[s] >= MAX_ATTEMPTS) { g_side[s] = SIDE_DONE; PrintFormat("%s given up for today", name); }
  }

// Entry logic, called on every tick inside the trading part of the day.
void ManageEntries()
  {
   if(g_dayClosed || !g_levelsOk) return;
   if(g_side[0] == SIDE_DONE && g_side[1] == SIDE_DONE) return;

   // one trade per day: a fill closes the day for entries (OCO)
   if(CountPositions(false) > 0 || g_enteredToday)
     {
      g_dayClosed = true;
      if(FindPending(true) > 0 || FindPending(false) > 0) DeletePendings("one-cancels-other");
      g_status = "in a trade / traded today";
      return;
     }
   // account-wide daily loss stop (checked at most once a minute)
   if(InpMaxDailyLossPct > 0.0 && TimeCurrent() - g_lastLossCheck >= 60)
     {
      g_lastLossCheck = TimeCurrent();
      double loss = TodayLossPct();
      if(loss >= InpMaxDailyLossPct)
        {
         g_dayClosed = true;
         g_status = "daily loss limit";
         PrintFormat("No new entries today: today's loss %.2f%% >= limit %.2f%% (all symbols, magic %I64u)", loss, InpMaxDailyLossPct, InpMagic);
         DeletePendings("daily loss limit");
         return;
        }
     }

   bool needPlace = (g_side[0] == SIDE_WAIT || g_side[1] == SIDE_WAIT);
   if(!needPlace) { g_status = "orders live"; return; }

   // gates that only delay placing (re-checked on later ticks)
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY) { Wait("broker allows no new trades on this symbol"); return; }
   if(mode == SYMBOL_TRADE_MODE_LONGONLY && g_side[1] == SIDE_WAIT)  { g_side[1] = SIDE_DONE; Print("SELL side skipped: broker allows long only"); }
   if(mode == SYMBOL_TRADE_MODE_SHORTONLY && g_side[0] == SIDE_WAIT) { g_side[0] = SIDE_DONE; Print("BUY side skipped: broker allows short only"); }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED)) { Wait("algo trading is switched off in the terminal"); return; }
   if(!SessionOpenNow()) { Wait("symbol's trade session is closed"); return; }
   double spread = Spread(), dist = InpSL_ATR * g_atr;
   if(InpMaxSpreadPctSL > 0.0 && spread > dist * InpMaxSpreadPctSL / 100.0)
     { Wait(StringFormat("spread %.*f is above %.1f%% of the stop distance %.*f", _Digits, spread, InpMaxSpreadPctSL, _Digits, dist)); return; }
   if(InpMaxPositions > 0 && CountPositions(true) >= InpMaxPositions)
     { Wait(StringFormat("%d positions open with this magic (max %d)", CountPositions(true), InpMaxPositions)); return; }

   for(int s = 0; s < 2; s++)
      if(g_side[s] == SIDE_WAIT && TimeCurrent() - g_lastAttempt[s] >= 5) PlaceSide(s);

   int live = (g_side[0] == SIDE_PLACED ? 1 : 0) + (g_side[1] == SIDE_PLACED ? 1 : 0);
   g_status = StringFormat("%d order(s) live", live);
  }

//+------------------------------------------------------------------+
//|  Chart comment                                                    |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION) || (MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))) return;
   if(TimeCurrent() - g_lastComment < 1) return;
   g_lastComment = TimeCurrent();
   string t = StringFormat("PDH/PDL Breakout  %s\n", _Symbol);
   if(g_levelsOk)
      t += StringFormat("PDH %.*f  PDL %.*f  (from %s)  ATR %.*f  range/ATR %.2f\n", _Digits, g_pdh, _Digits, g_pdl,
                        TimeToString(g_levelDay, TIME_DATE), _Digits, g_atr, (g_pdh - g_pdl) / g_atr);
   t += StringFormat("Entries %s-%s server | status: %s\n", HHMM(g_startMin), HHMM(g_dayEnd), g_status);
   t += StringFormat("Positions %d (all symbols %d) | spread %.*f", CountPositions(false), CountPositions(true), _Digits, Spread());
   Comment(t);
  }

//+------------------------------------------------------------------+
//|  Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_startMin = ParseHHMM(InpEntryStart);
   g_endMin   = ParseHHMM(InpDayEnd);
   string bad = "";
   if(g_startMin < 0 || g_endMin < 0 || g_endMin <= g_startMin) bad = "EntryStart / DayEnd must be HH:MM with start before end";
   else if(InpRiskPct <= 0.0 || InpRiskPct > 5.0)               bad = "RiskPct must be > 0 and <= 5";
   else if(InpSL_ATR <= 0.0)                                     bad = "SL_ATR must be > 0";
   else if(InpRR <= 0.0)                                         bad = "RR must be > 0";
   else if(InpMaxRangeATR < 0.0 || InpMaxSpreadPctSL < 0.0 || InpMaxDailyLossPct < 0.0 || InpMaxPositions < 0)
      bad = "MaxRangeATR, MaxSpreadPctSL, MaxDailyLossPct and MaxPositions must be >= 0";
   if(bad != "") { Print("INVALID INPUT: ", bad); return INIT_PARAMETERS_INCORRECT; }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(50);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   g_day = 0;

   PrintFormat("PDH_PDL_Breakout 2.00 on %s | digits %d, tick size %g, tick value %g %s, contract %g, lots %g-%g step %g | stops level %I64d, freeze %I64d points",
               _Symbol, _Digits, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
               AccountInfoString(ACCOUNT_CURRENCY), SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL), SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   PrintFormat("Rules: risk %.2f%% | SL %.2f x ATR(%d) | TP %.2f R | skip if range > %.2f ATR | entries %s-%s server | daily loss stop %.1f%% | max positions %d",
               InpRiskPct, InpSL_ATR, ATR_DAYS, InpRR, InpMaxRangeATR, InpEntryStart, InpDayEnd, InpMaxDailyLossPct, InpMaxPositions);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   if(!MQLInfoInteger(MQL_OPTIMIZATION) && reason == REASON_REMOVE) { ObjectDelete(0, "PDH"); ObjectDelete(0, "PDL"); }
  }

void OnTick()
  {
   datetime now   = TimeCurrent();
   datetime today = DayStart(now);
   int      mins  = MinuteOfDay(now);
   if(today != g_day)
     {
      NewDay(today);
     }

   // two positions on this symbol (both stops hit in one fast move): keep the first, close the rest
   if(CountPositions(false) > 1)
     {
      ulong newest = 0; long newestTime = -1;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
         long tm = PositionGetInteger(POSITION_TIME_MSC);
         if(tm > newestTime) { newestTime = tm; newest = t; }
        }
      if(newest > 0 && g_trade.PositionClose(newest)) PrintFormat("Position #%I64u closed: second fill on the same day (one trade per day)", newest);
     }

   // day end: nothing is held after it
   if(mins >= g_dayEnd)
     {
      if(FindPending(true) > 0 || FindPending(false) > 0) DeletePendings("day end");
      if(CountPositions(false) > 0) CloseAll("day end");
      g_dayClosed = true;
      g_status = "day ended";
      UpdateComment();
      return;
     }

   // OCO safety net (e.g. a delete that failed, or a restart right after a fill)
   if(g_enteredToday && (FindPending(true) > 0 || FindPending(false) > 0)) DeletePendings("one-cancels-other");

   PrepareLevels();
   if(mins >= g_startMin) ManageEntries();
   UpdateComment();
  }

// Fills and closes: OCO, exposure limit and clear log lines.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(!IsOurs(HistoryDealGetInteger(trans.deal, DEAL_MAGIC), HistoryDealGetString(trans.deal, DEAL_SYMBOL))) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      g_enteredToday = true;
      g_dayClosed    = true;
      double px = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      bool   buy = HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY;
      double lvl = buy ? g_pdh : g_pdl;
      PrintFormat("FILLED %s %.2f lots @ %.*f (level %.*f, slippage+spread %.*f)", buy ? "BUY" : "SELL",
                  HistoryDealGetDouble(trans.deal, DEAL_VOLUME), _Digits, px, _Digits, lvl, _Digits, buy ? px - lvl : lvl - px);
      DeletePendings("one-cancels-other");
      g_side[0] = g_side[1] = SIDE_DONE;
      g_status = "in a trade";
      if(InpMaxPositions > 0 && CountPositions(true) > InpMaxPositions)
        {
         ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         if(PositionSelectByTicket(pos) && g_trade.PositionClose(pos))
            PrintFormat("Position #%I64u closed at once: more than %d positions open with magic %I64u", pos, InpMaxPositions, InpMagic);
        }
     }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string how = (reason == DEAL_REASON_SL) ? "stop loss" : (reason == DEAL_REASON_TP) ? "take profit" : "EA (day end / limit)";
      double pnl = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                   HistoryDealGetDouble(trans.deal, DEAL_COMMISSION) + HistoryDealGetDouble(trans.deal, DEAL_FEE);
      PrintFormat("CLOSED @ %.*f by %s, result %+.2f %s", _Digits, HistoryDealGetDouble(trans.deal, DEAL_PRICE), how, pnl,
                  AccountInfoString(ACCOUNT_CURRENCY));
      g_status = "trade closed - done for today";
     }
  }
//+------------------------------------------------------------------+
