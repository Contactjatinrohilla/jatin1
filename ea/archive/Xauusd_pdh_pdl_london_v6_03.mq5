//+------------------------------------------------------------------+
//|             XAUUSD_PDH_PDL_London  v6.00 (refactored)             |
//|                                                                  |
//|  STRATEGY (unchanged from v5.41)                                 |
//|   PDH/PDL : previous completed D1 candle high/low                |
//|   London  : London-session high/low, traded after session close  |
//|   4H      : previous completed H4 candle high/low                |
//|   Entry   : BUY STOP above the high / SELL STOP below the low     |
//|             (or, per module, a confirmed MARKET entry when a      |
//|             candle of InpConfirmMinutes closes beyond the level)  |
//|   SL/TP   : fixed point distances from the entry                 |
//|   Risk    : % of balance per leg, sized with OrderCalcProfit      |
//|   Exits   : breakeven -> trail activation -> trail distance      |
//|                                                                  |
//|  ARCHITECTURE                                                    |
//|   Time/Session -> Level detection (CExpert) -> Confirmation       |
//|   (CConfirm) -> Setup ledger + execution (CModule) -> Position    |
//|   management (CTrailStop) -> Account guard (CRiskGovernor)        |
//|                                                                  |
//|  SETUP IDENTITY (duplicate prevention)                           |
//|   symbol + module magic + period start + side                    |
//|   period = D1 open (PDH, London) or H4 open (4H).                 |
//|   The ledger is rebuilt from live orders + order history at init |
//|   and at every period change, so "already traded" survives any   |
//|   EA / terminal / VPS restart. A set is placed at most ONCE per   |
//|   period; a confirmed side trades at most once per period.        |
//|                                                                  |
//|  v6.03 CHANGES vs v6.02 (forensic fixes, see investigation report)|
//|   - CTrailStop::Update(): profit used to trigger breakeven/trail  |
//|     is now the position's real closable P/L (Bid for a BUY, Ask  |
//|     for a SELL), not the old "SPREADFIX" entry-side measurement, |
//|     which overstated floating profit by one spread-width on both |
//|     sides and triggered breakeven/trailing before the position   |
//|     was actually that profitable.                                |
//|   - CRiskGovernor: a breach no longer unconditionally market-     |
//|     closes every open position. It now leaves a position alone   |
//|     when its native SL is still intact and ahead of price, and   |
//|     only force-closes when the SL is missing or price has already|
//|     traded through it (a genuine gap/slippage situation the      |
//|     native stop can no longer be trusted to handle). Pendings are|
//|     still always cleared on a breach (no SL exists to respect on |
//|     an order that hasn't filled). Blackout-flatten behavior is   |
//|     unchanged - it still always closes, since that is a session  |
//|     rule, not a stop-loss-trust decision.                        |
//|   - No other logic, defaults, or modules were changed. In         |
//|     particular InpUseTP still defaults to true as before; this   |
//|     backtest's InpUseTP=false was a per-run setting, not a code  |
//|     default, and per the investigation report should NOT be      |
//|     assumed fixed just by restoring it (see report Part 2).       |
//|                                                                  |
//|  v6.00 CHANGES vs v5.41 (see the refactor report for details)    |
//|   - One setup ledger replaces m_placed / m_h4PlacedCandle /       |
//|     m_usedBuy/Sell / AlreadyTradedSince / LoadUsedFromHistory.    |
//|   - Pendings from a previous period are cancelled at the new      |
//|     period AND on restart (4H leftover leg no longer survives).   |
//|   - Market-order stop validation fixed (confirmation entries      |
//|     were rejected whenever SYMBOL_TRADE_STOPS_LEVEL > 0).          |
//|   - Risk: min-lot over-risk blocked; failed calc blocks instead  |
//|     of silently using a fixed lot; deviation check one-sided.    |
//|   - Account-guard flatten uses the symbol's filling mode and      |
//|     retries until flat.                                          |
//|   - Breakeven works with trailing OFF; freeze level respected.    |
//|   - Broker timezone model (fixed / EET+US DST / EET+EU DST /      |
//|     auto-live) - works identically in the Strategy Tester.       |
//|   - Trades the chart symbol only; refuses to start on mismatch.   |
//|   - Inputs reduced from 69 to 52; unsafe OFF switches removed.    |
//|   - Structured NO TRADE / TRADE TAKEN reason logging, printed on |
//|     change only (no per-tick journal flooding).                  |
//+------------------------------------------------------------------+
#property copyright "XAUUSD PDH/PDL + London + 4H EA v6.03"
#property version   "6.03"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//|  CONFIGURATION                                                   |
//+------------------------------------------------------------------+
enum ENUM_DIRECTION_MODE
  {
   DIR_BOTH      = 0, // Both (buy + sell)
   DIR_BUY_ONLY  = 1, // Buy only
   DIR_SELL_ONLY = 2  // Sell only
  };

enum ENUM_BROKER_TZ
  {
   TZ_FIXED      = 0, // Fixed offset (InpBrokerUTCOffset, never changes)
   TZ_EET_US_DST = 1, // UTC+2 / UTC+3 on US DST dates (most "NY-close" brokers)
   TZ_EET_EU_DST = 2, // UTC+2 / UTC+3 on EU DST dates
   TZ_AUTO_LIVE  = 3  // Auto-detect live (tester falls back to fixed offset)
  };

enum ENUM_GOV_HALT_MODE
  {
   GOV_PERMANENT  = 0, // PERMANENT: breach halts forever (correct for LIVE)
   GOV_PAUSE_DAYS = 1, // PAUSE: resume after InpGovPauseDays days
   GOV_LOG_ONLY   = 2  // LOG ONLY: record breach, keep trading (TESTER analysis)
  };

input group "=== 1. Strategy ==="
input bool   InpEnablePDH      = true;     // PDH/PDL module
input bool   InpEnableLondon   = true;     // London session module
input bool   InpEnable4H       = true;     // 4H candle high/low module
input ENUM_DIRECTION_MODE InpDirection = DIR_BOTH; // Trade direction

input group "=== 2. Entry Confirmation (optional, per module) ==="
input bool   InpConfirmPDH     = false;    // PDH: confirmed MARKET entry instead of pending straddle
input bool   InpConfirmLondon  = false;    // London: confirmed MARKET entry instead of pending straddle
input bool   InpConfirm4H      = false;    // 4H: confirmed MARKET entry instead of pending straddle
input int    InpConfirmMinutes = 5;        // Confirmation candle (minutes): 2,3,4,5,6,10,12,15,20,30,60
input bool   InpConfirmOneTradePerSet = false; // ON: only ONE confirmed trade per level set (high OR low)

input group "=== 3. Risk ==="
input bool   InpAutoLot        = true;     // Auto lot from risk % (OFF = fixed lot)
input double InpRiskPct        = 1.0;      // Risk % of balance per leg
input double InpFixedLot       = 0.10;     // Fixed lot (used only when Auto lot is OFF)
input double InpMaxRiskOverPct = 5.0;      // Skip trade if actual risk exceeds target by more than this %

input group "=== 4. Stop Loss / Take Profit ==="
input double InpSL_Pts         = 120.0;    // Stop loss (points)
input bool   InpUseTP          = true;     // Attach take profit (OFF = SL/trailing exits only)
input double InpTP_Pts         = 240.0;    // Take profit (points)

input group "=== 5. Breakeven & Trailing ==="
input bool   InpEnableBreakEven  = true;   // Move SL to entry at +BreakEven points
input double InpBreakEvenPts     = 20.0;   // Breakeven trigger (points)
input bool   InpEnableTrailing   = true;   // Trailing stop
input double InpTrailActivatePts = 20.0;   // Trailing activation (points, after breakeven if enabled)
input double InpTrailDist        = 10.0;   // Trailing distance (points behind price)

input group "=== 6. Sessions & Broker Time ==="
input int    InpLondonOpenUTC   = 8;       // London session open (UTC hour)
input int    InpLondonCloseUTC  = 16;      // London session close (UTC hour)
input ENUM_BROKER_TZ InpBrokerTZ = TZ_FIXED; // Broker server timezone model
input int    InpBrokerUTCOffset = 3;       // Broker UTC offset (hours) for FIXED model / tester fallback
input bool   InpEnableBlackout  = true;    // Daily-open blackout (no orders/positions around rollover)
input int    InpBreakCloseHour  = 23;      // Daily market CLOSE hour (server time)
input int    InpBreakCloseMin   = 0;       // Daily market CLOSE minute
input int    InpBreakOpenHour   = 1;       // Daily market REOPEN hour (server time)
input int    InpBreakOpenMin    = 0;       // Daily market REOPEN minute
input int    InpBlackoutBeforeMin = 15;    // Blackout starts this many minutes BEFORE the close
input int    InpBlackoutAfterMin  = 15;    // Blackout ends this many minutes AFTER the reopen
input bool   InpBlackoutFlatten   = true;  // Close open positions when the blackout starts

input group "=== 7. Execution ==="
input int    InpMaxSpreadPts    = 500;     // Maximum acceptable spread to open (points, 0 = off)
input string InpSymbolAliases   = "XAUUSD"; // Chart symbol must contain one of these (comma-separated)

input group "=== 8. DANGER ZONE - Account Protection ==="
input bool   InpEnableRiskGov    = true;   // Account guard (daily loss + overall drawdown)
input double InpDailyLossPct     = 2.5;    // Halt for the day at this % equity loss
input double InpMaxDrawdownPct   = 8.5;    // Halt at this % drawdown from equity high-water mark
input bool   InpCloseAllOnBreach = true;   // On breach: close all positions + pendings
input ENUM_GOV_HALT_MODE InpGovHaltMode = GOV_PERMANENT; // Overall-DD halt behavior (PERMANENT for live)
input int    InpGovPauseDays     = 5;      // Days to pause when halt mode = PAUSE
input bool   InpGovResetOnInit   = false;  // One-time wipe of saved anchors/high-water mark (runs once, then set back to false)

input group "=== 9. Advanced ==="
input ulong  InpMagicBase          = 100000; // Magic base: PDH=+1, London=+2, 4H=+3
input bool   InpEnableSpreadBuffer = false;  // Pad pending entries outward by live spread x multiplier
input double InpSpreadBufferMult   = 1.5;    // Entry padding multiplier
input bool   InpSimSpreadTester    = false;  // TESTER ONLY: pad entries by InpSimSpreadPts (do NOT use with real-tick modelling)
input double InpSimSpreadPts       = 30.0;   // TESTER ONLY: simulated spread padding (points)

input group "=== 10. Notifications & Debug ==="
input bool   InpEnablePush      = true;    // Push notification on wide-spread fills and guard breaches
input bool   InpEnableVisuals   = true;    // Draw levels and SL lines on the chart
input bool   InpDebug           = false;   // Extra diagnostic prints

//--- Internal constants (formerly inputs whose OFF state only disabled a safety check)
#define RETRY_MAX            3      // transient broker-error retries
#define RETRY_WAIT_MS        400    // wait between retries (live only)
#define DEVIATION_PTS        80     // market-order slippage allowance
#define FLATTEN_THROTTLE_SEC 30     // blackout flatten retry interval
#define MODIFY_TIMEOUT_MS    5000   // async SL modify confirmation timeout

#define SIDE_BUY   0
#define SIDE_SELL  1

#define LDN_WAIT   0
#define LDN_IN     1
#define LDN_DONE   2

//+------------------------------------------------------------------+
//|  GLOBAL STATE                                                    |
//+------------------------------------------------------------------+
string g_sym      = "";
double g_pt       = 0;
int    g_dg       = 0;
double g_tick     = 0;
bool   g_isTester = false;
ulong  g_magicPDH = 0, g_magicLDN = 0, g_magic4H = 0;

struct SLondonHours
  {
   int startBroker;
   int endBroker;
  };
SLondonHours g_ldn;
int          g_utcOffset = 0;
bool         g_tzInit    = false;
ENUM_TIMEFRAMES g_confirmTF = PERIOD_M5;   // resolved from InpConfirmMinutes

// MT5 only builds candles for these minute sizes.
ENUM_TIMEFRAMES MinutesToTF(int m)
  {
   switch(m)
     {
      case 2:  return PERIOD_M2;
      case 3:  return PERIOD_M3;
      case 4:  return PERIOD_M4;
      case 5:  return PERIOD_M5;
      case 6:  return PERIOD_M6;
      case 10: return PERIOD_M10;
      case 12: return PERIOD_M12;
      case 15: return PERIOD_M15;
      case 20: return PERIOD_M20;
      case 30: return PERIOD_M30;
      case 60: return PERIOD_H1;
      default: return PERIOD_CURRENT;   // unsupported
     }
  }

//+------------------------------------------------------------------+
//|  DIAGNOSTICS - reason codes                                      |
//+------------------------------------------------------------------+
enum EReason
  {
   R_NONE = 0,
   R_OK,
   R_ALREADY_TRADED,
   R_DUPLICATE_ORDERS,
   R_POSITION_OPEN,
   R_FLUSH_PENDING,
   R_INVALID_LEVELS,
   R_PRICE_BEYOND_LEVEL,
   R_INVALID_SL,
   R_INVALID_TP,
   R_INVALID_VOLUME,
   R_STOP_LEVEL,
   R_SPREAD_TOO_HIGH,
   R_RISK_HALT,
   R_RISK_CALC_FAILED,
   R_RISK_ABOVE_LIMIT,
   R_NO_MARGIN,
   R_BLACKOUT,
   R_SESSION_CLOSED,
   R_NOT_CONNECTED,
   R_TRADING_NOT_ALLOWED,
   R_SYMBOL_TRADE_DISABLED,
   R_BAD_QUOTES,
   R_DIRECTION_DISABLED,
   R_CONFIRMATION_FAILED,
   R_BROKER_REJECTED,
   R_BROKER_BACKOFF,
   R_HISTORY_UNAVAILABLE
  };

