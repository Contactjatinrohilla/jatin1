//+------------------------------------------------------------------+
//|              XAUUSD_Simple_Breakout.mq5   v7.00                   |
//|                                                                  |
//|  A deliberately small rewrite of the PDH/PDL + London idea.       |
//|                                                                  |
//|  SETUP A  Previous-day high/low (PDH/PDL)                        |
//|           From InpPDHStart: BUY STOP above PDH, SELL STOP below   |
//|           PDL.                                                   |
//|  SETUP B  Session range (default = London 08:00-16:00 London time)|
//|           Range = highest high / lowest low of the M1 bars from   |
//|           InpRangeStart to InpRangeEnd. At InpRangeEnd: BUY STOP  |
//|           above the range high, SELL STOP below the range low.    |
//|                                                                  |
//|  RULES (both setups)                                             |
//|   - Each setup is placed at most once per day.                    |
//|   - ONE trade at a time: as soon as any order fills, every other  |
//|     pending order is deleted (this is also the OCO of a straddle).|
//|   - Max InpMaxTradesDay trades per day.                           |
//|   - Unfilled orders are deleted at InpTradeEnd; open trades are   |
//|     closed at InpCloseTime (before the daily break / weekend).    |
//|   - Daily loss stop on closed + open P/L.                         |
//|   - Optional breakeven at +InpBE_R. No trailing stop.             |
//|                                                                  |
//|  UNITS: every distance is in USD of gold price (5.00 = a $5 move  |
//|  in XAUUSD), so 2-digit and 3-digit symbols behave identically.   |
//|  TIMES: SERVER time (the clock in Market Watch and on the chart). |
//|  On a UTC+2 winter / UTC+3 summer server, London 08:00 = 10:00    |
//|  server all year. See docs/GUIDE.md for the full time table.      |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout v7.00"
#property version   "7.00"

#include <Trade\Trade.mqh>

input group "=== 1. Setups (SERVER time, HH:MM) ==="
input bool   InpUsePDH          = true;     // Setup A: previous-day high/low breakout
input string InpPDHStart        = "01:15";  // A: place orders from
input bool   InpUseRange        = true;     // Setup B: session-range breakout
input string InpRangeStart      = "10:00";  // B: range start (10:00 server = London 08:00)
input string InpRangeEnd        = "18:00";  // B: range end = orders placed (18:00 server = London 16:00)
input string InpTradeEnd        = "22:30";  // Delete unfilled orders at
input string InpCloseTime       = "23:30";  // Close open trades at ("" = never)

input group "=== 2. Trade (USD price distance: 5.00 = $5 gold move) ==="
input double InpSL_USD          = 5.00;     // Stop loss distance
input double InpRR              = 2.0;      // Take profit = SL x this (0 = no TP)
input double InpBE_R            = 1.0;      // Move SL to entry at this many R in profit (0 = off)
input double InpBuffer_USD      = 0.00;     // Place stop orders this far beyond the level
input double InpMaxSpread_USD   = 0.60;     // Wait while the spread is wider than this

input group "=== 3. Risk ==="
input double InpRiskPct         = 1.0;      // Risk % of balance per trade
input int    InpMaxTradesDay    = 2;        // Max trades per day (both setups together)
input double InpMaxDailyLossPct = 2.5;      // Close all + stop for the day at this loss % (0 = off)
input ulong  InpMagic           = 700000;   // Magic base (A = +1, B = +2)

#define SET_PDH   0
#define SET_RANGE 1

CTrade   g_trade;
ulong    g_magic[2];
string   g_name[2] = {"PDH", "RANGE"};
int      g_tPDH, g_tRangeStart, g_tRangeEnd, g_tTradeEnd, g_tClose;   // minutes after server midnight
datetime g_day         = 0;
bool     g_used[2];            // setup already placed today
bool     g_spreadLog[2];       // "waiting for spread" printed today
bool     g_halted      = false;
int      g_tradesToday = 0;
double   g_dayStartBal = 0;
bool     g_recount     = true;
double   g_rangeHi     = 0, g_rangeLo = 0;

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

double Norm(double price)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0) tick = _Point;
   return NormalizeDouble(MathRound(price / tick) * tick, _Digits);
  }

bool IsOurMagic(ulong m) { return m == g_magic[SET_PDH] || m == g_magic[SET_RANGE]; }
int  SetOf(ulong m)      { return (m == g_magic[SET_PDH]) ? SET_PDH : SET_RANGE; }

int OurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         IsOurMagic((ulong)PositionGetInteger(POSITION_MAGIC))) n++;
   return n;
  }

