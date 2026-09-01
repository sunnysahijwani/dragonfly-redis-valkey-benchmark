#!/usr/bin/env bash
# Start ONE engine in single-node mode, pinned + persistence off.
# Usage: up.sh <redis|valkey|dragonfly>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

engine="${1:?usage: up.sh <redis|valkey|dragonfly>}"
ensure_net
rm_container "eng"

# memlock applied to ALL engines (docker --ulimit, engine-agnostic) so it is
# symmetric — neutralises the "DF got memlock, others didn't" bias.
# NET_RUN = host stack (bare metal) or bridge; set in lib.sh from HOST_NET.
common_pin=(--cpuset-cpus="$SERVER_CPUS" "${NET_RUN[@]}" --name eng --ulimit memlock=-1)
[ "$HOST_NET" = "1" ] && readyhost="127.0.0.1" || readyhost="eng"

case "$engine" in
  redis)
    docker run -d "${common_pin[@]}" "$IMG_REDIS" \
      redis-server --save '' --appendonly no \
        --maxmemory "$MAXMEMORY" --maxmemory-policy noeviction \
        --io-threads "$SERVER_THREADS" --protected-mode no
    ;;
  valkey)
    docker run -d "${common_pin[@]}" "$IMG_VALKEY" \
      valkey-server --save '' --appendonly no \
        --maxmemory "$MAXMEMORY" --maxmemory-policy noeviction \
        --io-threads "$SERVER_THREADS" --protected-mode no
    ;;
  dragonfly)
    # ⚠️ NOTE: single-node DF (proactor_threads=N does I/O AND execution) is NOT
    # equal to single-node Redis (io-threads=N does I/O only, 1 exec thread).
    # This mode is a BASELINE ONLY. The fair peer is up-cluster.sh.
    # Parity made EXPLICIT (verified from `dragonfly --help`, not assumed):
    #   cache_mode=false  == Redis noeviction (OOM when full, no eviction)
    #   snapshot_cron=''  == persistence off
    # --security-opt seccomp=unconfined: Docker's default seccomp blocks the
    #   io_uring syscalls, so DF silently falls back to epoll (its slower path).
    #   This flag lets DF use io_uring — its native I/O. Redis/Valkey use epoll
    #   natively, so each engine runs on its own best path (fair, verified).
    #   NOTE: DF also needs maxmemory >= ~256MB * proactor_threads (12GB @ 48).
    docker run -d "${common_pin[@]}" --security-opt seccomp=unconfined "$IMG_DRAGONFLY" \
      dragonfly --logtostderr --proactor_threads="$SERVER_THREADS" \
        --maxmemory="$MAXMEMORY" --dbnum=1 \
        --cache_mode=false --snapshot_cron='' --dbfilename=''
    ;;
  *) die "unknown engine: $engine" ;;
esac

wait_ready "$readyhost" 6379
log "$engine up (single-node), server cpus=$SERVER_CPUS threads=$SERVER_THREADS host_net=$HOST_NET"
rcli "$readyhost" 6379 info server 2>/dev/null | grep -iE 'redis_version|dragonfly_version|os:' || true