string ReasonText(EReason r)
  {
   switch(r)
     {
      case R_OK:                   return "OK";
      case R_ALREADY_TRADED:       return "ALREADY_TRADED";
      case R_DUPLICATE_ORDERS:     return "DUPLICATE_SETUP";
      case R_POSITION_OPEN:        return "POSITION_OPEN";
      case R_FLUSH_PENDING:        return "OLD_ORDERS_PENDING_DELETE";
      case R_INVALID_LEVELS:       return "INVALID_LEVELS";
      case R_PRICE_BEYOND_LEVEL:   return "PRICE_BEYOND_LEVEL";
      case R_INVALID_SL:           return "INVALID_SL";
      case R_INVALID_TP:           return "INVALID_TP";
      case R_INVALID_VOLUME:       return "INVALID_VOLUME";
      case R_STOP_LEVEL:           return "STOP_LEVEL_VIOLATION";
      case R_SPREAD_TOO_HIGH:      return "SPREAD_TOO_HIGH";
      case R_RISK_HALT:            return "DAILY_RISK_LIMIT";
      case R_RISK_CALC_FAILED:     return "RISK_CALC_FAILED";
      case R_RISK_ABOVE_LIMIT:     return "RISK_ABOVE_LIMIT";
      case R_NO_MARGIN:            return "NO_MARGIN";
      case R_BLACKOUT:             return "BLACKOUT";
      case R_SESSION_CLOSED:       return "SESSION_NOT_ACTIVE";
      case R_NOT_CONNECTED:        return "NOT_CONNECTED";
      case R_TRADING_NOT_ALLOWED:  return "TRADING_NOT_ALLOWED";
      case R_SYMBOL_TRADE_DISABLED:return "SYMBOL_TRADE_DISABLED";
      case R_BAD_QUOTES:           return "BAD_QUOTES";
      case R_DIRECTION_DISABLED:   return "DIRECTION_DISABLED";
      case R_CONFIRMATION_FAILED:  return "CONFIRMATION_FAILED";
      case R_BROKER_REJECTED:      return "BROKER_REJECTED";
      case R_BROKER_BACKOFF:       return "BROKER_BACKOFF";
      case R_HISTORY_UNAVAILABLE:  return "HISTORY_UNAVAILABLE";
      default:                     return "NONE";
     }
  }

//+------------------------------------------------------------------+
//|  UTILITY                                                         |
//+------------------------------------------------------------------+
double PtsToPrice(double pts) { return pts * g_pt; }

// Snap to the broker's tick grid (not merely digits) to avoid "invalid price".
double NormalizeToTick(double price)
  {
   if(g_tick <= 0) return NormalizeDouble(price, g_dg);
   return NormalizeDouble(MathRound(price / g_tick) * g_tick, g_dg);
  }

string SideName(int side) { return (side == SIDE_BUY) ? "BUY" : "SELL"; }

bool DirEnabled(int side)
  {
   if(InpDirection == DIR_BOTH) return true;
   return (side == SIDE_BUY) ? (InpDirection == DIR_BUY_ONLY) : (InpDirection == DIR_SELL_ONLY);
  }

bool UsesConfirmation() { return InpConfirmPDH || InpConfirmLondon || InpConfirm4H; }

//+------------------------------------------------------------------+
//|  TIME / SESSION                                                  |
//|  Bar-coupled logic (periods, blackout, London phase) uses         |
//|  TimeCurrent() - the time of the last tick - so a day or H4       |
//|  rollover is never seen before the new bar exists. Only the       |
//|  broker session check uses TimeTradeServer(), which must work     |
//|  without a fresh tick.                                           |
//+------------------------------------------------------------------+
datetime DayStartNow()
  {
   datetime t = iTime(g_sym, PERIOD_D1, 0);
   if(t <= 0) { long now = (long)TimeCurrent(); t = (datetime)(now - now % 86400); }
   return t;
  }

datetime H4StartNow()
  {
   datetime t = iTime(g_sym, PERIOD_H4, 0);
   if(t <= 0) { long now = (long)TimeCurrent(); t = (datetime)(now - now % 14400); }
   return t;
  }

int ServerHour() { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt.hour; }

int NormalizeHour(int h) { return ((h % 24) + 24) % 24; }

bool InSession(int h, int start, int end)
  {
   if(start == end) return false;
   if(start < end) return (h >= start && h < end);
   return (h >= start || h < end);
  }

int DaysInMonth(int y, int m)
  {
   int d[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
   if(m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) return 29;
   return d[m - 1];
  }

int DayOfWeekOf(int y, int m, int day)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = y; s.mon = m; s.day = day;
   MqlDateTime o;
   TimeToStruct(StructToTime(s), o);
   return o.day_of_week;
  }

int NthSunday(int y, int m, int n) { return 1 + (7 - DayOfWeekOf(y, m, 1)) % 7 + 7 * (n - 1); }
int LastSunday(int y, int m)       { int dim = DaysInMonth(y, m); return dim - DayOfWeekOf(y, m, dim); }

// DST at day granularity (switches happen on Sunday, when gold is closed).
bool IsUSDST(datetime t)
  {
   MqlDateTime s; TimeToStruct(t, s);
   int md = s.mon * 100 + s.day;
   return md >= 300 + NthSunday(s.year, 3, 2) && md < 1100 + NthSunday(s.year, 11, 1);
  }

bool IsEUDST(datetime t)
  {
   MqlDateTime s; TimeToStruct(t, s);
   int md = s.mon * 100 + s.day;
   return md >= 300 + LastSunday(s.year, 3) && md < 1000 + LastSunday(s.year, 10);
  }

// Live only: server offset = TimeTradeServer() - TimeGMT(). Unreliable if the
// PC clock is skewed, so a result not close to a whole hour is discarded.
bool DetectLiveUTCOffset(int &offset)
  {
   offset = InpBrokerUTCOffset;
   if(g_isTester) return false;
   datetime srv = TimeTradeServer();
   datetime gmt = TimeGMT();
   if(srv <= 0 || gmt <= 0) return false;
   long diff = (long)srv - (long)gmt;
   int  hrs  = (int)MathRound(diff / 3600.0);
   if(MathAbs(diff - (long)hrs * 3600) > 300 || hrs < -12 || hrs > 14) return false;
   offset = hrs;
   return true;
  }

SLondonHours CalcLondonSessionHours(int utcOffset)
  {
   SLondonHours h;
   h.startBroker = NormalizeHour(InpLondonOpenUTC  + utcOffset);
   h.endBroker   = NormalizeHour(InpLondonCloseUTC + utcOffset);
   PrintFormat("[Time] London UTC %02d:00-%02d:00 | broker offset UTC%+d | effective server window %02d:00-%02d:00",
               InpLondonOpenUTC, InpLondonCloseUTC, utcOffset, h.startBroker, h.endBroker);
   return h;
  }

// Called at init and on every new day - never mid-session, so a London range
// being tracked is never split across two different windows.
void ApplyBrokerTimezone(string ctx)
  {
   datetime now = TimeCurrent();
   int    modelOff = InpBrokerUTCOffset;
   string model    = "FIXED";
   if(InpBrokerTZ == TZ_EET_US_DST)      { modelOff = 2 + (IsUSDST(now) ? 1 : 0); model = "EET+US-DST"; }
   else if(InpBrokerTZ == TZ_EET_EU_DST) { modelOff = 2 + (IsEUDST(now) ? 1 : 0); model = "EET+EU-DST"; }
   else if(InpBrokerTZ == TZ_AUTO_LIVE)  { model = "AUTO-LIVE"; }

   int  det;
   bool haveDet = DetectLiveUTCOffset(det);
   int  use     = (InpBrokerTZ == TZ_AUTO_LIVE && haveDet) ? det : modelOff;

   if(haveDet && det != use)
     {
      string msg = StringFormat("[Time:%s] MISMATCH: broker server is UTC%+d but the %s model gives UTC%+d. "
                                "London window is %dh off. Fix InpBrokerUTCOffset / InpBrokerTZ.",
                                ctx, det, model, use, MathAbs(det - use));
      Print(msg);
      Alert(msg);
     }
   if(!g_tzInit && g_isTester && InpBrokerTZ == TZ_AUTO_LIVE)
      Print("[Time] AUTO-LIVE cannot detect DST in the Strategy Tester - using fixed InpBrokerUTCOffset. "
            "Use an EET+DST model for DST-correct backtests.");

   if(!g_tzInit || use != g_utcOffset)
     {
      if(g_tzInit)
         PrintFormat("[Time:%s] Broker offset changed UTC%+d -> UTC%+d (%s) - London window recalculated",
                     ctx, g_utcOffset, use, model);
      g_utcOffset = use;
      g_ldn       = CalcLondonSessionHours(use);
      g_tzInit    = true;
     }
  }

//--- Daily-open blackout window [close - Before, reopen + After), server time.
void BlackoutWindow(int &s, int &e)
  {
   s = ((InpBreakCloseHour * 60 + InpBreakCloseMin - InpBlackoutBeforeMin) % 1440 + 1440) % 1440;
   e = ((InpBreakOpenHour  * 60 + InpBreakOpenMin  + InpBlackoutAfterMin ) % 1440 + 1440) % 1440;
  }

bool InBlackout()
  {
   if(!InpEnableBlackout) return false;
   int s, e;
   BlackoutWindow(s, e);
   if(s == e) return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int m = dt.hour * 60 + dt.min;
   if(s < e) return (m >= s && m < e);
   return (m >= s || m < e);
  }

// Next blackout start as an absolute server time - used as a broker-side
// expiry on pending legs (safety net if our own cancel is ever rejected).
datetime NextBlackoutStart()
  {
   if(!InpEnableBlackout) return 0;
   int s, e;
   BlackoutWindow(s, e);
   if(s == e) return 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int deltaMin = s - (dt.hour * 60 + dt.min);
   if(deltaMin <= 0) deltaMin += 1440;
   return TimeCurrent() + (datetime)deltaMin * 60 - dt.sec;
  }

//+------------------------------------------------------------------+
//|  SYMBOL / BROKER                                                 |
//|  The EA trades the CHART symbol, which already carries the        |
//|  broker's exact name (XAUUSD, XAUUSD.m, XAUUSD.x, ...). The alias |
//|  list is only a guard against running on the wrong instrument.    |
//+------------------------------------------------------------------+
bool ChartMatchesAliases()
  {
   string aliases[];
   int n = StringSplit(InpSymbolAliases, ',', aliases);
   bool any = false;
   string sym = _Symbol;
   StringToUpper(sym);
   for(int a = 0; a < n; a++)
     {
      string base = aliases[a];
      StringTrimLeft(base);
      StringTrimRight(base);
      if(base == "") continue;
      any = true;
      StringToUpper(base);                        // case-insensitive: "xauusd.m" matches "XAUUSD.m"
      if(StringFind(sym, base) >= 0) return true;
     }
   return !any; // empty alias list = no guard
  }

bool InitSymbol()
  {
   g_sym  = _Symbol;
   g_pt   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   g_dg   = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   g_tick = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   if(g_tick <= 0) g_tick = g_pt;

   if(!ChartMatchesAliases())
     {
      string msg = StringFormat("[Symbol] SYMBOL_NOT_FOUND: chart '%s' does not match InpSymbolAliases='%s'. "
                                "EA will NOT trade. Attach to the right chart or update the alias list.",
                                _Symbol, InpSymbolAliases);
      Print(msg);
      Alert(msg);
      return false;
     }
   if(g_pt <= 0)
     {
      PrintFormat("[Symbol] SYMBOL_NOT_FOUND: no point size for '%s'", g_sym);
      return false;
     }
   PrintFormat("[Symbol] Trading %s | point=%.6f digits=%d tickSize=%.6f | SL=%.0f pts (%.*f) TP=%.0f pts (%.*f)",
               g_sym, g_pt, g_dg, g_tick, InpSL_Pts, g_dg, InpSL_Pts * g_pt, InpTP_Pts, g_dg, InpTP_Pts * g_pt);
   if((SymbolInfoInteger(g_sym, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_SPECIFIED) == 0)
      PrintFormat("[Symbol] Broker does not support timed expiry on %s - pending legs are GTC (EA still cancels them itself)", g_sym);
   return true;
  }

bool IsMarketOpenNow()
  {
   datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int secOfDay = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime from, to;
   for(int s = 0; ; s++)
     {
      if(!SymbolInfoSessionTrade(g_sym, (ENUM_DAY_OF_WEEK)dt.day_of_week, s, from, to)) break;
      if(secOfDay >= (int)from && secOfDay < (int)to) return true;
     }
   return false;
  }

bool SideAllowedByBroker(int side)
  {
   long m = SymbolInfoInteger(g_sym, SYMBOL_TRADE_MODE);
   if(m == SYMBOL_TRADE_MODE_FULL)      return true;
   if(m == SYMBOL_TRADE_MODE_LONGONLY)  return side == SIDE_BUY;
   if(m == SYMBOL_TRADE_MODE_SHORTONLY) return side == SIDE_SELL;
   return false;
  }

bool IsTransientRetcode(uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return true;
      default:
         return false;
     }
  }

// Account / terminal / market preconditions shared by every entry.
EReason CheckEnvironment(string &detail)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     { detail = "terminal not connected"; return R_NOT_CONNECTED; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_EXPERT) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     { detail = "algo trading not allowed (terminal/EA/account)"; return R_TRADING_NOT_ALLOWED; }
   long tmode = SymbolInfoInteger(g_sym, SYMBOL_TRADE_MODE);
   if(tmode == SYMBOL_TRADE_MODE_DISABLED || tmode == SYMBOL_TRADE_MODE_CLOSEONLY)
     { detail = StringFormat("%s trade mode does not allow new positions", g_sym); return R_SYMBOL_TRADE_DISABLED; }
   if(!IsMarketOpenNow())
     { detail = "broker trade session closed - will retry when it opens"; return R_SESSION_CLOSED; }
   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0 || ask < bid)
     { detail = StringFormat("bid=%.5f ask=%.5f", bid, ask); return R_BAD_QUOTES; }
   double spreadPts = (ask - bid) / g_pt;
   if(InpMaxSpreadPts > 0 && spreadPts > InpMaxSpreadPts)
     { detail = StringFormat("spread %.0f pts > max %d", spreadPts, InpMaxSpreadPts); return R_SPREAD_TOO_HIGH; }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) <= 0)
     { detail = "no free margin"; return R_NO_MARGIN; }
   return R_OK;
  }

