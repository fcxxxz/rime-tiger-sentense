from pathlib import Path
import json
B=Path('/tmp/tiger-100k-20261026-a3D7SM')
s=json.loads((B/'summary.json').read_text());n=s['new'];o=s['original'];p=s['paired']
rows=[]
def add(label,key,fmt='{:.2f}'):
 rows.append('| '+label+' | '+fmt.format(n[key])+' | '+fmt.format(o[key])+' |')
add('错误提前上屏句数','wrong_sentences','{:d}')
add('错误提交事件（含首错后的级联）','wrong_commit_events','{:d}')
add('最终整句正确数','final_correct','{:d}')
rows.append(f"| 最终首选准确率 | {n['final_correct']/1000:.3f}% | {o['final_correct']/1000:.3f}% |")
rows.append(f"| 自动上屏字符覆盖率 | {n['coverage']*100:.2f}% | {o['coverage']*100:.2f}% |")
rows.append(f"| 正确公共前缀自动覆盖率 | {n['correct_prefix_coverage']*100:.2f}% | {o['correct_prefix_coverage']*100:.2f}% |")
for label,key in [('全程平均未上屏键','pending_keys_mean'),('全程平均未上屏字','pending_chars_mean'),('打完瞬间平均未上屏键','final_pending_keys_mean'),('打完瞬间平均未上屏字','final_pending_chars_mean')]:add(label,key)
for label,key in [('未上屏键 P50','pending_keys_p50'),('未上屏键 P90','pending_keys_p90'),('未上屏键 P99','pending_keys_p99'),('整句零自动提交','no_commit_sentences'),('自动覆盖不足30%的句子','low_coverage_sentences')]:add(label,key,'{:d}')
for label,key in [('逐键处理器CPU均值（ms）','latency_mean_ms'),('逐键处理器CPU P50（ms）','latency_p50_ms'),('逐键处理器CPU P90（ms）','latency_p90_ms'),('逐键处理器CPU P99（ms）','latency_p99_ms')]:add(label,key,'{:.3f}')
length_rows=[]
for entry in s['by_length']:
 a,c=entry['new'],entry['original'];count=entry['sentences']
 length_rows.append(f"| {entry['length']} 字 | {count:,} | {a['wrong_sentences']} / {c['wrong_sentences']} | {a['coverage']*100:.2f}% / {c['coverage']*100:.2f}% | {a['final_pending_chars_mean']:.2f} / {c['final_pending_chars_mean']:.2f} |")
