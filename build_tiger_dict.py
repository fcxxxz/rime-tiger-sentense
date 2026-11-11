#!/usr/bin/env python3
"""生成统一口径的 tiger 主码表（单字层）：虎整码表 + 生僻字回填。

问题（2026-11-11 装机反馈）：整句层用虎整码表（tiger_sentence.codes.txt，
我@tu/的=ue 首选），而单字层若沿用旧 tiger.dict.yaml（近@tu 首选），
同码位两层候选序不一致。

本脚本把单字层基表也换成虎整口径：
- 虎整码表全部条目按其行序锁定同码候选序（weight = 1e9 − 全局行号，
  同码内严格递减；一简字 2 码首选、词条目一并保留）；
- 回填字典（--fallback，默认本仓 tiger.dict.yaml 旧版）中**不在虎整
  条目集里的 text**，按原码原权重追加——生僻字四码全码得以保留，
  Ctrl+X 全字集功能不受影响；已在虎整表里的字（如 近：旧表 @tu）只认
  虎整码位（@tuc），旧码位条目丢弃。

用法: python3 build_tiger_dict.py [--fallback 旧tiger.dict.yaml] [--out tiger.dict.yaml]
"""
from __future__ import annotations

import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent
HZ_CODES = HERE / 'tiger_sentence_native/data/tiger/hz-codes.txt'


def load_hz():
    entries = []  # (text, code) 按文件行序
    for line in HZ_CODES.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        text, code = line.split('\t')
        entries.append((text, code))
    return entries


def load_fallback(path: Path):
    """旧 Rime dict：text\tcode\tweight 三列。"""
    out = []
    in_data = False
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.strip() == '...':
            in_data = True
            continue
        if not in_data or not line or line.startswith('#'):
            continue
        f = line.split('\t')
        if len(f) < 2:
            continue
        text, code = f[0], f[1]
        weight = int(f[2]) if len(f) > 2 and f[2].isdigit() else 1
        out.append((text, code, weight))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument('--fallback', type=Path, default=HERE / 'tiger.dict.yaml')
    ap.add_argument('--out', type=Path, default=HERE / 'tiger.dict.yaml')
    args = ap.parse_args()

    hz = load_hz()
    hz_texts = {t for t, _c in hz}
    fallback = load_fallback(args.fallback) if args.fallback != args.out else []
    keep = [(t, c, w) for t, c, w in fallback if t not in hz_texts]

    lines = [
        '# Rime dictionary: tiger',
        '# encoding: utf-8',
        '# 虎整码表统一口径（build_tiger_dict.py 生成）：常用字候选序=虎整 codes.txt 行序；',
        '# 生僻字（不在虎整表）按四码全码回填，Ctrl+X 全字集可达。',
        '',
        '---',
        'name: tiger',
        'version: "2026.11.11"',
        'sort: by_weight',
        'use_preset_vocabulary: false',
        'columns:',
        '  - text',
        '  - code',
        '  - weight',
        '...',
        '',
    ]
    n_hz = n_fb = 0
    for i, (text, code) in enumerate(hz):
        lines.append(f'{text}\t{code}\t{1_000_000_000 - i}')
        n_hz += 1
    for text, code, weight in keep:
        lines.append(f'{text}\t{code}\t{weight}')
        n_fb += 1
    args.out.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'{args.out.name}: 虎整 {n_hz} 条 + 回填 {n_fb} 条（来源 {args.fallback.name}）')


if __name__ == '__main__':
    main()
