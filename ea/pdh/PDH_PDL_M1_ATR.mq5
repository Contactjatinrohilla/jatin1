//+------------------------------------------------------------------+
//| PDH_PDL_M1_ATR.mq5                                               |
//|                                                                  |
//| What it does (in plain English):                                 |
//|  1. Reads yesterday's High (PDH) and Low (PDL).                  |
//|  2. Waits for a 1-minute candle to CLOSE above PDH (buy) or      |
//|     below PDL (sell). Only the first close beyond the level       |
//|     counts, and each side trades at most once per day.           |
//|  3. Enters at market with SL and TP set from ATR on M1.          |
//|  4. Watches account equity on every tick. If the account loses   |
//|     2.5% today or 8.5% this week, it closes all this EA's trades |
//|     and stops trading until the next day / week. This is shared |
//|     across every chart running this EA on the same account.      |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "PDH/PDL breakout, M1 close confirmation, ATR SL/TP, daily & weekly loss caps"

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lots
   LOT_RISK_PERCENT = 1  // % of equity risked per trade
  };

//--- Inputs ---------------------------------------------------------
input group "=== Entry ==="
input bool   TradeBuys        = true;   // Buy on M1 close above PDH
input bool   TradeSells       = true;   // Sell on M1 close below PDL

input group "=== Stop Loss / Take Profit (ATR on M1) ==="
input int    ATR_Period       = 5;      // ATR period (M1 candles)
input double ATR_SL_Mult      = 2.0;    // SL distance = ATR x this
input double ATR_TP_Mult      = 4.0;    // TP distance = ATR x this

input group "=== Position Size ==="
input ENUM_LOT_MODE LotMode   = LOT_FIXED; // Lot sizing method
input double FixedLots        = 0.01;   // Lots (when Fixed lots)
input double RiskPercent      = 0.5;    // % of equity risked (when Risk %)

input group "=== Loss Limits (whole account, all EA instances) ==="
input double DailyLossPct     = 2.5;    // Max daily loss %
input double WeeklyLossPct    = 8.5;    // Max weekly loss %
input double LossBaseAmount   = 0;      // % base: 0 = equity at day/week start, >0 = fixed amount (e.g. initial balance)

input group "=== Optional Filters (off by default) ==="
input int    MaxSpreadPoints  = 0;      // Max spread in points (0 = off)
input bool   UseSession       = false;  // Only trade between the hours below
input int    SessionStartHour = 8;      // Session start hour (server time)
input int    SessionEndHour   = 17;     // Session end hour (server time)

input group "=== Execution ==="
input long   MagicNumber      = 260514; // Magic number (use the same on all charts)
input int    SlippagePoints   = 30;     // Max slippage (points)

//--- Globals --------------------------------------------------------
CTrade   trade;
int      atrHandle   = INVALID_HANDLE;
datetime lastBarTime = 0;      // last M1 bar processed
datetime tradedDay   = 0;      // day the flags below belong to
bool     tradedHigh  = false;  // PDH breakout already traded today
bool     tradedLow   = false;  // PDL breakout already traded today
double   riskRoom    = 0;      // money left before the nearest loss cap
bool     haltLogged  = false;
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

   atrHandle = iATR(_Symbol, PERIOD_M1, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
     { Print("Could not create ATR."); return INIT_FAILED; }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   gvPrefix = "PDHPDL_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_";
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
      CloseAllEAPositions();
      return;
     }

   //--- 2) Signals: once per new M1 candle
   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   if(barTime == 0 || barTime == lastBarTime) return;
   lastBarTime = barTime;

   CheckForEntry();
  }

//====================================================================
//  LOSS PROTECTION
//====================================================================

// Returns the equity stored at the start of a period. The first EA
// instance to see a new period records it; all others read it.
double PeriodBaseEquity(const string name, const datetime periodStart, const double equity)
  {
   string kTime = gvPrefix + name + "Start";
   string kEq   = gvPrefix + name + "Equity";
   if(!GlobalVariableCheck(kTime) || (datetime)GlobalVariableGet(kTime) != periodStart
      || !GlobalVariableCheck(kEq))
     {
      GlobalVariableSet(kEq, equity);
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
   datetime weekStart = dayStart - ((t.day_of_week + 6) % 7) * 86400; // Monday

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

// Closes every position opened by this EA (same magic, any symbol).
void CloseAllEAPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(!trade.PositionClose(ticket))
         Print("Close failed for #", ticket, " retcode ", trade.ResultRetcode());
     }
  }

