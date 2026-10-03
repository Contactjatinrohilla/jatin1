//+------------------------------------------------------------------+
//|              XAUUSD_Simple_Breakout.mq5   v7.82                   |
//|                                                                  |
//|  A deliberately small rewrite of the PDH/PDL + London idea.       |
//|                                                                  |
//|  SETUP A  Previous-day high/low (PDH/PDL), active from PDHStart.  |
//|  SETUP B  Session range (default = London 08:00-16:00 London time)|
//|           = highest high / lowest low of the M1 bars from         |
//|           RangeStart to RangeEnd, active from RangeEnd.           |
//|  SETUP C  4H straddle: previous completed H4 candle high/low, a   |
//|           new straddle each H4 candle that opens inside the       |
//|           H4From-H4To window; unfilled orders end with the candle.|
//|                                                                  |
//|  ENTRY MODES (InpEntryMode, per-setup override - optimisable)    |
//|   Confirmation OFF = 0 STOP / 1 STOP-LIMIT; ON = 2 CLOSE / 3 RETEST |
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
//|   - Daily loss stop on closed + open P/L.                         |
//|   - Fixed breakeven and trailing stop, in $ like SL and TP:       |
//|     at +BE_Trigger the SL goes to entry + BE_Lock; from           |
//|     +TrailStart the SL follows TrailDist behind price.            |
//|                                                                  |
//|  OPTIMISATION: select "Custom max" in the Strategy Tester and     |
//|  pick what to maximise with InpScore (section 7).                 |
//|                                                                  |
//|  UNITS: all distances use InpDistUnit - PRICE (gold $, index     |
//|  points; default), POINTS or PIPS (forex). Works on any symbol:  |
//|  XAUUSD, NAS100/USTEC, EURUSD... (lots sized by the broker).     |
//|  TIMES: SERVER time. On a UTC+2/+3 server London 08:00 = 10:00 and |
//|  US data (08:30 New York) = 15:30. See docs/GUIDE.md.              |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout v7.82"
#property version   "7.82"

#include <Trade\Trade.mqh>

enum ENUM_ENTRY_MODE
  {
   ENTRY_STOP       = 0, // Stop order at the level
   ENTRY_STOP_LIMIT = 1, // Stop-limit: skip fills worse than MaxSlip
   ENTRY_CLOSE      = 2, // Market order after a candle CLOSES beyond the level
   ENTRY_RETEST     = 3  // Limit order back at the level after a close beyond it
  };

enum ENUM_ENTRY_OVERRIDE
  {
   EO_DEFAULT    = 0, // Same as Entry mode
   EO_STOP       = 1, // Confirmation OFF: stop order
   EO_STOP_LIMIT = 2, // Confirmation OFF: stop-limit
   EO_CLOSE      = 3, // Confirmation ON: candle close, market order
   EO_RETEST     = 4  // Confirmation ON: candle close, then retest limit
  };

enum ENUM_RANGE_TZ
  {
   RTZ_SERVER = 0, // Server time
   RTZ_IST    = 1, // India time (IST, UTC+5:30)
   RTZ_UTC    = 2  // UTC
  };

enum ENUM_SERVER_DST
  {
   SDST_US   = 0, // Summer +1h on US dates (most gold brokers)
   SDST_EU   = 1, // Summer +1h on EU dates
   SDST_NONE = 2  // No summer time (fixed offset)
  };

