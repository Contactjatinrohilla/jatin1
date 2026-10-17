//+------------------------------------------------------------------+
//| PDH_PDL_M1_ATR.mq5                                               |
//|                                                                  |
//| What it does (in plain English):                                 |
//|  1. Reads yesterday's High (PDH) and Low (PDL).                  |
//|  2. Waits for a 1-minute candle to CLOSE above PDH (buy) or      |
//|     below PDL (sell). Only the FIRST M1 close beyond each level  |
//|     today counts - it is read from today's M1 history, so it     |
//|     also holds after an EA restart. If that first close cannot   |
//|     be traded (trade open, filter, margin...), the side is done  |
//|     for the day; a later re-cross is never traded.               |
//|  3. Enters at market. SL / TP = ATR x multiplier (ATR timeframe  |
//|     is an input, M5 by default - M1 ATR is too noisy).           |
//|     Optional breakeven and a daily time exit.                    |
//|  4. Watches account equity on every tick. If the account loses   |
//|     2.5% today or 8.5% this week, it closes all this EA's trades |
//|     and stops trading until the next day / week. This is shared |
//|     across every chart running this EA on the same account, and  |
//|     a new trade is only opened if it plus the open risk of all   |
//|     the EA's other trades still fits inside the limit.           |
//|  5. Lot size is cut to what free margin can hold.                |
//+------------------------------------------------------------------+
#property version   "2.00"
#property description "PDH/PDL breakout, first M1 close confirmation, ATR SL/TP, daily & weekly loss caps"

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lots
   LOT_RISK_PERCENT = 1  // % of equity risked per trade
  };

//--- Inputs ---------------------------------------------------------
input group "=== Entry ==="
input bool   TradeBuys        = true;   // Buy on first M1 close above PDH
input bool   TradeSells       = true;   // Sell on first M1 close below PDL

input group "=== Stop Loss / Take Profit (ATR) ==="
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_M5; // ATR timeframe (v1 used M1)
input int    ATR_Period       = 14;     // ATR period (v1 used 5)
input double ATR_SL_Mult      = 2.0;    // SL distance = ATR x this
input double ATR_TP_Mult      = 4.0;    // TP distance = ATR x this

input group "=== Trade Management ==="
input bool   UseBreakeven     = false;  // Move SL to entry once in profit
input double BreakevenAtR     = 1.0;    // ... at this many R (1 R = SL distance)
input bool   UseTimeExit      = false;  // Close trades + stop entries at the time below (no overnight / weekend holds)
input int    ExitHour         = 22;     // Exit hour (server time)
input int    ExitMinute       = 45;     // Exit minute

input group "=== Position Size ==="
input ENUM_LOT_MODE LotMode   = LOT_FIXED; // Lot sizing method
input double FixedLots        = 0.01;   // Lots (when Fixed lots)
input double RiskPercent      = 0.5;    // % of equity risked (when Risk %)
input double MaxMarginUsePct  = 90.0;   // Use at most this % of free margin for one trade

input group "=== Loss Limits (whole account, all EA instances) ==="
input double DailyLossPct     = 2.5;    // Max daily loss %
input double WeeklyLossPct    = 8.5;    // Max weekly loss %
input double LossBaseAmount   = 0;      // % base: 0 = equity at day/week start, >0 = fixed amount (e.g. initial balance)

input group "=== Optional Filters (off by default) ==="
input int    MaxSpreadPoints  = 0;      // Max spread in points (0 = off)
input bool   UseSession       = false;  // Only open trades between the hours below
input int    SessionStartHour = 8;      // Session start hour (server time)
input int    SessionEndHour   = 17;     // Session end hour (server time)

input group "=== Execution ==="
input long   MagicNumber      = 260514; // Magic number (use the same on all charts)
input int    SlippagePoints   = 30;     // Max slippage (points)

