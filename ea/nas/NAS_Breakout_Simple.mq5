//+------------------------------------------------------------------+
//|                                        NAS_Breakout_Simple.mq5    |
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
//+------------------------------------------------------------------+
#property copyright "NAS Breakout Simple"
#property version   "1.26"
#property description "PDH/PDL breakout + 4H straddle for Nasdaq 100 CFDs. every level traded."

#include <Trade\Trade.mqh>

input group "=== Setups ==="
input bool   InpUsePDH     = true;           // Trade the previous-day high / low breakout
input bool   InpUseH4      = true;           // Trade the 4H candle straddle
input string InpWindow     = "00:00-23:55";  // Trading window, server time HH:MM-HH:MM

input group "=== Exit (index points) ==="
input double InpSL         = 50.0;           // Stop loss
input bool   InpUseTP      = false;          // Use fixed take profit (false = TP = SL x RR)
input double InpFixedTP    = 100.0;          // Fixed take profit in points
input double InpRR         = 2.0;            // Take profit = SL x this when fixed TP is off (0 = no take profit)
input bool   InpUseBE      = false;          // Use breakeven
input double InpBEAt       = 5.0;            // Breakeven: move SL to entry +1 at this many points profit
input bool   InpUseTrail   = false;          // Use trailing stop
input double InpTrailAt    = 5.0;            // Trailing starts at this many points profit
input double InpTrailDist  = 40.0;           // Trailing: SL stays this many points behind price

input group "=== Risk ==="
input double InpRiskPct    = 0.5;            // Risk per trade, % of balance
input int    InpMaxTrades  = 0;              // Maximum trades per day, both setups together (0 = no limit; when reached, remaining orders are deleted)
input ulong  InpMagic      = 930001;         // Magic number (PDH = this, 4H = this + 1)

//--- fixed rules (kept out of the inputs on purpose)
#define MIN_DAY_HOURS   6.0     // daily candles shorter than this (Sunday stubs) are skipped
#define MAX_RANGE_PCT   10.0    // a level range above 10% of price = broken history, skipped
#define BE_LOCK         1.0     // breakeven puts the SL this many points past entry
#define MIN_MODIFY      1.0     // move the SL only when it improves by at least this

CTrade   trade;
int      g_winStart = 0, g_winEnd = 0, g_dayEnd = 0;
datetime g_day = 0, g_h4 = 0;
double   g_pdh = 0, g_pdl = 0;
bool     g_pdhOk = false, g_pdhDone = false;
int      g_tradesToday = 0;
string   g_status = "";

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
      if(trade.OrderDelete(t)) PrintFormat("Order #%I64u deleted (%s)", t, why);
     }
  }

void CloseAll(const string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && Ours(PositionGetInteger(POSITION_MAGIC), PositionGetString(POSITION_SYMBOL)) && trade.PositionClose(t))
         PrintFormat("Position #%I64u closed (%s)", t, why);
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

