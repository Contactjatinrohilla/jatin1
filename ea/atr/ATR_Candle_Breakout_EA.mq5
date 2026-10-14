//+------------------------------------------------------------------+
//|                                     ATR_Candle_Breakout_EA.mq5   |
//|                                                                  |
//|  Clean-room rebuild of an "ATR candle breakout" EA. The supplied  |
//|  .ex5 is compiled + encrypted, so its source cannot be recovered; |
//|  this file implements the strategy its name describes:            |
//|                                                                  |
//|  On every new candle of InpTF the candle that just closed is      |
//|  measured against the ATR. If its range (high - low) is at least  |
//|  ATR x InpTriggerMult it is a "signal candle":                    |
//|                                                                  |
//|   ENTRY_STOP_ORDERS - BUY STOP above its high, SELL STOP below    |
//|                       its low (straddle). Unfilled orders are     |
//|                       deleted after InpExpiryBars candles. When   |
//|                       one side fills, the other is deleted        |
//|                       (InpOCO).                                   |
//|   ENTRY_MARKET      - market order in the candle's direction      |
//|                       (bullish close = buy, bearish = sell).      |
//|                                                                  |
//|  Stop loss = ATR x InpSLMult (or the opposite candle extreme),    |
//|  take profit = SL x InpRR. Optional ATR trailing stop and         |
//|  breakeven. Lot size from % risk of balance (or fixed lots).      |
//+------------------------------------------------------------------+
#property copyright "ATR Candle Breakout"
#property version   "1.00"
#property description "Trades breakouts of candles whose range exceeds ATR x multiplier."

#include <Trade\Trade.mqh>

enum ENUM_ENTRY_MODE
  {
   ENTRY_STOP_ORDERS = 0,   // Stop orders at candle high / low
   ENTRY_MARKET      = 1    // Market order in candle direction
  };

enum ENUM_SL_MODE
  {
   SL_ATR    = 0,           // ATR x multiplier
   SL_CANDLE = 1            // Opposite end of the signal candle
  };

input group "=== Signal ==="
input ENUM_TIMEFRAMES InpTF          = PERIOD_H1;          // Signal timeframe
input int             InpAtrPeriod   = 14;                 // ATR period
input double          InpTriggerMult = 1.5;                // Candle range must be >= ATR x this
input bool            InpBodyFilter  = true;               // Also require body >= 50% of the range
input ENUM_ENTRY_MODE InpEntryMode   = ENTRY_STOP_ORDERS;  // Entry mode
input double          InpEntryBuffer = 0.0;                // Stop-order offset beyond high/low, x ATR
input int             InpExpiryBars  = 1;                  // Delete unfilled orders after this many candles
input bool            InpOCO         = true;               // Delete the opposite order when one fills

input group "=== Exit ==="
input ENUM_SL_MODE    InpSLMode      = SL_ATR;             // Stop loss mode
input double          InpSLMult      = 1.0;                // SL = ATR x this (ATR mode)
input double          InpRR          = 2.0;                // TP = SL distance x this (0 = no TP)
input bool            InpUseBE       = false;              // Use breakeven
input double          InpBEAtR       = 1.0;                // Move SL to entry at this many R profit
input bool            InpUseTrail    = false;              // Use ATR trailing stop
input double          InpTrailMult   = 1.5;                // Trailing distance = ATR x this

input group "=== Risk ==="
input double          InpRiskPct     = 1.0;                // Risk per trade, % of balance (0 = fixed lots)
input double          InpFixedLots   = 0.10;               // Fixed lots when risk % is 0
input int             InpMaxPositions= 1;                  // Max open positions of this EA (0 = no limit)
input string          InpWindow      = "00:00-23:59";      // Trading window, server time HH:MM-HH:MM
input ulong           InpMagic       = 240501;             // Magic number

CTrade   trade;
int      g_atr = INVALID_HANDLE;
datetime g_lastBar = 0;
int      g_winStart = 0, g_winEnd = 24 * 60;

