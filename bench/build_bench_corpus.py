#!/usr/bin/env python3
"""从 V5 训练语料池（corpus/fenci/，源自魔虎仓 research/lm_sentence_compare/corpus/fenci/）
抽句并按词表 rank-1 全码编码，产出提前上屏基准语料 TSV（句\t码流）。
用法: python3 bench/build_bench_corpus.py [总数=100000] [输出=/tmp/corpus.tsv]
结果与结论见 bench/../docs/2026-10-23-early-commit-benchmark.md（原魔虎仓
docs/reports/ 同名报告的迁移副本）。"""
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOTAL = int(sys.argv[1]) if len(sys.argv) > 1 else 100_000
OUT = Path(sys.argv[2]) if len(sys.argv) > 2 else Path("/tmp/corpus.tsv")

char_best = {}
for line in io.open(ROOT / "tiger_sentence_native/data/tiger/tiger.lexicon.txt", encoding="utf-8"):
    if line.startswith("#"):
        continue
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3 and len(parts[1]) == 1 and len(parts[0]) >= 2:
        try:
            rank = int(parts[2])
        except ValueError:
            continue
        cur = char_best.get(parts[1])
        if cur is None or rank < cur[1]:
            char_best[parts[1]] = (parts[0], rank)

files = sorted((ROOT / "corpus/fenci").glob("*.txt"))
quota = TOTAL // len(files) + 1500
written = 0
with io.open(OUT, "w", encoding="utf-8") as out:
    for f in files:
        took = 0
        try:
            for line in io.open(f, encoding="utf-8", errors="ignore"):
                s = line.strip().replace(" ", "").replace("\u3000", "")
                if not (4 <= len(s) <= 30):
                    continue
                if took >= quota or written >= TOTAL:
                    break
                codes = []
                for ch in s:
                    b = char_best.get(ch)
                    if not b:
                        break
                    codes.append(b[0])
                else:
                    out.write(s + "\t" + "".join(codes) + "\n")
                    written += 1
                    took += 1
        except FileNotFoundError:
            pass
        if written >= TOTAL:
            break
print("corpus:", written, "->", OUT)
