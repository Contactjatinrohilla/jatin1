import openpyxl, datetime as dt, pickle, collections
F='/root/.claude/uploads/da43ab64-eac2-56d3-ba14-1f5da96ff85a/541b9e02-Code_v7.71_XAUUSD_Report_Enhanced.xlsx'
wb=openpyxl.load_workbook(F,read_only=True,data_only=True)
rows=list(wb['Sheet1'].iter_rows(values_only=True))
P=lambda s: dt.datetime.strptime(s,'%Y.%m.%d %H:%M:%S')
orders={}
allorders=[]
for r in rows[127:1209]:
    v=[x for x in r if x is not None]
    if len(v)<9: continue
    o=dict(setup_time=P(v[0]),id=v[1],type=v[3],price=v[5],state=v[-2],comment=v[-1])
    if 'stop' in o['type']:
        o['sl']=v[6]; o['tp']=v[7]; o['done']=P(v[8])
    orders[o['id']]=o; allorders.append(o)
deals=[]
for r in rows[1211:]:
    v=[x for x in r if x is not None]
    if len(v)<12 or v[2]=='balance': continue
    deals.append(dict(t=P(v[0]),type=v[3],dir=v[4],vol=float(v[5]),price=v[6],order=v[7],profit=v[10],comment=v[12]))
trades=[]
openq=[]
dup=0
for d in deals:
    if d['dir']=='in':
        if openq: dup+=1
        openq.append(d); continue
    # out: closes the oldest open position of the opposite type
    k=next(j for j,a in enumerate(openq) if a['type']!=d['type'])
    a=openq.pop(k); b=d
    o=orders[a['order']]
    buy=a['type']=='buy'
    sgn=1 if buy else -1
    level=o['price']; fill=a['price']; ex=b['price']
    slpx=float(b['comment'].split()[1]) if b['comment'].startswith('sl') else None
    move=(ex-fill)*sgn
    if b['comment'].startswith('tp'): kind='TP'
    else:
        slmove=(slpx-fill)*sgn
        kind='SL' if slmove< -0.5 else ('BE' if slmove<0.45 else 'TRAIL')
    trades.append(dict(setup=a['comment'][:-2],buy=buy,t_in=a['t'],t_out=b['t'],level=level,fill=fill,exit=ex,
        slip=(fill-level)*sgn,move=move,profit=b['profit'],vol=a['vol'],kind=kind,armed=o['setup_time'],
        R=b['profit']/(a['vol']*100*1.8),overlap=False))
print('entries while another position open:',dup)
# level widths: pair stop orders with same setup_time and setup
grp=collections.defaultdict(dict)
for o in allorders:
    if 'stop' in o['type']:
        grp[(o['setup_time'],o['comment'][:-2])]['B' if o['type'].startswith('buy') else 'S']=o['price']
pdh={}
for (t,s),d in grp.items():
    if s=='PDH': pdh[t.date()]=d
for tr in trades:
    d=grp.get((tr['armed'],tr['setup']),{})
    tr['width']=(d['B']-d['S']) if 'B' in d and 'S' in d else None
    p=pdh.get(tr['t_in'].date(),{})
    tr['pdh']=p.get('B'); tr['pdl']=p.get('S')
pickle.dump(trades,open('/tmp/claude-0/-home-user-jatin1/da43ab64-eac2-56d3-ba14-1f5da96ff85a/scratchpad/trades.pkl','wb'))
print(len(trades), collections.Counter(t['kind'] for t in trades), sum(t['profit'] for t in trades))
