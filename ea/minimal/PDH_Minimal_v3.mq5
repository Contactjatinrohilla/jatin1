//+------------------------------------------------------------------+
//|                         PDH_Minimal_v3.mq5  v1.20                   |
//|                                                                  |
//|  Previous-day high / low (PDH / PDL) only. Nothing else.          |
//|                                                                  |
//|  BREAKOUT  at the window start: BUY STOP at PDH, SELL STOP at     |
//|            PDL (a side price is already beyond is skipped).       |
//|            First fill deletes the other order.                    |
//|            SL = InpSL_USD, TP = SL x InpRR.                        |
//|  SWEEP     M5 candle trades >= $0.50 beyond PDH/PDL and a candle  |
//|            closes back inside within 6 candles -> market order    |
//|            back into the range. SL = sweep extreme + $0.50        |
//|            (skipped if wider than InpSL_USD), TP = SL x InpRR.    |
//|                                                                  |
//|  One position at a time, one trade per side per day. Unfilled     |
//|  orders deleted and open trades closed at the window end.         |
//|  Breakeven: at +BE_Trigger $ the SL moves to entry +BE_Lock $.    |
//|  Trailing: from +TrailStart $ the SL follows TrailDist $ behind.  |
//|  Switched on with InpUseBE / InpUseTrail. SL only moves forward.   |
//|  No filters. Times = server time.                                 |
//|  Optimisation (whatever the Inputs table shows - just tick):       |
//|  SL 1..50 step 0.5, RR 1..10 step 0.5, breakeven and trailing     |
//|  inputs 0.1..100 step 0.1.                                        |
//+------------------------------------------------------------------+
#property copyright "PDH Minimal v1.20"
#property version   "1.20"

#include <Trade\Trade.mqh>

enum ENUM_MODE { MODE_BREAKOUT = 0, MODE_SWEEP = 1 };

input ENUM_MODE InpMode    = MODE_BREAKOUT;  // Mode: breakout or sweep reversal
input double    InpSL_USD  = 1.0;            // SL in $ (sweep: maximum SL) - for a single test type e.g. 14
input double    InpRR      = 1.0;            // TP = SL x RR - for a single test type e.g. 2
input double    InpRiskPct = 0.5;            // Risk % of balance per trade
input string    InpWindow  = "03:00-22:00";  // Trading window, server time (orders/entries inside, everything closed at the end)
input bool      InpUseBE      = false;       // Breakeven ON/OFF (set true to use / optimise the two breakeven inputs)
input double    InpBE_Trigger = 0.1;         // Breakeven: when the trade is this many $ in profit
input double    InpBE_Lock    = 0.1;         // Breakeven: move the SL to entry + this many $ (not above the trigger)
input bool      InpUseTrail   = false;       // Trailing ON/OFF (set true to use / optimise the two trailing inputs)
input double    InpTrailStart = 0.1;         // Trailing: starts when the trade is this many $ in profit
input double    InpTrailDist  = 0.1;         // Trailing: SL stays this many $ behind price

#define MAGIC      910000
#define SWEEP_MIN  0.50      // sweep must go this far beyond the level ($)
#define SWEEP_BARS 6         // close back inside within this many M5 candles
#define SWEEP_BUF  0.50      // SL beyond the sweep extreme ($)

CTrade   trade;
int      winStart, winEnd;
datetime day = 0, lastBar = 0;
double   pdh = 0, pdl = 0;
bool     placed = false;             // breakout orders placed today
bool     sideDone[2];                // 0 = high side, 1 = low side
bool     swept[2];
double   swExt[2];
int      swBars[2];

int ParseHHMM(string s)
  {
   string p[];
   if(StringSplit(s, ':', p) != 2) return -1;
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   return (h < 0 || h > 23 || m < 0 || m > 59) ? -1 : h * 60 + m;
  }

double Norm(double p) { return NormalizeDouble(p, _Digits); }

int MyPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC) n++;
   return n;
  }

void DeleteOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == MAGIC) trade.OrderDelete(t);
     }
  }

void CloseAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == MAGIC) trade.PositionClose(t);
     }
  }

double Lot(bool buy, double entry, double sl)
  {
   double loss = 0;
   if(!OrderCalcProfit(buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, entry, sl, loss) || loss == 0) return 0;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot  = MathFloor(AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0 / MathAbs(loss) / step) * step;
   if(lot < vmin) return 0;                                   // even the minimum lot would risk too much
   return MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
  }

