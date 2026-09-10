#!/usr/bin/env bash
# go-redis autopipeline session — RUN THIS ON THE CLIENT box.
# One cluster bring-up, four phases against it, teardown:
#   1. memtier REALISTIC reference   (single cluster-mode client — bench.sh)
#   2. memtier CEILING reference     (one memtier per shard — cluster-saturate.sh)
#   3. go-redis tool sweep           (fdcluster-bench: arms x worker shapes x in-flight)
#   4. optional sampling calibration (only if GR_CALIBRATE_FLAG is set — needs
#      the tool's full-sampling flag from Nedyalko; skipped otherwise)
# Fresh same-day references mean the go-redis numbers are never compared
# against stale data. Every go-redis run's JSON is kept in results/goredis-json/
# and recorded to results/runs-goredis.csv; memtier rows land in runs.csv.
#
# Prereqs (see PHASE-B-RUNBOOK.md):
#   - passwordless SSH client -> server; harness at same path on both boxes
#   - fdcluster-bench-linux binary at $GR_BIN (cross-compiled on the Mac)
#
# Required env:
#   SERVER_SSH  SERVER_PRIVATE_IP
# Main knobs (defaults = the published capture conditions):
#   CORES=48 RATIOS="1:10" DATA_SIZES="100" PIPELINES="16" KEY_MAX=1000000
#   TEST_TIME=20 REPS=2 CLIENT_THREADS=48 CLIENT_CONNS=20 MAXMEMORY=32gb
#   GR_INFLIGHTS="3072 6144"  GR_WORKER_SHAPES="16 64"  GR_REPS=2
#   GR_BIN=$ROOT/fdcluster-bench-linux
#   SKIP_MEMTIER=1 to skip phases 1-2 (go-redis only, e.g. a re-run)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${SERVER_SSH:?set SERVER_SSH=user@server-ip}"
: "${SERVER_PRIVATE_IP:?set SERVER_PRIVATE_IP=server-private-ip}"
: "${REMOTE_DIR:=$ROOT}"
: "${CORES:=48}"
: "${MAXMEMORY:=32gb}"
: "${KEY_MAX:=1000000}"
: "${TEST_TIME:=20}"
: "${REPS:=2}"
: "${GR_INFLIGHTS:=3072 6144}"
: "${GR_WORKER_SHAPES:=16 64}"
: "${GR_REPS:=2}"
: "${GR_WARMUP:=5s}"
: "${GR_BIN:=$ROOT/fdcluster-bench-linux}"
: "${SKIP_MEMTIER:=0}"
export RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)}"
export RUN_NOTE="${RUN_NOTE:-goredis-session-${CORES}c}"

RATIO="${RATIOS:-1:10}"; RATIO="${RATIO%% *}"
DATA="${DATA_SIZES:-100}"; DATA="${DATA%% *}"
rs="${RATIO%%:*}"; rg="${RATIO##*:}"
cpus="0-$((CORES-1))"
JSON_DIR="$RESULTS_DIR/goredis-json"; mkdir -p "$JSON_DIR"

[ -x "$GR_BIN" ] || die "go-redis binary not found/executable at $GR_BIN (cross-compile on the Mac, scp here)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SERVER_SSH" true || die "cannot SSH to $SERVER_SSH"
log "SESSION RUN_ID=$RUN_ID | cores=$CORES ratio=$RATIO data=${DATA}B key_max=$KEY_MAX"

remote() { ssh -o BatchMode=yes "$SERVER_SSH" "cd '$REMOTE_DIR' && $*"; }

# ---- cluster up (once for the whole session) --------------------------------
log "=== cluster up: redis x$CORES shards ==="
remote "HOST_NET=1 ANNOUNCE_IP=$SERVER_PRIVATE_IP SERVER_CPUS='$cpus' SHARDS=$CORES MAXMEMORY=$MAXMEMORY bash scripts/up-cluster.sh redis $CORES" \
  || die "cluster up failed"
trap 'log "teardown"; remote "bash scripts/down.sh" || true' EXIT

if [ "$SKIP_MEMTIER" != "1" ]; then
  # ---- phase 1: memtier realistic reference ---------------------------------
  log "=== phase 1: memtier realistic (cluster-mode client) ==="
  HOST_NET=1 SHARDS=$CORES SERVER_THREADS=$CORES RUN_ID="$RUN_ID" RUN_NOTE="${RUN_NOTE}-ref" \
    bash "$HERE/bench.sh" redis cluster "$SERVER_PRIVATE_IP" 7001 1 || warn "realistic reference failed"

  # ---- phase 2: memtier ceiling reference -----------------------------------
  log "=== phase 2: memtier ceiling (one memtier per shard) ==="
  HOST_NET=1 RUN_ID="$RUN_ID" bash "$HERE/cluster-saturate.sh" redis "$SERVER_PRIVATE_IP" 7001 "$CORES" \
    || warn "ceiling reference failed"