enum ENUM_DIST_UNIT
  {
   UNIT_PRICE  = 0, // Price (gold: 5.0 = $5 move; NAS100: 5.0 = 5 index points)
   UNIT_POINTS = 1, // Points (the symbol's smallest price step)
   UNIT_PIPS   = 2  // Pips (forex: 1 pip = 10 points on 5/3-digit pairs)
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

input group "=== 0. Symbol / units ==="
input ENUM_DIST_UNIT InpDistUnit = UNIT_PRICE; // Unit of ALL distance inputs (SL, BE, trail, spread, slip, buffer...)

input group "=== 1. Setups (SERVER time, HH:MM) ==="
input bool   InpUsePDH          = true;     // Setup A: previous-day high/low breakout
input string InpPDHStart        = "01:15";  // A: active from
input bool   InpUseRange        = true;     // Setup B: session-range breakout
input string InpRangeStart      = "10:00";  // B: range start (10:00 server = London 08:00)
input string InpRangeEnd        = "18:00";  // B: range end = active from (18:00 server = London 16:00)
input ENUM_RANGE_TZ InpRangeTZ  = RTZ_SERVER; // B: range start/end are typed in this time zone
input int    InpServerUTCWinter = 2;        // Broker server UTC offset in winter (hours)
input ENUM_SERVER_DST InpServerDST = SDST_US; // Broker server summer-time rule
input bool   InpUse4H           = false;    // Setup C: 4H candle high/low straddle
input string InpH4From          = "08:00";  // C: only H4 candles opening at/after this time
input string InpH4To            = "20:00";  // C: ...and before this time (H4 opens 00,04,08,12,16,20)
input string InpTradeEnd        = "22:00";  // Delete unfilled orders / stop new entries at
input string InpCloseTime       = "22:15";  // Close open trades at (see CloseMode)
input ENUM_CLOSE_MODE InpCloseMode = CLOSE_DAILY; // When CloseTime applies

input group "=== 2. Entry ==="
input ENUM_ENTRY_MODE InpEntryMode = ENTRY_STOP; // Entry mode (0/1 = confirmation OFF, 2/3 = ON)
input ENUM_ENTRY_OVERRIDE InpEntryPDH   = EO_DEFAULT; // PDH setup entry
input ENUM_ENTRY_OVERRIDE InpEntryRange = EO_DEFAULT; // RANGE setup entry
input ENUM_ENTRY_OVERRIDE InpEntryH4    = EO_DEFAULT; // 4H setup entry
input ENUM_DIRECTION  InpDirection = DIR_BOTH;   // Direction
input ENUM_TIMEFRAMES InpConfirmTF = PERIOD_M5;  // Candle for CLOSE / RETEST modes
input double InpBuffer_USD      = 0.00;     // Entry this far beyond the level
input double InpMaxSlip_USD     = 0.50;     // STOP-LIMIT: max fill distance past the level
input double InpMaxChase_USD    = 3.00;     // CLOSE/RETEST: ignore closes further than this past the level (0 = off)
input double InpMaxSpread_USD   = 0.60;     // Wait while the spread is wider than this
input bool   InpSkipBroken      = true;     // STOP modes: skip a side whose level price already traded through
input double InpBrokenTol_USD   = 0.00;     // ...counts as broken when price came within this of the level

input group "=== 3. Exit (distances in the unit chosen in section 0) ==="
input double InpSL_USD          = 14.00;    // Stop loss distance (gold: $14 = 1400 points; tested best $11-16)
input double InpRR              = 3.0;      // Take profit = SL x this (0 = no TP; above ~5 changes nothing)
input double InpBE_Trigger_USD  = 14.00;    // Breakeven: move SL to entry when the trade is this much in profit (0 = off; ~1x SL)
input double InpBE_Lock_USD     = 0.50;     // Breakeven: put the SL this much past entry (covers spread)
input double InpTrailStart_USD  = 20.00;    // Trailing: starts when the trade is this much in profit (0 = off)
input double InpTrailDist_USD   = 8.00;     // Trailing: SL stays this far behind price
input double InpTrailStep_USD   = 0.50;     // Trailing: move the SL only when it gains at least this


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
input double InpRiskPct         = 0.5;      // Risk % of balance per trade
input int    InpMaxTradesDay    = 2;        // Max trades per day (all setups together)
input double InpMaxDailyLossPct = 2.5;      // Close all + stop for the day at this loss % (0 = off)
input ulong  InpMagic           = 700000;   // Magic base (A = +1, B = +2, C = +3)

input group "=== 6. Optimisation: Custom max (Strategy Tester only) ==="
input ENUM_SCORE InpScore       = SCORE_ROBUST; // What "Custom max" maximises
input int    InpMinTrades       = 100;      // Score 0 below this many trades
input double InpScoreMaxDD      = 20.0;     // Score 0 if max equity DD % is above this (0 = off)
input double InpScoreWorstR     = 3.0;      // Score 0 if any trade lost more than this many R (0 = off)

input group "=== 7. Diagnostics ==="
input bool   InpTradeLog        = true;     // Write every trade to Common\Files\SB_trades_<symbol>.csv (single tests, not optimisation)
input int    InpPostExitMin     = 240;      // ...and follow price this many minutes after the exit
input string InpLogTag          = "";       // Added to the log file name, e.g. T03 -> SB_trades_<symbol>_T03.csv

input group "=== 8. Optimisation ranges (set by the code) ==="
input bool   InpFixedRanges     = true;     // SL, TP (RR), breakeven, trailing: optimise Start..Stop by Step below
input double InpOptStart        = 0.05;     // ...Start
input double InpOptStep         = 0.05;     // ...Step
input double InpOptStop         = 100.0;    // ...Stop

// Distance inputs converted to price once in OnInit (see InpDistUnit).
double   g_unit, g_SL, g_BEtrig, g_BElock, g_TrStart, g_TrDist, g_TrStep;
double   g_Buf, g_Slip, g_Chase, g_Spread, g_BrkTol, g_MinLvl, g_MaxLvl;

#define SET_PDH   0
#define SET_RANGE 1
#define SET_H4    2
#define NSETS     3

CTrade   g_trade;
ulong    g_magic[NSETS];
string   g_name[NSETS] = {"PDH", "RANGE", "H4"};
int      g_tPDH, g_tRangeStart, g_tRangeEnd, g_tTradeEnd, g_tClose;   // minutes after server midnight
int      g_tH4From, g_tH4To;
int      g_rangeStartIn, g_rangeEndIn;   // range times as typed (in InpRangeTZ)
bool     g_rangeDayOk  = true;           // converted range window is usable today
datetime g_h4Start     = 0;    // open time of the current H4 candle
int      g_w1s = -1, g_w1e = -1, g_w2s = -1, g_w2e = -1;              // no-trade windows
datetime g_day         = 0;
int      g_closeToday  = -1;   // effective close minute today (-1 = none)
bool     g_used[NSETS];            // setup placed / traded - not re-tried until re-armed
bool     g_filled[NSETS];          // setup produced a trade today
bool     g_spreadLog[NSETS];
bool     g_levelLog[NSETS];
bool     g_levelOk[NSETS];
datetime g_lastBar[NSETS];
bool     g_dayBlocked  = false;
bool     g_halted      = false;
bool     g_stopLimitOk = true;
int      g_tradesToday = 0;
double   g_dayStartBal = 0;
bool     g_recount     = true;
double   g_rangeHi     = 0, g_rangeLo = 0;
double   g_openRisk    = 0;    // money risked by the open trade (for R statistics)
double   g_curR        = 0;    // R of the open trade (summed over its closing deals)
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

bool IsOurMagic(ulong m) { return m == g_magic[SET_PDH] || m == g_magic[SET_RANGE] || m == g_magic[SET_H4]; }
int  SetOf(ulong m)      { return (m == g_magic[SET_PDH]) ? SET_PDH : (m == g_magic[SET_RANGE]) ? SET_RANGE : SET_H4; }
bool SetEnabled(int s)   { return s == SET_PDH ? InpUsePDH : s == SET_RANGE ? InpUseRange : InpUse4H; }
bool DirOK(bool isBuy)   { return InpDirection == DIR_BOTH || (isBuy ? InpDirection == DIR_BUY : InpDirection == DIR_SELL); }
// Entry mode of setup s: its own override, or the global InpEntryMode.
ENUM_ENTRY_MODE EntryModeOf(int s)
  {
   ENUM_ENTRY_OVERRIDE o = (s == SET_PDH) ? InpEntryPDH : (s == SET_RANGE) ? InpEntryRange : InpEntryH4;
   if(o == EO_DEFAULT) return InpEntryMode;
   return (ENUM_ENTRY_MODE)((int)o - 1);
  }

bool UsesConfirmation(int s) { ENUM_ENTRY_MODE m = EntryModeOf(s); return m == ENTRY_CLOSE || m == ENTRY_RETEST; }

// Time from which setup s may enter (PDH / RANGE: today's start time; H4: the current H4 candle).
datetime ActiveTime(int s)
  {
   if(s == SET_PDH)   return g_day + g_tPDH * 60;
   if(s == SET_RANGE) return g_day + g_tRangeEnd * 60;
   return g_h4Start;
  }

// H4 setup only for candles opening inside the H4From-H4To window.
bool H4Allowed()
  {
   if(g_h4Start <= 0) return false;
   int m = (int)(((long)g_h4Start % 86400) / 60);
   return m >= g_tH4From && m < g_tH4To;
  }

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
int DeletePendings(string why, datetime olderThan = 0, int setMask = 7)
  {
   int mask = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(!IsOurMagic(mg) || (setMask & (1 << SetOf(mg))) == 0) continue;
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
   for(int s = 0; s < NSETS; s++)
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
   if(spread <= g_Spread) return true;
   if(!g_spreadLog[s])
     {
      PrintFormat("[%s] waiting: spread %g > max %g", g_name[s], spread, g_Spread);
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
   for(int s = 0; s < NSETS; s++) g_filled[s] = false;
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
         int s = SetOf(mg);
         // H4 "filled" means: in the current H4 candle; PDH / RANGE: today.
         if(s != SET_H4 || (datetime)HistoryDealGetInteger(d, DEAL_TIME) >= g_h4Start) g_filled[s] = true;
        }
     }
   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE) - closed;
  }

