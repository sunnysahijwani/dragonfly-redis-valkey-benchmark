#!/usr/bin/env bash
# The operational-simplicity story: cross-key ops that DF does freely but a
# Redis Cluster rejects unless keys share a hash slot. Demonstrated with the
# actual slot numbers + the hash-tag workaround, so it's rigorous not hand-wavy.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

K=(alpha bravo charlie)              # plain keys -> generally different slots
T=('{u1}:name' '{u1}:email')         # hash-tagged -> forced SAME slot

# Did the command error? redis-cli prints errors but exits 0, so string-match.
verdict() { case "$1" in *CROSSSLOT*|*ERR*|*WRONGTYPE*) echo REJECTED;; *) echo "OK";; esac; }

demo() {  # host port [cluster]
  local h="$1" p="$2" cmode="${3:-}"
  local c=(); [ -n "$cmode" ] && c=(-c)
  local cc=(${c[@]+"${c[@]}"})

  if [ -n "$cmode" ]; then
    printf '  slots: '; for k in "${K[@]}"; do
      printf '%s=%s ' "$k" "$(rcli "$h" "$p" cluster keyslot "$k" | tr -d '\r')"; done; echo
  fi

  rcli "$h" "$p" ${cc[@]+"${cc[@]}"} mset "${K[0]}" 1 "${K[1]}" 2 "${K[2]}" 3 >/dev/null 2>&1
  out=$(rcli "$h" "$p" ${cc[@]+"${cc[@]}"} mget "${K[@]}" 2>&1 | tr '\n' ' ')
  printf '  %-28s %s -> %s\n' "MGET 3 plain keys:" "$(verdict "$out")" "$out"

  out=$(rcli "$h" "$p" ${cc[@]+"${cc[@]}"} eval "return #KEYS" 3 "${K[@]}" 2>&1 | tr '\n' ' ')
  printf '  %-28s %s -> %s\n' "EVAL over 3 plain keys:" "$(verdict "$out")" "$out"

  rcli "$h" "$p" ${cc[@]+"${cc[@]}"} mset "${T[0]}" a "${T[1]}" b >/dev/null 2>&1
  out=$(rcli "$h" "$p" ${cc[@]+"${cc[@]}"} mget "${T[@]}" 2>&1 | tr '\n' ' ')
  printf '  %-28s %s -> %s\n' "MGET 2 hash-tagged keys:" "$(verdict "$out")" "$out"
}

# Single-box behavior demo; works in bridge OR host mode. Uses a fixed 3-shard
# cluster (minimum) — this proves CROSSSLOT behavior, not throughput, so no need
# to spin up a big cluster even if SERVER_THREADS is large on the server box.
[ "$HOST_NET" = "1" ] && EH="127.0.0.1" || EH="eng"

echo "================ Dragonfly (single process) ================"
bash "$HERE/up.sh" dragonfly >/dev/null; demo "$EH" 6379; bash "$HERE/down.sh" >/dev/null
echo
echo "================ Redis Cluster (3 shards) ================"
bash "$HERE/up-cluster.sh" redis 3 >/dev/null
read -r ch cp < "$RESULTS_DIR/.cluster-entry"; demo "$ch" "$cp" cluster; bash "$HERE/down.sh" >/dev/null
echo
log "DF: every multi-key op just works. Cluster: plain cross-slot keys REJECTED;"
log "only hash-tagged {same-slot} keys work — that constraint is the app's cost."
