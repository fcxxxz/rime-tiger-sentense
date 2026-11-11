#!/usr/bin/env python3
"""TIGER_SECONDARY_PENALTY 扫描聚合：总体 + 碰撞对逐字命中率（办/皇/近/首… vs 说/的/我…）。

对比臂：base（现状）、compete（penalty=0 即已有结果）、pen05…pen40。
所有 pen* 臂与 compete 同语料（corpus-compete，一简字打 2 码），逐句配对。
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

B = Path('/tmp/tiger-usertable-20261110')
G = json.loads((B / 'groups.json').read_text())
SHARDS, PER, N = 8, 1250, 10000

PENS = ['0.5', '1.0', '1.5', '2.0', '3.0', '4.0']
PEN_ARMS = ['pen' + p.replace('.', '') for p in PENS]


def load(arm):
    rows = {}
    for shard in range(SHARDS):
        for line in (B / f'{arm}-{shard}.tsv').open():
            p = line.rstrip('\n').split('\t')
            if p[0] == 'R':
                rows[int(p[1])] = {'text': p[2], 'raw': p[3], 'final': p[5],
                                   'wrong': int(p[6])}
    assert len(rows) == N, f'{arm}: {len(rows)} rows'
    return rows


def char_hits(rows, targets):
    hit = {c: [0, 0] for c in targets}
    for r in rows.values():
        t, f = r['text'], r['final']
        for i, ch in enumerate(t):
            if ch in hit:
                hit[ch][1] += 1
                if i < len(f) and f[i] == ch:
                    hit[ch][0] += 1
    return hit


def main() -> None:
    one_key = set(G['one_key_chars'])
    demoted = set(G['demoted_chars'])
    pairs = G['collision_pairs']

    arms = ['base', 'compete'] + PEN_ARMS
    data = {a: load(a) for a in arms}

    # 语料一致性：compete 系全部同语料
    for a in PEN_ARMS:
        for i, r in data['compete'].items():
            assert r['text'] == data[a][i]['text'] and r['raw'] == data[a][i]['raw']

    out = {'metrics': {}, 'char_stats': {}}
    for a in arms:
        rows = data[a]
        out['metrics'][a] = {
            'final_acc': sum(r['text'] == r['final'] for r in rows.values()) / N,
            'wrong_sentences': sum(r['wrong'] for r in rows.values()),
            'keys': sum(len(r['raw']) for r in rows.values()),
        }
        out['char_stats'][a] = {c: {'correct': v[0], 'total': v[1],
                                    'acc': v[0] / v[1] if v[1] else None}
                                for c, v in char_hits(rows, one_key | demoted).items()
                                if v[1] > 0}
    (B / 'sweep-summary.json').write_text(json.dumps(out, ensure_ascii=False, indent=2))

    # ---- 控制台输出 ----
    print('=== 总体（base 语料不同，其余同 compete 语料一简字打 2 码）===')
    hdr = ['指标'] + arms
    print(('{:<10}' + '{:>9}' * len(arms)).format(*hdr))
    for k in ('final_acc', 'wrong_sentences'):
        vals = [f"{out['metrics'][a][k]:.4%}" if k == 'final_acc'
                else str(out['metrics'][a][k]) for a in arms]
        print(('{:<10}' + '{:>9}' * len(arms)).format(k, *vals))
    print(('{:<10}' + '{:>9}' * len(arms)).format(
        'keys', *[f"{out['metrics'][a]['keys']:,}" for a in arms]))

    print()
    print('=== 碰撞首选字（rank 1，被反杀的受害者）===')
    hdr = ['字(码)'] + ['样本'] + arms
    rows_data = []
    for code, (head, sec) in sorted(pairs.items()):
        h = {a: out['char_stats'][a].get(head) for a in arms}
        if any(v and v['total'] >= 5 for v in h.values()):
            rows_data.append((code, head, h))
    rows_data.sort(key=lambda r: -(r[2]['base'] or {'total': 0})['total'])
    print(('{:<10}' + '{:>6}' + '{:>9}' * len(arms)).format('字(码)', '样本', *arms))
    for code, head, h in rows_data:
        t = (h['base'] or {'total': 0})['total']
        vals = [f"{h[a]['acc']:.1%}" if h[a] else '-' for a in arms]
        print(('{:<10}' + '{:>6}' + '{:>9}' * len(arms)).format(
            f'{head}({code})', t, *vals))

    print()
    print('=== 一简次选字（受益者）===')
    sec_rows = []
    for code, (head, sec) in sorted(pairs.items()):
        s = {a: out['char_stats'][a].get(sec) for a in arms}
        if any(v and v['total'] >= 5 for v in s.values()):
            sec_rows.append((code, sec, s))
    sec_rows.sort(key=lambda r: -(r[2]['base'] or {'total': 0})['total'])
    print(('{:<10}' + '{:>6}' + '{:>9}' * len(arms)).format('字(码)', '样本', *arms))
    for code, sec, s in sec_rows:
        t = (s['base'] or {'total': 0})['total']
        vals = [f"{s[a]['acc']:.1%}" if s[a] else '-' for a in arms]
        print(('{:<10}' + '{:>6}' + '{:>9}' * len(arms)).format(
            f'{sec}({code})', t, *vals))

    # 合计
    print()
    for label, group in [('碰撞首选字合计', demoted), ('一简次选字合计', one_key)]:
        for a in arms:
            cs = out['char_stats'][a]
            tot = sum(cs[c]['total'] for c in group if c in cs)
            cor = sum(cs[c]['correct'] for c in group if c in cs)
            if tot:
                out['metrics'][a][label] = f'{cor / tot:.3%}({tot})'
        print(('{:<12}' + '{:>16}' * len(arms)).format(
            label, *[out['metrics'][a][label] for a in arms]))


if __name__ == '__main__':
    main()
