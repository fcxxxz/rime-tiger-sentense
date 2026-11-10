from pathlib import Path
import csv, hashlib, json, math
B=Path('/tmp/tiger-100k-20261026-a3D7SM')

def percentile(values,q):
 values=sorted(values)
 return values[max(0,math.ceil(len(values)*q)-1)] if values else None

def hist_percentile(hist,q):
 threshold=math.ceil(sum(hist.values())*q); count=0
 for k,v in sorted(hist.items()):
  count+=v
  if count>=threshold:return k

def load(mode):
 rows={}; events={}; hist={}; latency=[]
 for shard in range(8):
  path=B/f'{mode}-{shard}.tsv'; done=False; shardn=0; shardkeys=0
  for line in path.open():
   p=line.rstrip('\n').split('\t')
   if p[0]=='R':
    _,id,text,raw,committed,final,wrong,commits,pk,pc,fpk,fpc,ms,maxms,chars,cchars=p
    id=int(id); assert id not in rows
    rows[id]={'id':id,'text':text,'raw':raw,'committed':committed,'final':final,'wrong':int(wrong),'commits':int(commits),'pk':int(pk),'pc':int(pc),'fpk':int(fpk),'fpc':int(fpc),'ms':float(ms),'maxms':float(maxms),'chars':int(chars),'cchars':int(cchars)}
    assert len(text)==int(chars) and len(committed)==int(cchars)
    assert int(wrong)==int(not text.startswith(committed))
    shardn+=1; shardkeys+=len(raw)
   elif p[0]=='W': events.setdefault(int(p[1]),[]).append({'key':int(p[2]),'text':p[3],'cumulative':p[4]})
   elif p[0]=='H': hist[int(p[1])]=hist.get(int(p[1]),0)+int(p[2])
   elif p[0]=='L': latency.append(float(p[1]))
   elif p[0]=='DONE':
    assert int(p[1])==shardn==12500 and int(p[2])==shardkeys; done=True
  assert done,f'Incomplete {path}'
 assert set(rows)==set(range(1,100001))
 keys=sum(len(r['raw']) for r in rows.values()); chars=sum(r['chars'] for r in rows.values())
 assert sum(hist.values())==keys
 assert set(events)=={i for i,r in rows.items() if r['wrong']}
 correct_committed=0
 for r in rows.values():
  for a,b in zip(r['text'],r['committed']):
   if a!=b:break
   correct_committed+=1
 metrics={'sentences':len(rows),'characters':chars,'keys':keys,'wrong_sentences':sum(r['wrong'] for r in rows.values()),'wrong_commit_events':sum(map(len,events.values())),'final_correct':sum(r['text']==r['final'] for r in rows.values()),'commits':sum(r['commits'] for r in rows.values()),'coverage':sum(r['cchars'] for r in rows.values())/chars,'correct_prefix_coverage':correct_committed/chars,'pending_keys_mean':sum(r['pk'] for r in rows.values())/keys,'pending_chars_mean':sum(r['pc'] for r in rows.values())/keys,'final_pending_keys_mean':sum(r['fpk'] for r in rows.values())/len(rows),'final_pending_chars_mean':sum(r['fpc'] for r in rows.values())/len(rows),'no_commit_sentences':sum(r['commits']==0 for r in rows.values()),'low_coverage_sentences':sum(r['cchars']/r['chars']<.3 for r in rows.values()),'latency_mean_ms':sum(r['ms'] for r in rows.values())/keys,'latency_max_ms':max(r['maxms'] for r in rows.values()),'latency_samples':len(latency)}
 for label,q in [('p50',.5),('p90',.9),('p99',.99)]:
  metrics['pending_keys_'+label]=hist_percentile(hist,q)
  metrics['final_pending_chars_'+label]=percentile([r['fpc'] for r in rows.values()],q)
  metrics['latency_'+label+'_ms']=percentile(latency,q)
 return rows,events,metrics