// Stop-distance validation. Pending stops are measured from the entry price;
// market orders from the price the position will be CLOSED at (Bid for a buy,
// Ask for a sell) - the broker's rule. SL is mandatory.
EReason CheckStops(bool isBuy, bool isPending, double entry, double sl, double tp, string &detail)
  {
   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);

   if(sl <= 0 || (isBuy && sl >= entry) || (!isBuy && sl <= entry))
     { detail = StringFormat("entry=%.5f sl=%.5f", entry, sl); return R_INVALID_SL; }
   if(tp > 0 && ((isBuy && tp <= entry) || (!isBuy && tp >= entry)))
     { detail = StringFormat("entry=%.5f tp=%.5f", entry, tp); return R_INVALID_TP; }

   if(isPending)
     {
      double gap = isBuy ? (entry - ask) : (bid - entry);
      if(gap <= 0)
        { detail = StringFormat("price already beyond %s STOP entry %.5f (ask=%.5f bid=%.5f)", isBuy ? "BUY" : "SELL", entry, ask, bid); return R_PRICE_BEYOND_LEVEL; }
     }

   long   stopsLvl = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist  = stopsLvl * g_pt;
   if(minDist <= 0) return R_OK;

   if(isPending)
     {
      double gap = isBuy ? (entry - ask) : (bid - entry);
      if(gap < minDist)
        { detail = StringFormat("entry %.5f is %.0f pts from market, broker min %d", entry, gap / g_pt, (int)stopsLvl); return R_STOP_LEVEL; }
      if(MathAbs(entry - sl) < minDist || (tp > 0 && MathAbs(tp - entry) < minDist))
        { detail = StringFormat("SL/TP closer than broker min %d pts to entry", (int)stopsLvl); return R_STOP_LEVEL; }
     }
   else
     {
      double closePx = isBuy ? bid : ask;
      double slGap = isBuy ? (closePx - sl) : (sl - closePx);
      double tpGap = (tp > 0) ? (isBuy ? (tp - closePx) : (closePx - tp)) : minDist;
      if(slGap < minDist || tpGap < minDist)
        { detail = StringFormat("SL/TP closer than broker min %d pts to %s", (int)stopsLvl, isBuy ? "bid" : "ask"); return R_STOP_LEVEL; }
     }
   return R_OK;
  }

//+------------------------------------------------------------------+
//|  POSITION / ORDER OWNERSHIP (single check used everywhere)       |
//+------------------------------------------------------------------+
bool SelectedPositionIsOurs(ulong magic)
  {
   return PositionGetString(POSITION_SYMBOL) == g_sym && (ulong)PositionGetInteger(POSITION_MAGIC) == magic;
  }

bool SelectedOrderIsOurs(ulong magic)
  {
   return OrderGetString(ORDER_SYMBOL) == g_sym && (ulong)OrderGetInteger(ORDER_MAGIC) == magic;
  }

bool IsEAMagic(ulong m) { return m == g_magicPDH || m == g_magicLDN || m == g_magic4H; }

int CountPositions(ulong magic)
  {
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
      if(PositionGetTicket(i) > 0 && SelectedPositionIsOurs(magic)) c++;
   return c;
  }

int CountPendings(ulong magic)
  {
   int c = 0;
   for(int i = 0; i < OrdersTotal(); i++)
      if(OrderGetTicket(i) > 0 && SelectedOrderIsOurs(magic)) c++;
   return c;
  }

// Close positions and/or delete pendings for one magic. Returns how many
// could NOT be closed/deleted (caller retries).
int CloseAllFor(CTrade &trade, ulong magic, bool positions, bool pendings, string why)
  {
   int remaining = 0;
   trade.SetExpertMagicNumber(magic);
   if(positions)
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !SelectedPositionIsOurs(magic)) continue;
         if(trade.PositionClose(t))
            PrintFormat("[Close] position #%I64u closed (%s)", t, why);
         else
           {
            remaining++;
            PrintFormat("[Close] position #%I64u close FAILED (%s) rc=%u %s", t, why,
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
           }
        }
   if(pendings)
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0 || !SelectedOrderIsOurs(magic)) continue;
         if(trade.OrderDelete(t))
            PrintFormat("[Close] pending #%I64u deleted (%s)", t, why);
         else
           {
            remaining++;
            PrintFormat("[Close] pending #%I64u delete FAILED (%s) rc=%u %s", t, why,
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
           }
        }
   return remaining;
  }

//+------------------------------------------------------------------+
//|  RISK - lot sizing                                               |
//|  lot = (balance x risk%) / loss of 1.0 lot from entry to SL,      |
//|  with the loss asked from the broker via OrderCalcProfit - never  |
//|  hand-derived from points/pips/ticks. The final lot's real risk   |
//|  is re-checked: rounding UP to the broker minimum can never push  |
//|  risk above target + InpMaxRiskOverPct.                           |
//+------------------------------------------------------------------+
int VolumeDigits(double step)
  {
   int d = 0;
   while(d < 8 && MathAbs(step * MathPow(10, d) - MathRound(step * MathPow(10, d))) > 1e-8) d++;
   return d;
  }

double ClampVolume(double v)
  {
   double step   = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   double lot = step * MathFloor(v / step + 1e-9);
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(lot, VolumeDigits(step));
  }

EReason CalcLot(ENUM_ORDER_TYPE type, double entry, double sl, double &lot, string &detail)
  {
   lot = 0;
   if(!InpAutoLot)
     {
      lot = ClampVolume(InpFixedLot);
      if(lot <= 0) { detail = "fixed lot clamps to 0"; return R_INVALID_VOLUME; }
      return R_OK;
     }
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPct / 100.0;
   if(riskMoney <= 0) { detail = "balance/risk gives 0 risk money"; return R_RISK_CALC_FAILED; }

   double lossPerLot = 0;
   if(!OrderCalcProfit(type, g_sym, 1.0, entry, sl, lossPerLot))
     { detail = StringFormat("OrderCalcProfit error %d", GetLastError()); return R_RISK_CALC_FAILED; }
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0) { detail = "loss per lot is 0"; return R_RISK_CALC_FAILED; }

   lot = ClampVolume(riskMoney / lossPerLot);
   if(lot <= 0) { detail = "volume clamps to 0"; return R_INVALID_VOLUME; }

   double actual = 0;
   if(!OrderCalcProfit(type, g_sym, lot, entry, sl, actual))
     { detail = StringFormat("OrderCalcProfit error %d (final lot)", GetLastError()); return R_RISK_CALC_FAILED; }
   actual = MathAbs(actual);
   double limit = riskMoney * (1.0 + InpMaxRiskOverPct / 100.0);
   detail = StringFormat("target=%.2f actual=%.2f lot=%.2f (raw %.4f)", riskMoney, actual, lot, riskMoney / lossPerLot);
   if(actual > limit)
     {
      detail = StringFormat("lot %.2f risks %.2f > target %.2f +%.1f%% (broker min lot %.2f too large for this balance/SL)",
                            lot, actual, riskMoney, InpMaxRiskOverPct, SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN));
      return R_RISK_ABOVE_LIMIT;
     }
   return R_OK;
  }

//+------------------------------------------------------------------+
//|  CHART VISUALS                                                   |
//+------------------------------------------------------------------+
void DrawLevel(string name, double price, color clr)
  {
   if(price <= 0) return;
   datetime t1 = iTime(g_sym, PERIOD_D1, 1);
   datetime t2 = TimeCurrent() + 86400 * 2;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TREND, 0, t1, price, t2, price);
   else
     {
      ObjectMove(0, name, 0, t1, price);
      ObjectMove(0, name, 1, t2, price);
     }
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,      STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK,       true);
  }

void DrawLabel(string name, double price, string text, color clr)
  {
   if(price <= 0) return;
   datetime t = TimeCurrent() + 3600;
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

// Live only (tester keeps everything so the finished chart can be reviewed):
// removes level lines and live order/position lines. Entry/exit arrows
// (EA_DEAL_*) are trade history and are kept.
void DeleteAllVisuals()
  {
   if(g_isTester) return;
   string names[] = {"EA_PDH","EA_PDL","EA_LSH","EA_LSL","EA_H4H","EA_H4L",
                     "LBL_PDH","LBL_PDL","LBL_LSH","LBL_LSL","LBL_H4H","LBL_H4L"};
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, names[i]);
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i, 0, -1);
      if(StringFind(nm, "EA_ORD_") == 0 || StringFind(nm, "EA_POS_") == 0) ObjectDelete(0, nm);
     }
  }

bool VisualsOn() { return InpEnableVisuals && !MQLInfoInteger(MQL_OPTIMIZATION); }

void UpdateVisuals(double pdh, double pdl, double lsh, double lsl)
  {
   if(!InpEnableVisuals) return;
   DrawLevel("EA_PDH", pdh, clrDodgerBlue);
   DrawLevel("EA_PDL", pdl, clrOrangeRed);
   DrawLevel("EA_LSH", lsh, clrLime);
   DrawLevel("EA_LSL", lsl, clrYellow);
   if(pdh > 0) DrawLabel("LBL_PDH", pdh, "PDH " + DoubleToString(pdh, g_dg), clrDodgerBlue);
   if(pdl > 0) DrawLabel("LBL_PDL", pdl, "PDL " + DoubleToString(pdl, g_dg), clrOrangeRed);
   if(lsh > 0) DrawLabel("LBL_LSH", lsh, "LSH " + DoubleToString(lsh, g_dg), clrLime);
   if(lsl > 0) DrawLabel("LBL_LSL", lsl, "LSL " + DoubleToString(lsl, g_dg), clrYellow);
   ChartRedraw();
  }

void DrawH4Levels(double hi, double lo, datetime srcCandleOpen)
  {
   if(!InpEnableVisuals) return;
   datetime t2 = srcCandleOpen + 8 * 3600;   // source candle + the candle it is traded in
   DrawLevel("EA_H4H", hi, clrMagenta);
   DrawLevel("EA_H4L", lo, clrAqua);
   ObjectMove(0, "EA_H4H", 0, srcCandleOpen, hi);  ObjectMove(0, "EA_H4H", 1, t2, hi);
   ObjectMove(0, "EA_H4L", 0, srcCandleOpen, lo);  ObjectMove(0, "EA_H4L", 1, t2, lo);
   ObjectSetInteger(0, "EA_H4H", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, "EA_H4L", OBJPROP_WIDTH, 2);
   DrawLabel("LBL_H4H", hi, "4H High " + DoubleToString(hi, g_dg), clrMagenta);
   DrawLabel("LBL_H4L", lo, "4H Low "  + DoubleToString(lo, g_dg), clrAqua);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//|  TRADE VISUALS                                                   |
//|  Pending orders: entry (dashed) + SL + TP lines.                 |
//|  Open positions: entry + SL (follows breakeven/trailing) + TP.    |
//|  Every deal: entry/exit arrow; on close a dotted line joins the   |
//|  entry and exit. Lines start at the order/position time and run   |
//|  to the right; the object description shows what each line is.   |
//+------------------------------------------------------------------+
bool g_visDirty = true;   // set on trade events -> stale lines get cleaned up

// Horizontal ray from t0. Returns true if anything was created or moved.
bool DrawPriceLine(string name, datetime t0, double price, color clr, ENUM_LINE_STYLE style, int width, string descr)
  {
   if(price <= 0)
     {
      if(ObjectFind(0, name) >= 0) { ObjectDelete(0, name); return true; }
      return false;
     }
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, t0, price, t0 + 60, price);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT,  true);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE,      style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH,      width);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetString(0, name, OBJPROP_TEXT,    descr);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, descr);
      return true;
     }
   if(MathAbs(ObjectGetDouble(0, name, OBJPROP_PRICE, 0) - price) < g_pt / 2) return false;
   ObjectMove(0, name, 0, t0, price);
   ObjectMove(0, name, 1, t0 + 60, price);
   ObjectSetString(0, name, OBJPROP_TEXT,    descr);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, descr);
   return true;
  }

string ModuleName(ulong magic)
  {
   if(magic == g_magicPDH) return "PDH";
   if(magic == g_magicLDN) return "London";
   if(magic == g_magic4H)  return "4H";
   return "?";
  }

