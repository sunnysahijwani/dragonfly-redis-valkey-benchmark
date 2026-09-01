#!/usr/bin/env bash
# Phase A orchestrator (this Mac): the fair per-node comparison +
# single-node baselines that show why a lone Redis shard is not a fair peer.
# Directional only — NOT the published core-scaling curve.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export RUN_ID="$(date +%Y%m%d-%H%M%S)"   # one shared id for the whole batch
log "Phase A start | RUN_ID=$RUN_ID | note='${RUN_NOTE}'"
log "server cpus=$SERVER_CPUS threads=$SERVER_THREADS | shards=$SHARDS x io=$SHARD_IO_THREADS | client cpus=$CLIENT_CPUS"

bench_single() {   # engine
  bash "$HERE/up.sh" "$1" >/dev/null
  bash "$HERE/bench.sh" "$1" single eng 6379 0
  bash "$HERE/down.sh" >/dev/null
}
bench_cluster() {  # engine
  bash "$HERE/up-cluster.sh" "$1" "$SHARDS" >/dev/null
  read -r ch cp < "$RESULTS_DIR/.cluster-entry"
  bash "$HERE/bench.sh" "$1" cluster "$ch" "$cp" 1
  bash "$HERE/down.sh" >/dev/null
}

# --- Headline: fair per-node peers (DF one process vs multi-shard cluster) ---
bench_single  dragonfly
bench_cluster redis
bench_cluster valkey
# --- Baselines: single-thread shards (context, NOT the fair comparison) ---
bench_single  redis
bench_single  valkey

log "results appended to results/runs.csv (RUN_ID=$RUN_ID)"
log "Phase A done."
