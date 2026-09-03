# Dragonfly vs Redis vs Valkey — a fair, reproducible benchmark

A methodology-first throughput/latency/memory benchmark of **Dragonfly**, **Redis**,
and **Valkey** on **48 real bare-metal cores** — with the harness, pinned versions,
and raw data so you can rerun and challenge every number.

📖 **Full write-up (7-part series):** https://two-techies.com/blog/dragonfly-vs-redis-valkey-benchmark

![Throughput vs cores: Dragonfly climbs smoothly to 15.5M, a realistic Redis cluster plateaus at ~5M, the fully-driven cluster ceiling scales to 40M](images/02-scaling.png)

## The headline (48 cores, read-heavy, pipelined)

| Configuration | Throughput |
|---|---|
| Redis Cluster — **fully driven** (per-shard routing) | **40.6M ops/s** (raw ceiling) |
| **Dragonfly** — single process | **15.5M ops/s** |
| Redis Cluster — **realistic** (a normal client) | **4.6M ops/s** |

All three are real. Redis's *raw* ceiling is higher, but you only reach it with
flawless client-side routing and a client as big as the server. Dragonfly gives
you **3.4× a realistic cluster** for near-zero operational effort. It's a trade-off
between **raw throughput and operational simplicity** — quantified.

## TL;DR findings

- **Scaling:** Dragonfly scales smoothly 2M→15.5M; a *realistic* cluster plateaus ~5M
  (more shards don't help a normal client); the driven *ceiling* scales to ~40M.
- **The cluster-driving problem:** a single cluster-mode client under-reports a
  cluster by ~9× (shards sit ~16% idle) — so we report the cluster **two ways**.
- **Latency:** Dragonfly sub-ms; a well-driven cluster sub-ms too; a naive cluster
  client balloons to ~84ms p50 (client-side queuing).
- **Multi-key** (MGET/MSET across the keyspace): Dragonfly does it; clusters can't
  (CROSSSLOT) without hash-tag co-location.
- **Memory:** Dragonfly ~13% leaner (146 vs 165/169 bytes/key).

## What makes it fair

- **Three configurations, not two:** single-DF vs Redis/Valkey **cluster** (single
  Redis is one thread — you must cluster to use all cores). The cluster is reported
  both **realistic** and **fully-driven**.
- Client on a **separate, over-provisioned box**; every run proven **server-bound**.
- Keyspace **pre-populated** (reads hit real data, `hit_rate ≈ 1.0`).
- Each engine on its **own best I/O path** (Dragonfly `io_uring`, Redis/Valkey `epoll`).
- Images **pinned by digest**; every knob recorded per row.
- Full methodology (including a bias caught in our own setup): see the blog series.

## Setup

- **Server:** AWS `c7i.metal-24xl` — bare metal, Intel Xeon 8488C (Sapphire Rapids),
  48 physical cores, single NUMA, 192 GB. **Client:** `c7i.24xlarge`. us-east-1, same AZ + placement group.
- **Versions:** Redis 8.2.8 · Valkey 8.1.9 · Dragonfly v1.40.1 · memtier_benchmark 2.5.1.

## Reproduce it

```bash
# 1. edit config.env (versions, cores, workload matrix)
# 2. single-box quick run (laptop/one box; Docker required):
bash scripts/run-phase-a.sh
# 3. two-box run (server + client, bare metal): see PHASE-B-RUNBOOK.md
# 4. the fully-driven cluster ceiling:
bash scripts/cluster-saturate.sh redis <server-ip> 7001 <shards>
# 5. regenerate the analysis tables from the raw data:
python3 analysis/analyze-aws.py     # tables -> results/FINDINGS.md
#    (the charts in images/ are pre-rendered; every number is re-derivable here)
```

## Repo layout

```
config.env             all knobs (pinned image digests, cores, workload matrix)
scripts/               the harness (up / bench / cluster-saturate / ramp / run-2box …)
analysis/              parse + report tables from runs.csv
results/
  runs-aws.csv         the raw capture (350 runs) — re-derive everything from this
  FINDINGS.md          analysis tables
  memory-aws.txt       bytes/key
  crossslot-aws.txt    the cross-slot operational demo
PHASE-B-RUNBOOK.md     exact AWS two-box setup
images/                the result charts (PNG)
```

## Credits & license

Benchmarking notes from **the DragonflyDB team** helped shape the approach. Harness released under the **MIT License**.
Rerun it, break it, tell me where I'm wrong — that's the point.
