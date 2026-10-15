//+------------------------------------------------------------------+
//|                     SB_CompareData.mq5                            |
//|                                                                  |
//|  Script: compares two price histories minute by minute, e.g.      |
//|  your BROKER symbol against the Tick Data Suite / Dukascopy       |
//|  custom symbol, to see whether a backtest on the downloaded data  |
//|  matches what the broker really quoted.                           |
//|                                                                  |
//|   - time zone: finds the hour shift that lines the two up best    |
//|     (0 = same server time, anything else = fix the GMT offset)    |
//|   - symbol specs: digits, point, contract size, tick value        |
//|   - per day: day high/low (= next day's PDH/PDL) of both and the  |
//|     difference in points, first/last bar time, missing minutes,   |
//|     average and largest close difference, average spread of both  |
//|                                                                  |
//|  Output: Common\Files\SB_compare_<broker>_vs_<other>.csv (one row |
//|  per day) and a summary in the Experts journal.                   |
//|  Use: run it on any chart, type both symbol names in the inputs.  |
//|  Both symbols must be in Market Watch with M1 history loaded.     |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Simple Breakout - data compare"
#property version   "1.00"
#property script_show_inputs

input string   InpBrokerSym   = "";             // Broker symbol (empty = chart symbol)
input string   InpOtherSym    = "XAUUSD_TDS";   // Downloaded data symbol (Tick Data Suite / Dukascopy custom symbol)
input datetime InpFrom        = D'2026.07.01';  // From (broker server date)
input datetime InpTo          = D'2026.10.01';  // To (broker server date)
input int      InpShiftHours  = 99;             // Hours to add to the other symbol's time (99 = find it automatically)
input int      InpHLTolPoints = 20;             // Day high/low difference above this (points) = flagged day
input double   InpMinMatchPct = 90.0;           // Fewer matching minutes than this % = flagged day

// Load M1 history of a symbol back to 'from'; returns the first available M1 date.
datetime LoadHistory(const string sym, const datetime from)
  {
   datetime first = 0;
   for(int tries = 0; tries < 30; tries++)
     {
      MqlRates probe[];
      CopyRates(sym, PERIOD_M1, from, from + 7 * 86400, probe);
      first = (datetime)SeriesInfoInteger(sym, PERIOD_M1, SERIES_FIRSTDATE);
      if(first > 0 && first <= from + 7 * 86400) break;
      Sleep(1000);
     }
   PrintFormat("M1 history for %s: available from %s", sym, TimeToString(first, TIME_DATE));
   return first;
  }

// Average |close difference| (in price) over minutes present in both arrays, other time shifted by 'shift' seconds.
// Also returns the number of matched minutes and the largest difference.
double CloseDiff(const MqlRates &a[], const MqlRates &b[], const long shift, int &matched, double &maxDiff)
  {
   int na = ArraySize(a), nb = ArraySize(b), i = 0, j = 0;
   double sum = 0;
   matched = 0;
   maxDiff = 0;
   while(i < na && j < nb)
     {
      long ta = (long)a[i].time, tb = (long)b[j].time + shift;
      if(ta < tb) { i++; continue; }
      if(ta > tb) { j++; continue; }
      double d = MathAbs(a[i].close - b[j].close);
      sum += d;
      maxDiff = MathMax(maxDiff, d);
      matched++;
      i++; j++;
     }
   return matched > 0 ? sum / matched : -1;
  }

// Find the hour shift (-12..+12) for the other symbol that makes its closes match the broker's best.
int FindShift(const string bsym, const string osym)
  {
   double score[25];
   int    count[25];
   ArrayInitialize(score, 0);
   ArrayInitialize(count, 0);
   int sampled = 0;
   datetime start = (datetime)((long)InpFrom - (long)InpFrom % 86400);
   long span = MathMax(1, ((long)InpTo - (long)start) / 86400);
   long step = MathMax(1, span / 20);                       // about 20 sample days over the range
   for(datetime day = start; day < InpTo && sampled < 20; day += (int)(step * 86400))
     {
      MqlRates a[], b[];
      if(CopyRates(bsym, PERIOD_M1, day, day + 86399, a) < 60) continue;
      if(CopyRates(osym, PERIOD_M1, day - 13 * 3600, day + 86399 + 13 * 3600, b) < 60) continue;
      sampled++;
      for(int k = -12; k <= 12; k++)
        {
         int m; double mx;
         double d = CloseDiff(a, b, (long)k * 3600, m, mx);
         if(m < 30) continue;                                 // too little overlap to judge
         score[k + 12] += d;
         count[k + 12]++;
        }
     }
   int best = 0;
   double bestScore = DBL_MAX;
   for(int k = -12; k <= 12; k++)
     {
      if(count[k + 12] < MathMax(1, sampled / 2)) continue;
      double s = score[k + 12] / count[k + 12];
      if(s < bestScore) { bestScore = s; best = k; }
     }
   PrintFormat("Time shift search on %d sample days: best = %+d h (avg close difference %s)", sampled, best,
               bestScore < DBL_MAX ? DoubleToString(bestScore, (int)SymbolInfoInteger(bsym, SYMBOL_DIGITS)) : "n/a");
   return best;
  }