// Called every tick; only touches objects whose price changed.
void UpdateTradeVisuals()
  {
   if(!VisualsOn()) return;
   bool changed = false;

   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetString(ORDER_SYMBOL) != g_sym) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(!IsEAMagic(mg)) continue;
      bool isBuy = ((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == ORDER_TYPE_BUY_STOP);
      datetime t0 = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      string   p  = "EA_ORD_" + (string)t + "_";
      string   m  = ModuleName(mg) + (isBuy ? " BUY STOP #" : " SELL STOP #") + (string)t;
      changed |= DrawPriceLine(p + "E",  t0, OrderGetDouble(ORDER_PRICE_OPEN), isBuy ? clrDodgerBlue : clrOrangeRed, STYLE_DASH, 1, m + " entry");
      changed |= DrawPriceLine(p + "SL", t0, OrderGetDouble(ORDER_SL), clrRed,  STYLE_DOT, 1, m + " SL");
      changed |= DrawPriceLine(p + "TP", t0, OrderGetDouble(ORDER_TP), clrLime, STYLE_DOT, 1, m + " TP");
     }

   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetString(POSITION_SYMBOL) != g_sym) continue;
      ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(!IsEAMagic(mg)) continue;
      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      datetime t0 = (datetime)PositionGetInteger(POSITION_TIME);
      string   p  = "EA_POS_" + (string)t + "_";
      string   m  = ModuleName(mg) + (isBuy ? " BUY #" : " SELL #") + (string)t;
      changed |= DrawPriceLine(p + "E",  t0, PositionGetDouble(POSITION_PRICE_OPEN), isBuy ? clrDodgerBlue : clrOrangeRed, STYLE_SOLID, 1, m + " entry");
      changed |= DrawPriceLine(p + "SL", t0, PositionGetDouble(POSITION_SL), clrRed,  STYLE_SOLID, 2, m + " SL / trailing");
      changed |= DrawPriceLine(p + "TP", t0, PositionGetDouble(POSITION_TP), clrLime, STYLE_SOLID, 1, m + " TP");
     }

   // After a trade event: remove lines of orders/positions that no longer exist.
   if(g_visDirty)
     {
      g_visDirty = false;
      for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
        {
         string nm = ObjectName(0, i, 0, -1);
         bool isOrd = (StringFind(nm, "EA_ORD_") == 0), isPos = (StringFind(nm, "EA_POS_") == 0);
         if(!isOrd && !isPos) continue;
         string rest = StringSubstr(nm, 7);
         ulong  t    = (ulong)StringToInteger(StringSubstr(rest, 0, StringFind(rest, "_")));
         bool alive  = isOrd ? OrderSelect(t) : PositionSelectByTicket(t);
         if(!alive) { ObjectDelete(0, nm); changed = true; }
        }
     }
   if(changed) ChartRedraw();
  }

// Entry/exit arrow for one of our deals, plus an entry->exit line on close.
void DrawDealArrow(ulong deal)
  {
   if(!VisualsOn()) return;
   datetime t     = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   double   px    = HistoryDealGetDouble(deal, DEAL_PRICE);
   long     type  = HistoryDealGetInteger(deal, DEAL_TYPE);
   long     entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   ulong    posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   ulong    mg    = (ulong)HistoryDealGetInteger(deal, DEAL_MAGIC);
   double   pl    = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
   bool     isIn  = (entry == DEAL_ENTRY_IN);
   bool     buyDeal = (type == DEAL_TYPE_BUY);

   string name = "EA_DEAL_" + (string)deal;
   ObjectCreate(0, name, buyDeal ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, t, px);
   ObjectSetInteger(0, name, OBJPROP_COLOR, isIn ? (buyDeal ? clrDodgerBlue : clrOrangeRed) : clrGold);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   string descr = isIn ? StringFormat("%s %s entry @ %.*f", ModuleName(mg), buyDeal ? "BUY" : "SELL", g_dg, px)
                       : StringFormat("%s exit @ %.*f  P/L %.2f", ModuleName(mg), g_dg, px, pl);
   ObjectSetString(0, name, OBJPROP_TEXT, descr);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, descr);

   if(!isIn && posId > 0 && HistorySelectByPosition(posId))
     {
      for(int i = 0; i < HistoryDealsTotal(); i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0 || HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         datetime t0  = (datetime)HistoryDealGetInteger(d, DEAL_TIME);
         double   p0  = HistoryDealGetDouble(d, DEAL_PRICE);
         bool     buy = (HistoryDealGetInteger(d, DEAL_TYPE) == DEAL_TYPE_BUY);
         string   ln  = name + "_L";
         ObjectCreate(0, ln, OBJ_TREND, 0, t0, p0, t, px);
         ObjectSetInteger(0, ln, OBJPROP_COLOR, buy ? clrDodgerBlue : clrOrangeRed);
         ObjectSetInteger(0, ln, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, ln, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, ln, OBJPROP_SELECTABLE, false);
         ObjectSetString(0, ln, OBJPROP_TOOLTIP, descr);
         break;
        }
     }
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//|  ACCOUNT GUARD: CRiskGovernor                                    |
//|  Equity-based daily-loss and overall-drawdown limits. Blocks new |
//|  entries and (optionally) flattens all three modules, retrying    |
//|  until the book is actually flat.                                |
//+------------------------------------------------------------------+
class CRiskGovernor
  {
private:
   CTrade   m_trade;
   double   m_dayAnchor;
   double   m_hwm;
   bool     m_dayHalted;
   bool     m_permHalted;
   int      m_ddBreaches;
   int      m_dayBreaches;
   int      m_pauseUntilDay;
   bool     m_flattenOwed;
   string   m_flattenWhy;
   datetime m_lastFlattenTry;

   // Persistence is live-only; every backtest starts clean.
   void   GVSet(string name, double v) { if(!g_isTester) GlobalVariableSet(name, v); }
   bool   GVHas(string name)           { return !g_isTester && GlobalVariableCheck(name); }
   double GVGet(string name)           { return g_isTester ? 0 : GlobalVariableGet(name); }

   string GVAnchor()    { return "RG_DAYANCHOR_" + g_sym; }
   string GVAnchorDay() { return "RG_ANCHORDAY_" + g_sym; }
   string GVHwm()       { return "RG_HWM_"       + g_sym; }
   string GVResetDone() { return "RG_RESETDONE_" + g_sym; }

   int TodayInt() { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt.year * 10000 + dt.mon * 100 + dt.day; }

   // v6.03: a breach used to market-close EVERY open position unconditionally,
   // via the same CloseAllFor() the blackout-flatten path uses. That treats a
   // position with a perfectly intact, unbroken native SL the same as one
   // whose stop has already been gapped through - closing it at the current
   // market price even when that price is worse than the SL it already has,
   // and even though the SL alone already caps that position's remaining
   // risk. The governor's real job on a breach is to stop NEW risk (handled
   // by TradingAllowed() gating entries) and to catch positions whose native
   // stop can no longer be trusted - not to pre-empt a stop that still works.
   //
   // NeedsForceClose() returns true only when:
   //   - the position has no SL at all (nothing capping its risk), or
   //   - price has already traded through the SL level (the native stop
   //     should have filled by now but the position is still open - a
   //     genuine gap/slippage situation the governor should act on).
   // Otherwise the native SL is left to do its job untouched.
   bool NeedsForceClose(ulong ticket)
     {
      if(!PositionSelectByTicket(ticket)) return false;
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0) return true;   // unprotected position - always force close

      bool   isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double bid   = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double ask   = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      return isBuy ? (bid <= sl) : (ask >= sl);
     }

   // Closes only positions that NeedsForceClose(); always clears pendings for
   // this magic (an unfilled setup adding new risk this period is exactly
   // what a breach should stop, regardless of SL status - there's no SL to
   // respect on an order that hasn't filled yet). Returns items still owed.
   int FlattenFor(ulong magic)
     {
      int remaining = 0;
      m_trade.SetExpertMagicNumber(magic);
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !SelectedPositionIsOurs(magic)) continue;
         if(!NeedsForceClose(t))
           {
            if(InpDebug) PrintFormat("[RiskGov] Position #%I64u has an intact native SL ahead of price - leaving it (%s)", t, m_flattenWhy);
            continue;
           }
         if(m_trade.PositionClose(t))
            PrintFormat("[RiskGov] Position #%I64u force-closed at market (SL missing or already breached) (%s)", t, m_flattenWhy);
         else
           {
            remaining++;
            PrintFormat("[RiskGov] Position #%I64u force-close FAILED (%s) rc=%u %s", t, m_flattenWhy,
                        m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
           }
        }
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0 || !SelectedOrderIsOurs(magic)) continue;
         if(m_trade.OrderDelete(t))
            PrintFormat("[RiskGov] Pending #%I64u deleted (%s)", t, m_flattenWhy);
         else
           {
            remaining++;
            PrintFormat("[RiskGov] Pending #%I64u delete FAILED (%s) rc=%u %s", t, m_flattenWhy,
                        m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
           }
        }
      return remaining;
     }

   void DoFlatten()
     {
      int rem = FlattenFor(g_magicPDH) + FlattenFor(g_magicLDN) + FlattenFor(g_magic4H);
      if(rem == 0)
        {
         if(m_flattenOwed) PrintFormat("[RiskGov] FLATTEN COMPLETE (%s)", m_flattenWhy);
         m_flattenOwed = false;
        }
      else
        {
         m_flattenOwed = true;
         PrintFormat("[RiskGov] FLATTEN incomplete: %d item(s) left - retrying", rem);
        }
     }

   void Breach(string why)
     {
      if(InpEnablePush && !g_isTester) SendNotification(StringFormat("%s %s: %s", MQLInfoString(MQL_PROGRAM_NAME), g_sym, why));
      if(!InpCloseAllOnBreach) return;
      m_flattenWhy = why;
      DoFlatten();
     }

public:
   CRiskGovernor() : m_dayAnchor(0), m_hwm(0), m_dayHalted(false), m_permHalted(false),
                     m_ddBreaches(0), m_dayBreaches(0), m_pauseUntilDay(0),
                     m_flattenOwed(false), m_flattenWhy(""), m_lastFlattenTry(0) {}

   void Init()
     {
      m_trade.SetTypeFillingBySymbol(g_sym);
      m_trade.SetDeviationInPoints(DEVIATION_PTS);
      if(!InpEnableRiskGov) return;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);

      // One-time reset: runs once while the input is true, re-arms when set back to false.
      if(!g_isTester)
        {
         if(InpGovResetOnInit)
           {
            if(!GlobalVariableCheck(GVResetDone()))
              {
               GlobalVariableDel(GVHwm());
               GlobalVariableDel(GVAnchor());
               GlobalVariableDel(GVAnchorDay());
               GlobalVariableSet(GVResetDone(), 1);
               Print("[RiskGov] Saved anchors/high-water mark WIPED (one-time). Set InpGovResetOnInit=false now.");
              }
            else
               Print("[RiskGov] InpGovResetOnInit is still true but the one-time reset already ran - NOT wiping again.");
           }
         else if(GlobalVariableCheck(GVResetDone()))
            GlobalVariableDel(GVResetDone());
        }

      if(GVHas(GVHwm())) m_hwm = GVGet(GVHwm());
      if(m_hwm < eq) { m_hwm = eq; GVSet(GVHwm(), m_hwm); }

      int today = TodayInt();
      if(GVHas(GVAnchor()) && GVHas(GVAnchorDay()) && (int)GVGet(GVAnchorDay()) == today)
        {
         m_dayAnchor = GVGet(GVAnchor());
         PrintFormat("[RiskGov] Restored day anchor=%.2f (day %d) hwm=%.2f", m_dayAnchor, today, m_hwm);
        }
      else
         SetDailyAnchor(eq, today);
     }

   void SetDailyAnchor(double eq, int day)
     {
      m_dayAnchor = eq;
      m_dayHalted = false;
      GVSet(GVAnchor(), eq);
      GVSet(GVAnchorDay(), day);
      if(m_pauseUntilDay > 0 && day >= m_pauseUntilDay)
        {
         m_pauseUntilDay = 0;
         PrintFormat("[RiskGov] PAUSE ended - trading resumes (day %d)", day);
        }
      PrintFormat("[RiskGov] Day anchor: equity=%.2f (day %d)", eq, day);
     }

   void OnNewDay()
     {
      if(!InpEnableRiskGov) return;
      SetDailyAnchor(AccountInfoDouble(ACCOUNT_EQUITY), TodayInt());
     }

   bool TradingAllowed()
     {
      if(!InpEnableRiskGov) return true;
      if(m_pauseUntilDay > 0 && TodayInt() < m_pauseUntilDay) return false;
      return !(m_dayHalted || m_permHalted);
     }

   void OnTick()
     {
      if(!InpEnableRiskGov) return;

      if(m_flattenOwed && TimeCurrent() != m_lastFlattenTry)
        {
         m_lastFlattenTry = TimeCurrent();
         DoFlatten();
        }

      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > m_hwm) { m_hwm = eq; GVSet(GVHwm(), m_hwm); }

      bool pausedNow = (m_pauseUntilDay > 0 && TodayInt() < m_pauseUntilDay);
      if(!m_permHalted && !pausedNow && m_hwm > 0)
        {
         double ddPct = (m_hwm - eq) / m_hwm * 100.0;
         if(ddPct >= InpMaxDrawdownPct)
           {
            m_ddBreaches++;
            PrintFormat("[RiskGov] *** OVERALL DD BREACH #%d *** eq=%.2f hwm=%.2f dd=%.2f%% >= %.2f%%",
                        m_ddBreaches, eq, m_hwm, ddPct, InpMaxDrawdownPct);
            Breach("overall drawdown limit");
            if(InpGovHaltMode == GOV_PERMANENT)
               m_permHalted = true;
            else if(InpGovHaltMode == GOV_PAUSE_DAYS)
              {
               MqlDateTime dt;
               TimeToStruct(TimeCurrent() + (datetime)InpGovPauseDays * 86400, dt);
               m_pauseUntilDay = dt.year * 10000 + dt.mon * 100 + dt.day;
               m_hwm = eq; GVSet(GVHwm(), m_hwm);
               PrintFormat("[RiskGov] PAUSED until day %d, HWM re-based to %.2f", m_pauseUntilDay, m_hwm);
              }
            else
              { m_hwm = eq; GVSet(GVHwm(), m_hwm); }
           }
        }

      if(!m_dayHalted && !pausedNow && m_dayAnchor > 0)
        {
         double lossPct = (m_dayAnchor - eq) / m_dayAnchor * 100.0;
         if(lossPct >= InpDailyLossPct)
           {
            m_dayBreaches++;
            m_dayHalted = true;
            PrintFormat("[RiskGov] *** DAILY LOSS HALT #%d *** eq=%.2f anchor=%.2f loss=%.2f%% >= %.2f%%",
                        m_dayBreaches, eq, m_dayAnchor, lossPct, InpDailyLossPct);
            Breach("daily loss limit");
           }
        }
     }

   void LogSummary()
     {
      if(!InpEnableRiskGov) return;
      PrintFormat("[RiskGov] SUMMARY: overall-DD breaches=%d | daily-loss halts=%d | %s",
                  m_ddBreaches, m_dayBreaches,
                  m_ddBreaches > 0 ? "*** THIS CONFIG WOULD HAVE FAILED A PROP ACCOUNT ***" : "no overall-DD breach");
     }

   void LogState()
     {
      if(!InpEnableRiskGov) { Print("[RiskGov] DISABLED"); return; }
      PrintFormat("[RiskGov] eq=%.2f anchor=%.2f hwm=%.2f | daily %.1f%% overall %.1f%% | closeOnBreach=%s",
                  AccountInfoDouble(ACCOUNT_EQUITY), m_dayAnchor, m_hwm, InpDailyLossPct, InpMaxDrawdownPct,
                  InpCloseAllOnBreach ? "YES" : "NO");
     }
  };

