"""Parse an MT5 Strategy Tester .xlsx report into settings, orders and paired trades."""
import datetime as dt
import openpyxl


def _num(v):
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return float(str(v).replace(" ", "").split("/")[0])


def _t(s):
    return dt.datetime.strptime(s, "%Y.%m.%d %H:%M:%S")


def parse(path):
    ws = openpyxl.load_workbook(path, data_only=False).active
    rows = [[c.value for c in r] for r in ws.iter_rows()]
    info, inputs, results = {}, [], {}
    sec = None
    orders, deals = {}, []
    for r in rows:
        a = r[0]
        if a in ("Settings", "Results", "Orders", "Deals"):
            sec = a
            continue
        if sec in ("Settings", "Results"):
            cells = [x for x in r if x is not None]
            if not cells:
                continue
            if sec == "Settings":
                if isinstance(a, str) and a.endswith(":"):
                    info[a[:-1]] = cells[1] if len(cells) > 1 else ""
                    if a == "Inputs:":
                        inputs.append(cells[1])
                elif a is None and cells:
                    inputs.append(cells[0])
            else:
                for i in range(0, len(r) - 1):
                    if isinstance(r[i], str) and r[i].endswith(":"):
                        nxt = next((x for x in r[i + 1:] if x is not None), None)
                        results[r[i][:-1]] = nxt
        elif sec == "Orders" and isinstance(r[1], (int, float)):
            orders[int(r[1])] = dict(open=_t(r[0]), type=r[3], price=_num(r[6]), sl=_num(r[7]),
                                     tp=_num(r[8]), state=r[11], comment=r[12])
        elif sec == "Deals" and isinstance(r[1], (int, float)) and r[3] in ("buy", "sell"):
            deals.append(dict(time=_t(r[0]), deal=int(r[1]), type=r[3], dir=r[4], vol=_num(r[5]),
                              price=_num(r[6]), order=int(r[7]), comm=_num(r[8]) or 0,
                              swap=_num(r[9]) or 0, profit=_num(r[10]) or 0, comment=r[12] or ""))
        elif sec == "Deals" and r[3] == "balance":
            info["Deposit deal"] = _num(r[10])

    # pair: an OUT deal closes the open IN deal of the opposite type (one leg per side)
    deals.sort(key=lambda d: (d["time"], 0 if d["dir"] == "in" else 1, d["deal"]))
    open_by_type, trades = {}, []
    for d in deals:
        if d["dir"] == "in":
            open_by_type.setdefault(d["type"], []).append(d)
        else:
            want = "buy" if d["type"] == "sell" else "sell"
            ent = open_by_type[want].pop(0)
            o = orders.get(ent["order"], {})
            trades.append(dict(entry=ent, exit=d, order=o))
    trades.sort(key=lambda t: (t["entry"]["time"], t["entry"]["deal"]))
    return info, inputs, results, trades
