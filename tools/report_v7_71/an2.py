exec(open('an.py').read().split("print('ALL'")[0])
import statistics as st
for t in T:
    t['hold']=(t['t_out']-t['t_in']).total_seconds()/60
    t['wait']=(t['t_in']-max(t['armed'],t['t_in'].replace(hour=0,minute=0,second=0))).total_seconds()/60
print('slippage at entry ($): median %.3f mean %.3f  >0.1: %d  >0.3: %d'%(st.median(t['slip'] for t in T),st.mean(t['slip'] for t in T),sum(t['slip']>0.1 for t in T),sum(t['slip']>0.3 for t in T)))
for k in ('SL','BE','TP'):
    g=[t for t in T if t['kind']==k]
    print(k,'hold min: median %.1f  p25 %.1f p75 %.1f | exit move median %.2f'%(st.median(x['hold'] for x in g),*st.quantiles([x['hold'] for x in g],n=4)[::2],st.median(x['move'] for x in g)))
sl=[t for t in T if t['kind']=='SL']
print('SL trades stopped within 2 min: %d, 5 min: %d, 10 min: %d of %d'%(sum(t['hold']<=2 for t in sl),sum(t['hold']<=5 for t in sl),sum(t['hold']<=10 for t in sl),len(sl)))
print('SL exit move worse than -1.9 (slipped stop):',sum(t['move']<-1.9 for t in sl), ' mean SL move %.3f'%st.mean(t['move'] for t in sl))
by('LEVEL WIDTH (high-low of the setup, $)',lambda t:'none' if t['width'] is None else ('a <5' if t['width']<5 else 'b 5-10' if t['width']<10 else 'c 10-20' if t['width']<20 else 'd 20-30' if t['width']<30 else 'e 30+'))
by('LEVEL WIDTH x SETUP',lambda t:(t['setup'],'none' if t['width'] is None else ('a <5' if t['width']<5 else 'b 5-10' if t['width']<10 else 'c 10-20' if t['width']<20 else 'd 20+')))
by('MIN FROM LEVEL ACTIVE TO FILL',lambda t:'a <15' if t['wait']<15 else 'b 15-60' if t['wait']<60 else 'c 1-3h' if t['wait']<180 else 'd 3h+')
# trade number in day and previous result
day=collections.defaultdict(list)
for t in sorted(T,key=lambda x:x['t_in']): day[t['t_in'].date()].append(t)
for d,g in day.items():
    for i,t in enumerate(g):
        t['nday']=i+1; t['prev']= 'first' if i==0 else ('after loss' if g[i-1]['profit']<=0 else 'after win')
        t['same_dir_prev']= None if i==0 else (g[i-1]['buy']==t['buy'])
by('TRADE # IN DAY',lambda t:min(t['nday'],5))
by('PREVIOUS TRADE TODAY',lambda t:t['prev'])
by('SAME DIRECTION AS PREVIOUS TRADE TODAY',lambda t:t['same_dir_prev'],lambda t:t['same_dir_prev'] is not None)
# position vs previous day range
def pos(t):
    if t['pdh'] is None or t['pdl'] is None: return 'unknown'
    if t['fill']>t['pdh']: return 'above PDH'
    if t['fill']<t['pdl']: return 'below PDL'
    return 'inside PD range'
by('ENTRY vs PREVIOUS-DAY RANGE x SIDE',lambda t:(pos(t),'B' if t['buy'] else 'S'))
by('WITH/AGAINST previous-day breakout',lambda t:'with' if (pos(t)=='above PDH' and t['buy']) or (pos(t)=='below PDL' and not t['buy']) else ('against' if pos(t) in('above PDH','below PDL') else pos(t)))
by('OVERLAP double position',lambda t:t['t_in'] in {x['t_in'] for x in T if x is not t})
pickle.dump(T,open('trades2.pkl','wb'))