void OnStart()
  {
   string bsym = (InpBrokerSym == "") ? _Symbol : InpBrokerSym;
   string osym = InpOtherSym;
   if(!SymbolSelect(bsym, true) || !SymbolSelect(osym, true))
     {
      string w = StringFormat("Symbol not found: '%s' or '%s'. Type the names exactly as in Market Watch.", bsym, osym);
      Print(w); Alert(w);
      return;
     }
   if(bsym == osym) { Alert("Broker symbol and other symbol are the same - pick two different symbols."); return; }

   datetime bFirst = LoadHistory(bsym, InpFrom), oFirst = LoadHistory(osym, InpFrom);
   if(bFirst > InpFrom + 7 * 86400 || oFirst > InpFrom + 7 * 86400)
      Alert(StringFormat("M1 history starts after %s (%s from %s, %s from %s). Set Tools > Options > Charts > "
                         "Max bars in chart = Unlimited, open M1 charts of both, press Home to load history.",
                         TimeToString(InpFrom, TIME_DATE), bsym, TimeToString(bFirst, TIME_DATE),
                         osym, TimeToString(oFirst, TIME_DATE)));

   // ---- symbol specs
   double bpt = SymbolInfoDouble(bsym, SYMBOL_POINT), opt = SymbolInfoDouble(osym, SYMBOL_POINT);
   int    bdg = (int)SymbolInfoInteger(bsym, SYMBOL_DIGITS), odg = (int)SymbolInfoInteger(osym, SYMBOL_DIGITS);
   double bcs = SymbolInfoDouble(bsym, SYMBOL_TRADE_CONTRACT_SIZE), ocs = SymbolInfoDouble(osym, SYMBOL_TRADE_CONTRACT_SIZE);
   double btv = SymbolInfoDouble(bsym, SYMBOL_TRADE_TICK_VALUE), otv = SymbolInfoDouble(osym, SYMBOL_TRADE_TICK_VALUE);
   double bts = SymbolInfoDouble(bsym, SYMBOL_TRADE_TICK_SIZE), ots = SymbolInfoDouble(osym, SYMBOL_TRADE_TICK_SIZE);
   string specs = StringFormat("Specs  %s: digits %d, point %s, contract %.2f, tick value %.4f / size %s  |  "
                               "%s: digits %d, point %s, contract %.2f, tick value %.4f / size %s",
                               bsym, bdg, DoubleToString(bpt, bdg), bcs, btv, DoubleToString(bts, bdg),
                               osym, odg, DoubleToString(opt, odg), ocs, otv, DoubleToString(ots, odg));
   string specIssues = "";
   if(bdg != odg)                  specIssues += "DIGITS differ (SL/TP in points mean different prices!); ";
   if(MathAbs(bcs - ocs) > 1e-9)   specIssues += "CONTRACT SIZE differs (profit per lot differs); ";
   if(MathAbs(btv / MathMax(bts, 1e-12) - otv / MathMax(ots, 1e-12)) > 1e-6 * MathMax(1.0, btv / MathMax(bts, 1e-12)))
                                   specIssues += "TICK VALUE differs; ";

   // ---- time shift
   int shiftH = (InpShiftHours == 99) ? FindShift(bsym, osym) : InpShiftHours;
   long shift = (long)shiftH * 3600;

   // ---- per day comparison
   string fname = "SB_compare_" + bsym + "_vs_" + osym + ".csv";
   int fh = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE) { PrintFormat("Cannot open %s (error %d)", fname, GetLastError()); return; }
   FileWrite(fh, "date", "weekday", "broker_bars", "other_bars", "matched", "match_pct",
             "broker_first", "other_first", "broker_last", "other_last",
             "broker_high", "other_high", "diff_high_pts", "broker_low", "other_low", "diff_low_pts",
             "avg_close_diff_pts", "max_close_diff_pts", "broker_avg_spread_pts", "other_avg_spread_pts", "issues");

   string wd[7] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
   int    days = 0, hlBad = 0, matchBad = 0, onlyBroker = 0, onlyOther = 0;
   double sumHL = 0, maxHL = 0, sumClose = 0, maxClose = 0, sumBSpr = 0, sumOSpr = 0, sumMatch = 0;

   datetime start = (datetime)((long)InpFrom - (long)InpFrom % 86400);
   for(datetime day = start; day < InpTo; day += 86400)
     {
      MqlDateTime t;
      TimeToStruct(day, t);
      MqlRates a[], braw[], b[];
      int na = CopyRates(bsym, PERIOD_M1, day, day + 86399, a);
      // other symbol's bars that fall on this broker day after the shift
      int nr = CopyRates(osym, PERIOD_M1, (datetime)((long)day - shift), (datetime)((long)day + 86399 - shift), braw);
      int nb = MathMax(nr, 0);
      ArrayResize(b, nb);
      for(int i = 0; i < nb; i++) { b[i] = braw[i]; b[i].time = (datetime)((long)braw[i].time + shift); }
      if(na <= 0 && nb <= 0) continue;
      if(na <= 0 || nb <= 0)
        {
         if(na <= 0) onlyOther++; else onlyBroker++;
         FileWrite(fh, TimeToString(day, TIME_DATE), wd[t.day_of_week], MathMax(na, 0), nb, 0, 0,
                   "", "", "", "", "", "", "", "", "", "", "", "", "", "",
                   na <= 0 ? "ONLY_OTHER_HAS_DATA" : "ONLY_BROKER_HAS_DATA");
         continue;
        }
      days++;

      double ah = a[0].high, al = a[0].low, bh = b[0].high, bl = b[0].low, aspr = 0, bspr = 0;
      for(int i = 0; i < na; i++) { ah = MathMax(ah, a[i].high); al = MathMin(al, a[i].low); aspr += a[i].spread; }
      for(int i = 0; i < nb; i++) { bh = MathMax(bh, b[i].high); bl = MathMin(bl, b[i].low); bspr += b[i].spread; }
      aspr /= na;
      bspr = bspr / nb * opt / bpt;                         // other symbol's spread in broker points

      int matched; double mx;
      double avgD = CloseDiff(a, b, 0, matched, mx);
      double pct  = 100.0 * matched / MathMax(na, nb);
      double dH = (bh - ah) / bpt, dL = (bl - al) / bpt;

      string issues = "";
      if(MathAbs(dH) > InpHLTolPoints || MathAbs(dL) > InpHLTolPoints) { hlBad++; issues += "HIGH_LOW_DIFFER;"; }
      if(pct < InpMinMatchPct) { matchBad++; issues += StringFormat("MISSING_MINUTES(%.0f%% match);", pct); }
      if(t.day_of_week == 0 || t.day_of_week == 6) issues += "WEEKEND_BARS;";

      sumHL   += (MathAbs(dH) + MathAbs(dL)) / 2;
      maxHL    = MathMax(maxHL, MathMax(MathAbs(dH), MathAbs(dL)));
      if(avgD >= 0) { sumClose += avgD / bpt; maxClose = MathMax(maxClose, mx / bpt); }
      sumBSpr += aspr;
      sumOSpr += bspr;
      sumMatch += pct;

      FileWrite(fh, TimeToString(day, TIME_DATE), wd[t.day_of_week], na, nb, matched, DoubleToString(pct, 1),
                TimeToString(a[0].time, TIME_MINUTES), TimeToString(b[0].time, TIME_MINUTES),
                TimeToString(a[na - 1].time, TIME_MINUTES), TimeToString(b[nb - 1].time, TIME_MINUTES),
                DoubleToString(ah, bdg), DoubleToString(bh, odg), DoubleToString(dH, 0),
                DoubleToString(al, bdg), DoubleToString(bl, odg), DoubleToString(dL, 0),
                avgD >= 0 ? DoubleToString(avgD / bpt, 1) : "", DoubleToString(mx / bpt, 0),
                DoubleToString(aspr, 1), DoubleToString(bspr, 1), issues);
     }
   FileClose(fh);

   // ---- summary
   string head = StringFormat("DATA COMPARE %s (broker) vs %s  %s - %s", bsym, osym,
                              TimeToString(InpFrom, TIME_DATE), TimeToString(InpTo, TIME_DATE));
   string l1 = (shiftH == 0)
               ? "Time zone: OK - both are on the same server time (shift 0 h)"
               : StringFormat("Time zone: OTHER DATA IS SHIFTED %+d h - set the GMT offset in Tick Data Suite so "
                              "it matches the broker, otherwise PDH/PDL and session times are wrong", shiftH);
   string l2 = (specIssues == "") ? "Symbol specs: OK (digits, contract size, tick value match)"
                                  : "Symbol specs: " + specIssues;
   string l3 = StringFormat("Days compared: %d | only broker has data: %d | only other has data: %d | avg minute match %.1f%%",
                            days, onlyBroker, onlyOther, days > 0 ? sumMatch / days : 0);
   string l4 = StringFormat("Day high/low difference: avg %.1f pts, max %.0f pts | days above %d pts: %d",
                            days > 0 ? sumHL / days : 0, maxHL, InpHLTolPoints, hlBad);
   string l5 = StringFormat("M1 close difference: avg %.1f pts, max %.0f pts | days under %.0f%% minute match: %d",
                            days > 0 ? sumClose / days : 0, maxClose, InpMinMatchPct, matchBad);
   string l6 = StringFormat("Average spread: broker %.1f pts, other %.1f pts (set TDS spread/commission to match the broker)",
                            days > 0 ? sumBSpr / days : 0, days > 0 ? sumOSpr / days : 0);
   Print(head); Print(specs); Print(l1); Print(l2); Print(l3); Print(l4); Print(l5); Print(l6);
   PrintFormat("Details per day: %s\\Files\\%s", TerminalInfoString(TERMINAL_COMMONDATA_PATH), fname);
   Alert(head); Alert(l1); Alert(l2); Alert(l3); Alert(l4); Alert(l5); Alert(l6);
  }
//+------------------------------------------------------------------+
