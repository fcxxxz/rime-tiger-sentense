#!/bin/zsh
# 三方十万句分片运行（prepare.py 之后执行）。
# 用法: zsh run.sh [并行度=24]
set -euo pipefail
cd "$(dirname "$0")"
BASE=/tmp/tiger-lvyww-100k-20261110
LUA=/opt/homebrew/opt/lua@5.4/bin/lua
test -x "$LUA" && LUA_BIN=$LUA || LUA_BIN=lua
PAR=${1:-24}
PER=1250
pids=()
for mode in new lvyww orig; do
  root=$BASE/$mode
  for shard in {0..7}; do
    start=$((shard * PER + 1))
    out=$BASE/$mode-$shard.tsv
    log=$BASE/$mode-$shard.log
    if [[ -f $out && $(tail -1 "$out" 2>/dev/null) == DONE* ]] then
      echo "skip $mode-$shard (done)"; continue
    fi
    while (( ${#pids[@]} >= PAR )); do
      newpids=(); for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && newpids+=($p); done
      pids=("${newpids[@]}"); (( ${#pids[@]} < PAR )) || sleep 5
    done
    echo "launch $mode-$shard"
    $LUA_BIN driver.lua "$mode" "$root" "$BASE/corpus.tsv" "$start" $PER "$out" > "$log" 2>&1 &
    pids+=($!)
  done
done
fail=0
for p in "${pids[@]}"; do wait $p || fail=1; done
echo "all shards finished (fail=$fail)"
exit $fail
