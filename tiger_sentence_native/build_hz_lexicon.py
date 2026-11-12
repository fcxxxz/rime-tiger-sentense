#!/usr/bin/env python3
"""从虎整码表源（lvyww/tiger-sentense-rime 的 codes.txt/char_ranks.txt）生成
本引擎的词表 data/tiger/tiger.lexicon.txt。

源文件已随仓库存放在 data/tiger/（hz-codes.txt、hz-char_ranks.txt、
hz-full_code_whitelist.txt，GPL-3，来自
https://github.com/lvyww/tiger-sentense-rime，致谢）。
码表设计：一简字 2 码占首选位（的=ue、在=ng、我=tu、说=sh…），原主人
退长码（近=tuc、办=shb、存=ngh…），定顶（all_ranks=false）下 2 码打法
天然成立——2026-11-11 基准：随机 1 万句 99.45%（+0.07pp vs 原表）省键
4.49%，见 bench/usertable-10k/report-hz.md。

第 7 列 flags（第 5/6 列读音位留空）：
  h = 高频字非最优码。照搬虎整 build_lexicon_index 的高频过滤：字频名次
      （去重稠密名次）≤ HIGH_FREQ_LIMIT、不在全码白名单的单字，只有其
      最优码（码长 ≥2 中首选位最短者，并列取源表行序在前；没有首选位时
      取最短码）与 1 键码可参与组句。引擎在 tiger/high_freq_limit > 0 时
      把带 h 的条目挡在多段组句边外，整段命中（单打该码）不受影响。
      最优码并列必须用源表行序裁决（燕 ldac/ladc），本词表按码排序后
      行序已丢失，故只能在生成期算好。

用法: python3 build_hz_lexicon.py   # 在 tiger_sentence_native/ 下执行
"""
from __future__ import annotations

from pathlib import Path

HERE = Path(__file__).resolve().parent
CODES = HERE / 'data/tiger/hz-codes.txt'
RANKS = HERE / 'data/tiger/hz-char_ranks.txt'
WHITELIST = HERE / 'data/tiger/hz-full_code_whitelist.txt'
OUT = HERE / 'data/tiger/tiger.lexicon.txt'
HIGH_FREQ_LIMIT = 1500  # 虎整 tiger_sentence/high_freq_limit 默认值


def content_lines(path: Path):
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if line and not line.startswith('#'):
            yield line


def primary_codes(by_code: dict[str, list[str]],
                  source_codes: dict[str, list[str]]) -> dict[str, str]:
    """每字最优码（虎整口径）：码长 ≥2 中首选位最短者，并列取源表行序在前；
    无首选位时取最短码。返回 字 -> 最优码。"""
    primary: dict[str, str] = {}
    for ch, codes in source_codes.items():
        best_first = best_any = None
        for code in codes:  # 源表行序
            if len(code) < 2:
                continue
            if best_any is None or len(code) < len(best_any):
                best_any = code
            if by_code[code][0] == ch and (best_first is None or len(code) < len(best_first)):
                best_first = code
        primary[ch] = best_first or best_any or ''
    return primary


def nonoptimal_all(primary: dict[str, str],
                   source_codes: dict[str, list[str]]) -> set[tuple[str, str]]:
    """全字非最优码形 (code, 字)——γ 码形先验标记（flag 'o'）：
    码长 ≥2 且不是该字最优码的码形，覆盖全部字（h 只罩前 1500 高频字，
    拟 1689 类漏网即在此）。1 键码不算非最优。"""
    marked = set()
    for ch, codes in source_codes.items():
        for code in codes:
            if len(code) >= 2 and code != primary.get(ch):
                marked.add((code, ch))
    return marked


def high_freq_nonoptimal(by_code: dict[str, list[str]],
                         source_codes: dict[str, list[str]]) -> set[tuple[str, str]]:
    """返回虎整高频过滤会从组句词表剔除的 (code, 字)。"""
    dense: dict[str, int] = {}
    for line in content_lines(RANKS):
        dense.setdefault(line[0], len(dense) + 1)
    common = {ch for ch, rank in dense.items() if rank <= HIGH_FREQ_LIMIT}
    whitelist = {ch for line in content_lines(WHITELIST) for ch in line}
    primary = primary_codes(by_code, source_codes)
    blocked = set()
    for ch in source_codes:
        if ch not in common or ch in whitelist:
            continue
        for code in source_codes[ch]:
            if len(code) >= 2 and code != primary[ch]:
                blocked.add((code, ch))
    return blocked


def main() -> None:
    by_code: dict[str, list[str]] = {}
    source_codes: dict[str, list[str]] = {}
    for line in CODES.read_text(encoding='utf-8').splitlines():
        if not line or line.startswith('#'):
            continue
        text, code = line.split('\t')
        by_code.setdefault(code, []).append(text)
        if len(text) == 1:
            source_codes.setdefault(text, []).append(code)

    freq: dict[str, int] = {}
    for i, line in enumerate(RANKS.read_text(encoding='utf-8').splitlines()):
        if not line or line.startswith('#'):
            continue
        freq[line.split('\t')[0]] = i + 1

    blocked = high_freq_nonoptimal(by_code, source_codes)
    nonopt = nonoptimal_all(primary_codes(by_code, source_codes), source_codes)
    lines = ['# code\ttext\trank\tfreq_rank\t\t\tflags']
    n_char = n_word = 0
    for code in sorted(by_code):
        for rank, text in enumerate(by_code[code], 1):
            if len(text) == 1:
                freq_rank, n_char = freq.get(text, 20001), n_char + 1
            else:
                freq_rank, n_word = 0, n_word + 1
            row = f'{code}\t{text}\t{rank}\t{freq_rank}'
            flags = ('h' if (code, text) in blocked else '') + \
                    ('o' if (code, text) in nonopt else '')
            if flags:
                row += '\t\t\t' + flags
            lines.append(row)
    OUT.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'{OUT.name}: {len(lines) - 1} 行（单字 {n_char}，词 {n_word}，码 {len(by_code)}，'
          f'高频非最优码 {len(blocked)}）')


if __name__ == '__main__':
    main()
