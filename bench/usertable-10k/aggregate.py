#!/usr/bin/env python3
"""用户虎单码表三臂聚合：总体指标 + **碰撞字分组**（一简字句 / 降档字句 /
无关句）+ 逐字命中率，回答「一简 2 码与原 2 码字能否离散开」。"""
from __future__ import annotations

import csv
import hashlib
import json
import math
from pathlib import Path

B = Path('/tmp/tiger-usertable-20261110')
M = json.loads((B / 'manifest.json').read_text())
G = json.loads((B / 'groups.json').read_text())
ARMS = list(M['arms'])
SHARDS = M['shards']
PER = M['sentences_per_shard']
N = M['n']
ONE_KEY = set(G['one_key_chars'])
DEMOTED = set(G['demoted_chars'])


def percentile(values, q):
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * q) - 1)] if values else None


def hist_percentile(hist, q):
    threshold = math.ceil(sum(hist.values()) * q)
    count = 0
    for k, v in sorted(hist.items()):
        count += v
        if count >= threshold:
            return k


def load(arm):
    rows, events, hist, latency = {}, {}, {}, []
    for shard in range(SHARDS):
        path = B / f'{arm}-{shard}.tsv'
        done = shardn = shardkeys = 0
        for line in path.open():
            p = line.rstrip('\n').split('\t')
            if p[0] == 'R':
                (_, id, text, raw, committed, final, wrong, commits, pk, pc,
                 fpk, fpc, ms, maxms, chars, cchars) = p
                id = int(id)
                assert id not in rows
                rows[id] = {'id': id, 'text': text, 'raw': raw, 'committed': committed,
                            'final': final, 'wrong': int(wrong), 'commits': int(commits),
                            'pk': int(pk), 'pc': int(pc), 'fpk': int(fpk), 'fpc': int(fpc),
                            'ms': float(ms), 'maxms': float(maxms),
                            'chars': int(chars), 'cchars': int(cchars)}
                assert int(wrong) == int(not text.startswith(committed))
                shardn += 1
                shardkeys += len(raw)
            elif p[0] == 'W':
                events.setdefault(int(p[1]), []).append(
                    {'key': int(p[2]), 'text': p[3], 'cumulative': p[4]})
            elif p[0] == 'H':
                hist[int(p[1])] = hist.get(int(p[1]), 0) + int(p[2])
            elif p[0] == 'L':
                latency.append(float(p[1]))
            elif p[0] == 'DONE':
                assert int(p[1]) == shardn == PER and int(p[2]) == shardkeys
                done = 1
        assert done, f'incomplete {path}'
    assert set(rows) == set(range(1, N + 1))
    keys = sum(len(r['raw']) for r in rows.values())
    chars = sum(r['chars'] for r in rows.values())
    assert sum(hist.values()) == keys
    m = {'sentences': len(rows), 'characters': chars, 'keys': keys,
         'final_correct': sum(r['text'] == r['final'] for r in rows.values()),
         'wrong_sentences': sum(r['wrong'] for r in rows.values()),
         'wrong_commit_events': sum(map(len, events.values())),
         'coverage': sum(r['cchars'] for r in rows.values()) / chars,
         'final_pending_chars_mean': sum(r['fpc'] for r in rows.values()) / len(rows),
         'latency_mean_ms': sum(r['ms'] for r in rows.values()) / keys}
    m['final_acc'] = m['final_correct'] / m['sentences']
    for label, q in [('p50', .5), ('p90', .9), ('p99', .99)]:
        m['pending_keys_' + label] = hist_percentile(hist, q)
        m['latency_' + label + '_ms'] = percentile(latency, q)
    return rows, events, m


def char_hits(rows, targets):
    """逐字命中：目标句的 final 与 target 对位比较，统计 targets 中各字正确率。"""
    hit = {c: [0, 0] for c in targets}  # [correct, total]
    for r in rows.values():
        t, f = r['text'], r['final']
        for i, ch in enumerate(t):
            if ch in hit:
                hit[ch][1] += 1
                if i < len(f) and f[i] == ch:
                    hit[ch][0] += 1
    return hit


