from pathlib import Path
import gzip, hashlib, json, shutil, tarfile
B=Path('/tmp/tiger-100k-20261026-a3D7SM')
REPO=Path('/Users/fuchuxuan/输入法/rime-tiger')
DEST=REPO/'docs/reports/2026-10-26-tiger-100k-comparison'
assert (B/'summary.json').exists() and (B/'report.md').exists()
assert not DEST.exists(), 'Refuse to overwrite existing report directory'
DEST.mkdir()
for name in ['report.md','summary.json','early-errors.md','all-errors.tsv','manifest.json','driver.lua','aggregate.py','prepare.py','report.py','character-codes.json']:
 shutil.copy2(B/name,DEST/name)
for name in ['all-errors.tsv','corpus.tsv','paired-differences.tsv']:
 with (B/name).open('rb') as src,gzip.open(DEST/(name+'.gz'),'wb') as out:shutil.copyfileobj(src,out)
with tarfile.open(DEST/'raw-results.tar.gz','w:gz') as out:
 for pattern in ['new-[0-7].tsv','original-[0-7].tsv','new-[0-7].log','original-[0-7].log']:
  for path in sorted(B.glob(pattern)):out.add(path,arcname=path.name)
with tarfile.open(DEST/'runtime-snapshots.tar.gz','w:gz') as out:
 for root in [B/'new',B/'original']:
  for path in sorted(root.rglob('*')):
   if path.is_file() and path.suffix not in {'.bin','.zip'} and not any(part.startswith('.') for part in path.relative_to(root).parts):
    out.add(path,arcname=str(path.relative_to(B)))
hashes={p.name:hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in DEST.iterdir() if p.is_file()}
(DEST/'artifact-sha256.json').write_text(json.dumps(hashes,indent=2))
print(DEST)
print('artifact bytes',sum(p.stat().st_size for p in DEST.iterdir()))
