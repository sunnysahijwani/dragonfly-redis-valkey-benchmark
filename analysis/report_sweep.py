#!/usr/bin/env python3
"""Shard-sweep view: for a run_id, show ops/sec by shard count per workload,
and pick the BEST shard count for each workload.

    report_sweep.py [run_id]     # default: most recent
"""
import csv, os, sys, statistics
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CSV = os.path.join(ROOT, "results", "runs.csv")

rows = list(csv.DictReader(open(CSV)))
if not rows:
    print("no runs recorded yet"); sys.exit(0)
run_id = sys.argv[1] if len(sys.argv) > 1 else max(r["run_id"] for r in rows)
rows = [r for r in rows if r["run_id"] == run_id]

shard_vals = sorted({int(r["shards"]) for r in rows})
# (ratio,data,pipeline) -> shards -> [ops...]
g = defaultdict(lambda: defaultdict(list))
for r in rows:
    g[(r["ratio"], r["data_bytes"], r["pipeline"])][int(r["shards"])].append(float(r["ops_per_sec"]))

print(f"# Shard sweep — run {run_id}  (shards tried: {shard_vals})\n")
print("| workload (SET:GET, bytes, pipe) | " + " | ".join(f"{s} shards" for s in shard_vals) + " | best |")
print("|" + "---|" * (len(shard_vals) + 2))
for k in sorted(g):
    cells, best_ops, best_s = [], -1, None
    for s in shard_vals:
        ops = statistics.median(g[k][s]) if g[k].get(s) else 0
        cells.append(f"{int(ops):,}" if ops else "—")
        if ops > best_ops:
            best_ops, best_s = ops, s
    print(f"| {k[0]}, {k[1]}B, p{k[2]} | " + " | ".join(cells) + f" | **{best_s} shards** |")

print("\nUse the winning shard count as the fair per-node Redis/Valkey config in the writeup.")
