//+------------------------------------------------------------------+
//|                   XAUUSD_PDH_PDL_London.mq5                       |
//|  Full per-version changelog trimmed for file size - unchanged     |
//|  logic notes below still apply:                                   |
//|   v5.39 [PATTERN] New M1-only confirmation mode                    |
//|         (InpEnableCandlePatternConfirm): replaces the 5M-arm/      |
//|         1M-execute check with N consecutive same-color, strong-    |
//|         bodied (>= InpConfirmBodyPct% body) 1M candles beyond the  |
//|         level before firing. Off by default; 5M/1M path unchanged. |
//|   v5.36 [CONFIRM-ALL] The 5M-arm / 1M-execute confirmation entry     |
//|         (one trade per level, first-1M-candle check) is now a      |
//|         shared engine and also available for PDH/PDL and London    |
//|         (LSH/LSL): InpEnablePDHConfirmation / InpEnableLDNConfirmation.|
//|   v5.35 [ONEPERLEVEL] 4H-CONFIRM mode: only ONE trade per 4H high  |
//|         and ONE per 4H low. Once a confirmed trade fires on a     |
//|         level it is locked until the next 4H candle (previously   |
//|         it re-armed and re-entered after every stop/trail-out).   |
//|         Lock survives EA restart (rebuilt from deal history).     |
//|         (v5.35) [CONFIRMFIX] 1M confirmation now waits for the FIRST 1M      |
//|         candle AFTER the arming 5M close and checks that candle's |
//|         close (old code re-read the 5M's own last minute, so the  |
//|         1M step never confirmed anything).                        |
//|         (v5.35) [H4LINES] Previous 4H candle high/low are now drawn on the |
//|         chart (EA_H4H / EA_H4L, labelled) and updated each new    |
//|         4H candle. Uses the InpEnableVisuals toggle.              |
//|   v5.32 [BLACKOUTEXP] Pending legs now carry a broker-side expiry |
//|         at blackout start, as a backstop if our own cancel is     |
//|         rejected at rollover (closes the reopen gap-fill risk).   |
//|   v5.31 [RGFIX] Risk Governor breach-flatten now also covers the  |
//|         4H module (previously only PDH/London).                  |
//|         [TRAILSTOPFIX] Trailing SL clamps to the broker's min     |
//|         stop distance instead of silently failing every modify.   |
//|   v5.30 [SPREADFIX] Breakeven/trail activation now measures       |
//|         profit inclusive of live spread, matching chart-visible   |
//|         point moves instead of triggering late.                   |
//|   v5.17-5.29: rollover orphan-order fix, daily-open blackout       |
//|         window, risk governor, per-feature toggles, spread        |
//|         buffer, simulated tester spread, London self-heal.        |
//|   STRATEGY LOGIC (PDH/PDL levels, London LSH/LSL, SL/TP distances, |
//|   risk-% sizing, 3-stage trailing math) UNCHANGED since v4.00.     |
//+------------------------------------------------------------------+
#property copyright "XAUUSD PDH/PDL + London + 4H EA v5.39"
#property version   "5.39"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//|  INPUTS                                                          |
//+------------------------------------------------------------------+
input group "=== EA Identity ==="
input ulong  InpMagicPDH        = 100001;  // Magic: PDH/PDL orders
input ulong  InpMagicLDN        = 100002;  // Magic: London orders
input ulong  InpMagic4H         = 100003;  // Magic: 4H candle high/low orders
input bool   InpDebug           = true;    // Debug journal prints

input group "=== Feature Toggles (v5.10) ==="
input bool   InpEnablePDH        = true;   // Run the PDH/PDL set
input bool   InpEnableLondon     = true;   // Run the London session set (master switch)
input bool   InpEnable4H         = true;   // Run the 4H candle high/low set (one straddle per 4H candle from previous candle's high/low)
input bool   InpEnableTrailing   = true;   // Enable 3-stage trailing stop
input bool   InpEnableRecovery   = true;   // Reconstruct broker state on init
input bool   InpEnableRetry      = true;   // Retry transient broker errors
input bool   InpEnableSuffixSearch = true; // Scan broker symbols for XAUUSD variant
input bool   InpEnableVisuals    = true;   // Draw chart lines/labels

input group "=== Extended Toggles (v5.13) ==="
input bool   InpEnableBreakEven  = true;   // Stage-1 breakeven move (stages 2/3 still governed by Trailing toggle)
input bool   InpEnableTP         = true;   // Attach TP to orders (false = SL only, trail/SL handles exits)
input bool   InpEnableBuyLegs    = true;   // Place BUY STOP legs
input bool   InpEnableSellLegs   = true;   // Place SELL STOP legs
input bool   InpEnablePush       = true;   // Push notifications to phone (MetaQuotes ID required)
input bool   InpEnableDayFlush   = true;   // Cancel remaining pendings at day rollover (false = leave them GTC)
input bool   InpEnableLdnRebuild = true;   // Reconstruct London range from M1 history on restart
input bool   InpEnableRiskDevChk = true;   // Reject lot if actual risk deviates >InpMaxRiskDeviationPct from target
input bool   InpEnableDupScan    = true;   // Broker-side duplicate scan before placement
input bool   InpEnableGVPersist  = true;   // Persist day marker/anchors to GlobalVariables (false = clean slate each init)

input group "=== DANGER ZONE - NOT RECOMMENDED TO CHANGE ==="
input bool   InpEnableStopLevelChk = true; // Stop-level/tick validation. OFF re-creates 'invalid price' live failures
input bool   InpEnableSessionChk   = true; // Market-session defer. OFF re-creates 'market closed' failures
input bool   InpEnableHardStops    = true; // Hard broker-side SL(/TP) on orders. OFF = naked orders. NEVER recommended

input group "=== Risk ==="
input bool   InpAutoLot         = true;    // Auto lot from risk % (OrderCalcProfit based) - DEFAULT ON
input double InpRiskPct         = 1.0;     // Risk % per trade (per leg) - DEFAULT 1%
input double InpFixedLot        = 0.10;    // Fixed lot (AutoLot=false / calc fallback; clamped to broker limits)
input double InpMaxRiskDeviationPct = 5.0; // Max allowed deviation between target & actual risk

input group "=== SL / TP (live default: SL 120 / TP 240) ==="
input double InpSL_Pts          = 120.0;   // Stop Loss in points
input double InpTP_Pts          = 240.0;   // Take Profit in points

input group "=== Trailing Stop (3-stage) ==="
input double InpBreakEvenPts     = 20.0;   // Stage 1: points profit to move SL to breakeven
input double InpTrailActivatePts = 20.0;   // Stage 2: points profit to activate trailing
input double InpTrailDist        = 10.0;   // Stage 3: points to keep SL behind current price

input group "=== London Session ==="
input int    InpLondonOpenUTC   = 8;       // London session open (UTC hour, 0-23)
input int    InpLondonCloseUTC  = 16;      // London session close (UTC hour, 0-23)
input int    InpBrokerUTCOffset = 3;       // Broker server UTC offset (hours). Most Gold brokers use UTC+3 (EET)

input group "=== Reliability ==="
input string InpSymbolBase      = "XAUUSD"; // Base symbol name (prefix/suffix auto-detected)
input int    InpRetryMax        = 3;        // Max retries for TRANSIENT broker errors
input int    InpRetryWaitMs     = 400;      // Wait between transient retries (ms)
input int    InpMaxSpreadPts    = 500;      // Reject placement if spread exceeds this (points; 0=off)

input group "=== Confirmation Entry: 5M arm + 1M execute (MARKET order) ==="
input bool   InpEnable4HConfirmation = false;  // ON: 4H module waits for 5M arm + 1M execute (MARKET order) instead of the immediate pending straddle. OFF = original behavior, unchanged.
input bool   InpEnablePDHConfirmation = false; // ON: PDH/PDL module uses the same 5M arm + 1M execute confirmation instead of the pending straddle. OFF = original behavior.
input bool   InpEnableLDNConfirmation = false; // ON: London module (LSH/LSL, after the session closes) uses the same confirmation instead of the pending straddle. OFF = original behavior.
input bool   InpConfirmOneTradePerCandle = false; // OFF: one trade on the HIGH and one on the LOW per level set. ON: only ONE trade in total per level set (per 4H candle for 4H; per day for PDH and London).

input group "=== Candle Pattern Confirmation (M1-only, replaces 5M-arm/1M-execute) ==="
input bool   InpEnableCandlePatternConfirm = false; // ON: use the M1 consecutive-strong-candle pattern below instead of the 5M-arm/1M-execute logic. Only matters on modules where confirmation is already enabled above.
input int    InpConfirmCandleCount = 3;             // Number of consecutive same-color, strong-bodied 1M candles required (starting from the breakout candle) before firing the market order. Typical: 3-4.
input double InpConfirmBodyPct = 70.0;              // Minimum body size as a % of the candle's full range (high-low) for a candle to count as "strong". A candle with a bigger wick than this fails and resets the count.

enum ENUM_GOV_HALT_MODE
  {
   GOV_PERMANENT = 0,  // PERMANENT: breach halts forever (correct for LIVE)
   GOV_PAUSE_DAYS = 1, // PAUSE: resume after InpGovPauseDays days
   GOV_LOG_ONLY = 2    // LOG ONLY: record breach, keep trading (TESTER analysis)
  };

input group "=== Risk Governor (prop-firm limits) ==="
input bool   InpEnableRiskGov    = true;    // Master switch for the risk governor
input double InpDailyLossPct     = 2.5;     // Halt for the day at this % equity loss from daily anchor (firm hard limit 3%)
input double InpMaxDrawdownPct   = 8.5;     // Halt permanently at this % equity DD from high-water mark (firm hard limit 10%)
input bool   InpCloseAllOnBreach = true;    // On breach: close all positions+pendings (true) or just block new trades (false)
input ENUM_GOV_HALT_MODE InpGovHaltMode = GOV_PERMANENT; // Overall-DD halt behavior (keep PERMANENT for live!)
input int    InpGovPauseDays     = 5;       // Days to pause when HaltMode=PAUSE
input bool   InpGovResetOnInit   = false;   // LIVE: wipe persisted anchors/HWM at init (fresh baseline)

input group "=== Spread Buffer (v5.12) ==="
input bool   InpEnableSpreadBuffer = false; // Pad stop entries by (live spread x mult). OFF = original entries (default)
input double InpSpreadBufferMult   = 1.5;   // Entry padding = current spread x this multiple
input bool   InpFillSpreadAlert    = true;  // Log/alert when a position fills while spread > InpMaxSpreadPts (no action taken)

input group "=== Simulated Spread - BACKTEST ONLY (v5.20) ==="
input bool   InpSimSpreadTester    = true;  // Apply InpSimSpreadPts in Strategy Tester only. AUTO-DISABLED on live/demo.
input double InpSimSpreadPts        = 30.0;  // Spread (points) to simulate in backtest. Fills padded outward by this. 0=off.

input group "=== Daily-Open Blackout - avoids the daily reopen spike/gap fills ==="
input bool   InpEnableBlackout     = true;        // ON: nothing is exposed or opened inside the window
input int    InpBreakCloseHour     = 23;          // Daily market CLOSE - hour, SERVER time (0-23). Check Market Watch > XAUUSD > Specification > Trade sessions
input int    InpBreakCloseMin      = 0;           // Daily market CLOSE - minute (0-59)
input int    InpBreakOpenHour      = 1;           // Daily market REOPEN - hour, SERVER time (0-23)
input int    InpBreakOpenMin       = 0;           // Daily market REOPEN - minute (0-59)
input int    InpBlackoutBeforeMin  = 15;          // Minutes BEFORE the close: stop new orders, cancel pendings, flatten
input int    InpBlackoutAfterMin   = 15;          // Minutes AFTER the reopen: keep everything off
input bool   InpBlackoutFlatten    = true;        // Close open positions at window start (avoids gap-through-SL at the reopen)

//+------------------------------------------------------------------+
//|  SYMBOL PROPERTIES - resolved once (suffix/prefix-aware)         |
//+------------------------------------------------------------------+
string g_sym  = "";   // Resolved traded symbol (base +/- broker affix)
double g_pt   = 0;    // _Point value
int    g_dg   = 0;    // Digits
double g_tick = 0;    // [U3] SYMBOL_TRADE_TICK_SIZE - true price granularity

//+------------------------------------------------------------------+
//|  [U4] ROBUST SYMBOL RESOLUTION                                   |
//|  Matches the base ("XAUUSD") anywhere in a broker symbol name -   |
//|  prefix, suffix, or both. Chooses deterministically so we never   |
//|  accidentally trade a lookalike (e.g. XAUUSD.raw when .r exists): |
//|    1. exact base match wins outright                              |
//|    2. else a candidate already in Market Watch wins               |
//|    3. else the SHORTEST total name wins (fewest extra chars)      |
//|  Every candidate is logged. Falls back to _Symbol if nothing      |
//|  matches, so init still succeeds but never mis-trades silently.   |
//+------------------------------------------------------------------+
bool NameInMarketWatch(string name)
  {
   int total = SymbolsTotal(true); // selected (Market Watch) only
   for(int i = 0; i < total; i++)
      if(SymbolName(i, true) == name) return true;
   return false;
  }

string ResolveSymbol()
  {
   string base = InpSymbolBase;

   // Suffix search disabled -> use chart symbol if it contains base, else base.
   if(!InpEnableSuffixSearch)
     {
      if(StringFind(_Symbol, base) >= 0) return _Symbol;
      if(SymbolSelect(base, true))       return base;
      PrintFormat("[Symbol] SuffixSearch OFF and no direct match; using chart '%s'", _Symbol);
      return _Symbol;
     }

   // Gather every symbol whose name CONTAINS the base anywhere.
   string cands[];
   int    nc = 0;
   int    total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      if(StringFind(name, base) >= 0)
        {
         ArrayResize(cands, nc + 1);
         cands[nc++] = name;
        }
     }

   if(nc == 0)
     {
      PrintFormat("[Symbol] ERROR: no broker symbol contains '%s'. Falling back to chart '%s'.", base, _Symbol);
      return _Symbol;
     }

   if(nc > 1)
     {
      string list = "";
      for(int i = 0; i < nc; i++) list += (i ? ", " : "") + cands[i];
      PrintFormat("[Symbol] Multiple candidates: %s (override via InpSymbolBase if wrong)", list);
     }

   // 1) exact base match wins outright.
   for(int i = 0; i < nc; i++)
      if(cands[i] == base)
        {
         SymbolSelect(base, true);
         return base;
        }

   // 2) prefer a candidate already in Market Watch.
   string chosen = "";
   for(int i = 0; i < nc; i++)
      if(NameInMarketWatch(cands[i])) { chosen = cands[i]; break; }

   // 3) else the shortest total name.
   if(chosen == "")
     {
      chosen = cands[0];
      for(int i = 1; i < nc; i++)
         if(StringLen(cands[i]) < StringLen(chosen))
            chosen = cands[i];
     }

   SymbolSelect(chosen, true);
   return chosen;
  }

