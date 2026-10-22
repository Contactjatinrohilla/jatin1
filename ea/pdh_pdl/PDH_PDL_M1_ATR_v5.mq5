//+------------------------------------------------------------------+
//| PDH_PDL_M1_ATR.mq5   v5.00 - killzone high/low like PDH/PDL      |
//|                                                                  |
//| v5.00 changes (PDH/PDL signals unchanged):                       |
//|  A. Session killzones: Asian, London, New York (+ optional       |
//|     London Close). Each killzone's HIGH and LOW are traded       |
//|     exactly like PDH and PDL: once the killzone has ended, the   |
//|     FIRST M1 close above its high = buy, the first M1 close      |
//|     below its low = sell. Only the first close counts (read from |
//|     M1 history, restart safe); a side whose first close cannot   |
//|     be traded is done. The levels stay live until the killzone's |
//|     trade-end time (default 24:00 = rest of the day, like PDH).  |
//|     SL / TP = ATR x multiplier, same as PDH/PDL (optional: SL at |
//|     the other side / middle of the killzone, TP as R multiple).  |
//|  B. On/off input for every strategy, plus chart buttons that     |
//|     switch each one on/off live (new entries only - open trades  |
//|     are kept). Button state survives timeframe change / restart; |
//|     changing the inputs resets it to the inputs.                 |
//|  C. Each strategy has its own magic: MagicNumber + 0 PDH/PDL,    |
//|     +1 Asia KZ, +2 London KZ, +3 New York KZ, +4 London Close KZ.|
//|     Loss caps, open risk and closing cover all of them. Keep     |
//|     MagicNumber+1..+4 free for other EAs. OneTradeAtATime        |
//|     (default) keeps v3's one trade per chart.                    |
//|  D. Chart: killzone boxes (last N days) with name and size, KZ   |
//|     high / low lines with price, distance from price and BROKEN  |
//|     (like the PDH/PDL lines), breakout arrows, a panel row per   |
//|     killzone, entry/SL/TP lines per strategy.                    |
//|  E. Optional KillzoneEntriesOnly: every strategy (PDH/PDL too)   |
//|     only opens trades while price is inside a killzone.          |
//|                                                                  |
//| v3.00 changes:                                                   |
//|  A. Risk money per lot from OrderCalcProfit instead of tick      |
//|     value, which some brokers report wrongly (report A: ~10x).   |
//|  B. Risk base selectable: equity / balance / fixed initial       |
//|     balance (prop accounts: use INITIAL).                        |
//|  C. Margin cap is logged and counted; on start the EA prints the |
//|     symbol's margin, leverage and the max risk the margin allows.|
//|     A summary of real risk per trade is printed at test end.     |
//|  D. Optional breakeven lock-in (+x R) and trailing stop.         |
//|                                                                  |
//| What it does (in plain English):                                 |
//|  1. Reads yesterday's High (PDH) and Low (PDL).                  |
//|  2. Waits for a 1-minute candle to CLOSE above PDH (buy) or      |
//|     below PDL (sell). Only the FIRST M1 close beyond each level  |
//|     today counts - it is read from today's M1 history, so it     |
//|     also holds after an EA restart. If that first close cannot   |
//|     be traded (trade open, filter, margin...), the side is done  |
//|     for the day; a later re-cross is never traded.               |
//|     The killzone highs / lows work the same way (see v5 A).      |
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
//|  6. Chart (live and visual backtest): PDH/PDL lines, killzone    |
//|     boxes + lines, entry / SL / TP lines with price, points, money and   |
//|     R, live P/L at price, info panel, on/off buttons. Drawing    |
//|     only - the trading logic does not depend on it.              |
//+------------------------------------------------------------------+
#property version   "5.00"
#property description "PDH/PDL + Asia/London/New York killzone high/low breakouts, first M1 close confirmation, ATR SL/TP, daily & weekly loss caps"

#include <Trade/Trade.mqh>

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lots
   LOT_RISK_PERCENT = 1  // % risked per trade
  };

enum ENUM_RISK_BASE
  {
   RISK_BASE_EQUITY  = 0, // Current equity (compounding)
   RISK_BASE_BALANCE = 1, // Current balance (compounding)
   RISK_BASE_INITIAL = 2  // Fixed initial balance (prop firm style)
  };

enum ENUM_SESS_DIR
  {
   DIR_BOTH  = 0, // Buys and sells
   DIR_BUYS  = 1, // Buys only
   DIR_SELLS = 2  // Sells only
  };

enum ENUM_SESS_SL
  {
   SESS_SL_ATR   = 0, // ATR x multiplier (same as PDH/PDL)
   SESS_SL_RANGE = 1, // Other side of the killzone
   SESS_SL_MID   = 2  // Middle of the killzone
  };

//--- Inputs ---------------------------------------------------------
input group "=== Strategies (on/off at start - chart buttons switch them live) ==="
input bool   UsePDHPDL        = true;   // PDH/PDL breakout
input bool   UseAsiaKZ        = true;   // Asian killzone high/low breakout
input bool   UseLondonKZ      = true;   // London killzone high/low breakout
input bool   UseNewYorkKZ     = true;   // New York killzone high/low breakout
input bool   UseLondonCloseKZ = false;  // London Close killzone high/low breakout
input bool   OneTradeAtATime  = true;   // Only one open trade per chart (false = one per strategy)

input group "=== Entry (PDH/PDL) ==="
input bool   TradeBuys        = true;   // Buy on first M1 close above PDH
input bool   TradeSells       = true;   // Sell on first M1 close below PDL

input group "=== Killzones (server time, HH:MM - defaults = ICT times for a GMT+2/+3 server) ==="
input string AsiaKZStart      = "03:00"; // Asian KZ: start (20:00 New York)
input string AsiaKZEnd        = "07:00"; // Asian KZ: end (its high/low are traded from here)
input string AsiaKZTradeEnd   = "24:00"; // Asian KZ: high/low traded until (24:00 = rest of the day, like PDH/PDL)
input ENUM_SESS_DIR AsiaKZDirection = DIR_BOTH; // Asian KZ: direction
input string LondonKZStart    = "09:00"; // London KZ: start (02:00 New York)
input string LondonKZEnd      = "12:00"; // London KZ: end (its high/low are traded from here)
input string LondonKZTradeEnd = "24:00"; // London KZ: high/low traded until (24:00 = rest of the day, like PDH/PDL)
input ENUM_SESS_DIR LondonKZDirection = DIR_BOTH; // London KZ: direction
input string NYKZStart        = "14:00"; // New York KZ: start (07:00 New York)
input string NYKZEnd          = "17:00"; // New York KZ: end (its high/low are traded from here)
input string NYKZTradeEnd     = "24:00"; // New York KZ: high/low traded until (24:00 = rest of the day, like PDH/PDL)
input ENUM_SESS_DIR NYKZDirection = DIR_BOTH; // New York KZ: direction
input string LondonCloseKZStart    = "17:00"; // London Close KZ: start (10:00 New York)
input string LondonCloseKZEnd      = "19:00"; // London Close KZ: end (its high/low are traded from here)
input string LondonCloseKZTradeEnd = "24:00"; // London Close KZ: high/low traded until (24:00 = rest of the day, like PDH/PDL)
input ENUM_SESS_DIR LondonCloseKZDirection = DIR_BOTH; // London Close KZ: direction
input ENUM_SESS_SL KZ_SLMode  = SESS_SL_ATR; // Killzone trades: stop loss at (ATR = same as PDH/PDL)
input double KZ_TP_R          = 2.0;    // ... TP = SL distance x this (other side / middle modes)
input int    KZ_SLBufferPoints = 0;     // ... SL this many points beyond the killzone level (other side / middle modes)
input int    MinRangePoints   = 0;      // Skip a killzone whose high-low is smaller (points, 0 = off)
input int    MaxRangePoints   = 0;      // Skip a killzone whose high-low is larger (points, 0 = off)
input bool   KillzoneEntriesOnly = false; // All strategies: only open trades INSIDE a killzone (start-end)

