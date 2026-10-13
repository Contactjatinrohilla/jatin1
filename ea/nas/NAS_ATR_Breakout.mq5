//+------------------------------------------------------------------+
//|                                          NAS_ATR_Breakout.mq5     |
//|                                                                  |
//|  Nasdaq 100 CFD (NAS100 / US100 / USTEC / NDX100) channel        |
//|  breakout with ATR-based stop loss and take profit.               |
//|                                                                  |
//|  Entry: every time a new candle opens on the signal timeframe,   |
//|         a BUY STOP goes at the highest high and a SELL STOP at   |
//|         the lowest low of the last N closed candles (plus an      |
//|         optional ATR buffer). Unfilled orders are replaced on     |
//|         the next candle, so the levels follow the channel.        |
//|  Exits: SL = ATR x multiplier, TP = ATR x multiplier (or SL x RR),|
//|         optional breakeven and ATR trailing stop. ATR is taken    |
//|         from the last CLOSED candle of the signal timeframe, so   |
//|         stops widen in volatile markets and tighten in quiet ones.|
//|  Filter: the channel must be between min and max ATR wide - too   |
//|         tight = noise, too wide = the move already happened.      |
//|                                                                  |
//|  When one side fills the other is deleted (OCO, switchable) and   |
//|  by default no new orders go out while a trade is open.           |
//|  Everything is closed at the window end and 5 minutes before the  |
//|  broker's daily close - nothing is held overnight.                |
//|                                                                  |
//|  Times are SERVER time (Market Watch clock). The default window   |
//|  16:30-22:45 is the US cash session on GMT+2/+3 brokers.          |
//+------------------------------------------------------------------+
#property copyright "NAS ATR Breakout"
#property version   "1.00"
#property description "N-candle channel breakout for Nasdaq 100 CFDs with ATR stop loss / take profit, breakeven and trailing."

#include <Trade\Trade.mqh>

input group "=== Breakout ==="
input ENUM_TIMEFRAMES InpTF       = PERIOD_M15;     // Signal timeframe (channel and ATR)
input int    InpLookback   = 20;                    // Channel: highest high / lowest low of this many closed candles
input double InpBufferATR  = 0.1;                   // Entry buffer beyond the channel, x ATR (0 = exactly at the level)
input double InpMinRangeATR = 1.0;                  // Skip if channel is narrower than this x ATR (0 = no minimum)
input double InpMaxRangeATR = 6.0;                  // Skip if channel is wider than this x ATR (0 = no maximum)
input string InpWindow     = "16:30-22:45";         // Trading window, server time HH:MM-HH:MM

input group "=== ATR exits ==="
input int    InpATRPeriod  = 14;                    // ATR period
input double InpSLATR      = 1.5;                   // Stop loss = ATR x this
input bool   InpUseTPATR   = true;                  // Take profit from ATR (false = TP = SL x RR)
input double InpTPATR      = 3.0;                   // Take profit = ATR x this
input double InpRR         = 2.0;                   // Take profit = SL x this when ATR TP is off (0 = no take profit)
input bool   InpUseBE      = false;                 // Use breakeven
input double InpBEATR      = 1.0;                   // Breakeven: move SL to entry + lock at this x ATR profit
input bool   InpUseTrail   = false;                 // Use ATR trailing stop
input double InpTrailStartATR = 1.0;                // Trailing starts at this x ATR profit
input double InpTrailATR   = 2.0;                   // Trailing: SL stays this x ATR behind price

input group "=== Risk ==="
input double InpRiskPct    = 0.5;                   // Risk per trade, % of balance
input bool   InpOCO        = true;                  // When one side fills, delete the opposite order
input bool   InpOnePosition = true;                 // No new orders while a trade is open
input int    InpMaxTrades  = 3;                     // Maximum trades per day (0 = no limit)
input ulong  InpMagic      = 940001;                // Magic number