// A setup is used if it already traded (today / this H4 candle) or still has a live order.
void RecoverUsed()
  {
   for(int s = 0; s < NSETS; s++) g_used[s] = g_filled[s];
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(!IsOurMagic(mg)) continue;
      datetime since = (SetOf(mg) == SET_H4) ? g_h4Start : g_day;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) >= since) g_used[SetOf(mg)] = true;
     }
  }

int DayOfWeekOf(int y, int m, int d)
  {
   MqlDateTime t; ZeroMemory(t); t.year = y; t.mon = m; t.day = d;
   MqlDateTime o; TimeToStruct(StructToTime(t), o);
   return o.day_of_week;
  }
int NthSunday(int y, int m, int n) { return 1 + (7 - DayOfWeekOf(y, m, 1)) % 7 + 7 * (n - 1); }
int LastSunday(int y, int m)
  {
   int dim = (m == 3 || m == 10) ? 31 : 30;
   return dim - DayOfWeekOf(y, m, dim);
  }

// Broker server UTC offset (minutes) on the given server day.
int ServerOffsetMin(datetime day)
  {
   MqlDateTime t; TimeToStruct(day, t);
   int md = t.mon * 100 + t.day;
   bool dst = false;
   if(InpServerDST == SDST_US) dst = md >= 300 + NthSunday(t.year, 3, 2) && md < 1100 + NthSunday(t.year, 11, 1);
   if(InpServerDST == SDST_EU) dst = md >= 300 + LastSunday(t.year, 3) && md < 1000 + LastSunday(t.year, 10);
   return (InpServerUTCWinter + (dst ? 1 : 0)) * 60;
  }