input group "=== Stop Loss / Take Profit (ATR) ==="
input ENUM_TIMEFRAMES ATR_Timeframe = PERIOD_M5; // ATR timeframe (v1 used M1)
input int    ATR_Period       = 14;     // ATR period (v1 used 5)
input double ATR_SL_Mult      = 2.0;    // SL distance = ATR x this
input double ATR_TP_Mult      = 4.0;    // TP distance = ATR x this

input group "=== Trade Management ==="
input bool   UseBreakeven     = false;  // Move SL to entry once in profit
input double BreakevenAtR     = 1.0;    // ... at this many R (1 R = SL distance)
input double BreakevenLockR   = 0.0;    // ... SL goes to entry + this many R (0 = exact breakeven, 0.5 = lock half R)
input bool   UseTrailing      = false;  // Trail the SL once in profit
input double TrailStartR      = 1.0;    // ... start trailing at this many R
input double TrailDistanceR   = 1.0;    // ... SL stays this many R behind price
input bool   UseTimeExit      = false;  // Close trades + stop entries at the time below (no overnight / weekend holds)
input int    ExitHour         = 22;     // Exit hour (server time)
input int    ExitMinute       = 45;     // Exit minute

input group "=== Position Size ==="
input ENUM_LOT_MODE LotMode   = LOT_FIXED; // Lot sizing method
input double FixedLots        = 0.01;   // Lots (when Fixed lots)
input double RiskPercent      = 0.5;    // % risked per trade (when Risk %)
input ENUM_RISK_BASE RiskBase = RISK_BASE_EQUITY; // Risk % is taken of ... (prop: Fixed initial balance)
input double InitialBalance   = 0;      // Initial balance for RISK_BASE_INITIAL (0 = balance when EA starts; set it on live accounts)
input double MaxMarginUsePct  = 90.0;   // Use at most this % of free margin for one trade (safety cap only)

input group "=== Loss Limits (whole account, all EA instances) ==="
input double DailyLossPct     = 2.5;    // Max daily loss %
input double WeeklyLossPct    = 8.5;    // Max weekly loss %
input double LossBaseAmount   = 0;      // % base: 0 = equity at day/week start, >0 = fixed amount (e.g. initial balance)

input group "=== Optional Filters (off by default) ==="
input int    MaxSpreadPoints  = 0;      // Max spread in points (0 = off)
input bool   UseSession       = false;  // Only open trades (all strategies) between the hours below
input int    SessionStartHour = 8;      // Trading hours start (server time)
input int    SessionEndHour   = 17;     // Trading hours end (server time)

input group "=== Execution ==="
input long   MagicNumber      = 260514; // Magic number (strategies use this +0..+4; same on all charts)
input int    SlippagePoints   = 30;     // Max slippage (points)

input group "=== Chart Display ==="
input bool   ShowChart        = true;   // Draw levels, trade lines, numbers and the info panel
input bool   ShowPanel        = true;   // ... info panel (top-left)
input bool   ShowButtons      = true;   // ... on/off buttons for each strategy (live chart)
input int    FontSize         = 9;      // ... text size
input color  ColPDH           = clrDodgerBlue;   // ... PDH line
input color  ColPDL           = clrOrange;       // ... PDL line
input color  ColEntry         = clrSilver;       // ... entry line
input color  ColSL            = clrRed;          // ... stop loss line
input color  ColTP            = clrLimeGreen;    // ... take profit line
input color  ColPanel         = clrWhite;        // ... panel text
input int    KZHistoryDays    = 5;      // ... killzone boxes for this many days
input bool   DrawAsiaKZ       = true;   // ... draw Asian killzone (box, high/low, labels)
input bool   DrawLondonKZ     = true;   // ... draw London killzone
input bool   DrawNewYorkKZ    = true;   // ... draw New York killzone
input bool   DrawLondonCloseKZ = true;  // ... draw London Close killzone
input bool   KillzoneBoxFill  = true;   // ... filled killzone boxes (false = outline)
input color  ColAsiaKZ        = clrViolet;       // ... Asian KZ colour
input color  ColLondonKZ      = clrDeepSkyBlue;  // ... London KZ colour
input color  ColNewYorkKZ     = clrGold;         // ... New York KZ colour
input color  ColLondonCloseKZ = clrSandyBrown;   // ... London Close KZ colour

//--- Strategies -----------------------------------------------------
#define NSTRAT      5
#define ST_PDH      0
#define ST_ASIAKZ   1
#define ST_LONDONKZ 2
#define ST_NYKZ     3
#define ST_LCKZ     4
#define ST_FIRSTKZ  ST_ASIAKZ

struct SessWin   { datetime rs; datetime re; datetime te; };   // range start, range end, trade end
struct SessBreak { bool up; bool dn; datetime upT; datetime dnT; double upP; double dnP; };

bool          stratOn[NSTRAT];         // live on/off (inputs, then the chart buttons)
int           sessStart[NSTRAT], sessEnd[NSTRAT], sessTradeEnd[NSTRAT];   // minutes of the day
ENUM_SESS_DIR sessDir[NSTRAT];
bool          sessDraw[NSTRAT];
bool          sessFill[NSTRAT];
color         sessCol[NSTRAT];
string        sessText[NSTRAT];        // panel row per killzone (refreshed once per M1 bar)
string        kzLineId[NSTRAT];        // latest killzone's line objects, labels refreshed every second
double        kzHi[NSTRAT], kzLo[NSTRAT];
bool          kzUp[NSTRAT], kzDn[NSTRAT];

string StratName(const int s)
  {
   switch(s)
     {
      case ST_PDH:    return "PDH/PDL";
      case ST_ASIAKZ:   return "Asia KZ";
      case ST_LONDONKZ: return "London KZ";
      case ST_NYKZ:     return "NY KZ";
      case ST_LCKZ:     return "LdnClose KZ";
     }
   return "?";
  }

bool IsOurMagic(const long m) { return m >= MagicNumber && m < MagicNumber + NSTRAT; }

