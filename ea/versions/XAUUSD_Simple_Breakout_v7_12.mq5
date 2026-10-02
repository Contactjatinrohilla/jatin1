//+------------------------------------------------------------------+
//|              XAUUSD_Simple_Breakout.mq5   v7.12                   |
//|                                                                  |
//|  A deliberately small rewrite of the PDH/PDL + London idea.       |
//|                                                                  |
//|  SETUP A  Previous-day high/low (PDH/PDL), active from PDHStart.  |
//|  SETUP B  Session range (default = London 08:00-16:00 London time)|
//|           = highest high / lowest low of the M1 bars from         |
//|           RangeStart to RangeEnd, active from RangeEnd.           |
//|                                                                  |
//|  ENTRY MODES (InpEntryMode - optimisable)                        |
//|   0 STOP        BUY STOP above the high, SELL STOP below the low  |
//|   1 STOP-LIMIT  same, but never fills more than MaxSlip past the  |
//|                 level (spike fills are skipped, not taken)        |
//|   2 CLOSE       market order after a ConfirmTF candle CLOSES      |
//|                 beyond the level (not further than MaxChase)      |
//|   3 RETEST      after that close, a LIMIT order back at the level |
//|                                                                  |
//|  RULES                                                           |
//|   - ONE trade at a time: when any order fills, every other        |
//|     pending order is deleted (also the OCO of a straddle). A      |
//|     setup that did not fill is re-armed and can trade after.      |
//|   - Each setup fills at most once per day; max trades per day.    |
//|   - No-trade windows / days (news), weekday switches, level-size  |
//|     filter, direction switch.                                    |
//|   - Orders deleted at TradeEnd, trades closed at CloseTime.       |
//|   - Daily loss stop on closed + open P/L. Optional breakeven.     |
//|                                                                  |
//|  OPTIMISATION: select "Custom max" in the Strategy Tester and     |
//|  pick what to maximise with InpScore (section 7).                 |
//|                                                                  |
//|  UNITS: distances in USD of gold price (5.00 = a $5 move), so     |
//|  2-digit and 3-digit symbols behave identically.                  |
//|  TIMES: SERVER time. On a UTC+2/+3 server London 08:00 = 10:00 and |
//|  US data (08:30 New York) = 15:30. See docs/GUIDE.md.              |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout v7.12"
#property version   "7.12"

#include <Trade\Trade.mqh>

enum ENUM_ENTRY_MODE
  {
   ENTRY_STOP       = 0, // Stop order at the level
   ENTRY_STOP_LIMIT = 1, // Stop-limit: skip fills worse than MaxSlip
   ENTRY_CLOSE      = 2, // Market order after a candle CLOSES beyond the level
   ENTRY_RETEST     = 3  // Limit order back at the level after a close beyond it
  };

enum ENUM_DIRECTION
  {
   DIR_BOTH = 0, // Buy and sell
   DIR_BUY  = 1, // Buy only
   DIR_SELL = 2  // Sell only
  };

enum ENUM_CLOSE_MODE
  {
   CLOSE_DAILY  = 0, // Close open trades every day at CloseTime
   CLOSE_FRIDAY = 1, // Hold overnight, close only on Friday (no weekend gap)
   CLOSE_NEVER  = 2  // Never force-close (SL / TP only)
  };

enum ENUM_SCORE
  {
   SCORE_ROBUST   = 0, // Robust: (PF-1) x sqrt(trades) / max DD%
   SCORE_PF       = 1, // Profit factor
   SCORE_RECOVERY = 2, // Recovery factor (net profit / max DD)
   SCORE_PROFIT   = 3, // Net profit
   SCORE_SHARPE   = 4, // Sharpe ratio
   SCORE_AVG_R    = 5, // Average R per trade (expectancy)
   SCORE_RET_DD   = 6  // Return % / max DD %
  };

input group "=== 1. Setups (SERVER time, HH:MM) ==="
input bool   InpUsePDH          = true;     // Setup A: previous-day high/low breakout
input string InpPDHStart        = "01:15";  // A: active from
input bool   InpUseRange        = true;     // Setup B: session-range breakout
input string InpRangeStart      = "10:00";  // B: range start (10:00 server = London 08:00)
input string InpRangeEnd        = "18:00";  // B: range end = active from (18:00 server = London 16:00)
input string InpTradeEnd        = "22:00";  // Delete unfilled orders / stop new entries at
input string InpCloseTime       = "22:15";  // Close open trades at (see CloseMode)
input ENUM_CLOSE_MODE InpCloseMode = CLOSE_DAILY; // When CloseTime applies

