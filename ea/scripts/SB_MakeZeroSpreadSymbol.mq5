//+------------------------------------------------------------------+
//|                  SB_MakeZeroSpreadSymbol.mq5                      |
//|                                                                  |
//|  Script: makes a CUSTOM SYMBOL that is an exact copy of the chart |
//|  symbol (same bid prices, same times, same contract settings)     |
//|  but with NO SPREAD at all: every tick ask = bid, every M1 bar    |
//|  spread = 0. Use it to see the EA's pure price edge without any   |
//|  spread cost. Backtest the EA on the new symbol with              |
//|  "Every tick based on real ticks".                                |
//|                                                                  |
//|  Use: open a chart of the source symbol (e.g. XAUUSD.T), drag     |
//|  this script on it, set the dates, OK. It copies one day at a     |
//|  time (progress in the chart corner). The new symbol is added to  |
//|  Market Watch, e.g. XAUUSD.T_S0.                                  |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout - zero spread copy"
#property version   "1.00"
#property script_show_inputs

input datetime InpFrom   = D'2022.04.01';   // Copy from (server date)
input datetime InpTo     = D'2026.10.02';   // Copy to (server date)
input string   InpSuffix = "_S0";           // New symbol suffix
input bool     InpResume = true;            // Symbol already exists: continue from its last copied day

void OnStart()
  {
   string src = _Symbol;
   if(StringFind(SymbolInfoString(src, SYMBOL_PATH), "Custom\\SB") == 0)
     {
      Alert(src, " is a copy made by an SB script. Run it on the ORIGINAL symbol's chart (e.g. XAUUSD.T), not on ", src, ".");
      return;
     }
   if(InpSuffix == "") { Alert("Suffix must not be empty"); return; }
   string dst = src + InpSuffix;

   // 1) create the custom symbol as a copy of the source (contract size, digits, sessions, margin...)
   bool isCustom = false;
   bool exists   = SymbolExist(dst, isCustom);
   if(exists && !isCustom) { Alert(dst, " already exists as a broker symbol - choose another suffix"); return; }
   if(!exists && !CustomSymbolCreate(dst, "Custom\\SB", src))
     { Alert("CustomSymbolCreate failed, error ", GetLastError()); return; }
   CustomSymbolSetInteger(dst, SYMBOL_SPREAD_FLOAT, false);
   CustomSymbolSetInteger(dst, SYMBOL_SPREAD, 0);
   CustomSymbolSetString(dst, SYMBOL_DESCRIPTION, src + " copy, zero spread (ask = bid)");
   PrintFormat("Copying %s -> %s  %s .. %s  zero spread", src, dst,
               TimeToString(InpFrom, TIME_DATE), TimeToString(InpTo, TIME_DATE));

   long   totalTicks = 0;
   double origSprSum = 0;
   double pt = SymbolInfoDouble(src, SYMBOL_POINT);
   int    daysDone = 0, daysEmpty = 0;
   datetime failedDay = 0;
   datetime start = (datetime)((long)InpFrom - (long)InpFrom % 86400);
   if(exists && InpResume)
     {
      datetime lastBar = (datetime)SeriesInfoInteger(dst, PERIOD_M1, SERIES_LASTBAR_DATE);
      if(lastBar > start)
        {
         start = (datetime)((long)lastBar - (long)lastBar % 86400);   // re-copy the last day (it may be incomplete)
         PrintFormat("%s already has data up to %s - continuing from %s", dst, TimeToString(lastBar), TimeToString(start, TIME_DATE));
        }
     }
   double totalDays = MathMax(1.0, (double)(InpTo - start) / 86400.0);

   for(datetime day = start; day < InpTo && !IsStopped(); day += 86400)
     {
      // 2) M1 bars of the day (bid prices unchanged, spread 0)
      MqlRates rates[];
      int nr = CopyRates(src, PERIOD_M1, day, day + 86399, rates);
      if(nr > 0)
        {
         for(int i = 0; i < nr; i++) rates[i].spread = 0;
         CustomRatesReplace(dst, day, day + 86399, rates);
        }

      // 3) ticks of the day: same bid, ask = bid
      MqlTick ticks[];
      ulong from_msc = (ulong)day * 1000, to_msc = (ulong)(day + 86400) * 1000 - 1;
      // big custom-symbol histories (Tickstory, Dukascopy) can need many seconds to load one day:
      // keep asking for up to ~60 s instead of skipping the day and leaving a hole in the copy
      int nt = -1, err = 0;
      for(int tries = 0; tries < 60 && nt < 0 && !IsStopped(); tries++)
        {
         ResetLastError();
         nt = CopyTicksRange(src, ticks, COPY_TICKS_ALL, from_msc, to_msc);
         if(nt < 0) { err = GetLastError(); Sleep(1000); }
        }
      if(nt < 0)
        {
         if(IsStopped()) break;
         failedDay = day;
         PrintFormat("%s: ticks of %s could not be loaded in 60 s (error %d) - stopping so this day is not skipped",
                     TimeToString(day, TIME_DATE), src, err);
         break;
        }
      if(nt == 0) { daysEmpty++; continue; }
      int kept = 0;
      for(int i = 0; i < nt; i++)
        {
         if(ticks[i].bid <= 0) continue;
         if(ticks[i].ask > 0) origSprSum += (ticks[i].ask - ticks[i].bid) / pt;
         ticks[kept]       = ticks[i];
         ticks[kept].ask   = ticks[i].bid;
         ticks[kept].flags = TICK_FLAG_BID | TICK_FLAG_ASK;
         kept++;
        }
      if(kept == 0) { daysEmpty++; continue; }
      if(CustomTicksReplace(dst, (long)from_msc, (long)to_msc, ticks, kept) < 0)
         PrintFormat("CustomTicksReplace failed for %s, error %d", TimeToString(day, TIME_DATE), GetLastError());
      totalTicks += kept;
      daysDone++;
      if(daysDone % 10 == 0)
         Comment(StringFormat("Copying %s -> %s : %s  %.0f%% done (%d days, %I64d ticks). Keep this chart open until the DONE message.",
                              src, dst, TimeToString(day, TIME_DATE), 100.0 * (double)(day - start) / 86400.0 / totalDays,
                              daysDone, totalTicks));
     }
   Comment("");
   SymbolSelect(dst, true);
   if(failedDay > 0)
     {
      Alert(StringFormat("PAUSED at %s: MT5 did not deliver the ticks of %s in time. Run the script again with Resume = true - "
                         "it retries this day (the data is usually loaded by then).", TimeToString(failedDay, TIME_DATE), src));
      return;
     }
   if(IsStopped())
     {
      Alert("STOPPED before the end (the chart was closed / changed, or another script was dropped on it) - "
            "run the script again ONCE with Resume = true to continue from where it stopped.");
      return;
     }
   string msg = StringFormat("DONE: %s created from %s | %d days, %I64d ticks | spread removed (original average %.1f points) | "
                             "%d days without ticks (weekends/holidays). Backtest the EA on %s with 'Every tick based on real ticks'.",
                             dst, src, daysDone, totalTicks, totalTicks > 0 ? origSprSum / totalTicks : 0, daysEmpty, dst);
   Print(msg);
   Alert(msg);
  }
//+------------------------------------------------------------------+