//+------------------------------------------------------------------+
//|  Helpers                                                          |
//+------------------------------------------------------------------+
int ParseHHMM(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   string p[];
   if(StringSplit(s, ':', p) != 2)
      return -1;
   int h = (int)StringToInteger(p[0]);
   int m = (int)StringToInteger(p[1]);
   if(h < 0 || h > 24 || m < 0 || m > 59)
      return -1;
   return h * 60 + m;
  }

bool InWindow()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   int now = t.hour * 60 + t.min;
   if(g_winStart <= g_winEnd)
      return now >= g_winStart && now <= g_winEnd;
   return now >= g_winStart || now <= g_winEnd;      // window crosses midnight
  }

double Norm(const double price)
  {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
  }

double GetATR(const int shift)
  {
   double buf[];
   if(CopyBuffer(g_atr, 0, shift, 1, buf) != 1)
      return 0.0;
   return buf[0];
  }

double StopLevelDist()
  {
   long lvl = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return (double)lvl * _Point;
  }

double LotsForRisk(const double slDist)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lots    = InpFixedLots;

   if(InpRiskPct > 0.0 && slDist > 0.0)
     {
      double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickVal <= 0.0 || tickSize <= 0.0)
         return 0.0;
      double risk     = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
      double lossLot  = slDist / tickSize * tickVal;
      lots = risk / lossLot;
     }

   lots = MathFloor(lots / step) * step;
   if(lots < minLot)
      lots = minLot;
   if(lots > maxLot)
      lots = maxLot;
   return NormalizeDouble(lots, 8);
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         n++;
     }
   return n;
  }

int CountOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == (long)InpMagic)
         n++;
     }
   return n;
  }

void DeleteOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == (long)InpMagic)
         trade.OrderDelete(ticket);
     }
  }

//+------------------------------------------------------------------+
//|  Entries                                                          |
//+------------------------------------------------------------------+
void PlaceStopOrders(const double hi, const double lo, const double atr)
  {
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minD   = StopLevelDist();
   double buf    = InpEntryBuffer * atr;
   int    secs   = PeriodSeconds(InpTF) * MathMax(InpExpiryBars, 1);
   datetime exp  = iTime(_Symbol, InpTF, 0) + secs;

   //--- buy stop
   double buyPx = Norm(hi + buf);
   if(buyPx > ask + minD)
     {
      double slDist = (InpSLMode == SL_ATR) ? atr * InpSLMult : buyPx - lo;
      if(slDist > minD)
        {
         double sl = Norm(buyPx - slDist);
         double tp = (InpRR > 0.0) ? Norm(buyPx + slDist * InpRR) : 0.0;
         double lots = LotsForRisk(slDist);
         if(lots > 0.0)
            trade.BuyStop(lots, buyPx, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, exp, "ATR breakout buy");
        }
     }

   //--- sell stop
   double sellPx = Norm(lo - buf);
   if(sellPx < bid - minD)
     {
      double slDist = (InpSLMode == SL_ATR) ? atr * InpSLMult : hi - sellPx;
      if(slDist > minD)
        {
         double sl = Norm(sellPx + slDist);
         double tp = (InpRR > 0.0) ? Norm(sellPx - slDist * InpRR) : 0.0;
         double lots = LotsForRisk(slDist);
         if(lots > 0.0)
            trade.SellStop(lots, sellPx, _Symbol, sl, tp, ORDER_TIME_SPECIFIED, exp, "ATR breakout sell");
        }
     }
  }

void PlaceMarket(const bool isBuy, const double hi, const double lo, const double atr)
  {
   double px     = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist = (InpSLMode == SL_ATR) ? atr * InpSLMult : (isBuy ? px - lo : hi - px);
   if(slDist <= StopLevelDist())
      return;
   double lots = LotsForRisk(slDist);
   if(lots <= 0.0)
      return;
   if(isBuy)
     {
      double sl = Norm(px - slDist);
      double tp = (InpRR > 0.0) ? Norm(px + slDist * InpRR) : 0.0;
      trade.Buy(lots, _Symbol, 0.0, sl, tp, "ATR breakout buy");
     }
   else
     {
      double sl = Norm(px + slDist);
      double tp = (InpRR > 0.0) ? Norm(px - slDist * InpRR) : 0.0;
      trade.Sell(lots, _Symbol, 0.0, sl, tp, "ATR breakout sell");
     }
  }