input group "=== 2. Entry ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_STOP; // Entry mode
input ENUM_DIRECTION  InpDirection = DIR_BOTH;   // Direction
input ENUM_TIMEFRAMES InpConfirmTF = PERIOD_M5;  // Candle for CLOSE / RETEST modes
input double InpBuffer_USD      = 0.00;     // Entry this far beyond the level
input double InpMaxSlip_USD     = 0.50;     // STOP-LIMIT: max fill distance past the level
input double InpMaxChase_USD    = 3.00;     // CLOSE/RETEST: ignore closes further than this past the level (0 = off)
input double InpMaxSpread_USD   = 0.60;     // Wait while the spread is wider than this

input group "=== 3. Exit (USD price distance: 5.00 = $5 gold move) ==="
input double InpSL_USD          = 5.00;     // Stop loss distance
input double InpRR              = 2.0;      // Take profit = SL x this (0 = no TP)
input double InpBE_R            = 1.0;      // Move SL to entry at this many R in profit (0 = off)

input group "=== 4. Filters ==="
input bool   InpTradeMon        = true;     // Trade Monday
input bool   InpTradeTue        = true;     // Trade Tuesday
input bool   InpTradeWed        = true;     // Trade Wednesday
input bool   InpTradeThu        = true;     // Trade Thursday
input bool   InpTradeFri        = true;     // Trade Friday
input string InpNoTrade1        = "";       // No-trade window 1, HH:MM-HH:MM (e.g. 15:15-16:00 = US data)
input string InpNoTrade2        = "";       // No-trade window 2, HH:MM-HH:MM
input bool   InpWindowCancel    = true;     // In a window: delete pending orders (re-placed after it)
input bool   InpWindowClose     = false;    // In a window: also close open trades
input string InpNoTradeDates    = "";       // Skip whole days, yyyy.mm.dd comma-separated (NFP, CPI, FOMC...)
input double InpMinLevelRange_USD = 0.0;    // Skip a setup if high-low is smaller than this (0 = off)
input double InpMaxLevelRange_USD = 0.0;    // Skip a setup if high-low is larger than this (0 = off)

input group "=== 5. Risk ==="
input double InpRiskPct         = 1.0;      // Risk % of balance per trade
input int    InpMaxTradesDay    = 2;        // Max trades per day (both setups together)
input double InpMaxDailyLossPct = 2.5;      // Close all + stop for the day at this loss % (0 = off)
input ulong  InpMagic           = 700000;   // Magic base (A = +1, B = +2)

input group "=== 6. Optimisation: Custom max (Strategy Tester only) ==="
input ENUM_SCORE InpScore       = SCORE_ROBUST; // What "Custom max" maximises
input int    InpMinTrades       = 100;      // Score 0 below this many trades
input double InpScoreMaxDD      = 10.0;     // Score 0 if max equity DD % is above this (0 = off)
input double InpScoreWorstR     = 3.0;      // Score 0 if any trade lost more than this many R (0 = off)

#define SET_PDH   0
#define SET_RANGE 1

CTrade   g_trade;
ulong    g_magic[2];
string   g_name[2] = {"PDH", "RANGE"};
int      g_tPDH, g_tRangeStart, g_tRangeEnd, g_tTradeEnd, g_tClose;   // minutes after server midnight
int      g_w1s = -1, g_w1e = -1, g_w2s = -1, g_w2e = -1;              // no-trade windows
datetime g_day         = 0;
int      g_closeToday  = -1;   // effective close minute today (-1 = none)
bool     g_used[2];            // setup placed / traded - not re-tried until re-armed
bool     g_filled[2];          // setup produced a trade today
bool     g_spreadLog[2];
bool     g_levelLog[2];
bool     g_levelOk[2];
datetime g_lastBar[2];
bool     g_dayBlocked  = false;
bool     g_halted      = false;
bool     g_stopLimitOk = true;
int      g_tradesToday = 0;
double   g_dayStartBal = 0;
bool     g_recount     = true;
double   g_rangeHi     = 0, g_rangeLo = 0;
double   g_openRisk    = 0;    // money risked by the open trade (for R statistics)
double   g_sumR        = 0, g_worstR = 0;
int      g_nR          = 0;

