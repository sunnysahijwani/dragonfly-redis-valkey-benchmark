#!/usr/bin/env bash
# Drive a Redis/Valkey CLUSTER to its TRUE per-node ceiling: one memtier process
# per shard, connected DIRECTLY to that shard's port (non-cluster-mode) with a
# {hash-tag} key-prefix whose slot that shard owns — so each shard gets a single
# dedicated, fully-pipelined stream (exactly what a single Redis core can take).
# This is what an optimal client-side-routing cluster client with enough client
# resources achieves; memtier's single-process --cluster-mode cannot (routing
# contention + connection fan-out leave shards ~15-35% idle).
# RUN ON THE CLIENT against an already-up cluster. Appends a "cluster-sat" row.
# Usage: cluster-saturate.sh <engine> <entry_host> <entry_port> <num_shards>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

engine="${1:?engine}"; host="${2:?host}"; port="${3:?port}"; N="${4:?shards}"
: "${RUN_ID:=$(date +%Y%m%d-%H%M%S)}"
DATA="${DATA_SIZES:-100}"; DATA="${DATA%% *}"
RATIO="${RATIOS:-1:10}";   RATIO="${RATIO%% *}"
PIPE="${PIPELINES:-16}";   PIPE="${PIPE%% *}"
KPS="${SAT_KEYS:-100000}"; TSECS="${TEST_TIME:-15}"; PT="${SAT_T:-2}"; PC="${SAT_C:-15}"
mkdir -p "$RESULTS_DIR"

# Ask the cluster which port owns which slots, then find one hash-tag per shard
# whose slot that port owns. Emits "<shard_port> <tag>" lines. Verified from the
# live topology (not assumed from creation order).
MAP=$(rcli "$host" "$port" cluster nodes 2>/dev/null | python3 -c '
import sys
def crc16(s):
    c=0
    for b in s.encode():
        c^=b<<8
        for _ in range(8): c=((c<<1)^0x1021)&0xFFFF if c&0x8000 else (c<<1)&0xFFFF
    return c
masters=[]
for line in sys.stdin:
    p=line.split()
    if len(p)<9 or "master" not in p[2]: continue
    port=int(p[1].split("@")[0].rsplit(":",1)[1])
    lo=hi=None
    for f in p[8:]:
        if f.startswith("["): continue
        if "-" in f: a,b=f.split("-"); lo,hi=int(a),int(b); break
        if f.isdigit(): lo=hi=int(f); break
    if lo is not None: masters.append((port,lo,hi))
# a pool of candidate tags with their slots
tags=[("s%d"%i, crc16("s%d"%i)%16384) for i in range(len(masters)*200)]
for (port,lo,hi) in sorted(masters):
    for t,sl in tags:
        if lo<=sl<=hi: print(port,t); break
')
NM=$(echo "$MAP" | grep -c .)
[ "$NM" -eq "$N" ] || die "port->tag mapping got $NM of $N shards"
log "cluster-saturate $engine: $N shards x memtier(t=$PT c=$PC pipe=$PIPE) r=$RATIO d=${DATA}B ${TSECS}s"
docker rm -f $(docker ps -aq --filter "name=^sat_") $(docker ps -aq --filter "name=^pop_") >/dev/null 2>&1 || true

# populate each shard directly (parallel)
while read -r sp tag; do
  docker run -d --name "pop_$sp" --network host "$IMG_MEMTIER" \
    -s "$host" -p "$sp" --key-prefix "{$tag}:" --ratio=1:0 \
    -n "$KPS" -t 1 -c 2 --key-minimum=1 --key-maximum="$KPS" --key-pattern=S:S -d "$DATA" \
    --hide-histogram >/dev/null 2>&1
done <<< "$MAP"
while read -r sp tag; do docker wait "pop_$sp" >/dev/null 2>&1; docker rm -f "pop_$sp" >/dev/null 2>&1; done <<< "$MAP"
log "populated $N shards"

# bench each shard directly, in parallel
while read -r sp tag; do
  docker run -d --name "sat_$sp" --network host -v /tmp:/results "$IMG_MEMTIER" \
    -s "$host" -p "$sp" --key-prefix "{$tag}:" \
    -t "$PT" -c "$PC" --test-time="$TSECS" --pipeline="$PIPE" --ratio="$RATIO" -d "$DATA" \
    --key-minimum=1 --key-maximum="$KPS" --key-pattern=R:R --distinct-client-seed \
    --hide-histogram --json-out-file="/results/sat_$sp.json" >/dev/null 2>&1
done <<< "$MAP"
while read -r sp tag; do docker wait "sat_$sp" >/dev/null 2>&1; done <<< "$MAP"
log "bench done; aggregating $N shard results"

PORTS=$(echo "$MAP" | awk '{print $1}' | tr '\n' ' ')
python3 - $PORTS <<'PY'
import json,sys,statistics
ports=sys.argv[1:]
ops=hits=misses=kb=0.0; errs=0; p50=[];p99=[];p999=[]
for sp in ports:
    T=json.load(open(f"/tmp/sat_{sp}.json"))["ALL STATS"]["Totals"]
    ops+=float(T.get("Ops/sec",0)); hits+=float(T.get("Hits/sec",0)); misses+=float(T.get("Misses/sec",0))
    kb+=float(T.get("KB/sec",0));   errs+=int(T.get("Connection Errors",0) or 0)
    pct=T.get("Percentile Latencies",{})
    if pct:
        p50.append(float(pct.get("p50.00",0))); p99.append(float(pct.get("p99.00",0))); p999.append(float(pct.get("p99.90",0)))
out={"ALL STATS":{"Totals":{"Ops/sec":round(ops,2),"Hits/sec":round(hits,2),"Misses/sec":round(misses,2),
     "KB/sec":round(kb,2),"Connection Errors":errs,
     "Percentile Latencies":{"p50.00":round(statistics.median(p50),3) if p50 else "",
        "p99.00":round(max(p99),3) if p99 else "","p99.90":round(max(p999),3) if p999 else ""}}}}
json.dump(out, open("/tmp/sat_combined.json","w"))
PY

python3 "$ROOT/analysis/record.py" /tmp/sat_combined.json \
  run_id="$RUN_ID" note="$RUN_NOTE" engine="$engine" mode="cluster-sat" \
  shards="$N" server_threads="$N" shard_io_threads="${SHARD_IO_THREADS:-1}" \
  cores_used="$N" server_cpus="$SERVER_CPUS" client_cpus="$CLIENT_CPUS" \
  client_threads="$((PT*N))" client_conns="$PC" \
  pipeline="$PIPE" ratio="$RATIO" data_bytes="$DATA" key_max="$KPS" \
  test_time="$TSECS" populate=1 rep="${REP:-1}"
docker rm -f $(docker ps -aq --filter "name=^sat_") >/dev/null 2>&1 || true
