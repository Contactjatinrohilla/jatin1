//+------------------------------------------------------------------+
//|                                       NAS_PDH_PDL_Breakout.mq5    |
//|                                                                  |
//|  Nasdaq 100 CFD (NAS100 / US100 / USTEC) previous-day high/low    |
//|  breakout.                                                       |
//|                                                                  |
//|  Idea in one sentence: yesterday's high (PDH) and low (PDL) are   |
//|  levels many traders watch; when price breaks one of them during  |
//|  the New York session we follow the break.                        |
//|                                                                  |
//|  How it works                                                    |
//|   1. Every new server day the EA works out PDH and PDL from      |
//|      yesterday's FULL daily candle (the whole ~23h CFD day), or   |
//|      optionally from yesterday's cash session only.               |
//|   2. When the trading window opens (default: the whole day, from |
//|      the first tick after 00:00) it places a BUY STOP just        |
//|      above PDH and a SELL STOP just below PDL (filters below).    |
//|   3. When one of them fills, the other one is deleted. At most    |
//|      one trade per day.                                           |
//|   4. Stop loss / take profit are set on the order. Optional       |
//|      breakeven and trailing stop move the stop loss in profit.    |
//|   5. At the window end (and on Friday at FridayClose) everything  |
//|      is closed - no trade is held overnight or over the weekend.  |
//|      The window end moves to 5 minutes before the broker's daily  |
//|      session close when that is earlier.                          |
//|                                                                  |
//|  ALL distances are in POINTS (the symbol's smallest price step,   |
//|  _Point). On a 2-decimal Nasdaq quote 100 points = 1.00 index     |
//|  point; on a 1-decimal quote 10 points = 1.0 index point.         |
//|  ALL times are SERVER time (the time shown in Market Watch).      |
//+------------------------------------------------------------------+
#property copyright "NAS PDH PDL Breakout"
#property version   "1.10"
#property description "Previous-day high/low breakout for Nasdaq 100 CFDs (NAS100 / US100 / USTEC)."

#include <Trade\Trade.mqh>

//--- where PDH / PDL come from
enum ENUM_LEVEL_SOURCE
  {
   LEVEL_D1           = 0, // Previous daily candle (short Sunday candles skipped)
   LEVEL_CASH_SESSION = 1  // Previous day's cash session only (CashStart - CashEnd)
  };

//--- how the stop loss distance is chosen
enum ENUM_SL_MODE
  {
   SL_FIXED          = 0, // Fixed number of points
   SL_OPPOSITE_LEVEL = 1, // At the opposite level (PDL for buys, PDH for sells), capped
   SL_RANGE_PERCENT  = 2  // Percentage of yesterday's range (PDH - PDL)
  };

//--- trailing stop types
enum ENUM_TRAIL_MODE
  {
   TRAIL_OFF        = 0, // No trailing stop
   TRAIL_CONTINUOUS = 1, // SL follows price at a fixed distance
   TRAIL_STEPPED    = 2  // SL moves up in fixed steps
  };

//=== 1. Levels ======================================================
input group "=== 1. Levels ==="
input ENUM_LEVEL_SOURCE InpLevelSource      = LEVEL_D1;  // Where PDH / PDL come from
input int               InpMinDailyBarHours = 6;         // D1: ignore daily candles shorter than this (Sunday stubs)
input string            InpCashStart        = "16:30";   // Cash session start, server time (New York 09:30)
input string            InpCashEnd          = "23:00";   // Cash session end, server time (New York 16:00)

//=== 2. Entry =======================================================
input group "=== 2. Entry ==="
input string            InpWindow             = "00:00-23:55"; // Trading window, server time (default = whole day; ends 5 min before the session close)
input int               InpEntryBufferPoints  = 0;      // Entry this many points beyond PDH / PDL
input int               InpMaxGapPoints       = 0;      // Skip the day if price is this far beyond a level at the window start (0 = off)
input int               InpMinRangePoints     = 0;      // Skip the day if PDH - PDL is smaller than this (0 = off)
input int               InpMaxRangePoints     = 0;      // Skip the day if PDH - PDL is larger than this (0 = off)
input int               InpOrderExpiryMinutes = 0;      // Delete unfilled orders this many minutes after the window start (0 = off)

