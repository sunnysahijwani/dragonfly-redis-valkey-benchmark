# Phase B Runbook — AWS bare-metal capture

The Mac dress rehearsal validated the harness. Phase B produces the **publishable
throughput, latency, and core-scaling numbers** on real hardware. Follow this
top to bottom; every step is ordered and mostly copy-paste.

---

## 0. Topology & why two instances

```
  ┌─────────────────────────┐         private VPC network         ┌──────────────────────────┐
  │  SERVER (engine)         │  <──────  same AZ, 25+ Gbps  ─────> │  CLIENT (load generator) │
  │  c7i.metal-24xl          │                                     │  c7i.24xlarge            │
  │  48 REAL cores, no HV     │                                     │  96 vCPU (drives memtier)│
  └─────────────────────────┘                                     └──────────────────────────┘
```

**Why two boxes, not one:** at the top of the scaling sweep the engine uses **all
48 cores**, so there are none left to run the client on the same box. Two
instances also give full CPU + memory-bandwidth separation (Oded's note #3), so
the client can never steal the server's resources. `ramp.sh` will *prove* the
client isn't the bottleneck.

- **Server:** `c7i.metal-24xl` — 48 physical cores, bare metal (the thing under test).
- **Client:** `c7i.24xlarge` — 96 vCPU, virtualized is fine (client doesn't need bare metal).
- Both in the **same AZ**, same **cluster placement group**, ENA enabled.
- **Estimated cost:** ~$4.3/hr each ≈ **$8.6/hr**; a thorough 4–6 hr session ≈ **$35–50**, then terminate.

---

## 1. Pre-flight (do this a DAY before — quota approval takes hours)

0. **Account + credits (per AWS support, Aug 2026):** up to **$200** promo credits go to a
   *genuinely new* customer (eligibility auto-checked at signup — a new email alone won't qualify
   if the same card/identity used AWS before; no credit-farming). Credits cover **all services incl
   EC2 on-demand + `.metal` + EBS + data transfer, all regions**. **Choose the Paid Plan** — the Free
   Plan *auto-closes the account* when credits deplete (could strand a mid-run benchmark); Paid Plan
   just falls back to on-demand rates. Our run ≈ $35–50 ≪ $200, so credits (if granted) cover it;
   if not granted, out-of-pocket ≈ $40. Confirm the credit balance in Billing before spending.
1. **vCPU quota.** New accounts cap at ~5–32 vCPU. You need **96 (server) + 96 (client) ≈ 192 vCPU**.
   Service Quotas console → EC2 → *"Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances"*
   → Request quota increase → **224** (us-east-1). Also search **metal**-specific quotas and request
   whatever `c7i.metal-24xl` needs. Approval can take hours–a day → do this FIRST.
2. **Budget alarm** at ~$50 (Billing → Budgets → cost budget = your credit/spend cap, email alert).
   Use **On-Demand**, never Spot (Spot can be reclaimed mid-run).
3. **SSH keypair** created and downloaded.

---

## 2. Provision

1. **Placement group:** EC2 → Placement Groups → create, strategy **cluster**.
2. **Security group** (call it `bench-sg`):
   - Inbound SSH (22) from **your IP only**.
   - Inbound **All traffic** where source = `bench-sg` itself (lets the two instances talk on every port: 6379 + 7001–70xx).
3. **Launch SERVER:** `c7i.metal-24xl`, Amazon Linux 2023 (or Ubuntu 24.04), **100 GB gp3** EBS,
   the cluster placement group, `bench-sg`, your keypair. Enable ENA (default on c7i).
4. **Launch CLIENT:** `c7i.24xlarge`, same AMI/AZ/placement group/SG/key.
5. Note both **private IPv4** addresses:
   ```
   SERVER_PRIVATE_IP=10.x.x.x
   CLIENT_PRIVATE_IP=10.x.x.y
   ```

---

## 3. Setup — run on BOTH boxes

```bash
# Amazon Linux 2023:
sudo dnf -y install docker git python3 && sudo systemctl enable --now docker
sudo usermod -aG docker $USER && newgrp docker      # re-login if needed
# (Ubuntu: sudo apt-get update && sudo apt-get -y install docker.io git python3)

# Get the harness (git clone your repo, or scp the folder up):
git clone <your-repo-url> dragonfly-benchmark && cd dragonfly-benchmark
```

**Host tuning on the SERVER box** (consistent, representative perf):
```bash
# disable transparent hugepages (Redis/Valkey/DF all recommend this)
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
sudo sysctl -w vm.overcommit_memory=1
sudo sysctl -w net.core.somaxconn=1024
ulimit -n 1048576        # file descriptors for many connections
```

**Pre-pull the pinned images by digest** (server needs the engines; client needs memtier):
```bash
# on SERVER:
docker pull redis:8.2@sha256:2f7462b9e93e0a7ae2edf3a0a0babc8a4d29f8bfc50849b906b7caaef925edc1
docker pull valkey/valkey:8.1@sha256:495e4fecdc98ee48a20b207726caa5ab6451e0fac3642a9be10d9e70b3068df6
docker pull ghcr.io/dragonflydb/dragonfly:latest@sha256:ebf3c6c213e82fb51b4521660cca13f06f3421dc5b1ed14f2f474c50b5e29986
# on CLIENT:
docker pull redislabs/memtier_benchmark:latest@sha256:5f15b74f657fd30ee73453af9caa1781de1614f4d934d46feee711dc19b758af
```

---

## 4. ✅ Two-box mode (`HOST_NET`) — already built

`HOST_NET=1` is implemented and locally validated (single-node + cluster):
- **`up.sh` / `up-cluster.sh`** use `--network host`; clusters advertise
  `--cluster-announce-ip $ANNOUNCE_IP` so a remote client reaches every shard,
  and wait for `cluster_state:ok` before anyone loads data.
- **`bench.sh` / `ramp.sh` / `populate.sh`** run memtier on the host stack, targeting a given IP.

**Orchestration = two SSH sessions (engine on SERVER, load from CLIENT):**
```
# --- SERVER session: bring the engine up (stays running) ---
HOST_NET=1 ANNOUNCE_IP=$SERVER_PRIVATE_IP SERVER_CPUS=$SERVER_CPUS SERVER_THREADS=48 \
  bash scripts/up.sh dragonfly              # or: up-cluster.sh redis 48

# --- CLIENT session: drive load against the server's private IP ---
HOST_NET=1 REPS=3 MULTIKEY=1 ... bash scripts/bench.sh dragonfly single $SERVER_PRIVATE_IP 6379 0

# --- SERVER session: tear down before the next engine/level ---
bash scripts/down.sh
```
> `run-phase-a.sh` co-locates up+bench+down on ONE box — use it only for the
> single-box/loopback fallback (Appendix), NOT two-box. On the day, smoke-test the
> cluster path once on the real boxes (cross-host gossip); single-node is already proven.
> The residual sub-1% miss seen locally is Docker-Desktop-on-Mac host-net noise; on
> real Linux `--network host` is native and clean.

---

## 5. Identify physical cores (SERVER box)

```bash
lscpu -e            # shows CPU <-> CORE <-> NODE, and hyperthread siblings
lscpu | grep -i numa
```
- Pick **physical cores on ONE NUMA node** (avoid HT siblings) for the engine.
- **Dragonfly gets the LOW cores** (Oded #3). Example for a 48-core / 2-NUMA box, using node 0:
  ```bash
  export SERVER_CPUS="0-23"     # adjust to the real physical-core list from lscpu -e
  ```
- The **client** cores live on the client box, so `CLIENT_CPUS` there just spans its vCPUs.

---

## 6. Prove the client is NOT the bottleneck (ramp) — DO THIS FIRST

```bash
# SERVER: bring up one engine at full cores
HOST_NET=1 SERVER_CPUS="$SERVER_CPUS" SERVER_THREADS=48 bash scripts/up.sh dragonfly

# CLIENT: ramp the load, watch the verdict column
HOST_NET=1 CONNS_LADDER="10 25 50 100 200 400" RAMP_TIME=15 \
  bash scripts/ramp.sh $SERVER_PRIVATE_IP 6379 0
```
- Read the plateau row. It **must say `server-bound`** (server CPU ~maxed, client headroom).
- If it says `client-bound`, the client is the ceiling → use a bigger client instance or add a second client. **Do not proceed until server-bound.**

---

## 7. Find the fair cluster layout (shard-sweep)

```bash
# SERVER + CLIENT coordinated; sweep shard counts at the target core budget
HOST_NET=1 SERVER_CPUS="$SERVER_CPUS" SHARD_LADDER="8 12 16 24 48" \
  bash scripts/shard-sweep.sh redis
HOST_NET=1 SERVER_CPUS="$SERVER_CPUS" SHARD_LADDER="8 12 16 24 48" \
  bash scripts/shard-sweep.sh valkey
```
- Record the **winning `SHARDS`** per engine — that's the fair per-node cluster config for the headline.

---

## 8. Core-scaling sweep (the headline capture)

Loop the server core budget; client fixed and over-provisioned. Use the best
`SHARDS` from step 7 at each level. For each core level, repeat the SERVER-up →
CLIENT-bench → SERVER-down cycle for the three peers (dragonfly single, redis
cluster, valkey cluster). Common client-side settings:
```
CLIENT_ENV="HOST_NET=1 REPS=3 MULTIKEY=1 TEST_TIME=30 KEY_MAX=5000000 \
  RATIOS='1:10 1:1' DATA_SIZES='100 1024' PIPELINES='1 16' RUN_NOTE=scale-${CORES}c"
```
Per core level `CORES` in `4 8 16 24 48`, with `SERVER_CPUS` = the real physical
cores from `lscpu -e`:
```bash
# DRAGONFLY (single process)
#   SERVER: HOST_NET=1 SERVER_CPUS=$CPUS SERVER_THREADS=$CORES bash scripts/up.sh dragonfly
#   CLIENT: $CLIENT_ENV bash scripts/bench.sh dragonfly single $SERVER_PRIVATE_IP 6379 0
#   SERVER: bash scripts/down.sh
# REDIS CLUSTER (best shard count from step 7)
#   SERVER: HOST_NET=1 ANNOUNCE_IP=$SERVER_PRIVATE_IP SERVER_CPUS=$CPUS SHARDS=$CORES bash scripts/up-cluster.sh redis $CORES
#   CLIENT: $CLIENT_ENV SHARDS=$CORES bash scripts/bench.sh redis cluster $SERVER_PRIVATE_IP 7001 1
#   SERVER: bash scripts/down.sh
# VALKEY CLUSTER — same as redis, swap the engine name.
```
- Produces the DF-single vs Redis/Valkey-cluster curve from 4→48 cores, with reps + multi-key.
- Everything appends to the CLIENT's `results/runs.csv`, tagged `note=scale-Nc`.
- 💡 **Fully automated (recommended): `scripts/run-2box.sh`.** Run it ON THE CLIENT; it SSHes to
  the server to up/down each engine and drives the load locally — the whole sweep in one command:
  ```bash
  # one-time: passwordless SSH client->server (ssh-keygen; copy .pub to server authorized_keys)
  SERVER_SSH=ec2-user@$SERVER_PRIVATE_IP SERVER_PRIVATE_IP=$SERVER_PRIVATE_IP \
    SCALE="4 8 16 24 48" REPS=3 MULTIKEY=1 TEST_TIME=30 KEY_MAX=5000000 \
    RATIOS="1:10 1:1" DATA_SIZES="100 1024" PIPELINES="1 16" \
    bash scripts/run-2box.sh sweep
  ```
  Preview first with `DRY_RUN=1` to see every server/client command without executing. ⚠️ In sweep
  mode `SERVER_CPUS` is derived as `0-(n-1)`; if `lscpu -e` shows non-contiguous physical cores,
  run levels individually with an explicit `SERVER_CPUS`.

---

## 9. Re-confirm the hardware-independent results

```bash
HOST_NET=1 bash scripts/crossslot.sh          # should match the Mac exactly
HOST_NET=1 bash scripts/memory.sh 5000000 100  # bytes/key at scale
```
(These should reproduce the Mac findings; capturing them on real HW closes any "but you were on a laptop" objection.)

---

## 10. Collect & report

```bash
python3 analysis/report.py <run_id>          # per-run comparison table
python3 analysis/report_sweep.py <sweep_id>  # shard-sweep table
# pull results back to your Mac:
scp -i <key> ec2-user@<SERVER_PUBLIC_IP>:~/dragonfly-benchmark/results/runs.csv ./results/
```
- `runs.csv` is the single source of truth — every row self-describes its config.
- Charts for the blog: plot ops/sec vs cores per engine from `runs.csv` (add a small matplotlib step, or import into a sheet).

---

## 11. Teardown (don't skip — this is where money leaks)

```bash
# from your laptop, or the console:
aws ec2 terminate-instances --instance-ids <server-id> <client-id>
```
- Confirm both **terminated**, delete the **placement group**, check no orphaned **EBS volumes / Elastic IPs**.
- Verify the **billing dashboard** shows the run and nothing lingering.

---

## 12. One-glance checklist

- [ ] vCPU quota approved (~224) + credits confirmed + billing alarm set
- [ ] Two instances up, same AZ/placement group, SG allows intra-group traffic
- [ ] Docker + harness + pinned images on both boxes; THP off on server
- [ ] `HOST_NET` two-box path built + smoke-tested (single-node then cluster)
- [ ] `lscpu -e` → SERVER_CPUS = real physical cores, DF on low cores
- [ ] `ramp.sh` shows **server-bound** (client proven not the ceiling)
- [ ] `shard-sweep` winner recorded
- [ ] core-scaling sweep 4→48 with REPS=3 MULTIKEY=1 captured
- [ ] cross-slot + memory re-confirmed on real HW
- [ ] `runs.csv` pulled back
- [ ] **instances terminated + billing verified**

---

## Appendix — single-box fallback (cheaper, one instance)

If you'd rather run one box: engine + memtier on the same `c7i.metal-24xl`, pinned
to **disjoint physical cores** (`--network host`, memtier → `127.0.0.1`). On bare
metal, pinning is real, so CPU separation holds. Caveats to disclose honestly:
loopback (no real NIC path) and shared memory bandwidth. Works only where you can
spare cores for the client — so it can't do the *top* of the scaling sweep (48
server cores leaves none for the client). Fine for a cheaper first pass; two boxes
is the headline.