//--- Globals --------------------------------------------------------
CTrade   trade;
int      atrHandle   = INVALID_HANDLE;
datetime lastBarTime = 0;      // last M1 bar processed
double   riskRoom    = 0;      // money left before the nearest loss cap
bool     haltLogged  = false;
datetime lastCloseFail = 0;    // throttles close retries / log lines
string   gvPrefix;             // shared-variable prefix for this account

//+------------------------------------------------------------------+
int OnInit()
  {
   if(ATR_Period < 1 || ATR_SL_Mult <= 0 || ATR_TP_Mult <= 0)
     { Print("Invalid ATR settings."); return INIT_PARAMETERS_INCORRECT; }
   if(DailyLossPct <= 0 || WeeklyLossPct <= 0)
     { Print("Loss limits must be above 0."); return INIT_PARAMETERS_INCORRECT; }
   if(LotMode == LOT_FIXED && FixedLots <= 0)
     { Print("FixedLots must be above 0."); return INIT_PARAMETERS_INCORRECT; }
   if(LotMode == LOT_RISK_PERCENT && RiskPercent <= 0)
     { Print("RiskPercent must be above 0."); return INIT_PARAMETERS_INCORRECT; }
   if(MaxMarginUsePct <= 0 || MaxMarginUsePct > 100)
     { Print("MaxMarginUsePct must be 1-100."); return INIT_PARAMETERS_INCORRECT; }
   if(UseBreakeven && BreakevenAtR <= 0)
     { Print("BreakevenAtR must be above 0."); return INIT_PARAMETERS_INCORRECT; }
   if(ExitHour < 0 || ExitHour > 23 || ExitMinute < 0 || ExitMinute > 59)
     { Print("Invalid exit time."); return INIT_PARAMETERS_INCORRECT; }
   if(SessionStartHour < 0 || SessionStartHour > 23 || SessionEndHour < 0 || SessionEndHour > 24)
     { Print("Invalid session hours."); return INIT_PARAMETERS_INCORRECT; }

   atrHandle = iATR(_Symbol, ATR_Timeframe, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
     { Print("Could not create ATR."); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   gvPrefix = "PDHPDL_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_";

   // Each backtest starts clean: no halt / start equity left over from a previous run
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      GlobalVariablesDeleteAll(gvPrefix);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   //--- 1) Loss protection: every tick (cheap)
   if(!RiskCheck())
     {
      ClosePositions(true);                    // every symbol of this EA
      return;
     }

   //--- 2) Time exit and breakeven: every tick
   if(UseTimeExit && PastExitTime())
      ClosePositions(false);                   // this chart's symbol
   else
      ManagePositions();

   //--- 3) Signals: once per new M1 candle
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime == 0 || barTime == lastBarTime) return;
   lastBarTime = barTime;

   CheckForEntry();
  }

//====================================================================
//  LOSS PROTECTION
//====================================================================

// Closed-trade profit (incl. commission, swap, fee) of the whole account since `from`.
double RealizedSince(const datetime from)
  {
   double sum = 0;
   if(!HistorySelect(from, TimeCurrent() + 60)) return 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      long type = HistoryDealGetInteger(deal, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL) continue;   // skip deposits etc.
      sum += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_COMMISSION)
           + HistoryDealGetDouble(deal, DEAL_SWAP)   + HistoryDealGetDouble(deal, DEAL_FEE);
     }
   return sum;
  }

// Returns the equity stored at the start of a period. The first EA
// instance to see a new period records it; all others read it.
// If no EA ran at the period start, losses already closed in the
// period are added back, so they still count toward the limit.
double PeriodBaseEquity(const string name, const datetime periodStart, const double equity)
  {
   string kTime = gvPrefix + name + "Start";
   string kEq   = gvPrefix + name + "Equity";
   if(!GlobalVariableCheck(kTime) || (datetime)GlobalVariableGet(kTime) != periodStart
      || !GlobalVariableCheck(kEq))
     {
      double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - RealizedSince(periodStart);
      GlobalVariableSet(kEq, MathMax(equity, startBalance));
      GlobalVariableSet(kTime, (double)periodStart);
     }
   return GlobalVariableGet(kEq);
  }