//=== 3. Stop loss and take profit ===================================
input group "=== 3. Stop loss / take profit (points) ==="
input ENUM_SL_MODE      InpSLMode      = SL_FIXED;      // How the stop loss is set
input int               InpSLPoints    = 5000;          // SL_FIXED: stop loss distance in points
input int               InpMaxSLPoints = 15000;         // SL_OPPOSITE_LEVEL: maximum stop loss in points (0 = no cap)
input double            InpSLRangePct  = 50.0;          // SL_RANGE_PERCENT: stop loss = this % of (PDH - PDL)
input double            InpRR          = 2.0;           // Take profit = stop loss distance x this
input bool              InpUseTP       = true;          // Use a take profit (false = exit by trailing stop / window end)

//=== 4. Trade management ============================================
input group "=== 4. Trade management (points) ==="
input bool              InpUseBE             = false;   // Breakeven on/off
input int               InpBE_TriggerPoints  = 3000;    // Breakeven: when the trade is this many points in profit...
input int               InpBE_LockPoints     = 200;     // ...move the SL to entry + this many points (not above the trigger)
input ENUM_TRAIL_MODE   InpTrailMode         = TRAIL_OFF; // Trailing stop type
input int               InpTrailStartPoints  = 5000;    // Trailing starts when the trade is this many points in profit
input int               InpTrailDistPoints   = 3000;    // CONTINUOUS: SL stays this many points behind price
input int               InpStepPoints        = 2000;    // STEPPED: every this many points of profit...
input int               InpLockPoints        = 1000;    // ...the SL locks this many more points (steps x lock)
input int               InpMinModifyPoints   = 100;     // Only move the SL when it changes by at least this many points
input string            InpFridayClose       = "22:00"; // Friday: close everything at this server time

//=== 5. Risk and filters ============================================
input group "=== 5. Risk and filters ==="
input double            InpRiskPct         = 0.5;       // Risk per trade, % of balance
input int               InpMaxSpreadPoints = 0;         // Do not place orders while the spread is above this (0 = off)
input bool              InpTradeMon        = true;      // Trade on Monday
input bool              InpTradeTue        = true;      // Trade on Tuesday
input bool              InpTradeWed        = true;      // Trade on Wednesday
input bool              InpTradeThu        = true;      // Trade on Thursday
input bool              InpTradeFri        = true;      // Trade on Friday
input ulong             InpMagic           = 920001;    // Magic number (identifies this EA's trades)

//--- working variables ------------------------------------------------
CTrade   g_trade;
int      g_winStart = 0, g_winEnd = 0;       // trading window, minutes after server midnight
int      g_cashStart = 0, g_cashEnd = 0;     // cash session, minutes after server midnight
int      g_friClose = 0;                     // Friday close, minutes after server midnight
datetime g_day = 0;                          // current server day (midnight)
int      g_dayEnd = 0;                       // today's real window end (window end or session close - 5 min)
bool     g_levelsOk = false;                 // PDH / PDL valid for today
double   g_pdh = 0.0, g_pdl = 0.0;
string   g_levelDay = "";                    // date the levels were taken from
bool     g_ordersDone = false;               // today's order decision has been made
bool     g_tradedToday = false;              // a trade was opened today
bool     g_spreadLogged = false;             // "spread too wide" printed today
string   g_status = "";                      // text for the chart comment
datetime g_lastComment = 0;

//+------------------------------------------------------------------+
//|  Small helpers                                                    |
//+------------------------------------------------------------------+
// "HH:MM" -> minutes after midnight, -1 if invalid.
int ParseHHMM(const string text)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   string parts[];
   if(StringSplit(s, ':', parts) != 2) return -1;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return -1;
   return h * 60 + m;
  }

// Midnight (server time) of the day that contains t.
datetime DayStart(const datetime t) { return (datetime)((long)t - (long)t % 86400); }

// Minutes after server midnight.
int MinuteOfDay(const datetime t) { return (int)(((long)t % 86400) / 60); }