//+------------------------------------------------------------------+
//|  Helpers                                                         |
//+------------------------------------------------------------------+
// "HH:MM" -> minutes after midnight. -1 = empty, -2 = invalid.
int ParseHHMM(string text)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "") return -1;
   string p[];
   if(StringSplit(s, ':', p) != 2) return -2;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59) return -2;
   return h * 60 + m;
  }

// "HH:MM-HH:MM" -> start/end minutes. Empty = off (-1). False if invalid.
bool ParseWindow(string text, int &s, int &e)
  {
   s = e = -1;
   string t = text;
   StringTrimLeft(t);
   StringTrimRight(t);
   if(t == "") return true;
   string p[];
   if(StringSplit(t, '-', p) != 2) return false;
   s = ParseHHMM(p[0]);
   e = ParseHHMM(p[1]);
   return s >= 0 && e >= 0 && s != e;
  }

bool InWindow(int m, int s, int e)
  {
   if(s < 0) return false;
   return (s < e) ? (m >= s && m < e) : (m >= s || m < e);   // may cross midnight
  }

double Norm(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

bool IsOurMagic(ulong m) { return m == g_magic[SET_PDH] || m == g_magic[SET_RANGE]; }
int  SetOf(ulong m)      { return (m == g_magic[SET_PDH]) ? SET_PDH : SET_RANGE; }
bool DirOK(bool isBuy)   { return InpDirection == DIR_BOTH || (isBuy ? InpDirection == DIR_BUY : InpDirection == DIR_SELL); }
int  ActiveFrom(int s)   { return (s == SET_PDH) ? g_tPDH : g_tRangeEnd; }

int OurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         IsOurMagic((ulong)PositionGetInteger(POSITION_MAGIC))) n++;
   return n;
  }

// Deletes our pending orders (only those placed before olderThan, if given).
// Returns a bit mask of the setups that lost an order (bit 0 = PDH, bit 1 = RANGE).
int DeletePendings(string why, datetime olderThan = 0)
  {
   int mask = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(!IsOurMagic(mg)) continue;
      if(olderThan > 0 && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= olderThan) continue;
      g_trade.SetExpertMagicNumber(mg);
      if(g_trade.OrderDelete(t))
        {
         mask |= 1 << SetOf(mg);
         PrintFormat("Pending #%I64u deleted (%s)", t, why);
        }
      else PrintFormat("Pending #%I64u delete FAILED (%s): %s", t, why, g_trade.ResultRetcodeDescription());
     }
   return mask;
  }

// Deletes pendings; a setup that has not traded today may be placed again later.
void CancelAndRearm(string why)
  {
   int mask = DeletePendings(why);
   for(int s = 0; s < 2; s++)
      if((mask & (1 << s)) != 0 && !g_filled[s]) g_used[s] = false;
  }

void ClosePositions(string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg)) continue;
      g_trade.SetExpertMagicNumber(mg);
      if(g_trade.PositionClose(t)) PrintFormat("Position #%I64u closed (%s)", t, why);
      else PrintFormat("Position #%I64u close FAILED (%s): %s", t, why, g_trade.ResultRetcodeDescription());
     }
  }

bool SpreadOK(int s)
  {
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(spread <= InpMaxSpread_USD) return true;
   if(!g_spreadLog[s])
     {
      PrintFormat("[%s] waiting: spread $%.2f > max $%.2f", g_name[s], spread, InpMaxSpread_USD);
      g_spreadLog[s] = true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  Day state (rebuilt from the account, so restarts are safe)       |
//+------------------------------------------------------------------+
// Trades taken today (total and per setup) and the balance at the start of the day.
void RecountToday()
  {
   if(!HistorySelect(g_day, TimeCurrent() + 60)) return;   // retried next tick
   g_recount     = false;
   g_tradesToday = 0;
   g_filled[SET_PDH] = g_filled[SET_RANGE] = false;
   double closed = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      closed += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                HistoryDealGetDouble(d, DEAL_COMMISSION);
      ulong mg = (ulong)HistoryDealGetInteger(d, DEAL_MAGIC);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN &&
         HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol && IsOurMagic(mg))
        {
         g_tradesToday++;
         g_filled[SetOf(mg)] = true;
        }
     }
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - closed;
  }

// A setup is used if it already traded today or still has a live order.
void RecoverUsed()
  {
   for(int s = 0; s < 2; s++) g_used[s] = g_filled[s];
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(IsOurMagic(mg) && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= g_day) g_used[SetOf(mg)] = true;
     }
  }