void CacheSymbol()
  {
   g_sym  = ResolveSymbol();
   g_pt   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   g_dg   = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   g_tick = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   if(g_tick <= 0) g_tick = g_pt; // safety

   PrintFormat("[Symbol] Resolved=%s (base=%s) | _Point=%.6f | Digits=%d | TickSize=%.6f",
               g_sym, InpSymbolBase, g_pt, g_dg, g_tick);
   PrintFormat("[Symbol] SL=%.0f pts = %.4f price | TP=%.0f pts = %.4f price",
               InpSL_Pts, InpSL_Pts * g_pt, InpTP_Pts, InpTP_Pts * g_pt);
   PrintFormat("[Symbol] BreakEven=%.0f pts | TrailActivate=%.0f pts | TrailDist=%.0f pts",
               InpBreakEvenPts, InpTrailActivatePts, InpTrailDist);
  }

// Convert N points to price distance
double PtsToPrice(double pts) { return pts * g_pt; }

//--- [U3] Normalize a price to the broker's TICK SIZE (not merely digits).
//    Some brokers use a tick size coarser than a single point; sending a
//    price off the tick grid triggers "invalid price". Round to nearest
//    tick, then to digits for clean display.
double NormalizeToTick(double price)
  {
   if(g_tick <= 0) return NormalizeDouble(price, g_dg);
   double snapped = MathRound(price / g_tick) * g_tick;
   return NormalizeDouble(snapped, g_dg);
  }

//+------------------------------------------------------------------+
//|  [U3] MARKET-SESSION CHECK                                       |
//|  True only when the symbol is currently tradable AND inside an    |
//|  open trade session. Used to DEFER (not cancel) around the        |
//|  midnight rollover / weekend close where placement would fail     |
//|  with "market closed".                                            |
//+------------------------------------------------------------------+
bool IsMarketOpenNow()
  {
   long tmode = SymbolInfoInteger(g_sym, SYMBOL_TRADE_MODE);
   if(tmode == SYMBOL_TRADE_MODE_DISABLED) return false;
   if(tmode == SYMBOL_TRADE_MODE_CLOSEONLY) return false;

   datetime now = TimeTradeServer();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   ENUM_DAY_OF_WEEK dow = (ENUM_DAY_OF_WEEK)dt.day_of_week;

   // Seconds since midnight (server time) for session comparison.
   int secOfDay = dt.hour*3600 + dt.min*60 + dt.sec;

   datetime from, to;
   for(int s = 0; ; s++)
     {
      if(!SymbolInfoSessionTrade(g_sym, dow, s, from, to))
         break; // no more sessions defined for this day
      // from/to are seconds-of-day as datetime offsets.
      int f = (int)from;
      int t = (int)to;
      if(secOfDay >= f && secOfDay < t)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|  [U3] STOP-LEVEL VALIDATION for a pending stop order             |
//|  Rejects (returns false) any leg whose entry/SL/TP violates the   |
//|  broker's minimum stop distance, logging the exact numbers.       |
//+------------------------------------------------------------------+
bool StopLevelsOK(bool isBuyStop, double entry, double sl, double tp, string ctx)
  {
   // [T-DANGER] Validation toggle: OFF re-creates 'invalid price' failures.
   if(!InpEnableStopLevelChk)
     {
      PrintFormat("[%s] *** DANGER: StopLevelChk OFF - skipping price validation ***", ctx);
      return true;
     }

   long stopsLvl  = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
   long freezeLvl = SymbolInfoInteger(g_sym, SYMBOL_TRADE_FREEZE_LEVEL);
   double minDist = stopsLvl * g_pt;

   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);

   // A BUY STOP entry must sit at least stopsLvl above ASK; SELL STOP below BID.
   double refEntry = isBuyStop ? ask : bid;
   double entryGap = isBuyStop ? (entry - refEntry) : (refEntry - entry);
   if(minDist > 0 && entryGap < minDist)
     {
      PrintFormat("[%s] STOP-LEVEL FAIL: entry gap %.5f < min %.5f (stopsLvl=%d pts) | entry=%.5f ref=%.5f",
                  ctx, entryGap, minDist, (int)stopsLvl, entry, refEntry);
      return false;
     }

   // SL/TP must be at least stopsLvl away from the entry price.
   // Zeroed SL/TP (hard-stops or TP toggled off) are exempt from the distance check.
   double slGap = (sl > 0) ? MathAbs(entry - sl) : 0;
   double tpGap = (tp > 0) ? MathAbs(tp - entry) : 0;
   if(minDist > 0 && ((sl > 0 && slGap < minDist) || (tp > 0 && tpGap < minDist)))
     {
      PrintFormat("[%s] STOP-LEVEL FAIL: slGap=%.5f tpGap=%.5f < min %.5f (stopsLvl=%d pts)",
                  ctx, slGap, tpGap, minDist, (int)stopsLvl);
      return false;
     }

   if(freezeLvl > 0 && InpDebug)
      PrintFormat("[%s] freezeLvl=%d pts (informational)", ctx, (int)freezeLvl);

   return true;
  }

//+------------------------------------------------------------------+
//|  [Retry] BROKER ERROR CLASSIFICATION                             |
//+------------------------------------------------------------------+
bool IsTransientRetcode(uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_CHANGED:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_REJECT:
      case TRADE_RETCODE_TIMEOUT:
      case TRADE_RETCODE_CONNECTION:
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return true;
      default:
         return false;
     }
  }

//+------------------------------------------------------------------+
//|  PRE-TRADE ENVIRONMENT CHECKLIST                                 |
//+------------------------------------------------------------------+
bool ValidateTradeEnvironment(string ctx)
  {
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
     {
      PrintFormat("[Validate:%s] FAIL: terminal not connected", ctx);
      return false;
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
     {
      PrintFormat("[Validate:%s] FAIL: algo trading not allowed", ctx);
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
     {
      PrintFormat("[Validate:%s] FAIL: account trade not allowed", ctx);
      return false;
     }
   long tmode = SymbolInfoInteger(g_sym, SYMBOL_TRADE_MODE);
   if(tmode == SYMBOL_TRADE_MODE_DISABLED)
     {
      PrintFormat("[Validate:%s] FAIL: symbol %s trade disabled", ctx, g_sym);
      return false;
     }
   // [U3] Defer (not fail-loud) when the market session is closed.
   // [T-DANGER] SessionChk toggle: OFF re-creates 'market closed' failures.
   if(!InpEnableSessionChk)
      PrintFormat("[Validate:%s] *** DANGER: SessionChk OFF ***", ctx);
   else if(!IsMarketOpenNow())
     {
      PrintFormat("[Validate:%s] DEFER: market session closed for %s (will place when it reopens)", ctx, g_sym);
      return false;
     }
   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0 || ask < bid)
     {
      PrintFormat("[Validate:%s] FAIL: bad quotes bid=%.5f ask=%.5f", ctx, bid, ask);
      return false;
     }
   if(InpMaxSpreadPts > 0)
     {
      double spreadPts = (ask - bid) / g_pt;
      if(spreadPts > InpMaxSpreadPts)
        {
         PrintFormat("[Validate:%s] FAIL: spread %.0f pts exceeds max %d", ctx, spreadPts, InpMaxSpreadPts);
         return false;
        }
     }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) <= 0)
     {
      PrintFormat("[Validate:%s] FAIL: no free margin", ctx);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|  LONDON SESSION DETECTION  (unchanged)                           |
//+------------------------------------------------------------------+
struct SLondonHours
  {
   int sessionStartBroker;
   int sessionEndBroker;
  };

int NormalizeHour(int h) { return ((h % 24) + 24) % 24; }

bool InSession(int h, int start, int end)
  {
   if(start == end) return false;
   if(start < end) return (h >= start && h < end);
   return (h >= start || h < end);
  }

SLondonHours CalcLondonSessionHours()
  {
   SLondonHours h;
   h.sessionStartBroker = NormalizeHour(InpLondonOpenUTC  + InpBrokerUTCOffset);
   h.sessionEndBroker   = NormalizeHour(InpLondonCloseUTC + InpBrokerUTCOffset);
   PrintFormat("[London] Session UTC %02d:00-%02d:00 | Broker offset=UTC%+d | Broker window %02d:00-%02d:00",
               InpLondonOpenUTC, InpLondonCloseUTC, InpBrokerUTCOffset,
               h.sessionStartBroker, h.sessionEndBroker);
   return h;
  }

SLondonHours g_ldn;

//+------------------------------------------------------------------+
//|  CHART VISUAL ENGINE  (gated by InpEnableVisuals)                |
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
   ObjectSetString(0, name, OBJPROP_TEXT,    text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,  clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

void DeleteAllVisuals()
  {
   string names[] = {"EA_PDH","EA_PDL","EA_LSH","EA_LSL","EA_H4H","EA_H4L",
                     "LBL_PDH","LBL_PDL","LBL_LSH","LBL_LSL","LBL_H4H","LBL_H4L"};
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, names[i]);
   // clean up any live SL lines (per-set, name is dynamic: "EA_SL_<setname>")
   for(int i = ObjectsTotal(0, 0, -1) - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i, 0, -1);
      if(StringFind(nm, "EA_SL_") == 0)
         ObjectDelete(0, nm);
     }
  }

void UpdateVisuals(double pdh, double pdl, double lsh, double lsl)
  {
   if(!InpEnableVisuals) return; // [U5] toggle
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

//+------------------------------------------------------------------+
//|  [H4LINES] 4H high/low lines. The line starts at the open of the  |
//|  4H candle the level came from and runs to the end of the candle  |
//|  it is being traded in. Same two objects are moved each new       |
//|  candle, so the chart never fills up with old lines. Redraws only |
//|  when the level changes (or the objects were deleted).            |
//+------------------------------------------------------------------+
void DrawH4Levels(double hi, double lo, datetime srcCandleOpen)
  {
   if(!InpEnableVisuals) return;
   static datetime s_t = 0;
   static double   s_h = 0, s_l = 0;
   bool exists = (ObjectFind(0, "EA_H4H") >= 0 && ObjectFind(0, "EA_H4L") >= 0);
   if(exists && srcCandleOpen == s_t && hi == s_h && lo == s_l) return;
   s_t = srcCandleOpen; s_h = hi; s_l = lo;

   datetime t1 = srcCandleOpen;
   datetime t2 = srcCandleOpen + 8 * 3600;   // source candle + the current 4H candle
   DrawLevel("EA_H4H", hi, clrMagenta);
   DrawLevel("EA_H4L", lo, clrAqua);
   ObjectMove(0, "EA_H4H", 0, t1, hi);  ObjectMove(0, "EA_H4H", 1, t2, hi);
   ObjectMove(0, "EA_H4L", 0, t1, lo);  ObjectMove(0, "EA_H4L", 1, t2, lo);
   ObjectSetInteger(0, "EA_H4H", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, "EA_H4L", OBJPROP_WIDTH, 2);
   DrawLabel("LBL_H4H", hi, "4H High " + DoubleToString(hi, g_dg), clrMagenta);
   DrawLabel("LBL_H4L", lo, "4H Low "  + DoubleToString(lo, g_dg), clrAqua);
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//|  LIVE SL LINE (moves every tick with the trailing stop)          |
//+------------------------------------------------------------------+
void DrawSLLine(string name, double sl, string label, color clr)
  {
   if(!InpEnableVisuals) return;
   if(sl <= 0) return;
   DrawLevel(name, sl, clr);                      // create-or-move (existing helper)
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   DrawLabel(name + "_LBL", sl, label, clr);
   ChartRedraw();
  }

void DeleteSLLine(string name)
  {
   if(ObjectFind(0, name) >= 0)          ObjectDelete(0, name);
   if(ObjectFind(0, name + "_LBL") >= 0) ObjectDelete(0, name + "_LBL");
  }

//+------------------------------------------------------------------+
//|  [U1] PROFESSIONAL LOT SIZING                                    |
//|                                                                  |
//|  WHY OrderCalcProfit and NOT "risk / price":                     |
//|    The gold price (e.g. 4100) tells you nothing about your money |
//|    risk. What matters is how much 1.0 lot LOSES moving from the  |
//|    exact entry to the exact SL. OrderCalcProfit asks the broker  |
//|    that question directly for THIS symbol's contract spec and    |
//|    account currency, so:                                         |
//|        lot = (balance * risk%) / lossPerLot(entry->SL)          |
//|    yields the size that risks exactly risk% if the SL is hit.    |
//|    Dividing risk money by the price would be dimensionally wrong.|
//|  The formula is UNCHANGED from v4.00; only the fixed-lot fallback|
//|  is hardened (clamped to broker min/max/step + logged loudly).   |
//+------------------------------------------------------------------+
double ClampVolume(double v)
  {
   double step   = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   if(step <= 0) step = 0.01;
   double lot = step * MathFloor(v / step);
   lot = MathMax(lot, minLot);
   lot = MathMin(lot, maxLot);
   return NormalizeDouble(lot, 2);
  }

double FixedLotFallback(string why)
  {
   double clamped = ClampVolume(InpFixedLot);
   PrintFormat("[Lot] FALLBACK to fixed lot (%s): requested=%.2f clamped=%.2f", why, InpFixedLot, clamped);
   return clamped;
  }

double CalcLotPro(ENUM_ORDER_TYPE orderType, double entryPrice, double slPrice)
  {
   if(!InpAutoLot) return FixedLotFallback("AutoLot=false");

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = bal * InpRiskPct / 100.0;
   if(riskMoney <= 0) return FixedLotFallback("riskMoney<=0");

   double lossPerLot = 0;
   if(!OrderCalcProfit(orderType, g_sym, 1.0, entryPrice, slPrice, lossPerLot))
      return FixedLotFallback(StringFormat("OrderCalcProfit err=%d", GetLastError()));
   lossPerLot = MathAbs(lossPerLot);
   if(lossPerLot <= 0) return FixedLotFallback("lossPerLot<=0");

   double rawLot = riskMoney / lossPerLot;      // <-- 1% sizing (see header)
   double lot    = ClampVolume(rawLot);
   double minLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);

   double actualLoss = 0;
   bool gotActual = OrderCalcProfit(orderType, g_sym, lot, entryPrice, slPrice, actualLoss);
   double deviationPct = 0;
   if(gotActual)
     {
      actualLoss = MathAbs(actualLoss);
      deviationPct = (riskMoney > 0) ? MathAbs(actualLoss - riskMoney) / riskMoney * 100.0 : 0;
     }

   PrintFormat("[Lot] Balance=%.2f RiskTarget=%.2f(%.1f%%) LossPerLot(1.0)=%.2f RawLot=%.2f -> Lot=%.2f ActualRisk=%.2f Dev=%.2f%%",
               bal, riskMoney, InpRiskPct, lossPerLot, rawLot, lot, actualLoss, deviationPct);

   if(InpEnableRiskDevChk && gotActual && deviationPct > InpMaxRiskDeviationPct && lot > minLot)
     {
      PrintFormat("[Lot] REJECTED: risk deviation %.2f%% exceeds tolerance %.2f%%", deviationPct, InpMaxRiskDeviationPct);
      return 0;
     }
   return lot;
  }

//+------------------------------------------------------------------+
//|  ORDER / POSITION SCAN HELPERS                                   |
//+------------------------------------------------------------------+
bool OrderIsLive(ulong ticket)
  {
   if(ticket == 0) return false;
   for(int i = 0; i < OrdersTotal(); i++)
      if(OrderGetTicket(i) == ticket) return true;
   return false;
  }

int CountPendingByMagic(ulong magic)
  {
   int c = 0;
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_sym) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != magic) continue;
      c++;
     }
   return c;
  }

