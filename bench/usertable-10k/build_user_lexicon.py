#!/usr/bin/env python3
"""从用户部署的虎单码表快照生成原生引擎 lexicon，可选落实
「一简字在组句中优先使用全码前 2 码」规则。

- 仅取单字、纯字母 1–4 码行（虎单码表口径，多字词不进引擎）
- rank = 同码行序（快照按权重排序，与 Rime sort:by_weight 一致）
- freq_rank = 该字在快照中最大权重的降序名次（缺权重 20001）——列语义
  与魔虎仓 tools/build_tiger_lexicon.py 一致，频源换成用户表自身权重
- `--inject`：一简字（有 1 键码的字）在其「全码（最长码）前 2 码」处作为
  **次选（rank 2）**加入，该码位原首选不动——单独打时 的=u、皇=un 首选仍是
  皇；只有组句时「的」才以 un 次选身份参与。该码位已有该字时保持原序不动。
  ⚠️ 引擎 `allow_all = all_ranks_always || length<=4`：组句边默认只取每码
  rank1，故本规则必须配 all_ranks=true 才生效（见 bench/usertable-10k 报告）。

用法: python3 build_user_lexicon.py [--inject] [--src 快照] [--out lexicon]
"""
from __future__ import annotations

import argparse
import collections
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
UNKNOWN_FREQ_RANK = 20001


def load_rows(path: Path) -> list[tuple[str, str, int]]:
    rows: list[tuple[str, str, int]] = []
    in_body = False
    for line in path.read_text(encoding='utf-8').splitlines():
        s = line.rstrip('\r\n')
        if s.strip() == '...':
            in_body = True
            continue
        if not in_body or not s or s.startswith('#'):
            continue
        f = s.split('\t')
        if len(f) < 2:
            continue
        text, code = f[0].strip(), f[1].strip()
        if len(text) != 1 or not (code.isalpha() and code.islower() and 1 <= len(code) <= 4):
            continue
        weight = 0
        if len(f) >= 3 and f[2].strip():
            try:
                weight = int(float(f[2]))
            except ValueError:
                pass
        rows.append((text, code, weight))
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--inject', action='store_true')
    ap.add_argument('--src', type=Path, default=HERE / 'tiger_user.dict.yaml')
    ap.add_argument('--out', type=Path, default=None)
    ap.add_argument('--stats', type=Path, default=None)
    args = ap.parse_args()
    out = args.out or HERE / ('tiger_user_inject.lexicon.txt' if args.inject
                              else 'tiger_user_base.lexicon.txt')

    rows = load_rows(args.src)
    best_weight: dict[str, int] = {}
    for t, _c, w in rows:
        if w > best_weight.get(t, -1):
            best_weight[t] = w
    freq_rank = {c: i for i, c in enumerate(sorted(best_weight, key=lambda x: -best_weight[x]), 1)}

    codes_of: dict[str, list[str]] = collections.defaultdict(list)
    for t, c, _w in rows:
        codes_of[t].append(c)
    one_key = {t: cs for t, cs in codes_of.items() if any(len(c) == 1 for c in cs)}

    by_code: dict[str, list[str]] = collections.defaultdict(list)
    for t, c, _w in rows:
        if t not in by_code[c]:
            by_code[c].append(t)

    injected: list[tuple[str, str, str, str]] = []   # (字, 2码, 全码, 该码位原首选)
    already: list[tuple[str, str, int]] = []          # (字, 2码, 原 rank)
    if args.inject:
        for t, cs in one_key.items():
            full = max(cs, key=len)
            p2 = full[:2]
            seq = by_code[p2]
            if t in seq:
                # 该码位已有此字：保持原序不动（如 一=fi、不=cb）
                already.append((t, p2, seq.index(t) + 1))
                continue
            # 作为次选插入：原首选不动，其余顺次后移
            head = seq[:1]
            by_code[p2] = head + [t] + seq[1:]
            injected.append((t, p2, full, head[0] if head else ''))

    lines = ['# code\ttext\trank\tfreq_rank']
    for code in sorted(by_code):
        for rank, t in enumerate(by_code[code], 1):
            lines.append(f'{code}\t{t}\t{rank}\t{freq_rank.get(t, UNKNOWN_FREQ_RANK)}')
    out.write_text('\n'.join(lines) + '\n', encoding='utf-8')

    stats = {'inject': args.inject, 'single_char_rows': len(rows),
             'unique_chars': len(codes_of), 'one_key_chars': len(one_key),
             'lexicon_rows': len(lines) - 1,
             'injected_secondary': [[t, p, f, head] for t, p, f, head in injected],
             'already_present': [[t, p, r] for t, p, r in already],
             'collision_pairs': {p: [head, t] for t, p, _f, head in injected if head}}
    (args.stats or HERE / f'lexicon-stats-{"inject" if args.inject else "base"}.json').write_text(
        json.dumps(stats, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in stats.items()
                      if k not in ('injected_secondary', 'already_present', 'collision_pairs')},
                     ensure_ascii=False))
    if args.inject:
        print('次选注入（码位: 首选/次选）:',
              ' '.join(f'{p}:{head}/{t}' for t, p, _f, head in injected))
        print('原已在该码位（不动）:', ' '.join(f'{t}={p}(r{r})' for t, p, r in already))


if __name__ == '__main__':
    main()
