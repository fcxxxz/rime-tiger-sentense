#!/usr/bin/env python3
"""渲染三方同码对照 report.md（数据来自 summary.json / manifest.json，规模见 manifest n）"""
from pathlib import Path
import json

B = Path('/tmp/tiger-lvyww-100k-20261110')
S = json.loads((B / 'summary.json').read_text())
M = json.loads((B / 'manifest.json').read_text())
COLS = [('new', '魔虎整句'), ('lvyww', 'tiger-sentense-rime'), ('orig', '虎整原版')]
METRICS = [
    ('wrong_sentences', '错误提前上屏句数', '{:.0f}'),
    ('wrong_commit_events', '错误提交事件（含级联）', '{:.0f}'),
    ('final_correct', '最终整句正确数', '{:.0f}'),
    ('final_acc', '最终首选准确率', '{:.3%}'),
    ('coverage', '自动上屏字符覆盖率', '{:.2%}'),
    ('correct_prefix_coverage', '正确公共前缀自动覆盖率', '{:.2%}'),
    ('pending_keys_mean', '全程平均未上屏键', '{:.2f}'),
    ('pending_chars_mean', '全程平均未上屏字', '{:.2f}'),
    ('final_pending_keys_mean', '打完瞬间平均未上屏键', '{:.2f}'),
    ('final_pending_chars_mean', '打完瞬间平均未上屏字', '{:.2f}'),
    ('pending_keys_p50', '未上屏键 P50', '{:.0f}'),
    ('pending_keys_p90', '未上屏键 P90', '{:.0f}'),
    ('pending_keys_p99', '未上屏键 P99', '{:.0f}'),
    ('no_commit_sentences', '整句零自动提交', '{:.0f}'),
    ('low_coverage_sentences', '自动覆盖不足30%的句子', '{:.0f}'),
    ('latency_mean_ms', '逐键处理器CPU均值（ms）', '{:.3f}'),
    ('latency_p50_ms', '逐键处理器CPU P50（ms）', '{:.3f}'),
    ('latency_p90_ms', '逐键处理器CPU P90（ms）', '{:.3f}'),
    ('latency_p99_ms', '逐键处理器CPU P99（ms）', '{:.3f}'),
]

m = S['metrics']
for c, _ in COLS:
    m[c]['final_acc'] = m[c]['final_correct'] / m[c]['sentences']

lines = [f'# 魔虎整句 vs tiger-sentense-rime：三方同码对照 {M["n"]:,} 句（2026-11-10）', '']
lines += [f'三方完整运行同一批 **{M["n"]:,} 句、{m["new"]["characters"]:,} 字、{m["new"]["keys"]:,} 键**，'
          f'逐句配对核验（共同 rank-1 单字 {M["common_rank1_characters"]:,} 个）。'
          '固定码表、固定模型、关闭个人学习的离线逐键测评。', '']
lines += ['## 结果', '', '| 指标 | ' + ' | '.join(name for _, name in COLS) + ' |',
          '|---|' + '---:|' * len(COLS)]
for key, name, fmt in METRICS:
    lines.append(f'| {name} | ' + ' | '.join(fmt.format(m[c][key]) for c, _ in COLS) + ' |')
lines += ['', f'错误提前上屏率分别为 ' +
          ' / '.join(f'{m[c]["wrong_sentences"] / m[c]["sentences"]:.3%}' for c, _ in COLS) + '。'
          '按句计错：该句任一笔自动提交不再是目标句前缀即记错；级联错误另记事件。', '']

lines += ['## 逐句差异（new vs lvyww 主对照）', '']
p = S['paired']['new_vs_lvyww']
lines += [f'- 双方错误提前提交：{p["both_wrong_early"]} 句；仅魔虎整句：{p["new_only_wrong_early"]} 句；'
          f'仅 tiger-sentense-rime：{p["lvyww_only_wrong_early"]} 句。',
          f'- 最终首选仅魔虎整句正确：{p["new_only_final_correct"]} 句；'
          f'仅 tiger-sentense-rime 正确：{p["lvyww_only_final_correct"]} 句；'
          f'双方均正确：{p["both_final_correct"]} 句。']
