#!/bin/zsh
# 双臂分片运行（prepare.py 之后执行），每分片用 /usr/bin/time -l 采最大驻留内存。
# 用法: zsh run.sh [并行度=16]
set -euo pipefail
B=/tmp/tiger-hz-lvyww-50k-20261111
LUA=/opt/homebrew/opt/lua@5.4/bin/lua
test -x "$LUA" && LUA_BIN=$LUA || LUA_BIN=lua
PAR=${1:-16}
PER=$(python3 -c "import json;print(json.load(open('$B/manifest.json'))['sentences_per_shard'])")
pids=()
for mode in new lvyww; do
  for shard in {0..7}; do
    start=$((shard * PER + 1))
    out=$B/$mode-$shard.tsv
    timelog=$B/$mode-$shard.time
    log=$B/$mode-$shard.log
    if [[ -f $out && $(tail -1 "$out" 2>/dev/null) == DONE* && -s $timelog ]]; then
      echo "skip $mode-$shard (done)"; continue
    fi
    while (( ${#pids[@]} >= PAR )); do
      newpids=(); for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && newpids+=($p); done
      pids=("${newpids[@]}"); (( ${#pids[@]} < PAR )) || sleep 5
    done
    echo "launch $mode-$shard"
    /usr/bin/time -l $LUA_BIN "$B/driver.lua" "$mode" "$B/$mode" "$B/corpus.tsv" "$start" "$PER" "$out" \
      > "$log" 2> "$timelog" &
    pids+=($!)
  done
done
fail=0
for p in "${pids[@]}"; do wait $p || fail=1; done
echo "all shards finished (fail=$fail)"
exit $fail
