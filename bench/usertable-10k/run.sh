#!/bin/zsh
# 用户虎单码表三臂分片运行（prepare.py 之后执行）。用法: zsh run.sh [并行度=24]
set -euo pipefail
B=/tmp/tiger-usertable-20261110
LUA=/opt/homebrew/opt/lua@5.4/bin/lua
test -x "$LUA" && LUA_BIN=$LUA || LUA_BIN=lua
PAR=${1:-24}
PER=$(python3 -c "import json;print(json.load(open('$B/manifest.json'))['sentences_per_shard'])")
pids=()
ARMS=($(python3 -c "import json;print(' '.join(json.load(open('$B/manifest.json'))['arms']))"))
for arm in $ARMS; do
  lex=$(python3 -c "import json;print(json.load(open('$B/manifest.json'))['arms']['$arm']['lexicon'])")
  ar=$(python3 -c "import json;print(json.load(open('$B/manifest.json'))['arms']['$arm']['all_ranks'])")
  for shard in {0..7}; do
    start=$((shard * PER + 1))
    out=$B/$arm-$shard.tsv
    log=$B/$arm-$shard.log
    if [[ -f $out && $(tail -1 "$out" 2>/dev/null) == DONE* ]] then
      echo "skip $arm-$shard (done)"; continue
    fi
    while (( ${#pids[@]} >= PAR )); do
      newpids=(); for p in "${pids[@]}"; do kill -0 $p 2>/dev/null && newpids+=($p); done
      pids=("${newpids[@]}"); (( ${#pids[@]} < PAR )) || sleep 5
    done
    echo "launch $arm-$shard"
    $LUA_BIN "$B/driver.lua" "$arm" "$B" "$B/corpus-$arm.tsv" "$start" "$PER" "$out" "$lex" "$ar" \
      > "$log" 2>&1 &
    pids+=($!)
  done
done
fail=0
for p in "${pids[@]}"; do wait $p || fail=1; done
echo "all shards finished (fail=$fail)"
exit $fail