//--- fixed rules (kept out of the inputs on purpose)
#define BE_LOCK_ATR     0.05    // breakeven puts the SL this x ATR past entry (covers spread / commission)
#define MIN_MODIFY      1.0     // move the SL only when it improves by at least this many points
#define MAX_RANGE_PCT   10.0    // a channel above 10% of price = broken history, skipped

CTrade   trade;
int      g_atrHandle = INVALID_HANDLE;
int      g_winStart = 0, g_winEnd = 0, g_dayEnd = 0;
datetime g_day = 0, g_bar = 0;
int      g_tradesToday = 0;
double   g_atr = 0.0, g_hi = 0.0, g_lo = 0.0;
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

bool Ours(const long magic, const string sym) { return sym == _Symbol && (ulong)magic == InpMagic; }

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

void DeleteOrders(const string why)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || !Ours(OrderGetInteger(ORDER_MAGIC), OrderGetString(ORDER_SYMBOL))) continue;
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

// ATR of the last closed signal candle (0 if not ready).
double ATR()
  {
   double v[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, v) != 1 || v[0] <= 0.0) return 0.0;
   return v[0];
  }

// Highest high / lowest low of the last InpLookback closed signal candles.
bool Channel(double &hi, double &lo)
  {
   double h[], l[];
   if(CopyHigh(_Symbol, InpTF, 1, InpLookback, h) != InpLookback) return false;
   if(CopyLow(_Symbol, InpTF, 1, InpLookback, l) != InpLookback)  return false;
   hi = h[ArrayMaximum(h)];
   lo = l[ArrayMinimum(l)];
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

// One stop order at 'entry' with ATR-based SL / TP.
void PlaceStop(const bool buy, const double entry, const double atr)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap = BrokerMinDist();
   string side = buy ? "BUY" : "SELL";
   if(buy ? ask >= entry - gap : bid <= entry + gap)
     {
      PrintFormat("%s skipped: price is already at/through %.*f", side, _Digits, entry);
      return;
     }
   double slDist = atr * InpSLATR;
   if(slDist <= gap) { PrintFormat("%s skipped: SL %.2f (ATR %.2f) inside the broker minimum %.2f", side, slDist, atr, gap); return; }
   double tpDist = InpUseTPATR ? atr * InpTPATR : slDist * InpRR;
   double sl = Norm(buy ? entry - slDist : entry + slDist);
   double tp = (tpDist > 0.0) ? Norm(buy ? entry + tpDist : entry - tpDist) : 0.0;
   if(sl <= 0.0 || tp < 0.0) return;
   double lot = LotSize(buy, entry, sl);
   if(lot <= 0.0) return;
   bool ok = buy ? trade.BuyStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ATR BO")
                 : trade.SellStop(lot, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "ATR BO");
   if(ok) PrintFormat("%s STOP %.2f lots @ %.*f  SL %.*f (%.1f pts)  TP %s  | ATR %.1f", side, lot, _Digits, entry, _Digits, sl, slDist,
                      tp > 0.0 ? StringFormat("%.*f (%.1f pts)", _Digits, tp, tpDist) : "none", atr);
   else   PrintFormat("%s STOP rejected: %s", side, trade.ResultRetcodeDescription());
  }

// New signal candle: replace the unfilled pair with fresh channel levels.
void NewBar()
  {
   DeleteOrders("new candle - levels refreshed");
   if(InpOnePosition && CountPositions() > 0) { g_status = "trade open - no new orders"; return; }

   g_atr = ATR();
   if(g_atr <= 0.0) { g_status = "ATR not ready"; return; }
   if(!Channel(g_hi, g_lo)) { g_status = "channel not ready / broken history"; return; }

   double range = (g_hi - g_lo) / g_atr;
   HLine("BO high", g_hi, clrLime);
   HLine("BO low", g_lo, clrMagenta);
   if(InpMinRangeATR > 0.0 && range < InpMinRangeATR) { g_status = StringFormat("channel %.1f ATR < min %.1f - skipped", range, InpMinRangeATR); return; }
   if(InpMaxRangeATR > 0.0 && range > InpMaxRangeATR) { g_status = StringFormat("channel %.1f ATR > max %.1f - skipped", range, InpMaxRangeATR); return; }

   double buf = g_atr * InpBufferATR;
   PlaceStop(true,  Norm(g_hi + buf), g_atr);
   PlaceStop(false, Norm(g_lo - buf), g_atr);
   g_status = StringFormat("channel %.1f ATR, orders placed", range);
  }