lines += ['## 逐句差异（new vs orig 连续性对照）', '']
p2 = S['paired']['new_vs_orig']
lines += [f'- 双方错误提前提交：{p2["both_wrong_early"]} 句；仅魔虎整句：{p2["new_only_wrong_early"]} 句；'
          f'仅虎整原版：{p2["orig_only_wrong_early"]} 句。',
          f'- 最终首选仅魔虎整句正确：{p2["new_only_final_correct"]} 句；'
          f'仅虎整原版正确：{p2["orig_only_final_correct"]} 句。']

lines += ['', '## 按句长分组', '', '| 句长 | 句数 | ' + ' | '.join(
    f'{name}（错提前/覆盖/末余字）' for _, name in COLS) + ' |', '|---|---:|' + '---|' * len(COLS)]
for g in S['by_length']:
    cells = []
    for c, _ in COLS:
        d = g[c]
        cells.append(f'{d["wrong_sentences"]} / {d["coverage"]:.2%} / {d["final_pending_chars_mean"]:.2f}')
    lines.append(f'| {g["length"]} 字 | {g["sentences"]:,} | ' + ' | '.join(cells) + ' |')

lines += ['', '## 版本与参数', '']
for c, _ in COLS:
    lines += [f'- **{c}**：{M["versions"][c]}']
lines += ['', f'- 本仓 Git：`{M["git_head"]}`（工作树干净：{M["git_status_clean"]}）；seed {M["seed"]}。', '']
lines += ['## 共同语料与统计口径', '',
          f'语料池从本仓 corpus/fenci（V5 训练分词语料，31 源）重建：去重后可编码唯一句 '
          f'{M["pool_unique_encodable"]:,}（拒收 {M["rejected_unique"]:,}），固定随机种子 {M["seed"]} 抽 '
          f'{M["n"]:,} 句。共同单字集合 {M["common_rank1_characters"]:,}：每个字在**三方**同一个码位都为 '
          'rank1，码长 ≥2，按「长度、字典序」取最短；不用一码简码，不因预测结果改目标。句长 4–30 字。',
          '',
          '每键统计与收尾解码口径与 2026-10-26 报告一致：未上屏键=存活 input 长度；未上屏字=已打完字符数−已上屏数；'
          '覆盖率以 Unicode 字符计；CPU 用 os.clock() 每 4 键采样 1 键，仅 processor（含解码与提交），不含候选窗。',
          '',
          '**与 2026-10-26 报告不可横比**：池行序不可复现（旧 /tmp/corpus79w.tsv 已失），共同字集由两方改三方交集，'
          '本批为独立新抽样。语料池与 V5 训练同源（fenci），属训练重叠测评，不能作为独立留出集泛化准确率。',
          '',
          'tiger-sentense-rime 仓库 HEAD（1.6.20261010.1）默认 TCSKNM03 五阶模型未随 Release 公开，'
          '本对照采用其最新可安装发布包；其 HEAD 侧的新特性（五阶模型、邻键纠错、自动选重、自学习）'
          '在公开模型发布前无法同口径评测。', '']
lines += ['## 可复核文件', '',
          '- [summary.json](summary.json)：三方全部指标与配对统计。',
          '- [manifest.json](manifest.json)：三方运行时代码/模型/词表 SHA-256 与参数。',
          '- [early-errors.md](early-errors.md)：三方全部错误提前提交句（各第一次错误提交）。',
          '- [all-errors.tsv](all-errors.tsv)：全部错误记录（最终错误 + 错误提前提交）。',
          '- [corpus.tsv](corpus.tsv)：共同目标句、共同码流与每键字符边界。',
          '- [paired-differences.tsv](paired-differences.tsv)：三方任意不同或含错的句子。',
          f'- 运行目录：`{B}`；分片 {M["shards"]}×{M["sentences_per_shard"]}/引擎。', '']
(B / 'report.md').write_text('\n'.join(lines), encoding='utf-8')
print('\n'.join(lines[:40]))