//--- Globals --------------------------------------------------------
CTrade   trade;
int      atrHandle   = INVALID_HANDLE;
datetime lastBarTime = 0;      // last M1 bar processed
double   riskRoom    = 0;      // money left before the nearest loss cap
bool     haltLogged  = false;
datetime lastCloseFail = 0;    // throttles close retries / log lines
string   gvPrefix;             // shared-variable prefix for this account
bool     pdhBrokenToday = false; // for the chart display (set by the signal check)
bool     pdlBrokenToday = false;
datetime lastDraw    = 0;      // chart redraw at most once per server second
datetime sessDrawBar = 0;      // session drawings rebuilt once per M1 bar
bool     sessDirty   = true;   // ... or right away after a button click
int      panelRows   = 0;      // rows drawn last time (extra ones are deleted)
const string OBJ     = "PDHPDL_V_"; // prefix of every chart object this EA draws
double   initBalance = 0;      // base for RISK_BASE_INITIAL
// sizing statistics (printed when the EA stops / the test ends)
int      statTrades = 0, statMarginCapped = 0, statVolumeCapped = 0;
double   statRiskSum = 0, statRiskMin = DBL_MAX, statRiskMax = 0;
bool     lastMarginCapped = false, lastVolumeCapped = false;
bool     symbolChecked = false;   // start-up symbol check done

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
   if(UseBreakeven && (BreakevenLockR < 0 || BreakevenLockR >= BreakevenAtR))
     { Print("BreakevenLockR must be 0 or more and below BreakevenAtR."); return INIT_PARAMETERS_INCORRECT; }
   if(UseTrailing && (TrailStartR <= 0 || TrailDistanceR <= 0))
     { Print("TrailStartR and TrailDistanceR must be above 0."); return INIT_PARAMETERS_INCORRECT; }
   if(ExitHour < 0 || ExitHour > 23 || ExitMinute < 0 || ExitMinute > 59)
     { Print("Invalid exit time."); return INIT_PARAMETERS_INCORRECT; }
   if(SessionStartHour < 0 || SessionStartHour > 23 || SessionEndHour < 0 || SessionEndHour > 24)
     { Print("Invalid session hours."); return INIT_PARAMETERS_INCORRECT; }
   if(KZ_SLMode != SESS_SL_ATR && KZ_TP_R <= 0)
     { Print("KZ_TP_R must be above 0."); return INIT_PARAMETERS_INCORRECT; }
   if(KZ_SLBufferPoints < 0 || MinRangePoints < 0 || MaxRangePoints < 0
      || (MaxRangePoints > 0 && MaxRangePoints < MinRangePoints))
     { Print("Invalid killzone SL buffer / range size filter."); return INIT_PARAMETERS_INCORRECT; }
   if(!LoadSession(ST_ASIAKZ,   AsiaKZStart,   AsiaKZEnd,   AsiaKZTradeEnd,   AsiaKZDirection,   DrawAsiaKZ,   ColAsiaKZ,   KillzoneBoxFill) ||
      !LoadSession(ST_LONDONKZ, LondonKZStart, LondonKZEnd, LondonKZTradeEnd, LondonKZDirection, DrawLondonKZ, ColLondonKZ, KillzoneBoxFill) ||
      !LoadSession(ST_NYKZ,     NYKZStart,     NYKZEnd,     NYKZTradeEnd,     NYKZDirection,     DrawNewYorkKZ, ColNewYorkKZ, KillzoneBoxFill) ||
      !LoadSession(ST_LCKZ, LondonCloseKZStart, LondonCloseKZEnd, LondonCloseKZTradeEnd, LondonCloseKZDirection,
                   DrawLondonCloseKZ, ColLondonCloseKZ, KillzoneBoxFill))
      return INIT_PARAMETERS_INCORRECT;

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

   //--- strategy on/off: inputs, or the button state kept from before a timeframe change / restart
   stratOn[ST_PDH]    = UsePDHPDL;
   stratOn[ST_ASIAKZ]   = UseAsiaKZ;
   stratOn[ST_LONDONKZ] = UseLondonKZ;
   stratOn[ST_NYKZ]     = UseNewYorkKZ;
   stratOn[ST_LCKZ]     = UseLondonCloseKZ;
   bool useInputs = MQLInfoInteger(MQL_TESTER) || UninitializeReason() == REASON_PARAMETERS;
   for(int s = 0; s < NSTRAT; s++)
     {
      if(useInputs) GlobalVariableDel(BtnKey(s));
      else if(GlobalVariableCheck(BtnKey(s))) stratOn[s] = GlobalVariableGet(BtnKey(s)) > 0.5;
     }
   string names = "";
   for(int s = 0; s < NSTRAT; s++)
      names += (s > 0 ? " | " : "") + StratName(s) + (stratOn[s] ? " ON" : " OFF");
   Print("Strategies: ", names, KillzoneEntriesOnly ? "  (entries only inside killzones)" : "");

   initBalance = (InitialBalance > 0) ? InitialBalance : AccountInfoDouble(ACCOUNT_BALANCE);
   if(LotMode == LOT_RISK_PERCENT && RiskBase == RISK_BASE_INITIAL && InitialBalance <= 0
      && !MQLInfoInteger(MQL_TESTER))
      Print("NOTE: InitialBalance = 0, using current balance ", DoubleToString(initBalance, 2),
            " as the risk base. Set InitialBalance to the account size so it stays fixed after restarts.");
   symbolChecked = PrintSymbolCheck();   // in the tester prices arrive with the first tick

   UpdateChart();                        // panel + buttons show before the first tick
   return INIT_SUCCEEDED;
  }

// Reads one session's times ("HH:MM") into the session arrays.
bool LoadSession(const int s, const string start, const string end, const string tradeEnd,
                 const ENUM_SESS_DIR dir, const bool draw, const color clr, const bool fill)
  {
   int a = ParseHM(start), b = ParseHM(end), c = ParseHM(tradeEnd);
   if(a < 0 || a >= 1440 || b <= 0 || c <= 0 || a == b % 1440 || b % 1440 == c % 1440)
     {
      Print(StratName(s), ": invalid session times '", start, "' / '", end, "' / '", tradeEnd,
            "' - use HH:MM (00:00-24:00), range start <> range end <> trade end.");
      return false;
     }
   sessStart[s] = a; sessEnd[s] = b; sessTradeEnd[s] = c;
   sessDir[s] = dir; sessDraw[s] = draw; sessCol[s] = clr; sessFill[s] = fill;
   sessText[s] = "";
   return true;
  }

// "HH:MM" -> minutes of the day (0-1440), -1 if invalid.
int ParseHM(const string text)
  {
   string t = text;
   StringTrimLeft(t);
   StringTrimRight(t);
   string p[];
   if(StringSplit(t, ':', p) != 2 || StringLen(p[0]) < 1 || StringLen(p[1]) != 2) return -1;
   for(int k = 0; k < 2; k++)
      for(int i = 0; i < StringLen(p[k]); i++)
        {
         ushort ch = StringGetCharacter(p[k], i);
         if(ch < '0' || ch > '9') return -1;
        }
   int h = (int)StringToInteger(p[0]), m = (int)StringToInteger(p[1]);
   if(h > 24 || m > 59 || h * 60 + m > 1440) return -1;
   return h * 60 + m;
  }

string HM(const int minutes) { return StringFormat("%02d:%02d", minutes / 60, minutes % 60); }

string BtnKey(const int s) { return "PDHPDL_btn_" + IntegerToString(ChartID()) + "_" + IntegerToString(s); }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   if(statTrades > 0)
      PrintFormat("SIZING SUMMARY: %d trades | real risk per trade avg %.3f%% (min %.3f%%, max %.3f%%) of risk base | "
                  "cut by margin cap: %d | cut by max volume: %d",
                  statTrades, statRiskSum / statTrades, statRiskMin, statRiskMax, statMarginCapped, statVolumeCapped);
   if(reason == REASON_REMOVE)                 // EA taken off the chart: forget the button state
      for(int s = 0; s < NSTRAT; s++) GlobalVariableDel(BtnKey(s));
   ObjectsDeleteAll(0, OBJ);
   Comment("");
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   TickLogic();
   UpdateChart();                              // drawing only, after the trading logic
  }

// On/off buttons (live charts; the strategy tester does not send clicks).
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   string pfx = OBJ + "btn_";
   if(id != CHARTEVENT_OBJECT_CLICK || StringFind(sparam, pfx) != 0) return;
   int s = (int)StringToInteger(StringSubstr(sparam, StringLen(pfx)));
   if(s < 0 || s >= NSTRAT) return;
   stratOn[s] = !stratOn[s];
   GlobalVariableSet(BtnKey(s), stratOn[s] ? 1.0 : 0.0);
   Print(StratName(s), stratOn[s] ? " switched ON" : " switched OFF", " (new entries only - open trades are kept)");
   lastDraw  = 0;
   sessDirty = true;
   UpdateChart();
  }

void TickLogic()
  {
   if(!symbolChecked) symbolChecked = PrintSymbolCheck();

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
   for(int s = ST_FIRSTKZ; s < NSTRAT; s++)
      CheckSessionEntry(s);
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
   if(!ShowChart) Comment("PDH/PDL EA: LOSS LIMIT HIT - trading stopped");   // with ShowChart the panel shows it
  }

