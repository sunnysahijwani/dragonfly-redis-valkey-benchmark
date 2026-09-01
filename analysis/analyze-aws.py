#!/usr/bin/env python3
"""Full analysis of the AWS capture (results/runs-aws.csv) -> all the views the
blog series needs. Read-only; prints markdown-ish tables."""
import csv, statistics
from collections import defaultdict

ROWS = [r for r in csv.DictReader(open("results/runs-aws.csv"))]
CORES = [4, 8, 16, 24, 48]
SERIES = ["dragonfly-single", "redis-cluster", "redis-cluster-sat",
          "valkey-cluster", "valkey-cluster-sat"]
NICE = {"dragonfly-single": "Dragonfly", "redis-cluster": "Redis (realistic)",
        "redis-cluster-sat": "Redis (ceiling)", "valkey-cluster": "Valkey (realistic)",
        "valkey-cluster-sat": "Valkey (ceiling)"}


def med(vs):
    vs = [float(v) for v in vs if v not in ("", None)]
    return statistics.median(vs) if vs else 0.0


def sel(ratio, data, pipe):
    return [r for r in ROWS if r["ratio"] == ratio and r["data_bytes"] == data and r["pipeline"] == pipe]


def curve(rows):
    by = defaultdict(lambda: defaultdict(list))
    for r in rows:
        by[f'{r["engine"]}-{r["mode"]}'][int(r["cores_used"])].append(float(r["ops_per_sec"]))
    return by


def show_curve(title, ratio, data, pipe, metric="ops"):
    print(f"\n### {title}  (SET:GET {ratio}, {data}B, pipeline {pipe}) — Mops/s by cores")
    by = curve(sel(ratio, data, pipe))
    print("| series | " + " | ".join(f"{c}c" for c in CORES) + " |")
    print("|" + "---|" * (len(CORES) + 1))
    for s in SERIES:
        d = by.get(s, {})
        print(f"| {NICE[s]} | " + " | ".join(f"{med(d.get(c, [0]))/1e6:.1f}" for c in CORES) + " |")


print("# Dragonfly vs Redis vs Valkey — AWS capture analysis")
print(f"\nc7i.metal-24xl (48 physical cores, Sapphire Rapids), client c7i.24xlarge, us-east-1.")
print(f"Rows: {len(ROWS)}. Redis 8.2.8 / Valkey 8.1.9 / Dragonfly v1.40.1, io_uring, pipelined.")

# 1. Scaling curves
show_curve("SCALING — read-heavy pipelined", "1:10", "100", "16")
show_curve("SCALING — mixed pipelined", "1:1", "100", "16")
show_curve("SCALING — read-heavy, NO pipeline", "1:10", "100", "1")
show_curve("SCALING — read-heavy, 1KB values", "1:10", "1024", "16")

# 2. 48-core cross-workload (Dragonfly vs realistic vs ceiling)
print("\n### 48-CORE throughput per node (Mops/s) across workloads")
print("| workload | DF | Redis real | Redis ceil | Valkey real | Valkey ceil |")
print("|---|---|---|---|---|---|")
for ratio in ["1:10", "1:1"]:
    for data in ["100", "1024"]:
        for pipe in ["1", "16"]:
            by = curve(sel(ratio, data, pipe))
            def at48(s): return med(by.get(s, {}).get(48, [0])) / 1e6
            print(f"| {ratio}, {data}B, p{pipe} | {at48('dragonfly-single'):.1f} | "
                  f"{at48('redis-cluster'):.1f} | {at48('redis-cluster-sat'):.1f} | "
                  f"{at48('valkey-cluster'):.1f} | {at48('valkey-cluster-sat'):.1f} |")

# 3. Latency at 48c, hero workload
print("\n### LATENCY at 48 cores — read-heavy pipelined (ms)")
print("| series | p50 | p99 | p99.9 |")
print("|---|---|---|---|")
for s in SERIES:
    rs = [r for r in sel("1:10", "100", "16") if f'{r["engine"]}-{r["mode"]}' == s and int(r["cores_used"]) == 48]
    if rs:
        print(f"| {NICE[s]} | {med([r['p50_ms'] for r in rs]):g} | {med([r['p99_ms'] for r in rs]):g} | {med([r['p999_ms'] for r in rs]):g} |")

# 4. Multi-key (Dragonfly only; cluster = CROSSSLOT)
print("\n### MULTI-KEY (Dragonfly single; Redis/Valkey cluster reject cross-slot) — Mops/s by cores")
for lbl, ratio in [("MGET(10)", "mget10"), ("MSET(10)", "mset10")]:
    by = curve([r for r in ROWS if r["ratio"] == ratio and r["data_bytes"] == "100" and r["pipeline"] == "16"])
    d = by.get("dragonfly-single", {})
    print(f"- {lbl}, p16: " + " ".join(f"{c}c={med(d.get(c,[0]))/1e6:.1f}M" for c in CORES))

# 5. Key synthesis numbers
print("\n### HEADLINE NUMBERS (read-heavy pipelined, 48 cores)")
by = curve(sel("1:10", "100", "16"))
df = med(by["dragonfly-single"].get(48, [0]))
rr = med(by["redis-cluster"].get(48, [0]))
rc = med(by["redis-cluster-sat"].get(48, [0]))
print(f"- Dragonfly: {df/1e6:.1f}M | Redis realistic: {rr/1e6:.1f}M | Redis ceiling: {rc/1e6:.1f}M")
print(f"- Dragonfly vs realistic cluster: **{df/rr:.1f}x**")
print(f"- Dragonfly as fraction of the raw ceiling: **{df/rc*100:.0f}%** (for ~zero client effort)")
print(f"- Ceiling vs Dragonfly: {rc/df:.1f}x (only with optimal per-shard routing + huge client)")
# crossover: where DF overtakes realistic cluster
for c in CORES:
    if med(by["dragonfly-single"].get(c, [0])) > med(by["redis-cluster"].get(c, [0])):
        print(f"- Dragonfly overtakes the realistic cluster at ~{c} cores")
        break
