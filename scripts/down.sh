#!/usr/bin/env bash
# Tear down all engine containers (single + cluster). Leaves the network.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# bash 3.2 compatible (macOS default) — no mapfile.
ids=$(docker ps -aq --filter "name=^eng")
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086
  docker rm -f $ids >/dev/null
  log "removed engine container(s)"
else
  log "no engine containers to remove"
fi
rm -f "$RESULTS_DIR/.cluster-entry"
