#!/usr/bin/env python3
"""用户虎单码表三臂对照 staging + 各臂语料（2026-11-10）。

问题：一简字取全码前 2 码注入后，与原 2 码字同码（un 的/皇、tu 我/近），
会不会降准确度？引擎 `allow_all = all_ranks_always || length<=4`——整句
（>4 键）每条组句边只取每码 rank 1，故分两条路测：

规则（用户口径）：**单独打不变**——的=u、皇=un 首选仍是皇；**只有组句时**
「的」以 un 的**次选**身份参与。故注入的是 rank 2，码位原首选不动。
引擎 `allow_all = all_ranks_always || length<=4`：组句边默认只取每码 rank1，
因此该规则必须配 all_ranks=true 才生效（定顶下 rank2 不参与组句，已由
probe_pin.lua 单独验证）。

  base    原表 + all_ranks=false  现状：一简字组句须打 3/4 码
  ranks   原表 + all_ranks=true   隔离「开竞争」本身的代价（部首/异体字
                                  也进组句），语料与 base 逐字节相同
  compete 注入次选 + all_ranks=true  目标方案：一简字组句改打 2 码，
                                  的/皇 同在 un 竞争，模型按上下文裁决
                                  ← 直接回答「能不能离散开」

**语料按各臂真实打法生成**（1 键码在组句中被引擎拒绝：
`consumed_end-pos < 2` → 每字取最短可用码 ≥2）：
  base/ranks = 该字 **rank 1** 的最短码 ≥2（两臂语料相同）
  compete    = 该字 **任意 rank** 的最短码 ≥2 —— 码表即打法，不退让：
               「皇」仍打 un，「的」也打 un，碰撞在 un 位真实发生
与 base 相比，compete 语料**只有 26 个一简字的码变短**，其余字逐字节相同；
键数差即该规则的省键收益。

句子集合三臂相同（取三臂都可编码的交集），逐句配对。
"""
from __future__ import annotations

import hashlib
import json
import random
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
OURS = HERE.parents[1]
BASE = Path('/tmp/tiger-usertable-20261110')
SEED = 20261110
N = 10_000
SHARDS = 8
PER = N // SHARDS
ARMS = {
    # 现状基线：原表 + 组句边只取 rank1，一简字只能打 3/4 码
    'base': {'lexicon': 'tiger_user_base.lexicon.txt', 'all_ranks': 'false', 'rank1_only': True},
    # all_ranks 对照：同一张原表、同一份语料，只打开全档位竞争
    # （隔离「开竞争」本身的代价：部首/异体字也会进组句）
    'ranks': {'lexicon': 'tiger_user_base.lexicon.txt', 'all_ranks': 'true', 'rank1_only': True},
    # 目标方案：一简字 2 码次选注入 + 全档位竞争，一简字组句改打 2 码
    'compete': {'lexicon': 'tiger_user_inject.lexicon.txt', 'all_ranks': 'true', 'rank1_only': False},
}


def load_lexicon(path: Path):
    """code -> [(text, rank)]，按 rank 升序。"""
    out = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.startswith('#'):
            continue
        f = line.split('\t')
        if len(f) < 3:
            continue
        out.setdefault(f[0], []).append((f[1], int(f[2])))
    return out


def shortest_codes(lex, rank1_only: bool):
    """每字组句可用的最短码（≥2 键；定顶臂要求 rank1）。"""
    best = {}
    for code, entries in lex.items():
        if len(code) < 2:
            continue
        for text, rank in entries:
            if len(text) != 1:
                continue
            if rank1_only and rank != 1:
                continue
            cur = best.get(text)
            if cur is None or (len(code), code) < (len(cur), cur):
                best[text] = code
    return best