CRiskGovernor g_risk;

//+------------------------------------------------------------------+
//|  POSITION MANAGEMENT: CTrailStop (one per leg, bound to ticket)  |
//|  Stage 1 breakeven -> stage 2 trail activation -> stage 3 trail. |
//|  Profit is measured on the entry-side price (SPREADFIX, v5.30):   |
//|  BUY = Ask move, SELL = Bid move, i.e. the chart point move.       |
//|  The SL itself is always placed off the executable price (Bid for |
//|  a buy, Ask for a sell), never moves backwards, and respects the  |
//|  broker stop and freeze levels.                                  |
//+------------------------------------------------------------------+
class CTrailStop
  {
private:
   ulong  m_magic;
   ulong  m_ticket;
   bool   m_init;
   bool   m_isBuy;
   bool   m_beDone;
   bool   m_trailActive;
   CTrade m_atrade;          // async - SL modifies never block the tick
   bool   m_pendingModify;
   double m_pendingSL;
   string m_pendingReason;
   ulong  m_pendingSentMs;

public:
   CTrailStop() : m_magic(0), m_ticket(0), m_init(false), m_isBuy(false), m_beDone(false), m_trailActive(false),
                  m_pendingModify(false), m_pendingSL(0), m_pendingReason(""), m_pendingSentMs(0) {}

   void Attach(ulong magic)
     {
      m_magic = magic;
      m_atrade.SetAsyncMode(true);
      m_atrade.SetExpertMagicNumber(magic);
     }

   ulong Ticket() const        { return m_ticket; }
   bool  IsTracking() const    { return m_init; }
   bool  MatchesTicket(ulong t) const { return m_init && m_ticket == t; }

   // Fresh fill and restart adoption use the same path: breakeven is
   // considered done if the SL already sits at/beyond entry.
   void Track(ulong ticket, bool isBuy, double entry, double curSL)
     {
      m_ticket = ticket; m_isBuy = isBuy; m_init = true; m_trailActive = false;
      m_beDone = (curSL > 0) && (isBuy ? (curSL >= entry - g_pt) : (curSL <= entry + g_pt));
      m_pendingModify = false;
      PrintFormat("[Trail %I64u #%I64u] TRACKING %s | entry=%.5f SL=%.5f | beDone=%s",
                  m_magic, m_ticket, isBuy ? "BUY" : "SELL", entry, curSL, m_beDone ? "yes" : "no");
     }

   void Reset()
     {
      m_init = false; m_ticket = 0; m_isBuy = false; m_beDone = false; m_trailActive = false;
      m_pendingModify = false; m_pendingSL = 0; m_pendingReason = ""; m_pendingSentMs = 0;
     }

   void OnAsyncModifyResult(bool success, uint retcode)
     {
      if(!m_pendingModify) return;
      if(success)
         PrintFormat("[Trail %I64u #%I64u] SL MOVED (%s) -> %.5f", m_magic, m_ticket, m_pendingReason, m_pendingSL);
      else
         PrintFormat("[Trail %I64u #%I64u] SL MODIFY REJECTED (%s) rc=%u target=%.5f", m_magic, m_ticket, m_pendingReason, retcode, m_pendingSL);
      m_pendingModify = false;
     }

   // Returns false once the position no longer exists.
   bool Update()
     {
      if(!m_init) return false;
      if(!PositionSelectByTicket(m_ticket)) return false;
      if(!InpEnableBreakEven && !InpEnableTrailing) return true;

      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid    = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double ask    = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      // v6.03: profit is now measured off the position's true closable price
      // (Bid for a BUY, Ask for a SELL) - i.e. real floating P/L. The prior
      // "SPREADFIX" (v5.30) measured off the entry-side price on both legs,
      // which algebraically overstates floating profit by exactly one spread
      // width in both directions - (ask-openPx)/pt for a BUY, (openPx-bid)/pt
      // for a SELL - causing breakeven/trailing to trigger before the
      // position was actually that profitable.
      double profitPts = (m_isBuy ? (bid - openPx) : (openPx - ask)) / g_pt;

      if(InpEnableBreakEven && !m_beDone && profitPts >= InpBreakEvenPts)
        {
         m_beDone = true;
         PrintFormat("[Trail %I64u #%I64u] BREAKEVEN stage reached | profit=%.1f pts", m_magic, m_ticket, profitPts);
        }
      bool beGateOpen = !InpEnableBreakEven || m_beDone;
      if(InpEnableTrailing && beGateOpen && !m_trailActive && profitPts >= InpTrailActivatePts)
        {
         m_trailActive = true;
         PrintFormat("[Trail %I64u #%I64u] TRAIL ACTIVE | profit=%.1f pts", m_magic, m_ticket, profitPts);
        }
      if(!m_beDone && !m_trailActive) return true;

      double candidateSL;
      string reason;
      if(m_trailActive)
        {
         candidateSL = NormalizeToTick(m_isBuy ? bid - PtsToPrice(InpTrailDist) : ask + PtsToPrice(InpTrailDist));
         reason = "TRAIL";
        }
      else
        {
         candidateSL = NormalizeToTick(openPx);
         reason = "BREAKEVEN";
        }

      // Never move backwards; never on the wrong side of the executable price.
      if(curSL > 0 && (m_isBuy ? candidateSL <= curSL : candidateSL >= curSL)) return true;
      if(m_isBuy ? candidateSL >= bid : candidateSL <= ask) return true;

      // Broker minimum stop distance: trail at the closest allowed level.
      long stopsLvl = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
      if(stopsLvl > 0)
        {
         double minAllowed = NormalizeToTick(m_isBuy ? bid - stopsLvl * g_pt : ask + stopsLvl * g_pt);
         if(m_isBuy ? candidateSL > minAllowed : candidateSL < minAllowed)
           {
            candidateSL = minAllowed;
            if(curSL > 0 && (m_isBuy ? candidateSL <= curSL : candidateSL >= curSL)) return true;
           }
        }

      // Broker freeze level: SL/TP cannot be modified while price is this close to them.
      long frz = SymbolInfoInteger(g_sym, SYMBOL_TRADE_FREEZE_LEVEL);
      if(frz > 0)
        {
         double fd = frz * g_pt;
         bool slFrozen = curSL > 0 && (m_isBuy ? (bid - curSL) <= fd : (curSL - ask) <= fd);
         bool tpFrozen = curTP > 0 && (m_isBuy ? (curTP - bid) <= fd : (ask - curTP) <= fd);
         if(slFrozen || tpFrozen)
           {
            if(InpDebug) PrintFormat("[Trail %I64u #%I64u] %s skipped: FREEZE_LEVEL_VIOLATION (%d pts)", m_magic, m_ticket, reason, (int)frz);
            return true;
           }
        }

      if(m_pendingModify && (GetTickCount() - m_pendingSentMs) < MODIFY_TIMEOUT_MS) return true;

      m_pendingModify = true;
      m_pendingSL     = candidateSL;
      m_pendingReason = reason;
      m_pendingSentMs = GetTickCount();
      if(!m_atrade.PositionModify(m_ticket, candidateSL, curTP))
        {
         PrintFormat("[Trail %I64u #%I64u] SL MODIFY SEND FAILED (%s) rc=%u %s target=%.5f",
                     m_magic, m_ticket, reason, m_atrade.ResultRetcode(), m_atrade.ResultRetcodeDescription(), candidateSL);
         m_pendingModify = false;
        }
      else if(InpDebug)
         PrintFormat("[Trail %I64u #%I64u] SL MODIFY SENT (%s) %.5f -> %.5f | profit=%.1f pts",
                     m_magic, m_ticket, reason, curSL, candidateSL, profitPts);
      return true;
     }
  };

//+------------------------------------------------------------------+
//|  SETUP LEDGER + EXECUTION: CModule (one per PDH / London / 4H)   |
//|                                                                  |
//|  Ledger state per side for the current period:                   |
//|    NONE    - no order of this period                             |
//|    PENDING - a live pending order placed this period             |
//|    FILLED  - an order placed this period was filled (= USED)     |
//|    CLOSED  - an order placed this period ended unfilled          |
//|  Straddle rule: the set is placed at most once per period         |
//|  (any side != NONE). Confirmation rule: a side trades at most     |
//|  once per period (FILLED).                                        |
//|  Rebuilt at init and every period change from live orders and     |
//|  order history (only orders whose SETUP time is inside the        |
//|  period count, so a previous period's leg never blocks a new      |
//|  one). Live pendings from an older period are deleted.            |
//+------------------------------------------------------------------+
enum ESetupState { SETUP_NONE = 0, SETUP_PENDING = 1, SETUP_FILLED = 2, SETUP_CLOSED = 3 };

string SetupStateText(ESetupState s)
  {
   switch(s)
     {
      case SETUP_PENDING: return "PENDING";
      case SETUP_FILLED:  return "FILLED";
      case SETUP_CLOSED:  return "CLOSED_UNFILLED";
      default:            return "NONE";
     }
  }

