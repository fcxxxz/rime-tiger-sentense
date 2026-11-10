from pathlib import Path
import json
B=Path('/tmp/tiger-errors-20261027-di_havvm')
PREV=Path('/tmp/tiger-100k-20261026-a3D7SM')
# error-corpus.tsv: original_id \t text \t code (subset order); corpus.tsv: same order minus id column.
ids=[int(l.split('\t')[0]) for l in (B/'error-corpus.tsv').read_text().splitlines()]
assert len(ids)==2094
# Verify subset corpus line N matches error-corpus row N.
sub=(B/'corpus.tsv').read_text().splitlines()
err=(B/'error-corpus.tsv').read_text().splitlines()
for n in (0,1,500,1500,2093):
 f=sub[n].split('\t');e=err[n].split('\t')
 assert f[0]==e[1] and f[1]==e[2],n
def load_subset(path):
 rows={};events={}
 for line in path.read_text().splitlines():
  p=line.split('\t')
  if p[0]=='R':
   rows[int(p[1])]={'text':p[2],'raw':p[3],'committed':p[4],'final':p[5],'wrong':int(p[6]),'commits':int(p[7]),'fpk':int(p[10]),'fpc':int(p[11])}
  elif p[0]=='W':events.setdefault(int(p[1]),[]).append((int(p[2]),p[3],p[4]))
 return rows,events
cur_new,cur_ne=load_subset(B/'subset-new.tsv')
cur_old,cur_oe=load_subset(B/'subset-original.tsv')
def load_prev(mode):
 rows={};events={}
 for p in PREV.glob(mode+'-[0-7].tsv'):
  for line in p.read_text().splitlines():
   f=line.split('\t')
   if f[0]=='R':
    i=int(f[1]);rows[i]={'committed':f[4],'final':f[5],'wrong':int(f[6]),'commits':int(f[7]),'fpk':int(f[10]),'fpc':int(f[11])}
   elif f[0]=='W':events.setdefault(int(f[1]),[]).append((int(f[2]),f[3],f[4]))
 return rows,events
prev_new,prev_ne=load_prev('new');prev_old,prev_oe=load_prev('original')
fields=['committed','final','wrong','commits','fpk','fpc']
def diff(cur,prev):
 return sorted(ids[i-1] for i in cur if any(cur[i][k]!=prev[ids[i-1]][k] for k in fields))
result={
 'new_wrong':sum(cur_new[i]['wrong'] for i in cur_new),
 'new_wrong_before':sum(prev_new[ids[i-1]]['wrong'] for i in cur_new),
 'original_wrong':sum(cur_old[i]['wrong'] for i in cur_old),
 'original_wrong_before':sum(prev_old[ids[i-1]]['wrong'] for i in cur_old),
 'new_changed':diff(cur_new,prev_new),
 'original_changed':diff(cur_old,prev_old),
 'new_fixed_early':sorted(ids[i-1] for i in cur_new if cur_new[i]['wrong']==0 and prev_new[ids[i-1]]['wrong']==1),
 'new_new_early_errors':sorted(ids[i-1] for i in cur_new if cur_new[i]['wrong']==1 and prev_new[ids[i-1]]['wrong']==0),
 'original_fixed_early':sorted(ids[i-1] for i in cur_old if cur_old[i]['wrong']==0 and prev_old[ids[i-1]]['wrong']==1),
 'original_new_early_errors':sorted(ids[i-1] for i in cur_old if cur_old[i]['wrong']==1 and prev_old[ids[i-1]]['wrong']==0),
 'new_final_still_wrong':sorted(ids[i-1] for i in cur_new if cur_new[i]['final']!=cur_new[i]['text']),
 'original_final_still_wrong':sorted(ids[i-1] for i in cur_old if cur_old[i]['final']!=cur_old[i]['text']),
}
(B/'subset-summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
for k,v in result.items():print(k,len(v) if isinstance(v,list) else v, '' if not isinstance(v,list) or len(v)>12 else v)
