#!/usr/bin/env python3
"""虎整魔虎版（hz 码表）vs 官方虎整（lvyww 发布包）双臂对照基准 staging。

与 2026-11-10 的 lvyww-100k 三方对照不同：本仓整句层已换虎整码表
（tiger_sentence_native/data/tiger/tiger.lexicon.txt 由 lvyww codes.txt
生成，2026-11-11），两臂码表同源——共同 rank-1 字集即该表本身。

新增指标（run.sh 用 /usr/bin/time -l 采内存）：句均上屏次数、每键上屏率、
打完瞬间残留码长/字数、每分片最大驻留内存（RSS）。

语料池：corpus/fenci 文件名排序、去重、4–30 字、全字可编码；
seed=20261111 抽 10,000 句。训练重叠口径（与 lvyww-100k 相同，注明）。
"""
from pathlib import Path
import hashlib, json, random, shutil

BASE = Path('/tmp/tiger-hz-lvyww-20261111')
OURS = Path('/Users/fuchuxuan/输入法/整句')
LVYWW = OURS / 'competitors/tsr-release/tiger-sentense-rime'
SEED = 20261111
N = 10_000
SHARDS = 8
PER = N // SHARDS

for m in ('new', 'lvyww'):
    (BASE / m).mkdir(parents=True)

# ---- new：本仓虎整魔虎版（hz 词表 = 仓内现行产物） ----
new = BASE / 'new'
shutil.copytree(OURS / 'lua', new / 'lua')
shutil.copytree(OURS / 'tiger_sentence_native', new / 'tiger_sentence_native',
                ignore=shutil.ignore_patterns('data', '*.bin', '*.zip', 'lua-5*',
                                              '*.o', '*.a', 'build', '__pycache__'))
(new / 'tiger_sentence_native/data/tiger').mkdir(parents=True)
shutil.copy2(OURS / 'tiger_sentence_native/data/tiger/tiger.lexicon.txt',
             new / 'tiger_sentence_native/data/tiger/tiger.lexicon.txt')
shutil.copy2(OURS / 'tiger.schema.yaml', new / 'tiger.schema.yaml')
(new / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin').symlink_to(
    OURS / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin')

# ---- lvyww：官方发布包 20260915 ----
lv = BASE / 'lvyww'
shutil.copytree(LVYWW / 'lua', lv / 'lua')
(lv / 'models').mkdir()
shutil.copy2(LVYWW / 'models/sentence-ngram-mobile.bin', lv / 'models/sentence-ngram-mobile.bin')
for name in ['tiger_sentence.codes.txt', 'tiger_sentence.char_ranks.txt',
             'tiger_sentence.full_code_whitelist.txt', 'tiger_sentence.supplement.txt',
             'tiger_sentence.schema.yaml', 'rime.lua', 'README.md']:
    if (LVYWW / name).exists():
        shutil.copy2(LVYWW / name, lv / name)

# ---- 双臂 rank-1 码表 → 共同集合（应同源一致） ----
ours_codes = {}
for line in (new / 'tiger_sentence_native/data/tiger/tiger.lexicon.txt').read_text(encoding='utf-8').splitlines():
    p = line.split('\t')
    if len(p) >= 3 and len(p[1]) == 1 and len(p[0]) >= 2 and p[2] == '1' and p[0].isalpha():
        ours_codes.setdefault(p[1], set()).add(p[0])

lvyww_codes, first_by_code = {}, {}
for line in (lv / 'tiger_sentence.codes.txt').read_text(encoding='utf-8').splitlines():
    if not line or line.startswith('#'):
        continue
    text, _, code = line.partition('\t')
    if not code or not code.isalpha() or len(code) < 2 or len(text) != 1:
        continue
    if code not in first_by_code:
        first_by_code[code] = text
for code, text in first_by_code.items():
    lvyww_codes.setdefault(text, set()).add(code)

common = {}
for ch, codes in ours_codes.items():
    shared = codes & lvyww_codes.get(ch, set())
    if shared:
        common[ch] = min(shared, key=lambda s: (len(s), s))
print(f"本仓 rank-1 字 {len(ours_codes)}，lvyww {len(lvyww_codes)}，共同 {len(common)}")
assert common.get('在') == 'ng' and common.get('的') == 'ue', \
    f"hz 口径 sanity 失败: 在={common.get('在')!r} 的={common.get('的')!r}"

# ---- 语料 ----
seen, pool, rejected = set(), [], 0
for f in sorted((OURS / 'corpus/fenci').glob('*.txt')):
    for line in f.open(encoding='utf-8', errors='ignore'):
        text = line.strip().replace(' ', '').replace('\u3000', '')
        if not text or text in seen:
            continue
        seen.add(text)
        if not 4 <= len(text) <= 30 or any(c not in common for c in text):
            rejected += 1
            continue
        pool.append(text)
print(f"池 {len(pool):,} 句（弃 {rejected:,}）")

rng = random.Random(SEED)
selected = rng.sample(pool, N)
with (BASE / 'corpus.tsv').open('w', encoding='utf-8') as out:
    for text in selected:
        codes = [common[c] for c in text]
        bounds = []
        for i, code in enumerate(codes):
            bounds.extend([i] * (len(code) - 1) + [i + 1])
        out.write(text + '\t' + ''.join(codes) + '\t' + ','.join(map(str, bounds)) + '\n')
(BASE / 'character-codes.json').write_text(json.dumps(common, ensure_ascii=False, indent=2), encoding='utf-8')

# ---- manifest ----
shutil.copy2(Path(__file__).parent / 'driver.lua', BASE / 'driver.lua')
files = {}
for party in (new, lv):
    for p in sorted(party.rglob('*')):
        if p.is_file() and not p.is_symlink():
            files[str(p.relative_to(BASE))] = {
                'bytes': p.stat().st_size,
                'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()}
for p in [BASE / 'corpus.tsv', BASE / 'character-codes.json']:
    files[p.name] = {'bytes': p.stat().st_size,
                     'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()}
model = OURS / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin'
files['new/tiger_sentence_native/mohu-sentence-ngram-v5.bin'] = {
    'bytes': model.stat().st_size,
    'sha256': hashlib.file_digest(model.open('rb'), 'sha256').hexdigest()}

meta = {'seed': SEED, 'n': N, 'shards': SHARDS, 'sentences_per_shard': PER,
        'pool_unique_encodable': len(pool), 'common_encodable_characters': len(common),
        'git_head': shutil.run(['git', '-C', str(OURS), 'rev-parse', '--short', 'HEAD'],
                               capture_output=True, text=True).stdout.strip(),
        'files': files}
(BASE / 'manifest.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k: v for k, v in meta.items() if k != 'files'}, ensure_ascii=False))