class CModule
  {
private:
   CTrade      m_trade;
   CTrailStop  m_trailBuy;
   CTrailStop  m_trailSell;
   ulong       m_magic;
   string      m_name;
   datetime    m_period;
   bool        m_ledgerOk;
   ESetupState m_state[2];
   ulong       m_orderTkt[2];
   ulong       m_flush[];
   bool        m_flushFailLogged;
   datetime    m_lastFlatten;
   datetime    m_backoffUntil;
   EReason     m_lastReason;
   bool        m_bothLive;

   CTrailStop *Trail(int side) { return (side == SIDE_BUY) ? GetPointer(m_trailBuy) : GetPointer(m_trailSell); }

   // Prints a NO TRADE reason only when it changes (no per-tick flooding).
   void Diag(EReason r, string detail)
     {
      if(r == m_lastReason) return;
      m_lastReason = r;
      PrintFormat("[%s] NO TRADE | reason=%s | %s", m_name, ReasonText(r), detail);
     }

   void QueueFlush(ulong t)
     {
      for(int i = 0; i < ArraySize(m_flush); i++)
         if(m_flush[i] == t) return;
      int n = ArraySize(m_flush);
      ArrayResize(m_flush, n + 1);
      m_flush[n] = t;
     }

   // Deletes queued pendings; a rejected delete (e.g. market closed at
   // rollover) stays queued and is retried every tick. New entries wait
   // until the queue is empty.
   void ProcessFlush()
     {
      for(int i = ArraySize(m_flush) - 1; i >= 0; i--)
        {
         ulong t = m_flush[i];
         bool gone = !OrderSelect(t);
         if(!gone)
           {
            if(m_trade.OrderDelete(t))
              {
               PrintFormat("[%s] Pending #%I64u deleted", m_name, t);
               gone = true;
              }
            else if(!m_flushFailLogged)
              {
               PrintFormat("[%s] Pending #%I64u delete FAILED rc=%u %s - retrying every tick",
                           m_name, t, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
               m_flushFailLogged = true;
              }
           }
         if(gone) ArrayRemove(m_flush, i, 1);
        }
      if(ArraySize(m_flush) == 0) m_flushFailLogged = false;
     }

   void QueueAllPendings()
     {
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong t = OrderGetTicket(i);
         if(t > 0 && SelectedOrderIsOurs(m_magic)) QueueFlush(t);
        }
     }

   bool RebuildLedger(datetime period)
     {
      m_period = period;
      for(int s = 0; s < 2; s++) { m_state[s] = SETUP_NONE; m_orderTkt[s] = 0; }
      m_backoffUntil = 0;

      // 1) Live pending orders: this period's become PENDING, older ones are stale.
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0 || !SelectedOrderIsOurs(m_magic)) continue;
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_STOP && type != ORDER_TYPE_SELL_STOP) continue;
         int side = (type == ORDER_TYPE_BUY_STOP) ? SIDE_BUY : SIDE_SELL;
         datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
         if(setup >= period && m_state[side] == SETUP_NONE)
           {
            m_state[side]    = SETUP_PENDING;
            m_orderTkt[side] = t;
            PrintFormat("[%s] RECOVERED live %s pending #%I64u (placed %s)", m_name, SideName(side), t,
                        TimeToString(setup, TIME_DATE | TIME_MINUTES));
           }
         else
           {
            QueueFlush(t);
            PrintFormat("[%s] Pending #%I64u placed %s belongs to an older period - deleting", m_name, t,
                        TimeToString(setup, TIME_DATE | TIME_MINUTES));
           }
        }

      // 2) Order history of this period: which sides were placed / filled.
      if(!HistorySelect(period, TimeCurrent() + 60))
        {
         m_ledgerOk = false;
         Diag(R_HISTORY_UNAVAILABLE, "HistorySelect failed - no entries until history loads");
         return false;
        }
      int n = HistoryOrdersTotal();
      for(int i = 0; i < n; i++)
        {
         ulong t = HistoryOrderGetTicket(i);
         if(t == 0) continue;
         if(HistoryOrderGetString(t, ORDER_SYMBOL) != g_sym) continue;
         if((ulong)HistoryOrderGetInteger(t, ORDER_MAGIC) != m_magic) continue;
         if((datetime)HistoryOrderGetInteger(t, ORDER_TIME_SETUP) < period) continue;
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(t, ORDER_TYPE);
         int side;
         if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
            side = (type == ORDER_TYPE_BUY_STOP) ? SIDE_BUY : SIDE_SELL;
         else if(type == ORDER_TYPE_BUY || type == ORDER_TYPE_SELL)
           {
            // Market orders count only if they OPENED a position (position id ==
            // order ticket); closing orders (SL/TP/flatten) are ignored.
            if((ulong)HistoryOrderGetInteger(t, ORDER_POSITION_ID) != t) continue;
            side = (type == ORDER_TYPE_BUY) ? SIDE_BUY : SIDE_SELL;
           }
         else continue;
         ENUM_ORDER_STATE st = (ENUM_ORDER_STATE)HistoryOrderGetInteger(t, ORDER_STATE);
         if(st == ORDER_STATE_FILLED || st == ORDER_STATE_PARTIAL)
            m_state[side] = SETUP_FILLED;
         else if((st == ORDER_STATE_CANCELED || st == ORDER_STATE_EXPIRED) && m_state[side] == SETUP_NONE)
            m_state[side] = SETUP_CLOSED;
        }
      m_ledgerOk   = true;
      m_lastReason = R_NONE;
      PrintFormat("[%s] PERIOD %s | ledger BUY=%s SELL=%s%s", m_name, TimeToString(period, TIME_DATE | TIME_MINUTES),
                  SetupStateText(m_state[SIDE_BUY]), SetupStateText(m_state[SIDE_SELL]),
                  SetStarted() ? " (setup already used this period - will not re-place)" : "");
      return true;
     }

   // A tracked pending that is no longer live has either filled or ended.
   void SyncLedger()
     {
      for(int s = 0; s < 2; s++)
        {
         if(m_state[s] != SETUP_PENDING) continue;
         ulong t = m_orderTkt[s];
         if(t == 0 || OrderSelect(t)) continue;
         if(!HistoryOrderSelect(t)) continue;   // not in history yet - check next tick
         ENUM_ORDER_STATE st = (ENUM_ORDER_STATE)HistoryOrderGetInteger(t, ORDER_STATE);
         m_state[s]    = (st == ORDER_STATE_FILLED || st == ORDER_STATE_PARTIAL) ? SETUP_FILLED : SETUP_CLOSED;
         m_orderTkt[s] = 0;
         PrintFormat("[%s] %s pending #%I64u -> %s", m_name, SideName(s), t, SetupStateText(m_state[s]));
        }
     }

   // Preconditions shared by straddle and confirmed entries.
   bool EntryGates(EReason &r, string &d)
     {
      if(!g_risk.TradingAllowed())      { r = R_RISK_HALT;        d = "account guard halted trading"; return false; }
      if(InBlackout())                  { r = R_BLACKOUT;         d = "inside the daily-open blackout window"; return false; }
      if(ArraySize(m_flush) > 0)        { r = R_FLUSH_PENDING;    d = StringFormat("%d old pending(s) still being deleted", ArraySize(m_flush)); return false; }
      if(HasOpenPosition())             { r = R_POSITION_OPEN;    d = "module already has an open position - waiting for it to close"; return false; }
      if(CountPendings(m_magic) > 0)    { r = R_DUPLICATE_ORDERS; d = "untracked live pending order(s) with this magic (another instance?)"; return false; }
      if(TimeCurrent() < m_backoffUntil)
                                        { r = R_BROKER_BACKOFF;   d = "broker rejected the last attempt - retrying in 60s"; return false; }
      r = CheckEnvironment(d);
      return r == R_OK;
     }

   // The single order-sending path (pending stop or market), with retry.
   EReason SendEntry(int side, bool isPending, double entry, double lot, double sl, double tp, string tag,
                     ulong &orderTkt, string &detail)
     {
      bool isBuy = (side == SIDE_BUY);
      datetime expiry = 0;
      ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
      if(isPending)
        {
         expiry = NextBlackoutStart();
         bool canExpire = (SymbolInfoInteger(g_sym, SYMBOL_EXPIRATION_MODE) & SYMBOL_EXPIRATION_SPECIFIED) != 0;
         if(expiry > 0 && canExpire && expiry - TimeCurrent() >= 60) tt = ORDER_TIME_SPECIFIED;
         else expiry = 0;
        }
      double slDist = MathAbs(entry - sl);
      double tpDist = (tp > 0) ? MathAbs(tp - entry) : 0;

      for(int attempt = 1; attempt <= RETRY_MAX + 1; attempt++)
        {
         bool sent;
         double useSL = sl, useTP = tp;
         if(isPending)
            sent = isBuy ? m_trade.BuyStop(lot, entry, g_sym, sl, tp, tt, expiry, tag)
                         : m_trade.SellStop(lot, entry, g_sym, sl, tp, tt, expiry, tag);
         else
           {
            // Market: SL/TP keep their distances from the price at send time.
            double px = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK) : SymbolInfoDouble(g_sym, SYMBOL_BID);
            useSL = NormalizeToTick(isBuy ? px - slDist : px + slDist);
            useTP = (tp > 0) ? NormalizeToTick(isBuy ? px + tpDist : px - tpDist) : 0.0;
            sent  = isBuy ? m_trade.Buy(lot, g_sym, 0.0, useSL, useTP, tag)
                          : m_trade.Sell(lot, g_sym, 0.0, useSL, useTP, tag);
           }
         uint rc = m_trade.ResultRetcode();
         bool ok = sent && (isPending ? (rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE)
                                      : (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL));
         if(ok)
           {
            orderTkt = m_trade.ResultOrder();
            detail = StringFormat("order #%I64u lot=%.2f SL=%.5f TP=%.5f (attempt %d)", orderTkt, lot, useSL, useTP, attempt);
            return R_OK;
           }
         if(IsTransientRetcode(rc) && attempt <= RETRY_MAX)
           {
            PrintFormat("[%s] %s %s transient rc=%u %s - retry %d/%d", m_name, SideName(side), isPending ? "STOP" : "MARKET",
                        rc, m_trade.ResultRetcodeDescription(), attempt, RETRY_MAX);
            if(!g_isTester) Sleep(RETRY_WAIT_MS);
            continue;
           }
         detail = StringFormat("rc=%u %s", rc, m_trade.ResultRetcodeDescription());
         m_backoffUntil = TimeCurrent() + 60;
         return R_BROKER_REJECTED;
        }
      detail = "retries exhausted";
      m_backoffUntil = TimeCurrent() + 60;
      return R_BROKER_REJECTED;
     }

   void FillSpreadCheck()
     {
      double spreadPts = (SymbolInfoDouble(g_sym, SYMBOL_ASK) - SymbolInfoDouble(g_sym, SYMBOL_BID)) / g_pt;
      if(InpMaxSpreadPts <= 0 || spreadPts <= InpMaxSpreadPts) return;
      PrintFormat("[%s] FILL-SPREAD ALERT: filled at spread %.0f pts > max %d (no action taken)", m_name, spreadPts, InpMaxSpreadPts);
      if(InpEnablePush && !g_isTester)
         SendNotification(StringFormat("%s %s filled in wide spread %.0f pts", g_sym, m_name, spreadPts));
     }

public:
   CModule() : m_magic(0), m_name(""), m_period(0), m_ledgerOk(false), m_flushFailLogged(false),
               m_lastFlatten(0), m_backoffUntil(0), m_lastReason(R_NONE), m_bothLive(false)
     {
      for(int s = 0; s < 2; s++) { m_state[s] = SETUP_NONE; m_orderTkt[s] = 0; }
     }

   void Init(ulong magic, string name)
     {
      m_magic = magic; m_name = name;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetMarginMode();
      m_trade.SetTypeFillingBySymbol(g_sym);
      m_trade.SetDeviationInPoints(DEVIATION_PTS);
      m_trailBuy.Attach(magic);
      m_trailSell.Attach(magic);
     }

   string Name() const             { return m_name; }
   bool   HasOpenPosition()        { return CountPositions(m_magic) > 0; }
   bool   SetStarted()             { return m_state[SIDE_BUY] != SETUP_NONE || m_state[SIDE_SELL] != SETUP_NONE; }
   bool   IsFilled(int side)       { return m_state[side] == SETUP_FILLED; }
   bool   AnyFilled()              { return IsFilled(SIDE_BUY) || IsFilled(SIDE_SELL); }

   // Restart recovery: adopt live positions, rebuild the ledger.
   void Recover(datetime period)
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !SelectedPositionIsOurs(m_magic)) continue;
         bool buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         CTrailStop *tr = Trail(buy ? SIDE_BUY : SIDE_SELL);
         if(!tr.IsTracking())
            tr.Track(t, buy, PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL));
        }
      RebuildLedger(period);
      ProcessFlush();
     }

   // New D1 / H4 period: older pendings are deleted, ledger starts fresh.
   void BeginPeriod(datetime period)
     {
      RebuildLedger(period);
      ProcessFlush();
     }

   // Per tick, before entries: deletes, ledger transitions, blackout.
   void Housekeeping()
     {
      ProcessFlush();
      if(!m_ledgerOk) RebuildLedger(m_period);
      SyncLedger();
      if(InBlackout())
        {
         if(CountPendings(m_magic) > 0)
           {
            QueueAllPendings();
            PrintFormat("[%s] Blackout: deleting pending orders", m_name);
            ProcessFlush();
           }
         if(InpBlackoutFlatten && HasOpenPosition() && TimeCurrent() - m_lastFlatten >= FLATTEN_THROTTLE_SEC)
           {
            m_lastFlatten = TimeCurrent();
            CloseAllFor(m_trade, m_magic, true, false, m_name + " blackout flatten");
           }
        }
     }

   // Pending BUY STOP above the high + SELL STOP below the low, once per period.
   void PlaceStraddle(double high, double low)
     {
      if(!m_ledgerOk || SetStarted()) return;
      if(high <= 0 || low <= 0 || high <= low)
        { Diag(R_INVALID_LEVELS, StringFormat("H=%.5f L=%.5f", high, low)); return; }
      EReason r;
      string  d;
      if(!EntryGates(r, d)) { Diag(r, d); return; }

      double slDist = PtsToPrice(InpSL_Pts);
      double tpDist = PtsToPrice(InpTP_Pts);
      // Entry padding (moves the entry level, not a spread filter):
      //  - spread buffer: live spread x multiplier (optional)
      //  - tester-only simulated spread (never applies live)
      double buf = 0.0;
      if(InpEnableSpreadBuffer)
         buf += (SymbolInfoDouble(g_sym, SYMBOL_ASK) - SymbolInfoDouble(g_sym, SYMBOL_BID)) * InpSpreadBufferMult;
      if(g_isTester && InpSimSpreadTester && InpSimSpreadPts > 0)
         buf += PtsToPrice(InpSimSpreadPts);

      int     placed = 0;
      EReason first  = R_NONE;
      string  fails  = "";
      for(int side = 0; side < 2; side++)
        {
         if(!DirEnabled(side)) continue;
         bool   isBuy = (side == SIDE_BUY);
         double entry = NormalizeToTick(isBuy ? high + buf : low - buf);
         double sl    = NormalizeToTick(isBuy ? entry - slDist : entry + slDist);
         double tp    = InpUseTP ? NormalizeToTick(isBuy ? entry + tpDist : entry - tpDist) : 0.0;
         double lot   = 0;
         ulong  tkt   = 0;
         string ld    = "";
         EReason lr   = SideAllowedByBroker(side) ? R_OK : R_SYMBOL_TRADE_DISABLED;
         if(lr != R_OK) ld = "broker trade mode forbids this side";
         if(lr == R_OK) lr = CheckStops(isBuy, true, entry, sl, tp, ld);
         if(lr == R_OK) lr = CalcLot(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, entry, sl, lot, ld);
         string lotInfo = ld;
         if(lr == R_OK) lr = SendEntry(side, true, entry, lot, sl, tp, m_name + (isBuy ? "_B" : "_S"), tkt, ld);
         if(lr == R_OK)
           {
            m_state[side]    = SETUP_PENDING;
            m_orderTkt[side] = tkt;
            placed++;
            PrintFormat("[%s] TRADE PLACED | %s STOP entry=%.5f | %s | risk %s", m_name, SideName(side), entry, ld, lotInfo);
           }
         else
           {
            if(first == R_NONE) first = lr;
            fails += StringFormat("%s: %s (%s) ", SideName(side), ReasonText(lr), ld);
           }
        }

      if(placed > 0)
        {
         m_lastReason = R_NONE;
         PrintFormat("[%s] SETUP PLACED for period %s | H=%.5f L=%.5f | pad=%.5f", m_name,
                     TimeToString(m_period, TIME_DATE | TIME_MINUTES), high, low, buf);
         if(fails != "")
            PrintFormat("[%s] Leg NOT placed (set counts as placed; not retried this period): %s", m_name, fails);
        }
      else if(first != R_NONE)
         Diag(first, fails);
     }

   // Single-side MARKET entry after a confirmation fired.
   bool ConfirmedEntry(int side, double level)
     {
      bool   isBuy = (side == SIDE_BUY);
      EReason r;
      string d = "";
      if(!DirEnabled(side))                r = R_DIRECTION_DISABLED;
      else if(!m_ledgerOk)                 r = R_HISTORY_UNAVAILABLE;
      else if(IsFilled(side) || (InpConfirmOneTradePerSet && AnyFilled())) r = R_ALREADY_TRADED;
      else if(!EntryGates(r, d))           { }
      else if(!SideAllowedByBroker(side))  r = R_SYMBOL_TRADE_DISABLED;
      else
        {
         double price = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK) : SymbolInfoDouble(g_sym, SYMBOL_BID);
         double sl    = NormalizeToTick(isBuy ? price - PtsToPrice(InpSL_Pts) : price + PtsToPrice(InpSL_Pts));
         double tp    = InpUseTP ? NormalizeToTick(isBuy ? price + PtsToPrice(InpTP_Pts) : price - PtsToPrice(InpTP_Pts)) : 0.0;
         double lot   = 0;
         ulong  tkt   = 0;
         r = CheckStops(isBuy, false, price, sl, tp, d);
         if(r == R_OK) r = CalcLot(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, NormalizeToTick(price), sl, lot, d);
         string lotInfo = d;
         if(r == R_OK) r = SendEntry(side, false, price, lot, sl, tp, m_name + (isBuy ? "_CB" : "_CS"), tkt, d);
         if(r == R_OK)
           {
            m_state[side] = SETUP_FILLED;
            m_lastReason  = R_NONE;
            PrintFormat("[%s] TRADE TAKEN | CONFIRMED %s market | level=%.5f | %s | risk %s",
                        m_name, SideName(side), level, d, lotInfo);
            return true;
           }
        }
      PrintFormat("[%s] NO TRADE | CONFIRMED %s | reason=%s | %s", m_name, SideName(side), ReasonText(r), d);
      return false;
     }

   // Per tick, after entries: bind each position to its tracker, trail, draw.
   void ManagePositions()
     {
      bool sawBuy = false, sawSell = false;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0 || !SelectedPositionIsOurs(m_magic)) continue;
         bool buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         if(buy) sawBuy = true; else sawSell = true;
         CTrailStop *tr = Trail(buy ? SIDE_BUY : SIDE_SELL);
         if(!tr.IsTracking())
           {
            PrintFormat("[%s] %s leg OPEN -> position #%I64u", m_name, buy ? "BUY" : "SELL", t);
            tr.Track(t, buy, PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL));
            FillSpreadCheck();
           }
        }
      bool both = sawBuy && sawSell;
      if(both != m_bothLive)
        {
         m_bothLive = both;
         if(both) PrintFormat("[%s] BOTH legs live - each tracked independently", m_name);
        }
      for(int s = 0; s < 2; s++)
        {
         CTrailStop *tr = Trail(s);
         if(tr.IsTracking() && !tr.Update())
           {
            PrintFormat("[%s] %s position #%I64u closed", m_name, SideName(s), tr.Ticket());
            tr.Reset();
           }
        }
     }

   bool NotifyModifyResult(ulong ticket, bool success, uint retcode)
     {
      if(m_trailBuy.MatchesTicket(ticket))  { m_trailBuy.OnAsyncModifyResult(success, retcode);  return true; }
      if(m_trailSell.MatchesTicket(ticket)) { m_trailSell.OnAsyncModifyResult(success, retcode); return true; }
      return false;
     }
  };