// 0 = Sunday ... 6 = Saturday.
int DayOfWeek(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;
  }

// Previous Monday-Friday date before 'day'.
datetime PrevWeekday(const datetime day)
  {
   datetime d = day - 86400;
   while(DayOfWeek(d) == 0 || DayOfWeek(d) == 6) d -= 86400;
   return d;
  }

// Rounds a price to the symbol's tick size.
double NormPrice(const double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

double SpreadPoints() { return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point; }

// Broker minimum distance between price and SL/TP (stops level / freeze level), in price.
double MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)(MathMax(stops, freeze) + 1) * _Point;
  }

bool IsOurs(const long magic, const string symbol) { return (ulong)magic == InpMagic && symbol == _Symbol; }

bool TradeDayAllowed(const int dow)
  {
   switch(dow)
     {
      case 1: return InpTradeMon;
      case 2: return InpTradeTue;
      case 3: return InpTradeWed;
      case 4: return InpTradeThu;
      case 5: return InpTradeFri;
     }
   return false;   // Saturday / Sunday
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && IsOurs(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) n++;
     }
   return n;
  }

int CountPendings()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && IsOurs(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) n++;
     }
   return n;
  }

void DeletePendings(const string why)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurs(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
      if(g_trade.OrderDelete(ticket)) PrintFormat("Order #%I64u deleted (%s)", ticket, why);
      else PrintFormat("Order #%I64u could NOT be deleted (%s): %s", ticket, why, g_trade.ResultRetcodeDescription());
     }
  }

void CloseAll(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;
      if(g_trade.PositionClose(ticket)) PrintFormat("Position #%I64u closed (%s)", ticket, why);
      else PrintFormat("Position #%I64u could NOT be closed (%s): %s", ticket, why, g_trade.ResultRetcodeDescription());
     }
  }

// Last minute of the broker's trade session on this weekday (1440 if unknown).
int SessionEndMinute(const int dow)
  {
   datetime from = 0, to = 0;
   long     last = -1;
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dow, i, from, to)) break;
      last = MathMax(last, (long)to / 60);
     }
   return (last <= 0) ? 1440 : (int)MathMin((long)1440, last);
  }

//+------------------------------------------------------------------+
//|  Levels                                                          |
//+------------------------------------------------------------------+
// Highest high / lowest low of the M1 candles between from and to. False if there are none.
bool M1HighLow(const datetime from, const datetime to, double &hi, double &lo)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, from, to, r);
   if(n <= 0) return false;
   hi = r[0].high;
   lo = r[0].low;
   for(int i = 1; i < n; i++)
     {
      hi = MathMax(hi, r[i].high);
      lo = MathMin(lo, r[i].low);
     }
   return hi > lo;
  }

// How many hours a server day really traded (first to last M1 candle). -1 if unknown.
double TradedHours(const datetime dayStart)
  {
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, dayStart, dayStart + 86399, r);
   if(n <= 0) return -1.0;
   return (double)(r[n - 1].time - r[0].time + 60) / 3600.0;
  }

// LEVEL_D1: previous completed daily candle; short (Sunday) candles are skipped.
bool LevelsFromD1(const datetime today)
  {
   MqlRates d[];
   int n = CopyRates(_Symbol, PERIOD_D1, 0, 10, d);   // oldest first, newest last
   if(n <= 0) { Print("No daily candles available yet"); return false; }
   datetime expected = PrevWeekday(today);
   for(int i = n - 1; i >= 0; i--)
     {
      if(d[i].time >= today) continue;                   // today's (unfinished) candle
      double hours = TradedHours(d[i].time);
      bool shortBar = (hours >= 0.0) ? (hours < InpMinDailyBarHours) : (DayOfWeek(d[i].time) == 0);
      if(shortBar)
        {
         PrintFormat("Daily candle %s is short (%.1f h) - using the one before it", TimeToString(d[i].time, TIME_DATE), hours);
         continue;
        }
      if(DayStart(d[i].time) < expected)
        {
         PrintFormat("No data for %s (holiday?) - no trading today", TimeToString(expected, TIME_DATE));
         return false;
        }
      g_pdh = d[i].high;
      g_pdl = d[i].low;
      g_levelDay = TimeToString(d[i].time, TIME_DATE);
      return true;
     }
   Print("No usable previous daily candle found");
   return false;
  }

