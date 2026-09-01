#!/usr/bin/env bash
# Two-box orchestrator — RUN THIS ON THE CLIENT box.
# For each config it: (1) SSHes to the SERVER to bring the engine up (HOST_NET),
# (2) drives load locally with bench.sh against the server's private IP,
# (3) SSHes to the SERVER to tear down. Results land in the CLIENT's runs.csv.
#
# Prereqs:
#   - passwordless SSH from client -> server  (ssh-keygen on client; append its
#     .pub to the server's ~/.ssh/authorized_keys)
#   - harness present at the SAME path on both boxes; HOST_NET validated
#
# Required env:
#   SERVER_SSH         ssh target for the server, e.g. ec2-user@10.0.1.10
#   SERVER_PRIVATE_IP  address the client hits,   e.g. 10.0.1.10
#   SERVER_CPUS        engine's physical cores,   e.g. 0-23  (single-config mode)
# Optional env:
#   REMOTE_DIR   harness path on the server (default: same as local ROOT)
#   DRY_RUN=1    print the server/client commands instead of running them
#   SHARD_IO_THREADS, plus the usual client-side workload knobs (REPS, MULTIKEY,
#   TEST_TIME, KEY_MAX, RATIOS, DATA_SIZES, PIPELINES, CLIENT_CPUS)
#   SCALE / ENGINES  (sweep mode)
#
# Usage:
#   # one config:
#   SERVER_SSH=ec2-user@10.0.1.10 SERVER_PRIVATE_IP=10.0.1.10 SERVER_CPUS=0-23 \
#     bash scripts/run-2box.sh dragonfly single 24
#   # full core-scaling sweep (SERVER_CPUS derived per level as 0-(n-1)):
#   SERVER_SSH=... SERVER_PRIVATE_IP=... SCALE="4 8 16 24 48" \
#     REPS=3 MULTIKEY=1 bash scripts/run-2box.sh sweep
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SERVER_SSH:?set SERVER_SSH=user@server-ip}"
: "${SERVER_PRIVATE_IP:?set SERVER_PRIVATE_IP=server-private-ip}"
: "${REMOTE_DIR:=$ROOT}"
: "${DRY_RUN:=0}"

# Run a command on the server (or print it in dry-run).
remote() {
  if [ "$DRY_RUN" = "1" ]; then echo "  [SERVER] $*"; else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER_SSH" "cd '$REMOTE_DIR' && $*"
  fi
}
# Run bench locally (or print it in dry-run).
local_bench() {
  if [ "$DRY_RUN" = "1" ]; then echo "  [CLIENT] $*"; return 0; fi
  eval "$@"
}

preflight() {
  [ "$DRY_RUN" = "1" ] && { log "DRY_RUN: not touching SSH"; return 0; }
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER_SSH" true \
    || die "cannot SSH to $SERVER_SSH (set up passwordless SSH client->server)"
  log "SSH to server OK"
}

# one config: <engine> <single|cluster> <cores> <server_cpus>
run_config() {
  local engine="$1" mode="$2" cores="$3" cpus="$4"
  local st="$cores" shards="$cores" port cl
  log "=== $engine/$mode @ ${cores} cores (cpus=$cpus) ==="
  local mem="MAXMEMORY=${MAXMEMORY:-4gb}"   # forwarded to the server (DF needs >=256MB*threads)
  if [ "$mode" = "single" ]; then
    port=6379; cl=0
    remote "HOST_NET=1 ANNOUNCE_IP=$SERVER_PRIVATE_IP SERVER_CPUS='$cpus' SERVER_THREADS=$st $mem bash scripts/up.sh $engine" \
      || { warn "server up failed ($engine/$mode)"; return 1; }
  else
    port=7001; cl=1
    remote "HOST_NET=1 ANNOUNCE_IP=$SERVER_PRIVATE_IP SERVER_CPUS='$cpus' SHARDS=$shards SHARD_IO_THREADS=${SHARD_IO_THREADS:-1} $mem bash scripts/up-cluster.sh $engine $shards" \
      || { warn "server cluster up failed ($engine)"; return 1; }
  fi
  local_bench "HOST_NET=1 SHARDS=$shards SERVER_THREADS=$st RUN_ID='$RUN_ID' RUN_NOTE='$RUN_NOTE' \
    bash '$HERE/bench.sh' $engine $mode $SERVER_PRIVATE_IP $port $cl" || warn "bench failed ($engine/$mode)"
  remote "bash scripts/down.sh" || warn "server down failed"
}

if [ "${1:-}" = "sweep" ]; then
  : "${SCALE:=4 8 16 24 48}"
  : "${ENGINES:=dragonfly:single redis:cluster valkey:cluster}"
  export RUN_ID="$(date +%Y%m%d-%H%M%S)"
  preflight
  log "SWEEP RUN_ID=$RUN_ID | scale='$SCALE' | engines='$ENGINES'"
  for cores in $SCALE; do
    cpus="0-$((cores-1))"   # ⚠️ verify these map to REAL physical cores (lscpu -e)
    export RUN_NOTE="scale-${cores}c"
    for spec in $ENGINES; do
      run_config "${spec%%:*}" "${spec##*:}" "$cores" "$cpus"
    done
  done
  log "sweep done. Results in results/runs.csv (RUN_ID=$RUN_ID). Report: python3 analysis/report.py"
else
  engine="${1:?usage: run-2box.sh <engine> <single|cluster> <cores>  |  run-2box.sh sweep}"
  mode="${2:?single|cluster}"; cores="${3:?cores}"
  : "${SERVER_CPUS:?set SERVER_CPUS=engine physical cores}"
  : "${RUN_ID:=$(date +%Y%m%d-%H%M%S)}"; export RUN_ID
  : "${RUN_NOTE:=2box-${cores}c}"; export RUN_NOTE
  preflight
  run_config "$engine" "$mode" "$cores" "$SERVER_CPUS"
  log "done. Report: python3 analysis/report.py $RUN_ID"
fi
