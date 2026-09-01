#!/usr/bin/env bash
# Sweep cluster shard counts so we report the engine's BEST per-node layout,
# not the first one we tried. This is the fairness fix that stops us
# accidentally sandbagging Redis/Valkey with a bad shard count.
# Usage: shard-sweep.sh <redis|valkey>   (default redis)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

engine="${1:-redis}"
: "${SHARD_LADDER:=3 4 6 8}"           # shard counts to try (>=3: cluster minimum)
export RUN_ID="$(date +%Y%m%d-%H%M%S)"
export RUN_NOTE="shard-sweep-$engine"
log "shard-sweep $engine | RUN_ID=$RUN_ID | ladder='$SHARD_LADDER' | server cpus=$SERVER_CPUS"

for s in $SHARD_LADDER; do
  if [ "$s" -lt 3 ]; then warn "skip $s shards (<3, cluster minimum)"; continue; fi
  export SHARDS="$s"                   # bench.sh reads this for cores_used + record
  log "--- $engine cluster with $s shards ---"
  # Resilient: one bad layout warns + continues, never aborts the whole sweep.
  if bash "$HERE/up-cluster.sh" "$engine" "$s" >/dev/null 2>&1; then
    read -r ch cp < "$RESULTS_DIR/.cluster-entry"
    bash "$HERE/bench.sh" "$engine" cluster "$ch" "$cp" 1 || warn "bench failed at $s shards"
  else
    warn "cluster start failed at $s shards (skipping)"
  fi
  bash "$HERE/down.sh" >/dev/null
done

log "sweep done. Best layout per workload:"
python3 "$ROOT/analysis/report_sweep.py" "$RUN_ID"