if __name__=='__main__':
 new,ne,nm=load('new'); old,oe,om=load('original')
 for id,n in new.items():
  o=old[id]; assert (n['text'],n['raw'])==(o['text'],o['raw'])
 manifest=json.loads((B/'manifest.json').read_text())
 for rel,meta in manifest['files'].items():
  p=B/rel
  assert hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==meta['sha256'],f'Changed {p}'
 for key,val in [('sentences',100000),('keys',2855645),('characters',1218539)]:assert nm[key]==om[key]==val
 paired={'both_wrong_early':len(set(ne)&set(oe)),'new_only_wrong_early':len(set(ne)-set(oe)),'original_only_wrong_early':len(set(oe)-set(ne)),'both_final_correct':sum(n['final']==n['text'] and old[i]['final']==n['text'] for i,n in new.items()),'new_only_final_correct':sum(n['final']==n['text'] and old[i]['final']!=n['text'] for i,n in new.items()),'original_only_final_correct':sum(n['final']!=n['text'] and old[i]['final']==n['text'] for i,n in new.items()),'new_less_final_pending':sum(n['fpc']<old[i]['fpc'] for i,n in new.items()),'original_less_final_pending':sum(n['fpc']>old[i]['fpc'] for i,n in new.items())}
 result={'new':nm,'original':om,'paired':paired}
 by_length=[]
 for low,high in [(4,8),(9,15),(16,30)]:
  ids=[i for i,r in new.items() if low<=r['chars']<=high]
  entry={'length':f'{low}-{high}','sentences':len(ids)}
  for mode,rows in [('new',new),('original',old)]:
   subset=[rows[i] for i in ids]
   entry[mode]={'wrong_sentences':sum(r['wrong'] for r in subset),
     'final_correct':sum(r['text']==r['final'] for r in subset),
     'coverage':sum(r['cchars'] for r in subset)/sum(r['chars'] for r in subset),
     'final_pending_chars_mean':sum(r['fpc'] for r in subset)/len(subset)}
  by_length.append(entry)
 result['by_length']=by_length
 with (B/'paired-differences.tsv').open('w') as h:
  writer=csv.writer(h,delimiter='\t')
  writer.writerow(['id','target','code','new_auto','original_auto','new_final','original_final','new_wrong_auto','original_wrong_auto','new_pending_chars','original_pending_chars'])
  for i,n in sorted(new.items()):
   o=old[i]
   if (n['wrong'],n['final'],n['fpc'])!=(o['wrong'],o['final'],o['fpc']):
    writer.writerow([i,n['text'],n['raw'],n['committed'],o['committed'],n['final'],o['final'],n['wrong'],o['wrong'],n['fpc'],o['fpc']])
 (B/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
 with (B/'all-errors.tsv').open('w') as h:
  writer=csv.writer(h,delimiter='\t');writer.writerow(['engine','id','target','code','auto_committed','final','wrong_auto','first_wrong_key','first_wrong_cumulative'])
  for mode,rows,events in [('new',new,ne),('original',old,oe)]:
   for i,r in sorted(rows.items()):
    if r['wrong'] or r['final']!=r['text']:
     first=events.get(i,[{}])[0]
     writer.writerow([mode,i,r['text'],r['raw'],r['committed'],r['final'],r['wrong'],first.get('key',''),first.get('cumulative','')])
 lines=['# 十万句误上屏清单','','每条显示第一次错误提交；后续级联错误保存在分片 W 行中。','']
 for title,rows,events in [('新版',new,ne),('虎整原版',old,oe)]:
  lines += [f'## {title}：{len(events)} 句','']
  for i,ev in sorted(events.items()):
   r=rows[i];e=ev[0]
   lines += [f"- **{r['text']}**（#{i}，第 {e['key']} 键）：错误上屏 `{e['cumulative']}`；最终 `{r['final']}`。"]
  lines.append('')
 (B/'early-errors.md').write_text('\n'.join(lines))
 print(json.dumps(result,ensure_ascii=False,indent=2))