def main() -> None:
    data = {a: load(a) for a in ARMS}
    rows = {a: data[a][0] for a in ARMS}
    events = {a: data[a][1] for a in ARMS}
    metrics = {a: data[a][2] for a in ARMS}
    for a in ARMS[1:]:
        for i, r in rows[ARMS[0]].items():
            assert r['text'] == rows[a][i]['text'], f'corpus mismatch at {i}'
    for rel, meta in M['files'].items():
        p = B / rel
        assert hashlib.file_digest(p.open('rb'), 'sha256').hexdigest() == meta['sha256'], f'changed {p}'

    base_rows = rows[ARMS[0]]
    groups = {
        'has_one_key': [i for i, r in base_rows.items() if any(c in ONE_KEY for c in r['text'])],
        'has_demoted': [i for i, r in base_rows.items() if any(c in DEMOTED for c in r['text'])],
        'has_collision': [i for i, r in base_rows.items()
                          if any(c in ONE_KEY for c in r['text']) and any(c in DEMOTED for c in r['text'])],
        'neither': [i for i, r in base_rows.items()
                    if not any(c in ONE_KEY or c in DEMOTED for c in r['text'])],
    }
    by_group = {}
    for name, ids in groups.items():
        entry = {'sentences': len(ids)}
        for a in ARMS:
            sub = [rows[a][i] for i in ids]
            entry[a] = {
                'final_correct': sum(r['text'] == r['final'] for r in sub),
                'final_acc': (sum(r['text'] == r['final'] for r in sub) / len(sub)) if sub else None,
                'wrong_sentences': sum(r['wrong'] for r in sub),
                'coverage': (sum(r['cchars'] for r in sub) / sum(r['chars'] for r in sub)) if sub else None,
                'keys': sum(len(r['raw']) for r in sub),
            }
        by_group[name] = entry

    char_stats = {}
    for a in ARMS:
        hits = char_hits(rows[a], ONE_KEY | DEMOTED)
        char_stats[a] = {c: {'correct': v[0], 'total': v[1],
                             'acc': (v[0] / v[1]) if v[1] else None}
                         for c, v in hits.items() if v[1] > 0}

    paired = {}
    for i in range(len(ARMS)):
        for j in range(i + 1, len(ARMS)):
            a, b = ARMS[i], ARMS[j]
            paired[f'{a}_vs_{b}'] = {
                f'{a}_only_final_correct': sum(
                    rows[a][k]['final'] == rows[a][k]['text'] and rows[b][k]['final'] != rows[b][k]['text']
                    for k in base_rows),
                f'{b}_only_final_correct': sum(
                    rows[a][k]['final'] != rows[a][k]['text'] and rows[b][k]['final'] == rows[b][k]['text']
                    for k in base_rows),
                'both_final_correct': sum(
                    rows[a][k]['final'] == rows[a][k]['text'] and rows[b][k]['final'] == rows[b][k]['text']
                    for k in base_rows),
                f'{a}_only_wrong_early': len(set(events[a]) - set(events[b])),
                f'{b}_only_wrong_early': len(set(events[b]) - set(events[a])),
            }

    result = {'metrics': metrics, 'by_group': by_group, 'paired': paired,
              'char_stats': char_stats, 'keys_per_arm': M['keys_per_arm']}
    (B / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')

    with (B / 'collision-diffs.tsv').open('w') as h:
        w = csv.writer(h, delimiter='\t')
        w.writerow(['id', 'target'] + [f'{a}_{k}' for a in ARMS for k in ('code', 'final', 'ok')])
        for i in sorted(groups['has_collision']):
            finals = [(rows[a][i]['raw'], rows[a][i]['final'],
                       int(rows[a][i]['final'] == rows[a][i]['text'])) for a in ARMS]
            if len({f[1] for f in finals}) > 1 or any(f[2] == 0 for f in finals):
                w.writerow([i, base_rows[i]['text']] + [x for f in finals for x in f])

    print(json.dumps({'metrics': metrics, 'by_group': by_group, 'paired': paired},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
