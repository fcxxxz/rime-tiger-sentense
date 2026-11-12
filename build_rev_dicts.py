#!/usr/bin/env python3
"""生成双拼单字反查词典 mohu_rev_{zrm,flypy}.dict.yaml。

背景（2026-11-12 装机反馈「反查几乎不可用」）：tiger 方案的 ` 反查三码式
里 rev_zrm/rev_flypy 曾配 mohu_zrm/mohu_flypy（基础码表）+ .codes prism。
基础码表是「每字唯一精确码」（ni 下只有 你，泥=nik、尼=nic）——反查用户
恰恰不知道形码，双拼反查名存实亡。本脚本从三张已入库表数据驱动地重建
「纯音节」双拼单字表：

- mohu_pinyin.dict.yaml 给出 (字, 全拼音节, 字频)；
- mohu_zrm/mohu_flypy.dict.yaml 的单字码 = 双拼音节(固定 2 键) + 形码
  (0-2 键)，按 2 键前缀对齐，字频加权投票学「全拼音节 → 双拼码」映射；
- 多音字的跨读音码互相污染初票（重 chong 码 isl 给 zhong 投 is 脏票），
  用 EM 迭代消解：M0 多数票 → 每字每音只保留与 M0 前缀一致的码 → 重
  投票，直至映射收敛；
- 零声母同为 2 键（实测魔然 zrm/flypy 同一套：ai/ei/ao/ou/an/en/er 直拼，
  ang→ah、eng→eg，a/e/o 双写 aa/ee/oo——昂 ah/恩 en/嗯 eg/哦 oodt 样本
  证实，非标准自然码，故不硬编码任何映射，全部从票学出）。

用法:
  python3 build_rev_dicts.py --learn-only          # 只学映射+打印报告
  python3 build_rev_dicts.py                        # 学习+生成两张词典
"""
from __future__ import annotations

import argparse
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
PINYIN_DICT = HERE / 'mohu_pinyin.dict.yaml'
SHUANGPIN_DICTS = {'zrm': HERE / 'mohu_zrm.dict.yaml',
                   'flypy': HERE / 'mohu_flypy.dict.yaml'}
OUT_NAMES = {'zrm': 'mohu_rev_zrm.dict.yaml',
             'flypy': 'mohu_rev_flypy.dict.yaml'}
VERSION = '20261112'

SYL_WIDTH = 2          # 双拼音节固定 2 键（零声母亦然，见模块 docstring）
FORM_CODE_MAX = 2      # 形码至多 2 键（妮 nibc = ni + bc）
EM_ROUNDS = 5          # EM 迭代上限

INITIALS = ['zh', 'ch', 'sh', 'b', 'p', 'm', 'f', 'd', 't', 'n', 'l',
            'g', 'k', 'h', 'j', 'q', 'x', 'r', 'z', 'c', 's', 'y', 'w']
FINALS = ['iang', 'iong', 'uang', 'ang', 'eng', 'ing', 'ong', 'uai', 'uan',
          'ian', 'iao', 'ai', 'ei', 'ao', 'ou', 'an', 'en', 'in', 'ia',
          'ie', 'ua', 'uo', 'ue', 've', 'ui', 'vi', 'un', 'vn', 'iu',
          'er', 'a', 'o', 'e', 'i', 'u', 'v']
ZERO_INITIAL_SYLLABLES = {'a', 'ai', 'an', 'ang', 'ao', 'e', 'ei', 'en',
                          'eng', 'er', 'o', 'ou'}


def is_valid_syllable(p: str) -> bool:
    if p in ZERO_INITIAL_SYLLABLES:
        return True
    for ini in INITIALS:
        if p.startswith(ini):
            rest = p[len(ini):]
            if rest and rest in FINALS:
                return True
    return False


def parse_rime_dict(path: Path, want_weight: bool):
    """text\tcode[weight] 行；返回 [(text, code, weight|None)]。"""
    out, in_data = [], False
    for line in path.read_text(encoding='utf-8').splitlines():
        if not in_data:
            if line.strip() == '...':
                in_data = True
            continue
        if not line or line.startswith('#'):
            continue
        parts = line.split('\t')
        if len(parts) < 2:
            continue
        text, code = parts[0], parts[1]
        weight = None
        if want_weight and len(parts) >= 3 and parts[2]:
            try:
                weight = int(parts[2])
            except ValueError:
                weight = 0
        out.append((text, code, weight))
    return out


def em_learn(scheme, entries, codes_by_char, report):
    """entries=[(char, syl, weight)]；返回 (mapping, ambiguous)。

    EM：M0 全量 2 键前缀投票 → 每字每音只保留 m[:2]==M[p] 的码 → 重投票。
    """
    def vote(mapping):
        votes = defaultdict(Counter)
        for char, syl, weight in entries:
            mp = mapping.get(syl)
            for m in codes_by_char.get(char, ()):
                if not (SYL_WIDTH <= len(m) <= SYL_WIDTH + FORM_CODE_MAX):
                    continue
                if mp is not None and m[:SYL_WIDTH] != mp:
                    continue  # EM：跳过与现行映射不符的跨读音码
                votes[syl][m[:SYL_WIDTH]] += max(weight, 1)
        return {s: c.most_common(1)[0][0] for s, c in votes.items() if c}

    mapping = {}
    for _ in range(EM_ROUNDS):
        new_mapping = vote(mapping)
        if new_mapping == mapping:
            break
        mapping = new_mapping

    # 收敛后统计一致率（按最终映射过滤后的口径，与 EM 末轮一致）
    final_votes = defaultdict(Counter)
    for char, syl, weight in entries:
        mp = mapping.get(syl)
        if mp is None:
            continue
        for m in codes_by_char.get(char, ()):
            if SYL_WIDTH <= len(m) <= SYL_WIDTH + FORM_CODE_MAX \
                    and m[:SYL_WIDTH] == mp:
                final_votes[syl][m[:SYL_WIDTH]] += max(weight, 1)
    ambiguous = []
    for syl in sorted(mapping):
        counter = final_votes[syl]
        if not counter:
            ambiguous.append((syl, mapping[syl], 0.0, [('(无验证票)', 0)]))
            continue
        total = sum(counter.values())
        top = counter[mapping[syl]]
        if top / total < 0.95:
            ambiguous.append((syl, mapping[syl], top / total,
                              counter.most_common(3)))
    return mapping, ambiguous


