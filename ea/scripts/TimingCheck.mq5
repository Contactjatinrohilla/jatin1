//+------------------------------------------------------------------+
//|                                              TimingCheck.mq5     |
//|                                                                  |
//|  READ-ONLY script - it never trades.                              |
//|  Checks that your broker's clock and the EA's New York time       |
//|  agree, using the US stock market open (09:30 New York): at that  |
//|  minute Nasdaq always makes a sudden jump in movement.            |
//|                                                                  |
//|  Run it on a Nasdaq chart (any timeframe). Results go to the      |
//|  Experts log and to MQL5\Files\TimingCheck_<symbol>.csv           |
//+------------------------------------------------------------------+
#property copyright "NAS Breakout Simple"
#property version   "1.00"
#property description "Read-only: checks InpBrokerGMTWinter / InpBrokerDST against the real 09:30 New York open. Never trades."
#property script_show_inputs

input int      InpBrokerGMTWinter = 2;              // same value as in my EA
input bool     InpBrokerDST       = true;           // same value as in my EA
input datetime InpFrom            = D'2020.01.01';
input datetime InpTo              = D'2026.10.01';

#define NY_OPEN       (9 * 60 + 30)   // US stock market open, New York minutes after midnight
#define SEARCH_MIN    180             // look 3 hours before and after the expected open
#define BEFORE_BARS   30              // "calm" part: the 30 one-minute candles before
#define AFTER_BARS    5               // "jump" part: the 5 one-minute candles after
#define MATCH_MIN     10              // detected within 10 minutes of expected = MATCH
#define GAP_MIN       15              // a gap of 15+ minutes between M1 candles = trading break
// Killzones in New York time - same as the EA
#define KZ_ASIAN_START  (20 * 60)
#define KZ_ASIAN_END    (24 * 60)
#define KZ_LONDON_START (2 * 60)
#define KZ_LONDON_END   (5 * 60)
#define KZ_NYAM_START   (8 * 60 + 30)
#define KZ_NYAM_END     (11 * 60)

//+------------------------------------------------------------------+
//|  EXACT COPY of the EA's New York time functions                   |
//+------------------------------------------------------------------+
// The n-th Sunday of a month (n = 1 first, 2 second ...), at 00:00.
datetime NthSunday(const int year, const int month, const int n)
  {
   MqlDateTime s;
   ZeroMemory(s);
   s.year = year;
   s.mon  = month;
   s.day  = 1;
   datetime first = StructToTime(s);
   MqlDateTime f;
   TimeToStruct(first, f);
   return (datetime)((long)first + (long)((7 - f.day_of_week) % 7 + 7 * (n - 1)) * 86400);
  }

// True during US summer time: second Sunday of March to first Sunday of November.
bool UsSummerTime(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return t >= NthSunday(s.year, 3, 2) && t < NthSunday(s.year, 11, 1);
  }

// Hours to subtract from server time to get New York time.
// New York = GMT-5 in winter, GMT-4 in summer. Server = GMT + winter offset (+1 in summer if the broker uses DST).
int ServerMinusNYHours(const datetime t, const int gmtWinter, const bool brokerDST)
  {
   bool summer = UsSummerTime(t);
   int  server = gmtWinter + ((brokerDST && summer) ? 1 : 0);
   int  ny     = summer ? -4 : -5;
   return server - ny;
  }
//+------------------------------------------------------------------+

datetime DayStart(const datetime t) { return (datetime)((long)t - (long)t % 86400); }
int      MinuteOf(const datetime t) { return (int)(((long)t % 86400) / 60); }
int      Weekday(const datetime t)  { MqlDateTime s; TimeToStruct(t, s); return s.day_of_week; }
int      MonthOf(const datetime t)  { MqlDateTime s; TimeToStruct(t, s); return s.mon; }
datetime WeekStart(const datetime t) { return (datetime)((long)DayStart(t) - (long)((Weekday(t) + 6) % 7) * 86400); }
string   HM(const int minute) { int m = (minute % 1440 + 1440) % 1440; return StringFormat("%02d:%02d", m / 60, m % 60); }

