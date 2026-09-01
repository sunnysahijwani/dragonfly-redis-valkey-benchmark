#!/usr/bin/env bash
# Drive memtier against a target; populate first so GETs hit; record every run
# (with its full config) into results/runs.csv.
# Standard workloads = GET/SET ratios. With MULTIKEY=1, ALSO run MGET/MSET
# (single-node only — N distinct keys cross-slot on a cluster; that's the
# operational story, see crossslot.sh).
# memtier is pinned to CLIENT_CPUS. ⚠️ On equal client/server cores the CLIENT
# may be the bottleneck — over-provision it in Phase B and confirm with ramp.sh.
# Usage: bench.sh <engine> <mode:single|cluster> <host> <port> <cluster:0|1>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

engine="${1:?engine}"; mode="${2:?mode}"; host="${3:?host}"; port="${4:?port}"; cluster="${5:-0}"
label="${engine}-${mode}"
mkdir -p "$RESULTS_DIR"
: "${RUN_ID:=$(date +%Y%m%d-%H%M%S)}"   # batch id; run-phase-a exports one shared id
cflag=(); [ "$cluster" = "1" ] && cflag=(--cluster-mode)
[ "$mode" = "cluster" ] && cores_used="$SHARDS" || cores_used="$SERVER_THREADS"

# One run + record. Args: <ratio_label> <data> <pipe> <rep> [extra memtier args...]
run_one() {
  local rlabel="$1" data="$2" pipe="$3" rep="$4"; shift 4
  local tag="${RUN_ID}__${label}__r${rlabel//:/-}__d${data}__p${pipe}__rep${rep}"
  local js="$RESULTS_DIR/${tag}.json"
  log "run: $label $rlabel d${data} p${pipe} rep${rep} (t=$CLIENT_THREADS c=$CLIENT_CONNS ${TEST_TIME}s)"
  if docker run --rm "${NET_RUN[@]}" --cpuset-cpus="$CLIENT_CPUS" \
      -v "$RESULTS_DIR:/results" "$IMG_MEMTIER" \
      -s "$host" -p "$port" ${cflag[@]+"${cflag[@]}"} \
      -t "$CLIENT_THREADS" -c "$CLIENT_CONNS" --test-time="$TEST_TIME" --pipeline="$pipe" \
      -d "$data" --key-minimum=1 --key-maximum="$KEY_MAX" \
      --distinct-client-seed --hide-histogram "$@" \
      --json-out-file="/results/${tag}.json" >/dev/null 2>&1; then
    python3 "$ROOT/analysis/record.py" "$js" \
      run_id="$RUN_ID" note="$RUN_NOTE" engine="$engine" mode="$mode" \
      shards="$SHARDS" server_threads="$SERVER_THREADS" shard_io_threads="$SHARD_IO_THREADS" \
      cores_used="$cores_used" server_cpus="$SERVER_CPUS" client_cpus="$CLIENT_CPUS" \
      client_threads="$CLIENT_THREADS" client_conns="$CLIENT_CONNS" \
      pipeline="$pipe" ratio="$rlabel" data_bytes="$data" key_max="$KEY_MAX" \
      test_time="$TEST_TIME" populate="$POPULATE" rep="$rep"
  else
    warn "FAILED: $tag"
  fi
}

# Build MGET/MSET command strings (N keys) once.
if [ "$MULTIKEY" = "1" ]; then
  ks=""; for _ in $(seq 1 "$MULTIKEY_N"); do ks="$ks __key__"; done
  MGET_CMD="MGET$ks"
  MSET_CMD="MSET"; for _ in $(seq 1 "$MULTIKEY_N"); do MSET_CMD="$MSET_CMD __key__ __data__"; done
  [ "$mode" = "cluster" ] && log "note: MULTIKEY skipped on cluster (cross-slot); see crossslot.sh"
fi

for data in $DATA_SIZES; do
  [ "$POPULATE" = "1" ] && bash "$HERE/populate.sh" "$host" "$port" "$cluster" "$data"
  for pipe in $PIPELINES; do
    for rep in $(seq 1 "$REPS"); do
      for ratio in $RATIOS; do
        run_one "$ratio" "$data" "$pipe" "$rep" --ratio="$ratio" --key-pattern=R:R
      done
      # Multi-key: single-node only (cluster would CROSSSLOT on distinct keys).
      if [ "$MULTIKEY" = "1" ] && [ "$mode" = "single" ]; then
        run_one "mget${MULTIKEY_N}" "$data" "$pipe" "$rep" \
          --command="$MGET_CMD" --command-key-pattern=R --command-miss-tracking=auto
        run_one "mset${MULTIKEY_N}" "$data" "$pipe" "$rep" \
          --command="$MSET_CMD" --command-key-pattern=R
      fi
    done
  done
done