// LEVEL_CASH_SESSION: high / low of the previous weekday between CashStart and CashEnd.
bool LevelsFromCash(const datetime today)
  {
   datetime prev = PrevWeekday(today);
   double hi = 0.0, lo = 0.0;
   if(!M1HighLow(prev + g_cashStart * 60, prev + g_cashEnd * 60 - 1, hi, lo))
     {
      PrintFormat("No cash-session data on %s (holiday or missing history) - no trading today", TimeToString(prev, TIME_DATE));
      return false;
     }
   g_pdh = hi;
   g_pdl = lo;
   g_levelDay = TimeToString(prev, TIME_DATE) + " " + InpCashStart + "-" + InpCashEnd;
   return true;
  }

void DrawLevel(const string name, const double price, const color clr, const string label)
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(ObjectFind(0, name) < 0)
     {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price)) return;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
   else if(!ObjectMove(0, name, 0, 0, price)) return;
   ObjectSetString(0, name, OBJPROP_TEXT, label);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, label);
  }

// Called on the first tick of every server day.
void NewDay(const datetime today)
  {
   g_day          = today;
   g_ordersDone   = false;
   g_tradedToday  = false;
   g_spreadLogged = false;
   g_dayEnd       = (int)MathMin(g_winEnd, SessionEndMinute(DayOfWeek(today)) - 5);
   if(g_dayEnd < g_winEnd)
      PrintFormat("Session closes at %02d:%02d today - everything is closed at %02d:%02d", (g_dayEnd + 5) / 60, (g_dayEnd + 5) % 60,
                  g_dayEnd / 60, g_dayEnd % 60);
   g_levelsOk     = (InpLevelSource == LEVEL_D1) ? LevelsFromD1(today) : LevelsFromCash(today);

   // after a restart: did we already trade today / are our orders already there?
   if(HistorySelect(today, TimeCurrent() + 60))
      for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal > 0 && IsOurs(HistoryDealGetInteger(deal, DEAL_MAGIC), HistoryDealGetString(deal, DEAL_SYMBOL)) &&
            HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN) g_tradedToday = true;
        }
   if(CountPendings() > 0 || g_tradedToday) g_ordersDone = true;

   if(!g_levelsOk) { g_status = "no levels today"; return; }
   double rangePts = (g_pdh - g_pdl) / _Point;
   PrintFormat("=== %s | levels from %s (%s) | PDH %.*f  PDL %.*f  range %.0f points",
               TimeToString(today, TIME_DATE), g_levelDay, EnumToString(InpLevelSource),
               _Digits, g_pdh, _Digits, g_pdl, rangePts);
   DrawLevel("NAS_PDH", g_pdh, clrDodgerBlue, "PDH " + DoubleToString(g_pdh, _Digits));
   DrawLevel("NAS_PDL", g_pdl, clrOrangeRed,  "PDL " + DoubleToString(g_pdl, _Digits));
   g_status = g_ordersDone ? "already handled today" : "waiting for the window";
  }

//+------------------------------------------------------------------+
//|  Orders                                                          |
//+------------------------------------------------------------------+
// Stop loss distance (in price) for an entry at 'entry'.
double StopDistance(const bool buy, const double entry)
  {
   switch(InpSLMode)
     {
      case SL_OPPOSITE_LEVEL:
        {
         double dist = buy ? entry - g_pdl : g_pdh - entry;
         if(InpMaxSLPoints > 0) dist = MathMin(dist, InpMaxSLPoints * _Point);
         return dist;
        }
      case SL_RANGE_PERCENT:
         return (g_pdh - g_pdl) * InpSLRangePct / 100.0;
      default:
         return InpSLPoints * _Point;
     }
  }