bool IsHalted(const string name, const datetime periodStart)
  {
   string k = gvPrefix + name + "Halt";
   return (GlobalVariableCheck(k) && (datetime)GlobalVariableGet(k) == periodStart);
  }

void SetHalted(const string name, const datetime periodStart)
  {
   GlobalVariableSet(gvPrefix + name + "Halt", (double)periodStart);
  }

// false = a loss cap is hit: close trades and do not trade.
bool RiskCheck()
  {
   datetime now      = TimeCurrent();
   datetime dayStart = now - (now % 86400);           // server midnight
   MqlDateTime t;
   TimeToStruct(dayStart, t);
   datetime weekStart = dayStart - t.day_of_week * 86400; // Sunday 00:00, so Sunday sessions belong to the coming week

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity <= 0)          // no account data: block new trades, close nothing
     { riskRoom = 0; return true; }

   double dayBase  = PeriodBaseEquity("Day",  dayStart,  equity);
   double weekBase = PeriodBaseEquity("Week", weekStart, equity);

   // Stay halted for the rest of the period once a cap was hit,
   // even if equity bounces back.
   if(IsHalted("Day", dayStart) || IsHalted("Week", weekStart))
     { riskRoom = 0; LogHalt(); return false; }

   double dayLimit  = (LossBaseAmount > 0 ? LossBaseAmount : dayBase)  * DailyLossPct  / 100.0;
   double weekLimit = (LossBaseAmount > 0 ? LossBaseAmount : weekBase) * WeeklyLossPct / 100.0;
   double dayLoss   = dayBase  - equity;
   double weekLoss  = weekBase - equity;

   if(dayLoss >= dayLimit)   SetHalted("Day",  dayStart);
   if(weekLoss >= weekLimit) SetHalted("Week", weekStart);
   if(dayLoss >= dayLimit || weekLoss >= weekLimit)
     { riskRoom = 0; LogHalt(); return false; }

   haltLogged = false;
   riskRoom   = MathMin(dayLimit - dayLoss, weekLimit - weekLoss);
   return true;
  }

void LogHalt()
  {
   if(haltLogged) return;
   haltLogged = true;
   Print("Loss limit reached. All EA trades closed. No new trades until the limit resets.");
   Comment("PDH/PDL EA: LOSS LIMIT HIT - trading stopped");
  }

// Closes this EA's positions: every symbol (loss cap) or only this chart's (time exit).
// After a failed close it waits 10 s before trying again, so a closed market does not flood the log.
void ClosePositions(const bool allSymbols)
  {
   if(lastCloseFail > 0 && TimeCurrent() - lastCloseFail < 10) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(!allSymbols && PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(trade.PositionClose(ticket))
         lastCloseFail = 0;
      else
        {
         lastCloseFail = TimeCurrent();
         Print("Close failed for #", ticket, " retcode ", trade.ResultRetcode(), " - retrying in 10 s");
        }
     }
  }

bool PastExitTime()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.hour * 60 + t.min >= ExitHour * 60 + ExitMinute;
  }

// Breakeven for this chart's position (SL moves once, when it is still behind entry).
void ManagePositions()
  {
   if(!UseBreakeven) return;
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber ||
         PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      bool   isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl <= 0) continue;

      double risk = isBuy ? open - sl : sl - open;
      if(risk <= 0) continue;                                    // already at / past breakeven

      double px     = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profit = isBuy ? px - open : open - px;
      if(profit < risk * BreakevenAtR) continue;

      double newSl = NormalizeDouble(open, _Digits);
      bool   legal = isBuy ? newSl < px - minDist : newSl > px + minDist;
      if(legal && !trade.PositionModify(ticket, newSl, tp))
         Print("Breakeven failed for #", ticket, " retcode ", trade.ResultRetcode());
     }
  }