// Last minute of today's trade session from the symbol specification (1440 if unknown).
int SessionEndMin(int dow)
  {
   datetime from, to;
   int end = -1;
   for(int i = 0; i < 10 && SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)dow, i, from, to); i++)
      end = (int)MathMax(end, (long)to / 60);
   return (end <= 0) ? 1440 : end;
  }

void NewDay(datetime day)
  {
   g_day     = day;
   g_halted  = false;
   g_rangeHi = 0;
   g_rangeLo = 0;
   for(int s = 0; s < 2; s++) { g_spreadLog[s] = false; g_levelLog[s] = false; g_levelOk[s] = false; }
   DeletePendings("left over from a previous day", day);
   g_recount = true;
   RecountToday();
   RecoverUsed();

   MqlDateTime dt;
   TimeToStruct(day, dt);
   bool dayOn[7];
   dayOn[0] = false; dayOn[1] = InpTradeMon; dayOn[2] = InpTradeTue; dayOn[3] = InpTradeWed;
   dayOn[4] = InpTradeThu; dayOn[5] = InpTradeFri; dayOn[6] = false;
   string date = TimeToString(day, TIME_DATE);
   bool newsDay = (InpNoTradeDates != "" && StringFind(InpNoTradeDates, date) >= 0);
   g_dayBlocked = !dayOn[dt.day_of_week] || newsDay;

   // Yesterday's close time was due but trades are still open: the market closed early
   // (holiday) before the close tick arrived - close them now.
   bool missedClose = (g_closeToday >= 0 && OurPositions() > 0);

   // Force-close time for today: per CloseMode, never later than 5 min before the session ends.
   g_closeToday = -1;
   if(g_tClose >= 0 && (InpCloseMode == CLOSE_DAILY || (InpCloseMode == CLOSE_FRIDAY && dt.day_of_week == 5)))
     {
      int sessEnd  = SessionEndMin(dt.day_of_week);
      g_closeToday = (int)MathMin(g_tClose, sessEnd - 5);
      if(g_closeToday < g_tClose)
         PrintFormat("NOTE: trade session ends %02d:%02d - closing at %02d:%02d instead of %s",
                     sessEnd / 60, sessEnd % 60, g_closeToday / 60, g_closeToday % 60, InpCloseTime);
     }

   if(missedClose) ClosePositions("close time was missed - market closed early");

   PrintFormat("=== %s | trades today=%d | PDH %s | RANGE %s%s", date, g_tradesToday,
               g_used[SET_PDH] ? "used" : "waiting", g_used[SET_RANGE] ? "used" : "waiting",
               g_dayBlocked ? (newsDay ? " | NO-TRADE DATE" : " | weekday switched off") : "");
  }

//+------------------------------------------------------------------+
//|  Levels                                                          |
//+------------------------------------------------------------------+
bool GetPDH(double &hi, double &lo)
  {
   MqlRates r[];
   if(CopyRates(_Symbol, PERIOD_D1, 0, 2, r) < 2) return false;
   if(r[1].time != g_day) return false;   // today's D1 bar not built yet (r[0] = previous day)
   hi = r[0].high;
   lo = r[0].low;
   return hi > lo;
  }

bool GetRange(double &hi, double &lo)
  {
   if(g_rangeHi <= 0)
     {
      MqlRates r[];
      int n = CopyRates(_Symbol, PERIOD_M1, g_day + g_tRangeStart * 60, g_day + g_tRangeEnd * 60 - 1, r);
      if(n <= 0) return false;
      double h = r[0].high, l = r[0].low;
      for(int i = 1; i < n; i++) { h = MathMax(h, r[i].high); l = MathMin(l, r[i].low); }
      if(h <= l) return false;
      g_rangeHi = h;
      g_rangeLo = l;
     }
   hi = g_rangeHi;
   lo = g_rangeLo;
   return true;
  }