// Converts the typed range times to server minutes for this day (IST has no summer time,
// so the server window moves by an hour when the broker changes clocks).
void ApplyRangeTZ(datetime day)
  {
   int prevS = g_tRangeStart, prevE = g_tRangeEnd;
   if(InpRangeTZ == RTZ_SERVER) { g_tRangeStart = g_rangeStartIn; g_tRangeEnd = g_rangeEndIn; }
   else
     {
      int zone = (InpRangeTZ == RTZ_IST) ? 330 : 0;
      int srv  = ServerOffsetMin(day);
      g_tRangeStart = ((g_rangeStartIn - zone + srv) % 1440 + 1440) % 1440;
      g_tRangeEnd   = ((g_rangeEndIn   - zone + srv) % 1440 + 1440) % 1440;
     }
   g_rangeDayOk = (g_tRangeStart < g_tRangeEnd && g_tRangeEnd < g_tTradeEnd);
   if(InpUseRange && (prevS != g_tRangeStart || prevE != g_tRangeEnd))
      PrintFormat("[RANGE] window %s-%s %s = %02d:%02d-%02d:%02d server%s", InpRangeStart, InpRangeEnd,
                  InpRangeTZ == RTZ_IST ? "IST" : InpRangeTZ == RTZ_UTC ? "UTC" : "server",
                  g_tRangeStart / 60, g_tRangeStart % 60, g_tRangeEnd / 60, g_tRangeEnd % 60,
                  g_rangeDayOk ? "" : " -> NOT USABLE (must end before TradeEnd and not cross midnight)");
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
   ApplyRangeTZ(day);
   g_halted  = false;
   g_rangeHi = 0;
   g_rangeLo = 0;
   for(int s = 0; s < NSETS; s++) { g_spreadLog[s] = false; g_levelLog[s] = false; g_levelOk[s] = false; }
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

// New H4 candle: the previous candle's unfilled H4 orders end, the H4 setup starts fresh.
void NewH4(datetime h)
  {
   g_h4Start = h;
   if(!InpUse4H) return;
   DeletePendings("previous 4H candle ended", h, 1 << SET_H4);
   g_spreadLog[SET_H4] = false;
   g_levelLog[SET_H4]  = false;
   g_levelOk[SET_H4]   = false;
   g_recount = true;
   RecountToday();
   RecoverUsed();
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

bool GetH4(double &hi, double &lo)
  {
   MqlRates r[];
   if(CopyRates(_Symbol, PERIOD_H4, 0, 2, r) < 2) return false;
   if(r[1].time != g_h4Start) return false;   // current H4 bar not built yet (r[0] = previous candle)
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

// Level line from the moment the level is KNOWN (t1) to the end of its trading window (t2).
void DrawLevel(string name, datetime t1, datetime t2, double price, color clr, string label)
  {
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   string txt = StringFormat("%s %.*f", label, _Digits, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, txt);
  }

// Shaded box over the window the range was measured in (drawn once the range has ended).
void DrawBox(string name, datetime t1, datetime t2, double hi, double lo, color clr)
  {
   if(ObjectFind(0, name) >= 0) return;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, t1, hi, t2, lo);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, StringFormat("range window: high %.*f low %.*f", _Digits, hi, _Digits, lo));
  }

// Levels for setup s, checked against the level-size filter (logged and drawn once per day).
bool GetLevels(int s, double &hi, double &lo)
  {
   bool ok = (s == SET_PDH) ? GetPDH(hi, lo) : (s == SET_RANGE) ? GetRange(hi, lo) : GetH4(hi, lo);
   if(!ok) return false;
   if(!g_levelLog[s])
     {
      g_levelLog[s] = true;
      double size = hi - lo;
      g_levelOk[s] = !((g_MinLvl > 0 && size < g_MinLvl) ||
                       (g_MaxLvl > 0 && size > g_MaxLvl));
      PrintFormat("[%s] levels high=%.*f low=%.*f size=%g%s", g_name[s], _Digits, hi, _Digits, lo, size,
                  g_levelOk[s] ? "" : " -> SKIPPED by level-size filter");
      if(!MQLInfoInteger(MQL_OPTIMIZATION))
        {
         // Lines start when the level is known: PDH at PDHStart, RANGE at RangeEnd, H4 at the candle open.
         datetime t1 = ActiveTime(s);
         datetime t2 = (s == SET_H4) ? g_h4Start + 4 * 3600 : g_day + g_tTradeEnd * 60;
         string   id = TimeToString(s == SET_H4 ? g_h4Start : g_day, TIME_DATE | TIME_MINUTES);
         color    ch = (s == SET_PDH) ? clrDodgerBlue : (s == SET_RANGE) ? clrLime : clrMagenta;
         color    cl = (s == SET_PDH) ? clrOrangeRed : (s == SET_RANGE) ? clrYellow : clrAqua;
         string   nm = (s == SET_PDH) ? "PDH" : (s == SET_RANGE) ? "RANGE high" : "4H high";
         string   nl = (s == SET_PDH) ? "PDL" : (s == SET_RANGE) ? "RANGE low" : "4H low";
         DrawLevel(g_name[s] + "_H_" + id, t1, t2, hi, ch, nm);
         DrawLevel(g_name[s] + "_L_" + id, t1, t2, lo, cl, nl);
         if(s == SET_RANGE)
            DrawBox("RANGE_BOX_" + id, g_day + g_tRangeStart * 60, g_day + g_tRangeEnd * 60, hi, lo, C'40,40,70');
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
   double sl  = Norm(isBuy ? entry - g_SL : entry + g_SL);
   double tp  = (InpRR > 0) ? Norm(isBuy ? entry + g_SL * InpRR : entry - g_SL * InpRR) : 0.0;
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

// Start of the period in which a level counts as "already broken":
// PDH from the start of the day, RANGE from the range end, H4 from the H4 candle open.
datetime BrokenSince(int s) { return (s == SET_PDH) ? g_day : ActiveTime(s); }

// True if price has already reached the entry level of this side since BrokenSince(s)
// (e.g. during the blackout before PDHStart, a no-trade window, or while another trade
// was open) - a breakout that already happened and came back is not traded again.
bool LevelBroken(int s, bool isBuy, double level)
  {
   if(!InpSkipBroken) return false;
   datetime from = BrokenSince(s);
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, from, TimeCurrent(), r);
   if(n <= 0) return false;
   double ext = isBuy ? r[0].high : r[0].low;
   for(int i = 1; i < n; i++) ext = isBuy ? MathMax(ext, r[i].high) : MathMin(ext, r[i].low);
   bool broken = isBuy ? (ext >= level - g_BrkTol) : (ext <= level + g_BrkTol);
   if(broken)
      PrintFormat("[%s] %s skipped: price already traded %s %.*f since %s (%s %.*f) - broken level, not re-entered",
                  g_name[s], isBuy ? "BUY" : "SELL", isBuy ? "up to" : "down to", _Digits, level,
                  TimeToString(from, TIME_DATE | TIME_MINUTES), isBuy ? "high" : "low", _Digits, ext);
   return broken;
  }

// STOP / STOP-LIMIT modes: the straddle is placed once (re-placed only after a re-arm).
void PlaceStraddle(int s, double hi, double lo)
  {
   if(!SpreadOK(s)) return;
   g_used[s] = true;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   bool   useStopLimit = (EntryModeOf(s) == ENTRY_STOP_LIMIT && g_stopLimitOk);
   double buyAt   = Norm(hi + g_Buf);
   double sellAt  = Norm(lo - g_Buf);

   if(!DirOK(true)) { }
   else if(buyAt - ask > minDist && LevelBroken(s, true, buyAt)) { }
   else if(buyAt - ask > minDist)
      SendOrder(s, useStopLimit ? ORDER_TYPE_BUY_STOP_LIMIT : ORDER_TYPE_BUY_STOP, buyAt, useStopLimit ? Norm(buyAt + g_Slip) : 0);
   else PrintFormat("[%s] BUY skipped: ask %.*f is already at/above %.*f", g_name[s], _Digits, ask, _Digits, buyAt);

   if(!DirOK(false)) { }
   else if(bid - sellAt > minDist && LevelBroken(s, false, sellAt)) { }
   else if(bid - sellAt > minDist)
      SendOrder(s, useStopLimit ? ORDER_TYPE_SELL_STOP_LIMIT : ORDER_TYPE_SELL_STOP, sellAt, useStopLimit ? Norm(sellAt - g_Slip) : 0);
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
   if(iTime(_Symbol, InpConfirmTF, 1) < ActiveTime(s)) return;   // candle began before the setup was active

   double c = iClose(_Symbol, InpConfirmTF, 1);
   bool isBuy = false;
   if(c > hi + g_Buf && DirOK(true))       isBuy = true;
   else if(c < lo - g_Buf && DirOK(false)) isBuy = false;
   else return;

   double level  = Norm(isBuy ? hi + g_Buf : lo - g_Buf);
   double beyond = isBuy ? c - level : level - c;
   if(g_Chase > 0 && beyond > g_Chase)
     {
      PrintFormat("[%s] %s close %.*f is %g past the level (> MaxChase %g) - ignored", g_name[s],
                  isBuy ? "BUY" : "SELL", _Digits, c, beyond, g_Chase);
      return;
     }
   if(!SpreadOK(s)) return;
   PrintFormat("[%s] CONFIRMED %s: %s candle closed %.*f beyond %.*f", g_name[s], isBuy ? "BUY" : "SELL",
               StringSubstr(EnumToString(InpConfirmTF), 7), _Digits, c, _Digits, level);

   bool sent;
   if(EntryModeOf(s) == ENTRY_CLOSE)
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

// Breakeven and trailing stop, both fixed distances in USD of price (like SL and TP).
//   profit >= BE_Trigger   -> SL = entry + BE_Lock (buy) / entry - BE_Lock (sell)
//   profit >= TrailStart   -> SL = price - TrailDist (buy) / price + TrailDist (sell)
// The SL only ever moves in the trade's favour, and is kept outside the broker's
// stop / freeze distance. Every move (or rejection) is written to the journal.
void ManageStops()
  {
   if(g_BEtrig <= 0 && g_TrStart <= 0) return;
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double guard = MathMax(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                          SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * _Point + _Point;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg)) continue;
      bool   buy    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl     = PositionGetDouble(POSITION_SL);
      double tp     = PositionGetDouble(POSITION_TP);
      double px     = buy ? bid : ask;                    // price the position closes at
      double profit = buy ? bid - open : open - ask;      // USD of price

      double newSL = sl;
      string why   = "";
      // 1) breakeven
      if(g_BEtrig > 0 && profit >= g_BEtrig)
        {
         double be = Norm(buy ? open + g_BElock : open - g_BElock);
         if(newSL <= 0 || (buy ? be > newSL : be < newSL)) { newSL = be; why = "breakeven"; }
        }
      // 2) trailing stop (moves only in steps of at least TrailStep)
      if(g_TrStart > 0 && profit >= g_TrStart)
        {
         double tr = Norm(buy ? px - g_TrDist : px + g_TrDist);
         double gain = (newSL <= 0) ? DBL_MAX : (buy ? tr - newSL : newSL - tr);
         if(gain >= MathMax(g_TrStep, _Point)) { newSL = tr; why = "trailing"; }
        }
      if(why == "") continue;

      // keep the broker's minimum distance from price
      if(buy ? (px - newSL < guard) : (newSL - px < guard)) newSL = Norm(buy ? px - guard : px + guard);
      if(sl > 0 && (buy ? newSL <= sl : newSL >= sl)) continue;   // never move backwards

      g_trade.SetExpertMagicNumber(mg);
      if(g_trade.PositionModify(t, newSL, tp))
         PrintFormat("Position #%I64u SL %.*f -> %.*f (%s at +%g profit)", t, _Digits, sl, _Digits, newSL, why, profit);
      else
         PrintFormat("Position #%I64u SL move to %.*f (%s) REJECTED: %u %s", t, _Digits, newSL, why,
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//|  Trade log (diagnostics)                                         |
//|  One CSV row per trade: entry level / fill / slippage / spread,   |
//|  best (MFE) and worst (MAE) excursion while open, exit reason,    |
//|  and the best move in the trade's direction during PostExitMin    |
//|  minutes after the exit - shows whether a stop was a real         |
//|  reversal or noise that later ran to the target.                  |
//+------------------------------------------------------------------+
struct STradeRec
  {
   ulong    pos;
   string   setup;
   bool     buy;
   datetime tOpen;
   datetime tClose;
   datetime tMfe;
   datetime postUntil;
   double   level;
   double   fill;
   double   sl0;
   double   tp0;
   double   spread;
   double   lots;
   double   mfe;
   double   mae;
   double   closePx;
   double   profit;
   double   postBest;
   string   reason;
  };
STradeRec g_tlOpen[];
STradeRec g_tlDone[];
int       g_tlFile = INVALID_HANDLE;

string TLPx(double v) { return DoubleToString(v, _Digits); }

void TL_Init()
  {
   if(!InpTradeLog || MQLInfoInteger(MQL_OPTIMIZATION)) return;
   string name = "SB_trades_" + _Symbol + (InpLogTag != "" ? "_" + InpLogTag : "") + ".csv";
   g_tlFile = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(g_tlFile == INVALID_HANDLE) { PrintFormat("Trade log: cannot open %s (error %d)", name, GetLastError()); return; }
   FileWrite(g_tlFile, "setup", "side", "open_time", "level", "fill", "entry_slip", "spread_at_entry", "sl_dist", "tp_dist",
             "lots", "mfe", "mae", "mfe_r", "mae_r", "min_to_mfe", "close_time", "close_price", "exit_reason", "profit",
             "r", "hold_min", "post_exit_min", "post_best", "post_best_r", "tp_hit_after_exit", "sl_dist_in_units");
   PrintFormat("Trade log: writing %s to the terminal's Common\\Files folder", name);
  }

void TL_Write(STradeRec &r)
  {
   if(g_tlFile == INVALID_HANDLE) return;
   double sl    = (r.sl0 > 0) ? MathAbs(r.level - r.sl0) : g_SL;
   double tp    = (r.tp0 > 0) ? MathAbs(r.level - r.tp0) : 0;
   double slip  = r.buy ? r.fill - r.level : r.level - r.fill;
   double risk  = (sl > 0) ? sl : g_SL;
   double move  = r.buy ? r.closePx - r.fill : r.fill - r.closePx;
   bool   post  = (r.postBest > -1e8);
   double tpFill = (r.tp0 > 0) ? (r.buy ? r.tp0 - r.fill : r.fill - r.tp0) : 0;
   string tpHit = (r.tp0 > 0 && post) ? (r.postBest >= tpFill ? "1" : "0") : "";
   FileWrite(g_tlFile, r.setup, r.buy ? "BUY" : "SELL", TimeToString(r.tOpen, TIME_DATE | TIME_SECONDS),
             TLPx(r.level), TLPx(r.fill), TLPx(slip), TLPx(r.spread), TLPx(sl), TLPx(tp),
             DoubleToString(r.lots, 2), TLPx(r.mfe), TLPx(r.mae),
             DoubleToString(r.mfe / risk, 3), DoubleToString(r.mae / risk, 3),
             DoubleToString((double)(r.tMfe - r.tOpen) / 60.0, 1),
             r.tClose > 0 ? TimeToString(r.tClose, TIME_DATE | TIME_SECONDS) : "open",
             TLPx(r.closePx), r.reason, DoubleToString(r.profit, 2), DoubleToString(move / risk, 3),
             DoubleToString((double)(r.tClose - r.tOpen) / 60.0, 1), IntegerToString(InpPostExitMin),
             post ? TLPx(r.postBest) : "", post ? DoubleToString(r.postBest / risk, 3) : "", tpHit,
             DoubleToString(risk / g_unit, 2));
   FileFlush(g_tlFile);
  }

void TL_Open(ulong deal)
  {
   if(g_tlFile == INVALID_HANDLE) return;
   STradeRec r;
   r.pos   = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   r.setup = g_name[SetOf((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC))];
   r.buy   = (HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY);
   r.tOpen = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   r.fill  = HistoryDealGetDouble(deal, DEAL_PRICE);
   r.lots  = HistoryDealGetDouble(deal, DEAL_VOLUME);
   r.level = r.fill;
   ulong ord = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
   if(HistoryOrderSelect(ord))
     {
      double op = HistoryOrderGetDouble(ord, ORDER_PRICE_OPEN);
      if(op > 0) r.level = op;                                   // the order (level) price
     }
   r.sl0 = 0;
   r.tp0 = 0;
   if(PositionSelectByTicket(r.pos)) { r.sl0 = PositionGetDouble(POSITION_SL); r.tp0 = PositionGetDouble(POSITION_TP); }
   r.spread    = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   r.mfe       = 0;
   r.mae       = 0;
   r.tMfe      = r.tOpen;
   r.tClose    = 0;
   r.postUntil = 0;
   r.closePx   = 0;
   r.profit    = 0;
   r.postBest  = -1e9;
   r.reason    = "";
   int n = ArraySize(g_tlOpen);
   ArrayResize(g_tlOpen, n + 1);
   g_tlOpen[n] = r;
  }

void TL_Close(ulong deal, double profitTotal)
  {
   if(g_tlFile == INVALID_HANDLE) return;
   ulong pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   int   n   = ArraySize(g_tlOpen);
   for(int i = 0; i < n; i++)
     {
      if(g_tlOpen[i].pos != pos) continue;
      STradeRec r = g_tlOpen[i];
      r.tClose  = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      r.closePx = HistoryDealGetDouble(deal, DEAL_PRICE);
      r.profit  = profitTotal;
      long why  = HistoryDealGetInteger(deal, DEAL_REASON);
      r.reason  = (why == DEAL_REASON_SL) ? "SL" : (why == DEAL_REASON_TP) ? "TP" :
                  (why == DEAL_REASON_EXPERT) ? "EA_close" : (why == DEAL_REASON_SO) ? "stop_out" : "other";
      if(r.reason == "SL" && (r.buy ? r.closePx >= r.fill : r.closePx <= r.fill)) r.reason = "BE_or_trail_stop";
      r.postUntil = r.tClose + InpPostExitMin * 60;
      int d = ArraySize(g_tlDone);
      ArrayResize(g_tlDone, d + 1);
      g_tlDone[d] = r;
      for(int j = i; j < n - 1; j++) g_tlOpen[j] = g_tlOpen[j + 1];
      ArrayResize(g_tlOpen, n - 1);
      return;
     }
  }

// Per tick: excursions of open trades, post-exit tracking of closed ones.
void TL_OnTick()
  {
   if(g_tlFile == INVALID_HANDLE) return;
   double   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_tlOpen); i++)
     {
      double fav = g_tlOpen[i].buy ? bid - g_tlOpen[i].fill : g_tlOpen[i].fill - ask;
      if(fav > g_tlOpen[i].mfe) { g_tlOpen[i].mfe = fav; g_tlOpen[i].tMfe = now; }
      if(-fav > g_tlOpen[i].mae) g_tlOpen[i].mae = -fav;
     }
   int n = ArraySize(g_tlDone);
   for(int i = n - 1; i >= 0; i--)
     {
      double fav = g_tlDone[i].buy ? bid - g_tlDone[i].fill : g_tlDone[i].fill - ask;
      if(fav > g_tlDone[i].postBest) g_tlDone[i].postBest = fav;
      if(now < g_tlDone[i].postUntil) continue;
      TL_Write(g_tlDone[i]);
      for(int j = i; j < ArraySize(g_tlDone) - 1; j++) g_tlDone[j] = g_tlDone[j + 1];
      ArrayResize(g_tlDone, ArraySize(g_tlDone) - 1);
     }
  }

void TL_Finish()
  {
   if(g_tlFile == INVALID_HANDLE) return;
   for(int i = 0; i < ArraySize(g_tlDone); i++) TL_Write(g_tlDone[i]);   // post-exit window cut short by the end of the test
   for(int i = 0; i < ArraySize(g_tlOpen); i++) { g_tlOpen[i].reason = "still_open"; TL_Write(g_tlOpen[i]); }
   FileClose(g_tlFile);
   g_tlFile = INVALID_HANDLE;
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
   double pip = (_Digits == 3 || _Digits == 5) ? 10 * _Point : _Point;
   g_unit   = (InpDistUnit == UNIT_POINTS) ? _Point : (InpDistUnit == UNIT_PIPS) ? pip : 1.0;
   g_SL     = InpSL_USD * g_unit;          g_BEtrig = InpBE_Trigger_USD * g_unit;  g_BElock = InpBE_Lock_USD * g_unit;
   g_TrStart= InpTrailStart_USD * g_unit;  g_TrDist = InpTrailDist_USD * g_unit;   g_TrStep = InpTrailStep_USD * g_unit;
   g_Buf    = InpBuffer_USD * g_unit;      g_Slip   = InpMaxSlip_USD * g_unit;     g_Chase  = InpMaxChase_USD * g_unit;
   g_Spread = InpMaxSpread_USD * g_unit;   g_BrkTol = InpBrokenTol_USD * g_unit;
   g_MinLvl = InpMinLevelRange_USD * g_unit; g_MaxLvl = InpMaxLevelRange_USD * g_unit;
   g_tPDH        = ParseHHMM(InpPDHStart);
   g_rangeStartIn = ParseHHMM(InpRangeStart);
   g_rangeEndIn   = ParseHHMM(InpRangeEnd);
   g_tRangeStart  = g_rangeStartIn;
   g_tRangeEnd    = g_rangeEndIn;
   g_tTradeEnd   = ParseHHMM(InpTradeEnd);
   g_tClose      = ParseHHMM(InpCloseTime);
   g_tH4From     = ParseHHMM(InpH4From);
   g_tH4To       = ParseHHMM(InpH4To);
   if(g_tPDH < 0 || g_tRangeStart < 0 || g_tRangeEnd < 0 || g_tTradeEnd < 0 || g_tClose == -2 ||
      g_tH4From < 0 || g_tH4To < 0)
      return Fail("times must be HH:MM, 00:00-23:59");
   if(!ParseWindow(InpNoTrade1, g_w1s, g_w1e) || !ParseWindow(InpNoTrade2, g_w2s, g_w2e))
      return Fail("no-trade windows must be HH:MM-HH:MM (or empty)");
   if(!InpUsePDH && !InpUseRange && !InpUse4H)    return Fail("all setups are off");
   if(InpUse4H && g_tH4From >= g_tH4To)           return Fail("H4From must be before H4To");
   if(g_BEtrig < 0 || g_BElock < 0)
      return Fail("breakeven values must be >= 0");
   if(g_BEtrig > 0 && g_BElock >= g_BEtrig)
      return Fail("BE_Lock must be smaller than BE_Trigger");
   if(g_TrStart < 0 || g_TrStep < 0) return Fail("trailing values must be >= 0");
   if(g_TrStart > 0 && g_TrDist <= 0) return Fail("TrailDist must be > 0");
   double spr = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(g_TrStart > 0 && spr > 0 && g_TrDist < 3 * spr)
      PrintFormat("WARNING: trail distance %g is less than 3x the current spread (%g) - normal noise will stop it out",
                  g_TrDist, spr);
   if(InpUsePDH && g_tPDH >= g_tTradeEnd)         return Fail("PDHStart must be before TradeEnd");
   if(InpUseRange && g_rangeStartIn >= 0 && g_rangeEndIn >= 0 && g_rangeStartIn >= g_rangeEndIn)
      return Fail("RangeStart must be before RangeEnd");
   if(InpUseRange && InpRangeTZ == RTZ_SERVER && g_tRangeEnd >= g_tTradeEnd)
      return Fail("RangeEnd must be before TradeEnd");
   if(InpServerUTCWinter < -12 || InpServerUTCWinter > 14) return Fail("ServerUTCWinter must be -12..14");
   if(g_tClose >= 0 && g_tClose < g_tTradeEnd)    return Fail("CloseTime must be at or after TradeEnd");
   if(g_SL <= 0 || InpRR < 0 || g_Buf < 0 || g_Spread <= 0 ||
      g_Slip < 0 || g_Chase < 0 || g_MinLvl < 0 || g_MaxLvl < 0)
      return Fail("SL / spread must be > 0; RR, BE, buffer, slip, chase, level filters must be >= 0");
   if(g_MaxLvl > 0 && g_MaxLvl <= g_MinLvl)
      return Fail("MaxLevelRange must be above MinLevelRange");
   if(InpRiskPct <= 0 || InpRiskPct > 5)          return Fail("RiskPct must be > 0 and <= 5");
   if(InpMaxTradesDay < 1)                        return Fail("MaxTradesDay must be >= 1");
   if(InpMinTrades < 0 || InpScoreMaxDD < 0 || InpScoreWorstR < 0) return Fail("score filters must be >= 0");
   if(InpPostExitMin < 0) return Fail("PostExitMin must be >= 0");

   double tpDist = g_SL * InpRR;
   if(InpRR > 0 && g_BEtrig >= tpDist)
      PrintFormat("WARNING: breakeven at +%g is at/after the TP at +%g - it will never trigger", g_BEtrig, tpDist);
   if(InpRR > 0 && g_TrStart >= tpDist)
      PrintFormat("WARNING: trailing starts at +%g, at/after the TP at +%g - it will never act (use RR 0 or a bigger RR)",
                  g_TrStart, tpDist);

   g_magic[SET_PDH]   = InpMagic + 1;
   g_magic[SET_RANGE] = InpMagic + 2;
   g_magic[SET_H4]    = InpMagic + 3;
   ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR, true);   // show the level labels on the chart
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints((ulong)MathMax(10, MathRound(g_Slip / _Point)));   // market-order slippage = MaxSlip
   for(int s = 0; s < NSETS; s++) g_lastBar[s] = 0;
   g_h4Start = 0;
   g_sumR = 0; g_worstR = 0; g_nR = 0; g_openRisk = 0; g_curR = 0;

   g_stopLimitOk = (SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE) & SYMBOL_ORDER_STOP_LIMIT) != 0;
   bool anyStopLimit = false;
   for(int s = 0; s < NSETS; s++) if(SetEnabled(s) && EntryModeOf(s) == ENTRY_STOP_LIMIT) anyStopLimit = true;
   if(anyStopLimit && !g_stopLimitOk)
      Print("WARNING: broker does not allow stop-limit orders on this symbol - using plain stop orders");

   PrintFormat("%s digits=%d point=%g | distances in %s (1 unit = %g price) | entry %s | SL %g = %.0f points | TP %s | BE %s | risk %.2f%% | max %d trades/day",
               _Symbol, _Digits, _Point, StringSubstr(EnumToString(InpDistUnit), 5), g_unit,
               EnumToString(InpEntryMode), g_SL, g_SL / _Point,
               InpRR > 0 ? StringFormat("%g", g_SL * InpRR) : "off",
               g_BEtrig > 0 ? StringFormat("at +%g (%.0f pts)", g_BEtrig, g_BEtrig / _Point) : "off",
               InpRiskPct, InpMaxTradesDay);
   for(int s = 0; s < NSETS; s++)
      if(SetEnabled(s))
         PrintFormat("[%s] entry %s - confirmation %s", g_name[s], EnumToString(EntryModeOf(s)),
                     UsesConfirmation(s) ? StringFormat("ON (%s candle close)", StringSubstr(EnumToString(InpConfirmTF), 7)) : "OFF");
   PrintFormat("Trailing %s", g_TrStart > 0 ?
               StringFormat("from +%g (%.0f pts), %g (%.0f pts) behind price, step %g", g_TrStart,
                            g_TrStart / _Point, g_TrDist, g_TrDist / _Point, g_TrStep) : "off");
   PrintFormat("4H straddle %s",
               InpUse4H ? StringFormat("ON for H4 candles %s-%s", InpH4From, InpH4To) : "off");
   PrintFormat("Server times: PDH from %s | range %s-%s | entries until %s | close %s | no-trade %s %s",
               InpPDHStart, InpRangeStart, InpRangeEnd, InpTradeEnd, (g_tClose < 0 || InpCloseMode == CLOSE_NEVER) ? "never" :
               (InpCloseMode == CLOSE_FRIDAY ? InpCloseTime + " Fridays" : InpCloseTime),
               InpNoTrade1 == "" ? "-" : InpNoTrade1, InpNoTrade2);
   TL_Init();
   return INIT_SUCCEEDED;
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   datetime day = (datetime)((long)now - (long)now % 86400);   // server midnight
   if(day != g_day) NewDay(day);
   datetime h4 = iTime(_Symbol, PERIOD_H4, 0);
   if(h4 > 0 && h4 != g_h4Start) NewH4(h4);
   if(g_recount) RecountToday();
   int mins = (int)((now - day) / 60);

   ManageStops();
   TL_OnTick();

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

   for(int s = 0; s < NSETS; s++)
     {
      if(!SetEnabled(s) || g_used[s] || g_filled[s] || now < ActiveTime(s)) continue;
      if(s == SET_H4 && !H4Allowed()) continue;
      if(s == SET_RANGE && !g_rangeDayOk) continue;
      double hi, lo;
      if(!GetLevels(s, hi, lo)) continue;
      if(!UsesConfirmation(s)) PlaceStraddle(s, hi, lo);
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
     {
      g_openRisk = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
      g_curR     = 0;
      TL_Open(trans.deal);
     }
   else if((entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY) && g_openRisk > 0)
     {
      double p = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                 HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
      g_curR += p / g_openRisk;
      ulong pos = (ulong)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
      if(!PositionSelectByTicket(pos))
        {
         g_sumR  += g_curR;
         g_nR++;
         g_worstR = MathMin(g_worstR, g_curR);
         PrintFormat("CLOSED %s %+.2f | whole trade %+.2fR", HistoryDealGetString(trans.deal, DEAL_COMMENT), p, g_curR);
         TL_Close(trans.deal, g_curR * g_openRisk);
         g_curR = 0;
        }
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
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|  Optimisation ranges from the code: when an optimisation starts,  |
//|  SL, RR, BE trigger/lock and the trailing inputs get the range    |
//|  InpOptStart..InpOptStop by InpOptStep, whatever the Inputs tab   |
//|  shows. Your ticks are kept: only ticked inputs are optimised.    |
//+------------------------------------------------------------------+
int OnTesterInit()
  {
   if(!InpFixedRanges) return INIT_SUCCEEDED;
   if(InpOptStep <= 0 || InpOptStop <= InpOptStart)
     {
      Print("Optimisation ranges: need Step > 0 and Stop > Start - Inputs tab ranges are used");
      return INIT_SUCCEEDED;
     }
   string names[] = {"InpSL_USD", "InpRR", "InpBE_Trigger_USD", "InpBE_Lock_USD",
                     "InpTrailStart_USD", "InpTrailDist_USD", "InpTrailStep_USD"};
   for(int i = 0; i < ArraySize(names); i++)
     {
      bool   on;
      double val, start, step, stop;
      if(!ParameterGetRange(names[i], on, val, start, step, stop)) continue;
      if(ParameterSetRange(names[i], on, val, InpOptStart, InpOptStep, InpOptStop))
         PrintFormat("Optimisation range %s: %g .. %g step %g%s", names[i], InpOptStart, InpOptStop, InpOptStep,
                     on ? " (optimised)" : " (not ticked - fixed at " + DoubleToString(val, 2) + ")");
      else
         PrintFormat("Optimisation range %s could not be set (error %d)", names[i], GetLastError());
     }
   return INIT_SUCCEEDED;
  }

void OnTesterDeinit() { }

void OnDeinit(const int reason)
  {
   TL_Finish();
  }
//+------------------------------------------------------------------+