def main() -> None:
    if BASE.exists():
        shutil.rmtree(BASE)
    BASE.mkdir(parents=True)

    # ---- staging：共用一份 lua/引擎，各臂只换 lexicon 与 all_ranks ----
    shutil.copytree(OURS / 'lua', BASE / 'lua')
    shutil.copytree(OURS / 'tiger_sentence_native', BASE / 'tiger_sentence_native',
                    ignore=shutil.ignore_patterns('data', '*.bin', '*.zip', 'lua-5*',
                                                  '*.o', '*.a', 'build', '__pycache__'))
    (BASE / 'tiger_sentence_native/data/tiger').mkdir(parents=True)
    (BASE / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin').symlink_to(
        OURS / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin')
    shutil.copy2(OURS / 'tiger.schema.yaml', BASE / 'tiger.schema.yaml')
    shutil.copy2(HERE / 'driver.lua', BASE / 'driver.lua')
    for name in ('tiger_user_base.lexicon.txt', 'tiger_user_inject.lexicon.txt',
                 'tiger_user.dict.yaml'):
        shutil.copy2(HERE / name, BASE / name)

    codes = {}
    for arm, cfg in ARMS.items():
        lex = load_lexicon(HERE / cfg['lexicon'])
        codes[arm] = shortest_codes(lex, cfg['rank1_only'])
        print(f'{arm}: 可组句字 {len(codes[arm])}')

    # ---- 语料：三臂都可编码的句子交集 ----
    usable = set.intersection(*(set(codes[a]) for a in ARMS))
    print('三臂共同可编码字:', len(usable))
    seen = set()
    pool = []
    rejected = 0
    for f in sorted((OURS / 'corpus/fenci').glob('*.txt')):
        for line in f.open(encoding='utf-8', errors='ignore'):
            text = line.strip().replace(' ', '').replace('\u3000', '')
            if not text or text in seen:
                continue
            seen.add(text)
            if not 4 <= len(text) <= 30 or any(c not in usable for c in text):
                rejected += 1
                continue
            pool.append(text)
    rng = random.Random(SEED)
    selected = rng.sample(pool, N)

    keys_per_arm = {}
    for arm in ARMS:
        cmap = codes[arm]
        total_keys = 0
        with (BASE / f'corpus-{arm}.tsv').open('w', encoding='utf-8') as out:
            for text in selected:
                cs = [cmap[c] for c in text]
                bounds = []
                for i, code in enumerate(cs):
                    bounds.extend([i] * (len(code) - 1) + [i + 1])
                total_keys += sum(map(len, cs))
                out.write(text + '\t' + ''.join(cs) + '\t' + ','.join(map(str, bounds)) + '\n')
        keys_per_arm[arm] = total_keys

    # ---- 碰撞受影响字集合（供聚合分组）----
    stats = json.loads((HERE / 'lexicon-stats-inject.json').read_text())
    # 一简字：注入为次选的 17 个 + 原本已在该 2 码位的 9 个
    one_key_chars = sorted({t for t, _p, _f, _h in stats['injected_secondary']}
                           | {t for t, _p, _r in stats['already_present']})
    # 碰撞对手：注入码位的原首选（皇/题/存/近…），它们现在与一简字同码竞争
    demoted_chars = sorted({h for _t, _p, _f, h in stats['injected_secondary'] if h})
    collision_pairs = stats['collision_pairs']
    (BASE / 'groups.json').write_text(json.dumps(
        {'one_key_chars': one_key_chars, 'demoted_chars': demoted_chars,
         'collision_pairs': collision_pairs,
         'codes': {a: codes[a] for a in ARMS}}, ensure_ascii=False, indent=2), encoding='utf-8')

    files = {}
    for p in sorted(BASE.rglob('*')):
        if p.is_file() and not p.is_symlink():
            files[str(p.relative_to(BASE))] = {
                'bytes': p.stat().st_size,
                'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()}
    model = OURS / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin'
    files['tiger_sentence_native/mohu-sentence-ngram-v5.bin'] = {
        'bytes': model.stat().st_size,
        'sha256': hashlib.file_digest(model.open('rb'), 'sha256').hexdigest()}

    meta = {'seed': SEED, 'n': N, 'shards': SHARDS, 'sentences_per_shard': PER,
            'arms': {a: {k: v for k, v in cfg.items()} for a, cfg in ARMS.items()},
            'pool_unique_encodable': len(pool), 'rejected_unique': rejected,
            'common_encodable_characters': len(usable),
            'chars': sum(map(len, selected)), 'keys_per_arm': keys_per_arm,
            'one_key_chars': one_key_chars, 'demoted_chars': demoted_chars,
            'source_table': '~/Library/Rime/tiger.dict.yaml 快照（version 2026.03.01，'
                            'sort:by_weight，单字 113,246 行 / 99,144 字，一简 26 位）',
            'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=OURS, text=True).strip(),
            'protocol': '各臂按自身可达最短码≥2 生成语料（键数不同，一并报告）；'
                        '句子集合与顺序三臂相同，逐句配对；user_model=false '
                        'two_char_word_gate=false native_short_codes=true；'
                        '提前上屏出厂默认；训练重叠口径（语料与 V5 训练同源 fenci）',
            'files': files}
    (BASE / 'manifest.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in meta.items()
                      if k not in ('files', 'one_key_chars', 'demoted_chars')},
                     ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