void DrawLevel(string name, datetime t1, datetime t2, double price, color clr)
  {
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

// Levels for setup s, checked against the level-size filter (logged and drawn once per day).
bool GetLevels(int s, double &hi, double &lo)
  {
   if(!(s == SET_PDH ? GetPDH(hi, lo) : GetRange(hi, lo))) return false;
   if(!g_levelLog[s])
     {
      g_levelLog[s] = true;
      double size = hi - lo;
      g_levelOk[s] = !((InpMinLevelRange_USD > 0 && size < InpMinLevelRange_USD) ||
                       (InpMaxLevelRange_USD > 0 && size > InpMaxLevelRange_USD));
      PrintFormat("[%s] levels high=%.*f low=%.*f size=$%.2f%s", g_name[s], _Digits, hi, _Digits, lo, size,
                  g_levelOk[s] ? "" : " -> SKIPPED by level-size filter");
      if(!MQLInfoInteger(MQL_OPTIMIZATION))
        {
         datetime t1 = g_day + (s == SET_PDH ? g_tPDH : g_tRangeStart) * 60, t2 = g_day + g_tTradeEnd * 60;
         DrawLevel(g_name[s] + "_H_" + TimeToString(g_day, TIME_DATE), t1, t2, hi, s == SET_PDH ? clrDodgerBlue : clrLime);
         DrawLevel(g_name[s] + "_L_" + TimeToString(g_day, TIME_DATE), t1, t2, lo, s == SET_PDH ? clrOrangeRed : clrYellow);
        }
     }
   return g_levelOk[s];
  }

//+------------------------------------------------------------------+
//|  Orders                                                          |
//+------------------------------------------------------------------+
// Lot from risk %: the broker computes the loss of 1 lot from entry to SL.
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
      if(vmin * lossPerLot > risk * 1.10) return 0;   // min lot would risk >10% more than planned
      lot = vmin;
     }
   lot = MathMin(lot, vmax);
   int volDigits = (int)MathMax(0, MathRound(-MathLog10(step)));
   return NormalizeDouble(lot, volDigits);
  }

// One sending path for every entry type. entry = order price (ignored for market);
// limitPx = limit price of a stop-limit (0 otherwise). SL/TP are measured from entry,
// lots from the worst possible fill.
bool SendOrder(int s, ENUM_ORDER_TYPE type, double entry, double limitPx = 0)
  {
   bool isBuy  = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT ||
                  type == ORDER_TYPE_BUY_STOP_LIMIT);
   bool market = (type == ORDER_TYPE_BUY || type == ORDER_TYPE_SELL);
   if(market) entry = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl  = Norm(isBuy ? entry - InpSL_USD : entry + InpSL_USD);
   double tp  = (InpRR > 0) ? Norm(isBuy ? entry + InpSL_USD * InpRR : entry - InpSL_USD * InpRR) : 0.0;
   double lot = CalcLot(isBuy, limitPx > 0 ? limitPx : entry, sl);
   string what = StringSubstr(EnumToString(type), 11);   // "BUY_STOP", "SELL_LIMIT", ...
   if(lot <= 0)
     {
      PrintFormat("[%s] %s NOT placed: lot calculation failed or min lot is too risky", g_name[s], what);
      return false;
     }
   g_trade.SetExpertMagicNumber(g_magic[s]);
   string cmt = g_name[s] + (isBuy ? "_B" : "_S");
   bool ok = market ? (isBuy ? g_trade.Buy(lot, _Symbol, 0.0, sl, tp, cmt) : g_trade.Sell(lot, _Symbol, 0.0, sl, tp, cmt))
                    : g_trade.OrderOpen(_Symbol, type, lot, limitPx, entry, sl, tp, ORDER_TIME_GTC, 0, cmt);
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
     {
      PrintFormat("[%s] %s %.2f lot @ %.*f%s  SL %.*f  TP %.*f", g_name[s], what, lot, _Digits, entry,
                  limitPx > 0 ? StringFormat(" (limit %.*f)", _Digits, limitPx) : "", _Digits, sl, _Digits, tp);
      return true;
     }
   PrintFormat("[%s] %s REJECTED: %u %s", g_name[s], what, rc, g_trade.ResultRetcodeDescription());
   return false;
  }

// STOP / STOP-LIMIT modes: the straddle is placed once (re-placed only after a re-arm).
void PlaceStraddle(int s, double hi, double lo)
  {
   if(!SpreadOK(s)) return;
   g_used[s] = true;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   bool   useStopLimit = (InpEntryMode == ENTRY_STOP_LIMIT && g_stopLimitOk);
   double buyAt   = Norm(hi + InpBuffer_USD);
   double sellAt  = Norm(lo - InpBuffer_USD);

   if(!DirOK(true)) { }
   else if(buyAt - ask > minDist)
      SendOrder(s, useStopLimit ? ORDER_TYPE_BUY_STOP_LIMIT : ORDER_TYPE_BUY_STOP, buyAt, useStopLimit ? Norm(buyAt + InpMaxSlip_USD) : 0);
   else PrintFormat("[%s] BUY skipped: ask %.*f is already at/above %.*f", g_name[s], _Digits, ask, _Digits, buyAt);

   if(!DirOK(false)) { }
   else if(bid - sellAt > minDist)
      SendOrder(s, useStopLimit ? ORDER_TYPE_SELL_STOP_LIMIT : ORDER_TYPE_SELL_STOP, sellAt, useStopLimit ? Norm(sellAt - InpMaxSlip_USD) : 0);
   else PrintFormat("[%s] SELL skipped: bid %.*f is already at/below %.*f", g_name[s], _Digits, bid, _Digits, sellAt);
  }