// Closes this EA's positions (all strategies): every symbol (loss cap) or only this chart's (time exit).
// After a failed close it waits 10 s before trying again, so a closed market does not flood the log.
void ClosePositions(const bool allSymbols)
  {
   if(lastCloseFail > 0 && TimeCurrent() - lastCloseFail < 10) return;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;
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

// Breakeven (optionally locking +BreakevenLockR) and optional trailing, for this chart's positions.
// 1 R is the position's INITIAL stop distance; the SL only ever moves in the trade's favour.
void ManagePositions()
  {
   if(!UseBreakeven && !UseTrailing) return;
   double minDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC)) ||
         PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      bool   isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double tp    = PositionGetDouble(POSITION_TP);
      if(sl <= 0) continue;

      double R = InitialRiskOf((ulong)PositionGetInteger(POSITION_IDENTIFIER), open);
      if(R <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;   // history lookup above may change the selection

      double px     = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profR  = (isBuy ? px - open : open - px) / R;
      double newSl  = sl;

      if(UseBreakeven && profR >= BreakevenAtR)
        {
         double be = isBuy ? open + BreakevenLockR * R : open - BreakevenLockR * R;
         if(isBuy ? be > newSl : be < newSl) newSl = be;
        }
      if(UseTrailing && profR >= TrailStartR)
        {
         double tr = isBuy ? px - TrailDistanceR * R : px + TrailDistanceR * R;
         if(isBuy ? tr > newSl : tr < newSl) newSl = tr;
        }

      newSl = NormalizeDouble(newSl, _Digits);
      if(MathAbs(newSl - sl) < _Point) continue;                  // nothing to move
      bool legal = isBuy ? newSl < px - minDist : newSl > px + minDist;
      if(legal && !trade.PositionModify(ticket, newSl, tp))
         Print("SL move failed for #", ticket, " retcode ", trade.ResultRetcode());
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

   pdhBrokenToday = pdhUsed || c1 > pdh;
   pdlBrokenToday = pdlUsed || c1 < pdl;
   if(!ShowChart)
      Comment(StringFormat("PDH: %s %s   PDL: %s %s   Loss room: %s",
              DoubleToString(pdh, _Digits), pdhBrokenToday ? "(broken today)" : "",
              DoubleToString(pdl, _Digits), pdlBrokenToday ? "(broken today)" : "",
              DoubleToString(riskRoom, 2)));

   if(!stratOn[ST_PDH]) return;                // switched off: levels still tracked for the chart

   // First M1 close beyond the level today
   bool buySignal  = TradeBuys  && !pdhUsed && c1 > pdh;
   bool sellSignal = TradeSells && !pdlUsed && c1 < pdl;
   if(!buySignal && !sellSignal) return;

   string side = buySignal ? "PDH buy" : "PDL sell";
   if(HasOpenPosition(ST_PDH))              { Print(side, " signal skipped: a trade is already open."); return; }
   if(UseTimeExit && PastExitTime())        { Print(side, " signal skipped: after exit time.");        return; }
   if(!FiltersPass(side))                   return;

   double atr[];
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0)
     { Print("ATR not available - ", side, " signal skipped."); return; }

   OpenTrade(ST_PDH, buySignal, atr[0] * ATR_SL_Mult, atr[0] * ATR_TP_Mult, atr[0],
             buySignal ? "PDH breakout" : "PDL breakout");
  }

//--- Session windows ------------------------------------------------
// The session that ends its range on server day `anchor` (00:00). A range that starts later
// in the day than it ends (e.g. 22:00-06:00) began the evening before; a trade end at or
// before the range end is on the next day.
void SessWindowFor(const int s, const datetime anchor, SessWin &w)
  {
   w.re = anchor + sessEnd[s] * 60;
   w.rs = anchor + sessStart[s] * 60;
   if(sessStart[s] >= sessEnd[s]) w.rs -= 86400;
   w.te = anchor + sessTradeEnd[s] * 60;
   if(sessTradeEnd[s] <= sessEnd[s]) w.te += 86400;
  }

// The latest session whose range started at or before `t`.
bool LatestWindow(const int s, const datetime t, SessWin &w)
  {
   datetime day = t - (t % 86400);
   for(int k = -1; k <= 2; k++)
     {
      SessWindowFor(s, day - k * 86400, w);
      if(w.rs <= t) return true;
     }
   return false;
  }

// High / low of the session's M1 bars from range start until range end (or `upTo`, if earlier).
bool SessRange(const SessWin &w, const datetime upTo, double &hi, double &lo)
  {
   datetime stop = (upTo < w.re ? upTo : w.re) - 1;
   if(stop < w.rs) return false;
   double h[], l[];
   if(CopyHigh(_Symbol, PERIOD_M1, w.rs, stop, h) <= 0) return false;
   if(CopyLow (_Symbol, PERIOD_M1, w.rs, stop, l) <= 0) return false;
   hi = h[ArrayMaximum(h)];
   lo = l[ArrayMinimum(l)];
   return hi > lo;
  }

// First closed M1 bar beyond the range high / low inside the trade window (for the chart / panel).
void SessBreaks(const SessWin &w, const double hi, const double lo, SessBreak &b)
  {
   b.up = false; b.dn = false; b.upT = 0; b.dnT = 0; b.upP = 0; b.dnP = 0;
   datetime bar0 = iTime(_Symbol, PERIOD_M1, 0);
   datetime stop = (w.te < bar0 ? w.te : bar0) - 1;
   if(stop < w.re) return;
   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M1, w.re, stop, r);
   for(int i = 0; i < n; i++)
     {
      if(!b.up && r[i].close > hi) { b.up = true; b.upT = r[i].time; b.upP = r[i].close; }
      if(!b.dn && r[i].close < lo) { b.dn = true; b.dnT = r[i].time; b.dnP = r[i].close; }
     }
  }

// Killzone high / low breakout: the first M1 close above the killzone high (buy) / below its low (sell)
// after the killzone ended, until its trade end. Same "first close only" rule as PDH/PDL.
void CheckSessionEntry(const int s)
  {
   if(!stratOn[s]) return;
   datetime bar1 = iTime(_Symbol, PERIOD_M1, 1);
   datetime bar2 = iTime(_Symbol, PERIOD_M1, 2);
   double   c1   = iClose(_Symbol, PERIOD_M1, 1);
   if(bar1 == 0 || c1 <= 0) return;

   SessWin w;
   if(!LatestWindow(s, bar1, w) || bar1 < w.re || bar1 >= w.te) return;   // outside the trade window
   double hi, lo;
   if(!SessRange(w, w.re, hi, lo)) return;     // no bars in the range (holiday / missing data)

   //--- Highest / lowest M1 close earlier in the trade window (before the last closed candle)
   double prevMax = -DBL_MAX, prevMin = DBL_MAX;
   if(bar2 >= w.re)
     {
      double closes[];
      int n = CopyClose(_Symbol, PERIOD_M1, w.re, bar2, closes);
      if(n <= 0) { Print(StratName(s), " M1 history not ready - signal check skipped."); return; }
      prevMax = closes[ArrayMaximum(closes)];
      prevMin = closes[ArrayMinimum(closes)];
     }

   bool buySignal  = sessDir[s] != DIR_SELLS && !(prevMax > hi) && c1 > hi;
   bool sellSignal = sessDir[s] != DIR_BUYS  && !(prevMin < lo) && c1 < lo;
   if(!buySignal && !sellSignal) return;

   string side = StratName(s) + (buySignal ? " high buy" : " low sell");
   double rangePts = (hi - lo) / _Point;
   if(MinRangePoints > 0 && rangePts < MinRangePoints)
     { Print(side, " signal skipped: killzone ", DoubleToString(rangePts, 0), " points < MinRangePoints."); return; }
   if(MaxRangePoints > 0 && rangePts > MaxRangePoints)
     { Print(side, " signal skipped: killzone ", DoubleToString(rangePts, 0), " points > MaxRangePoints."); return; }
   if(HasOpenPosition(s))                   { Print(side, " signal skipped: a trade is already open."); return; }
   if(UseTimeExit && PastExitTime())        { Print(side, " signal skipped: after exit time.");        return; }
   if(!FiltersPass(side))                   return;

   double atr[];
   if(CopyBuffer(atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0)
     { Print("ATR not available - ", side, " signal skipped."); return; }

   double slDist = atr[0] * ATR_SL_Mult;
   double tpDist = atr[0] * ATR_TP_Mult;
   if(KZ_SLMode != SESS_SL_ATR)
     {
      double level = (KZ_SLMode == SESS_SL_RANGE) ? (buySignal ? lo : hi) : (hi + lo) / 2.0;
      double buf   = KZ_SLBufferPoints * _Point;
      slDist = buySignal ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) - (level - buf)
                         : (level + buf) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(slDist <= 0) { Print(side, " signal skipped: price is already past the killzone stop level."); return; }
      tpDist = slDist * KZ_TP_R;
     }

   OpenTrade(s, buySignal, slDist, tpDist, atr[0], side);
  }