int OnInit()
  {
   string p[];
   if(StringSplit(InpWindow, '-', p) != 2) return INIT_PARAMETERS_INCORRECT;
   winStart = ParseHHMM(p[0]);
   winEnd   = ParseHHMM(p[1]);
   if(winStart < 0 || winEnd <= winStart || InpSL_USD <= 0 || InpRR <= 0 || InpRiskPct <= 0 || InpRiskPct > 5)
     {
      Print("Invalid inputs: window HH:MM-HH:MM (start before end), SL > 0, RR > 0, risk 0-5%");
      return INIT_PARAMETERS_INCORRECT;
     }
   if((InpUseBE && (InpBE_Trigger <= 0 || InpBE_Lock < 0 || InpBE_Lock > InpBE_Trigger)) ||
      (InpUseTrail && (InpTrailStart <= 0 || InpTrailDist <= 0)))
     {
      Print("Invalid inputs: BE trigger > 0 and BE lock not above it; trail start and distance > 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   trade.SetExpertMagicNumber(MAGIC);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);
   PrintFormat("PDH Minimal v3 | %s | SL $%g | RR %g | risk %.2f%% | window %s | BE %s | trail %s",
               InpMode == MODE_BREAKOUT ? "BREAKOUT" : "SWEEP", InpSL_USD, InpRR, InpRiskPct, InpWindow,
               InpUseBE ? StringFormat("at +%g -> entry +%g", InpBE_Trigger, InpBE_Lock) : "off",
               InpUseTrail ? StringFormat("from +%g, %g behind", InpTrailStart, InpTrailDist) : "off");
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime today = (datetime)((long)now - (long)now % 86400);
   int      mins  = (int)((now - today) / 60);

   // new day: levels from yesterday's D1 candle, reset state
   if(today != day)
     {
      if(iTime(_Symbol, PERIOD_D1, 0) != today) return;       // today's D1 candle not built yet
      day = today;
      pdh = iHigh(_Symbol, PERIOD_D1, 1);
      pdl = iLow(_Symbol, PERIOD_D1, 1);
      placed = false;
      for(int k = 0; k < 2; k++) { sideDone[k] = false; swept[k] = false; swExt[k] = 0; swBars[k] = 0; }
      PrintFormat("=== %s  PDH %.*f  PDL %.*f", TimeToString(today, TIME_DATE), _Digits, pdh, _Digits, pdl);
     }

   ManageStops();

   // window end: delete orders, close trades
   if(mins >= winEnd) { DeleteOrders(); CloseAll(); return; }
   if(mins < winStart) return;

   if(MyPositions() > 0) { DeleteOrders(); return; }          // one position at a time (OCO for the breakout)

   if(InpMode == MODE_BREAKOUT) Breakout();
   else                         Sweep();
  }

// Breakeven and trailing stop. The SL never moves backwards and stays outside the broker's stop level.
void ManageStops()
  {
   if(!InpUseBE && !InpUseTrail) return;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double gap = (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != MAGIC) continue;
      bool   buy    = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double px     = buy ? bid : ask;
      double profit = buy ? bid - open : open - ask;
      double newSL  = sl;
      if(InpUseBE && profit >= InpBE_Trigger)
        {
         double be = Norm(buy ? open + InpBE_Lock : open - InpBE_Lock);
         if(buy ? be > newSL : (newSL == 0 || be < newSL)) newSL = be;
        }
      if(InpUseTrail && profit >= InpTrailStart)
        {
         double tr = Norm(buy ? px - InpTrailDist : px + InpTrailDist);
         if(buy ? tr > newSL : (newSL == 0 || tr < newSL)) newSL = tr;
        }
      if(buy ? px - newSL < gap : newSL - px < gap) newSL = Norm(buy ? px - gap : px + gap);
      if(MathAbs(newSL - sl) < 0.1 || (buy ? newSL <= sl : (sl > 0 && newSL >= sl))) continue;   // move in steps of >= $0.10
      if(trade.PositionModify(t, newSL, PositionGetDouble(POSITION_TP)))
         PrintFormat("SL %.*f -> %.*f (profit %.2f)", _Digits, sl, _Digits, newSL, profit);
     }
  }

// BREAKOUT: stop orders at PDH / PDL once per day, only on the side price has not passed.
void Breakout()
  {
   if(placed) return;
   placed = true;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask < pdh)
     {
      double sl = Norm(pdh - InpSL_USD), tp = Norm(pdh + InpSL_USD * InpRR), lot = Lot(true, pdh, sl);
      if(lot > 0) trade.BuyStop(lot, Norm(pdh), _Symbol, sl, tp, ORDER_TIME_GTC, 0, "PDH_BUY");
     }
   else Print("BUY skipped: price already above PDH at the window start");
   if(bid > pdl)
     {
      double sl = Norm(pdl + InpSL_USD), tp = Norm(pdl - InpSL_USD * InpRR), lot = Lot(false, pdl, sl);
      if(lot > 0) trade.SellStop(lot, Norm(pdl), _Symbol, sl, tp, ORDER_TIME_GTC, 0, "PDL_SELL");
     }
   else Print("SELL skipped: price already below PDL at the window start");
  }