int CountPositionsByMagic(ulong magic)
  {
   int c = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic) continue;
      c++;
     }
   return c;
  }

//+------------------------------------------------------------------+
//|  DAILY-OPEN BLACKOUT WINDOW (server time)                        |
//|  Window = [close - Before, reopen + After). Handles a window      |
//|  that crosses midnight (start > end, e.g. 22:45 -> 01:15).        |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//|  [BLACKOUTEXP] Next occurrence of the blackout window START,     |
//|  as an absolute datetime (server time). Gives pending orders a    |
//|  broker-side expiration so that if our OWN OrderDelete() at       |
//|  rollover is ever REJECTED (the scenario v5.17's deferred-flush   |
//|  retry exists for), the order still dies on the broker's clock    |
//|  instead of sitting live for a reopen gap to fill into. Pure      |
//|  safety net: on a normal day CancelAll()/DayReset() removes the   |
//|  order long before this time, so it never actually self-expires.  |
//+------------------------------------------------------------------+
datetime NextBlackoutStart()
  {
   if(!InpEnableBlackout) return 0; // caller falls back to GTC
   int s, e;
   BlackoutWindow(s, e);
   if(s == e) return 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int nowMin   = dt.hour * 60 + dt.min;
   int deltaMin = s - nowMin;
   if(deltaMin <= 0) deltaMin += 1440; // window start already passed today -> next day
   return TimeCurrent() + (datetime)deltaMin * 60 - dt.sec;
  }

//+------------------------------------------------------------------+
//|  [RG] CLASS: CRiskGovernor  (account-level prop-firm guard)      |
//|                                                                  |
//|  Enforces two EQUITY-based limits, checked every tick and before |
//|  every placement. Touches NO strategy logic - it only blocks new |
//|  trades and (optionally) flattens when a limit is breached.       |
//|                                                                  |
//|   1) DAILY loss: equity vs a daily anchor captured at each new    |
//|      day. Anchor is persisted to a GlobalVariable so a mid-day    |
//|      restart does not lose the baseline. Halts for the REST OF    |
//|      THE DAY; auto-clears at the next new-day anchor.             |
//|   2) OVERALL drawdown: equity vs an all-time high-water mark      |
//|      (also persisted). Halts PERMANENTLY (until GVs are cleared). |
//|                                                                  |
//|  Thresholds are the INPUT buffers (e.g. 2.5% / 8.5%), set safely  |
//|  below the firm's hard limits (3% / 10%) to leave gap room.       |
//+------------------------------------------------------------------+
class CRiskGovernor
  {
private:
   CTrade  m_trade;
   double  m_dayAnchor;     // equity at start of trading day
   double  m_hwm;           // all-time equity high-water mark
   bool    m_dayHalted;     // daily limit hit -> no new trades today
   bool    m_permHalted;    // overall DD hit (PERMANENT mode)
   int     m_anchorDay;     // YYYYMMDD the anchor belongs to
   bool    m_isTester;      // [TG] running inside the Strategy Tester?
   int     m_ddBreaches;    // [TG] count of overall-DD breaches this run
   int     m_dayBreaches;   // [TG] count of daily-loss halts this run
   int     m_pauseUntilDay; // [TG] YYYYMMDD until which trading is paused (PAUSE mode)

   // [TG] Persistence wrapper: NEVER touch GlobalVariables in the tester,
   // so every backtest run starts clean (fixes stale-HWM contamination).
   void   GVSetSafe(string name, double v) { if(!m_isTester) GlobalVariableSet(name, v); }
   bool   GVCheckSafe(string name)         { return !m_isTester && GlobalVariableCheck(name); }
   double GVGetSafe(string name)           { return m_isTester ? 0 : GlobalVariableGet(name); }

   string GVAnchor() { return "RG_DAYANCHOR_" + g_sym; }
   string GVAnchorDay() { return "RG_ANCHORDAY_" + g_sym; }
   string GVHwm()    { return "RG_HWM_"       + g_sym; }

   int TodayInt()
     {
      MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
      return dt.year*10000 + dt.mon*100 + dt.day;
     }

   //--- Close every position + pending for BOTH magics on this symbol.
   void FlattenAll(string why)
     {
      // Close open positions.
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
         ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(mg != InpMagicPDH && mg != InpMagicLDN && mg != InpMagic4H) continue; // [RGFIX] 4H now covered by breach flatten
         m_trade.SetExpertMagicNumber(mg);
         if(m_trade.PositionClose(t))
            PrintFormat("[RiskGov] CLOSED position #%I64u (%s)", t, why);
         else
            PrintFormat("[RiskGov] CLOSE FAIL #%I64u rc=%d %s", t,
                        m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
        }
      // Delete pendings.
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != g_sym) continue;
         ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
         if(mg != InpMagicPDH && mg != InpMagicLDN && mg != InpMagic4H) continue; // [RGFIX] 4H now covered by breach flatten
         m_trade.SetExpertMagicNumber(mg);
         if(m_trade.OrderDelete(t))
            PrintFormat("[RiskGov] DELETED pending #%I64u (%s)", t, why);
        }
     }

public:
   CRiskGovernor() : m_dayAnchor(0), m_hwm(0), m_dayHalted(false),
                     m_permHalted(false), m_anchorDay(0), m_isTester(false),
                     m_ddBreaches(0), m_dayBreaches(0), m_pauseUntilDay(0) {}

   void Init()
     {
      if(!InpEnableRiskGov) return;
      m_isTester = (bool)MQLInfoInteger(MQL_TESTER); // [TG] tester detection
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);

      // [TG] Optional live reset: wipe persisted anchors for a fresh baseline.
      if(!m_isTester && InpGovResetOnInit)
        {
         GlobalVariableDel(GVHwm());
         GlobalVariableDel(GVAnchor());
         GlobalVariableDel(GVAnchorDay());
         Print("[RiskGov] Persisted anchors WIPED by InpGovResetOnInit");
        }

      // Restore high-water mark (live only - tester always starts clean).
      if(GVCheckSafe(GVHwm())) m_hwm = GVGetSafe(GVHwm());
      if(m_hwm < eq) { m_hwm = eq; GVSetSafe(GVHwm(), m_hwm); }

      // Restore today's anchor if it belongs to today; else set a fresh one.
      int today = TodayInt();
      if(GVCheckSafe(GVAnchor()) && GVCheckSafe(GVAnchorDay()) &&
         (int)GVGetSafe(GVAnchorDay()) == today)
        {
         m_dayAnchor = GVGetSafe(GVAnchor());
         m_anchorDay = today;
         PrintFormat("[RiskGov] Restored day anchor=%.2f (day %d) hwm=%.2f", m_dayAnchor, today, m_hwm);
        }
      else
        {
         SetDailyAnchor(eq, today);
        }

      if(m_isTester)
         PrintFormat("[RiskGov] TESTER MODE: state in-memory only (clean run) | HaltMode=%s",
                     InpGovHaltMode==GOV_PERMANENT?"PERMANENT":InpGovHaltMode==GOV_PAUSE_DAYS?"PAUSE":"LOG_ONLY");
     }

   //--- Capture a fresh daily anchor (called on new day).
   void SetDailyAnchor(double eq, int day)
     {
      m_dayAnchor = eq;
      m_anchorDay = day;
      m_dayHalted = false;                 // new day clears the daily halt
      GVSetSafe(GVAnchor(), eq);
      GVSetSafe(GVAnchorDay(), day);
      // [TG] PAUSE mode: lift the pause once its window has passed.
      if(m_pauseUntilDay > 0 && day >= m_pauseUntilDay)
        {
         m_pauseUntilDay = 0;
         PrintFormat("[RiskGov] PAUSE window ended - trading resumes (day %d)", day);
        }
      PrintFormat("[RiskGov] NEW DAY anchor set: equity=%.2f (day %d)", eq, day);
     }

   void OnNewDay()
     {
      if(!InpEnableRiskGov) return;
      SetDailyAnchor(AccountInfoDouble(ACCOUNT_EQUITY), TodayInt());
     }

   //--- True if new trades are currently allowed.
   bool TradingAllowed()
     {
      if(!InpEnableRiskGov) return true;
      if(m_pauseUntilDay > 0 && TodayInt() < m_pauseUntilDay) return false; // [TG] PAUSE mode
      return !(m_dayHalted || m_permHalted);
     }

   //--- Evaluate limits every tick. Halts (and optionally flattens) on breach.
   void OnTick()
     {
      if(!InpEnableRiskGov) return;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);

      // Update high-water mark.
      if(eq > m_hwm) { m_hwm = eq; GVSetSafe(GVHwm(), m_hwm); }

      // Overall drawdown vs high-water mark - behavior depends on HaltMode.
      bool pausedNow = (m_pauseUntilDay > 0 && TodayInt() < m_pauseUntilDay);
      if(!m_permHalted && !pausedNow && m_hwm > 0)
        {
         double ddPct = (m_hwm - eq) / m_hwm * 100.0;
         if(ddPct >= InpMaxDrawdownPct)
           {
            m_ddBreaches++;
            PrintFormat("[RiskGov] *** OVERALL DD BREACH #%d *** eq=%.2f hwm=%.2f dd=%.2f%% >= %.2f%% | mode=%s",
                        m_ddBreaches, eq, m_hwm, ddPct, InpMaxDrawdownPct,
                        InpGovHaltMode==GOV_PERMANENT?"PERMANENT":InpGovHaltMode==GOV_PAUSE_DAYS?"PAUSE":"LOG_ONLY");
            if(InpCloseAllOnBreach) FlattenAll("overall DD");

            switch(InpGovHaltMode)
              {
               case GOV_PERMANENT:
                  m_permHalted = true;   // live-correct: stays halted
                  break;
               case GOV_PAUSE_DAYS:
                 {
                  // Pause for N calendar days, then resume with a re-based HWM
                  // (so the same drawdown doesn't instantly re-trigger).
                  datetime until = TimeCurrent() + (datetime)InpGovPauseDays * 86400;
                  MqlDateTime dt; TimeToStruct(until, dt);
                  m_pauseUntilDay = dt.year*10000 + dt.mon*100 + dt.day;
                  m_hwm = eq; GVSetSafe(GVHwm(), m_hwm);
                  PrintFormat("[RiskGov] PAUSED until day %d, HWM re-based to %.2f", m_pauseUntilDay, m_hwm);
                  break;
                 }
               case GOV_LOG_ONLY:
                  // Tester-analysis mode: re-base HWM and continue so each
                  // distinct breach episode is counted once, not every tick.
                  m_hwm = eq; GVSetSafe(GVHwm(), m_hwm);
                  break;
              }
           }
        }

      // Daily loss vs anchor.
      if(!m_dayHalted && !pausedNow && m_dayAnchor > 0)
        {
         double dayLossPct = (m_dayAnchor - eq) / m_dayAnchor * 100.0;
         if(dayLossPct >= InpDailyLossPct)
           {
            m_dayBreaches++;
            m_dayHalted = true; // always halts for the day (all modes) - clears at next anchor
            PrintFormat("[RiskGov] *** DAILY LOSS HALT #%d *** eq=%.2f anchor=%.2f loss=%.2f%% >= %.2f%%",
                        m_dayBreaches, eq, m_dayAnchor, dayLossPct, InpDailyLossPct);
            if(InpCloseAllOnBreach) FlattenAll("daily loss");
           }
        }
     }

   // [TG] Final tally - call from OnDeinit so every backtest ends with a verdict line.
   void LogSummary()
     {
      if(!InpEnableRiskGov) return;
      PrintFormat("[RiskGov] SUMMARY: overall-DD breaches=%d | daily-loss halts=%d | %s",
                  m_ddBreaches, m_dayBreaches,
                  m_ddBreaches > 0 ? "*** THIS CONFIG WOULD HAVE FAILED A PROP ACCOUNT ***"
                                   : "no overall-DD breach this run");
     }

   void LogState()
     {
      if(!InpEnableRiskGov) { Print("[RiskGov] DISABLED"); return; }
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      PrintFormat("[RiskGov] eq=%.2f anchor=%.2f hwm=%.2f | dailyLimit=%.1f%% overallLimit=%.1f%% | closeOnBreach=%s",
                  eq, m_dayAnchor, m_hwm, InpDailyLossPct, InpMaxDrawdownPct,
                  InpCloseAllOnBreach ? "YES" : "NO");
     }
  };

CRiskGovernor g_risk; // global governor instance

