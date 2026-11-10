#!/usr/bin/env python3
"""三方十万句对照聚合：逐分片校验 → manifest 哈希复核 → 三方同语料断言 →
配对统计 → summary.json / paired-differences.tsv / all-errors.tsv / early-errors.md"""
from pathlib import Path
import csv, hashlib, json, math

B = Path('/tmp/tiger-lvyww-100k-20261110')
MODES = ['new', 'lvyww', 'orig']
SHARDS = 8
_manifest = __import__('json').loads((B / 'manifest.json').read_text())
PER = _manifest['sentences_per_shard']
N = _manifest['n']
LABEL = {'new': '魔虎整句（本仓）', 'lvyww': 'tiger-sentense-rime 发布包', 'orig': '虎整原版（参照）'}


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


def load(mode):
    rows = {}; events = {}; hist = {}; latency = []
    for shard in range(SHARDS):
        path = B / f'{mode}-{shard}.tsv'
        done = False; shardn = 0; shardkeys = 0
        for line in path.open():
            p = line.rstrip('\n').split('\t')
            if p[0] == 'R':
                _, id, text, raw, committed, final, wrong, commits, pk, pc, fpk, fpc, ms, maxms, chars, cchars = p
                id = int(id); assert id not in rows
                rows[id] = {'id': id, 'text': text, 'raw': raw, 'committed': committed, 'final': final,
                            'wrong': int(wrong), 'commits': int(commits), 'pk': int(pk), 'pc': int(pc),
                            'fpk': int(fpk), 'fpc': int(fpc), 'ms': float(ms), 'maxms': float(maxms),
                            'chars': int(chars), 'cchars': int(cchars)}
                assert len(text) == int(chars) and len(committed) == int(cchars)
                assert int(wrong) == int(not text.startswith(committed))
                shardn += 1; shardkeys += len(raw)
            elif p[0] == 'W':
                events.setdefault(int(p[1]), []).append({'key': int(p[2]), 'text': p[3], 'cumulative': p[4]})
            elif p[0] == 'H':
                hist[int(p[1])] = hist.get(int(p[1]), 0) + int(p[2])
            elif p[0] == 'L':
                latency.append(float(p[1]))
            elif p[0] == 'DONE':
                assert int(p[1]) == shardn == PER and int(p[2]) == shardkeys; done = True
        assert done, f'Incomplete {path}'
    assert set(rows) == set(range(1, N + 1))
    keys = sum(len(r['raw']) for r in rows.values()); chars = sum(r['chars'] for r in rows.values())
    assert sum(hist.values()) == keys
    assert set(events) == {i for i, r in rows.items() if r['wrong']}
    correct_committed = 0
    for r in rows.values():
        for a, b in zip(r['text'], r['committed']):
            if a != b:
                break
        correct_committed += 1
    metrics = {'sentences': len(rows), 'characters': chars, 'keys': keys,
               'wrong_sentences': sum(r['wrong'] for r in rows.values()),
               'wrong_commit_events': sum(map(len, events.values())),
               'final_correct': sum(r['text'] == r['final'] for r in rows.values()),
               'commits': sum(r['commits'] for r in rows.values()),
               'coverage': sum(r['cchars'] for r in rows.values()) / chars,
               'correct_prefix_coverage': correct_committed / chars,
               'pending_keys_mean': sum(r['pk'] for r in rows.values()) / keys,
               'pending_chars_mean': sum(r['pc'] for r in rows.values()) / keys,
               'final_pending_keys_mean': sum(r['fpk'] for r in rows.values()) / len(rows),
               'final_pending_chars_mean': sum(r['fpc'] for r in rows.values()) / len(rows),
               'no_commit_sentences': sum(r['commits'] == 0 for r in rows.values()),
               'low_coverage_sentences': sum(r['cchars'] / r['chars'] < .3 for r in rows.values()),
               'latency_mean_ms': sum(r['ms'] for r in rows.values()) / keys,
               'latency_max_ms': max(r['maxms'] for r in rows.values()),
               'latency_samples': len(latency)}
    for label, q in [('p50', .5), ('p90', .9), ('p99', .99)]:
        metrics['pending_keys_' + label] = hist_percentile(hist, q)
        metrics['final_pending_chars_' + label] = percentile([r['fpc'] for r in rows.values()], q)
        metrics['latency_' + label + '_ms'] = percentile(latency, q)
    return rows, events, metrics