datetime NextMonth(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   s.day = 1; s.hour = 0; s.min = 0; s.sec = 0;
   if(++s.mon > 12) { s.mon = 1; s.year++; }
   return StructToTime(s);
  }

// Expected open (server minute of the day) for a day, with given settings.
int ExpectedOpen(const datetime day, const int gmtWinter, const bool brokerDST)
  {
   return NY_OPEN + ServerMinusNYHours(day, gmtWinter, brokerDST) * 60;
  }

// Most common value in a small list.
int Mode(const int &v[], const int n)
  {
   int best = v[0], bestCount = 0;
   for(int i = 0; i < n; i++)
     {
      int c = 0;
      for(int j = 0; j < n; j++) if(MathAbs(v[j] - v[i]) <= 2) c++;   // values within 2 minutes count as the same
      if(c > bestCount) { bestCount = c; best = v[i]; }
     }
   return best;
  }

// Is a server minute inside the break [bs, be)? (the break may run past midnight)
bool InBreak(const int minute, const int bs, const int be)
  {
   int m = (minute % 1440 + 1440) % 1440;
   return (bs < be) ? (m >= bs && m < be) : (m >= bs || m < be);
  }

// Warn if a killzone (New York minutes) overlaps the break, in winter or summer.
void CheckKZ(const string name, const int nyStart, const int nyEnd, const int bs, const int be, const int fh)
  {
   datetime winter = D'2025.01.15', summer = D'2025.07.15';
   int sw = ServerMinusNYHours(winter, InpBrokerGMTWinter, InpBrokerDST) * 60;
   int ss = ServerMinusNYHours(summer, InpBrokerGMTWinter, InpBrokerDST) * 60;
   bool hitW = false, hitS = false;
   for(int m = nyStart; m < nyEnd; m++)
     {
      if(InBreak(m + sw, bs, be)) hitW = true;
      if(InBreak(m + ss, bs, be)) hitS = true;
     }
   string line = StringFormat("%s killzone = server %s-%s (winter), %s-%s (summer)%s", name,
                              HM(nyStart + sw), HM(nyEnd + sw), HM(nyStart + ss), HM(nyEnd + ss),
                              (hitW || hitS) ? "  <-- WARNING: falls inside the broker's daily break!" : "  OK");
   Print(line);
   if(fh != INVALID_HANDLE) FileWrite(fh, "killzone", line);
  }