//+------------------------------------------------------------------+
//|  CLASS: CTrailStop  (3-stage math UNCHANGED)                     |
//|  [FIX] Now tracks one EXACT position ticket instead of           |
//|  re-scanning by magic number every tick. That re-scan was the    |
//|  root cause of the "SL blew out 3x" bug: when BOTH the buy and   |
//|  sell leg of a set were live at once (opposite leg intentionally |
//|  not cancelled on fill, see [U2]), a single magic-based lookup   |
//|  could silently pick up the WRONG position. One CTrailStop now   |
//|  binds to one ticket for its whole life and never re-picks.      |
//+------------------------------------------------------------------+
class CTrailStop
  {
private:
   CTrade   *m_trade;
   ulong     m_magic;
   ulong     m_ticket;
   bool      m_init;
   bool      m_isBuy;
   double    m_entry;
   bool      m_beDone;
   bool      m_trailActive;
   double    m_beDist;
   double    m_trailActDist;
   double    m_trailDist;

   // [ASYNC] Dedicated async CTrade used ONLY for trailing SL modifies, so a
   // slow/stalled broker response on this leg's SL update can never block
   // the rest of the EA (other legs/modules still get every tick serviced).
   // Order placement/cancel/rollover keep using the shared synchronous
   // m_trade above - unchanged.
   CTrade    m_atrade;
   bool      m_pendingModify;
   double    m_pendingSL;
   string    m_pendingReason;
   ulong     m_pendingSentMs;

public:
   CTrailStop() : m_trade(NULL), m_magic(0), m_ticket(0), m_init(false), m_isBuy(false),
                  m_entry(0), m_beDone(false), m_trailActive(false),
                  m_beDist(0), m_trailActDist(0), m_trailDist(0),
                  m_pendingModify(false), m_pendingSL(0), m_pendingReason(""), m_pendingSentMs(0) {}

   void  Attach(CTrade *trade, ulong magic)
     {
      m_trade = trade; m_magic = magic;
      m_atrade.SetAsyncMode(true);
      m_atrade.SetExpertMagicNumber((long)magic);
     }
   ulong Ticket() const { return m_ticket; }
   // [ASYNC] Used by OnTradeTransaction (routed via CSetManager/CExpert) to
   // find which tracker a TRADE_ACTION_SLTP confirmation belongs to.
   bool  MatchesTicket(ulong tkt) const { return m_init && m_ticket == tkt; }

   void StartTracking(ulong ticket, bool isBuy, double entryPrice)
     {
      if(m_init)
        {
         if(InpDebug) PrintFormat("[Trail magic=%I64u tkt=%I64u] Already tracking, skip init", m_magic, m_ticket);
         return;
        }
      m_ticket = ticket; m_isBuy = isBuy; m_entry = entryPrice; m_beDone = false; m_trailActive = false; m_init = true;
      m_beDist = PtsToPrice(InpBreakEvenPts);
      m_trailActDist = PtsToPrice(InpTrailActivatePts);
      m_trailDist = PtsToPrice(InpTrailDist);
      PrintFormat("[Trail magic=%I64u tkt=%I64u] INIT | %s | Entry=%.5f | BE@+%.0f | Act@+%.0f | Trail=%.0f",
                  m_magic, m_ticket, isBuy ? "BUY" : "SELL", m_entry, InpBreakEvenPts, InpTrailActivatePts, InpTrailDist);
     }

   void AdoptExisting(ulong ticket, bool isBuy, double entryPrice, double curSL)
     {
      m_ticket = ticket; m_isBuy = isBuy; m_entry = entryPrice; m_init = true;
      m_beDist = PtsToPrice(InpBreakEvenPts);
      m_trailActDist = PtsToPrice(InpTrailActivatePts);
      m_trailDist = PtsToPrice(InpTrailDist);
      if(curSL > 0)
        {
         if(isBuy) m_beDone = (curSL >= entryPrice - g_pt);
         else      m_beDone = (curSL <= entryPrice + g_pt);
        }
      else m_beDone = false;
      m_trailActive = false;
      PrintFormat("[Trail magic=%I64u tkt=%I64u] ADOPTED | %s | Entry=%.5f curSL=%.5f | beDone=%s",
                  m_magic, m_ticket, isBuy ? "BUY" : "SELL", entryPrice, curSL, m_beDone ? "true" : "false");
     }

   void Reset()
     {
      if(m_init) PrintFormat("[Trail magic=%I64u tkt=%I64u] RESET", m_magic, m_ticket);
      m_init=false; m_ticket=0; m_isBuy=false; m_entry=0; m_beDone=false; m_trailActive=false;
      m_beDist=0; m_trailActDist=0; m_trailDist=0;
      m_pendingModify=false; m_pendingSL=0; m_pendingReason=""; m_pendingSentMs=0;
     }

   bool IsTracking() const { return m_init; }

   // [ASYNC] Called once OnTradeTransaction confirms (or rejects) the
   // in-flight SL modify this tracker sent. Replaces the old immediate
   // ok/fail check that used to run right after PositionModify() -
   // that immediate result no longer means anything once the call is async.
   void OnAsyncModifyResult(bool success, uint retcode)
     {
      if(!m_pendingModify) return;
      if(success)
         PrintFormat("[Trail magic=%I64u tkt=%I64u] SL MOVED (%s) | -> %.5f",
                     m_magic, m_ticket, m_pendingReason, m_pendingSL);
      else
         PrintFormat("[Trail magic=%I64u tkt=%I64u] SL MODIFY FAIL (%s) | rc=%u | new=%.5f",
                     m_magic, m_ticket, m_pendingReason, retcode, m_pendingSL);
      m_pendingModify = false;
     }

   bool Update()
     {
      // [FIX] Select THIS tracker's exact ticket - never re-derive it from
      // magic number, so a same-magic position on the opposite side can
      // never get mixed up with this one.
      if(!m_init) return false;
      if(!PositionSelectByTicket(m_ticket))
        {
         if(InpDebug) PrintFormat("[Trail magic=%I64u tkt=%I64u] Position not found - closed", m_magic, m_ticket);
         return false;
        }
      if(!InpEnableTrailing) return true;

      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      double bid    = SymbolInfoDouble(g_sym, SYMBOL_BID);
      double ask    = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      double closePx = m_isBuy ? bid : ask;
      // [SPREADFIX] add live spread back so profit matches the chart (Bid-based) move; BE/trail activate at true chart points
      double profitPts = (m_isBuy ? (closePx - openPx)/g_pt : (openPx - closePx)/g_pt) + (ask - bid)/g_pt;

      if(InpEnableBreakEven && !m_beDone && profitPts >= InpBreakEvenPts)
        {
         m_beDone = true;
         PrintFormat("[Trail magic=%I64u tkt=%I64u] BREAKEVEN | Profit=%.1f pts", m_magic, m_ticket, profitPts);
        }
      // [FIX] Stage 2 (trail) is gated on stage 1 (breakeven) actually being
      // done first, whenever breakeven is enabled. Previously m_trailActive
      // was set from an independent threshold check against the same
      // profitPts, so if InpTrailActivatePts <= InpBreakEvenPts trail could
      // fire on the same tick as (or before) breakeven, and the candidateSL
      // branch below always prefers TRAIL over BREAKEVEN - meaning the
      // breakeven stage silently never executed. This makes BE->trail a
      // strict, input-value-independent sequence.
      bool beGateOpen = (!InpEnableBreakEven) || m_beDone;
      if(beGateOpen && !m_trailActive && profitPts >= InpTrailActivatePts)
        {
         m_trailActive = true;
         PrintFormat("[Trail magic=%I64u tkt=%I64u] TRAIL ACTIVE | Profit=%.1f pts", m_magic, m_ticket, profitPts);
        }
      if(!m_beDone && !m_trailActive)
        {
         if(InpDebug) PrintFormat("[Trail magic=%I64u tkt=%I64u] Waiting | Profit=%.1f pts", m_magic, m_ticket, profitPts);
         return true;
        }

      double candidateSL; string reason;
      if(m_trailActive)
        {
         candidateSL = m_isBuy ? NormalizeToTick(bid - m_trailDist) : NormalizeToTick(ask + m_trailDist);
         reason = "TRAIL";
        }
      else
        {
         candidateSL = NormalizeToTick(openPx);
         reason = "BREAKEVEN";
        }

      if(curSL > 0)
        {
         if(m_isBuy && candidateSL <= curSL) { if(InpDebug) PrintFormat("[Trail %I64u tkt=%I64u] %s skip <=curSL", m_magic, m_ticket, reason); return true; }
         if(!m_isBuy && candidateSL >= curSL){ if(InpDebug) PrintFormat("[Trail %I64u tkt=%I64u] %s skip >=curSL", m_magic, m_ticket, reason); return true; }
        }
      if(m_isBuy && candidateSL >= bid) { if(InpDebug) PrintFormat("[Trail %I64u tkt=%I64u] %s skip >=bid", m_magic, m_ticket, reason); return true; }
      if(!m_isBuy && candidateSL <= ask){ if(InpDebug) PrintFormat("[Trail %I64u tkt=%I64u] %s skip <=ask", m_magic, m_ticket, reason); return true; }

      // [TRAILSTOPFIX] Clamp to the broker's minimum stop distance so a too-tight
      // trail (e.g. InpTrailDist below SYMBOL_TRADE_STOPS_LEVEL) doesn't just
      // silently fail every modify - it trails at the closest ALLOWED distance instead.
      if(InpEnableStopLevelChk)
        {
         long   stopsLvl = SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL);
         double minDist  = stopsLvl * g_pt;
         if(minDist > 0)
           {
            double minAllowedSL = m_isBuy ? NormalizeToTick(bid - minDist) : NormalizeToTick(ask + minDist);
            bool tooTight = m_isBuy ? (candidateSL > minAllowedSL) : (candidateSL < minAllowedSL);
            if(tooTight)
              {
               if(InpDebug) PrintFormat("[Trail %I64u tkt=%I64u] %s too tight for stopsLvl=%d pts, clamped %.5f -> %.5f",
                                        m_magic, m_ticket, reason, (int)stopsLvl, candidateSL, minAllowedSL);
               candidateSL = minAllowedSL;
               if(curSL > 0 && ((m_isBuy && candidateSL <= curSL) || (!m_isBuy && candidateSL >= curSL)))
                  return true; // clamped level is no better than what's already set - nothing to send
              }
           }
        }

      // [ASYNC] Sent via m_atrade (async mode) instead of the shared m_trade.
      // PositionModify() here only confirms the request was QUEUED, not its
      // outcome - the real accept/reject comes back later through
      // OnTradeTransaction -> OnAsyncModifyResult(). While the previous
      // request for THIS leg is still unconfirmed, skip sending another one
      // (5s safety timeout in case a confirmation is ever missed) rather
      // than stacking requests.
      if(m_pendingModify && (GetTickCount() - m_pendingSentMs) < 5000)
        {
         if(InpDebug) PrintFormat("[Trail %I64u tkt=%I64u] %s skip - prior modify still pending", m_magic, m_ticket, reason);
         return true;
        }
      m_pendingModify = true;
      m_pendingSL     = candidateSL;
      m_pendingReason = reason;
      m_pendingSentMs = GetTickCount();
      bool sent = m_atrade.PositionModify(m_ticket, candidateSL, curTP);
      if(!sent)
        {
         PrintFormat("[Trail magic=%I64u tkt=%I64u] SL MODIFY SEND FAIL (%s) | rc=%d %s | new=%.5f",
                     m_magic, m_ticket, reason, m_atrade.ResultRetcode(), m_atrade.ResultRetcodeDescription(), candidateSL);
         m_pendingModify = false;   // never queued - safe to retry next tick
        }
      else if(InpDebug)
         PrintFormat("[Trail magic=%I64u tkt=%I64u] SL MODIFY SENT (%s) | %.5f -> %.5f | Profit=%.1f pts (async, awaiting confirm)",
                     m_magic, m_ticket, reason, curSL, candidateSL, profitPts);
      return true;
     }
  };

