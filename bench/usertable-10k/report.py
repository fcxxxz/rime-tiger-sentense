#!/usr/bin/env python3
"""渲染用户虎单码表三臂报告 report.md"""
from pathlib import Path
import json

B = Path('/tmp/tiger-usertable-20261110')
S = json.loads((B / 'summary.json').read_text())
M = json.loads((B / 'manifest.json').read_text())
G = json.loads((B / 'groups.json').read_text())
ARMS = [('base', '现状（定顶）'), ('ranks', '仅开竞争'), ('compete', '次选注入+竞争')]
m = S['metrics']
cs = S['char_stats']
pairs = G['collision_pairs']

METRICS = [
    ('final_acc', '最终首选准确率', '{:.3%}'),
    ('final_correct', '最终整句正确数', '{:.0f}'),
    ('wrong_sentences', '错误提前上屏句数', '{:.0f}'),
    ('wrong_commit_events', '错误提交事件', '{:.0f}'),
    ('coverage', '自动上屏字符覆盖率', '{:.2%}'),
    ('final_pending_chars_mean', '打完瞬间平均未上屏字', '{:.2f}'),
    ('keys', '总键数', '{:.0f}'),
    ('latency_mean_ms', '逐键处理器CPU均值（ms）', '{:.3f}'),
    ('latency_p50_ms', '逐键处理器CPU P50（ms）', '{:.3f}'),
    ('latency_p99_ms', '逐键处理器CPU P99（ms）', '{:.3f}'),
]
GROUP_LABEL = {
    'has_one_key': '含一简字的句子',
    'has_demoted': '含碰撞首选字的句子（皇/题/种/近…）',
    'has_collision': '同时含一简字与碰撞首选字',
    'neither': '两类都不含（对照）',
}

L = []
L += [f'# 用户虎单码表：一简字 2 码次选参与组句的代价测评（{M["n"]:,} 句，2026-11-10）', '']
L += ['## 规则与机制前提', '',
      '规则（用户口径）：**单独打不变**——「的」=`u`、「皇」=`un` 首选仍是皇；',
      '**只有组句时**「的」以 `un` 的**次选**身份参与。故注入的是 rank 2，码位原首选不动。',
      '',
      '引擎门控 `allow_all = all_ranks_always || length <= 4`（`tigerengine.cc:3035`）：',
      '组句边默认**只取每码 rank 1**，所以该规则必须配 `all_ranks=true` 才生效。',
      '`probe_pin.lua` 实测：定顶下 `ngtnj` 只出「存袂」（无「在」），竞争下出「在袂」；',
      '≤4 键输入走 `length<=4` 例外，本来就全档位可见（`unph` 定顶下也能出「的黑」）。', '']
L += ['## 三臂设计', '',
      '| 臂 | 码表 | all_ranks | 一简字组句打法 | 语料 |',
      '|---|---|---|---|---|',
      '| base | 原表 | false | 3/4 码（如 的=`uni`） | 基准 |',
      '| ranks | 原表 | true | 3/4 码（同 base） | **与 base 逐字节相同** |',
      '| compete | 次选注入 | true | 2 码（的=`un`） | 仅 26 个一简字的码变短 |', '',
      '`ranks` 的作用是隔离「打开全档位竞争」本身的代价——它让所有部首/异体字也进组句，',
      '与注入无关。因此 base→ranks 是开关代价，ranks→compete 是注入代价。', '']

L += ['## 总体结果', '', '| 指标 | ' + ' | '.join(n for _a, n in ARMS) + ' |',
      '|---|' + '---:|' * len(ARMS)]
for key, name, fmt in METRICS:
    L.append(f'| {name} | ' + ' | '.join(fmt.format(m[a][key]) for a, _n in ARMS) + ' |')
L += ['', f'省键：base/ranks {m["base"]["keys"]:,} 键 → compete {m["compete"]["keys"]:,} 键，'
      f'**少 {m["base"]["keys"] - m["compete"]["keys"]:,} 键（−{1 - m["compete"]["keys"] / m["base"]["keys"]:.1%}）**；'
      f'准确率 {m["base"]["final_acc"]:.3%} → {m["compete"]["final_acc"]:.3%}'
      f'（−{(m["base"]["final_acc"] - m["compete"]["final_acc"]) * 100:.2f}pp）。', '']

L += ['## 分组准确率（碰撞归因）', '', '| 句子分组 | 句数 | ' + ' | '.join(n for _a, n in ARMS) + ' |',
      '|---|---:|' + '---:|' * len(ARMS)]