length_table='\n'.join(length_rows)
text=f'''# 新版虎码整句与虎整原版：十万句同码对照（2026-10-26）

本轮双方完整运行同一批 **100,000 句、1,218,539 字、2,855,645 键**，逐句配对核验，无跳过分片。结果是固定码表、固定模型、关闭个人学习后的离线逐键测评。

## 结果

| 指标 | 新版 | 虎整原版 |
|---|---:|---:|
'''+ '\n'.join(rows)+f'''

错误提前上屏率分别为 **{n['wrong_sentences']/1000:.3f}%** 与 **{o['wrong_sentences']/1000:.3f}%**。按句计错，只要该句任一笔自动提交不再是目标句的前缀即记错；后续连锁错误另记为事件，不重复增加错句数。

## 逐句差异

- 双方都发生错误提前提交：{p['both_wrong_early']} 句；仅新版发生：{p['new_only_wrong_early']} 句；仅原版发生：{p['original_only_wrong_early']} 句。
- 最终首选仅新版正确：{p['new_only_final_correct']} 句；仅原版正确：{p['original_only_final_correct']} 句；双方均正确：{p['both_final_correct']} 句。
- 打完瞬间，新版剩余未上屏字更少：{p['new_less_final_pending']} 句；原版更少：{p['original_less_final_pending']} 句；其余持平。

## 按句长分组

下表成对指标均按“新版 / 原版”排列。

| 句长 | 句数 | 错误提前上屏句数 | 自动字符覆盖率 | 打完瞬间未上屏字数均值 |
|---|---:|---:|---:|---:|
{length_table}

16–30字组中，新版打完平均剩余1.63字、原版10.00字，是本轮积极性差距最大的部分。该比较使用各自默认提前提交策略，不能仅从该表断言差距全由模型导致。

## 版本与参数

新版使用工作区当前快照（Git 基础 `56fb959`，另含未提交的 tracker、同码首选组句与排序修复；具体 SHA-256 见 manifest）。原生引擎 + V5 `TCSKNM04` 模型 389,671,262 字节。显式配置 `all_ranks="false"`、`two_char_word_gate="false"`、`native_short_codes=true`，提前提交采用 processor 出厂默认：门槛 0.99，普通证据3键、强证据2键。个人模型 `user_model=false`，无学习通知器与用户词库导入。

原版为用户本地 `Rime虎整句-20260826`，版本文件声明“自动提前上屏尾码置信度修正版”，基础源码 `c3b0a4a` 加包内改进。原包纯 Lua 引擎 + `TCSKNM02` 模型 **224,475,584 字节**，启动时调用 `model_status()` 并断言 `loaded=true`。原版固定门槛0.995、三代连续证据及至少3键存活尾码。保留原包11条静态 supplement；它属于出厂默认，原版无在线自学习实现。

双方保留各自发布算法与默认阈值，本轮比较整个方案，不将质量或速度差异单独归因于模型或算法。

## 共同语料与统计口径

从先前构建的 fenci 语料池 `/tmp/corpus79w.tsv` 提取目标句，先去重，再筛选双方都能编码的句子（786,086句），固定随机种子 `20261026` 抽100,000句。共同单字集合8,500字：每个字要求**在双方同一个码位都为rank1**，码长不少于2，并在共同码集合中按“长度、字典序”选最短码；不用一码简码，不用非首选码，不因某方案预测结果改目标。句长4–30字，完整输入最长80键。

这是已有V5训练语料池的复现测评，未做双方训练集去重，**不能作为独立留出集泛化准确率**。样本来自历史fenci池，并不保证31个源域等额抽样。

每个按键后统计：未上屏键=实际存活input长度；未上屏字=已完整打完码的目标字符数减已上屏Unicode字符数（下限0）。“全程平均”以按键加权；“打完瞬间”以句子等权。自动覆盖率以Unicode字符计，不混用字节和按键；正确公共前缀覆盖率只计已上屏串与目标相同的开头，排除错字后的字符。

收尾首选带已提交编码链解码。原版先筛选延续已提交文本的非空候选，再取首项；新版另要求已提交文本处的raw边界精确对齐。此前旧worker直接取全局首项再裁前缀，与真实菜单不符，本次已修正，因此此前的最终首选数字不可直接作为本轮的前后变化基线。

耗时使用 `os.clock()`，单位毫秒。每4键按时间顺序采样1键估算P50/P90/P99，均值包含全部按键。模型初始化发生在计时外；仅运行processor（含其解码与提交），并于收尾解码，不逐键构造候选窗。**这是处理器CPU耗时，不能等同于真实Rime候选窗端到端延迟**。模型/解码缓存跨句保留，每句已提交前缀与tracker重新隔离。

## 可复核文件

完整结果归档在本报告同目录，测评运行目录为 `/tmp/tiger-100k-20261026-a3D7SM/`。

- [summary.json](summary.json)：汇总指标及句长分组。
- [全部错误提前提交句](early-errors.md)：新版76句与原版159句，各展示第一次错误提交。
- [全部错误记录](all-errors.tsv)：包括最终错误和错误提前提交句。
- [共同十万句语料](corpus.tsv.gz)：目标、共同按键流、每键字符边界，gzip压缩。
- [character-codes.json](character-codes.json)：共同rank1最短码。
- [逐句差异](paired-differences.tsv.gz)：双方最终首选、已上屏文本、末键未上屏字数不同的所有句子。
- [原始结果](raw-results.tar.gz)：16个分片与日志，W行记录错误提交，R行记录句级指标，H/L行是分布及CPU采样。
- [运行时快照](runtime-snapshots.tar.gz)：双方运行时代码、词库、schema和版本声明；不重复打包大模型。模型仍在运行目录，并由manifest记录大小和SHA-256。
- [manifest.json](manifest.json)：版本、环境、参数和依赖SHA-256。
- [driver.lua](driver.lua)、[aggregate.py](aggregate.py)：执行与统计脚本。
- `artifact-sha256.json`：归档文件SHA-256。

本轮未调整生产代码、未部署输入法、未提交Git。
'''
(B/'report.md').write_text(text)
print(text)