//+------------------------------------------------------------------+
//|  CLASS: CSetManager                                              |
//+------------------------------------------------------------------+
class CSetManager
  {
private:
   CTrade     m_trade;
   CTrailStop m_trailBuy;    // [FIX] independent tracker for the buy-side position
   CTrailStop m_trailSell;   // [FIX] independent tracker for the sell-side position
   ulong      m_magic;
   string     m_name;
   ulong      m_buyTkt;
   ulong      m_sellTkt;
   bool       m_placed;
   bool       m_inTrade;
   bool       m_flushOwed;   // [v5.17] deferred-flush: a rollover CancelAll failed
                             // (e.g. [Market closed]); retry the delete every tick
                             // until the live pendings are actually gone.
   datetime   m_lastFlatten; // [blackout] throttle for flatten attempts

   bool HasPos() const
     {
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) == g_sym &&
            PositionGetInteger(POSITION_MAGIC) == (long)m_magic)
            return true;
        }
      return false;
     }

   // [FIX] Renamed from StartTrail(): now scans ALL live positions for this
   // magic every call (cheap, idempotent) so BOTH a buy leg and a sell leg
   // can be picked up independently, whichever order they fill in. This is
   // what actually fixes the "SL 3x" bug - the old version only ever looked
   // for the first leg and never noticed a second leg had opened.
   void SyncTrailTrackers()
     {
      bool sawBuy = false, sawSell = false;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)m_magic) continue;
         bool   buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         double ep  = PositionGetDouble(POSITION_PRICE_OPEN);
         if(buy)
           {
            sawBuy = true;
            if(!m_trailBuy.IsTracking())
              {
               PrintFormat("[%s] BUY leg triggered | Entry=%.5f | ticket=%I64u", m_name, ep, t);
               m_trailBuy.StartTracking(t, true, ep);
              }
           }
         else
           {
            sawSell = true;
            if(!m_trailSell.IsTracking())
              {
               PrintFormat("[%s] SELL leg triggered | Entry=%.5f | ticket=%I64u", m_name, ep, t);
               m_trailSell.StartTracking(t, false, ep);
              }
           }
        }
      if(sawBuy && sawSell)
         PrintFormat("[%s] BOTH legs live simultaneously - tracking each independently (buy tkt=%I64u, sell tkt=%I64u)",
                     m_name, m_trailBuy.Ticket(), m_trailSell.Ticket());
     }

   // [SL-LINE] Redraws (or deletes) one leg's live SL line so it tracks its
   // own trailing stop. Called separately for the buy tracker and the sell
   // tracker so a straddle with both legs live shows two independent lines.
   void RefreshLegLine(CTrailStop &trail, string suffix)
     {
      string lineName = "EA_SL_" + m_name + "_" + suffix;
      if(!trail.IsTracking() || !PositionSelectByTicket(trail.Ticket()))
        {
         DeleteSLLine(lineName);
         return;
        }
      double sl = PositionGetDouble(POSITION_SL);
      if(sl <= 0)
        {
         DeleteSLLine(lineName);
         return;
        }
      DrawSLLine(lineName, sl, m_name + " " + suffix + " SL " + DoubleToString(sl, g_dg), clrRed);
     }

   //--- [Retry] Place one pending leg with classified retry + tick/stop-level guards.
   bool PlaceLegRetry(bool isBuyStop, double lot, double entry, double sl, double tp, string tag, ulong &outTicket)
     {
      // [U3] Snap all prices to the tick grid BEFORE any validation/submit.
      entry = NormalizeToTick(entry);
      sl    = NormalizeToTick(sl);
      tp    = NormalizeToTick(tp);

      // [BLACKOUTEXP] Broker-side expiry at the next blackout start. Safety net
      // only - on a normal day our own cancel removes the order well before this.
      datetime expiry = NextBlackoutStart();
      ENUM_ORDER_TYPE_TIME timeType = (expiry > 0) ? ORDER_TIME_SPECIFIED : ORDER_TIME_GTC;

      // [U3] Stop-level / freeze-level guard - skip a doomed leg cleanly.
      if(!StopLevelsOK(isBuyStop, entry, sl, tp, m_name))
         return false;

      int maxAttempts = InpEnableRetry ? (InpRetryMax + 1) : 1; // [U5] retry toggle
      for(int attempt = 1; attempt <= maxAttempts; attempt++)
        {
         bool sent = isBuyStop
                    ? m_trade.BuyStop (lot, entry, g_sym, sl, tp, timeType, expiry, tag)
                    : m_trade.SellStop(lot, entry, g_sym, sl, tp, timeType, expiry, tag);
         uint rc = m_trade.ResultRetcode();

         if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED))
           {
            outTicket = m_trade.ResultOrder();
            PrintFormat("[%s] %s placed (attempt %d) | Entry=%.5f SL=%.5f TP=%.5f Lot=%.2f",
                        m_name, isBuyStop ? "BUY STOP" : "SELL STOP", attempt, entry, sl, tp, lot);
            return true;
           }
         if(InpEnableRetry && IsTransientRetcode(rc) && attempt < maxAttempts)
           {
            PrintFormat("[%s] %s TRANSIENT rc=%u (%s), retry %d/%d after %dms",
                        m_name, isBuyStop ? "BUY STOP" : "SELL STOP", rc,
                        m_trade.ResultRetcodeDescription(), attempt, InpRetryMax, InpRetryWaitMs);
            if(!MQLInfoInteger(MQL_TESTER)) Sleep(InpRetryWaitMs); // [EFFIC] real delay only needed live; skip in tester so optimization isn't slowed by wall-clock waits
            continue;
           }
         PrintFormat("[%s] %s FAILED rc=%u (%s)", m_name,
                     isBuyStop ? "BUY STOP" : "SELL STOP", rc, m_trade.ResultRetcodeDescription());
         return false;
        }
      return false;
     }

   //--- [CONFIRM] Send one MARKET order for the confirmed direction, with the
   //    same retry/transient-error handling as PlaceLegRetry(), but via
   //    CTrade::Buy/Sell instead of BuyStop/SellStop.
   bool ExecuteMarketRetry(bool isBuy, double lot, double sl, double tp, string tag, ulong &outTicket)
     {
      sl = NormalizeToTick(sl);
      tp = NormalizeToTick(tp);

      int maxAttempts = InpEnableRetry ? (InpRetryMax + 1) : 1; // [U5] retry toggle
      for(int attempt = 1; attempt <= maxAttempts; attempt++)
        {
         bool sent = isBuy
                    ? m_trade.Buy (lot, g_sym, 0.0, sl, tp, tag)
                    : m_trade.Sell(lot, g_sym, 0.0, sl, tp, tag);
         uint rc = m_trade.ResultRetcode();

         if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL))
           {
            outTicket = m_trade.ResultOrder();
            PrintFormat("[%s] CONFIRMED %s market fill (attempt %d) | SL=%.5f TP=%.5f Lot=%.2f",
                        m_name, isBuy ? "BUY" : "SELL", attempt, sl, tp, lot);
            return true;
           }
         if(InpEnableRetry && IsTransientRetcode(rc) && attempt < maxAttempts)
           {
            PrintFormat("[%s] CONFIRMED %s TRANSIENT rc=%u (%s), retry %d/%d after %dms",
                        m_name, isBuy ? "BUY" : "SELL", rc,
                        m_trade.ResultRetcodeDescription(), attempt, InpRetryMax, InpRetryWaitMs);
            if(!MQLInfoInteger(MQL_TESTER)) Sleep(InpRetryWaitMs);
            continue;
           }
         PrintFormat("[%s] CONFIRMED %s FAILED rc=%u (%s)", m_name,
                     isBuy ? "BUY" : "SELL", rc, m_trade.ResultRetcodeDescription());
         return false;
        }
      return false;
     }

   //--- [blackout] Close every open position of this module.
   void FlattenPositions()
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         if(m_trade.PositionClose(t))
            PrintFormat("[%s] Blackout flatten: closed ticket %I64u", m_name, t);
         else
            PrintFormat("[%s] Blackout flatten FAILED ticket %I64u rc=%u (%s)",
                        m_name, t, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
        }
     }

   //--- [blackout] Called every tick while InBlackout(): remove resting pendings and
   //    (optionally) flatten, so nothing is live when the market reopens.
   void BlackoutGuard()
     {
      if(!m_flushOwed && (OrderIsLive(m_buyTkt) || OrderIsLive(m_sellTkt)))
         CancelAll("daily-open blackout");   // failures are retried by RetryFlush()

      if(InpBlackoutFlatten && HasPos() && (TimeCurrent() - m_lastFlatten) >= 30)
        {
         m_lastFlatten = TimeCurrent();
         FlattenPositions();
        }
     }