// True when hi/lo look like real prices (protects against broken history).
bool LevelsSane(const double hi, const double lo)
  {
   return lo > 0.0 && hi > lo && (hi - lo) <= hi * MAX_RANGE_PCT / 100.0;
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
      if(lots > maxLots) { PrintFormat("Lot reduced %.2f -> %.2f (margin)", lots, maxLots); lots = maxLots; }
     }
   if(lots < vmin) { PrintFormat("Skipped: lot %.4f below broker minimum %.2f (risk/margin too small)", lots, vmin); return 0.0; }
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
      PrintFormat("[%s] %s skipped: price is already at/through %.*f", tag, side, _Digits, entry);
      return;
     }
   if(InpSL <= gap) { PrintFormat("[%s] SL %g is inside the broker minimum %.2f", tag, InpSL, gap); return; }
   double sl  = Norm(buy ? entry - InpSL : entry + InpSL);
   double tpDist = (InpUseTP && InpFixedTP > 0.0) ? InpFixedTP : InpSL * InpRR;   // fixed TP wins over RR
   double tp  = (tpDist > 0.0) ? Norm(buy ? entry + tpDist : entry - tpDist) : 0.0;
   if(sl <= 0.0 || tp < 0.0) return;
   double lot = LotSize(buy, entry, sl);
   if(lot <= 0.0) return;
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
   g_day = today;
   g_pdhDone = false;
   g_tradesToday = 0;
   g_dayEnd = (int)MathMin(g_winEnd, SessionEnd(Weekday(today)) - 5);
   g_pdhOk = PrevDay(today, g_pdh, g_pdl) && LevelsSane(g_pdh, g_pdl);
   if(g_pdhOk)
     {
      PrintFormat("=== %s  PDH %.*f  PDL %.*f  (range %.0f)  | close at %02d:%02d", TimeToString(today, TIME_DATE),
                  _Digits, g_pdh, _Digits, g_pdl, g_pdh - g_pdl, g_dayEnd / 60, g_dayEnd % 60);
      HLine("PDH", g_pdh, clrDodgerBlue);
      HLine("PDL", g_pdl, clrOrangeRed);
     }
   else PrintFormat("=== %s  no valid PDH/PDL (holiday or broken history) - PDH setup off today", TimeToString(today, TIME_DATE));
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
         PrintFormat("SL %.*f -> %.*f (profit %.1f points)", _Digits, sl, _Digits, target, profit);
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
   if(err != "") { Print("INVALID INPUT: ", err); return INIT_PARAMETERS_INCORRECT; }

   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(200);
   PrintFormat("NAS Breakout Simple on %s | PDH %s | 4H %s | window %s | SL %g %s | BE %s | trail %s | risk %.2f%% | max trades/day %d (0 = no limit) | broker min distance %.2f",
               _Symbol, InpUsePDH ? "on" : "off", InpUseH4 ? "on" : "off", InpWindow, InpSL,
               InpUseTP ? StringFormat("TP %g (fixed)", InpFixedTP) : InpRR > 0.0 ? StringFormat("TP = %g x SL", InpRR) : "no TP",
               InpUseBE ? StringFormat("%g", InpBEAt) : "off",
               InpUseTrail ? StringFormat("%g/%g", InpTrailAt, InpTrailDist) : "off", InpRiskPct, InpMaxTrades, BrokerMinDist());
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason) { Comment(""); }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime today = DayStart(now);
   int mins = MinuteOf(now);
   if(today != g_day) NewDay(today);

   ManageStops();

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
   else
     {
      // 1) PDH / PDL - once a day
      if(InpUsePDH && !g_pdhDone && g_pdhOk)
        {
         g_pdhDone = true;
         Straddle(g_pdh, g_pdl, InpMagic, "PDH");
        }
      // 2) 4H straddle - as soon as each new 4H candle opens: old 4H orders out, new pair in
      datetime h4 = iTime(_Symbol, PERIOD_H4, 0);
      if(InpUseH4 && h4 > 0 && h4 != g_h4)
        {
         g_h4 = h4;
         DeleteOrders(InpMagic + 1, "new 4H candle - old 4H order replaced");
         double hi = iHigh(_Symbol, PERIOD_H4, 1), lo = iLow(_Symbol, PERIOD_H4, 1);
         if(hi > 0.0 && lo > 0.0)
           {
            HLine("H4 high", hi, clrLime);
            HLine("H4 low", lo, clrMagenta);
            Straddle(hi, lo, InpMagic + 1, "H4");
           }
        }
      g_status = StringFormat("%d open, waiting for breakouts", CountPositions());
     }

   if(!MQLInfoInteger(MQL_OPTIMIZATION))
      Comment(StringFormat("NAS Breakout Simple | %s\nPDH %.*f  PDL %.*f | trades today %d | %s",
                           _Symbol, _Digits, g_pdh, _Digits, g_pdl, g_tradesToday, g_status));
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
// SL, TP and trail distance: start 2, step 2 whatever the Inputs table shows.
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
   Range("InpTrailDist",  2.0, 2.0, 150.0);
   Print("Optimisation ranges: SL / TP / trail distance start 2, step 2 (RR 0..5 step 0.5); breakeven and trail start use the Inputs table");
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