// With OneTradeAtATime any of this EA's trades on the chart's symbol blocks; otherwise only the strategy's own.
bool HasOpenPosition(const int strat)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(magic) || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(OneTradeAtATime || magic == MagicNumber + strat) return true;
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
      if(!inSession) { Print(side, " signal skipped: outside trading hours."); return false; }
     }
   if(KillzoneEntriesOnly && !InKillzone(TimeCurrent()))
     { Print(side, " signal skipped: not inside a killzone."); return false; }
   return true;
  }

// true while `t` is between the start and end of any killzone (on or off - the times are what count).
bool InKillzone(const datetime t)
  {
   for(int s = ST_FIRSTKZ; s < NSTRAT; s++)
     {
      SessWin w;
      if(LatestWindow(s, t, w) && t < w.re) return true;
     }
   return false;
  }

//====================================================================
//  EXECUTION
//====================================================================

// Money lost if `lots` of `symbol` hit a stop `dist` price units away.
// v3: uses OrderCalcProfit - the terminal's own P/L formula (contract size, calc mode,
// currency conversion) - so it matches the money a stop really costs. Tick value is only
// a fallback: on some symbols it does not match real P/L (report A was ~10x off).
double MoneyAtRisk(const string symbol, const double lots, const double dist)
  {
   if(lots <= 0 || dist <= 0) return -1;
   double px = SymbolInfoDouble(symbol, SYMBOL_BID);
   double pl = 0;
   if(px > dist && OrderCalcProfit(ORDER_TYPE_BUY, symbol, lots, px, px - dist, pl) && pl < 0)
      return -pl;
   return MoneyAtRiskTickValue(symbol, lots, dist);
  }

double MoneyAtRiskTickValue(const string symbol, const double lots, const double dist)
  {
   double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0) tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0 || tickValue <= 0) return -1;
   return dist / tickSize * tickValue * lots;
  }

double RiskBaseAmount()
  {
   if(RiskBase == RISK_BASE_INITIAL) return initBalance;
   if(RiskBase == RISK_BASE_BALANCE) return AccountInfoDouble(ACCOUNT_BALANCE);
   return AccountInfoDouble(ACCOUNT_EQUITY);
  }

// Start-up check: prints what one point and one lot really cost on this symbol, the margin
// the broker asks for, and the largest risk % the margin cap allows at common stop sizes.
bool PrintSymbolCheck()
  {
   double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(px <= 0) return false;                                          // no price yet: try again on next tick
   double one = 1.0;                                                   // 1.00 price unit (1 index point)
   double byCalc = MoneyAtRisk(_Symbol, 1.0, one);
   double byTick = MoneyAtRiskTickValue(_Symbol, 1.0, one);
   double marginPerLot = 0;
   OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginPerLot);
   double notional = byCalc * px;
   PrintFormat("SYMBOL CHECK %s | money per 1.00 point per 1.00 lot: %.4f (P/L calc) vs %.4f (tick value)%s",
               _Symbol, byCalc, byTick,
               (byCalc > 0 && byTick > 0 && MathAbs(byTick / byCalc - 1) > 0.02) ? "  <-- MISMATCH: tick value is wrong on this symbol, v3 uses P/L calc" : "");
   PrintFormat("SYMBOL CHECK %s | contract %.2f | volume min %.2f step %.2f max %.2f | margin per lot %.2f %s | symbol leverage ~1:%.0f (account 1:%d)",
               _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), marginPerLot, AccountInfoString(ACCOUNT_CURRENCY),
               marginPerLot > 0 ? notional / marginPerLot : 0, (int)AccountInfoInteger(ACCOUNT_LEVERAGE));
   if(marginPerLot > 0 && byCalc > 0)
     {
      // max lots = equity x cap / margin per lot -> max risk % = cap x SL x money-per-point / margin per lot
      string s = "";
      double sls[] = {10, 25, 50, 100};
      for(int i = 0; i < ArraySize(sls); i++)
         s += StringFormat("  SL %.0f pts: %.2f%%", sls[i], MaxMarginUsePct * sls[i] * byCalc / marginPerLot);
      Print("SYMBOL CHECK max risk per trade the margin cap allows:", s);
      if(LotMode == LOT_RISK_PERCENT && MaxMarginUsePct * 25 * byCalc / marginPerLot < RiskPercent)
         PrintFormat("WARNING: with this symbol's margin, RiskPercent %.2f%% is NOT reachable for stops under ~%.0f points. "
                     "Most trades will be cut by the margin cap. Check the live account's index leverage.",
                     RiskPercent, RiskPercent * marginPerLot / (MaxMarginUsePct * byCalc));
     }
   return true;
  }

// What all of this EA's open trades (every chart, every strategy) can still lose from here to their SL.
// Equity already includes their current profit/loss, so the distance is measured from the current price.
double OpenRiskAllCharts()
  {
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!IsOurMagic(PositionGetInteger(POSITION_MAGIC))) continue;

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
      lots = RiskBaseAmount() * RiskPercent / 100.0 / perLot;
     }
   lastMarginCapped = false;
   lastVolumeCapped = false;

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
               " to fit free margin (MaxMarginUsePct ", DoubleToString(MaxMarginUsePct, 0), "%).");
         lots = maxByMargin;
         lastMarginCapped = true;
        }
     }

   lots = MathFloor(lots / step + 1e-9) * step;  // always round DOWN
   if(lots < minLot)
     { Print("Lot size below broker minimum - trade skipped (no rounding up)."); return 0; }
   if(lots > maxLot)
     {
      Print("Lots reduced from ", DoubleToString(lots, 2), " to broker maximum ", DoubleToString(maxLot, 2), ".");
      lots = maxLot;
      lastVolumeCapped = true;
     }

   int digits = (int)MathMax(0, MathCeil(-MathLog10(step)));
   return NormalizeDouble(lots, digits);
  }

