import pickle, statistics as st, collections
T=pickle.load(open('trades.pkl','rb'))
def S(g):
    n=len(g)
    if not n: return 'n=0'
    w=[t for t in g if t['profit']>0]; l=[t for t in g if t['profit']<=0]
    gp=sum(t['profit'] for t in w); gl=-sum(t['profit'] for t in l)
    net=gp-gl
    # max dd of cumulative R within group
    c=pk=dd=0
    for t in sorted(g,key=lambda x:x['t_in']):
        c+=t['R']; pk=max(pk,c); dd=max(dd,pk-c)
    k=collections.Counter(t['kind'] for t in g)
    return f"n={n:3d} win%={100*len(w)/n:4.0f} PF={gp/gl if gl else 99:4.2f} avgR={sum(t['R'] for t in g)/n:+.3f} net=${net:7.0f} ddR={dd:4.1f}  TP={k['TP']:3d} BE={k['BE']:3d} SL={k['SL']:3d}"
def by(title,key,filt=lambda t:True):
    print('\n'+title)
    g=collections.defaultdict(list)
    for t in T:
        if filt(t): g[key(t)].append(t)
    for k in sorted(g): print(f"  {str(k):<22}",S(g[k]))
print('ALL',S(T))
by('SETUP',lambda t:t['setup'])
by('SIDE',lambda t:'BUY' if t['buy'] else 'SELL')
by('SETUP x SIDE',lambda t:t['setup']+(' BUY' if t['buy'] else ' SELL'))
by('HOUR (server)',lambda t:t['t_in'].hour)
by('HOUR x SIDE',lambda t:(t['t_in'].hour,'B' if t['buy'] else 'S'))
by('HOUR x SETUP',lambda t:(t['t_in'].hour,t['setup']))
by('DOW',lambda t:t['t_in'].strftime('%w %a'))
by('MONTH',lambda t:t['t_in'].strftime('%Y-%m'))
by('EXIT kind',lambda t:t['kind'])
