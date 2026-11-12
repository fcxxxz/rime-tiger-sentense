#!/usr/bin/env python3
"""虎整组句资格 A/B 聚合：各臂对 base（旧定顶）逐句配对。

R 行字段同 hz-lvyww-10k/driver.lua：id word raw committed final wrong ncommits
sum_pk sum_pc final_pk final_pc sum_ms max_ms word_len committed_len；
W 行 = 错误提前上屏事件。输出 summary.json 与 flips.tsv（相对 base 翻转的句子）。
"""
from __future__ import annotations

import json
from pathlib import Path

B = Path('/tmp/tiger-hz-policy-20261111')
ARMS = ['base', 'policy', 'minlen', 'hf']
SHARDS = 8


def load(arm):
    rows, wrong_events = {}, 0
    for shard in range(SHARDS):
        done = False
        for line in (B / f'{arm}-{shard}.tsv').open(encoding='utf-8'):
            p = line.rstrip('\n').split('\t')
            if p[0] == 'R':
                rows[int(p[1])] = {
                    'word': p[2], 'raw': p[3], 'final': p[5], 'wrong': int(p[6]),
                    'ncommits': int(p[7]), 'final_pk': int(p[10]), 'final_pc': int(p[11]),
                    'sum_ms': float(p[12]), 'wlen': int(p[14]), 'clen': int(p[15]),
                }
            elif p[0] == 'W':
                wrong_events += 1
            elif p[0] == 'DONE':
                done = True
        assert done, f'incomplete {arm}-{shard}'
    return rows, wrong_events


def main() -> None:
    data = {a: load(a) for a in ARMS}
    base = data['base'][0]
    n = len(base)
    metrics, flips = {}, []
    for arm in ARMS:
        rows, wrong_events = data[arm]
        assert rows.keys() == base.keys()
        keys = sum(len(r['raw']) for r in rows.values())
        m = {
            'final_acc': sum(r['final'] == r['word'] for r in rows.values()) / n,
            'wrong_commit_events': wrong_events,
            'wrong_commit_sentences': sum(r['wrong'] for r in rows.values()),
            'coverage': sum(r['clen'] for r in rows.values()) / sum(r['wlen'] for r in rows.values()),
            'commits_per_sentence': sum(r['ncommits'] for r in rows.values()) / n,
            'pending_keys_mean': sum(r['final_pk'] for r in rows.values()) / n,
            'latency_mean_ms': sum(r['sum_ms'] for r in rows.values()) / keys,
        }
        if arm != 'base':
            fixed = broke = 0
            for i, r in rows.items():
                ok, ok0 = r['final'] == r['word'], base[i]['final'] == base[i]['word']
                if ok and not ok0:
                    fixed += 1
                    flips.append((arm, 'fixed', i, r['word'], r['raw'], base[i]['final'], r['final']))
                elif ok0 and not ok:
                    broke += 1
                    flips.append((arm, 'broke', i, r['word'], r['raw'], base[i]['final'], r['final']))
            m['vs_base_fixed'], m['vs_base_broke'] = fixed, broke
        metrics[arm] = m
    result = {'n': n, 'metrics': metrics}
    (B / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    with (B / 'flips.tsv').open('w', encoding='utf-8') as out:
        out.write('arm\tkind\tid\tword\traw\tbase_final\tarm_final\n')
        for row in flips:
            out.write('\t'.join(map(str, row)) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
