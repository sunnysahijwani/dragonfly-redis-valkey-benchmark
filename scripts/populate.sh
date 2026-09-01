#!/usr/bin/env bash
# Preload the keyspace so read-heavy runs actually HIT (fixes the ~72%-miss bug).
# Single client + sequential keys 1..KEY_MAX => exactly KEY_MAX distinct keys.
# Usage: populate.sh <host> <port> <cluster:0|1> <data_bytes>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

host="${1:?host}"; port="${2:?port}"; cluster="${3:-0}"; data="${4:-100}"
cflag=(); [ "$cluster" = "1" ] && cflag=(--cluster-mode)

log "populate: $KEY_MAX keys x ${data}B into $host:$port (cluster=$cluster)"
docker run --rm "${NET_RUN[@]}" --cpuset-cpus="$CLIENT_CPUS" "$IMG_MEMTIER" \
  -s "$host" -p "$port" ${cflag[@]+"${cflag[@]}"} \
  --ratio=1:0 -n "$KEY_MAX" -t 1 -c 1 \
  --key-minimum=1 --key-maximum="$KEY_MAX" --key-pattern=S:S -d "$data" \
  --hide-histogram >/dev/null 2>&1
loaded=$(rcli "$host" "$port" dbsize 2>/dev/null | tr -d '\r')
log "populate done: dbsize=$loaded"
