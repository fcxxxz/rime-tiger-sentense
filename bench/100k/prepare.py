from pathlib import Path
import hashlib, json, random, re, shutil, subprocess
BASE = Path('/tmp/tiger-100k-20261026-a3D7SM')
REPO = Path('/Users/fuchuxuan/输入法/rime-tiger')
ORIG = Path('/Users/fuchuxuan/Downloads/Rime虎整句-20260826')
new, old = BASE/'new', BASE/'original'
new.mkdir(); old.mkdir()
shutil.copytree(REPO/'lua', new/'lua')
shutil.copytree(REPO/'tiger_sentence_native', new/'tiger_sentence_native', ignore=shutil.ignore_patterns('data', '*.bin', 'lua-5*', '*.o', '*.a', 'build', '__pycache__'))
(new/'tiger_sentence_native/data/tiger').mkdir(parents=True)
shutil.copy2(REPO/'tiger_sentence_native/data/tiger/tiger.lexicon.txt', new/'tiger_sentence_native/data/tiger/tiger.lexicon.txt')
shutil.copy2(REPO/'tiger.schema.yaml', new/'tiger.schema.yaml')
# The model is immutable in this evaluation; hashing it detects any external change.
(new/'tiger_sentence_native/mohu-sentence-ngram-v5.bin').symlink_to(REPO/'tiger_sentence_native/mohu-sentence-ngram-v5.bin')
shutil.copytree(ORIG/'lua', old/'lua')
(old/'models').mkdir()
shutil.copy2(ORIG/'models/sentence-ngram-mobile.bin', old/'models/sentence-ngram-mobile.bin')
for name in ['tiger_sentence.supplement.txt', '版本信息.txt', 'tiger_sentence.schema.yaml', 'rime.lua', 'README.md']:
 if (ORIG/name).exists(): shutil.copy2(ORIG/name, old/name)

a, b = {}, {}
for line in (new/'tiger_sentence_native/data/tiger/tiger.lexicon.txt').read_text().splitlines():
 p=line.split('\t')
 if len(p)>=3 and len(p[1])==1 and len(p[0])>=2 and p[2]=='1' and p[0].isalpha():
  a.setdefault(p[1],set()).add(p[0])
for line in (old/'lua/tiger_sentence_lexicon.lua').read_text().splitlines():
 m=re.search(r'\["([a-z]+)"\]\s*=\s*\{(.*)\}',line)
 if m and len(m[1])>=2:
  for ch,rank in re.findall(r'\{t="([^"]+)",r=(\d+)\}',m[2]):
   if len(ch)==1 and rank=='1': b.setdefault(ch,set()).add(m[1])
common={c:min(codes & b.get(c,set()),key=lambda s:(len(s),s)) for c,codes in a.items() if codes & b.get(c,set())}
assert common.get('传')=='jm' and common.get('物')=='qne'
seen=set(); pool=[]; rejected=0
with Path('/tmp/corpus79w.tsv').open() as h:
 for line in h:
  text=line.split('\t',1)[0]
  if text in seen: continue
  seen.add(text)
  if not 4<=len(text)<=30 or any(c not in common for c in text): rejected+=1; continue
  pool.append(text)
rng=random.Random(20261026)
selected=rng.sample(pool,100000)
with (BASE/'corpus.tsv').open('w') as out:
 for text in selected:
  codes=[common[c] for c in text]; bounds=[]
  for i,code in enumerate(codes): bounds.extend([i]*(len(code)-1)+[i+1])
  out.write(text+'\t'+''.join(codes)+'\t'+','.join(map(str,bounds))+'\n')
(BASE/'character-codes.json').write_text(json.dumps(common,ensure_ascii=False,indent=2))
files={}
for root in [new,old]:
 for p in sorted(root.rglob('*')):
  if p.is_file(): files[str(p.relative_to(BASE))]={'bytes':p.stat().st_size,'sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest()}
for p in [BASE/'corpus.tsv',BASE/'driver.lua']:
 files[p.name]={'bytes':p.stat().st_size,'sha256':hashlib.file_digest(p.open('rb'),'sha256').hexdigest()}
meta={'seed':20261026,'n':100000,'pool_unique_encodable':len(pool),'rejected_unique':rejected,'common_rank1_characters':len(common),'chars':sum(map(len,selected)),'keys':sum(len(common[c]) for t in selected for c in t),'git_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),'git_diff_stat':subprocess.check_output(['git','diff','--stat'],cwd=REPO,text=True),'files':files}
(BASE/'manifest.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in meta.items() if k!='files'},ensure_ascii=False,indent=2))
