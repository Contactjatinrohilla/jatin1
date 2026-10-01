#!/usr/bin/env python3
"""
Convert Dukascopy XAUUSD tick data into an MT5 custom-symbol tick file.

What it fixes
  1. DIGITS  - Dukascopy quotes gold with 3 decimals (2650.125). Most MT5
               brokers (and prop firms) use 2 (2650.13). Output is rounded
               to --digits so "points" mean the same as on your broker.
  2. SPREAD  - Dukascopy's raw spread swings a lot. --spread replaces it
               with a FIXED spread in USD (0.25 = 25 points on a 2-digit
               symbol), centred on the Dukascopy mid price.
  3. TIMEZONE- Dukascopy timestamps are UTC. Brokers run their server on
               UTC+2 (winter) / UTC+3 (US summer time) so the daily candle
               closes at 17:00 New York. --tz eet-us shifts the ticks so
               your D1 candles, PDH/PDL and session times match the broker.

Input  : any CSV with a time column and Bid/Ask columns. Recognised:
           Dukascopy export   "Gmt time,Ask,Bid,AskVolume,BidVolume"
                              01.01.2024 22:00:00.123 (optional " GMT+0100")
           dukascopy-node     "timestamp,askPrice,bidPrice,..." (epoch ms)
           MT5 tick export    "<DATE> <TIME> <BID> <ASK> ..." (tab separated)
         .gz files are read directly.
Output : MT5 tick CSV (tab separated) for
         Symbols > Custom symbol > Ticks > Import Ticks.

Examples
  python3 dukascopy_to_mt5.py XAUUSD_ticks.csv XAUUSD_mt5.csv --spread 0.25
  python3 dukascopy_to_mt5.py mt5_export.csv fixed.csv --spread 0.25 --tz none
"""
import argparse
import csv
import datetime as dt
import gzip
import io
import re
import sys

EPOCH_ORD = dt.date(1970, 1, 1).toordinal()
DAY_MS = 86_400_000
HOUR_MS = 3_600_000


# ---------------------------------------------------------------- timezone
def _nth_sunday(y, m, n):
    first = dt.date(y, m, 1)
    return first + dt.timedelta(days=(6 - first.weekday()) % 7 + 7 * (n - 1))


def _last_sunday(y, m):
    nxt = dt.date(y + (m == 12), m % 12 + 1, 1)
    last = nxt - dt.timedelta(days=1)
    return last - dt.timedelta(days=(last.weekday() - 6) % 7)


def _ms(d, hour):
    return (d.toordinal() - EPOCH_ORD) * DAY_MS + hour * HOUR_MS


_dst_cache = {}


def dst_window_ms(year, rule):
    """[start, end) of summer time in UTC epoch ms."""
    key = (year, rule)
    if key not in _dst_cache:
        if rule == "us":   # 2nd Sun March 02:00 EST (07 UTC) -> 1st Sun Nov 02:00 EDT (06 UTC)
            _dst_cache[key] = (_ms(_nth_sunday(year, 3, 2), 7), _ms(_nth_sunday(year, 11, 1), 6))
        else:              # EU: last Sun March 01 UTC -> last Sun Oct 01 UTC
            _dst_cache[key] = (_ms(_last_sunday(year, 3), 1), _ms(_last_sunday(year, 10), 1))
    return _dst_cache[key]


def make_offset_fn(tz, fixed_hours):
    if tz == "none":
        return lambda ms: 0
    if tz == "fixed":
        off = int(fixed_hours * HOUR_MS)
        return lambda ms: off
    rule = "us" if tz == "eet-us" else "eu"
    year_of_day = {}

    def fn(ms):
        day = ms // DAY_MS
        y = year_of_day.get(day)
        if y is None:
            y = dt.date.fromordinal(day + EPOCH_ORD).year
            year_of_day[day] = y
        s, e = dst_window_ms(y, rule)
        return 3 * HOUR_MS if s <= ms < e else 2 * HOUR_MS
    return fn


# ---------------------------------------------------------------- parsing
_days_cache = {}


def _days(y, m, d):
    k = (y, m, d)
    v = _days_cache.get(k)
    if v is None:
        v = dt.date(y, m, d).toordinal() - EPOCH_ORD
        _days_cache[k] = v
    return v


