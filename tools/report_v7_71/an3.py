exec(open('an.py').read().split("print('ALL'")[0])
import math
T=pickle.load(open('trades2.pkl','rb'))
def se(g):
    r=[t['R'] for t in g]; return st.stdev(r)/math.sqrt(len(r))
print('overall avgR %.3f  SE %.3f  stdev %.2f'%(st.mean(t['R'] for t in T),se(T),st.stdev(t['R'] for t in T)))
def sess(h):
    return ('1 Asia 01-07' if h<8 else '2 08-09 pre-London' if h<10 else '3 10-11 London open' if h<12 else '4 12-15 midday/US data' if h<16 else '5 16 NY open' if h<17 else '6 17-21 late')
by('SESSION',lambda t:sess(t['t_in'].hour))
by('SESSION x SIDE',lambda t:(sess(t['t_in'].hour),'B' if t['buy'] else 'S'))
def h4age(t):
    m=(t['t_in'].hour%4)*60+t['t_in'].minute
    return 'a first 30 min of H4 candle' if m<30 else 'b 30-60 min' if m<60 else 'c 1-2 h' if m<120 else 'd 2-4 h'
by('H4: minutes into the H4 candle at entry',h4age,lambda t:t['setup']=='H4')
by('RANGE: minutes after range end',lambda t:'a <30' if t['wait']<30 else 'b 30-60' if t['wait']<60 else 'c 60+',lambda t:t['setup']=='RANGE')
by('ALL: minutes after level became active',lambda t:'a <30' if t['wait']<30 else 'b 30-60' if t['wait']<60 else 'c 60-180' if t['wait']<180 else 'd 180+')
# outcome probabilities vs random walk
n=len(T); reach=sum(t['kind'] in('BE','TP') for t in T); tp=sum(t['kind']=='TP' for t in T)
print('\nreached +0.80: %d/%d = %.1f%%  | of those reached +1.80 (TP): %d/%d = %.1f%%'%(reach,n,100*reach/n,tp,reach,100*tp/reach))
for s in (0.20,0.25,0.30):
    print(' random-walk with spread %.2f: P(+0.8 before SL)=%.1f%%  P(TP before BE stop | at +0.8)=%.1f%%'%(s,100*(1.8-s)/2.6,100*0.5/1.5))
# cost per trade
print('entry slip mean %.3f, SL overshoot mean %.3f'%(st.mean(t['slip'] for t in T),st.mean(-t['move']-1.8 for t in T if t['kind']=='SL')))
# what if no BE (random walk from +0.8): TP 1.0 away, SL 2.6 away
be=[t for t in T if t['kind']=='BE']
print('BE trades',len(be),'sum R %.1f'%sum(t['R'] for t in be))
# R per kind
for k in ('TP','BE','SL'): print(k,'avg R %.3f'%st.mean(t['R'] for t in T if t['kind']==k))