public:
   CSetManager() : m_magic(0), m_name(""), m_buyTkt(0), m_sellTkt(0), m_placed(false), m_inTrade(false), m_flushOwed(false), m_lastFlatten(0) {}

   void Init(ulong magic, string name)
     {
      m_magic = magic; m_name = name;
      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetMarginMode();
      m_trade.SetTypeFillingBySymbol(g_sym);
      m_trade.SetDeviationInPoints(80);
      m_trailBuy.Attach(&m_trade, magic);
      m_trailSell.Attach(&m_trade, magic);
     }

   void RecoverFromBroker()
     {
      if(!InpEnableRecovery) return; // [U5] recovery toggle
      m_buyTkt = 0; m_sellTkt = 0; m_placed = false; m_inTrade = false; m_flushOwed = false;
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != g_sym) continue;
         if((ulong)OrderGetInteger(ORDER_MAGIC) != m_magic) continue;
         long type = OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP)  { m_buyTkt  = t; m_placed = true; }
         if(type == ORDER_TYPE_SELL_STOP) { m_sellTkt = t; m_placed = true; }
        }
      // [FIX] Adopt EVERY live position for this magic (previously stopped
      // after the first match with `break`, so a restart while both legs
      // were live would silently orphan the second one).
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_sym) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != m_magic) continue;
         bool   buy   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
         double ep    = PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL = PositionGetDouble(POSITION_SL);
         if(buy) m_trailBuy.AdoptExisting(t, true, ep, curSL);
         else    m_trailSell.AdoptExisting(t, false, ep, curSL);
         m_inTrade = true; m_placed = true;
        }
      if(m_placed || m_inTrade)
         PrintFormat("[%s] RECOVERED | buyTkt=%I64u sellTkt=%I64u inTrade=%s",
                     m_name, m_buyTkt, m_sellTkt, m_inTrade ? "true" : "false");
     }

   bool Place(double high, double low)
     {
      if(m_placed) { if(InpDebug) PrintFormat("[%s] Already placed, skip", m_name); return false; }

      // [RG] Account-level guard: block new placements while halted.
      if(!g_risk.TradingAllowed())
        {
         if(InpDebug) PrintFormat("[%s] SKIP placement: risk governor halted trading", m_name);
         return false;
        }

      // [blackout] Place nothing inside the daily-open window. Not marked placed,
      // so the existing per-tick retry paths re-attempt after it ends.
      if(InBlackout()) return false;

      if(high <= 0 || low <= 0 || high <= low)
        { PrintFormat("[%s] Invalid levels H=%.5f L=%.5f", m_name, high, low); return false; }

      // [T] Duplicate-scan toggle (recovery + m_placed flag still guard when off).
      if(InpEnableDupScan &&
         (CountPendingByMagic(m_magic) > 0 || CountPositionsByMagic(m_magic) > 0))
        {
         PrintFormat("[%s] SKIP placement: existing orders/positions for magic %I64u", m_name, m_magic);
         m_placed = true;
         return false;
        }
      if(!ValidateTradeEnvironment(m_name))
        {
         // Not marked placed -> will retry on a later tick (e.g. once session opens).
         return false;
        }

      double slDist = PtsToPrice(InpSL_Pts);
      double tpDist = PtsToPrice(InpTP_Pts);
      bool ok = false;

      // [T] Direction guard: at least one leg must be enabled.
      if(!InpEnableBuyLegs && !InpEnableSellLegs)
        {
         PrintFormat("[%s] WARNING: both Buy and Sell legs disabled - nothing to place", m_name);
         return false;
        }

      // [SB] Spread buffer: pad the entry OUTWARD by (live spread x mult) so a
      // momentary spread spike alone can't trigger the stop at a bad level.
      // SL and TP are measured FROM the padded entry, so the point-distances
      // (and thus risk) are preserved exactly. Buffer is 0 when toggle is off.
      double buf = 0.0;
      if(InpEnableSpreadBuffer)
        {
         double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
         double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
         double spread = ask - bid;
         buf = spread * InpSpreadBufferMult;
         if(InpDebug)
            PrintFormat("[%s] Spread buffer: spread=%.5f x%.2f = %.5f pad", m_name, spread, InpSpreadBufferMult, buf);
        }

      // [SIMSPREAD v5.20] Backtest-only simulated spread. Adds an outward pad of
      // InpSimSpreadPts so tester fills reflect a realistic spread cost (BUY fills
      // at high+spread, SELL at low-spread) instead of the tester's optimistic
      // spread. SL/TP keep their point-distances from the padded entry, so risk
      // per trade is unchanged - only the fill level (and thus the cost) shifts.
      // Guarded by MQLInfoInteger(MQL_TESTER): NEVER pads on live/demo, where the
      // real broker spread already applies.
      if(InpSimSpreadTester && InpSimSpreadPts > 0 && MQLInfoInteger(MQL_TESTER))
        {
         double simPad = InpSimSpreadPts * g_pt;
         buf += simPad;
         if(InpDebug)
            PrintFormat("[%s] SIM-SPREAD (tester): +%.0f pts = %.5f added pad (total buf=%.5f)",
                        m_name, InpSimSpreadPts, simPad, buf);
        }

      // [T-DANGER] Hard-stops toggle: when off, SL/TP are sent as 0 (naked).
      // Loud warning - this removes broker-side protection entirely.
      if(!InpEnableHardStops)
         PrintFormat("[%s] *** DANGER: HardStops OFF - placing NAKED orders (no SL/TP) ***", m_name);

      // BUY STOP at high + buffer (SL/TP keep their distances from the entry)
      if(InpEnableBuyLegs)
        {
         double bE = high + buf, bS = bE - slDist, bT = bE + tpDist;
         double useS = InpEnableHardStops ? bS : 0.0;
         double useT = (InpEnableHardStops && InpEnableTP) ? bT : 0.0;
         double buyLot = CalcLotPro(ORDER_TYPE_BUY, NormalizeToTick(bE), NormalizeToTick(bS));
         if(buyLot > 0) { if(PlaceLegRetry(true,  buyLot, bE, useS, useT, m_name+"_B", m_buyTkt)) ok = true; }
         else PrintFormat("[%s] BUY STOP skipped: lot rejected/zero", m_name);
        }
      else if(InpDebug) PrintFormat("[%s] BUY leg disabled by toggle", m_name);

      // SELL STOP at low - buffer (SL/TP keep their distances from the entry)
      if(InpEnableSellLegs)
        {
         double sE = low - buf, sS = sE + slDist, sT = sE - tpDist;
         double useS = InpEnableHardStops ? sS : 0.0;
         double useT = (InpEnableHardStops && InpEnableTP) ? sT : 0.0;
         double sellLot = CalcLotPro(ORDER_TYPE_SELL, NormalizeToTick(sE), NormalizeToTick(sS));
         if(sellLot > 0) { if(PlaceLegRetry(false, sellLot, sE, useS, useT, m_name+"_S", m_sellTkt)) ok = true; }
         else PrintFormat("[%s] SELL STOP skipped: lot rejected/zero", m_name);
        }
      else if(InpDebug) PrintFormat("[%s] SELL leg disabled by toggle", m_name);

      m_placed = ok;
      return ok;
     }

   // [CONFIRM] Single-direction MARKET entry once the 5M-arm/1M-execute
   // sequence has fired. Mirrors Place()'s guards (risk governor, blackout,
   // duplicate-scan, trade-environment, hard-stops/TP toggles, auto-lot) but
   // sends a market order for the one confirmed side instead of a resting
   // two-sided stop straddle. Independent of m_placed/m_buyTkt/m_sellTkt
   // (those track pending legs); the resulting position is picked up on the
   // next Tick() by the existing SyncTrailTrackers() scan, same as any fill.
   bool ExecuteConfirmedMarket(bool isBuy, double level)
     {
      if(!g_risk.TradingAllowed())
        {
         if(InpDebug) PrintFormat("[%s] SKIP confirmed entry: risk governor halted trading", m_name);
         return false;
        }
      if(InBlackout())
        {
         if(InpDebug) PrintFormat("[%s] SKIP confirmed entry: inside daily-open blackout", m_name);
         return false;
        }
      if((isBuy && !InpEnableBuyLegs) || (!isBuy && !InpEnableSellLegs))
        {
         if(InpDebug) PrintFormat("[%s] SKIP confirmed %s: leg disabled by toggle", m_name, isBuy ? "BUY" : "SELL");
         return false;
        }
      if(InpEnableDupScan &&
         (CountPendingByMagic(m_magic) > 0 || CountPositionsByMagic(m_magic) > 0))
        {
         PrintFormat("[%s] SKIP confirmed entry: existing orders/positions for magic %I64u", m_name, m_magic);
         return false;
        }
      if(!ValidateTradeEnvironment(m_name))
         return false;

      double slDist = PtsToPrice(InpSL_Pts);
      double tpDist = PtsToPrice(InpTP_Pts);

      double price = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK) : SymbolInfoDouble(g_sym, SYMBOL_BID);
      double sl    = isBuy ? price - slDist : price + slDist;
      double tp    = isBuy ? price + tpDist : price - tpDist;

      if(!StopLevelsOK(isBuy, price, sl, tp, m_name))
         return false;

      double useS = InpEnableHardStops ? NormalizeToTick(sl) : 0.0;
      double useT = (InpEnableHardStops && InpEnableTP) ? NormalizeToTick(tp) : 0.0;
      if(!InpEnableHardStops)
         PrintFormat("[%s] *** DANGER: HardStops OFF - placing NAKED confirmed order ***", m_name);

      double lotSL = (useS > 0) ? useS : sl; // CalcLotPro needs a real SL distance even if hard stops are off
      double lot = CalcLotPro(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, NormalizeToTick(price), NormalizeToTick(lotSL));
      if(lot <= 0)
        {
         PrintFormat("[%s] Confirmed %s skipped: lot rejected/zero", m_name, isBuy ? "BUY" : "SELL");
         return false;
        }

      ulong outTicket = 0;
      bool ok = ExecuteMarketRetry(isBuy, lot, useS, useT, m_name + (isBuy ? "_CB" : "_CS"), outTicket);
      if(ok)
         PrintFormat("[%s] CONFIRMED %s executed | armedLevel=%.5f price=%.5f Lot=%.2f SL=%.5f TP=%.5f",
                     m_name, isBuy ? "BUY" : "SELL", level, price, lot, useS, useT);
      return ok;
     }

   void CancelAll(string reason)
     {
      // [v5.17] RESULT-CHECKED cancel. Previously this fired OrderDelete() and
      // then unconditionally zeroed the tickets - so a [Market closed] rejection
      // at the 03:30 rollover left the order LIVE on the broker but forgotten by
      // the EA (an unretriable orphan that also blocked the new day's placement).
      // Now: only clear a ticket when its delete actually succeeds. If any delete
      // fails, set m_flushOwed so RetryFlush() keeps trying every tick until the
      // market reopens and the pendings are genuinely gone.
      bool allClear = true;

      if(OrderIsLive(m_buyTkt))
        {
         if(m_trade.OrderDelete(m_buyTkt))
           { PrintFormat("[%s] BUY STOP cancelled: %s", m_name, reason); m_buyTkt = 0; }
         else
           {
            allClear = false;
            PrintFormat("[%s] BUY STOP cancel FAILED (%s) rc=%u (%s) - deferring flush",
                        m_name, reason, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
           }
        }
      else m_buyTkt = 0;

      if(OrderIsLive(m_sellTkt))
        {
         if(m_trade.OrderDelete(m_sellTkt))
           { PrintFormat("[%s] SELL STOP cancelled: %s", m_name, reason); m_sellTkt = 0; }
         else
           {
            allClear = false;
            PrintFormat("[%s] SELL STOP cancel FAILED (%s) rc=%u (%s) - deferring flush",
                        m_name, reason, m_trade.ResultRetcode(), m_trade.ResultRetcodeDescription());
           }
        }
      else m_sellTkt = 0;

      // [v5.17] m_placed is cleared ONLY when the book is truly clean. While a
      // flush is still owed, keep m_placed=true so we do not place a fresh set
      // on top of orders that are still live on the broker.
      if(allClear)
        {
         m_placed = false;
         m_flushOwed = false;
        }
      else
        {
         m_flushOwed = true;   // retried by RetryFlush() on every tick
         m_placed    = true;   // block new placement until the orphan is gone
        }
     }

   // [v5.17] Deferred-flush retry. Called every tick from Tick(). When a rollover
   // cancel was rejected (typically [Market closed] during the broker's daily
   // maintenance window), this re-attempts the delete once the market reopens.
   // Only after the book is confirmed clean does it release m_placed so the new
   // day's set can be placed by the existing self-heal paths in OnTick().
   void RetryFlush()
     {
      if(!m_flushOwed) return;

      bool buyLive  = OrderIsLive(m_buyTkt);
      bool sellLive = OrderIsLive(m_sellTkt);

      if(buyLive  && m_trade.OrderDelete(m_buyTkt))
        { PrintFormat("[%s] Deferred flush: BUY STOP cleared",  m_name); m_buyTkt = 0;  buyLive  = false; }
      if(sellLive && m_trade.OrderDelete(m_sellTkt))
        { PrintFormat("[%s] Deferred flush: SELL STOP cleared", m_name); m_sellTkt = 0; sellLive = false; }

      // If a ticket is no longer live at all (filled or cancelled elsewhere),
      // treat it as cleared so we do not wait on a ghost.
      if(!OrderIsLive(m_buyTkt))  m_buyTkt  = 0;
      if(!OrderIsLive(m_sellTkt)) m_sellTkt = 0;

      if(m_buyTkt == 0 && m_sellTkt == 0)
        {
         m_flushOwed = false;
         m_placed    = false;   // book clean -> allow the new day's set to place
         PrintFormat("[%s] Deferred flush COMPLETE - book clean, placement re-enabled", m_name);
        }
     }

   void DayReset()
     {
      // [T] Day-flush toggle: when off, pendings survive rollover (GTC).
      if(InpEnableDayFlush)
         CancelAll("Day reset");
      else
        {
         PrintFormat("[%s] DayFlush OFF: pendings left running; state reset for new day", m_name);
         m_placed = false; // allow a fresh set for the new day
        }
      if(!HasPos()) { m_trailBuy.Reset(); m_trailSell.Reset(); m_inTrade = false; }
     }

   bool IsPlaced() const { return m_placed; }

   // [ASYNC] Routes a TRADE_ACTION_SLTP confirmation (from OnTradeTransaction,
   // via CExpert) to whichever leg tracker sent it. Returns true once matched
   // so the caller can stop checking the other modules.
   bool NotifyModifyResult(ulong ticket, bool success, uint retcode)
     {
      if(m_trailBuy.MatchesTicket(ticket))  { m_trailBuy.OnAsyncModifyResult(success, retcode);  return true; }
      if(m_trailSell.MatchesTicket(ticket)) { m_trailSell.OnAsyncModifyResult(success, retcode); return true; }
      return false;
     }
   bool InTrade()        { return HasPos(); }

   void Tick()
     {
      // [v5.17] Deferred-flush retry FIRST: if a rollover cancel was rejected
      // (e.g. [Market closed]), keep retrying the delete until the orphaned
      // pendings are gone and placement is re-enabled.
      RetryFlush();

      if(InBlackout()) BlackoutGuard();   // [blackout] cancel pendings / flatten inside the daily-open window

      bool hasPos = HasPos();
      if(hasPos)
        {
         if(!m_inTrade)
           {
            // [U2] BEHAVIOR CHANGE: the opposite leg is intentionally NOT
            // deleted here. Both stops remain live after a fill; all
            // pendings are flushed only at day rollover via DayReset().

            // [SB] Fill-time spread guard: LOG/ALERT only (no action). Gold
            // spreads blow out at news/rollover; this records when a fill
            // landed in a bad-spread moment so you can audit slippage.
            if(InpFillSpreadAlert)
              {
               double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
               double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
               double spreadPts = (ask - bid) / g_pt;
               if(InpMaxSpreadPts > 0 && spreadPts > InpMaxSpreadPts)
                 {
                  PrintFormat("[%s] FILL-SPREAD ALERT: filled at spread %.0f pts > max %d (no action taken)",
                              m_name, spreadPts, InpMaxSpreadPts);
                  if(InpEnablePush && MQLInfoInteger(MQL_PROGRAM_TYPE) == PROGRAM_EXPERT)
                     SendNotification(StringFormat("%s filled in wide spread %.0f pts", m_name, spreadPts));
                 }
              }

            m_inTrade = true;
           }

         // [FIX] Scan for BOTH legs every tick (idempotent - each StartTracking
         // call is a no-op once a tracker is already bound to a ticket). This
         // is what lets a second leg fill AFTER the first without ever being
         // silently left un-managed.
         SyncTrailTrackers();

         if(m_trailBuy.IsTracking() && !m_trailBuy.Update())
           {
            PrintFormat("[%s] BUY position closed (ticket=%I64u)", m_name, m_trailBuy.Ticket());
            m_trailBuy.Reset();
           }
         RefreshLegLine(m_trailBuy, "BUY");

         if(m_trailSell.IsTracking() && !m_trailSell.Update())
           {
            PrintFormat("[%s] SELL position closed (ticket=%I64u)", m_name, m_trailSell.Ticket());
            m_trailSell.Reset();
           }
         RefreshLegLine(m_trailSell, "SELL");

         if(!m_trailBuy.IsTracking() && !m_trailSell.IsTracking())
            m_inTrade = false;
        }
      else if(m_inTrade)
        {
         m_trailBuy.Reset();
         m_trailSell.Reset();
         m_inTrade = false;
         RefreshLegLine(m_trailBuy, "BUY");
         RefreshLegLine(m_trailSell, "SELL");
        }
     }
  };

//+------------------------------------------------------------------+
//|  CLASS: CConfirm  (shared 5M-arm / 1M-execute confirmation)      |
//|  One instance per module (4H / PDH / London). Given a fixed high  |
//|  and low it does:                                                 |
//|   1) 5M candle closes beyond the level      -> ARM that side      |
//|   2) the FIRST 1M candle after that 5M close must itself close    |
//|      beyond the level                       -> MARKET order       |
//|      (closes back inside                    -> arm cancelled)     |
//|   3) ONE trade per level: once a confirmed trade has fired on the |
//|      high (or low) it is locked until the level set changes.      |
//|      Lock is rebuilt from deal history, so it survives restarts.  |
//+------------------------------------------------------------------+
class CConfirm
  {
private:
   string   m_tag, m_hiName, m_loName;
   ulong    m_magic;
   double   m_high, m_low;
   datetime m_key;            // identity of the current level set (4H candle open / day open); 0 = no levels
   datetime m_last5M;
   datetime m_armM1;          // open time of the FIRST 1M candle after the arming 5M close
   bool     m_armedBuy, m_armedSell;
   bool     m_usedBuy, m_usedSell;
   double   m_armedLevel;

   // [PATTERN] M1-only consecutive strong-candle confirmation state.
   // Only used when InpEnableCandlePatternConfirm is true; the 5M-arm/1M-execute
   // members and logic above are left completely untouched either way.
   datetime m_patLastM1;     // last processed (closed) 1M bar, so each bar is only counted once
   bool     m_patArmed;      // a pattern sequence is currently in progress
   bool     m_patDirBuy;     // direction of the in-progress sequence (true=buy, false=sell)
   int      m_patCount;      // consecutive qualifying candles counted so far

   // A candle "qualifies" for direction dir (true=buy/bullish, false=sell/bearish) if
   // it closed the right color AND its body is at least InpConfirmBodyPct of its full range.
   bool PatternCandleQualifies(int shift, bool dirBuy)
     {
      double o = iOpen(g_sym, PERIOD_M1, shift);
      double c = iClose(g_sym, PERIOD_M1, shift);
      double h = iHigh(g_sym, PERIOD_M1, shift);
      double l = iLow(g_sym, PERIOD_M1, shift);
      double range = h - l;
      if(range <= 0) return false;                 // no real range to judge - reject rather than divide by zero
      bool colorOk = dirBuy ? (c > o) : (c < o);
      if(!colorOk) return false;
      double bodyPct = MathAbs(c - o) / range * 100.0;
      return (bodyPct >= InpConfirmBodyPct);
     }

   void RunPattern(CSetManager &mgr)
     {
      datetime cur1M = iTime(g_sym, PERIOD_M1, 0);
      if(cur1M <= 0 || cur1M == m_patLastM1) return;   // only act once per newly-closed 1M bar
      m_patLastM1 = cur1M;

      double closePrev = iClose(g_sym, PERIOD_M1, 1);  // the bar that JUST closed
      bool   locked     = InpConfirmOneTradePerCandle && (m_usedBuy || m_usedSell);

      if(!m_patArmed)
        {
         if(mgr.InTrade()) return;                     // don't start a new sequence while already in a trade
         if(closePrev > m_high && !m_usedBuy && !locked && PatternCandleQualifies(1, true))
           {
            m_patArmed = true; m_patDirBuy = true; m_patCount = 1;
            PrintFormat("[%s-PATTERN] Strong bullish candle #1/%d above %s %.5f - watching for continuation",
                        m_tag, InpConfirmCandleCount, m_hiName, m_high);
           }
         else if(closePrev < m_low && !m_usedSell && !locked && PatternCandleQualifies(1, false))
           {
            m_patArmed = true; m_patDirBuy = false; m_patCount = 1;
            PrintFormat("[%s-PATTERN] Strong bearish candle #1/%d below %s %.5f - watching for continuation",
                        m_tag, InpConfirmCandleCount, m_loName, m_low);
           }
        }
      else
        {
         if(PatternCandleQualifies(1, m_patDirBuy))
           {
            m_patCount++;
            PrintFormat("[%s-PATTERN] Strong %s candle #%d/%d", m_tag, m_patDirBuy ? "bullish" : "bearish",
                        m_patCount, InpConfirmCandleCount);
            if(m_patCount >= InpConfirmCandleCount)
              {
               if(mgr.ExecuteConfirmedMarket(m_patDirBuy, m_armedLevel))
                 {
                  if(m_patDirBuy) m_usedBuy = true; else m_usedSell = true;
                 }
               m_patArmed = false; m_patCount = 0;
              }
           }
         else
           {
            PrintFormat("[%s-PATTERN] Sequence broken (wrong color or weak body) after %d/%d - cancelled",
                        m_tag, m_patCount, InpConfirmCandleCount);
            m_patArmed = false; m_patCount = 0;
           }
        }
     }

   void LoadUsedFromHistory(datetime since)
     {
      m_usedBuy = false; m_usedSell = false;
      if(!HistorySelect(since, TimeCurrent() + 60)) return;
      int n = HistoryDealsTotal();
      for(int i = 0; i < n; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != g_sym) continue;
         if((ulong)HistoryDealGetInteger(d, DEAL_MAGIC) != m_magic) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
         long type = HistoryDealGetInteger(d, DEAL_TYPE);
         if(type == DEAL_TYPE_BUY)  m_usedBuy  = true;
         if(type == DEAL_TYPE_SELL) m_usedSell = true;
        }
      if(InpDebug && (m_usedBuy || m_usedSell))
         PrintFormat("[%s] Restored used-level lock from history | %s traded=%s %s traded=%s",
                     m_tag, m_hiName, m_usedBuy ? "true" : "false", m_loName, m_usedSell ? "true" : "false");
     }

