#!/usr/bin/env python3
"""Append ONE go-redis benchmark run to results/runs-goredis.csv.

Usage:
    record_goredis.py <tool_json> key=value key=value ...

Same contract as record.py, but for the go-redis autopipeline tool
(fdcluster-bench): metrics come from its JSON summary, knobs the tool
already echoes (arm/workers/inflight/ratio/...) are taken from the JSON
and can be overridden or extended via key=value args. Kept as a separate
CSV because the client-side columns differ from the memtier schema.
"""
import csv, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNS = os.path.join(ROOT, "results", "runs-goredis.csv")

META_COLS = ["run_id", "note", "engine", "mode", "shards", "cores_used",
             "server_cpus", "client_cpus", "client", "arm", "workers",
             "inflight", "total_inflight", "async", "pipeline_equiv",
             "ratio", "data_bytes", "key_max", "test_time", "rep"]
METRIC_COLS = ["ops_per_sec", "ops_per_core", "p50_ms", "p99_ms", "p999_ms",
               "errors", "total_conns", "total_active", "kb_per_sec",
               "client_cpu_pct"]   # mean whole-box client CPU busy% during the run
COLS = META_COLS + METRIC_COLS

# JSON fields the tool echoes -> our column names
FROM_JSON = {"arm": "arm", "workers": "workers", "inflight": "inflight",
             "total_inflight": "total_inflight", "keyspace": "key_max",
             "payload": "data_bytes", "ops_per_sec": "ops_per_sec",
             "p50_ms": "p50_ms", "p99_ms": "p99_ms", "p999_ms": "p999_ms",
             "errors": "errors", "total_conns": "total_conns",
             "total_active": "total_active"}


def main():
    d = json.load(open(sys.argv[1]))
    meta = {}
    for kv in sys.argv[2:]:
        k, _, v = kv.partition("=")
        meta[k] = v

    row = {c: "" for c in COLS}
    for jf, col in FROM_JSON.items():
        if jf in d:
            row[col] = d[jf]
    row["ratio"] = f"{d.get('ratio_set', '?')}:{d.get('ratio_get', '?')}"
    row["test_time"] = round(float(d.get("duration_sec", 0)), 1)
    row["client"] = meta.get("client", "go-redis")

    row.update({k: v for k, v in meta.items() if k in COLS})

    cores = float(row.get("cores_used") or 0)
    if cores and row["ops_per_sec"]:
        row["ops_per_core"] = round(float(row["ops_per_sec"]) / cores, 2)
    # payload bytes * ops/s -> KB/s (approximate, value payload only)
    if row["ops_per_sec"] and d.get("payload"):
        row["kb_per_sec"] = round(float(row["ops_per_sec"]) * d["payload"] / 1024, 2)

    new = not os.path.exists(RUNS)
    with open(RUNS, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=COLS)
        if new:
            w.writeheader()
        w.writerow(row)
    print(f"recorded {row['client']}/{row['arm']} workers={row['workers']} "
          f"inflight={row['inflight']} -> {int(float(row['ops_per_sec'])):,} ops/s, "
          f"p50={row['p50_ms']}ms errors={row['errors']}")


if __name__ == "__main__":
    main()