def _time_ms(t):
    # "HH:MM:SS" or "HH:MM:SS.fff..." or "HH:MM"
    h = int(t[0:2]); mi = int(t[3:5])
    s = int(t[6:8]) if len(t) >= 8 else 0
    frac = t[9:12] if len(t) > 9 else ""
    ms = int((frac + "000")[:3]) if frac else 0
    return ((h * 60 + mi) * 60 + s) * 1000 + ms


_gmt_re = re.compile(r"\s*(?:GMT|UTC)?\s*([+-])(\d{2}):?(\d{2})$")


def make_time_parser(sample):
    """Returns f(text) -> UTC epoch ms, chosen from the first data row."""
    s = sample.strip()
    if re.fullmatch(r"\d{12,14}", s):
        return lambda x: int(x)
    if re.fullmatch(r"\d{9,11}(\.\d+)?", s):
        return lambda x: int(round(float(x) * 1000))

    def split_tz(x):
        x = x.strip().rstrip("Z")
        m = _gmt_re.search(x)
        if m and len(x) > 19:
            sign = 1 if m.group(1) == "+" else -1
            off = sign * (int(m.group(2)) * 60 + int(m.group(3))) * 60_000
            return x[: m.start()].strip(), off
        return x, 0

    body, _ = split_tz(s)
    if re.match(r"\d{2}\.\d{2}\.\d{4}[ T]", body):          # 01.01.2024 22:00:00.123
        def f(x):
            b, off = split_tz(x)
            return _days(int(b[6:10]), int(b[3:5]), int(b[0:2])) * DAY_MS + _time_ms(b[11:]) - off
        return f
    if re.match(r"\d{4}[.\-/]\d{2}[.\-/]\d{2}[ T]", body):  # 2024.01.01 22:00:00.123
        def f(x):
            b, off = split_tz(x)
            return _days(int(b[0:4]), int(b[5:7]), int(b[8:10])) * DAY_MS + _time_ms(b[11:]) - off
        return f
    if re.match(r"\d{8}[ T]", body):                         # 20240101 22:00:00.123
        def f(x):
            b, off = split_tz(x)
            return _days(int(b[0:4]), int(b[4:6]), int(b[6:8])) * DAY_MS + _time_ms(b[9:]) - off
        return f
    raise ValueError(f"Unrecognised time format: {sample!r}")


def open_text(path):
    if path == "-":
        return sys.stdin
    if path.endswith(".gz"):
        return io.TextIOWrapper(gzip.open(path, "rb"), encoding="utf-8-sig", newline="")
    return open(path, "r", encoding="utf-8-sig", newline="")


