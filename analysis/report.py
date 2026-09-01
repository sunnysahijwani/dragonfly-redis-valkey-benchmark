#!/usr/bin/env python3
"""Markdown comparison table from results/runs.csv, engines side by side per
workload. Median across reps. Throughput-per-node is the headline; hit_rate is
shown so a reader can see GETs actually hit.

    report.py [run_id]     # default: the most recent run_id in the file
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

# (ratio,data,pipeline) -> label -> list of rows (reps)
groups = defaultdict(lambda: defaultdict(list))
for r in rows:
    groups[(r["ratio"], r["data_bytes"], r["pipeline"])][f'{r["engine"]}-{r["mode"]}'].append(r)

labels = sorted({f'{r["engine"]}-{r["mode"]}' for r in rows})


def med(vs):
    vs = [float(v) for v in vs if v not in ("", None)]
    return statistics.median(vs) if vs else 0.0


print(f"# Results — run {run_id} ({len(rows)} runs)\n")
print("Headline = throughput-per-node (median ops/sec). "
      "hit_rate should be ~1.0 (GETs hitting real data).\n")
print("| workload (SET:GET, bytes, pipe) | " + " | ".join(labels) + " |")
print("|" + "---|" * (len(labels) + 1))
for k in sorted(groups):
    ratio, data, pipe = k
    cells = []
    for lb in labels:
        reps = groups[k].get(lb)
        if not reps:
            cells.append("—"); continue
        ops = med([x["ops_per_sec"] for x in reps])
        p50 = med([x["p50_ms"] for x in reps])
        p99 = med([x["p99_ms"] for x in reps])
        hr = med([x["hit_rate"] for x in reps])
        cells.append(f"{int(ops):,} ops/s<br>p50 {p50:g}/p99 {p99:g} · hit {hr:g}")
    print(f"| {ratio}, {data}B, p{pipe} | " + " | ".join(cells) + " |")

print("\n## Throughput winner per workload (with margin)\n")
for k in sorted(groups):
    scored = sorted(((med([x["ops_per_sec"] for x in v]), lb)
                     for lb, v in groups[k].items()), reverse=True)
    if not scored:
        continue
    top, second = scored[0], (scored[1] if len(scored) > 1 else (0, "—"))
    margin = (top[0] / second[0] - 1) * 100 if second[0] else 0
    print(f"- {k[0]}, {k[1]}B, p{k[2]}: **{top[1]}** "
          f"({int(top[0]):,} ops/s, +{margin:.0f}% vs {second[1]})")
