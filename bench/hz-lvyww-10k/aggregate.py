#!/usr/bin/env python3
"""双臂聚合：准确率/上屏率/句均上屏次数/每键上屏率/残留码长/内存/性能。

R 行字段：id word raw committed final wrong ncommits sum_pk sum_pc
          final_pk final_pc sum_ms max_ms word_len committed_len
W 行：错误提前上屏事件；L 行：逐键处理器 CPU（抽样）。
time 日志：/usr/bin/time -l 的 maximum resident set size（字节）。
"""
from __future__ import annotations

import json
import math
from pathlib import Path

B = Path('/tmp/tiger-hz-lvyww-20261111')
M = json.loads((B / 'manifest.json').read_text())
ARMS = ['new', 'lvyww']
LABEL = {'new': '虎整魔虎版', 'lvyww': '官方虎整'}
N = M['n']
SHARDS = M['shards']


def percentile(values, q):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * q) - 1)] if values else None


def load(arm):
    rows, wrong_events, latencies = {}, 0, []
    for shard in range(SHARDS):
        path = B / f'{arm}-{shard}.tsv'
        done = False
        for line in path.open():
            p = line.rstrip('\n').split('\t')
            if p[0] == 'R':
                (_, id, word, raw, committed, final, wrong, ncommits, sum_pk, sum_pc,
                 final_pk, final_pc, sum_ms, max_ms, wlen, clen) = p
                rows[int(id)] = {
                    'word': word, 'raw': raw, 'committed': committed, 'final': final,
                    'wrong': int(wrong), 'ncommits': int(ncommits),
                    'sum_pk': int(sum_pk), 'sum_pc': int(sum_pc),
                    'final_pk': int(final_pk), 'final_pc': int(final_pc),
                    'sum_ms': float(sum_ms), 'max_ms': float(max_ms),
                    'wlen': int(wlen), 'clen': int(clen),
                    'keys': len(raw),
                }
            elif p[0] == 'W':
                wrong_events += 1
            elif p[0] == 'L':
                latencies.append(float(p[1]))
            elif p[0] == 'DONE':
                done = True
        assert done, f'incomplete {path}'
    assert len(rows) == N, f'{arm}: {len(rows)} rows'
    return rows, wrong_events, latencies


def max_rss_kb(arm):
    vals = []
    for shard in range(SHARDS):
        for line in (B / f'{arm}-{shard}.time').open():
            if 'maximum resident set size' in line:
                for tok in line.strip().split():
                    if tok.isdigit():
                        vals.append(int(tok))
                        break
    return vals


def main() -> None:
    data = {a: load(a) for a in ARMS}
    for i, r in data[ARMS[0]][0].items():
        assert r['word'] == data[ARMS[1]][0][i]['word'], f'corpus mismatch at {i}'

    out = {}
    for a in ARMS:
        rows, wrong_events, lat = data[a]
        keys = sum(r['keys'] for r in rows.values())
        chars = sum(r['wlen'] for r in rows.values())
        cchars = sum(r['clen'] for r in rows.values())
        commits = sum(r['ncommits'] for r in rows.values())
        rss = max_rss_kb(a)
        out[a] = {
            'final_acc': sum(r['final'] == r['word'] for r in rows.values()) / N,
            'wrong_commit_events': wrong_events,
            'wrong_sentences': sum(r['wrong'] for r in rows.values()),
            'coverage': cchars / chars,                # 自动上屏字符覆盖率
            'commits_per_sentence': commits / N,      # 句均上屏次数
            'commits_per_key': commits / keys,        # 每键上屏率
            'pending_keys_mean': sum(r['final_pk'] for r in rows.values()) / N,   # 残留码长
            'pending_chars_mean': sum(r['final_pc'] for r in rows.values()) / N,  # 残留字数
            'keys': keys,
            'chars': chars,
            'commits': commits,
            'latency_mean_ms': sum(r['sum_ms'] for r in rows.values()) / keys,
            'latency_p50_ms': percentile(lat, .5),
            'latency_p99_ms': percentile(lat, .99),
            'rss_max_mb': max(rss) / 1048576 if rss else None,      # time -l 报字节
            'rss_mean_mb': (sum(rss) / len(rss) / 1048576) if rss else None,
        }

    paired = {}
    a, b = ARMS
    ra, rb = data[a][0], data[b][0]
    paired[f'{a}_only_correct'] = sum(
        ra[k]['final'] == ra[k]['word'] and rb[k]['final'] != rb[k]['word'] for k in ra)
    paired[f'{b}_only_correct'] = sum(
        ra[k]['final'] != ra[k]['word'] and rb[k]['final'] == rb[k]['word'] for k in ra)
    result = {'metrics': out, 'paired': paired, 'meta': {k: v for k, v in M.items() if k != 'files'}}
    (B / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