// Deletes our pending orders (only those placed before olderThan, if given).
void DeletePendings(string why, datetime olderThan = 0)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(!IsOurMagic(mg)) continue;
      if(olderThan > 0 && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= olderThan) continue;
      g_trade.SetExpertMagicNumber(mg);
      if(g_trade.OrderDelete(t)) PrintFormat("Pending #%I64u deleted (%s)", t, why);
      else PrintFormat("Pending #%I64u delete FAILED (%s): %s", t, why, g_trade.ResultRetcodeDescription());
     }
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

//+------------------------------------------------------------------+
//|  Day state (rebuilt from the account, so restarts are safe)       |
//+------------------------------------------------------------------+
// Trades taken today and the balance at the start of the day.
void RecountToday()
  {
   if(!HistorySelect(g_day, TimeCurrent() + 60)) return;   // retried next tick
   g_recount     = false;
   g_tradesToday = 0;
   double closed = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;
      closed += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP) +
                HistoryDealGetDouble(d, DEAL_COMMISSION);
      if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN &&
         HistoryDealGetString(d, DEAL_SYMBOL) == _Symbol &&
         IsOurMagic((ulong)HistoryDealGetInteger(d, DEAL_MAGIC)))
         g_tradesToday++;
     }
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - closed;
  }

// A setup counts as used if any of its orders was placed today.
void RecoverUsed()
  {
   g_used[SET_PDH] = g_used[SET_RANGE] = false;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(IsOurMagic(mg) && (datetime)OrderGetInteger(ORDER_TIME_SETUP) >= g_day) g_used[SetOf(mg)] = true;
     }
   if(!HistorySelect(g_day, TimeCurrent() + 60)) return;
   for(int i = 0; i < HistoryOrdersTotal(); i++)
     {
      ulong t = HistoryOrderGetTicket(i);
      if(t == 0 || HistoryOrderGetString(t, ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)HistoryOrderGetInteger(t, ORDER_MAGIC);
      if(IsOurMagic(mg) && (datetime)HistoryOrderGetInteger(t, ORDER_TIME_SETUP) >= g_day) g_used[SetOf(mg)] = true;
     }
  }

void NewDay(datetime day)
  {
   g_day     = day;
   g_halted  = false;
   g_rangeHi = 0;
   g_rangeLo = 0;
   g_spreadLog[SET_PDH] = g_spreadLog[SET_RANGE] = false;
   DeletePendings("left over from a previous day", day);
   RecoverUsed();
   g_recount = true;
   RecountToday();
   PrintFormat("=== %s | trades today=%d | PDH %s | RANGE %s", TimeToString(day, TIME_DATE), g_tradesToday,
               g_used[SET_PDH] ? "already placed" : "waiting", g_used[SET_RANGE] ? "already placed" : "waiting");
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
      PrintFormat("[RANGE] %s-%s high=%.*f low=%.*f size=$%.2f (%d M1 bars)", InpRangeStart, InpRangeEnd,
                  _Digits, h, _Digits, l, h - l, n);
     }
   hi = g_rangeHi;
   lo = g_rangeLo;
   return true;
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