void NewDay(const datetime today)
  {
   // Safety net: if the market stopped before the day-end time there was no tick to clean up.
   if(g_day != 0 && (CountOrders() > 0 || CountPositions() > 0))
     {
      PrintFormat("New day: %d order(s) and %d trade(s) left from %s (no tick after the day-end time) - removed",
                  CountOrders(), CountPositions(), TimeToString(g_day, TIME_DATE));
      DeleteOrders("left from yesterday");
      CloseAll("left from yesterday");
     }
   g_day = today;
   g_tradesToday = 0;
   g_bar = 0;                       // first candle inside the window places orders straight away
   g_dayEnd = (int)MathMin(g_winEnd, SessionEnd(Weekday(today)) - 5);
   PrintFormat("=== %s  window %s, close at %02d:%02d", TimeToString(today, TIME_DATE), InpWindow, g_dayEnd / 60, g_dayEnd % 60);
  }

//+------------------------------------------------------------------+
//|  Breakeven and ATR trailing                                       |
//+------------------------------------------------------------------+
void ManageStops()
  {
   bool be = InpUseBE && InpBEATR > 0.0, trail = InpUseTrail && InpTrailATR > 0.0;
   if(!be && !trail) return;
   double atr = ATR();
   if(atr <= 0.0) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double gap = BrokerMinDist();
   double lock = atr * BE_LOCK_ATR, trailDist = atr * InpTrailATR;
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
      if(be && profit >= atr * InpBEATR)
         target = buy ? MathMax(target, open + lock) : (target == 0.0 ? open - lock : MathMin(target, open - lock));
      if(trail && profit >= atr * InpTrailStartATR)
         target = buy ? MathMax(target, px - trailDist) : (target == 0.0 ? px + trailDist : MathMin(target, px + trailDist));
      if(target == sl) continue;
      if(buy)  target = MathMin(target, px - gap);           // broker minimum distance
      else     target = MathMax(target, px + gap);
      target = Norm(target);
      if(sl != 0.0 && (buy ? target < sl + MIN_MODIFY : target > sl - MIN_MODIFY)) continue;   // not a real improvement
      if(trade.PositionModify(t, target, PositionGetDouble(POSITION_TP)))
         PrintFormat("SL %.*f -> %.*f (profit %.1f points, ATR %.1f)", _Digits, sl, _Digits, target, profit, atr);
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
   if(g_winStart < 0 || g_winEnd <= g_winStart)                 err = "Window must be HH:MM-HH:MM with start before end";
   else if(InpLookback < 2)                                     err = "lookback must be >= 2";
   else if(InpATRPeriod < 1)                                    err = "ATR period must be >= 1";
   else if(InpSLATR <= 0.0)                                     err = "SL ATR multiplier must be > 0";
   else if(InpUseTPATR && InpTPATR <= 0.0)                      err = "TP ATR multiplier must be > 0";
   else if(InpRR < 0.0 || InpBufferATR < 0.0)                   err = "RR and buffer must be >= 0";
   else if(InpMinRangeATR < 0.0 || InpMaxRangeATR < 0.0)        err = "channel filters must be >= 0";
   else if(InpMaxRangeATR > 0.0 && InpMaxRangeATR <= InpMinRangeATR) err = "max channel must be above min channel";
   else if(InpUseBE && InpBEATR <= 0.0)                         err = "breakeven ATR multiplier must be > 0";
   else if(InpUseTrail && (InpTrailStartATR <= 0.0 || InpTrailATR <= 0.0)) err = "trailing start and distance must be > 0";
   else if(InpRiskPct <= 0.0 || InpRiskPct > 5.0)               err = "risk must be > 0 and <= 5";
   else if(InpMaxTrades < 0)                                    err = "max trades must be >= 0 (0 = no limit)";
   if(err != "") { Print("INVALID INPUT: ", err); return INIT_PARAMETERS_INCORRECT; }

   g_atrHandle = iATR(_Symbol, InpTF, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE) { Print("Could not create the ATR indicator"); return INIT_FAILED; }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(200);
   PrintFormat("NAS ATR Breakout on %s | %s channel %d | buffer %g ATR | range %g-%g ATR | window %s | ATR(%d) SL x%g | %s | BE %s | trail %s | risk %.2f%% | OCO %s | max trades/day %d",
               _Symbol, EnumToString(InpTF), InpLookback, InpBufferATR, InpMinRangeATR, InpMaxRangeATR, InpWindow, InpATRPeriod, InpSLATR,
               InpUseTPATR ? StringFormat("TP x%g ATR", InpTPATR) : InpRR > 0.0 ? StringFormat("TP = %g x SL", InpRR) : "no TP",
               InpUseBE ? StringFormat("%g ATR", InpBEATR) : "off",
               InpUseTrail ? StringFormat("%g/%g ATR", InpTrailStartATR, InpTrailATR) : "off",
               InpRiskPct, InpOCO ? "on" : "off", InpMaxTrades);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE) IndicatorRelease(g_atrHandle);
   Comment("");
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime today = DayStart(now);
   int mins = MinuteOf(now);
   if(today != g_day) NewDay(today);

   ManageStops();

   if(mins >= g_dayEnd || mins < g_winStart)
     {
      DeleteOrders("outside the window");
      if(mins >= g_dayEnd && CountPositions() > 0) CloseAll("window end");
      g_status = "outside the window";
     }
   else if(InpMaxTrades > 0 && g_tradesToday >= InpMaxTrades)
     {
      DeleteOrders("max trades for today reached");
      g_status = "max trades for today reached";
     }
   else
     {
      datetime bar = iTime(_Symbol, InpTF, 0);
      if(bar > 0 && bar != g_bar)
        {
         g_bar = bar;
         NewBar();
        }
     }

   if(!MQLInfoInteger(MQL_OPTIMIZATION))
      Comment(StringFormat("NAS ATR Breakout | %s %s\nChannel %.*f / %.*f | ATR %.1f | trades today %d | open %d\n%s",
                           _Symbol, EnumToString(InpTF), _Digits, g_hi, _Digits, g_lo, g_atr, g_tradesToday, CountPositions(), g_status));
  }

