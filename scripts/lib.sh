#!/usr/bin/env bash
# Shared helpers. Every script sources this, which sources config.env.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/config.env"

# Network args for every helper container: host stack (bare metal) or bridge.
if [ "${HOST_NET:-0}" = "1" ]; then NET_RUN=(--network host); else NET_RUN=(--network "$NET"); fi

log()  { printf '\033[0;36m[bench]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

ensure_net() {
  [ "${HOST_NET:-0}" = "1" ] && return 0   # host network needs no bridge
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
}

# RESP CLI from a transient redis-cli container. Bridge mode reaches engines by
# container hostname; host mode by IP/127.0.0.1. (Valkey ships only valkey-cli,
# so we never exec into the engine container itself.)
rcli() {
  local host="$1" port="$2"; shift 2
  docker run --rm "${NET_RUN[@]}" "$IMG_REDIS" redis-cli -h "$host" -p "$port" "$@"
}

# Wait until <host:port> answers PING (RESP works for all 3 engines).
wait_ready() {
  local host="$1" port="${2:-6379}" tries=60
  for _ in $(seq 1 $tries); do
    if rcli "$host" "$port" ping 2>/dev/null | grep -qi PONG; then
      return 0
    fi
    sleep 0.25
  done
  die "$host did not become ready on port $port"
}

# Remove a container if it exists (idempotent).
rm_container() { docker rm -f "$1" >/dev/null 2>&1 || true; }