// Opens a trade for strategy `strat` (its own magic) with the given SL / TP distances.
bool OpenTrade(const int strat, const bool isBuy, double slDist, double tpDist, const double atr, const string comment)
  {
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
      Print(comment, " trade skipped: risk ", DoubleToString(risk, 2),
            " exceeds remaining loss allowance ", DoubleToString(MathMax(room, 0), 2),
            " (limit room ", DoubleToString(riskRoom, 2), " minus open trades' risk)");
      return false;
     }

   trade.SetExpertMagicNumber(MagicNumber + strat);
   for(int attempt = 0; attempt < 3; attempt++)
     {
      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) return false;

      double price = isBuy ? tick.ask : tick.bid;
      double sl    = NormalizeDouble(isBuy ? price - slDist : price + slDist, _Digits);
      double tp    = NormalizeDouble(isBuy ? price + tpDist : price - tpDist, _Digits);

      bool sent = isBuy ? trade.Buy (lots, _Symbol, price, sl, tp, comment)
                        : trade.Sell(lots, _Symbol, price, sl, tp, comment);
      uint rc = trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
        {
         double base    = RiskBaseAmount();
         double riskPct = base > 0 ? risk / base * 100.0 : 0;
         Print(StratName(strat), ": ", isBuy ? "BUY " : "SELL ", lots, " lots | SL ", sl, " | TP ", tp,
               " | ATR ", DoubleToString(atr, _Digits),
               " | risk ", DoubleToString(risk, 2), " = ", DoubleToString(riskPct, 3), "% of base",
               lastMarginCapped ? " [MARGIN CAPPED]" : "", lastVolumeCapped ? " [MAX VOLUME]" : "");
         statTrades++;
         statRiskSum += riskPct;
         statRiskMin  = MathMin(statRiskMin, riskPct);
         statRiskMax  = MathMax(statRiskMax, riskPct);
         if(lastMarginCapped) statMarginCapped++;
         if(lastVolumeCapped) statVolumeCapped++;
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
//====================================================================
//  CHART DISPLAY
//====================================================================

// 1 R = the position's INITIAL SL distance, from the order that opened it (breakeven moves the SL later).
// Small cache, since with OneTradeAtATime = false several positions can be open.
#define RCACHE 8
ulong  rPos[RCACHE];
double rDist[RCACHE];
int    rNext = 0;
double InitialRiskOf(const ulong posId, const double open)
  {
   for(int i = 0; i < RCACHE; i++)
      if(rPos[i] == posId && rDist[i] > 0) return rDist[i];
   double dist = 0;
   datetime first = 0;
   if(HistorySelectByPosition(posId))
      for(int i = HistoryOrdersTotal() - 1; i >= 0; i--)
        {
         ulong o = HistoryOrderGetTicket(i);
         if(o == 0) continue;
         datetime t  = (datetime)HistoryOrderGetInteger(o, ORDER_TIME_SETUP);
         double   sl = HistoryOrderGetDouble(o, ORDER_SL);
         if(sl > 0 && (first == 0 || t < first)) { first = t; dist = MathAbs(open - sl); }
        }
   if(dist > 0) { rPos[rNext] = posId; rDist[rNext] = dist; rNext = (rNext + 1) % RCACHE; }
   return dist;
  }

// Money for `lots` moving `dist` in price (positive number).
double MoneyForDist(const double lots, const double dist)
  {
   double m = MoneyAtRisk(_Symbol, lots, MathAbs(dist));   // same P/L calc as the sizing
   return m > 0 ? m : 0;
  }

string Money(const double v)
  {
   return (v < 0 ? "-" : "+") + DoubleToString(MathAbs(v), 2) + " " + AccountInfoString(ACCOUNT_CURRENCY);
  }

string Pts(const double d)
  {
   return (d < 0 ? "-" : "+") + DoubleToString(MathAbs(d), _Digits) + " pts";
  }

// Mixes `c` into the chart background (a = share of `c`), so filled boxes stay behind the candles' colours.
color Blend(const color c, const color bg, const double a)
  {
   int ci = (int)c, bi = (int)bg;
   int r = (int)MathRound(( ci        & 0xFF) * a + ( bi        & 0xFF) * (1 - a));
   int g = (int)MathRound(((ci >> 8)  & 0xFF) * a + ((bi >> 8)  & 0xFF) * (1 - a));
   int b = (int)MathRound(((ci >> 16) & 0xFF) * a + ((bi >> 16) & 0xFF) * (1 - a));
   return (color)(r | (g << 8) | (b << 16));
  }

// Horizontal segment from t1 to t2 with a label at its right end.
void DrawLevel(const string name, const datetime t1, const datetime t2, const double price, const color clr,
               const ENUM_LINE_STYLE style, const int width, const string text)
  {
   string ln = OBJ + name, tx = OBJ + name + "_txt";
   if(ObjectFind(0, ln) < 0) ObjectCreate(0, ln, OBJ_TREND, 0, t1, price, t2, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME, 0, t1);
   ObjectSetDouble (0, ln, OBJPROP_PRICE, 0, price);
   ObjectSetInteger(0, ln, OBJPROP_TIME, 1, t2);
   ObjectSetDouble (0, ln, OBJPROP_PRICE, 1, price);
   ObjectSetInteger(0, ln, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, ln, OBJPROP_STYLE, style);
   ObjectSetInteger(0, ln, OBJPROP_WIDTH, width);
   ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, ln, OBJPROP_BACK, true);
   ObjectSetString (0, ln, OBJPROP_TOOLTIP, text);

   if(ObjectFind(0, tx) < 0) ObjectCreate(0, tx, OBJ_TEXT, 0, t2, price);
   ObjectSetInteger(0, tx, OBJPROP_TIME, 0, t2);
   ObjectSetDouble (0, tx, OBJPROP_PRICE, 0, price);
   ObjectSetString (0, tx, OBJPROP_TEXT, " " + text);
   ObjectSetString (0, tx, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, tx, OBJPROP_FONTSIZE, FontSize);
   ObjectSetInteger(0, tx, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, tx, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0, tx, OBJPROP_SELECTABLE, false);
  }

void DeleteLevel(const string name)
  {
   ObjectDelete(0, OBJ + name);
   ObjectDelete(0, OBJ + name + "_txt");
  }

void TextAt(const string name, const datetime t, const double price, const string text, const color clr,
            const ENUM_ANCHOR_POINT anchor)
  {
   string nm = OBJ + name;
   if(ObjectFind(0, nm) < 0) ObjectCreate(0, nm, OBJ_TEXT, 0, t, price);
   ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t);
   ObjectSetDouble (0, nm, OBJPROP_PRICE, 0, price);
   ObjectSetString (0, nm, OBJPROP_TEXT, text);
   ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, FontSize);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, nm, OBJPROP_ANCHOR, anchor);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
  }

void PanelLine(const int row, const string text, const color clr)
  {
   string nm = OBJ + "panel_" + IntegerToString(row);
   if(ObjectFind(0, nm) < 0)
     {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
     }
   ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 20 + row * (FontSize + 7));
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, FontSize);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, clr);
   ObjectSetString (0, nm, OBJPROP_TEXT, text);
  }

// One on/off button per strategy, in a row starting at `y` pixels from the top.
void DrawButtons(const int y)
  {
   int w = 12 * (FontSize - 1) + 8, h = FontSize + 13;
   for(int s = 0; s < NSTRAT; s++)
     {
      string nm = OBJ + "btn_" + IntegerToString(s);
      if(ObjectFind(0, nm) < 0)
        {
         ObjectCreate(0, nm, OBJ_BUTTON, 0, 0, 0);
         ObjectSetInteger(0, nm, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetString (0, nm, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, nm, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(0, nm, OBJPROP_BORDER_COLOR, clrDimGray);
        }
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 10 + s * (w + 4));
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, y);
      ObjectSetInteger(0, nm, OBJPROP_XSIZE, w);
      ObjectSetInteger(0, nm, OBJPROP_YSIZE, h);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, FontSize);
      ObjectSetString (0, nm, OBJPROP_TEXT, (s == ST_LCKZ ? "LC KZ" : s == ST_LONDONKZ ? "Ldn KZ" : StratName(s)) + (stratOn[s] ? ": ON" : ": OFF"));
      ObjectSetInteger(0, nm, OBJPROP_BGCOLOR, stratOn[s] ? C'0,110,0' : C'130,0,0');
      ObjectSetInteger(0, nm, OBJPROP_STATE, false);
      ObjectSetString (0, nm, OBJPROP_TOOLTIP, "Click to switch " + StratName(s) + " entries on / off");
     }
  }