//====================================================================
//  SIGNALS
//====================================================================

void CheckForEntry()
  {
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today == 0) return;                      // daily data not ready
   if(today != tradedDay)
     {
      tradedDay = today;
      LoadTodaysTrades(today);                 // survives EA restarts
     }

   //--- Previous day's high/low (skips a short Sunday candle if the broker has one)
   int shift = 1;
   MqlDateTime d;
   TimeToStruct(iTime(_Symbol, PERIOD_D1, 1), d);
   if(d.day_of_week == 0) shift = 2;

   double pdh = iHigh(_Symbol, PERIOD_D1, shift);
   double pdl = iLow (_Symbol, PERIOD_D1, shift);
   double c1  = iClose(_Symbol, PERIOD_M1, 1); // last closed M1 candle
   double c2  = iClose(_Symbol, PERIOD_M1, 2); // the one before it
   if(pdh <= 0 || pdl <= 0 || c1 <= 0 || c2 <= 0) return;

   Comment(StringFormat("PDH: %s   PDL: %s   Bought PDH today: %s   Sold PDL today: %s",
           DoubleToString(pdh, _Digits), DoubleToString(pdl, _Digits),
           tradedHigh ? "yes" : "no", tradedLow ? "yes" : "no"));

   if(HasOpenPosition()) return;               // one trade at a time

   // First M1 close beyond the level (previous close was not beyond it)
   bool buySignal  = TradeBuys  && !tradedHigh && c1 > pdh && c2 <= pdh;
   bool sellSignal = TradeSells && !tradedLow  && c1 < pdl && c2 >= pdl;
   if(!buySignal && !sellSignal) return;
   if(!FiltersPass()) return;

   double atr[];
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0)
     { Print("ATR not available - signal skipped."); return; }

   if(buySignal)       { if(OpenTrade(true,  atr[0])) tradedHigh = true; }
   else if(sellSignal) { if(OpenTrade(false, atr[0])) tradedLow  = true; }
  }

// Rebuilds "already traded today" from account history.
void LoadTodaysTrades(const datetime dayStart)
  {
   tradedHigh = false;
   tradedLow  = false;
   if(!HistorySelect(dayStart, TimeCurrent() + 60)) return;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != MagicNumber) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      long type = HistoryDealGetInteger(deal, DEAL_TYPE);
      if(type == DEAL_TYPE_BUY)  tradedHigh = true;
      if(type == DEAL_TYPE_SELL) tradedLow  = true;
     }
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

bool FiltersPass()
  {
   if(MaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPoints)
     { Print("Spread too high - signal skipped."); return false; }

   if(UseSession)
     {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      bool inSession = (SessionStartHour <= SessionEndHour)
                       ? (t.hour >= SessionStartHour && t.hour < SessionEndHour)
                       : (t.hour >= SessionStartHour || t.hour < SessionEndHour);
      if(!inSession) return false;
     }
   return true;
  }

//====================================================================
//  EXECUTION
//====================================================================

// Money lost if `lots` hit a stop `dist` price units away.
double MoneyAtRisk(const double lots, const double dist)
  {
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return -1;
   return dist / tickSize * tickValue * lots;
  }

double CalcLots(const double slDist)
  {
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0 || maxLot <= 0 || step <= 0) return 0;

   double lots = FixedLots;
   if(LotMode == LOT_RISK_PERCENT)
     {
      double perLot = MoneyAtRisk(1.0, slDist);
      if(perLot <= 0) return 0;
      lots = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPercent / 100.0 / perLot;
     }

   lots = MathFloor(lots / step) * step;        // always round DOWN
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

   double lots = CalcLots(slDist);
   if(lots <= 0) return false;

   // Never open a trade whose stop-out would break a loss cap
   double risk = MoneyAtRisk(lots, slDist);
   if(risk <= 0 || risk > riskRoom)
     {
      Print("Trade skipped: risk ", DoubleToString(risk, 2),
            " exceeds remaining loss allowance ", DoubleToString(riskRoom, 2));
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