// Lot size so that a stop-out loses InpRiskPct % of the balance. 0 = cannot trade.
double LotForRisk(const bool buy, const double entry, const double sl)
  {
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   double profit1Lot = 0.0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, profit1Lot))
     {
      Print("OrderCalcProfit failed - cannot size the trade");
      return 0.0;
     }
   double lossPerLot = MathAbs(profit1Lot);
   if(lossPerLot <= 0.0) return 0.0;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = vmin;
   double lots = MathFloor(riskMoney / lossPerLot / step + 1e-9) * step;
   if(lots < vmin)
     {
      PrintFormat("Trade skipped: risk %.2f needs %.4f lots, below the broker minimum %.2f (SL too wide or balance too small)",
                  riskMoney, riskMoney / lossPerLot, vmin);
      return 0.0;
     }
   lots = MathMin(lots, vmax);
   int volDigits = (int)MathMax(0.0, MathRound(-MathLog10(step)));
   return NormalizeDouble(lots, volDigits);
  }

// Places one stop order. True if the broker accepted it.
bool PlaceStop(const bool buy, const double entry)
  {
   string side = buy ? "BUY STOP" : "SELL STOP";
   double dist = StopDistance(buy, entry);
   if(dist <= MinStopDistance())
     {
      PrintFormat("%s skipped: stop loss distance %.0f points is too small", side, dist / _Point);
      return false;
     }
   double sl  = NormPrice(buy ? entry - dist : entry + dist);
   double tp  = InpUseTP ? NormPrice(buy ? entry + dist * InpRR : entry - dist * InpRR) : 0.0;
   double lot = LotForRisk(buy, entry, sl);
   if(lot <= 0.0) { PrintFormat("%s skipped: lot size", side); return false; }

   bool ok = buy ? g_trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "PDH breakout")
                 : g_trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "PDL breakout");
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      PrintFormat("%s %.2f lots @ %.*f  SL %.*f (%.0f pts)  TP %s", side, lot, _Digits, entry, _Digits, sl, dist / _Point,
                  InpUseTP ? DoubleToString(tp, _Digits) : "none");
      return true;
     }
   PrintFormat("%s REJECTED: %u %s", side, rc, g_trade.ResultRetcodeDescription());
   return false;
  }

// The once-per-day order decision at the window start.
void TryPlaceOrders()
  {
   if(g_ordersDone || g_tradedToday || !g_levelsOk) return;

   if(!TradeDayAllowed(DayOfWeek(g_day)))
     {
      g_ordersDone = true;
      g_status = "weekday switched off";
      Print("No orders today: weekday switched off");
      return;
     }
   if(InpMaxSpreadPoints > 0 && SpreadPoints() > InpMaxSpreadPoints)
     {
      g_status = "waiting: spread too wide";
      if(!g_spreadLogged) { PrintFormat("Waiting: spread %.0f > max %d points", SpreadPoints(), InpMaxSpreadPoints); g_spreadLogged = true; }
      return;   // try again on the next tick
     }
   g_ordersDone = true;   // from here on the decision for today is final

   double rangePts = (g_pdh - g_pdl) / _Point;
   if(InpMinRangePoints > 0 && rangePts < InpMinRangePoints)
     { g_status = "skipped: range too small"; PrintFormat("No orders today: range %.0f < min %d points", rangePts, InpMinRangePoints); return; }
   if(InpMaxRangePoints > 0 && rangePts > InpMaxRangePoints)
     { g_status = "skipped: range too large"; PrintFormat("No orders today: range %.0f > max %d points", rangePts, InpMaxRangePoints); return; }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(InpMaxGapPoints > 0)
     {
      double above = (bid - g_pdh) / _Point, below = (g_pdl - bid) / _Point;
      if(above > InpMaxGapPoints || below > InpMaxGapPoints)
        {
         g_status = "skipped: gap";
         PrintFormat("No orders today: price %.*f is %.0f points beyond a level (max %d)", _Digits, bid, MathMax(above, below), InpMaxGapPoints);
         return;
        }
     }

   double minDist = MinStopDistance();
   double buyAt   = NormPrice(g_pdh + InpEntryBufferPoints * _Point);
   double sellAt  = NormPrice(g_pdl - InpEntryBufferPoints * _Point);
   int    placed  = 0;

   if(ask >= buyAt)               PrintFormat("BUY side skipped: price %.*f is already above %.*f", _Digits, ask, _Digits, buyAt);
   else if(buyAt - ask < minDist) PrintFormat("BUY side skipped: %.*f is too close to price for a stop order", _Digits, buyAt);
   else if(PlaceStop(true, buyAt)) placed++;

   if(bid <= sellAt)               PrintFormat("SELL side skipped: price %.*f is already below %.*f", _Digits, bid, _Digits, sellAt);
   else if(bid - sellAt < minDist) PrintFormat("SELL side skipped: %.*f is too close to price for a stop order", _Digits, sellAt);
   else if(PlaceStop(false, sellAt)) placed++;

   g_status = (placed == 2) ? "both orders placed" : (placed == 1) ? "one order placed" : "no orders placed";
  }

