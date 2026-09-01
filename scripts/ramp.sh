#!/usr/bin/env bash
# Ramp client connections to find the throughput PLATEAU and prove WHO is the
# bottleneck: samples server vs client CPU during each step.
#   server maxed + client headroom  = server-bound  = VALID measurement
#   client maxed + server headroom  = client-bound  = need a bigger client box
# Run against an already-up engine. Usage: ramp.sh <host> <port> <cluster:0|1>
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

host="${1:?host}"; port="${2:?port}"; cluster="${3:-0}"
: "${CONNS_LADDER:=1 5 10 25 50 100}"   # connections PER thread
: "${RAMP_THREADS:=$CLIENT_THREADS}"
: "${RAMP_PIPELINE:=16}"
: "${RAMP_RATIO:=1:10}"
: "${RAMP_DATA:=100}"
: "${RAMP_TIME:=10}"
cflag=(); [ "$cluster" = "1" ] && cflag=(--cluster-mode)
scores=$(echo "$SERVER_CPUS" | awk -F- '{print ($2? $2-$1+1 : 1)}')  # server core count

[ "$POPULATE" = "1" ] && bash "$HERE/populate.sh" "$host" "$port" "$cluster" "$RAMP_DATA"

log "ramp: threads=$RAMP_THREADS pipe=$RAMP_PIPELINE data=${RAMP_DATA}B ratio=$RAMP_RATIO time=${RAMP_TIME}s"
log "(server pinned to $scores core(s) -> ~$((scores*100))% = fully saturated)"
printf '\n%-8s %-10s %-14s %-12s %-12s %s\n' conns totalconns ops/sec srvCPU% cliCPU% verdict
printf -- '----------------------------------------------------------------------------\n'

prev=0
for conns in $CONNS_LADDER; do
  rm_container ramp-cli
  docker run -d --name ramp-cli "${NET_RUN[@]}" --cpuset-cpus="$CLIENT_CPUS" \
    -v "$RESULTS_DIR:/results" "$IMG_MEMTIER" \
    -s "$host" -p "$port" ${cflag[@]+"${cflag[@]}"} \
    -t "$RAMP_THREADS" -c "$conns" --test-time="$RAMP_TIME" --pipeline="$RAMP_PIPELINE" \
    --ratio="$RAMP_RATIO" -d "$RAMP_DATA" --key-minimum=1 --key-maximum="$KEY_MAX" --key-pattern=R:R \
    --distinct-client-seed --hide-histogram --json-out-file="/results/_ramp.json" >/dev/null

  ssum=0; csum=0; n=0
  while docker ps --format '{{.Names}}' | grep -q '^ramp-cli$'; do
    stats=$(docker stats --no-stream --format '{{.Name}} {{.CPUPerc}}' 2>/dev/null)
    s=$(echo "$stats" | awk '/^eng/{gsub(/%/,"",$2); sum+=$2} END{print sum+0}')
    c=$(echo "$stats" | awk '/^ramp-cli/{gsub(/%/,"",$2); print $2+0}')
    ssum=$(awk "BEGIN{print $ssum+${s:-0}}"); csum=$(awk "BEGIN{print $csum+${c:-0}}"); n=$((n+1))
  done
  docker wait ramp-cli >/dev/null 2>&1
  ops=$(python3 -c "import json;print(json.load(open('$RESULTS_DIR/_ramp.json'))['ALL STATS']['Totals']['Ops/sec'])" 2>/dev/null || echo 0)
  savg=$(awk "BEGIN{printf \"%.0f\", ($n? $ssum/$n:0)}")
  cavg=$(awk "BEGIN{printf \"%.0f\", ($n? $csum/$n:0)}")

  # verdict: plateau if throughput gain < 5% vs previous step
  gain=$(awk "BEGIN{print ($prev>0? ($ops/$prev-1)*100 : 100)}")
  verdict=""
  awk "BEGIN{exit !($gain < 5)}" && verdict="PLATEAU"
  # who is maxed near saturation?
  awk "BEGIN{exit !($cavg > $scores*90)}" && verdict="$verdict client-bound?"
  awk "BEGIN{exit !($savg > $scores*90)}" && verdict="$verdict server-bound"

  printf '%-8s %-10s %-14s %-12s %-12s %s\n' \
    "$conns" "$((RAMP_THREADS*conns))" "$(printf '%.0f' "$ops")" "$savg" "$cavg" "$verdict"
  prev="$ops"
  rm_container ramp-cli
done
rm -f "$RESULTS_DIR/_ramp.json"
echo
log "Read the plateau row: if it says 'server-bound' the number is trustworthy;"
log "if 'client-bound', the client is the ceiling — give it more cores/a bigger box."