// CLOSE / RETEST modes: once per new ConfirmTF candle, check whether the last closed
// candle closed beyond a level.
void CheckConfirm(int s, double hi, double lo)
  {
   datetime bar = iTime(_Symbol, InpConfirmTF, 0);
   if(bar <= 0 || bar == g_lastBar[s]) return;
   bool firstLook = (g_lastBar[s] == 0);
   g_lastBar[s] = bar;
   if(firstLook) return;                                         // never act on a stale candle after a (re)start
   if(iTime(_Symbol, InpConfirmTF, 1) < g_day + ActiveFrom(s) * 60) return;   // candle began before the setup was active

   double c = iClose(_Symbol, InpConfirmTF, 1);
   bool isBuy = false;
   if(c > hi + InpBuffer_USD && DirOK(true))       isBuy = true;
   else if(c < lo - InpBuffer_USD && DirOK(false)) isBuy = false;
   else return;

   double level  = Norm(isBuy ? hi + InpBuffer_USD : lo - InpBuffer_USD);
   double beyond = isBuy ? c - level : level - c;
   if(InpMaxChase_USD > 0 && beyond > InpMaxChase_USD)
     {
      PrintFormat("[%s] %s close %.*f is $%.2f past the level (> MaxChase $%.2f) - ignored", g_name[s],
                  isBuy ? "BUY" : "SELL", _Digits, c, beyond, InpMaxChase_USD);
      return;
     }
   if(!SpreadOK(s)) return;
   PrintFormat("[%s] CONFIRMED %s: %s candle closed %.*f beyond %.*f", g_name[s], isBuy ? "BUY" : "SELL",
               StringSubstr(EnumToString(InpConfirmTF), 7), _Digits, c, _Digits, level);

   bool sent;
   if(InpEntryMode == ENTRY_CLOSE)
      sent = SendOrder(s, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, 0);
   else
     {
      double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      double px = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool roomForLimit = isBuy ? (px - level > minDist) : (level - px > minDist);
      sent = roomForLimit ? SendOrder(s, isBuy ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT, level)
                          : SendOrder(s, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, 0);   // already back at the level
     }
   if(sent) g_used[s] = true;
  }

// Moves SL to the entry price once the trade is InpBE_R x SL in profit.
void ManageBreakeven()
  {
   if(InpBE_R <= 0) return;
   double trigger = InpBE_R * InpSL_USD;
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg)) continue;
      bool   buy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double be   = Norm(open);
      if(buy ? (bid - open < trigger || sl >= be || bid - be <= minDist)
             : (open - ask < trigger || (sl > 0 && sl <= be) || be - ask <= minDist)) continue;
      g_trade.SetExpertMagicNumber(mg);
      if(g_trade.PositionModify(t, be, tp)) PrintFormat("Position #%I64u SL -> breakeven %.*f", t, _Digits, be);
     }
  }

//+------------------------------------------------------------------+
//|  Events                                                          |
//+------------------------------------------------------------------+
int Fail(string why)
  {
   Print("INVALID INPUT: ", why);
   Alert("XAUUSD Simple Breakout - invalid input: ", why);
   return INIT_PARAMETERS_INCORRECT;
  }

