#!/usr/bin/env python3
"""Append ONE self-describing run to results/runs.csv.

Usage:
    record.py <memtier_json> key=value key=value ...

Metadata (the knobs) comes from key=value args so every result carries the
exact config it was produced under. Metrics come from the memtier JSON.
hit_rate proves GETs actually hit; ops_per_core is the secondary efficiency view.
"""
import csv, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS = os.path.join(ROOT, "results", "runs.csv")

# Fixed column order so the CSV stays stable across runs and is chart-ready.
META_COLS = ["run_id", "note", "engine", "mode", "shards", "server_threads",
             "shard_io_threads", "cores_used", "server_cpus", "client_cpus",
             "client_threads", "client_conns", "pipeline", "ratio",
             "data_bytes", "key_max", "test_time", "populate", "rep"]
METRIC_COLS = ["ops_per_sec", "ops_per_core", "p50_ms", "p99_ms", "p999_ms",
               "hit_rate", "hits_per_sec", "misses_per_sec", "conn_errors",
               "kb_per_sec"]
COLS = META_COLS + METRIC_COLS


def main():
    json_path = sys.argv[1]
    meta = {}
    for kv in sys.argv[2:]:
        k, _, v = kv.partition("=")
        meta[k] = v

    d = json.load(open(json_path))
    tot = d["ALL STATS"]["Totals"]
    pct = tot.get("Percentile Latencies", {})
    ops = float(tot.get("Ops/sec", 0))
    hits = float(tot.get("Hits/sec", 0))
    misses = float(tot.get("Misses/sec", 0))
    cores = float(meta.get("cores_used", 0) or 0)

    row = {c: meta.get(c, "") for c in META_COLS}
    row.update({
        "ops_per_sec": round(ops, 2),
        "ops_per_core": round(ops / cores, 2) if cores else "",
        "p50_ms": pct.get("p50.00", ""),
        "p99_ms": pct.get("p99.00", ""),
        "p999_ms": pct.get("p99.90", ""),
        "hit_rate": round(hits / (hits + misses), 4) if (hits + misses) else "",
        "hits_per_sec": round(hits, 2),
        "misses_per_sec": round(misses, 2),
        "conn_errors": tot.get("Connection Errors", ""),
        "kb_per_sec": round(float(tot.get("KB/sec", 0)), 2),
    })

    new = not os.path.exists(RUNS)
    with open(RUNS, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        if new:
            w.writeheader()
        w.writerow(row)
    print(f"recorded {meta.get('engine','?')}/{meta.get('mode','?')} "
          f"r{meta.get('ratio')} d{meta.get('data_bytes')} p{meta.get('pipeline')} "
          f"-> {int(ops):,} ops/s, hit_rate={row['hit_rate']}")


if __name__ == "__main__":
    main()
