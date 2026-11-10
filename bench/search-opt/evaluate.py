from pathlib import Path
import hashlib, importlib.util, json, shutil, tarfile, gzip
B=Path(__file__).resolve().parent
PREV=Path('/tmp/tiger-perf-final-20261026-whp9ry9j')
ORIGINAL=Path('/tmp/tiger-100k-20261026-a3D7SM')
sp=importlib.util.spec_from_file_location('aggregate',ORIGINAL/'aggregate.py')
a=importlib.util.module_from_spec(sp);sp.loader.exec_module(a)
a.B=B
rows,events,metrics=a.load('new')
a.B=PREV
previous,prior_events,prior_metrics=a.load('new')
first=json.loads((ORIGINAL/'summary.json').read_text())['new']
static_before=json.loads(Path('/tmp/tiger-100k-rerun-20261026-r7ojxj5e/summary.json').read_text())['current']
fields=['text','raw','committed','final','wrong','commits','pk','pc','fpk','fpc','chars','cchars']
changes=[i for i,r in rows.items() if any(r[k]!=previous[i][k] for k in fields)]
assert not changes, f'Behaviour changed: {changes[:20]}'
assert events==prior_events, 'Error event sequence changed'
manifest=json.loads((B/'manifest.json').read_text())
for name,m in manifest['files'].items():
 with (B/name).open('rb') as f: assert hashlib.file_digest(f,'sha256').hexdigest()==m['sha256'],name
result={'current':metrics,'compact_baseline':prior_metrics,'before_static_verification':first,'before_performance_optimization':static_before,'changed_sentences':len(changes),'events_identical':events==prior_events}
(B/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
labels=[('CPU均值 ms/键','latency_mean_ms','.3f'),('CPU P50 ms','latency_p50_ms','.3f'),('CPU P90 ms','latency_p90_ms','.3f'),('CPU P99 ms','latency_p99_ms','.3f'),('错误提前上屏句数','wrong_sentences','d'),('最终首选正确句数','final_correct','d'),('自动字符覆盖率','coverage','.4%'),('平均未上屏字','pending_chars_mean','.6f')]
text=['# 提前上屏第二轮性能优化（2026-10-26）','',
'同一批100000句、1218539字、2855645键。语料、驱动、模型及词表均沿用前次，all_ranks=false、user_model=false。八片各12500句，ID完整覆盖1..100000。','',
'| 指标 | 最初版本 | 新增静态复核后 | 上轮紧凑接口 | 本轮优化 |','|---|---:|---:|---:|---:|']
for label,key,fmt in labels:
 text.append('| '+label+' | '+' | '.join(format(m[key],fmt) for m in [first,static_before,prior_metrics,metrics])+' |')
text += ['',f"相对上轮紧凑接口，均值下降{100*(1-metrics['latency_mean_ms']/prior_metrics['latency_mean_ms']):.2f}%，P99下降{100*(1-metrics['latency_p99_ms']/prior_metrics['latency_p99_ms']):.2f}%；目前均值为最初版本的{metrics['latency_mean_ms']/first['latency_mean_ms']:.3f}倍。",'',
'本轮与紧凑接口基线全部非时间R字段零差异，W错误事件完全一致，H未上屏键分布一致。500句14474键trace亦字节一致。最初版本采用不同静态复核判定，准确性并不相同，因此不能将其速度作为完全等价实现的保证。','',
'## 改动','',
'- 字符模型静态概率缓存与带用户增益的workspace缓存分离，在普通与静态搜索间共享纯模型底分，容量有界；模型与blend在engine生命周期内不变，失败时清理。',
'- 只对最近全量重建、相同规范raw、非词模式且完全没有用户统计或个人覆盖的搜索图复用完整静态视图；增量图及所有个人影响场景仍回退隔离重建。',
'- 前缀证据每行只扫描一次UTF8字边界，复用同前缀质量，保留边界遍历和浮点累加次序。',
'- UTF8验证使用Lua标准库utf8.len的严格原生实现；无标准函数时仍走原校验。完整证据、阈值和学习隔离不变。','',
'## 验证及限制','',
'以完整原始结果而非仅汇总比较。速度为os.clock处理器CPU时间，不包括每键菜单渲染；均值统计所有键，分位数每四键采样一次。语料来自V5训练池，不是独立泛化留出集。个人学习在全量测评中关闭，个人隔离、配置失效另由回归验证。', '',
'本轮未提交Git、未部署实时输入法。工作区还有其他会话的既有未提交改动。','',
'[汇总](summary.json)、[manifest](manifest.json)、[原始结果](raw-results.tar.gz)、[运行时代码](runtime-snapshot.tar.gz)、[共同语料](corpus.tsv.gz)。']
(B/'report.md').write_text('\n'.join(text)+'\n')
d=Path('/Users/fuchuxuan/输入法/rime-tiger/docs/reports')/('2026-10-26-'+B.name)
assert not d.exists();d.mkdir()
for name in ['summary.json','report.md','manifest.json','driver.lua','evaluate.py']:shutil.copy2(B/name,d/name)
shutil.copy2(ORIGINAL/'aggregate.py',d/'aggregate.py')
with tarfile.open(d/'raw-results.tar.gz','w:gz') as t:
 for pat in ['new-[0-7].tsv','new-[0-7].log']:
  for p in sorted(B.glob(pat)):t.add(p,arcname=p.name)
with tarfile.open(d/'runtime-snapshot.tar.gz','w:gz') as t:
 for p in sorted((B/'final').rglob('*')):
  if p.is_file() and p.suffix not in {'.bin','.zip'}:t.add(p,arcname=str(p.relative_to(B)))
with (B/'corpus.tsv').open('rb') as src,gzip.open(d/'corpus.tsv.gz','wb') as dst:shutil.copyfileobj(src,dst)
artifacts={}
for p in d.iterdir():
 with p.open('rb') as f:artifacts[p.name]=hashlib.file_digest(f,'sha256').hexdigest()
(d/'artifact-sha256.json').write_text(json.dumps(artifacts,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2));print('REPORT',d/'report.md')