int OnInit()
  {
   g_tPDH        = ParseHHMM(InpPDHStart);
   g_tRangeStart = ParseHHMM(InpRangeStart);
   g_tRangeEnd   = ParseHHMM(InpRangeEnd);
   g_tTradeEnd   = ParseHHMM(InpTradeEnd);
   g_tClose      = ParseHHMM(InpCloseTime);
   if(g_tPDH < 0 || g_tRangeStart < 0 || g_tRangeEnd < 0 || g_tTradeEnd < 0 || g_tClose == -2)
      return Fail("times must be HH:MM, 00:00-23:59");
   if(!ParseWindow(InpNoTrade1, g_w1s, g_w1e) || !ParseWindow(InpNoTrade2, g_w2s, g_w2e))
      return Fail("no-trade windows must be HH:MM-HH:MM (or empty)");
   if(!InpUsePDH && !InpUseRange)                 return Fail("both setups are off");
   if(InpUsePDH && g_tPDH >= g_tTradeEnd)         return Fail("PDHStart must be before TradeEnd");
   if(InpUseRange && !(g_tRangeStart < g_tRangeEnd && g_tRangeEnd < g_tTradeEnd))
      return Fail("need RangeStart < RangeEnd < TradeEnd");
   if(g_tClose >= 0 && g_tClose < g_tTradeEnd)    return Fail("CloseTime must be at or after TradeEnd");
   if(InpSL_USD <= 0 || InpRR < 0 || InpBE_R < 0 || InpBuffer_USD < 0 || InpMaxSpread_USD <= 0 ||
      InpMaxSlip_USD < 0 || InpMaxChase_USD < 0 || InpMinLevelRange_USD < 0 || InpMaxLevelRange_USD < 0)
      return Fail("SL / spread must be > 0; RR, BE, buffer, slip, chase, level filters must be >= 0");
   if(InpMaxLevelRange_USD > 0 && InpMaxLevelRange_USD <= InpMinLevelRange_USD)
      return Fail("MaxLevelRange must be above MinLevelRange");
   if(InpRiskPct <= 0 || InpRiskPct > 5)          return Fail("RiskPct must be > 0 and <= 5");
   if(InpMaxTradesDay < 1)                        return Fail("MaxTradesDay must be >= 1");
   if(InpMinTrades < 0 || InpScoreMaxDD < 0 || InpScoreWorstR < 0) return Fail("score filters must be >= 0");

   if(InpBE_R > 0 && InpRR > 0 && InpBE_R >= InpRR)
      PrintFormat("WARNING: breakeven at %.1fR is at/after the TP at %.1fR - breakeven will never trigger", InpBE_R, InpRR);

   g_magic[SET_PDH]   = InpMagic + 1;
   g_magic[SET_RANGE] = InpMagic + 2;
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints((ulong)MathMax(1, MathRound(0.50 / _Point)));   // $0.50 market-order slippage
   g_lastBar[SET_PDH] = g_lastBar[SET_RANGE] = 0;
   g_sumR = 0; g_worstR = 0; g_nR = 0; g_openRisk = 0;

   g_stopLimitOk = (SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE) & SYMBOL_ORDER_STOP_LIMIT) != 0;
   if(InpEntryMode == ENTRY_STOP_LIMIT && !g_stopLimitOk)
      Print("WARNING: broker does not allow stop-limit orders on this symbol - using plain stop orders");

   PrintFormat("%s digits=%d | entry %s | SL $%.2f = %.0f points | TP %s | BE %s | risk %.2f%% | max %d trades/day",
               _Symbol, _Digits, EnumToString(InpEntryMode), InpSL_USD, InpSL_USD / _Point,
               InpRR > 0 ? StringFormat("$%.2f", InpSL_USD * InpRR) : "off",
               InpBE_R > 0 ? StringFormat("at +$%.2f", InpSL_USD * InpBE_R) : "off", InpRiskPct, InpMaxTradesDay);
   PrintFormat("Server times: PDH from %s | range %s-%s | entries until %s | close %s | no-trade %s %s",
               InpPDHStart, InpRangeStart, InpRangeEnd, InpTradeEnd, (g_tClose < 0 || InpCloseMode == CLOSE_NEVER) ? "never" :
               (InpCloseMode == CLOSE_FRIDAY ? InpCloseTime + " Fridays" : InpCloseTime),
               InpNoTrade1 == "" ? "-" : InpNoTrade1, InpNoTrade2);
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - (long)now % 86400);   // server midnight
   if(day != g_day) NewDay(day);
   if(g_recount) RecountToday();
   int mins = (int)((now - day) / 60);

   ManageBreakeven();

   //--- daily loss stop (closed + open P/L since the start of the day)
   if(!g_halted && InpMaxDailyLossPct > 0 && g_dayStartBal > 0)
     {
      double pct = (AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBal) / g_dayStartBal * 100.0;
      if(pct <= -InpMaxDailyLossPct)
        {
         g_halted = true;
         PrintFormat("DAILY LOSS STOP: %.2f%% <= -%.2f%% - closing everything until tomorrow", pct, InpMaxDailyLossPct);
        }
     }
   if(g_halted)
     {
      DeletePendings("daily loss stop");
      ClosePositions("daily loss stop");
      return;
     }

   //--- one trade at a time (also cancels the other side of the straddle)
   bool inTrade = OurPositions() > 0;
   if(inTrade) CancelAndRearm("a trade is open");
   if(g_tradesToday >= InpMaxTradesDay) DeletePendings("max trades for today reached");

   //--- no-trade windows (news)
   bool inWindow = InWindow(mins, g_w1s, g_w1e) || InWindow(mins, g_w2s, g_w2e);
   if(inWindow)
     {
      if(InpWindowCancel) CancelAndRearm("no-trade window");
      if(InpWindowClose && inTrade) ClosePositions("no-trade window");
     }

   //--- time limits
   if(mins >= g_tTradeEnd) DeletePendings("trade window ended");
   if(g_closeToday >= 0 && mins >= g_closeToday) ClosePositions("close time");

   //--- new entries
   if(inTrade || inWindow || g_dayBlocked || mins >= g_tTradeEnd || g_tradesToday >= InpMaxTradesDay) return;

   for(int s = 0; s < 2; s++)
     {
      if(!(s == SET_PDH ? InpUsePDH : InpUseRange) || g_used[s] || g_filled[s] || mins < ActiveFrom(s)) continue;
      double hi, lo;
      if(!GetLevels(s, hi, lo)) continue;
      if(InpEntryMode == ENTRY_STOP || InpEntryMode == ENTRY_STOP_LIMIT) PlaceStraddle(s, hi, lo);
      else CheckConfirm(s, hi, lo);
     }
  }