bool SendStop(int s, bool isBuy, double entry)
  {
   string side = isBuy ? "BUY STOP" : "SELL STOP";
   double sl   = Norm(isBuy ? entry - InpSL_USD : entry + InpSL_USD);
   double tp   = (InpRR > 0) ? Norm(isBuy ? entry + InpSL_USD * InpRR : entry - InpSL_USD * InpRR) : 0.0;
   double lot  = CalcLot(isBuy, entry, sl);
   if(lot <= 0)
     {
      PrintFormat("[%s] %s NOT placed: lot calculation failed or min lot is too risky", g_name[s], side);
      return false;
     }
   g_trade.SetExpertMagicNumber(g_magic[s]);
   string cmt = g_name[s] + (isBuy ? "_B" : "_S");
   bool ok = isBuy ? g_trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt)
                   : g_trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, cmt);
   uint rc = g_trade.ResultRetcode();
   if(ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
     {
      PrintFormat("[%s] %s %.2f lot @ %.*f  SL %.*f  TP %.*f", g_name[s], side, lot,
                  _Digits, entry, _Digits, sl, _Digits, tp);
      return true;
     }
   PrintFormat("[%s] %s REJECTED: %u %s", g_name[s], side, rc, g_trade.ResultRetcodeDescription());
   return false;
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

// Places the straddle once. Waits (and retries next tick) only while the spread is too wide.
void PlaceSetup(int s, double hi, double lo)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask - bid > InpMaxSpread_USD)
     {
      if(!g_spreadLog[s])
        {
         PrintFormat("[%s] waiting: spread $%.2f > max $%.2f", g_name[s], ask - bid, InpMaxSpread_USD);
         g_spreadLog[s] = true;
        }
      return;
     }
   g_used[s] = true;

   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double buyAt   = Norm(hi + InpBuffer_USD);
   double sellAt  = Norm(lo - InpBuffer_USD);
   PrintFormat("[%s] levels high=%.*f low=%.*f", g_name[s], _Digits, hi, _Digits, lo);

   if(buyAt - ask > minDist) SendStop(s, true, buyAt);
   else PrintFormat("[%s] BUY skipped: ask %.*f is already at/above %.*f", g_name[s], _Digits, ask, _Digits, buyAt);

   if(bid - sellAt > minDist) SendStop(s, false, sellAt);
   else PrintFormat("[%s] SELL skipped: bid %.*f is already at/below %.*f", g_name[s], _Digits, bid, _Digits, sellAt);

   if(!MQLInfoInteger(MQL_OPTIMIZATION))
     {
      datetime t1 = g_day + (s == SET_PDH ? g_tPDH : g_tRangeStart) * 60, t2 = g_day + g_tTradeEnd * 60;
      DrawLevel(g_name[s] + "_H_" + TimeToString(g_day, TIME_DATE), t1, t2, hi, s == SET_PDH ? clrDodgerBlue : clrLime);
      DrawLevel(g_name[s] + "_L_" + TimeToString(g_day, TIME_DATE), t1, t2, lo, s == SET_PDH ? clrOrangeRed : clrYellow);
     }
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
   if(!InpUsePDH && !InpUseRange)                 return Fail("both setups are off");
   if(InpUsePDH && g_tPDH >= g_tTradeEnd)         return Fail("PDHStart must be before TradeEnd");
   if(InpUseRange && !(g_tRangeStart < g_tRangeEnd && g_tRangeEnd < g_tTradeEnd))
      return Fail("need RangeStart < RangeEnd < TradeEnd");
   if(g_tClose >= 0 && g_tClose < g_tTradeEnd)    return Fail("CloseTime must be at or after TradeEnd");
   if(InpSL_USD <= 0 || InpRR < 0 || InpBE_R < 0 || InpBuffer_USD < 0 || InpMaxSpread_USD <= 0)
      return Fail("SL / spread must be > 0, RR / BE / buffer >= 0");
   if(InpRiskPct <= 0 || InpRiskPct > 5)          return Fail("RiskPct must be > 0 and <= 5");
   if(InpMaxTradesDay < 1)                        return Fail("MaxTradesDay must be >= 1");

   g_magic[SET_PDH]   = InpMagic + 1;
   g_magic[SET_RANGE] = InpMagic + 2;
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints((ulong)MathMax(1, MathRound(0.50 / _Point)));   // $0.50 slippage allowance

   PrintFormat("%s digits=%d point=%g | SL $%.2f = %.0f points | TP %s | BE %s | risk %.2f%% | max %d trades/day",
               _Symbol, _Digits, _Point, InpSL_USD, InpSL_USD / _Point,
               InpRR > 0 ? StringFormat("$%.2f", InpSL_USD * InpRR) : "off",
               InpBE_R > 0 ? StringFormat("at +$%.2f", InpSL_USD * InpBE_R) : "off",
               InpRiskPct, InpMaxTradesDay);
   PrintFormat("Server times: PDH from %s | range %s-%s | orders until %s | close %s",
               InpPDHStart, InpRangeStart, InpRangeEnd, InpTradeEnd, g_tClose >= 0 ? InpCloseTime : "never");
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
   if(inTrade) DeletePendings("a trade is open");
   if(g_tradesToday >= InpMaxTradesDay) DeletePendings("max trades for today reached");

   //--- time limits
   if(mins >= g_tTradeEnd) DeletePendings("trade window ended");
   if(g_tClose >= 0 && mins >= g_tClose) ClosePositions("close time");

   //--- new orders
   if(inTrade || mins >= g_tTradeEnd || g_tradesToday >= InpMaxTradesDay) return;

   double hi, lo;
   if(InpUsePDH && !g_used[SET_PDH] && mins >= g_tPDH && GetPDH(hi, lo))
      PlaceSetup(SET_PDH, hi, lo);
   if(InpUseRange && !g_used[SET_RANGE] && mins >= g_tRangeEnd && GetRange(hi, lo))
      PlaceSetup(SET_RANGE, hi, lo);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) g_recount = true;
  }
//+------------------------------------------------------------------+