// Panel text of the session's latest window: times, range, breakout status.
string SessPanelText(const int s, const datetime now)
  {
   string hdr = StringFormat("%-11s %-3s %s-%s >%s", StratName(s), stratOn[s] ? "ON" : "OFF",
                             HM(sessStart[s]), HM(sessEnd[s]), HM(sessTradeEnd[s]));
   SessWin w;
   double hi, lo;
   if(!LatestWindow(s, now, w) || !SessRange(w, now + 1, hi, lo)) return hdr + " | no data yet";
   string st;
   if(now < w.re) st = "killzone running";
   else
     {
      SessBreak b;
      SessBreaks(w, hi, lo, b);
      if(b.up && b.dn)      st = "broke UP and DOWN";
      else if(b.up)         st = "broke UP";
      else if(b.dn)         st = "broke DOWN";
      else if(now >= w.te)  st = "ended, no break";
      else                  st = "waiting for break";
     }
   return StringFormat("%s | H %s L %s (%s) | %s", hdr, DoubleToString(hi, _Digits), DoubleToString(lo, _Digits),
                       DoubleToString(hi - lo, _Digits), st);
  }

// Label of a killzone high / low line, in the style of the PDH / PDL labels.
string KZLabel(const int s, const bool high, const double price, const bool broken, const double bid)
  {
   return StringFormat("%s %s %s  (%s from price)%s%s", StratName(s), high ? "High" : "Low",
                       DoubleToString(price, _Digits), Pts(price - bid), broken ? "  BROKEN" : "",
                       stratOn[s] ? "" : "  [OFF]");
  }

// Updates the latest killzone lines' labels (distance from price) - called every chart redraw.
void RefreshKZLabels(const double bid)
  {
   for(int s = ST_FIRSTKZ; s < NSTRAT; s++)
     {
      if(kzLineId[s] == "") continue;
      ObjectSetString(0, OBJ + kzLineId[s] + "hi_txt", OBJPROP_TEXT, " " + KZLabel(s, true,  kzHi[s], kzUp[s], bid));
      ObjectSetString(0, OBJ + kzLineId[s] + "lo_txt", OBJPROP_TEXT, " " + KZLabel(s, false, kzLo[s], kzDn[s], bid));
     }
  }

