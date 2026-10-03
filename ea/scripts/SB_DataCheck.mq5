//+------------------------------------------------------------------+
//|                       SB_DataCheck.mq5                            |
//|                                                                  |
//|  Script: checks the price history of the chart symbol for the     |
//|  problems that break a PDH / range breakout backtest.             |
//|                                                                  |
//|   - D1 high/low that do not match the M1 bars of that day         |
//|     (wrong daily candle = wrong PDH/PDL levels)                   |
//|   - Saturday / Sunday bars (data not shifted to broker time)      |
//|   - weekdays with no M1 data, gaps inside the trading day          |
//|   - spikes: M1 bars far larger than the day's normal bar          |
//|   - zero / very wide spreads (from the bar spread field)           |
//|   - where the trading day starts/ends (time zone check)           |
//|                                                                  |
//|  Output: Common\Files\SB_datacheck_<symbol>.csv (one row per day)  |
//|  and a summary in the Experts journal. Drag it onto the chart of  |
//|  the symbol you backtest (e.g. XAUUSD.T).                         |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout - data check"
#property version   "1.00"
#property script_show_inputs

input datetime InpFrom        = D'2022.04.01';  // From (server date)
input datetime InpTo          = D'2026.10.01';  // To (server date)
input int      InpMaxGapMin   = 10;             // Report gaps between M1 bars longer than this (minutes)
input double   InpSpikeMult   = 10.0;           // Spike = M1 bar range larger than this x the day's median M1 range
input int      InpD1TolPoints = 5;              // Allowed D1 vs M1 high/low difference (points)
input int      InpWideSpread  = 0;              // Flag bars with spread above this (points, 0 = 10x the day's average)

double Median(double &a[])
  {
   int n = ArraySize(a);
   if(n == 0) return 0;
   ArraySort(a);
   return (n % 2 == 1) ? a[n / 2] : (a[n / 2 - 1] + a[n / 2]) / 2.0;
  }