def detect_columns(header):
    names = [h.strip().strip("<>").lower() for h in header]
    bid = next((i for i, n in enumerate(names) if "bid" in n and "vol" not in n), None)
    ask = next((i for i, n in enumerate(names) if "ask" in n and "vol" not in n), None)
    date = next((i for i, n in enumerate(names) if n == "date"), None)
    tcol = next((i for i, n in enumerate(names) if n == "time"), None)
    if date is not None and tcol is not None:
        return ("split", date, tcol), bid, ask, True
    t = next((i for i, n in enumerate(names) if "time" in n or "date" in n or n in ("ts", "timestamp")), None)
    return ("single", t, None), bid, ask, False


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", help="input CSV (.csv or .csv.gz, '-' = stdin)")
    ap.add_argument("output", help="output MT5 tick CSV")
    ap.add_argument("--spread", type=float, default=0.25,
                    help="fixed spread in USD (0.25 = 25 points on 2 digits). 0 = keep original spread. Default 0.25")
    ap.add_argument("--digits", type=int, default=2, help="price decimals of your broker's XAUUSD. Default 2")
    ap.add_argument("--tz", choices=["auto", "eet-us", "eet-eu", "fixed", "none"], default="auto",
                    help="UTC -> server time shift. auto = eet-us for UTC input, none for MT5-export input")
    ap.add_argument("--offset", type=float, default=2.0, help="hours, used with --tz fixed")
    ap.add_argument("--keep-duplicates", action="store_true",
                    help="keep ticks whose rounded bid/ask did not change")
    args = ap.parse_args()

    scale = 10 ** args.digits
    spread_i = int(round(args.spread * scale))
    fin = open_text(args.input)
    first = fin.readline()
    delim = "\t" if "\t" in first else (";" if first.count(";") > first.count(",") else ",")
    header = next(csv.reader([first], delimiter=delim))
    (tmode, tc1, tc2), bc, ac, is_mt5 = detect_columns(header)
    if bc is None or ac is None or tc1 is None:
        sys.exit(f"Could not find time/bid/ask columns in header: {header}")
    tz = args.tz if args.tz != "auto" else ("none" if is_mt5 else "eet-us")
    offset_fn = make_offset_fn(tz, args.offset)
    print(f"Input columns: time={header[tc1]}{'+' + header[tc2] if tc2 is not None else ''} "
          f"bid={header[bc]} ask={header[ac]} | delimiter={delim!r} | tz shift={tz}")
    print(f"Output: {args.digits} digits, spread="
          f"{'original' if spread_i == 0 else f'fixed ${spread_i / scale:.{args.digits}f} ({spread_i} points)'}")

    rdr = csv.reader(fin, delimiter=delim)
    out = open(args.output, "w", encoding="ascii", newline="\n")
    out.write("<DATE>\t<TIME>\t<BID>\t<ASK>\t<LAST>\t<VOLUME>\t<FLAGS>\n")

    parse = None
    last_bid = last_ask = None          # raw (MT5 exports can leave a side empty)
    prev_out = None
    prev_ms = -1
    n_in = n_out = n_dup = n_back = n_bad = 0
    max_dec = 0
    sp_sum = 0.0; sp_min = 1e9; sp_max = 0.0
    hist = [0] * 41                     # original spread histogram, $0.05 buckets, last = >= $2.00
    day_str_cache = {}
    fmt = f"{{:.{args.digits}f}}"

    for row in rdr:
        if not row:
            continue
        n_in += 1
        try:
            ttxt = row[tc1] + (" " + row[tc2] if tmode == "split" else "")
            if parse is None:
                parse = make_time_parser(ttxt)
            ms = parse(ttxt)
            b = row[bc].strip(); a = row[ac].strip()
            if b:
                if "." in b:
                    max_dec = max(max_dec, len(b) - b.index(".") - 1)
                last_bid = float(b)
            if a:
                last_ask = float(a)
            if last_bid is None or last_ask is None:
                continue
            bid, ask = last_bid, last_ask
        except (ValueError, IndexError):
            n_bad += 1
            continue

        sp = ask - bid
        sp_sum += sp; sp_min = min(sp_min, sp); sp_max = max(sp_max, sp)
        hist[min(40, max(0, int(sp / 0.05 + 1e-9)))] += 1

        if spread_i > 0:
            mid_i = (bid + ask) * 0.5 * scale
            bid_i = int(mid_i - spread_i / 2 + 0.5)
            ask_i = bid_i + spread_i
        else:
            bid_i = int(bid * scale + 0.5)
            ask_i = int(ask * scale + 0.5)

        if ms < prev_ms:
            n_back += 1                 # MT5 rejects out-of-order ticks
            continue
        prev_ms = ms
        if not args.keep_duplicates and (bid_i, ask_i) == prev_out:
            n_dup += 1
            continue
        prev_out = (bid_i, ask_i)

        sms = ms + offset_fn(ms)
        day = sms // DAY_MS
        ds = day_str_cache.get(day)
        if ds is None:
            ds = dt.date.fromordinal(day + EPOCH_ORD).strftime("%Y.%m.%d")
            day_str_cache[day] = ds
        r = sms - day * DAY_MS
        hh, r = divmod(r, HOUR_MS); mm, r = divmod(r, 60_000); ss, mss = divmod(r, 1000)
        out.write(f"{ds}\t{hh:02d}:{mm:02d}:{ss:02d}.{mss:03d}\t"
                  f"{fmt.format(bid_i / scale)}\t{fmt.format(ask_i / scale)}\t\t\t6\n")
        n_out += 1

    out.close()
    fin.close()
    n_ok = n_in - n_bad
    print(f"\nRows read: {n_in:,} | written: {n_out:,} | unchanged-price ticks dropped: {n_dup:,} | "
          f"out-of-order dropped: {n_back:,} | unreadable: {n_bad:,}")
    print(f"Input price decimals detected: {max_dec} (output: {args.digits})")
    if n_ok:
        print(f"ORIGINAL spread: min ${sp_min:.3f}  avg ${sp_sum / n_ok:.3f}  max ${sp_max:.3f}")
        acc, total = 0, sum(hist)
        for pct in (50, 90, 99):
            target = total * pct / 100
            acc = 0
            for i, c in enumerate(hist):
                acc += c
                if acc >= target:
                    label = ">= $2.00" if i == 40 else f"< ${(i + 1) * 0.05:.2f}"
                    print(f"  {pct}% of ticks had spread {label}")
                    break


if __name__ == "__main__":
    main()
