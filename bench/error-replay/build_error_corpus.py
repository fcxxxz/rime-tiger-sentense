from pathlib import Path
import csv
B=Path('/tmp/tiger-errors-20261027-di_havvm')
PREV=Path('/tmp/tiger-100k-20261026-a3D7SM')
prev={}
for mode in ['new','original']:
 rows={}
 for p in PREV.glob(mode+'-[0-7].tsv'):
  for line in p.read_text().splitlines():
   if line.startswith('R\t'):
    f=line.split('\t');rows[int(f[1])]=f
 prev[mode]=rows
lines=[]
with (PREV/'all-errors.tsv').open() as h:
 for row in csv.DictReader(h,delimiter='\t'):
  lines.append((int(row['id']),row['target'],row['code']))
ids=sorted(set(lines))
out={}
for i,text,code in ids:
 n=prev['new'][i];o=prev['original'][i]
 assert (n[2],n[3])==(o[2],o[3])==(text,code)
 out[i]=(text,code,n,o)
with (B/'error-corpus.tsv').open('w') as h:
 for i in sorted(out):
  h.write(f"{i}\t{out[i][0]}\t{out[i][1]}\n")
# Driver consumes word\tcode\tbounds; emit bounds only when we can recompute
# them from the original full corpus (keeps every field identical).
full={}
for line_no,line in enumerate((PREV/'corpus.tsv').open(),start=1):
 f=line.rstrip('\n').split('\t')
 if len(f)>=3:full[line_no]=(f[0],f[1],f[2])
with (B/'corpus.tsv').open('w') as h:
 missing=[]
 for i in sorted(out):
  if i not in full:missing.append(i);continue
  text,code,bounds=full[i]
  assert (text,code)==(out[i][0],out[i][1]),i
  h.write(f"{text}\t{code}\t{bounds}\n")
assert not missing, f'ids missing from full corpus: {missing[:10]}'
print('error sentences',len(out),'new wrong among them',sum(1 for v in out.values() if not v[0].startswith(v[2][4])),'orig wrong',sum(1 for v in out.values() if not v[0].startswith(v[3][4])))
print((B/'corpus.tsv').stat().st_size,'bytes corpus')
