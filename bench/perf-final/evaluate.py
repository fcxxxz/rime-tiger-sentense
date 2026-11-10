from pathlib import Path
import csv, gzip, hashlib, importlib.util, json, shutil, tarfile
B=Path(__file__).resolve().parent
PREV=Path('/tmp/tiger-100k-rerun-20261026-r7ojxj5e')
spec=importlib.util.spec_from_file_location('aggregate',Path('/tmp/tiger-100k-20261026-a3D7SM/aggregate.py'))
a=importlib.util.module_from_spec(spec);spec.loader.exec_module(a)
a.B=B
current,events,metrics=a.load('new')
a.B=PREV
previous,prev_events,prev_metrics=a.load('new')
fields=['text','raw','committed','final','wrong','commits','pk','pc','fpk','fpc','chars','cchars']
changed=[i for i,r in current.items() if any(r[k]!=previous[i][k] for k in fields)]
result={'optimized':metrics,'previous':prev_metrics,'changed_sentence_count':len(changed),'changed_ids':changed,'event_records_identical':events==prev_events}
manifest=json.loads((B/'manifest.json').read_text())
for name,meta in manifest['files'].items():
 with (B/name).open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==meta['sha256'],name
(B/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
with (B/'behaviour-changes.tsv').open('w') as f:
 w=csv.writer(f,delimiter='\t');w.writerow(['id','target','previous_auto','optimized_auto','previous_final','optimized_final','previous_wrong','optimized_wrong'])
 for i in changed:
  c,p=current[i],previous[i];w.writerow([i,c['text'],p['committed'],c['committed'],p['final'],c['final'],p['wrong'],c['wrong']])
columns=[('错误提前上屏句数','wrong_sentences','d'),('错误提交事件','wrong_commit_events','d'),('最终首选正确句数','final_correct','d'),('自动字符覆盖率','coverage','.4%'),('平均未上屏键','pending_keys_mean','.6f'),('平均未上屏字','pending_chars_mean','.6f'),('打完瞬间平均未上屏字','final_pending_chars_mean','.6f'),('提交次数','commits','d'),('CPU均值(ms/键)','latency_mean_ms','.3f'),('CPU P50(ms)','latency_p50_ms','.3f'),('CPU P90(ms)','latency_p90_ms','.3f'),('CPU P99(ms)','latency_p99_ms','.3f')]
report=['# 提前上屏静态复核性能优化验证（2026-10-26）','',
'同一批100,000句、1,218,539字、2,855,645键，8片各12500句全部完成。语料、模型、词表和driver同上一轮，all_ranks=false、user_model=false，出厂提前提交门槛不变。','',
'| 指标 | 优化前 | 性能优化后 |','|---|---:|---:|']
for label,k,fmt in columns:report.append('| '+label+' | '+format(prev_metrics[k],fmt)+' | '+format(metrics[k],fmt)+' |')
report+=['',f"与上一轮全部非时间句级字段发生差异：{len(changed)}句；W错误事件列表一致：{events==prev_events}。",'',f"处理器CPU均值下降{(1-metrics['latency_mean_ms']/prev_metrics['latency_mean_ms'])*100:.2f}%，P99下降{(1-metrics['latency_p99_ms']/prev_metrics['latency_p99_ms'])*100:.2f}%。该计时不含逐键候选窗渲染、初始化或收尾解码；P50/P90/P99每4键采样一次，均值统计全部按键。",'',
'语料来自V5既有训练语料池，不能当作独立留出集泛化准确率。此次测量关闭个人学习，有个人词/个人上下文场景另由回归测试验证。','',
'[汇总](summary.json)、[行为差异](behaviour-changes.tsv)、[原始结果](raw-results.tar.gz)、[运行时代码快照](runtime-snapshot.tar.gz)、[哈希清单](manifest.json)。','',f'运行目录：`{B}`。未提交Git。']
(B/'report.md').write_text('\n'.join(report)+'\n')
DEST=Path('/Users/fuchuxuan/输入法/rime-tiger/docs/reports')/B.name
assert not DEST.exists();DEST.mkdir()
for name in ['summary.json','report.md','behaviour-changes.tsv','manifest.json','driver.lua','evaluate.py']:
 shutil.copy2(B/name,DEST/name)
shutil.copy2('/tmp/tiger-100k-20261026-a3D7SM/aggregate.py',DEST/'aggregate.py')
with tarfile.open(DEST/'raw-results.tar.gz','w:gz') as out:
 for pattern in ['new-[0-7].tsv','new-[0-7].log']:
  for p in sorted(B.glob(pattern)):out.add(p,arcname=p.name)
with tarfile.open(DEST/'runtime-snapshot.tar.gz','w:gz') as out:
 for p in sorted((B/'new').rglob('*')):
  if p.is_file() and p.suffix not in {'.bin','.zip'} and not any(x.startswith('.') for x in p.relative_to(B/'new').parts):out.add(p,arcname=str(p.relative_to(B)))
with (B/'corpus.tsv').open('rb') as src,gzip.open(DEST/'corpus.tsv.gz','wb') as out:shutil.copyfileobj(src,out)
artifacts={}
for p in DEST.iterdir():
 with p.open('rb') as f:artifacts[p.name]=hashlib.file_digest(f,'sha256').hexdigest()
(DEST/'artifact-sha256.json').write_text(json.dumps(artifacts,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2));print('REPORT',DEST/'report.md')
