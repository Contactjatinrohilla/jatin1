//+------------------------------------------------------------------+
//|                    SB_MakeSpreadSymbol.mq5                        |
//|                                                                  |
//|  Script: makes a CUSTOM SYMBOL that is an exact copy of the chart |
//|  symbol (same bid prices, same times, same contract settings)     |
//|  but with the SPREAD you choose - e.g. your prop firm's 20-30     |
//|  points instead of the broker's 50+. Backtest the EA on the new   |
//|  symbol with "Every tick based on real ticks".                    |
//|                                                                  |
//|  Spread modes:                                                    |
//|   FIXED : every tick ask = bid + SpreadMin                        |
//|   CLIP  : keep the real spread but limit it to SpreadMin..Max     |
//|           (keeps news widening, removes the broker's extra cost)  |
//|   RANDOM: random spread between SpreadMin and SpreadMax per tick  |
//|                                                                  |
//|  Use: open a chart of the source symbol (e.g. XAUUSD.T), drag     |
//|  this script on it, set the dates and spread, OK. It copies one   |
//|  day at a time (progress in the chart corner). The new symbol is  |
//|  added to Market Watch, e.g. XAUUSD.T_S25.                        |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout - spread copy"
#property version   "1.11"
#property script_show_inputs

enum ENUM_SPREAD_MODE
  {
   SPM_FIXED  = 0, // Fixed: always SpreadMin
   SPM_CLIP   = 1, // Real spread, limited to SpreadMin..SpreadMax
   SPM_RANDOM = 2  // Random between SpreadMin and SpreadMax
  };

input datetime         InpFrom      = D'2022.04.01';   // Copy from (server date)
input datetime         InpTo        = D'2026.10.02';   // Copy to (server date)
input ENUM_SPREAD_MODE InpMode      = SPM_CLIP;        // Spread mode
input int              InpSpreadMin = 20;              // Spread min / fixed (points)
input int              InpSpreadMax = 30;              // Spread max (points)
input string           InpSuffix    = "";              // New symbol suffix ("" = _S<min>-<max> / _S<min>)
input bool             InpResume    = true;            // Symbol already exists: continue from its last copied day

void OnStart()
  {
   string src = _Symbol;
   if(StringFind(SymbolInfoString(src, SYMBOL_PATH), "Custom\\SB") == 0)
     {
      Alert(src, " is a copy made by this script. Run it on the ORIGINAL symbol's chart (e.g. XAUUSD.T), not on ", src, ".");
      return;
     }
   double pt  = SymbolInfoDouble(src, SYMBOL_POINT);
   if(InpSpreadMin < 0 || InpSpreadMax < InpSpreadMin) { Alert("Spread: need 0 <= min <= max"); return; }
   string suffix = InpSuffix != "" ? InpSuffix :
                   (InpMode == SPM_FIXED ? StringFormat("_S%d", InpSpreadMin) : StringFormat("_S%d-%d", InpSpreadMin, InpSpreadMax));
   string dst = src + suffix;

   // 1) create the custom symbol as a copy of the source (contract size, digits, sessions, margin...)
   bool exists = false;
   bool isCustom = false;
   exists = SymbolExist(dst, isCustom);
   if(exists && !isCustom) { Alert(dst, " already exists as a broker symbol - choose another suffix"); return; }
   if(!exists && !CustomSymbolCreate(dst, "Custom\\SB", src))
     { Alert("CustomSymbolCreate failed, error ", GetLastError()); return; }
   CustomSymbolSetInteger(dst, SYMBOL_SPREAD_FLOAT, true);
   CustomSymbolSetString(dst, SYMBOL_DESCRIPTION,
                         StringFormat("%s copy, spread %s %d-%d pts", src, EnumToString(InpMode), InpSpreadMin, InpSpreadMax));
   PrintFormat("Copying %s -> %s  %s .. %s  spread %s %d..%d points", src, dst, TimeToString(InpFrom, TIME_DATE),
               TimeToString(InpTo, TIME_DATE), EnumToString(InpMode), InpSpreadMin, InpSpreadMax);

   MathSrand((int)GetTickCount());
   long   totalTicks = 0;
   double sprSum = 0;
   int    daysDone = 0, daysEmpty = 0;
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
      // 2) M1 bars of the day (bid prices unchanged)
      MqlRates rates[];
      int nr = CopyRates(src, PERIOD_M1, day, day + 86399, rates);
      if(nr > 0)
        {
         int barSpread = (InpMode == SPM_FIXED) ? InpSpreadMin : (InpSpreadMin + InpSpreadMax) / 2;
         for(int i = 0; i < nr; i++)
            rates[i].spread = (InpMode == SPM_CLIP) ? (int)MathMax(InpSpreadMin, MathMin(InpSpreadMax, rates[i].spread)) : barSpread;
         CustomRatesReplace(dst, day, day + 86399, rates);
        }

      // 3) ticks of the day: same bid, new ask
      MqlTick ticks[];
      ulong from_msc = (ulong)day * 1000, to_msc = (ulong)(day + 86400) * 1000 - 1;
      int nt = -1;
      for(int tries = 0; tries < 5 && nt < 0; tries++)
        {
         nt = CopyTicksRange(src, ticks, COPY_TICKS_ALL, from_msc, to_msc);
         if(nt < 0) Sleep(500);
        }
      if(nt < 0) PrintFormat("%s: no ticks from %s (error %d)", TimeToString(day, TIME_DATE), src, GetLastError());
      if(nt <= 0) { daysEmpty++; continue; }
      int kept = 0;
      for(int i = 0; i < nt; i++)
        {
         if(ticks[i].bid <= 0) continue;
         int orig = (ticks[i].ask > 0) ? (int)MathRound((ticks[i].ask - ticks[i].bid) / pt) : InpSpreadMin;
         int sp;
         if(InpMode == SPM_FIXED)      sp = InpSpreadMin;
         else if(InpMode == SPM_CLIP)  sp = (int)MathMax(InpSpreadMin, MathMin(InpSpreadMax, orig));
         else                          sp = InpSpreadMin + (int)MathRound((InpSpreadMax - InpSpreadMin) * MathRand() / 32767.0);
         ticks[kept]       = ticks[i];
         ticks[kept].ask   = NormalizeDouble(ticks[i].bid + sp * pt, _Digits);
         ticks[kept].flags = TICK_FLAG_BID | TICK_FLAG_ASK;
         sprSum += sp;
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
   if(IsStopped())
     {
      Alert("STOPPED before the end - run the script again with Resume = true to continue from where it stopped.");
      return;
     }
   string msg = StringFormat("DONE: %s created from %s | %d days, %I64d ticks | average spread %.1f points | %d days without ticks "
                             "(weekends/holidays). Backtest the EA on %s with 'Every tick based on real ticks'.",
                             dst, src, daysDone, totalTicks, totalTicks > 0 ? sprSum / totalTicks : 0, daysEmpty, dst);
   Print(msg);
   Alert(msg);
  }
//+------------------------------------------------------------------+
