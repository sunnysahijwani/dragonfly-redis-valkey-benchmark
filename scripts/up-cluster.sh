#!/usr/bin/env bash
# Start Redis/Valkey as an N-master cluster that shares the SERVER_CPUS budget,
# so the whole node is saturated — the fair per-node peer for one DF process.
# Usage: up-cluster.sh <redis|valkey> [num_shards]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

engine="${1:?usage: up-cluster.sh <redis|valkey> [num_shards]}"
shards="${2:-$SHARDS}"     # default from config; ⚖️ sweep this to find best layout
# Redis/Valkey Cluster require >=3 masters to cover all 16384 slots.
[ "$shards" -ge 3 ] || die "cluster needs >=3 master shards (got $shards)"
ensure_net

case "$engine" in
  redis)  img="$IMG_REDIS";  bin="redis-server" ;;
  valkey) img="$IMG_VALKEY"; bin="valkey-server" ;;
  *) die "cluster mode supports redis|valkey only (DF is a single process)";;
esac

nodes=()
for i in $(seq 1 "$shards"); do
  port=$((7000 + i))
  name="eng-c$i"
  rm_container "$name"
  # Host mode: advertise ANNOUNCE_IP so a remote client can reach every shard.
  hostflags=()
  [ "$HOST_NET" = "1" ] && hostflags=(--cluster-announce-ip "$ANNOUNCE_IP" \
    --cluster-announce-port "$port" --cluster-announce-bus-port "$((port+10000))")
  docker run -d --cpuset-cpus="$SERVER_CPUS" "${NET_RUN[@]}" --name "$name" \
    --ulimit memlock=-1 \
    "$img" "$bin" --port "$port" \
      --cluster-enabled yes --cluster-node-timeout 5000 \
      --save '' --appendonly no \
      --maxmemory "$MAXMEMORY" --maxmemory-policy noeviction \
      --io-threads "$SHARD_IO_THREADS" --protected-mode no \
      ${hostflags[@]+"${hostflags[@]}"} >/dev/null
  if [ "$HOST_NET" = "1" ]; then
    naddr="127.0.0.1:$port"     # cluster forms locally; clients use ANNOUNCE_IP
  else
    ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NET\").IPAddress}}" "$name")"
    naddr="$ip:$port"
  fi
  wait_ready "${naddr%:*}" "$port"
  nodes+=("$naddr")
  log "shard $i up: $name ($naddr)"
done

log "forming $shards-master cluster..."
docker run --rm "${NET_RUN[@]}" "$IMG_REDIS" \
  redis-cli --cluster create "${nodes[@]}" --cluster-yes >/dev/null
first_host="${nodes[0]%:*}"; first_port="${nodes[0]##*:}"
# Wait for gossip to converge to cluster_state:ok before anyone loads data —
# prevents populating a half-formed cluster (host-net gossip can be slower).
state="fail"
for _ in $(seq 1 60); do
  state=$(rcli "$first_host" "$first_port" cluster info 2>/dev/null | awk -F: '/cluster_state:/{print $2}' | tr -d '\r\n ')
  [ "$state" = "ok" ] && break
  sleep 0.25
done
[ "$state" = "ok" ] || warn "cluster_state=$state after wait (not ok)"
log "$engine cluster ready: $shards shards on cpus=$SERVER_CPUS host_net=$HOST_NET state=$state"
# Entry for the client: host mode advertises ANNOUNCE_IP (server's private IP in
# two-box); bridge mode uses the container IP.
[ "$HOST_NET" = "1" ] && echo "$ANNOUNCE_IP $first_port" > "$RESULTS_DIR/.cluster-entry" \
                      || echo "$first_host $first_port" > "$RESULTS_DIR/.cluster-entry"