//+------------------------------------------------------------------+
//|  Breakeven and trailing stop                                      |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!InpUseBE && InpTrailMode == TRAIL_OFF) return;
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD   = MinStopDistance();
   double freeze = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurs(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL))) continue;

      bool   buy       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open      = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl        = PositionGetDouble(POSITION_SL);
      double tp        = PositionGetDouble(POSITION_TP);
      double price     = buy ? bid : ask;                       // price the trade would close at
      double profitPts = (buy ? bid - open : open - ask) / _Point;
      double target    = sl;
      string why       = "";

      // 1) breakeven
      if(InpUseBE && profitPts >= InpBE_TriggerPoints)
        {
         double be = buy ? open + InpBE_LockPoints * _Point : open - InpBE_LockPoints * _Point;
         if(sl == 0.0 || (buy ? be > target : be < target)) { target = be; why = "breakeven"; }
        }
      // 2) trailing
      if(InpTrailMode != TRAIL_OFF && profitPts >= InpTrailStartPoints)
        {
         double tr;
         if(InpTrailMode == TRAIL_CONTINUOUS)
            tr = buy ? bid - InpTrailDistPoints * _Point : ask + InpTrailDistPoints * _Point;
         else
           {
            double steps = MathFloor(profitPts / InpStepPoints);
            tr = buy ? open + steps * InpLockPoints * _Point : open - steps * InpLockPoints * _Point;
           }
         if((sl == 0.0 && why == "") || (buy ? tr > target : tr < target)) { target = tr; why = "trailing"; }
        }
      if(why == "") continue;

      // keep the broker's minimum distance from the current price
      if(buy && price - target < minD)  target = price - minD;
      if(!buy && target - price < minD) target = price + minD;
      target = NormPrice(target);

      // only in the trade's favour, and only if the change is big enough
      if(sl != 0.0 && (buy ? target <= sl : target >= sl)) continue;
      if(sl != 0.0 && MathAbs(target - sl) < InpMinModifyPoints * _Point) continue;
      // inside the freeze level the broker does not allow any change
      if(freeze > 0.0 && sl != 0.0 && MathAbs(price - sl) <= freeze) continue;

      if(g_trade.PositionModify(ticket, target, tp))
         PrintFormat("SL %s: %.*f -> %.*f (profit %.0f points)", why, _Digits, sl, _Digits, target, profitPts);
      else
         PrintFormat("SL %s to %.*f REJECTED: %s", why, _Digits, target, g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//|  Chart comment                                                    |
//+------------------------------------------------------------------+
void UpdateComment()
  {
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   datetime now = TimeCurrent();
   if(now - g_lastComment < 1) return;          // at most once per second
   g_lastComment = now;
   string txt = StringFormat("NAS PDH/PDL Breakout  (%s)\n", _Symbol);
   txt += StringFormat("Level source: %s  [%s]\n", InpLevelSource == LEVEL_D1 ? "previous daily candle" : "previous cash session", g_levelDay);
   if(g_levelsOk)
      txt += StringFormat("PDH %.*f   PDL %.*f   range %.0f points\n", _Digits, g_pdh, _Digits, g_pdl, (g_pdh - g_pdl) / _Point);
   else
      txt += "PDH / PDL: not available today\n";
   txt += StringFormat("Window %s | status: %s | pending %d | open %d\n", InpWindow, g_status, CountPendings(), CountPositions());
   txt += StringFormat("Spread %.0f points", SpreadPoints());
   Comment(txt);
  }

//+------------------------------------------------------------------+
//|  Events                                                          |
//+------------------------------------------------------------------+
int Fail(const string why)
  {
   Print("INVALID INPUT: ", why);
   return INIT_PARAMETERS_INCORRECT;
  }

int OnInit()
  {
   string w[];
   if(StringSplit(InpWindow, '-', w) != 2) return Fail("Window must be HH:MM-HH:MM");
   g_winStart  = ParseHHMM(w[0]);
   g_winEnd    = ParseHHMM(w[1]);
   g_cashStart = ParseHHMM(InpCashStart);
   g_cashEnd   = ParseHHMM(InpCashEnd);
   g_friClose  = ParseHHMM(InpFridayClose);
   if(g_winStart < 0 || g_winEnd < 0 || g_winEnd <= g_winStart) return Fail("Window must be HH:MM-HH:MM with start before end");
   if(g_cashStart < 0 || g_cashEnd < 0 || g_cashEnd <= g_cashStart) return Fail("CashStart / CashEnd must be HH:MM, start before end");
   if(g_friClose < 0)                                   return Fail("FridayClose must be HH:MM");
   if(InpRiskPct <= 0.0 || InpRiskPct > 10.0)          return Fail("RiskPct must be > 0 and <= 10");
   if(InpRR <= 0.0)                                     return Fail("RR must be > 0");
   if(InpSLMode == SL_FIXED && InpSLPoints <= 0)        return Fail("SLPoints must be > 0");
   if(InpSLMode == SL_RANGE_PERCENT && InpSLRangePct <= 0.0) return Fail("SLRangePct must be > 0");
   if(InpMaxSLPoints < 0 || InpEntryBufferPoints < 0 || InpMaxGapPoints < 0 || InpMinRangePoints < 0 ||
      InpMaxRangePoints < 0 || InpOrderExpiryMinutes < 0 || InpMaxSpreadPoints < 0 || InpMinModifyPoints < 0)
      return Fail("point and minute inputs must be >= 0");
   if(InpMaxRangePoints > 0 && InpMaxRangePoints <= InpMinRangePoints) return Fail("MaxRange must be above MinRange");
   if(InpUseBE && (InpBE_TriggerPoints <= 0 || InpBE_LockPoints < 0 || InpBE_LockPoints > InpBE_TriggerPoints))
      return Fail("Breakeven: trigger > 0 and lock between 0 and the trigger");
   if(InpTrailMode == TRAIL_CONTINUOUS && (InpTrailStartPoints < 0 || InpTrailDistPoints <= 0))
      return Fail("Continuous trailing: start >= 0 and distance > 0");
   if(InpTrailMode == TRAIL_STEPPED && (InpTrailStartPoints < 0 || InpStepPoints <= 0 || InpLockPoints <= 0))
      return Fail("Stepped trailing: start >= 0, step > 0 and lock > 0");
   if(InpMinDailyBarHours < 0 || InpMinDailyBarHours > 24) return Fail("MinDailyBarHours must be 0-24");

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(200);
   g_day = 0;

   PrintFormat("NAS_PDH_PDL_Breakout on %s | digits %d, 1 point = %g | window %s | SL %s | RR %g%s | risk %.2f%%",
               _Symbol, _Digits, _Point, InpWindow, EnumToString(InpSLMode), InpRR, InpUseTP ? "" : " (TP off)", InpRiskPct);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   Comment("");
   if(!MQLInfoInteger(MQL_OPTIMIZATION) && reason == REASON_REMOVE)
     {
      ObjectDelete(0, "NAS_PDH");
      ObjectDelete(0, "NAS_PDL");
     }
  }

void OnTick()
  {
   datetime now   = TimeCurrent();
   datetime today = DayStart(now);
   int      mins  = MinuteOfDay(now);
   if(today != g_day) NewDay(today);

   ManagePositions();

   // Friday: never hold over the weekend
   if(DayOfWeek(now) == 5 && mins >= g_friClose)
     {
      if(CountPendings() > 0) DeletePendings("Friday close");
      if(CountPositions() > 0) CloseAll("Friday close");
      g_ordersDone = true;
      g_status = "Friday close";
      UpdateComment();
      return;
     }

   // window end: nothing is held after it
   if(mins >= g_dayEnd)
     {
      if(CountPendings() > 0) DeletePendings("window end");
      if(CountPositions() > 0) CloseAll("window end");
      if(g_status != "window ended") g_status = "window ended";
      UpdateComment();
      return;
     }

   if(mins >= g_winStart)
     {
      // optional expiry of unfilled orders
      if(InpOrderExpiryMinutes > 0 && mins >= g_winStart + InpOrderExpiryMinutes && CountPendings() > 0)
        {
         DeletePendings("order expiry");
         g_status = "orders expired";
        }
      TryPlaceOrders();
     }
   UpdateComment();
  }

// Fills and closes: one-cancels-other, max one trade per day, logging.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(!IsOurs(HistoryDealGetInteger(trans.deal, DEAL_MAGIC), HistoryDealGetString(trans.deal, DEAL_SYMBOL))) return;

   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      g_tradedToday = true;
      PrintFormat("FILLED %s %.2f lots @ %.*f", HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY ? "BUY" : "SELL",
                  HistoryDealGetDouble(trans.deal, DEAL_VOLUME), _Digits, HistoryDealGetDouble(trans.deal, DEAL_PRICE));
      DeletePendings("one-cancels-other");
      g_status = "in a trade";
     }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      long   reason = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      string how    = (reason == DEAL_REASON_SL) ? "stop loss / trailing stop" : (reason == DEAL_REASON_TP) ? "take profit" : "closed by the EA";
      double pnl    = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                      HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      PrintFormat("CLOSED @ %.*f by %s, result %+.2f %s", _Digits, HistoryDealGetDouble(trans.deal, DEAL_PRICE), how, pnl,
                  AccountInfoString(ACCOUNT_CURRENCY));
      g_status = "trade closed - done for today";
     }
  }