if __name__ == '__main__':
    data = {m: load(m) for m in MODES}
    rows = {m: data[m][0] for m in MODES}
    events = {m: data[m][1] for m in MODES}
    metrics = {m: data[m][2] for m in MODES}
    for m in MODES[1:]:
        for id, r in rows['new'].items():
            o = rows[m][id]
            assert (r['text'], r['raw']) == (o['text'], o['raw'])
    manifest = json.loads((B / 'manifest.json').read_text())
    for rel, meta in manifest['files'].items():
        p = B / rel
        assert hashlib.file_digest(p.open('rb'), 'sha256').hexdigest() == meta['sha256'], f'Changed {p}'
    for key in ('sentences', 'keys', 'characters'):
        vals = {metrics[m][key] for m in MODES}
        assert len(vals) == 1, (key, vals)

    def pair(a, b):
        ra, rb = rows[a], rows[b]
        return {'both_wrong_early': len(set(events[a]) & set(events[b])),
                a + '_only_wrong_early': len(set(events[a]) - set(events[b])),
                b + '_only_wrong_early': len(set(events[b]) - set(events[a])),
                'both_final_correct': sum(ra[i]['final'] == ra[i]['text'] and rb[i]['final'] == ra[i]['text'] for i in ra),
                a + '_only_final_correct': sum(ra[i]['final'] == ra[i]['text'] and rb[i]['final'] != ra[i]['text'] for i in ra),
                b + '_only_final_correct': sum(ra[i]['final'] != ra[i]['text'] and rb[i]['final'] == ra[i]['text'] for i in ra),
                a + '_less_final_pending': sum(ra[i]['fpc'] < rb[i]['fpc'] for i in ra),
                b + '_less_final_pending': sum(ra[i]['fpc'] > rb[i]['fpc'] for i in ra)}

    result = {'metrics': metrics, 'paired': {'new_vs_lvyww': pair('new', 'lvyww'),
                                             'new_vs_orig': pair('new', 'orig'),
                                             'lvyww_vs_orig': pair('lvyww', 'orig')}}
    by_length = []
    for low, high in [(4, 8), (9, 15), (16, 30)]:
        ids = [i for i, r in rows['new'].items() if low <= r['chars'] <= high]
        entry = {'length': f'{low}-{high}', 'sentences': len(ids)}
        for m in MODES:
            subset = [rows[m][i] for i in ids]
            entry[m] = {'wrong_sentences': sum(r['wrong'] for r in subset),
                        'final_correct': sum(r['text'] == r['final'] for r in subset),
                        'coverage': sum(r['cchars'] for r in subset) / sum(r['chars'] for r in subset),
                        'final_pending_chars_mean': sum(r['fpc'] for r in subset) / len(subset)}
        by_length.append(entry)
    result['by_length'] = by_length

    with (B / 'paired-differences.tsv').open('w') as h:
        writer = csv.writer(h, delimiter='\t')
        writer.writerow(['id', 'target', 'code'] + [f'{m}_{k}' for m in MODES for k in ('auto', 'final', 'wrong', 'pending_chars')])
        for i in sorted(rows['new']):
            vals = [(rows[m][i]['committed'], rows[m][i]['final'], rows[m][i]['wrong'], rows[m][i]['fpc']) for m in MODES]
            if any(v != vals[0] for v in vals[1:]) or any(v[2] for v in vals):
                writer.writerow([i, rows['new'][i]['text'], rows['new'][i]['raw']] + [x for v in vals for x in v])
    (B / 'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
    with (B / 'all-errors.tsv').open('w') as h:
        writer = csv.writer(h, delimiter='\t')
        writer.writerow(['engine', 'id', 'target', 'code', 'auto_committed', 'final', 'wrong_auto', 'first_wrong_key', 'first_wrong_cumulative'])
        for m in MODES:
            for i, r in sorted(rows[m].items()):
                if r['wrong'] or r['final'] != r['text']:
                    first = events[m].get(i, [{}])[0]
                    writer.writerow([m, i, r['text'], r['raw'], r['committed'], r['final'], r['wrong'],
                                     first.get('key', ''), first.get('cumulative', '')])
    lines = ['# 三方十万句误上屏清单', '', '每条显示第一次错误提交；后续级联错误保存在分片 W 行中。', '']
    for m in MODES:
        lines += [f'## {LABEL[m]}：{len(events[m])} 句', '']
        for i, ev in sorted(events[m].items()):
            r = rows[m][i]; e = ev[0]
            lines += [f"- **{r['text']}**（#{i}，第 {e['key']} 键）：错误上屏 `{e['cumulative']}`；最终 `{r['final']}`。"]
        lines.append('')
    (B / 'early-errors.md').write_text('\n'.join(lines))
    print(json.dumps({k: v for k, v in result.items() if k != 'by_length'}, ensure_ascii=False, indent=2)[:4000])