fi

# ---- phase 3: go-redis sweep ------------------------------------------------
# Arms: cluster-fd async (the POC, at each worker shape), cluster-fd blocking
# (sync face, workers = total in-flight), fd-per-node baseline (16 workers).
gr_run() { # arm workers inflight async(0|1) rep
  local arm="$1" workers="$2" inflight="$3" async="$4" rep="$5" aflag=() alabel="sync"
  [ "$4" = "1" ] && { aflag=(-async); alabel="async"; }
  local tag="${arm}-${alabel}-w${workers}-i${inflight}-rep${rep}"
  local out="$JSON_DIR/$RUN_ID-$tag.json"
  log "go-redis: $tag"
  # Sample whole-box client CPU busy% every 2s for the duration of the run —
  # the "was the client actually saturated?" question must answer itself from
  # the CSV (lesson from session 1, where we couldn't prove it either way).
  local cpu_samples="$JSON_DIR/$RUN_ID-$tag.cpu"
  ( while :; do top -bn1 2>/dev/null | awk '/^%Cpu/{print 100-$8; exit}'; sleep 2; done > "$cpu_samples" ) &
  local sampler_pid=$!
  local rc=0
  "$GR_BIN" -arm "$arm" -addrs "$SERVER_PRIVATE_IP:7001,$SERVER_PRIVATE_IP:7002,$SERVER_PRIVATE_IP:7003" \
      ${aflag[@]+"${aflag[@]}"} ${GR_EXTRA:-} -workers "$workers" -inflight "$inflight" \
      -keyspace "$KEY_MAX" -payload "$DATA" -ratio-set "$rs" -ratio-get "$rg" \
      -duration "${TEST_TIME}s" -warmup "$GR_WARMUP" 2>"$JSON_DIR/$RUN_ID-$tag.stderr" >"$out" || rc=$?
  kill "$sampler_pid" 2>/dev/null; wait "$sampler_pid" 2>/dev/null
  # Warmup skews the first samples low; average the samples from the measured
  # window only (drop the first warmup/2s worth).
  local skip=$(( ${GR_WARMUP%s} / 2 ))
  local cpu_avg
  cpu_avg=$(awk -v skip="$skip" 'NR>skip{s+=$1;n++} END{if(n)printf "%.1f", s/n}' "$cpu_samples")
  if [ "$rc" = "0" ]; then
    python3 "$ROOT/analysis/record_goredis.py" "$out" \
      run_id="$RUN_ID" note="$RUN_NOTE" engine=redis mode=cluster shards="$CORES" \
      cores_used="$CORES" server_cpus="$cpus" client_cpus="all" async="$4" rep="$rep" \
      client_cpu_pct="${cpu_avg:-}" \
      || warn "record failed: $tag"
    [ -n "$cpu_avg" ] && log "  client cpu avg: ${cpu_avg}% busy"
  else
    warn "go-redis run failed: $tag (see $JSON_DIR/$RUN_ID-$tag.stderr)"
  fi
}

log "=== phase 3: go-redis sweep (inflights: $GR_INFLIGHTS | shapes: $GR_WORKER_SHAPES | reps: $GR_REPS) ==="
for rep in $(seq 1 "$GR_REPS"); do
  for N in $GR_INFLIGHTS; do
    for W in $GR_WORKER_SHAPES; do
      gr_run cluster-fd "$W" "$((N / W))" 1 "$rep"        # the POC, async window
    done
    gr_run cluster-fd "$N" 1 0 "$rep"                     # blocking face
    gr_run fd-per-node 16 "$((N / 16))" 1 "$rep"          # per-node upper bound
  done
done

# ---- phase 4: optional sampling calibration ---------------------------------
if [ -n "${GR_CALIBRATE_FLAG:-}" ]; then
  log "=== phase 4: sampling calibration (moderate load, 1/32 vs full) ==="
  gr_run cluster-fd 16 64 1 cal-sampled
  # same shape with full sampling: flag name comes from Nedyalko's tool
  GR_EXTRA="$GR_CALIBRATE_FLAG" gr_run cluster-fd 16 64 1 cal-full || true
else
  log "phase 4 skipped (set GR_CALIBRATE_FLAG once the tool has a full-sampling flag)"
fi

log "session done. RUN_ID=$RUN_ID"
log "  memtier rows  -> results/runs.csv"
log "  go-redis rows -> results/runs-goredis.csv (JSON in results/goredis-json/)"