//+------------------------------------------------------------------+
//|  Optimisation                                                    |
//+------------------------------------------------------------------+
// Sets the optimisation range of an integer input (keeps its tick box as it is).
void RangeL(const string name, const long start, const long step, const long stop)
  {
   bool enable = false;
   long value = 0, s1 = 0, s2 = 0, s3 = 0;
   if(ParameterGetRange(name, enable, value, s1, s2, s3))
      if(!ParameterSetRange(name, enable, value, start, step, stop)) PrintFormat("Could not set the range of %s", name);
  }

// Same for a decimal input.
void RangeD(const string name, const double start, const double step, const double stop)
  {
   bool enable = false;
   double value = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0;
   if(ParameterGetRange(name, enable, value, s1, s2, s3))
      if(!ParameterSetRange(name, enable, value, start, step, stop)) PrintFormat("Could not set the range of %s", name);
  }

int OnTesterInit()
  {
   RangeL("InpSLPoints",          1000, 500, 20000);
   RangeL("InpMaxSLPoints",       1000, 500, 20000);
   RangeD("InpRR",                1.0, 0.5, 6.0);
   RangeL("InpEntryBufferPoints", 0,    100, 2000);
   RangeL("InpBE_TriggerPoints",  500,  500, 20000);
   RangeL("InpBE_LockPoints",     500,  500, 20000);
   RangeL("InpTrailStartPoints",  500,  500, 20000);
   RangeL("InpTrailDistPoints",   500,  500, 20000);
   RangeL("InpStepPoints",        500,  500, 20000);
   RangeL("InpLockPoints",        500,  500, 20000);
   Print("Optimisation ranges set: SL 1000-20000/500, RR 1-6/0.5, buffer 0-2000/100, BE/trail 500-20000/500");
   return INIT_SUCCEEDED;
  }

void OnTesterDeinit() { }

// Custom max: profit factor x square root of trades (0 below 30 trades or when losing).
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   if(trades < 30.0 || pf <= 0.0) return 0.0;
   return pf * MathSqrt(trades);
  }
//+------------------------------------------------------------------+