//+------------------------------------------------------------------+
//|  CONFIRMATION: CConfirm (one per module)                         |
//|  When a candle of InpConfirmMinutes closes beyond the high (low), |
//|  enter at market in that direction on the next tick.              |
//|  Restart: the candle that closed before/while the EA was offline  |
//|  is never fired late. "Used" comes from the module's ledger.      |
//+------------------------------------------------------------------+
class CConfirm
  {
private:
   string   m_tag, m_hiName, m_loName;
   double   m_high, m_low;
   datetime m_key;          // level-set identity (period start); 0 = no levels
   datetime m_lastBar;      // open time of the last confirmation bar seen

   bool Blocked(CModule &mod, int side)
     {
      return mod.IsFilled(side) || (InpConfirmOneTradePerSet && mod.AnyFilled());
     }

   // Once per newly closed confirmation candle: if it closed beyond the high
   // (or low), enter at market in that direction.
   void RunCandleClose(CModule &mod)
     {
      datetime cur = iTime(g_sym, g_confirmTF, 0);
      if(cur <= 0 || cur == m_lastBar) return;
      bool firstLook = (m_lastBar == 0);
      m_lastBar = cur;
      if(firstLook) return;   // after (re)start: the last closed candle may be stale - never fire it late
      if(mod.HasOpenPosition()) return;

      double c = iClose(g_sym, g_confirmTF, 1);
      int side = (c > m_high) ? SIDE_BUY : (c < m_low) ? SIDE_SELL : -1;
      if(side < 0) return;
      if(Blocked(mod, side))
        {
         if(InpDebug) PrintFormat("[%s] %s: %s side already traded this period", m_tag, ReasonText(R_ALREADY_TRADED), SideName(side));
         return;
        }
      double level = (side == SIDE_BUY) ? m_high : m_low;
      PrintFormat("[%s] CONFIRMED %s: M%d candle closed %.5f beyond %s %.5f", m_tag, SideName(side),
                  InpConfirmMinutes, c, side == SIDE_BUY ? m_hiName : m_loName, level);
      mod.ConfirmedEntry(side, level);
     }

public:
   CConfirm() : m_tag(""), m_hiName("high"), m_loName("low"), m_high(0), m_low(0), m_key(0), m_lastBar(0) {}

   void Init(string tag, string hiName, string loName) { m_tag = tag; m_hiName = hiName; m_loName = loName; }

   void Clear() { m_key = 0; m_high = 0; m_low = 0; }

   // No-op unless the level set changed. The module ledger for this period
   // supplies the "already traded" state.
   void SetLevels(double hi, double lo, datetime key)
     {
      if(key == m_key && hi == m_high && lo == m_low) return;
      m_high = hi; m_low = lo; m_key = key;
      PrintFormat("[%s] Levels set | %s=%.5f %s=%.5f | waiting for an M%d close beyond a level",
                  m_tag, m_hiName, hi, m_loName, lo, InpConfirmMinutes);
     }

   void Run(CModule &mod)
     {
      if(m_key == 0 || m_high <= m_low) return;
      RunCandleClose(mod);
     }
  };

//+------------------------------------------------------------------+
//|  LEVEL DETECTION + ORCHESTRATION: CExpert                        |
//+------------------------------------------------------------------+
class CExpert
  {
private:
   CModule  m_pdh, m_ldn, m_h4;
   CConfirm m_cfPDH, m_cfLDN, m_cf4H;
   datetime m_dayStart, m_h4Start;
   double   m_pdHigh, m_pdLow;
   double   m_h4High, m_h4Low;
   int      m_ldnPhase;
   bool     m_ldnHasData;
   double   m_ldnHigh, m_ldnLow;

   // Previous COMPLETED D1 candle (static array is oldest-first: [1] = yesterday).
   bool LoadPDH()
     {
      MqlRates d1[3];
      if(CopyRates(g_sym, PERIOD_D1, 0, 3, d1) < 3) return false;
      if(!(d1[1].high > d1[1].low && d1[1].high > 0)) return false;
      m_pdHigh = d1[1].high; m_pdLow = d1[1].low;
      PrintFormat("[PDH/PDL] PDH=%.5f PDL=%.5f range=%.5f", m_pdHigh, m_pdLow, m_pdHigh - m_pdLow);
      return true;
     }

   // Previous COMPLETED H4 candle.
   bool LoadH4()
     {
      MqlRates h4[3];
      if(CopyRates(g_sym, PERIOD_H4, 0, 3, h4) < 3) return false;
      if(!(h4[1].high > h4[1].low && h4[1].high > 0)) return false;
      m_h4High = h4[1].high; m_h4Low = h4[1].low;
      PrintFormat("[4H] high=%.5f low=%.5f range=%.5f", m_h4High, m_h4Low, m_h4High - m_h4Low);
      DrawH4Levels(m_h4High, m_h4Low, h4[1].time);
      return true;
     }

   void ResetLondon() { m_ldnPhase = LDN_WAIT; m_ldnHasData = false; m_ldnHigh = 0; m_ldnLow = DBL_MAX; }

   // Restart: rebuild today's session range from M5 history (session is hour-aligned, so M5 gives the exact high/low).
   void ReconstructLondon()
     {
      ResetLondon();
      MqlRates m1[];
      int copied = CopyRates(g_sym, PERIOD_M5, m_dayStart, TimeCurrent(), m1);
      double hi = 0, lo = DBL_MAX;
      bool found = false;
      for(int i = 0; i < copied; i++)
        {
         if(m1[i].time < m_dayStart) continue;
         MqlDateTime dt;
         TimeToStruct(m1[i].time, dt);
         if(!InSession(dt.hour, g_ldn.startBroker, g_ldn.endBroker)) continue;
         hi = MathMax(hi, m1[i].high);
         lo = MathMin(lo, m1[i].low);
         found = true;
        }
      bool inNow = InSession(ServerHour(), g_ldn.startBroker, g_ldn.endBroker);
      if(found)
        {
         m_ldnHigh = hi; m_ldnLow = lo; m_ldnHasData = true;
         m_ldnPhase = inNow ? LDN_IN : LDN_DONE;
         PrintFormat("[London] Rebuilt from M5 history: H=%.5f L=%.5f | session %s", hi, lo, inNow ? "in progress" : "closed");
        }
      else
         m_ldnPhase = inNow ? LDN_IN : LDN_WAIT;
     }

   void UpdateLondon()
     {
      bool inSess = InSession(ServerHour(), g_ldn.startBroker, g_ldn.endBroker);
      if(inSess && m_ldnPhase != LDN_DONE)
        {
         double h = iHigh(g_sym, PERIOD_M5, 0);
         double l = iLow(g_sym, PERIOD_M5, 0);
         if(h > 0 && l > 0)
           {
            if(!m_ldnHasData) { m_ldnHigh = h; m_ldnLow = l; m_ldnHasData = true; }
            else { m_ldnHigh = MathMax(m_ldnHigh, h); m_ldnLow = MathMin(m_ldnLow, l); }
           }
         m_ldnPhase = LDN_IN;
        }
      else if(!inSess && m_ldnPhase == LDN_IN)
        {
         if(m_ldnHasData)
           {
            m_ldnPhase = LDN_DONE;
            PrintFormat("[London] Session closed | LSH=%.5f LSL=%.5f", m_ldnHigh, m_ldnLow);
            UpdateVisuals(m_pdHigh, m_pdLow, m_ldnHigh, m_ldnLow);
           }
         else
            m_ldnPhase = LDN_WAIT;
        }
     }

   void OnNewDay(datetime d)
     {
      m_dayStart = d;
      PrintFormat("[Day] NEW DAY %s", TimeToString(d, TIME_DATE));
      g_risk.OnNewDay();
      ApplyBrokerTimezone("new day");
      if(InpEnablePDH)    m_pdh.BeginPeriod(d);
      if(InpEnableLondon) m_ldn.BeginPeriod(d);
      ResetLondon();
      m_cfPDH.Clear();
      m_cfLDN.Clear();
      m_pdHigh = 0; m_pdLow = 0;
      if(InpEnablePDH) LoadPDH();
      UpdateVisuals(m_pdHigh, m_pdLow, 0, 0);
     }

   void OnNewH4(datetime h)
     {
      m_h4Start = h;
      if(!InpEnable4H) return;
      m_h4.BeginPeriod(h);   // previous candle's leftover leg is deleted here
      m_cf4H.Clear();
      m_h4High = 0; m_h4Low = 0;
      LoadH4();
     }

public:
   CExpert() : m_dayStart(0), m_h4Start(0), m_pdHigh(0), m_pdLow(0), m_h4High(0), m_h4Low(0),
               m_ldnPhase(LDN_WAIT), m_ldnHasData(false), m_ldnHigh(0), m_ldnLow(DBL_MAX) {}

   bool Init()
     {
      m_pdh.Init(g_magicPDH, "PDH");
      m_ldn.Init(g_magicLDN, "London");
      m_h4.Init(g_magic4H, "4H");
      m_cfPDH.Init("PDH-CONFIRM", "PDH", "PDL");
      m_cfLDN.Init("LDN-CONFIRM", "LSH", "LSL");
      m_cf4H.Init("4H-CONFIRM", "4H high", "4H low");

      m_dayStart = DayStartNow();
      m_h4Start  = H4StartNow();
      if(InpEnablePDH)    m_pdh.Recover(m_dayStart);
      if(InpEnableLondon) m_ldn.Recover(m_dayStart);
      if(InpEnable4H)     m_h4.Recover(m_h4Start);

      if(InpEnablePDH)    LoadPDH();
      if(InpEnable4H)     LoadH4();
      if(InpEnableLondon) ReconstructLondon();

      UpdateVisuals(m_pdHigh, m_pdLow, m_ldnHasData ? m_ldnHigh : 0, m_ldnHasData ? m_ldnLow : 0);
      return true;
     }

   void NotifyModifyResult(ulong ticket, bool success, uint retcode)
     {
      if(m_pdh.NotifyModifyResult(ticket, success, retcode)) return;
      if(m_ldn.NotifyModifyResult(ticket, success, retcode)) return;
      m_h4.NotifyModifyResult(ticket, success, retcode);
     }

   void OnTick()
     {
      g_risk.OnTick();

      //--- periods (single source: bar open times)
      datetime d = DayStartNow();
      if(d != m_dayStart) OnNewDay(d);
      datetime h = H4StartNow();
      if(h != m_h4Start) OnNewH4(h);

      //--- levels (retried only while missing)
      if(InpEnablePDH && m_pdHigh <= 0) LoadPDH();
      if(InpEnable4H  && m_h4High <= 0) LoadH4();
      if(InpEnableLondon) UpdateLondon();

      //--- housekeeping before entries
      if(InpEnablePDH)    m_pdh.Housekeeping();
      if(InpEnableLondon) m_ldn.Housekeeping();
      if(InpEnable4H)     m_h4.Housekeeping();

      //--- entries
      if(InpEnablePDH)
        {
         if(InpConfirmPDH)
           {
            if(m_pdHigh > 0) m_cfPDH.SetLevels(m_pdHigh, m_pdLow, m_dayStart);
            m_cfPDH.Run(m_pdh);
           }
         else
            m_pdh.PlaceStraddle(m_pdHigh, m_pdLow);
        }

      if(InpEnableLondon)
        {
         bool ready = (m_ldnPhase == LDN_DONE && m_ldnHasData && m_ldnHigh > m_ldnLow);
         if(InpConfirmLondon)
           {
            if(ready) m_cfLDN.SetLevels(m_ldnHigh, m_ldnLow, m_dayStart);
            else      m_cfLDN.Clear();
            m_cfLDN.Run(m_ldn);
           }
         else if(ready)
            m_ldn.PlaceStraddle(m_ldnHigh, m_ldnLow);
        }

      if(InpEnable4H)
        {
         if(InpConfirm4H)
           {
            if(m_h4High > 0) m_cf4H.SetLevels(m_h4High, m_h4Low, m_h4Start);
            m_cf4H.Run(m_h4);
           }
         else
            m_h4.PlaceStraddle(m_h4High, m_h4Low);
        }

      //--- position management
      if(InpEnablePDH)    m_pdh.ManagePositions();
      if(InpEnableLondon) m_ldn.ManagePositions();
      if(InpEnable4H)     m_h4.ManagePositions();

      UpdateTradeVisuals();
     }
  };