//====================================================================
//  SIGNALS
//====================================================================

void CheckForEntry()
  {
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today == 0) return;                      // daily data not ready

   //--- Previous day's high/low (skips a short Sunday candle if the broker has one)
   int shift = 1;
   MqlDateTime d;
   TimeToStruct(iTime(_Symbol, PERIOD_D1, 1), d);
   if(d.day_of_week == 0) shift = 2;

   double pdh = iHigh(_Symbol, PERIOD_D1, shift);
   double pdl = iLow (_Symbol, PERIOD_D1, shift);
   if(pdh <= 0 || pdl <= 0 || pdh <= pdl) return;

   //--- Last closed M1 candle must belong to today
   datetime bar1 = iTime(_Symbol, PERIOD_M1, 1);
   datetime bar2 = iTime(_Symbol, PERIOD_M1, 2);
   double   c1   = iClose(_Symbol, PERIOD_M1, 1);
   if(bar1 < today || c1 <= 0) return;

   //--- Highest / lowest M1 close earlier today (before the last closed candle)
   double prevMax = -DBL_MAX, prevMin = DBL_MAX;
   if(bar2 >= today)
     {
      double closes[];
      int n = CopyClose(_Symbol, PERIOD_M1, today, bar2, closes);
      if(n <= 0) { Print("Today's M1 history not ready - signal check skipped."); return; }
      prevMax = closes[ArrayMaximum(closes)];
      prevMin = closes[ArrayMinimum(closes)];
     }
   bool pdhUsed = prevMax > pdh;               // an earlier close already broke PDH today
   bool pdlUsed = prevMin < pdl;

   Comment(StringFormat("PDH: %s %s   PDL: %s %s   Loss room: %s",
           DoubleToString(pdh, _Digits), (pdhUsed || c1 > pdh) ? "(broken today)" : "",
           DoubleToString(pdl, _Digits), (pdlUsed || c1 < pdl) ? "(broken today)" : "",
           DoubleToString(riskRoom, 2)));

   // First M1 close beyond the level today
   bool buySignal  = TradeBuys  && !pdhUsed && c1 > pdh;
   bool sellSignal = TradeSells && !pdlUsed && c1 < pdl;
   if(!buySignal && !sellSignal) return;

   string side = buySignal ? "PDH buy" : "PDL sell";
   if(HasOpenPosition())                    { Print(side, " signal skipped: a trade is already open."); return; }
   if(UseTimeExit && PastExitTime())        { Print(side, " signal skipped: after exit time.");        return; }
   if(!FiltersPass(side))                   return;

   double atr[];
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0)
     { Print("ATR not available - ", side, " signal skipped."); return; }

   OpenTrade(buySignal, atr[0]);
  }

bool HasOpenPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
     }
   return false;
  }

bool FiltersPass(const string side)
  {
   if(MaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints)
     { Print(side, " signal skipped: spread too high."); return false; }

   if(UseSession)
     {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      bool inSession = (SessionStartHour <= SessionEndHour)
                       ? (t.hour >= SessionStartHour && t.hour < SessionEndHour)
                       : (t.hour >= SessionStartHour || t.hour < SessionEndHour);
      if(!inSession) { Print(side, " signal skipped: outside session."); return false; }
     }
   return true;
  }

//====================================================================
//  EXECUTION
//====================================================================

// Money lost if `lots` of `symbol` hit a stop `dist` price units away.
double MoneyAtRisk(const string symbol, const double lots, const double dist)
  {
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return -1;
   return dist / tickSize * tickValue * lots;
  }

