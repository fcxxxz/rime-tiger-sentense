#!/usr/bin/env python3
"""三方十万句对照基准 staging + 语料生成（2026-11-10）。

被测三方（同一批 100,000 句、同一共同 rank-1 码流、逐句配对）：
  new    本仓（整句/）：原生引擎 + V5 TCSKNM04，提前上屏出厂默认
  lvyww  lvyww/tiger-sentense-rime 官方发布包 20260915-3dd98bd
         （TCSKNM02 三阶 224,475,584B；HEAD 需要的五阶模型未随 Release
           公开，发布包才是用户可安装口径——报告中注明）
  orig   用户本地 Rime虎整句-20260826（2026-10-26 报告的原版参照，
         与 lvyww 同源不同代，保留做连续性对照）

共同单字集合 = 三方码表 rank-1 码的交集（每字取「长度、字典序」最短公共码，
码长 ≥2，不用一码简码）。语料池从本仓 corpus/fenci/（V5 训练分词语料，
源自魔虎仓 research/lm_sentence_compare/corpus/fenci/）重建：文件名排序、
逐行去重、4–30 字、全字可编码。seed=20261110 抽 100,000 句。

注意：池的行序由 fenci 文件名排序决定，与旧 792,441 句池（/tmp 已失）不
可复现同序，本批语料与 2026-10-26 报告的语料不同批，数字不可横比。
"""
from pathlib import Path
import hashlib, json, random, shutil, subprocess

BASE = Path('/tmp/tiger-lvyww-100k-20261110')
OURS = Path('/Users/fuchuxuan/输入法/整句')
LVYWW = OURS / 'competitors/tsr-release/tiger-sentense-rime'
ORIG = Path('/Users/fuchuxuan/Downloads/Rime虎整句-20260826')
SEED = 20261110
N = 100_000
SHARDS = 8
PER = N // SHARDS

for m in ('new', 'lvyww', 'orig'):
    (BASE / m).mkdir(parents=True)

# ---- new：本仓（模型以 symlink 指回仓库，防被动改） ----
new = BASE / 'new'
shutil.copytree(OURS / 'lua', new / 'lua')
shutil.copytree(OURS / 'tiger_sentence_native', new / 'tiger_sentence_native',
                ignore=shutil.ignore_patterns('data', '*.bin', '*.zip', 'lua-5*', '*.o', '*.a', 'build', '__pycache__'))
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

# ---- orig：2026-10-26 报告的本地原版参照 ----
og = BASE / 'orig'
shutil.copytree(ORIG / 'lua', og / 'lua')
(og / 'models').mkdir()
shutil.copy2(ORIG / 'models/sentence-ngram-mobile.bin', og / 'models/sentence-ngram-mobile.bin')
for name in ['tiger_sentence.supplement.txt', '版本信息.txt', 'tiger_sentence.schema.yaml', 'rime.lua', 'README.md']:
    if (ORIG / name).exists():
        shutil.copy2(ORIG / name, og / name)

# ---- 三方 rank-1 码表 → 共同集合 ----
import re

ours_codes = {}
for line in (new / 'tiger_sentence_native/data/tiger/tiger.lexicon.txt').read_text(encoding='utf-8').splitlines():
    p = line.split('\t')
    if len(p) >= 3 and len(p[1]) == 1 and len(p[0]) >= 2 and p[2] == '1' and p[0].isalpha():
        ours_codes.setdefault(p[1], set()).add(p[0])

# codes.txt：每行 "text\tcode"，同一 code 内行序即 rank（首行 = rank 1）
lvyww_codes = {}
first_by_code = {}
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

orig_codes = {}
for line in (og / 'lua/tiger_sentence_lexicon.lua').read_text(encoding='utf-8').splitlines():
    m = re.search(r'\["([a-z]+)"\]\s*=\s*\{(.*)\}', line)
    if m and len(m[1]) >= 2:
        for ch, rank in re.findall(r'\{t="([^"]+)",r=(\d+)\}', m[2]):
            if len(ch) == 1 and rank == '1':
                orig_codes.setdefault(ch, set()).add(m[1])

common = {}
for ch, codes in ours_codes.items():
    shared = codes & lvyww_codes.get(ch, set()) & orig_codes.get(ch, set())
    if shared:
        common[ch] = min(shared, key=lambda s: (len(s), s))
assert common.get('传') == 'jm' and common.get('物') == 'qne', \
    f"sanity failed: 传={common.get('传')!r} 物={common.get('物')!r}"

# ---- 语料池：fenci 文件名排序、去重、全字可编码 ----
seen = set()
pool = []
rejected = 0
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
for party in (new, lv, og):
    for p in sorted(party.rglob('*')):
        if p.is_file() and not p.is_symlink():
            files[str(p.relative_to(BASE))] = {
                'bytes': p.stat().st_size,
                'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()}
for p in [BASE / 'corpus.tsv', BASE / 'driver.lua']:
    files[p.name] = {'bytes': p.stat().st_size,
                     'sha256': hashlib.file_digest(p.open('rb'), 'sha256').hexdigest()}
model = OURS / 'tiger_sentence_native/mohu-sentence-ngram-v5.bin'
files['new/tiger_sentence_native/mohu-sentence-ngram-v5.bin'] = {
    'bytes': model.stat().st_size,
    'sha256': hashlib.file_digest(model.open('rb'), 'sha256').hexdigest()}

meta = {
    'seed': SEED, 'n': N, 'shards': SHARDS, 'sentences_per_shard': PER,
    'pool_unique_encodable': len(pool), 'rejected_unique': rejected,
    'common_rank1_characters': len(common),
    'chars': sum(map(len, selected)),
    'keys': sum(len(common[c]) for t in selected for c in t),
    'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=OURS, text=True).strip(),
    'git_status_clean': subprocess.check_output(['git', 'status', '--porcelain'], cwd=OURS, text=True).strip() == '',
    'versions': {
        'new': '本仓工作树（见 git_head）+ V5 TCSKNM04 u8 389,671,262B；'
               'all_ranks=false two_char_word_gate=false native_short_codes=true user_model=false；'
               '提前上屏出厂默认门槛 0.99（普通证据3键/强证据2键）',
        'lvyww': 'tiger-sentense-rime 发布包 20260915-3dd98bd-compact；'
                 'TCSKNM02 224,475,584B sha256 e3953f8f…；固定门槛0.995/三代证据/≥3键尾码；'
                 '无学习文件（supplement 仅随包11条静态）；HEAD 1.6.20261010.1 的五阶模型未公开，不可测',
        'orig': 'Rime虎整句-20260826（c3b0a4a+尾码置信度修正）；TCSKNM02 224,475,584B；'
                '与 2026-10-26 报告同物，保留连续性',
    },
    'protocol': '三方同语料逐句配对；每键 processor CPU（os.clock，每4键采样1键）；'
                '收尾解码取延续已提交文本且（new 另要求 raw 边界对齐）的首个候选；'
                '训练重叠测评（语料池与 V5 训练同源 fenci），非独立留出泛化',
    'files': files,
}
(BASE / 'manifest.json').write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding='utf-8')
print(json.dumps({k: v for k, v in meta.items() if k != 'files'}, ensure_ascii=False, indent=2))