public:
   CConfirm() : m_tag(""), m_hiName("high"), m_loName("low"), m_magic(0), m_high(0), m_low(0), m_key(0),
                m_last5M(0), m_armM1(0), m_armedBuy(false), m_armedSell(false),
                m_usedBuy(false), m_usedSell(false), m_armedLevel(0),
                m_patLastM1(0), m_patArmed(false), m_patDirBuy(false), m_patCount(0) {}

   void Init(string tag, ulong magic, string hiName, string loName)
     { m_tag = tag; m_magic = magic; m_hiName = hiName; m_loName = loName; }

   void Clear()
     {
      m_key = 0; m_high = 0; m_low = 0;
      m_armedBuy = false; m_armedSell = false;
      m_usedBuy = false;  m_usedSell = false;
      m_patArmed = false; m_patCount = 0;
     }

   // Call every tick with the current levels. Does nothing unless the key or
   // levels changed; a change starts a fresh level set (arms dropped, lock
   // re-read from deal history since usedSince).
   void SetLevels(double hi, double lo, datetime key, datetime usedSince)
     {
      if(key == m_key && hi == m_high && lo == m_low) return;
      m_high = hi; m_low = lo; m_key = key;
      m_armedBuy = false; m_armedSell = false;
      m_patArmed = false; m_patCount = 0;   // [PATTERN] fresh level set drops any in-progress sequence too
      LoadUsedFromHistory(usedSince);
      if(InpDebug) PrintFormat("[%s] New level | %s=%.5f %s=%.5f", m_tag, m_hiName, hi, m_loName, lo);
     }

   void Run(CSetManager &mgr)
     {
      if(m_key == 0) return;

      // [PATTERN] When enabled, this completely replaces the 5M-arm/1M-execute
      // logic below with the M1-only consecutive strong-candle sequence.
      if(InpEnableCandlePatternConfirm)
        {
         RunPattern(mgr);
         return;
        }

      // Step 1: 5M close beyond the level arms that side.
      datetime cur5M = iTime(g_sym, PERIOD_M5, 0);
      if(cur5M > 0 && cur5M != m_last5M)
        {
         m_last5M = cur5M;
         if(!m_armedBuy && !m_armedSell && !mgr.InTrade())
           {
            double close5M = iClose(g_sym, PERIOD_M5, 1);
            bool locked = InpConfirmOneTradePerCandle && (m_usedBuy || m_usedSell);
            if(close5M > m_high)
              {
               if(m_usedBuy || locked)
                 { if(InpDebug) PrintFormat("[%s] BUY on %s %.5f already traded - skipped", m_tag, m_hiName, m_high); }
               else
                 {
                  m_armedBuy = true; m_armedLevel = m_high; m_armM1 = cur5M;
                  PrintFormat("[%s] 5M confirmed BUY: closed %.5f above %s %.5f - waiting for 1M close",
                              m_tag, close5M, m_hiName, m_high);
                 }
              }
            else if(close5M < m_low)
              {
               if(m_usedSell || locked)
                 { if(InpDebug) PrintFormat("[%s] SELL on %s %.5f already traded - skipped", m_tag, m_loName, m_low); }
               else
                 {
                  m_armedSell = true; m_armedLevel = m_low; m_armM1 = cur5M;
                  PrintFormat("[%s] 5M confirmed SELL: closed %.5f below %s %.5f - waiting for 1M close",
                              m_tag, close5M, m_loName, m_low);
                 }
              }
           }
        }

      // Step 2: the FIRST 1M candle after the arming 5M close (it opens at the same
      // time as the new 5M candle) must itself close beyond the level. Wait until
      // that candle has finished, read ITS close, then execute or cancel.
      if(m_armedBuy || m_armedSell)
        {
         datetime cur1M = iTime(g_sym, PERIOD_M1, 0);
         if(cur1M > 0 && m_armM1 > 0 && cur1M > m_armM1)
           {
            int sh1M = iBarShift(g_sym, PERIOD_M1, m_armM1, true);
            if(sh1M < 1)
              {
               PrintFormat("[%s] 1M confirmation candle %s not found - arm cancelled",
                           m_tag, TimeToString(m_armM1, TIME_DATE|TIME_MINUTES));
               m_armedBuy = false; m_armedSell = false;
              }
            else
              {
               double close1M = iClose(g_sym, PERIOD_M1, sh1M);
               PrintFormat("[%s] 1M candle %s closed at %.5f (level %.5f)",
                           m_tag, TimeToString(m_armM1, TIME_DATE|TIME_MINUTES), close1M, m_armedLevel);
               if(m_armedBuy)
                 {
                  if(close1M > m_armedLevel)
                    {
                     if(mgr.ExecuteConfirmedMarket(true, m_armedLevel))
                        m_usedBuy = true;    // lock the high
                    }
                  else
                     PrintFormat("[%s] 1M closed back below level (%.5f) - BUY cancelled", m_tag, m_armedLevel);
                  m_armedBuy = false;
                 }
               else if(m_armedSell)
                 {
                  if(close1M < m_armedLevel)
                    {
                     if(mgr.ExecuteConfirmedMarket(false, m_armedLevel))
                        m_usedSell = true;   // lock the low
                    }
                  else
                     PrintFormat("[%s] 1M closed back above level (%.5f) - SELL cancelled", m_tag, m_armedLevel);
                  m_armedSell = false;
                 }
              }
           }
        }
     }
  };

//+------------------------------------------------------------------+
//|  MAIN EXPERT                                                     |
//+------------------------------------------------------------------+
class CExpert
  {
private:
   CSetManager m_pdh;
   CSetManager m_ldn;
   CSetManager m_h4;              // [4H] 4H candle high/low set
   datetime m_last4HBar;          // [4H] open-time of the 4H candle we last acted on (new-candle detection)
   datetime m_h4PlacedCandle;     // [4H] candle we have already placed a straddle for (prevents re-placement mid-candle)

   // [CONFIRM] Shared 5M-arm / 1M-execute engines, one per module. Only used
   // when the matching InpEnable*Confirmation toggle is on.
   CConfirm m_cf4H, m_cfPDH, m_cfLDN;
   datetime m_cfH4Candle;            // which 4H candle the 4H engine's levels belong to

   int      m_lastDay;
   datetime m_lastD1Open;
   double   m_pdHigh, m_pdLow;
   bool     m_ldnPlaced, m_ldnInSession, m_ldnHasData;
   bool     m_ldnSessionDone; // [U6] set once session closes with data; drives per-tick placement retry
   double   m_ldnHigh, m_ldnLow;

   string   GVDayName() { return "PDHPDL_LASTDAY_" + g_sym; }

   int      BrokerHour() { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt.hour; }
   int      TodayInt()   { MqlDateTime dt; TimeToStruct(TimeCurrent(), dt); return dt.year*10000 + dt.mon*100 + dt.day; }

   bool     NewDay()
     {
      int      today  = TodayInt();
      datetime d1open = iTime(g_sym, PERIOD_D1, 0);
      if(today == m_lastDay && d1open == m_lastD1Open) return false;
      if(InpEnableGVPersist && !(bool)MQLInfoInteger(MQL_TESTER) && GlobalVariableCheck(GVDayName()))
        {
         int persisted = (int)GlobalVariableGet(GVDayName());
         if(persisted == today && m_lastDay == -1)
           {
            m_lastDay = today; m_lastD1Open = d1open;
            if(InpDebug) PrintFormat("[Day] Reinit same day %d - no reset", today);
            return false;
           }
        }
      m_lastDay = today; m_lastD1Open = d1open;
      if(InpEnableGVPersist && !(bool)MQLInfoInteger(MQL_TESTER)) GlobalVariableSet(GVDayName(), today); // [T] persistence toggle; skipped in tester to keep runs clean
      PrintFormat("[Day] NEW DAY %d (D1 open %s)", today, TimeToString(d1open, TIME_DATE));
      return true;
     }

   bool     GetPDH_PDL(double &pdh, double &pdl)
     {
      MqlRates d1[3];
      if(CopyRates(g_sym, PERIOD_D1, 0, 3, d1) < 3) return false;
      pdh = d1[1].high; pdl = d1[1].low;
      bool ok = (pdh > pdl && pdh > 0);
      if(ok) PrintFormat("[PDH/PDL] PDH=%.5f PDL=%.5f Range=%.5f", pdh, pdl, pdh - pdl);
      return ok;
     }

   // [4H] Read the PREVIOUS completed 4H candle's high/low (shift 1), exactly
   // as GetPDH_PDL reads the previous completed daily candle. Never the forming
   // candle (shift 0), so levels don't move while the candle builds.
   bool     GetH4(double &h4high, double &h4low)
     {
      MqlRates h4[3];
      if(CopyRates(g_sym, PERIOD_H4, 0, 3, h4) < 3) return false;
      h4high = h4[1].high; h4low = h4[1].low;
      bool ok = (h4high > h4low && h4high > 0);
      if(ok)
        {
         PrintFormat("[4H] H4High=%.5f H4Low=%.5f Range=%.5f", h4high, h4low, h4high - h4low);
         DrawH4Levels(h4high, h4low, h4[1].time);   // [H4LINES]
        }
      return ok;
     }

   void     TrackLondonSession()
     {
      MqlRates m1[1];
      if(CopyRates(g_sym, PERIOD_M1, 0, 1, m1) < 1) return;
      if(!m_ldnHasData)
        {
         m_ldnHigh = m1[0].high; m_ldnLow = m1[0].low; m_ldnHasData = true;
         if(InpDebug) PrintFormat("[London] tracking start H=%.5f L=%.5f", m_ldnHigh, m_ldnLow);
        }
      else
        {
         if(m1[0].high > m_ldnHigh) m_ldnHigh = m1[0].high;
         if(m1[0].low  < m_ldnLow)  m_ldnLow  = m1[0].low;
        }
     }

   bool     ReconstructLondonFromHistory(bool &sessionOver)
     {
      sessionOver = false;
      MqlRates m1[];
      int copied = CopyRates(g_sym, PERIOD_M1, 0, 1440, m1);
      if(copied <= 0) return false;
      int today = TodayInt();
      double hi = 0, lo = DBL_MAX; bool found = false; int lastQualHour = -1;
      for(int i = 0; i < copied; i++)
        {
         MqlDateTime dt; TimeToStruct(m1[i].time, dt);
         int barDay = dt.year*10000 + dt.mon*100 + dt.day;
         if(barDay != today) continue;
         if(!InSession(dt.hour, g_ldn.sessionStartBroker, g_ldn.sessionEndBroker)) continue;
         if(m1[i].high > hi) hi = m1[i].high;
         if(m1[i].low  < lo) lo = m1[i].low;
         found = true; lastQualHour = dt.hour;
        }
      if(!found) return false;
      m_ldnHigh = hi; m_ldnLow = lo; m_ldnHasData = true;
      sessionOver = !InSession(BrokerHour(), g_ldn.sessionStartBroker, g_ldn.sessionEndBroker);
      PrintFormat("[London] Reconstructed H=%.5f L=%.5f lastHour=%d over=%s",
                  hi, lo, lastQualHour, sessionOver ? "true" : "false");
      return true;
     }

public:
   CExpert() : m_last4HBar(0), m_h4PlacedCandle(0),
               m_cfH4Candle(0),
               m_lastDay(-1), m_lastD1Open(0), m_pdHigh(0), m_pdLow(0),
               m_ldnPlaced(false), m_ldnInSession(false), m_ldnHasData(false),
               m_ldnSessionDone(false),
               m_ldnHigh(0), m_ldnLow(DBL_MAX) {}

   bool Init()
     {
      m_pdh.Init(InpMagicPDH, "PDH");
      m_ldn.Init(InpMagicLDN, "London");
      m_h4.Init(InpMagic4H, "4H");
      m_cf4H.Init("4H-CONFIRM",  InpMagic4H,  "4H high", "4H low");
      m_cfPDH.Init("PDH-CONFIRM", InpMagicPDH, "PDH",     "PDL");
      m_cfLDN.Init("LDN-CONFIRM", InpMagicLDN, "LSH",     "LSL");

      if(InpEnablePDH)    m_pdh.RecoverFromBroker();
      if(InpEnableLondon) m_ldn.RecoverFromBroker();
      if(InpEnable4H)     m_h4.RecoverFromBroker();

      m_lastDay    = TodayInt();
      m_lastD1Open = iTime(g_sym, PERIOD_D1, 0);
      if(InpEnableGVPersist && !(bool)MQLInfoInteger(MQL_TESTER) && !GlobalVariableCheck(GVDayName()))
         GlobalVariableSet(GVDayName(), m_lastDay);

      if(GetPDH_PDL(m_pdHigh, m_pdLow))
        {
         if(InpEnablePDH && !InpEnablePDHConfirmation && !m_pdh.IsPlaced())
            m_pdh.Place(m_pdHigh, m_pdLow);
        }

      if(InpEnableLondon)
        {
         bool sessionOver = false;
         if(InpEnableLdnRebuild && ReconstructLondonFromHistory(sessionOver))
           {
            if(sessionOver && !InpEnableLDNConfirmation && !m_ldn.IsPlaced())
              {
               PrintFormat("[London] Restart after session close - placing from reconstructed range");
               if(m_ldn.Place(m_ldnHigh, m_ldnLow)) m_ldnPlaced = true;
              }
            else if(sessionOver && m_ldn.IsPlaced())
               m_ldnPlaced = true;
            // [CONFIRM-ALL] London confirmation trades from the reconstructed range once the session is over
            if(sessionOver && InpEnableLDNConfirmation)
               m_ldnSessionDone = true;
           }
        }

      // [4H] On attach: place this candle's straddle from the previous completed
      // 4H candle, and mark the candle so the tick loop won't double-place.
      // [CONFIRM] Skipped entirely when InpEnable4HConfirmation is on - the
      // confirmation path (OnTick) picks up the current 4H level on its own
      // first tick instead of placing anything immediately.
      if(InpEnable4H && !InpEnable4HConfirmation)
        {
         datetime c4 = iTime(g_sym, PERIOD_H4, 0);
         m_last4HBar = c4;
         double h4h, h4l;
         if(GetH4(h4h, h4l) && !m_h4.IsPlaced())
           {
            if(m_h4.Place(h4h, h4l))
               m_h4PlacedCandle = c4;
           }
         else if(m_h4.IsPlaced())
            m_h4PlacedCandle = c4;
        }

      UpdateVisuals(m_pdHigh, m_pdLow,
                    m_ldnHasData ? m_ldnHigh : 0,
                    m_ldnHasData ? m_ldnLow  : 0);
      return true;
     }

   // [ASYNC] Routes a TRADE_ACTION_SLTP confirmation to whichever module
   // (PDH/London/4H) owns that ticket.
   void NotifyModifyResult(ulong ticket, bool success, uint retcode)
     {
      if(m_pdh.NotifyModifyResult(ticket, success, retcode)) return;
      if(m_ldn.NotifyModifyResult(ticket, success, retcode)) return;
      m_h4.NotifyModifyResult(ticket, success, retcode);
     }

   void OnTick()
     {
      int h = BrokerHour();

      // [RG] Evaluate account-level limits FIRST, every tick. If a limit is
      // breached this closes/halts before any new strategy action below.
      g_risk.OnTick();

      if(NewDay())
        {
         g_risk.OnNewDay(); // [RG] re-anchor daily equity; clears daily halt
         if(InpEnablePDH)    m_pdh.DayReset();
         if(InpEnableLondon) m_ldn.DayReset();
         m_ldnPlaced = false; m_ldnInSession = false; m_ldnHasData = false;
         m_ldnSessionDone = false;
         m_ldnHigh = 0; m_ldnLow = DBL_MAX;

         // (levels are always refreshed; the straddle is skipped in confirmation mode)
         if(InpEnablePDH && GetPDH_PDL(m_pdHigh, m_pdLow) && !InpEnablePDHConfirmation)
            m_pdh.Place(m_pdHigh, m_pdLow);

         UpdateVisuals(m_pdHigh, m_pdLow, 0, 0);
        }

      // [U5] London master switch: skip all session logic when off.
      if(InpEnableLondon)
        {
         bool inSession = InSession(h, g_ldn.sessionStartBroker, g_ldn.sessionEndBroker);
         if(inSession)
           {
            TrackLondonSession();
            m_ldnInSession = true;
           }
         else
           {
            // [U6] On the in->out session transition, LATCH the "session done"
            // state once (only if we actually tracked a range). We no longer
            // gate placement on the transient m_ldnInSession edge flag, so a
            // failed Place() no longer permanently locks London out for the day.
            if(m_ldnInSession && m_ldnHasData && !m_ldnSessionDone)
              {
               m_ldnSessionDone = true;
               PrintFormat("[London] Session closed | LSH=%.5f | LSL=%.5f", m_ldnHigh, m_ldnLow);
              }
            m_ldnInSession = false;
           }

         // [U6] Per-tick placement RETRY (mirrors PDH self-heal on line below).
         // Once the session has closed with a valid range, keep attempting to
         // place LDH/LDL until the set manager confirms placement (IsPlaced()).
         // This guarantees the 4-order intent holds even if the first attempt
         // is deferred (market-closed, wide spread, transient broker error).
         if(m_ldnSessionDone && m_ldnHasData && !InpEnableLDNConfirmation && !m_ldn.IsPlaced())
           {
            if(m_ldn.Place(m_ldnHigh, m_ldnLow))
              {
               m_ldnPlaced = true;
               UpdateVisuals(m_pdHigh, m_pdLow, m_ldnHigh, m_ldnLow);
              }
           }
        }

      // Retry a deferred PDH placement (e.g. it was skipped while market
      // was closed at rollover): if PDH is enabled, has levels, and hasn't
      // placed yet today, attempt again now.
      if(InpEnablePDH && !InpEnablePDHConfirmation && !m_pdh.IsPlaced() && m_pdHigh > 0 && m_pdLow > 0)
         m_pdh.Place(m_pdHigh, m_pdLow);

      //=== [4H] STRICT ONE-CYCLE-PER-CANDLE ==========================
      // At the start of each new 4H candle, place a fresh buy-stop (previous
      // candle high) + sell-stop (previous candle low). Then:
      //   Case 1 (neither filled): cancelled & replaced at next candle.
      //   Case 2 (one filled):     the other leg stays LIVE until it fills or
      //                            the candle closes; NO new orders this candle.
      //   Case 3 (both filled):    done; wait for next candle.
      // Placement happens exactly ONCE per candle (tracked by m_h4PlacedCandle),
      // so a mid-candle fill/close never spawns a new straddle.
      if(InpEnable4H && !InpEnable4HConfirmation)
        {
         datetime cur4H = iTime(g_sym, PERIOD_H4, 0);
         bool h4Open = m_h4.InTrade();   // a 4H position is currently open

         bool newCandle = (cur4H != m_last4HBar && cur4H > 0);
         if(newCandle && !h4Open)
           {
            // New candle, no carried-over position: clear the previous candle's
            // leftover un-triggered legs before placing this candle's straddle.
            m_h4.CancelAll("new 4H candle");
           }
         if(cur4H > 0) m_last4HBar = cur4H;

         // Place once per candle. Independent of book state, so after both legs
         // fill (Case 3) and the book empties mid-candle, we do NOT re-place.
         if(cur4H > 0 && cur4H != m_h4PlacedCandle && !h4Open)
           {
            double h4h, h4l;
            if(GetH4(h4h, h4l))
              {
               if(m_h4.Place(h4h, h4l))
                  m_h4PlacedCandle = cur4H;
              }
           }
        }
      //===============================================================

      //=== [CONFIRM] 5M-arm / 1M-execute confirmation entries ==========
      // Each module feeds its levels to a CConfirm engine (see class above).
      // 4H : high/low of the last CLOSED 4H candle (fresh set every 4H candle).
      // PDH: previous day's high/low (fresh set every day).
      // LDN: London session high/low, once the session has closed (fresh set every day).
      if(InpEnable4H && InpEnable4HConfirmation)
        {
         datetime cur4H = iTime(g_sym, PERIOD_H4, 0);
         if(cur4H > 0 && cur4H != m_cfH4Candle)
           {
            double h4h, h4l;
            if(GetH4(h4h, h4l))
              {
               m_cf4H.SetLevels(h4h, h4l, cur4H, cur4H);
               m_cfH4Candle = cur4H;
              }
           }
         m_cf4H.Run(m_h4);
        }

      if(InpEnablePDH && InpEnablePDHConfirmation)
        {
         datetime d1 = iTime(g_sym, PERIOD_D1, 0);
         if(d1 > 0 && m_pdHigh > 0 && m_pdLow > 0)
            m_cfPDH.SetLevels(m_pdHigh, m_pdLow, d1, d1);
         m_cfPDH.Run(m_pdh);
        }

      if(InpEnableLondon && InpEnableLDNConfirmation)
        {
         datetime d1 = iTime(g_sym, PERIOD_D1, 0);
         if(d1 > 0 && m_ldnSessionDone && m_ldnHasData && m_ldnHigh > m_ldnLow)
            m_cfLDN.SetLevels(m_ldnHigh, m_ldnLow, d1, d1);
         else
            m_cfLDN.Clear();
         m_cfLDN.Run(m_ldn);
        }
      //===============================================================

      if(InpEnablePDH)    m_pdh.Tick();
      if(InpEnableLondon) m_ldn.Tick();
      if(InpEnable4H)     m_h4.Tick();
     }
  };