for g, lab in GROUP_LABEL.items():
    v = S['by_group'][g]
    L.append(f'| {lab} | {v["sentences"]:,} | ' +
             ' | '.join(f'{v[a]["final_acc"]:.2%}' for a, _n in ARMS) + ' |')
L += ['', '关键读法：`has_demoted`（含碰撞首选字）从 base/ranks 的 99.35% 掉到 compete 的 '
      f'{S["by_group"]["has_demoted"]["compete"]["final_acc"]:.2%}，而 `neither`（不含两类字）'
      'base→ranks 已经掉了（开关代价），ranks→compete 几乎不动。**损失集中在碰撞首选字上，'
      '不是普遍性退化。**', '']

L += ['## 逐字命中率：碰撞码位（直接回答「能不能离散开」）', '',
      '| 码 | 首选字 | 样本 | base | compete | 一简次选字 | 样本 | base | compete |',
      '|---|---|---:|---:|---:|---|---:|---:|---:|']
rows = []
for code, (head, sec) in sorted(pairs.items()):
    h, h2 = cs['base'].get(head), cs['compete'].get(head)
    s, s2 = cs['base'].get(sec), cs['compete'].get(sec)
    if h and h2 and s and s2:
        rows.append((code, head, h, h2, sec, s, s2))
rows.sort(key=lambda r: -r[2]['total'])
for code, head, h, h2, sec, s, s2 in rows:
    L.append(f'| `{code}` | {head} | {h["total"]} | {h["acc"]:.1%} | {h2["acc"]:.1%} '
             f'| {sec} | {s["total"]} | {s["acc"]:.1%} | {s2["acc"]:.1%} |')
ht = sum(r[2]['total'] for r in rows); hb = sum(r[2]['correct'] for r in rows); hc = sum(r[3]['correct'] for r in rows)
st = sum(r[5]['total'] for r in rows); sb = sum(r[5]['correct'] for r in rows); sc = sum(r[6]['correct'] for r in rows)
L += ['', f'- **一简次选字**（的/我/是/和…）合计 {st:,} 次：{sb / st:.2%} → {sc / st:.2%}'
      f'（{(sc - sb) / st * 100:+.2f}pp，净 {sc - sb:+d} 字）——**几乎无损，模型认得出来**。',
      f'- **碰撞首选字**（皇/题/种/近…）合计 {ht:,} 次：{hb / ht:.2%} → {hc / ht:.2%}'
      f'（{(hc - hb) / ht * 100:+.2f}pp，净 {hc - hb:+d} 字）——**代价全在这里**。',
      '', '即：高频一简字凭上下文稳稳压住同码低频字（的 3,982 次 99.9% 不变），'
      '反向则不然——「办」93.7%、「皇」95.8%、「近」96.9%、「首」97.4% 有可感损失。'
      '这是频次悬殊（的 字频第 1 vs 皇 537、办 365）下语言模型的预期行为：'
      '模型能离散开绝大多数，但低频首选字在弱上下文里会被高频次选字吃掉。', '']

L += ['## 配对差异', '']
for k, v in S['paired'].items():
    L.append(f'- `{k}`：' + '，'.join(f'{kk}={vv}' for kk, vv in v.items()))
L += ['', '## 码表与口径', '',
      f'- 源表：{M["source_table"]}',
      f'- 一简字 26 位：17 个需注入 2 码次选（`un` 皇/的、`tu` 近/我 …），'
      f'9 个（不/了/人/大/也/可/而/行）**原表已在该 2 码位为次选**，规则与现表一致；1 个（一）已是 `fi` 首选。',
      f'- 语料池从 `corpus/fenci` 重建：可编码唯一句 {M["pool_unique_encodable"]:,}，'
      f'seed {M["seed"]} 抽 {M["n"]:,} 句；三臂共同可编码字 {M["common_encodable_characters"]:,}。',
      f'- `user_model=false`、`two_char_word_gate=false`、`native_short_codes=true`，提前上屏出厂默认。',
      f'- 本仓 Git `{M["git_head"]}`。训练重叠口径（语料与 V5 训练同源 fenci），非独立留出泛化。',
      '- 可复核：`summary.json`、`manifest.json`（全文件 SHA-256）、`collision-diffs.tsv`（碰撞句逐句差异）。', '']
(B / 'report.md').write_text('\n'.join(L), encoding='utf-8')
print('\n'.join(L))