// SWEEP: checked once per closed M5 candle.
void Sweep()
  {
   datetime bar = iTime(_Symbol, PERIOD_M5, 0);
   if(bar == lastBar) return;
   bool first = (lastBar == 0);
   lastBar = bar;
   if(first || iTime(_Symbol, PERIOD_M5, 1) < day + winStart * 60) return;

   double h = iHigh(_Symbol, PERIOD_M5, 1), l = iLow(_Symbol, PERIOD_M5, 1);
   double c = iClose(_Symbol, PERIOD_M5, 1), cPrev = iClose(_Symbol, PERIOD_M5, 2);
   for(int k = 0; k < 2; k++)
     {
      if(sideDone[k]) continue;
      bool   high   = (k == 0);
      double level  = high ? pdh : pdl;
      double beyond = high ? h - level : level - l;
      if(!swept[k])
        {
         bool startedInside = high ? cPrev <= level : cPrev >= level;
         if(!startedInside || beyond < SWEEP_MIN) continue;
         swept[k] = true; swExt[k] = high ? h : l; swBars[k] = 0;
         PrintFormat("%s swept: %.*f (%.2f beyond)", high ? "PDH" : "PDL", _Digits, swExt[k], beyond);
        }
      else
        {
         swExt[k] = high ? MathMax(swExt[k], h) : MathMin(swExt[k], l);
         swBars[k]++;
        }
      bool inside = high ? c < level : c > level;
      if(!inside)
        {
         if(swBars[k] >= SWEEP_BARS) { sideDone[k] = true; PrintFormat("%s: no close back inside in %d candles - real breakout", high ? "PDH" : "PDL", SWEEP_BARS); }
         continue;
        }
      sideDone[k] = true;                                       // one attempt per side per day
      bool   buy  = !high;
      double px   = buy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl   = Norm(buy ? swExt[k] - SWEEP_BUF : swExt[k] + SWEEP_BUF);
      double dist = MathAbs(px - sl);
      double tp   = Norm(buy ? px + dist * InpRR : px - dist * InpRR);
      if(dist > InpSL_USD) { PrintFormat("%s reclaimed but SL $%.2f > max $%g - skipped", high ? "PDH" : "PDL", dist, InpSL_USD); continue; }
      double lot = Lot(buy, px, sl);
      if(lot <= 0) continue;
      if(buy) trade.Buy(lot, _Symbol, 0, sl, tp, "PDL_SWEEP_BUY");
      else    trade.Sell(lot, _Symbol, 0, sl, tp, "PDH_SWEEP_SELL");
      return;
     }
  }

// Optimisation ranges start from 1 (MetaTrader's table shows its own numbers, these are used).
int OnTesterInit()
  {
   bool on; double v, a, b, c;
   if(ParameterGetRange("InpSL_USD", on, v, a, b, c)) ParameterSetRange("InpSL_USD", on, v, 1.0, 0.5, 50.0);
   if(ParameterGetRange("InpRR", on, v, a, b, c))     ParameterSetRange("InpRR", on, v, 1.0, 0.5, 10.0);
   string bt[] = {"InpBE_Trigger", "InpBE_Lock", "InpTrailStart", "InpTrailDist"};
   for(int i = 0; i < ArraySize(bt); i++)
      if(ParameterGetRange(bt[i], on, v, a, b, c)) ParameterSetRange(bt[i], on, v, 0.1, 0.1, 100.0);
   Print("Optimisation ranges: SL 1..50 step 0.5, RR 1..10 step 0.5, breakeven/trailing 0.1..100 step 0.1");
   return INIT_SUCCEEDED;
  }

void OnTesterDeinit() { }
//+------------------------------------------------------------------+