//+------------------------------------------------------------------+
CExpert *g_expert = NULL;

void LogToggles()
  {
   PrintFormat("[Config] PDH=%s London=%s 4H=%s (%s) Trailing=%s Recovery=%s Retry=%s SuffixSearch=%s Visuals=%s AutoLot=%s Debug=%s",
               InpEnablePDH?"ON":"OFF", InpEnableLondon?"ON":"OFF", InpEnable4H?"ON":"OFF",
               InpEnable4HConfirmation ? "5M-arm/1M-execute confirmation, MARKET entry" : "one-cycle-per-candle straddle, PENDING stops",
               InpEnableTrailing?"ON":"OFF",
               InpEnableRecovery?"ON":"OFF", InpEnableRetry?"ON":"OFF", InpEnableSuffixSearch?"ON":"OFF",
               InpEnableVisuals?"ON":"OFF", InpAutoLot?"ON":"OFF", InpDebug?"ON":"OFF");
   PrintFormat("[Config] Confirmation entry (5M arm + 1M execute): 4H=%s PDH=%s London=%s | OneTradeTotalPerSet=%s",
               InpEnable4HConfirmation?"ON":"OFF", InpEnablePDHConfirmation?"ON":"OFF",
               InpEnableLDNConfirmation?"ON":"OFF", InpConfirmOneTradePerCandle?"ON":"OFF");
   PrintFormat("[Config] RiskGov=%s (daily %.1f%%/overall %.1f%%, closeOnBreach=%s, haltMode=%s) | SpreadBuffer=%s (x%.2f) | FillSpreadAlert=%s",
               InpEnableRiskGov?"ON":"OFF", InpDailyLossPct, InpMaxDrawdownPct, InpCloseAllOnBreach?"YES":"NO",
               InpGovHaltMode==GOV_PERMANENT?"PERMANENT":InpGovHaltMode==GOV_PAUSE_DAYS?"PAUSE":"LOG_ONLY",
               InpEnableSpreadBuffer?"ON":"OFF", InpSpreadBufferMult, InpFillSpreadAlert?"ON":"OFF");
   PrintFormat("[Config] SimSpread(tester-only)=%s @ %.0f pts | ACTIVE NOW=%s",
               InpSimSpreadTester?"ON":"OFF", InpSimSpreadPts,
               (InpSimSpreadTester && InpSimSpreadPts > 0 && MQLInfoInteger(MQL_TESTER))?"YES":"NO");
   int bwS, bwE;
   BlackoutWindow(bwS, bwE);
   PrintFormat("[Config] Blackout=%s window=%02d:%02d-%02d:%02d server time (close %02d:%02d -%dm, reopen %02d:%02d +%dm), flatten=%s",
               InpEnableBlackout?"ON":"OFF",
               bwS/60, bwS%60, bwE/60, bwE%60,
               InpBreakCloseHour, InpBreakCloseMin, InpBlackoutBeforeMin,
               InpBreakOpenHour, InpBreakOpenMin, InpBlackoutAfterMin,
               InpBlackoutFlatten?"YES":"NO");
   PrintFormat("[Config] BE=%s TP=%s BuyLegs=%s SellLegs=%s Push=%s DayFlush=%s LdnRebuild=%s RiskDevChk=%s DupScan=%s GVPersist=%s",
               InpEnableBreakEven?"ON":"OFF", InpEnableTP?"ON":"OFF", InpEnableBuyLegs?"ON":"OFF",
               InpEnableSellLegs?"ON":"OFF", InpEnablePush?"ON":"OFF", InpEnableDayFlush?"ON":"OFF",
               InpEnableLdnRebuild?"ON":"OFF", InpEnableRiskDevChk?"ON":"OFF", InpEnableDupScan?"ON":"OFF",
               InpEnableGVPersist?"ON":"OFF");
   PrintFormat("[Config] DANGER-ZONE: StopLevelChk=%s SessionChk=%s HardStops=%s%s",
               InpEnableStopLevelChk?"ON":"OFF", InpEnableSessionChk?"ON":"OFF", InpEnableHardStops?"ON":"OFF",
               (!InpEnableStopLevelChk || !InpEnableSessionChk || !InpEnableHardStops) ?
               "  *** WARNING: safety features disabled - NOT RECOMMENDED ***" : "");
  }

int OnInit()
  {
   CacheSymbol();
   g_ldn = CalcLondonSessionHours();
   LogToggles();
   PrintFormat("[Init] BE=%.0f Act=%.0f Trail=%.0f RiskPct=%.1f%% (per leg, balance base)",
               InpBreakEvenPts, InpTrailActivatePts, InpTrailDist, InpRiskPct);

   g_risk.Init();     // [RG] restore/seed anchors + high-water mark
   g_risk.LogState();

   g_expert = new CExpert();
   if(!g_expert) return INIT_FAILED;
   if(!g_expert.Init()) { delete g_expert; g_expert=NULL; return INIT_FAILED; }

   PrintFormat("[TF] Chart period=%s | Operation is tick-driven and timeframe-independent "
               "(all price reads use explicit PERIOD_D1/PERIOD_M1). Attach on any TF.",
               EnumToString((ENUM_TIMEFRAMES)_Period));
   Print("[Init] EA Ready (v5.24 + daily-open blackout).");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_risk.LogSummary(); // [TG] end-of-run breach tally (tester verdict line)
   DeleteAllVisuals();
   if(g_expert) { delete g_expert; g_expert=NULL; }
  }

void OnTick() { if(g_expert) g_expert.OnTick(); }

//+------------------------------------------------------------------+
//| [4H] Execution logging. Records every fill and close for this     |
//| symbol so the Experts log shows whether an order triggered        |
//| ([EXEC] FILL) or closed ([EXEC] CLOSE) - previously invisible.    |
//| Pure logging: takes no trading action.                            |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult  &result)
  {
   // [ASYNC] Confirmation for an async trailing SL modify (TRADE_ACTION_SLTP)
   // arrives here as TRADE_TRANSACTION_REQUEST, carrying the real
   // accept/reject retcode that async PositionModify() couldn't return
   // immediately. Handled first and separately - does not touch the
   // existing DEAL_ADD fill/close logging below at all.
   if(trans.type == TRADE_TRANSACTION_REQUEST)
     {
      if(request.action == TRADE_ACTION_SLTP && g_expert != NULL)
        {
         bool ok = (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_DONE_PARTIAL);
         g_expert.NotifyModifyResult(request.position, ok, result.retcode);
        }
      return;
     }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.symbol != g_sym) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long   entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   long   dtype  = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   double price  = HistoryDealGetDouble (trans.deal, DEAL_PRICE);
   double vol    = HistoryDealGetDouble (trans.deal, DEAL_VOLUME);
   double profit = HistoryDealGetDouble (trans.deal, DEAL_PROFIT);
   long   magic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   string dir    = (dtype == DEAL_TYPE_BUY) ? "BUY" : (dtype == DEAL_TYPE_SELL) ? "SELL" : "?";

   if(entry == DEAL_ENTRY_IN)
      PrintFormat("[EXEC] FILL  %s %.2f @ %.5f | magic=%I64d | ticket=%I64u",
                  dir, vol, price, magic, trans.deal);
   else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
      PrintFormat("[EXEC] CLOSE %s %.2f @ %.5f | profit=%.2f | magic=%I64d | ticket=%I64u",
                  dir, vol, price, profit, magic, trans.deal);
  }
//+------------------------------------------------------------------+