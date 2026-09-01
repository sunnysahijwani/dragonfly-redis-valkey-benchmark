#!/usr/bin/env bash
# Memory efficiency: load N fixed-size keys into each single-node engine and
# measure bytes/key (used_memory). DF's less-disputable claim. Load via memtier
# (SET-only, sequential keys) so every engine gets identical data.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

N="${1:-1000000}"     # keys
VAL="${2:-100}"       # value bytes
# Single-box tool; works in bridge OR host mode (engine reachable at eng/127.0.0.1).
[ "$HOST_NET" = "1" ] && EH="127.0.0.1" || EH="eng"
echo "Loading $N keys x ${VAL}B into each engine, then reading used_memory..."
printf '\n%-12s %14s %14s %10s\n' "engine" "used_memory" "bytes/key" "keys"
printf -- '---------------------------------------------------------\n'

mem_used() { rcli "$EH" 6379 info memory 2>/dev/null | awk -F: '/^used_memory:/{print $2}' | tr -d '\r'; }

for engine in dragonfly redis valkey; do
  bash "$HERE/up.sh" "$engine" >/dev/null
  base=$(mem_used)   # empty-server baseline, subtracted out
  # Single client, sequential keys 1..N => exactly N distinct keys (no overwrite).
  docker run --rm "${NET_RUN[@]}" --cpuset-cpus="$CLIENT_CPUS" "$IMG_MEMTIER" \
    -s "$EH" -p 6379 --ratio=1:0 -n "$N" -t 1 -c 1 \
    --key-minimum=1 --key-maximum="$N" --key-pattern=S:S -d "$VAL" \
    --hide-histogram >/dev/null 2>&1
  used=$(mem_used)
  keys=$(rcli "$EH" 6379 dbsize 2>/dev/null | tr -d '\r')
  if [ -n "$used" ] && [ "${keys:-0}" -gt 0 ] 2>/dev/null; then
    bpk=$(awk "BEGIN{printf \"%.1f\", ($used-$base)/$keys}")
    printf '%-12s %14s %14s %10s\n' "$engine" "$used" "$bpk" "$keys"
  else
    printf '%-12s %14s %14s %10s\n' "$engine" "${used:-n/a}" "n/a" "${keys:-0}"
  fi
  bash "$HERE/down.sh" >/dev/null
done
echo "(bytes/key = (used_memory - empty_baseline) / distinct_keys)"