void OnStart()
  {
   PrintFormat("TimingCheck on %s | your settings: InpBrokerGMTWinter = %d, InpBrokerDST = %s | %s to %s",
               _Symbol, InpBrokerGMTWinter, InpBrokerDST ? "true" : "false", TimeToString(InpFrom, TIME_DATE), TimeToString(InpTo, TIME_DATE));

   // one entry per trading day: the day and its detected open (server minute)
   datetime dDay[];
   int      dOpen[];
   int      nd = 0;
   // daily breaks: start*1440+end and how often seen
   int      gKey[], gCount[];
   int      ng = 0;

   //--- 1) read M1 history one month at a time
   for(datetime m = DayStart(InpFrom); m < InpTo; m = NextMonth(m))
     {
      datetime mEnd = NextMonth(m);
      if(mEnd > InpTo) mEnd = InpTo;
      MqlRates r[];
      int n = CopyRates(_Symbol, PERIOD_M1, m, mEnd - 1, r);
      if(n <= BEFORE_BARS + AFTER_BARS)
        {
         PrintFormat("No M1 data for %s - skipped", TimeToString(m, TIME_DATE));
         continue;
        }
      // running total of candle ranges, so averages are instant
      double sum[];
      ArrayResize(sum, n + 1);
      sum[0] = 0.0;
      for(int i = 0; i < n; i++) sum[i + 1] = sum[i] + (r[i].high - r[i].low);

      // daily trading break: a gap of 15+ minutes on a weekday (same day or overnight to the next weekday)
      for(int i = 1; i < n; i++)
        {
         long gap = (long)r[i].time - (long)r[i - 1].time;
         if(gap < GAP_MIN * 60) continue;
         int w0 = Weekday(r[i - 1].time), w1 = Weekday(r[i].time);
         long days = ((long)DayStart(r[i].time) - (long)DayStart(r[i - 1].time)) / 86400;
         if(w0 < 1 || w0 > 5 || w1 < 1 || w1 > 5 || days > 1) continue;   // weekends and holidays are not the daily break
         int key = (MinuteOf(r[i - 1].time) + 1) * 1440 + MinuteOf(r[i].time);
         int k = 0;
         while(k < ng && gKey[k] != key) k++;
         if(k == ng) { ng++; ArrayResize(gKey, ng); ArrayResize(gCount, ng); gKey[k] = key; gCount[k] = 0; }
         gCount[k]++;
        }

      // detected open for every weekday in this month
      int p = 0;
      for(datetime day = DayStart(r[0].time); day <= DayStart(r[n - 1].time); day += 86400)
        {
         int wd = Weekday(day);
         if(wd == 0 || wd == 6) continue;
         datetime expected = day + ExpectedOpen(day, InpBrokerGMTWinter, InpBrokerDST) * 60;
         datetime lo = expected - SEARCH_MIN * 60, hi = expected + SEARCH_MIN * 60;
         while(p < n && r[p].time < lo) p++;
         double bestRatio = 0.0;
         int    best = -1;
         for(int i = p; i < n && r[i].time <= hi; i++)
           {
            if(i < BEFORE_BARS || i + AFTER_BARS > n) continue;
            double before = (sum[i] - sum[i - BEFORE_BARS]) / BEFORE_BARS;
            double after  = (sum[i + AFTER_BARS] - sum[i]) / AFTER_BARS;
            if(before <= 0.0) continue;
            if(after / before > bestRatio) { bestRatio = after / before; best = i; }
           }
         if(best < 0) continue;
         nd++;
         ArrayResize(dDay, nd);
         ArrayResize(dOpen, nd);
         dDay[nd - 1]  = day;
         dOpen[nd - 1] = MinuteOf(r[best].time);
        }
     }
   if(nd == 0)
     {
      Print("No M1 data found. Download the history first (View > Symbols > Bars), then run again.");
      return;
     }

   //--- 2) one line per week: most common detected open
   string file = "TimingCheck_" + _Symbol + ".csv";
   int fh = FileOpen(file, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
   if(fh != INVALID_HANDLE) FileWrite(fh, "week", "expected open (server)", "detected open", "difference (min)", "result");
   Print("week | expected open (server time) | detected open | difference in minutes | result");

   datetime wDay[];     // a day inside the week (used to work out the expected open)
   int      wOpen[];    // detected open of the week
   int      nw = 0, match = 0, misOther = 0, misMarOctNov = 0;
   int      vals[];
   ArrayResize(vals, 7);
   for(int i = 0; i < nd; )
     {
      datetime wk = WeekStart(dDay[i]);
      int c = 0;
      datetime sample = dDay[i];
      while(i < nd && WeekStart(dDay[i]) == wk) { if(c < 7) vals[c++] = dOpen[i]; i++; }
      int det = Mode(vals, c);
      int expOpen = ExpectedOpen(sample, InpBrokerGMTWinter, InpBrokerDST);
      int diff = det - expOpen;
      bool ok = MathAbs(diff) <= MATCH_MIN;
      nw++;
      ArrayResize(wDay, nw);
      ArrayResize(wOpen, nw);
      wDay[nw - 1] = sample;
      wOpen[nw - 1] = det;
      if(ok) match++;
      else
        {
         int mon = MonthOf(sample);
         if(mon == 3 || mon == 10 || mon == 11) misMarOctNov++; else misOther++;
        }
      string ws = TimeToString(wk, TIME_DATE);
      PrintFormat("%s | %s | %s | %+d | %s", ws, HM(expOpen), HM(det), diff, ok ? "MATCH" : "MISMATCH");
      if(fh != INVALID_HANDLE) FileWrite(fh, ws, HM(expOpen), HM(det), diff, ok ? "MATCH" : "MISMATCH");
     }

   //--- 3) try every setting: winter offset -2..+4, DST true/false
   int bestG = InpBrokerGMTWinter, bestCount = match;
   bool bestD = InpBrokerDST;
   for(int g = -2; g <= 4; g++)
      for(int d = 0; d <= 1; d++)
        {
         int cnt = 0;
         for(int k = 0; k < nw; k++)
            if(MathAbs(wOpen[k] - ExpectedOpen(wDay[k], g, d == 1)) <= MATCH_MIN) cnt++;
         if(cnt > bestCount) { bestCount = cnt; bestG = g; bestD = (d == 1); }
        }

   //--- 4) the broker's usual daily break
   int bs = -1, be = -1, bc = 0;
   for(int k = 0; k < ng; k++) if(gCount[k] > bc) { bc = gCount[k]; bs = gKey[k] / 1440; be = gKey[k] % 1440; }

   //--- 5) summary in simple words
   double pct = 100.0 * match / nw;
   Print("==================== SUMMARY ====================");
   PrintFormat("Weeks checked: %d | MATCH: %d | MISMATCH: %d (%.0f%% match)", nw, match, nw - match, pct);
   string verdict;
   if(pct > 90.0)
      verdict = StringFormat("Your settings are correct (InpBrokerGMTWinter = %d, InpBrokerDST = %s).",
                             InpBrokerGMTWinter, InpBrokerDST ? "true" : "false");
   else
      verdict = StringFormat("Change your EA to InpBrokerGMTWinter = %d and InpBrokerDST = %s (matches %d of %d weeks).",
                             bestG, bestD ? "true" : "false", bestCount, nw);
   Print(verdict);
   if(fh != INVALID_HANDLE) { FileWrite(fh, "summary", StringFormat("%d weeks, %d MATCH, %d MISMATCH", nw, match, nw - match)); FileWrite(fh, "summary", verdict); }

   if(misMarOctNov > 0 && misOther == 0)
     {
      string eu = "All mismatches are in March, October or November. Your broker probably changes its clock on EUROPEAN dates "
                  "(last Sunday of March / October) instead of US dates (second Sunday of March / first Sunday of November). "
                  "That means for about 2-3 weeks each spring and autumn the EA's New York time is 1 hour off, "
                  "so the killzones start 1 hour early or late in those weeks. The rest of the year is correct.";
      Print(eu);
      if(fh != INVALID_HANDLE) FileWrite(fh, "summary", eu);
     }
   if(bestCount * 100 < 90 * nw)
      Print("Even the best setting matches less than 90% of weeks - check that the M1 history is complete (View > Symbols > Bars).");

   if(bs >= 0)
     {
      string br = StringFormat("Usual daily trading break: %s-%s server time (seen %d times)", HM(bs), HM(be), bc);
      Print(br);
      if(fh != INVALID_HANDLE) FileWrite(fh, "break", br);
      CheckKZ("Asian",  KZ_ASIAN_START,  KZ_ASIAN_END,  bs, be, fh);
      CheckKZ("London", KZ_LONDON_START, KZ_LONDON_END, bs, be, fh);
      CheckKZ("NY AM",  KZ_NYAM_START,   KZ_NYAM_END,   bs, be, fh);
     }
   else Print("No regular daily trading break found.");

   if(fh != INVALID_HANDLE)
     {
      FileClose(fh);
      PrintFormat("Saved: File > Open Data Folder > MQL5 > Files > %s", file);
     }
   else PrintFormat("Could not save %s (error %d) - the results are only in this log.", file, GetLastError());
  }
//+------------------------------------------------------------------+