// What all of this EA's open trades (every chart) can still lose from here to their SL.
// Equity already includes their current profit/loss, so the distance is measured from the current price.
double OpenRiskAllCharts()
  {
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      string sym = PositionGetString(POSITION_SYMBOL);
      double sl  = PositionGetDouble(POSITION_SL);
      if(sl <= 0) return DBL_MAX;                                 // no SL: risk unknown, block new trades
      bool   isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double px    = isBuy ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
      double dist  = isBuy ? px - sl : sl - px;
      if(dist <= 0) continue;                                     // SL already locks in profit
      double r = MoneyAtRisk(sym, PositionGetDouble(POSITION_VOLUME), dist);
      if(r < 0) return DBL_MAX;
      total += r;
     }
   return total;
  }

double CalcLots(const bool isBuy, const double slDist)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0 || maxLot <= 0 || step <= 0) return 0;

   double lots = FixedLots;
   if(LotMode == LOT_RISK_PERCENT)
     {
      double perLot = MoneyAtRisk(_Symbol, 1.0, slDist);
      if(perLot <= 0) return 0;
      lots = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0 / perLot;
     }

   // Never ask for more than free margin can hold
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double marginPerLot = 0;
   if(OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, price, marginPerLot)
      && marginPerLot > 0)
     {
      double maxByMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * MaxMarginUsePct / 100.0 / marginPerLot;
      if(lots > maxByMargin)
        {
         Print("Lots reduced from ", DoubleToString(lots, 2), " to ", DoubleToString(maxByMargin, 2),
               " to fit free margin.");
         lots = maxByMargin;
        }
     }

   lots = MathFloor(lots / step + 1e-9) * step;  // always round DOWN
   if(lots < minLot)
     { Print("Lot size below broker minimum - trade skipped (no rounding up)."); return 0; }
   if(lots > maxLot) lots = maxLot;

   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, digits);
  }

bool OpenTrade(const bool isBuy, const double atr)
  {
   double slDist = atr * ATR_SL_Mult;
   double tpDist = atr * ATR_TP_Mult;

   // Respect the broker's minimum stop distance (plus spread as a cushion)
   double minDist = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)
                     + SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)) * _Point;
   if(slDist < minDist) slDist = minDist;
   if(tpDist < minDist) tpDist = minDist;

   double lots = CalcLots(isBuy, slDist);
   if(lots <= 0) return false;

   // Never open a trade whose stop-out, together with the EA's other open trades, would break a loss cap
   double risk     = MoneyAtRisk(_Symbol, lots, slDist);
   double openRisk = OpenRiskAllCharts();
   double room     = (openRisk == DBL_MAX) ? 0 : riskRoom - openRisk;
   if(risk <= 0 || risk > room)
     {
      Print("Trade skipped: risk ", DoubleToString(risk, 2),
            " exceeds remaining loss allowance ", DoubleToString(MathMax(room, 0), 2),
            " (limit room ", DoubleToString(riskRoom, 2), " minus open trades' risk)");
      return false;
     }

   for(int attempt = 0; attempt < 3; attempt++)
     {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return false;

      double price = isBuy ? tick.ask : tick.bid;
      double sl    = NormalizeDouble(isBuy ? price - slDist : price + slDist, _Digits);
      double tp    = NormalizeDouble(isBuy ? price + tpDist : price - tpDist, _Digits);

      bool sent = isBuy ? trade.Buy (lots, _Symbol, price, sl, tp, "PDH breakout")
                        : trade.Sell(lots, _Symbol, price, sl, tp, "PDL breakout");
      uint rc = trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
        {
         Print(isBuy ? "BUY " : "SELL ", lots, " lots | SL ", sl, " | TP ", tp,
               " | ATR ", DoubleToString(atr, _Digits));
         return true;
        }

      Print("Order failed, retcode ", rc, " (", trade.ResultRetcodeDescription(), ")");
      // Retry only when the price simply moved
      if(rc != TRADE_RETCODE_REQUOTE && rc != TRADE_RETCODE_PRICE_CHANGED &&
         rc != TRADE_RETCODE_PRICE_OFF)
         return false;
     }
   return false;
  }
//+------------------------------------------------------------------+
