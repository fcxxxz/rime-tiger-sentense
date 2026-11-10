from pathlib import Path
import csv, gzip, hashlib, importlib.util, json, shutil, tarfile
B=Path('/tmp/tiger-100k-rerun-20261026-r7ojxj5e')
OLD=Path('/tmp/tiger-100k-20261026-a3D7SM')
SPEC=importlib.util.spec_from_file_location('baseline_aggregate',OLD/'aggregate.py')
a=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(a)
a.B=B
rows,events,metrics=a.load('new')
a.B=OLD
previous,previous_events,previous_metrics=a.load('new')
original=json.loads((OLD/'summary.json').read_text())['original']
manifest=json.loads((B/'manifest.json').read_text())
for name,meta in manifest['files'].items():
 with (B/name).open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==meta['sha256'],name
for i,r in rows.items():assert (r['text'],r['raw'])==(previous[i]['text'],previous[i]['raw'])
changed=[i for i,r in rows.items() if any(r[k]!=previous[i][k] for k in ['committed','final','wrong','commits','pk','pc','fpk','fpc'])]
paired={'changed_sentences':len(changed),'fixed_early':sorted(set(previous_events)-set(events)),'new_early_errors':sorted(set(events)-set(previous_events)),
 'fixed_final':[i for i,r in rows.items() if r['final']==r['text'] and previous[i]['final']!=r['text']],
 'regressed_final':[i for i,r in rows.items() if r['final']!=r['text'] and previous[i]['final']==r['text']],
 'less_pending':sum(r['fpc']<previous[i]['fpc'] for i,r in rows.items()),'more_pending':sum(r['fpc']>previous[i]['fpc'] for i,r in rows.items())}
summary={'current':metrics,'previous':previous_metrics,'original_reference':original,'paired':paired}
(B/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
with (B/'changed-sentences.tsv').open('w') as f:
 w=csv.writer(f,delimiter='\t');w.writerow(['id','target','code','previous_auto','current_auto','previous_final','current_final','previous_wrong','current_wrong','previous_pending_chars','current_pending_chars'])
 for i in changed:
  r,p=rows[i],previous[i];w.writerow([i,r['text'],r['raw'],p['committed'],r['committed'],p['final'],r['final'],p['wrong'],r['wrong'],p['fpc'],r['fpc']])
with (B/'all-errors.tsv').open('w') as f:
 w=csv.writer(f,delimiter='\t');w.writerow(['id','target','code','auto_committed','final','wrong_auto','first_wrong_key','first_wrong_text'])
 for i,r in sorted(rows.items()):
  if r['wrong'] or r['final']!=r['text']:
   e=events.get(i,[{}])[0];w.writerow([i,r['text'],r['raw'],r['committed'],r['final'],r['wrong'],e.get('key',''),e.get('cumulative','')])
lines=['# 优化后新版十万句错误提前上屏清单','',f'共 {len(events)} 句。','']
for i,e in sorted(events.items()):lines.append(f"- **{rows[i]['text']}**（#{i}，第{e[0]['key']}键）：`{e[0]['cumulative']}`；最终 `{rows[i]['final']}`。")
(B/'early-errors.md').write_text('\n'.join(lines))
columns=[('错误提前上屏句数','wrong_sentences','d'),('错误提交事件','wrong_commit_events','d'),('最终首选正确句数','final_correct','d'),('自动字符覆盖率','coverage','.2%'),('全程平均未上屏键','pending_keys_mean','.3f'),('全程平均未上屏字','pending_chars_mean','.3f'),('打完瞬间平均未上屏字','final_pending_chars_mean','.3f'),('未上屏键P90','pending_keys_p90','d'),('零自动提交句数','no_commit_sentences','d'),('CPU均值(ms/键)','latency_mean_ms','.3f'),('CPU P50(ms)','latency_p50_ms','.3f'),('CPU P90(ms)','latency_p90_ms','.3f'),('CPU P99(ms)','latency_p99_ms','.3f')]
report=['# 优化后新版十万句复测（2026-10-26）','',
 '当前新版完整运行上轮相同的100,000句、1,218,539字、2,855,645键。驱动、语料、模型、词表哈希与上轮完全相同；仅更换当前工作区运行时代码和动态库。8片各12500句，ID完整覆盖1–100000。','',
 '| 指标 | 上轮新版 | 优化后新版 | 虎整原版（上轮参考） |','|---|---:|---:|---:|']
for title,k,fmt in columns:report.append('| '+title+' | '+' | '.join(format(m[k],fmt) for m in [previous_metrics,metrics,original])+' |')
report+=['',f"上屏/文本/未上屏行为发生变化：{len(changed)}句；修复原有误上屏{len(paired['fixed_early'])}句，新增误上屏{len(paired['new_early_errors'])}句；修复最终首选{len(paired['fixed_final'])}句，新增最终错误{len(paired['regressed_final'])}句。",'',
 '本轮沿用all_ranks=false、user_model=false、出厂提前上屏门槛及每句隔离。个人学习关闭，因此专门针对个人学习污染的优化不一定在本口径体现收益。CPU耗时仅包含processor，不含逐键菜单渲染；均值按全部按键计算，分位数每4键采样1次。语料来自V5训练语料池，结果不能视作独立留出集的泛化准确率。', '',
 '原版仅复用上轮完整结果，本轮没有重新运行原版。当前快照冻结后不受工作区后续改动影响。','',
 '## 文件','', '[全部错误提前提交](early-errors.md)、[全部最终错误](all-errors.tsv)、[前后变化句子](changed-sentences.tsv)、[完整汇总](summary.json)、[哈希清单](manifest.json)、[原始结果](raw-results.tar.gz)。', '',
 f'冻结运行目录：`{B}`。基线目录：`{OLD}`。没有修改、部署或提交生产代码。']
(B/'report.md').write_text('\n'.join(report)+'\n')
DEST=Path('/Users/fuchuxuan/输入法/rime-tiger/docs/reports')/B.name
assert not DEST.exists();DEST.mkdir()
for name in ['summary.json','manifest.json','driver.lua','report.md','early-errors.md','all-errors.tsv','changed-sentences.tsv','evaluate.py']:
 shutil.copy2(B/name,DEST/name)
shutil.copy2(OLD/'aggregate.py',DEST/'baseline-aggregate.py')
with tarfile.open(DEST/'raw-results.tar.gz','w:gz') as out:
 for pattern in ['new-[0-7].tsv','new-[0-7].log']:
  for p in sorted(B.glob(pattern)):out.add(p,arcname=p.name)
with tarfile.open(DEST/'runtime-snapshot.tar.gz','w:gz') as out:
 for p in sorted((B/'new').rglob('*')):
  if p.is_file() and p.suffix!='.bin':out.add(p,arcname=str(p.relative_to(B)))
with (B/'corpus.tsv').open('rb') as src,gzip.open(DEST/'corpus.tsv.gz','wb') as dst:shutil.copyfileobj(src,dst)
artifacts={}
for p in DEST.iterdir():
 with p.open('rb') as f:artifacts[p.name]=hashlib.file_digest(f,'sha256').hexdigest()
(DEST/'artifact-sha256.json').write_text(json.dumps(artifacts,indent=2))
print(json.dumps(summary,ensure_ascii=False,indent=2));print('REPORT',DEST/'report.md')