// Fill: count it and (OCO) delete the opposite order. Close: log the result.
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(!Ours(HistoryDealGetInteger(trans.deal, DEAL_MAGIC), HistoryDealGetString(trans.deal, DEAL_SYMBOL))) return;
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry == DEAL_ENTRY_IN)
     {
      g_tradesToday++;
      PrintFormat("FILLED %s @ %.*f (trade %d today)", HistoryDealGetInteger(trans.deal, DEAL_TYPE) == DEAL_TYPE_BUY ? "BUY" : "SELL",
                  _Digits, HistoryDealGetDouble(trans.deal, DEAL_PRICE), g_tradesToday);
      if(InpOCO) DeleteOrders("OCO - other side filled");
     }
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
     {
      long why = HistoryDealGetInteger(trans.deal, DEAL_REASON);
      PrintFormat("CLOSED by %s, result %+.2f", why == DEAL_REASON_SL ? "stop loss / trailing" : why == DEAL_REASON_TP ? "take profit" : "EA",
                  HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                  HistoryDealGetDouble(trans.deal, DEAL_COMMISSION));
     }
  }

// Custom max: profit factor x square root of trades (0 below 30 trades).
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES), pf = TesterStatistics(STAT_PROFIT_FACTOR);
   return (trades < 30.0 || pf <= 0.0) ? 0.0 : pf * MathSqrt(trades);
  }
//+------------------------------------------------------------------+