// Day counters + R statistics for the Custom max score.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   g_recount = true;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol ||
      !IsOurMagic((ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC))) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
      g_openRisk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   else if((entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) && g_openRisk > 0)
     {
      double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                 HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      double r = p / g_openRisk;
      g_sumR  += r;
      g_nR++;
      g_worstR = MathMin(g_worstR, r);
      PrintFormat("CLOSED %s %+.2f = %+.2fR", HistoryDealGetString(trans.deal, DEAL_COMMENT), p, r);
     }
  }

//+------------------------------------------------------------------+
//|  Custom max - choose the target with InpScore.                    |
//|  Any pass with too few trades, a loss, too deep a drawdown or a   |
//|  single trade worse than -InpScoreWorstR scores 0, so the         |
//|  optimiser cannot pick lucky or spike-exposed settings.           |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double ddPct  = TesterStatistics(STAT_EQUITY_DDREL_PERCENT);
   double dep    = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double avgR   = (g_nR > 0) ? g_sumR / g_nR : 0;

   string gate = "";
   if(trades < InpMinTrades)                             gate = StringFormat("only %.0f trades", trades);
   else if(profit <= 0)                                  gate = "not profitable";
   else if(InpScoreMaxDD > 0 && ddPct > InpScoreMaxDD)   gate = StringFormat("DD %.1f%% > %.1f%%", ddPct, InpScoreMaxDD);
   else if(InpScoreWorstR > 0 && g_worstR < -InpScoreWorstR)
                                                         gate = StringFormat("worst trade %.1fR", g_worstR);
   double score = 0;
   if(gate == "")
      switch(InpScore)
        {
         case SCORE_PF:       score = pf; break;
         case SCORE_RECOVERY: score = TesterStatistics(STAT_RECOVERY_FACTOR); break;
         case SCORE_PROFIT:   score = profit; break;
         case SCORE_SHARPE:   score = TesterStatistics(STAT_SHARPE_RATIO); break;
         case SCORE_AVG_R:    score = avgR; break;
         case SCORE_RET_DD:   score = (dep > 0) ? (profit / dep * 100.0) / MathMax(ddPct, 1.0) : 0; break;
         default:             score = (pf > 1.0) ? (pf - 1.0) * MathSqrt(trades) / MathMax(ddPct, 1.0) : 0; break;
        }
   PrintFormat("SCORE %s = %.4f | trades %.0f PF %.2f DD %.1f%% avgR %.2f worstR %.2f%s", EnumToString(InpScore),
               score, trades, pf, ddPct, avgR, g_worstR, gate == "" ? "" : " | 0 because " + gate);
   return score;
  }
//+------------------------------------------------------------------+