void CheckSignal()
  {
   double atr = GetATR(2);                 // ATR before the signal candle, so the candle doesn't inflate it
   if(atr <= 0.0)
      return;

   double o = iOpen(_Symbol, InpTF, 1);
   double h = iHigh(_Symbol, InpTF, 1);
   double l = iLow(_Symbol, InpTF, 1);
   double c = iClose(_Symbol, InpTF, 1);
   double range = h - l;
   if(range < atr * InpTriggerMult)
      return;
   if(InpBodyFilter && MathAbs(c - o) < range * 0.5)
      return;

   if(InpEntryMode == ENTRY_STOP_ORDERS)
     {
      DeleteOrders();                      // a new signal replaces any old straddle
      PlaceStopOrders(h, l, atr);
     }
   else if(c != o)
      PlaceMarket(c > o, h, l, atr);
  }

//+------------------------------------------------------------------+
//|  Trade management                                                 |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(!InpUseBE && !InpUseTrail)
      return;
   double atr = GetATR(1);
   double minD = StopLevelDist();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;

      bool   isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      double px    = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double newSl = sl;

      //--- breakeven: initial risk is the original SL distance (only while SL is still behind entry)
      if(InpUseBE && sl > 0.0)
        {
         double risk = isBuy ? open - sl : sl - open;
         if(risk > 0.0)
           {
            double profit = isBuy ? px - open : open - px;
            if(profit >= risk * InpBEAtR)
               newSl = open;
           }
        }

      //--- ATR trailing
      if(InpUseTrail && atr > 0.0)
        {
         double trail = isBuy ? px - atr * InpTrailMult : px + atr * InpTrailMult;
         if(isBuy  && trail > open && trail > newSl)
            newSl = trail;
         if(!isBuy && trail < open && (newSl == 0.0 || trail < newSl))
            newSl = trail;
        }

      newSl = Norm(newSl);
      bool better = isBuy ? newSl > sl + _Point : (sl == 0.0 || newSl < sl - _Point);
      bool legal  = isBuy ? newSl < px - minD : newSl > px + minD;
      if(newSl > 0.0 && better && legal)
         trade.PositionModify(ticket, newSl, tp);
     }
  }

//+------------------------------------------------------------------+
//|  Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_winStart = ParseHHMM(StringSubstr(InpWindow, 0, StringFind(InpWindow, "-")));
   g_winEnd   = ParseHHMM(StringSubstr(InpWindow, StringFind(InpWindow, "-") + 1));
   if(StringFind(InpWindow, "-") < 0 || g_winStart < 0 || g_winEnd < 0)
     {
      Print("Invalid trading window: ", InpWindow, " (use HH:MM-HH:MM)");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpAtrPeriod < 1 || InpTriggerMult <= 0.0 || InpSLMult <= 0.0)
     {
      Print("ATR period, trigger multiplier and SL multiplier must be positive");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_atr = iATR(_Symbol, InpTF, InpAtrPeriod);
   if(g_atr == INVALID_HANDLE)
     {
      Print("Failed to create ATR handle, error ", GetLastError());
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   g_lastBar = iTime(_Symbol, InpTF, 0);   // wait for the next fresh candle
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   if(g_atr != INVALID_HANDLE)
      IndicatorRelease(g_atr);
  }

//--- OCO: when one of our stop orders fills, delete the other side
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(!InpOCO || InpEntryMode != ENTRY_STOP_ORDERS || trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol || HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != (long)InpMagic)
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN && CountOrders() > 0)
      DeleteOrders();
  }

void OnTick()
  {
   ManagePositions();

   datetime bar = iTime(_Symbol, InpTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;

   if(!InWindow())
      return;
   if(InpMaxPositions > 0 && CountPositions() >= InpMaxPositions)
      return;
   CheckSignal();
  }
//+------------------------------------------------------------------+
