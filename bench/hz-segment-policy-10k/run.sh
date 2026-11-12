#!/bin/zsh
# 虎整组句资格 A/B（同引擎同词表，只换 tiger/ 配置）：
#   base    旧定顶（段边只取首选）
#   policy  auto_select_min_code_length=3 + high_freq_filter（虎整 HEAD 默认）
#   minlen  只开非首选单字组句（3,false）
#   hf      只开高频字最优码过滤（0,true）
# 语料复用 hz-lvyww-10k（seed 20261111，1 万句），先跑其 prepare.py。
# 用法: zsh run.sh [并行度=10]
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)
SRC=/tmp/tiger-hz-lvyww-20261111
B=/tmp/tiger-hz-policy-20261111
LUA=/opt/homebrew/opt/lua@5.4/bin/lua
test -x "$LUA" && LUA_BIN=$LUA || LUA_BIN=lua
PAR=${1:-10}
test -s $SRC/corpus.tsv || { echo "missing $SRC/corpus.tsv: run bench/hz-lvyww-10k/prepare.py" >&2; exit 1; }

rm -rf $B/stage && mkdir -p $B/stage/tiger_sentence_native/data/tiger
cp -R $REPO/lua $B/stage/lua
cp $REPO/tiger_sentence_native/*.lua $REPO/tiger_sentence_native/libtigerengine.dylib $B/stage/tiger_sentence_native/
cp $REPO/tiger_sentence_native/data/tiger/tiger.lexicon.txt $B/stage/tiger_sentence_native/data/tiger/
ln -sf $REPO/tiger_sentence_native/mohu-sentence-ngram-v5.bin $B/stage/tiger_sentence_native/
cp $SRC/corpus.tsv $B/corpus.tsv
cp ../hz-lvyww-10k/driver.lua $B/driver.lua
N=$(wc -l < $B/corpus.tsv | tr -d ' ')
PER=$(( (N + 7) / 8 ))

typeset -A ARMS
ARMS=(base "" policy "3,true" minlen "3,false" hf "0,true")
pids=()
for arm in base policy minlen hf; do
  for shard in {0..7}; do
    out=$B/$arm-$shard.tsv
    if [[ -f $out && $(tail -1 "$out" 2>/dev/null) == DONE* ]]; then
      echo "skip $arm-$shard (already done)"; continue
    fi
    while (( ${#pids[@]} >= PAR )); do
      newpids=(); for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && newpids+=($p); done
      pids=("${newpids[@]}"); (( ${#pids[@]} < PAR )) || sleep 5
    done
    echo "launch $arm-$shard"
    TIGER_BENCH_SEGMENT_POLICY=${ARMS[$arm]} $LUA_BIN $B/driver.lua new $B/stage $B/corpus.tsv \
      $((shard * PER + 1)) $PER $out > $B/$arm-$shard.log 2>&1 &
    pids+=($!)
  done
done
echo "waiting for ${#pids[@]} processes..."
fail=0
for p in "${pids[@]}"; do
  wait $p || { echo "process $p failed"; fail=1; }
done
echo "all shards finished (fail=$fail)"
exit $fail