void OnStart()
  {
   string sym   = _Symbol;
   double pt    = SymbolInfoDouble(sym, SYMBOL_POINT);
   int    dg    = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string fname = "SB_datacheck_" + sym + ".csv";
   int    fh    = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) { PrintFormat("Cannot open %s (error %d)", fname, GetLastError()); return; }
   FileWrite(fh, "date", "weekday", "m1_bars", "first_bar", "last_bar", "gaps", "max_gap_min", "d1_high", "m1_high",
             "diff_high_pts", "d1_low", "m1_low", "diff_low_pts", "spikes", "max_bar_range", "median_bar_range",
             "avg_spread_pts", "max_spread_pts", "zero_spread_bars", "issues");

   string wd[7] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
   int days = 0, noData = 0, weekendDays = 0, d1Bad = 0, gapDays = 0, spikeDays = 0, zeroSpreadDays = 0, wideDays = 0;
   int firstHour[24], lastHour[24];
   ArrayInitialize(firstHour, 0);
   ArrayInitialize(lastHour, 0);
   long   totalBars = 0;
   double sprSum = 0;

   datetime start = (datetime)((long)InpFrom - (long)InpFrom % 86400);
   for(datetime day = start; day < InpTo; day += 86400)
     {
      MqlDateTime t;
      TimeToStruct(day, t);
      MqlRates m[];
      int n = CopyRates(sym, PERIOD_M1, day, day + 86399, m);
      string issues = "";
      if(n <= 0)
        {
         if(t.day_of_week >= 1 && t.day_of_week <= 5)
           {
            noData++;
            FileWrite(fh, TimeToString(day, TIME_DATE), wd[t.day_of_week], 0, "", "", "", "", "", "", "", "", "", "", "",
                      "", "", "", "", "", "NO_M1_DATA (holiday or missing history)");
           }
         continue;
        }
      days++;
      totalBars += n;
      if(t.day_of_week == 0 || t.day_of_week == 6) { weekendDays++; issues += "WEEKEND_BARS(time zone not shifted?);"; }

      // gaps, ranges, spreads
      int    gaps = 0;
      double maxGap = 0, hi = m[0].high, lo = m[0].low, maxRange = 0;
      double ranges[];
      ArrayResize(ranges, n);
      long   sprTot = 0, sprMax = 0;
      int    zero = 0;
      for(int i = 0; i < n; i++)
        {
         ranges[i] = m[i].high - m[i].low;
         maxRange  = MathMax(maxRange, ranges[i]);
         hi = MathMax(hi, m[i].high);
         lo = MathMin(lo, m[i].low);
         sprTot += m[i].spread;
         sprMax  = MathMax(sprMax, (long)m[i].spread);
         if(m[i].spread == 0) zero++;
         if(i > 0)
           {
            double g = (double)(m[i].time - m[i - 1].time) / 60.0;
            if(g > InpMaxGapMin) { gaps++; maxGap = MathMax(maxGap, g); }
           }
        }
      double rangesCopy[];
      ArrayCopy(rangesCopy, ranges);
      double med = Median(rangesCopy);
      int spikes = 0;
      for(int i = 0; i < n; i++) if(med > 0 && ranges[i] > InpSpikeMult * med) spikes++;
      double avgSpr = (double)sprTot / n;
      sprSum += avgSpr;
      long   wideLim = (InpWideSpread > 0) ? InpWideSpread : (long)MathMax(1, 10 * avgSpr);

      MqlDateTime f, l;
      TimeToStruct(m[0].time, f);
      TimeToStruct(m[n - 1].time, l);
      firstHour[f.hour]++;
      lastHour[l.hour]++;

      // D1 candle of this date vs the M1 bars
      MqlRates d[];
      string d1h = "", d1l = "", dh = "", dl = "";
      int nd = CopyRates(sym, PERIOD_D1, day, day, d);
      if(nd == 1 && d[0].time == day)
        {
         double diffH = (d[0].high - hi) / pt, diffL = (lo - d[0].low) / pt;
         d1h = DoubleToString(d[0].high, dg); d1l = DoubleToString(d[0].low, dg);
         dh  = DoubleToString(diffH, 0);      dl  = DoubleToString(diffL, 0);
         if(MathAbs(diffH) > InpD1TolPoints || MathAbs(diffL) > InpD1TolPoints) { d1Bad++; issues += "D1_VS_M1_MISMATCH;"; }
        }
      else issues += "NO_D1_BAR;";

      if(gaps > 0)   { gapDays++;   issues += StringFormat("GAPS(%d, max %.0f min);", gaps, maxGap); }
      if(spikes > 0) { spikeDays++; issues += StringFormat("SPIKES(%d);", spikes); }
      if(zero > 0)   { zeroSpreadDays++; issues += StringFormat("ZERO_SPREAD(%d bars);", zero); }
      if(sprMax > wideLim) { wideDays++; issues += StringFormat("WIDE_SPREAD(max %d pts);", (int)sprMax); }

      FileWrite(fh, TimeToString(day, TIME_DATE), wd[t.day_of_week], n, TimeToString(m[0].time, TIME_MINUTES),
                TimeToString(m[n - 1].time, TIME_MINUTES), gaps, DoubleToString(maxGap, 0), d1h,
                DoubleToString(hi, dg), dh, d1l, DoubleToString(lo, dg), dl, spikes, DoubleToString(maxRange, dg),
                DoubleToString(med, dg), DoubleToString(avgSpr, 1), (int)sprMax, zero, issues);
     }
   FileClose(fh);

   int fh1 = 0, lh1 = 0;
   for(int h = 0; h < 24; h++) { if(firstHour[h] > firstHour[fh1]) fh1 = h; if(lastHour[h] > lastHour[lh1]) lh1 = h; }
   string s = StringFormat("DATA CHECK %s %s-%s: %d days with data (%I64d M1 bars) | weekdays without data: %d | weekend days with bars: %d | "
                           "D1 vs M1 mismatch: %d days | days with gaps > %d min: %d | spike days: %d | zero-spread days: %d | "
                           "wide-spread days: %d | avg spread %.1f pts | trading day usually %02d:xx - %02d:xx server",
                           sym, TimeToString(InpFrom, TIME_DATE), TimeToString(InpTo, TIME_DATE), days, totalBars, noData,
                           weekendDays, d1Bad, InpMaxGapMin, gapDays, spikeDays, zeroSpreadDays, wideDays,
                           days > 0 ? sprSum / days : 0, fh1, lh1);
   Print(s);
   PrintFormat("Details per day: %s\\Files\\%s", TerminalInfoString(TERMINAL_COMMONDATA_PATH), fname);
   Alert(s);
  }
//+------------------------------------------------------------------+
