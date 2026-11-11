#!/usr/bin/env python3
"""从虎整码表源（lvyww/tiger-sentense-rime 的 codes.txt/char_ranks.txt）生成
本引擎的 4 列词表 data/tiger/tiger.lexicon.txt。

源文件已随仓库存放在 data/tiger/（hz-codes.txt、hz-char-ranks.txt，
GPL-3，来自 https://github.com/lvyww/tiger-sentense-rime，致谢）。
码表设计：一简字 2 码占首选位（的=ue、在=ng、我=tu、说=sh…），原主人
退长码（近=tuc、办=shb、存=ngh…），定顶（all_ranks=false）下 2 码打法
天然成立——2026-11-11 基准：随机 1 万句 99.45%（+0.07pp vs 原表）省键
4.49%，见 bench/usertable-10k/report-hz.md。

用法: python3 build_hz_lexicon.py   # 在 tiger_sentence_native/ 下执行
"""
from __future__ import annotations

from pathlib import Path

HERE = Path(__file__).resolve().parent
CODES = HERE / 'data/tiger/hz-codes.txt'
RANKS = HERE / 'data/tiger/hz-char_ranks.txt'
OUT = HERE / 'data/tiger/tiger.lexicon.txt'


def main() -> None:
    by_code: dict[str, list[str]] = {}
    for line in CODES.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        text, code = line.split('\t')
        by_code.setdefault(code, []).append(text)

    freq: dict[str, int] = {}
    for i, line in enumerate(RANKS.read_text(encoding='utf-8').splitlines()):
        if not line or line.startswith('#'):
            continue
        freq[line.split('\t')[0]] = i + 1

    lines = ['# code\ttext\trank\tfreq_rank']
    n_char = n_word = 0
    for code in sorted(by_code):
        for rank, text in enumerate(by_code[code], 1):
            if len(text) == 1:
                freq_rank, n_char = freq.get(text, 20001), n_char + 1
            else:
                freq_rank, n_word = 0, n_word + 1
            lines.append(f'{code}\t{text}\t{rank}\t{freq_rank}')
    OUT.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'{OUT.name}: {len(lines) - 1} 行（单字 {n_char}，词 {n_word}，码 {len(by_code)}）')


if __name__ == '__main__':
    main()