// Box over the killzone, name + size above it, high / low lines over the trade window, breakout arrows.
void DrawSessionWindow(const int s, const int k, const SessWin &w, const double hi, const double lo,
                       const datetime now, const datetime right, const bool latest)
  {
   string id      = "SES_" + IntegerToString(s) + "_" + IntegerToString(k + 1) + "_";
   bool   forming = now < w.re;
   color  c       = sessCol[s];
   string tag     = (latest && !stratOn[s]) ? "  [OFF]" : "";

   string bx = OBJ + id + "box";
   ObjectCreate(0, bx, OBJ_RECTANGLE, 0, w.rs, hi, forming ? now : w.re, lo);
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   ObjectSetInteger(0, bx, OBJPROP_COLOR, sessFill[s] ? Blend(c, bg, 0.25) : c);
   ObjectSetInteger(0, bx, OBJPROP_FILL, sessFill[s]);
   ObjectSetInteger(0, bx, OBJPROP_BACK, true);
   ObjectSetInteger(0, bx, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, bx, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, bx, OBJPROP_SELECTABLE, false);
   ObjectSetString (0, bx, OBJPROP_TOOLTIP, StringFormat("%s %s-%s  High %s  Low %s", StratName(s), HM(sessStart[s]),
                    HM(sessEnd[s]), DoubleToString(hi, _Digits), DoubleToString(lo, _Digits)));

   TextAt(id + "name", w.rs, hi, StringFormat("%s %s%s%s", StratName(s), DoubleToString(hi - lo, _Digits),
          forming ? " (running)" : "", tag), c, ANCHOR_LEFT_LOWER);
   if(forming) return;

   SessBreak b;
   SessBreaks(w, hi, lo, b);
   datetime lineEnd = w.te < right ? w.te : right;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   DrawLevel(id + "hi", w.re, lineEnd, hi, c, latest ? STYLE_SOLID : STYLE_DASH, latest ? 2 : 1,
             latest ? KZLabel(s, true,  hi, b.up, bid) : "");
   DrawLevel(id + "lo", w.re, lineEnd, lo, c, latest ? STYLE_SOLID : STYLE_DASH, latest ? 2 : 1,
             latest ? KZLabel(s, false, lo, b.dn, bid) : "");
   if(latest && now < w.te)                    // still tradeable: its labels follow price every second
     { kzLineId[s] = id; kzHi[s] = hi; kzLo[s] = lo; kzUp[s] = b.up; kzDn[s] = b.dn; }
   if(b.up)
     {
      string a = OBJ + id + "up";
      ObjectCreate(0, a, OBJ_ARROW_UP, 0, b.upT, b.upP);
      ObjectSetInteger(0, a, OBJPROP_COLOR, c);
      ObjectSetInteger(0, a, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, a, OBJPROP_ANCHOR, ANCHOR_TOP);
      ObjectSetInteger(0, a, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, a, OBJPROP_TOOLTIP, StratName(s) + " first close above the killzone high");
     }
   if(b.dn)
     {
      string a = OBJ + id + "dn";
      ObjectCreate(0, a, OBJ_ARROW_DOWN, 0, b.dnT, b.dnP);
      ObjectSetInteger(0, a, OBJPROP_COLOR, c);
      ObjectSetInteger(0, a, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, a, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
      ObjectSetInteger(0, a, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, a, OBJPROP_TOOLTIP, StratName(s) + " first close below the killzone low");
     }
  }

// Rebuilds the session drawings and panel rows once per M1 bar (or right after a button click).
void DrawSessions(const datetime now, const datetime right)
  {
   datetime bar0 = iTime(_Symbol, PERIOD_M1, 0);
   if(bar0 == sessDrawBar && !sessDirty) return;
   sessDrawBar = bar0;
   sessDirty   = false;
   ObjectsDeleteAll(0, OBJ + "SES_");
   for(int s = 0; s < NSTRAT; s++) kzLineId[s] = "";

   int days = (int)MathMax(1, KZHistoryDays);
   datetime day = now - (now % 86400);
   for(int s = ST_FIRSTKZ; s < NSTRAT; s++)
     {
      sessText[s] = SessPanelText(s, now);
      if(!sessDraw[s]) continue;
      int drawn = 0;
      for(int k = -1; k < days * 2 + 4 && drawn < days; k++)   // calendar days back; weekends have no bars
        {
         SessWin w;
         SessWindowFor(s, day - k * 86400, w);
         if(w.rs > now) continue;
         double hi, lo;
         if(!SessRange(w, now + 1, hi, lo)) continue;
         DrawSessionWindow(s, k, w, hi, lo, now, right, drawn == 0);
         drawn++;
        }
     }
  }

void UpdateChart()
  {
   if(!ShowChart) return;
   if(MQLInfoInteger(MQL_OPTIMIZATION)) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;  // nobody sees it: keep tests fast
   datetime now = TimeCurrent();
   if(now == lastDraw) return;
   lastDraw = now;

   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   datetime right = iTime(_Symbol, PERIOD_CURRENT, 0) + PeriodSeconds() * 3;   // labels a few bars right of price
   if(today == 0) return;

   //--- PDH / PDL for today
   int shift = 1;
   MqlDateTime d;
   TimeToStruct(iTime(_Symbol, PERIOD_D1, 1), d);
   if(d.day_of_week == 0) shift = 2;
   double pdh = iHigh(_Symbol, PERIOD_D1, shift);
   double pdl = iLow (_Symbol, PERIOD_D1, shift);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   string off = stratOn[ST_PDH] ? "" : "  [OFF]";
   if(pdh > 0 && pdl > 0)
     {
      DrawLevel("PDH", today, right, pdh, ColPDH, STYLE_SOLID, 2,
                StringFormat("PDH %s  (%s from price)%s%s", DoubleToString(pdh, _Digits), Pts(pdh - bid),
                             pdhBrokenToday ? "  BROKEN" : "", off));
      DrawLevel("PDL", today, right, pdl, ColPDL, STYLE_SOLID, 2,
                StringFormat("PDL %s  (%s from price)%s%s", DoubleToString(pdl, _Digits), Pts(pdl - bid),
                             pdlBrokenToday ? "  BROKEN" : "", off));
     }

   //--- session boxes, high / low lines, labels
   DrawSessions(now, right);
   RefreshKZLabels(bid);

   //--- open positions of this chart (one set of lines per strategy)
   bool   had[NSTRAT];
   for(int s = 0; s < NSTRAT; s++) had[s] = false;
   string posText[];
   color  posClr[];
   string liveAll = "";
   double liveSum = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(magic) || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int s = (int)(magic - MagicNumber);
      if(had[s]) continue;                                        // one per strategy is drawn
      had[s] = true;

      bool     isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      double   open  = PositionGetDouble(POSITION_PRICE_OPEN);
      double   sl    = PositionGetDouble(POSITION_SL);
      double   tp    = PositionGetDouble(POSITION_TP);
      double   lots  = PositionGetDouble(POSITION_VOLUME);
      datetime t0    = (datetime)PositionGetInteger(POSITION_TIME);
      double   px    = isBuy ? bid : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double   dir   = isBuy ? 1.0 : -1.0;
      double   pl    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double   R     = InitialRiskOf((ulong)PositionGetInteger(POSITION_IDENTIFIER), open);
      string   sfx   = "_" + IntegerToString(s);
      string   nm    = StratName(s);

      DrawLevel("ENTRY" + sfx, t0, right, open, ColEntry, STYLE_DOT, 1,
                StringFormat("%s %s %s lots @ %s", nm, isBuy ? "BUY" : "SELL", DoubleToString(lots, 2),
                             DoubleToString(open, _Digits)));
      if(sl > 0)
        {
         double d_ = dir * (sl - open);                           // negative = loss side
         DrawLevel("SL" + sfx, t0, right, sl, ColSL, STYLE_DASH, 1,
                   StringFormat("%s SL %s | %s | %s%s", nm, DoubleToString(sl, _Digits), Pts(d_),
                                Money((d_ < 0 ? -1 : 1) * MoneyForDist(lots, d_)),
                                R > 0 ? StringFormat(" | %+.2fR", d_ / R) : ""));
        }
      else DeleteLevel("SL" + sfx);
      if(tp > 0)
        {
         double d_ = dir * (tp - open);
         DrawLevel("TP" + sfx, t0, right, tp, ColTP, STYLE_DASH, 1,
                   StringFormat("%s TP %s | %s | %s%s", nm, DoubleToString(tp, _Digits), Pts(d_),
                                Money(MoneyForDist(lots, d_)), R > 0 ? StringFormat(" | %+.2fR", d_ / R) : ""));
        }
      else DeleteLevel("TP" + sfx);

      double moved = dir * (px - open);
      string live  = StringFormat("P/L %s | %s%s", Money(pl), Pts(moved), R > 0 ? StringFormat(" | %+.2fR", moved / R) : "");
      liveAll += (liveAll == "" ? "" : "  ||  ") + (OneTradeAtATime ? "" : nm + " ") + live;
      liveSum += pl;

      int n = ArraySize(posText);
      ArrayResize(posText, n + 1);
      ArrayResize(posClr,  n + 1);
      posText[n] = StringFormat("Position: %s %s %s lots  %s", nm, isBuy ? "BUY" : "SELL", DoubleToString(lots, 2), live);
      posClr[n]  = pl >= 0 ? ColTP : ColSL;
     }
   for(int s = 0; s < NSTRAT; s++)
      if(!had[s]) { DeleteLevel("ENTRY_" + IntegerToString(s)); DeleteLevel("SL_" + IntegerToString(s)); DeleteLevel("TP_" + IntegerToString(s)); }

   string ln = OBJ + "LIVE";
   if(liveAll != "")
     {
      if(ObjectFind(0, ln) < 0) ObjectCreate(0, ln, OBJ_TEXT, 0, right, bid);
      ObjectSetInteger(0, ln, OBJPROP_TIME, 0, right);
      ObjectSetDouble (0, ln, OBJPROP_PRICE, 0, bid);
      ObjectSetString (0, ln, OBJPROP_TEXT, " " + liveAll);
      ObjectSetString (0, ln, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, ln, OBJPROP_FONTSIZE, FontSize + 1);
      ObjectSetInteger(0, ln, OBJPROP_COLOR, liveSum >= 0 ? ColTP : ColSL);
      ObjectSetInteger(0, ln, OBJPROP_ANCHOR, ANCHOR_LEFT);
      ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
     }
   else ObjectDelete(0, ln);

   //--- info panel
   int row = 0;
   if(ShowPanel)
     {
      datetime dayStart = now - (now % 86400);
      double   today_pl = RealizedSince(dayStart);
      double   atr[];
      string   atrTxt = "-";
      if(CopyBuffer(atrHandle, 0, 1, 1, atr) == 1)
         atrTxt = StringFormat("%s  (SL %s / TP %s)", DoubleToString(atr[0], _Digits),
                               DoubleToString(atr[0] * ATR_SL_Mult, _Digits), DoubleToString(atr[0] * ATR_TP_Mult, _Digits));
      PanelLine(row++, StringFormat("PDH/PDL + Killzones M1 ATR  |  %s  |  spread %d pts", _Symbol,
                                    (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD)), ColPanel);
      PanelLine(row++, StringFormat("%-11s %-3s PDH %s %s   PDL %s %s", StratName(ST_PDH), stratOn[ST_PDH] ? "ON" : "OFF",
                                    DoubleToString(pdh, _Digits), pdhBrokenToday ? "(broken)" : "",
                                    DoubleToString(pdl, _Digits), pdlBrokenToday ? "(broken)" : ""), ColPanel);
      for(int s = ST_FIRSTKZ; s < NSTRAT; s++)
         PanelLine(row++, sessText[s], stratOn[s] ? sessCol[s] : clrGray);
      PanelLine(row++, "ATR " + atrTxt, ColPanel);
      if(ArraySize(posText) == 0) PanelLine(row++, "Position: none", ColPanel);
      for(int i = 0; i < ArraySize(posText); i++) PanelLine(row++, posText[i], posClr[i]);
      PanelLine(row++, StringFormat("Closed today %s  |  Equity %s", Money(today_pl),
                                    DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)), today_pl >= 0 ? ColPanel : ColSL);
      PanelLine(row++, haltLogged ? "LOSS LIMIT HIT - trading stopped"
                                  : StringFormat("Loss room %s  (daily %.1f%% / weekly %.1f%%)",
                                                 DoubleToString(riskRoom, 2), DailyLossPct, WeeklyLossPct),
                haltLogged ? ColSL : ColPanel);
     }
   for(int r = row; r < panelRows; r++) ObjectDelete(0, OBJ + "panel_" + IntegerToString(r));
   panelRows = row;

   if(ShowButtons) DrawButtons(20 + row * (FontSize + 7) + 6);
   else ObjectsDeleteAll(0, OBJ + "btn_");
   ChartRedraw();
  }
//+------------------------------------------------------------------+
