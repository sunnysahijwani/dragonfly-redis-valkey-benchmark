#!/usr/bin/env bash
# Pass B: the FULLY-DRIVEN cluster ceiling sweep. RUN ON THE CLIENT.
# For each core level and engine: SSH to server to bring up an N-shard cluster,
# drive it to saturation locally with cluster-saturate.sh (one memtier/shard),
# record, then SSH to tear it down. Shares Pass A's RUN_ID so report.py shows
# dragonfly-single / *-cluster / *-cluster-sat side by side.
# Env: SERVER_SSH, SERVER_PRIVATE_IP, RUN_ID, SCALE, SAT_ENGINES, SAT_WORKLOADS.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SERVER_SSH:?set SERVER_SSH}"; : "${SERVER_PRIVATE_IP:?set SERVER_PRIVATE_IP}"
: "${REMOTE_DIR:=$ROOT}"
: "${SCALE:=4 8 16 24 48}"
: "${SAT_ENGINES:=redis valkey}"
# workloads as ratio/data/pipe
: "${SAT_WORKLOADS:=1:10/100/16 1:1/100/16 1:10/1024/16}"
export RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
log "Pass B (cluster-sat) RUN_ID=$RUN_ID | scale='$SCALE' | engines='$SAT_ENGINES'"

for cores in $SCALE; do
  cpus="0-$((cores-1))"
  for engine in $SAT_ENGINES; do
    log "=== $engine cluster-sat @ ${cores} shards ==="
    if ssh -o BatchMode=yes "$SERVER_SSH" "cd '$REMOTE_DIR' && HOST_NET=1 ANNOUNCE_IP=$SERVER_PRIVATE_IP SERVER_CPUS='$cpus' SHARDS=$cores MAXMEMORY=32gb bash scripts/up-cluster.sh $engine $cores" >/dev/null 2>&1; then
      for w in $SAT_WORKLOADS; do
        r="${w%%/*}"; rest="${w#*/}"; d="${rest%%/*}"; p="${rest##*/}"
        HOST_NET=1 SERVER_CPUS="$cpus" CLIENT_CPUS=0-95 TEST_TIME=15 \
          RATIOS="$r" DATA_SIZES="$d" PIPELINES="$p" SAT_KEYS=100000 SAT_T=2 SAT_C=15 \
          RUN_ID="$RUN_ID" RUN_NOTE="sat-scale-${cores}c" \
          bash "$HERE/cluster-saturate.sh" "$engine" "$SERVER_PRIVATE_IP" 7001 "$cores" \
          || warn "cluster-sat failed: $engine ${cores}sh $w"
      done
      ssh -o BatchMode=yes "$SERVER_SSH" "cd '$REMOTE_DIR' && bash scripts/down.sh" >/dev/null 2>&1
    else
      warn "cluster up failed: $engine ${cores} shards (skipping)"
    fi
  done
done
log "Pass B done. RUN_ID=$RUN_ID"