CExpert *g_expert = NULL;

//+------------------------------------------------------------------+
//|  CONFIGURATION VALIDATION                                        |
//+------------------------------------------------------------------+
bool ConfigFail(string why)
  {
   string msg = "[Config] INVALID INPUT - EA will not start: " + why;
   Print(msg);
   Alert(msg);
   return false;
  }

bool ValidateInputs()
  {
   if(!InpEnablePDH && !InpEnableLondon && !InpEnable4H) return ConfigFail("all three modules are disabled");
   if(InpAutoLot && (InpRiskPct <= 0 || InpRiskPct > 10)) return ConfigFail("InpRiskPct must be > 0 and <= 10");
   if(!InpAutoLot && InpFixedLot <= 0)                    return ConfigFail("InpFixedLot must be > 0");
   if(InpMaxRiskOverPct < 0 || InpMaxRiskOverPct > 100)   return ConfigFail("InpMaxRiskOverPct must be 0..100");
   if(InpSL_Pts <= 0)                                     return ConfigFail("InpSL_Pts must be > 0");
   if(InpUseTP && InpTP_Pts <= 0)                         return ConfigFail("InpTP_Pts must be > 0 when TP is used");
   if(InpEnableBreakEven && InpBreakEvenPts <= 0)         return ConfigFail("InpBreakEvenPts must be > 0");
   if(InpEnableTrailing && (InpTrailActivatePts <= 0 || InpTrailDist <= 0))
      return ConfigFail("InpTrailActivatePts and InpTrailDist must be > 0");
   if(InpLondonOpenUTC < 0 || InpLondonOpenUTC > 23 || InpLondonCloseUTC < 0 || InpLondonCloseUTC > 23)
      return ConfigFail("London hours must be 0..23");
   if(InpLondonOpenUTC == InpLondonCloseUTC)              return ConfigFail("London open and close hours are equal");
   if(InpBrokerUTCOffset < -12 || InpBrokerUTCOffset > 14) return ConfigFail("InpBrokerUTCOffset must be -12..14");
   if(InpBreakCloseHour < 0 || InpBreakCloseHour > 23 || InpBreakOpenHour < 0 || InpBreakOpenHour > 23 ||
      InpBreakCloseMin < 0 || InpBreakCloseMin > 59 || InpBreakOpenMin < 0 || InpBreakOpenMin > 59)
      return ConfigFail("blackout hours/minutes out of range");
   if(InpBlackoutBeforeMin < 0 || InpBlackoutBeforeMin > 720 || InpBlackoutAfterMin < 0 || InpBlackoutAfterMin > 720)
      return ConfigFail("blackout before/after minutes must be 0..720");
   if(InpMaxSpreadPts < 0)                                return ConfigFail("InpMaxSpreadPts must be >= 0");
   g_confirmTF = MinutesToTF(InpConfirmMinutes);
   if(UsesConfirmation() && g_confirmTF == PERIOD_CURRENT)
      return ConfigFail(StringFormat("InpConfirmMinutes=%d is not an MT5 candle size - use 2,3,4,5,6,10,12,15,20,30 or 60",
                                     InpConfirmMinutes));
   if(InpEnableRiskGov && (InpDailyLossPct <= 0 || InpDailyLossPct >= 100 || InpMaxDrawdownPct <= 0 || InpMaxDrawdownPct >= 100))
      return ConfigFail("risk governor limits must be between 0 and 100%");
   if(InpEnableRiskGov && InpGovHaltMode == GOV_PAUSE_DAYS && InpGovPauseDays < 1)
      return ConfigFail("InpGovPauseDays must be >= 1");
   if(InpMagicBase == 0 || InpMagicBase > ULONG_MAX - 3)  return ConfigFail("InpMagicBase must be > 0");
   if(InpEnableSpreadBuffer && InpSpreadBufferMult < 0)   return ConfigFail("InpSpreadBufferMult must be >= 0");
   if(InpSimSpreadTester && InpSimSpreadPts < 0)          return ConfigFail("InpSimSpreadPts must be >= 0");
   return true;
  }

void LogConfig()
  {
   string cf = StringFormat("CONFIRM M%d close", InpConfirmMinutes);
   PrintFormat("[Config] v6.03 %s | PDH=%s(%s) London=%s(%s) 4H=%s(%s) | direction=%s | one-trade-per-set=%s",
               g_sym,
               InpEnablePDH ? "ON" : "OFF",    InpConfirmPDH ? cf : "STRADDLE",
               InpEnableLondon ? "ON" : "OFF", InpConfirmLondon ? cf : "STRADDLE",
               InpEnable4H ? "ON" : "OFF",     InpConfirm4H ? cf : "STRADDLE",
               EnumToString(InpDirection), InpConfirmOneTradePerSet ? "ON" : "OFF");
   PrintFormat("[Config] Risk: %s | SL=%.0f TP=%s pts | BE=%s | Trail=%s",
               InpAutoLot ? StringFormat("%.2f%% per leg (max +%.1f%% over)", InpRiskPct, InpMaxRiskOverPct) : StringFormat("fixed %.2f lot", InpFixedLot),
               InpSL_Pts, InpUseTP ? DoubleToString(InpTP_Pts, 0) : "OFF",
               InpEnableBreakEven ? StringFormat("+%.0f pts", InpBreakEvenPts) : "OFF",
               InpEnableTrailing ? StringFormat("activate +%.0f, distance %.0f pts", InpTrailActivatePts, InpTrailDist) : "OFF");
   int bs, be;
   BlackoutWindow(bs, be);
   PrintFormat("[Config] Blackout=%s %02d:%02d-%02d:%02d server (flatten=%s) | max spread=%d pts | entry pad: buffer=%s sim(tester)=%s",
               InpEnableBlackout ? "ON" : "OFF", bs / 60, bs % 60, be / 60, be % 60, InpBlackoutFlatten ? "YES" : "NO",
               InpMaxSpreadPts,
               InpEnableSpreadBuffer ? StringFormat("x%.2f spread", InpSpreadBufferMult) : "OFF",
               (g_isTester && InpSimSpreadTester && InpSimSpreadPts > 0) ? StringFormat("%.0f pts", InpSimSpreadPts) : "OFF");
   PrintFormat("[Config] Magic PDH=%I64u London=%I64u 4H=%I64u | account guard=%s (daily %.1f%%, overall %.1f%%, %s)",
               g_magicPDH, g_magicLDN, g_magic4H, InpEnableRiskGov ? "ON" : "OFF", InpDailyLossPct, InpMaxDrawdownPct,
               EnumToString(InpGovHaltMode));
   if(!UsesConfirmation())
      Print("[Config] Note: confirmation settings are ignored (no module uses confirmation).");
   if(g_isTester && InpSimSpreadTester)
      Print("[Config] Note: simulated spread is ON - with 'real ticks' modelling this double-counts spread.");
  }

// Trades carrying this EA's comment tags but a magic we no longer use would
// silently become unmanaged after a magic change - warn loudly.
void WarnForeignMagic()
  {
   int n = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetTicket(i) == 0 || PositionGetString(POSITION_SYMBOL) != g_sym) continue;
      string c = PositionGetString(POSITION_COMMENT);
      if(!IsEAMagic((ulong)PositionGetInteger(POSITION_MAGIC)) &&
         (StringFind(c, "PDH_") == 0 || StringFind(c, "London_") == 0 || StringFind(c, "4H_") == 0)) n++;
     }
   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(OrderGetTicket(i) == 0 || OrderGetString(ORDER_SYMBOL) != g_sym) continue;
      string c = OrderGetString(ORDER_COMMENT);
      if(!IsEAMagic((ulong)OrderGetInteger(ORDER_MAGIC)) &&
         (StringFind(c, "PDH_") == 0 || StringFind(c, "London_") == 0 || StringFind(c, "4H_") == 0)) n++;
     }
   if(n > 0)
     {
      string msg = StringFormat("[Config] %d open trade(s)/order(s) on %s look like this EA's but use a different magic. "
                                "They will NOT be managed. Restore the previous InpMagicBase or manage them manually.", n, g_sym);
      Print(msg);
      Alert(msg);
     }
  }

//--- One instance per symbol + magic base (live only). Two charts running the
//    same magics would both manage - and try to place - the same setups.
string LockName() { return "EA_PDHLDN_LOCK_" + g_sym + "_" + (string)InpMagicBase; }

bool AcquireInstanceLock()
  {
   if(g_isTester) return true;
   string n  = LockName();
   double me = (double)ChartID();
   if(GlobalVariableCheck(n))
     {
      double owner = GlobalVariableGet(n);
      if(owner != me)
         for(long c = ChartFirst(); c >= 0; c = ChartNext(c))
            if((double)c == owner && c != ChartID())
              {
               string msg = StringFormat("[Config] DUPLICATE_SETUP: another chart already runs this EA on %s with magic base %I64u. "
                                         "This instance will NOT start.", g_sym, InpMagicBase);
               Print(msg);
               Alert(msg);
               return false;
              }
     }
   GlobalVariableTemp(n);
   GlobalVariableSet(n, me);
   return true;
  }

void ReleaseInstanceLock()
  {
   if(g_isTester) return;
   string n = LockName();
   if(GlobalVariableCheck(n) && GlobalVariableGet(n) == (double)ChartID()) GlobalVariableDel(n);
  }

//+------------------------------------------------------------------+
//|  EVENT HANDLERS                                                  |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (bool)MQLInfoInteger(MQL_TESTER);
   TesterHideIndicators(true);   // never draw indicators on the tester chart
   RemoveChartIndicators();      // remove any indicator lines already on the chart
   if(!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;
   if(!InitSymbol())     return INIT_PARAMETERS_INCORRECT;

   g_magicPDH = InpMagicBase + 1;
   g_magicLDN = InpMagicBase + 2;
   g_magic4H  = InpMagicBase + 3;
   if(!AcquireInstanceLock()) return INIT_FAILED;

   ApplyBrokerTimezone("init");
   if(InpEnableVisuals)
     {
      // MT5's own trade levels + trade history, and object descriptions for our labelled lines.
      ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS,  true);
      ChartSetInteger(0, CHART_SHOW_TRADE_HISTORY, true);
      ChartSetInteger(0, CHART_SHOW_OBJECT_DESCR,  true);
     }
   LogConfig();
   WarnForeignMagic();

   g_risk.Init();
   g_risk.LogState();

   g_expert = new CExpert();
   if(g_expert == NULL || !g_expert.Init())
     {
      if(g_expert != NULL) { delete g_expert; g_expert = NULL; }
      ReleaseInstanceLock();
      return INIT_FAILED;
     }
   Print("[Init] EA ready (v6.03). Chart timeframe does not matter - all reads use explicit timeframes.");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_risk.LogSummary();
   DeleteAllVisuals();
   ReleaseInstanceLock();
   if(g_expert != NULL) { delete g_expert; g_expert = NULL; }
  }

//+------------------------------------------------------------------+
//|  Removes every indicator from the chart (main window + subwindows)|
//|  so no high/low lines are drawn over the candles.                 |
//+------------------------------------------------------------------+
void RemoveChartIndicators()
  {
   int wins = (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL);
   for(int w = wins - 1; w >= 0; w--)
     {
      for(int i = ChartIndicatorsTotal(0, w) - 1; i >= 0; i--)
        {
         string nm = ChartIndicatorName(0, w, i);
         if(nm != "") ChartIndicatorDelete(0, w, nm);
        }
     }
   ChartRedraw();
  }

void OnTick()
  {
   static bool indCleaned = false;
   if(!indCleaned) { RemoveChartIndicators(); indCleaned = true; }   // tester template loads after OnInit
   if(g_expert != NULL) g_expert.OnTick();
  }

// Logging of fills/closes + routing of async SL-modify results.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult  &result)
  {
   if(trans.type == TRADE_TRANSACTION_REQUEST)
     {
      if(request.action == TRADE_ACTION_SLTP && g_expert != NULL)
        {
         bool ok = (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
         g_expert.NotifyModifyResult(request.position, ok, result.retcode);
        }
      return;
     }

   if(trans.type == TRADE_TRANSACTION_ORDER_ADD || trans.type == TRADE_TRANSACTION_ORDER_DELETE ||
      trans.type == TRADE_TRANSACTION_POSITION  || trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_visDirty = true;

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != g_sym) return;
   if(!HistoryDealSelect(trans.deal)) return;
   ulong magic = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(!IsEAMagic(magic)) return;
   DrawDealArrow(trans.deal);
   if(!HistoryDealSelect(trans.deal)) return;   // DrawDealArrow may change the history selection

   long   entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long   dtype  = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double price  = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double vol    = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   string dir    = (dtype == DEAL_TYPE_BUY) ? "BUY" : (dtype == DEAL_TYPE_SELL) ? "SELL" : "?";

   if(entry == DEAL_ENTRY_IN)
      PrintFormat("[EXEC] FILL  %s %.2f @ %.5f | magic=%I64u | deal=%I64u order=%I64u", dir, vol, price, magic, trans.deal, trans.order);
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      PrintFormat("[EXEC] CLOSE %s %.2f @ %.5f | profit=%.2f | magic=%I64u | deal=%I64u", dir, vol, price, profit, magic, trans.deal);
  }
//+------------------------------------------------------------------+