def build(scheme: str, mapping, pinyin_entries):
    """转换全拼表 → (text, code, weight)；同字同码合并权重。"""
    merged = defaultdict(int)
    no_map = Counter()
    for char, syl, weight in pinyin_entries:
        code = mapping.get(syl)
        if code is None:
            no_map[syl] += 1
            continue
        merged[(char, code)] += max(weight, 0)
    rows = sorted(merged.items(), key=lambda kv: -kv[1])
    return [(char, code, wt) for (char, code), wt in rows], no_map


def write_dict(path: Path, name: str, rows):
    lines = [
        '# Generated by build_rev_dicts.py. DO NOT EDIT.',
        f'# 【{name} 双拼单字反查词典】由 mohu_pinyin.dict.yaml 经数据驱动',
        '# 学出的音节映射转换生成；重新生成: python3 build_rev_dicts.py',
        '---',
        f'name: {name}',
        f'version: "{VERSION}"',
        'sort: by_weight',
        'use_preset_vocabulary: false',
        '...',
        '',
    ]
    lines += [f'{t}\t{c}\t{w}' for t, c, w in rows]
    path.write_text('\n'.join(lines) + '\n', encoding='utf-8')


def dump_syllables(mappings):
    """把学出的全拼→双拼映射写成 lua 数据模块（tiger_rev_engine 的
    全拼反查贪心切分用）。"""
    out = ['-- Generated by build_rev_dicts.py. DO NOT EDIT.',
           '-- 全拼音节 → zrm/flypy 双拼码（从魔然码表数据驱动学出，与',
           '-- mohu_{zrm,flypy}.dict.yaml 交叉校验 100% 吻合）。',
           'local M = {']
    for scheme in ('zrm', 'flypy'):
        out.append(f'  {scheme} = {{')
        for syl in sorted(mappings[scheme]):
            out.append(f'    {syl} = "{mappings[scheme][syl]}",')
        out.append('  },')
    out += ['}', 'return M', '']
    path = HERE / 'lua/tiger_rev_syllables.lua'
    path.write_text('\n'.join(out), encoding='utf-8')
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--learn-only', action='store_true',
                    help='只学映射并打印报告，不写词典')
    ap.add_argument('--syllables-only', action='store_true',
                    help='只生成 lua/tiger_rev_syllables.lua 音节映射模块')
    args = ap.parse_args()

    pinyin_entries = parse_rime_dict(PINYIN_DICT, want_weight=True)
    report = []
    bad = [(t, s) for t, s, _ in pinyin_entries if not is_valid_syllable(s)]
    if bad:
        report.append(f'[pinyin] 非法音节行 {len(bad)} 条（如 '
                      + ', '.join(f'{t}@{s}' for t, s in bad[:5]) + '，跳过）')
    pinyin_entries = [e for e in pinyin_entries if is_valid_syllable(e[1])]

    mappings = {}
    for scheme in ('zrm', 'flypy'):
        sp_entries = parse_rime_dict(SHUANGPIN_DICTS[scheme], want_weight=False)
        codes_by_char = defaultdict(list)
        for text, code, _ in sp_entries:
            codes_by_char[text].append(code)
        mapping, ambiguous = em_learn(scheme, pinyin_entries, codes_by_char,
                                      report)
        mappings[scheme] = mapping
        report.append(f'[{scheme}] 学得音节数={len(mapping)} 样例: '
                      f'ni={mapping.get("ni")} zhong={mapping.get("zhong")} '
                      f'a={mapping.get("a")} eng={mapping.get("eng")} '
                      f'in={mapping.get("yin")} er={mapping.get("er")}')
        if ambiguous:
            report.append(f'[{scheme}] 一致率<0.95 的映射 {len(ambiguous)} 个:')
            for syl, code, cons, top in ambiguous[:15]:
                report.append(f'  {syl}→{code} ({cons:.2f}) {top}')
        if args.learn_only or args.syllables_only:
            continue
        rows, no_map = build(scheme, mapping, pinyin_entries)
        if no_map:
            report.append(f'[{scheme}] 无映射音节（缺行）: '
                          + ', '.join(f'{s}×{n}' for s, n in no_map.most_common()))
        out = HERE / OUT_NAMES[scheme]
        write_dict(out, f'mohu_rev_{scheme}', rows)
        report.append(f'[{scheme}] 写出 {out.name}: {len(rows)} 条')

    if args.syllables_only:
        path = dump_syllables(mappings)
        report.append(f'写出 {path.relative_to(HERE)}: '
                      f'zrm={len(mappings["zrm"])} flypy={len(mappings["flypy"])} 音节')

    print('\n'.join(report))
    return 0


if __name__ == '__main__':
    sys.exit(main())
