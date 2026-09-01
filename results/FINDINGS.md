# Dragonfly vs Redis vs Valkey — AWS capture analysis

c7i.metal-24xl (48 physical cores, Sapphire Rapids), client c7i.24xlarge, us-east-1.
Rows: 350. Redis 8.2.8 / Valkey 8.1.9 / Dragonfly v1.40.1, io_uring, pipelined.

### SCALING — read-heavy pipelined  (SET:GET 1:10, 100B, pipeline 16) — Mops/s by cores
| series | 4c | 8c | 16c | 24c | 48c |
|---|---|---|---|---|---|
| Dragonfly | 2.0 | 3.7 | 6.5 | 9.0 | 15.5 |
| Redis (realistic) | 3.2 | 5.0 | 5.0 | 4.8 | 4.6 |
| Redis (ceiling) | 5.2 | 9.2 | 15.8 | 22.5 | 40.6 |
| Valkey (realistic) | 3.1 | 4.9 | 4.9 | 4.8 | 4.5 |
| Valkey (ceiling) | 5.0 | 8.8 | 15.2 | 21.7 | 40.2 |

### SCALING — mixed pipelined  (SET:GET 1:1, 100B, pipeline 16) — Mops/s by cores
| series | 4c | 8c | 16c | 24c | 48c |
|---|---|---|---|---|---|
| Dragonfly | 2.1 | 3.7 | 6.6 | 9.2 | 15.5 |
| Redis (realistic) | 3.1 | 5.0 | 4.8 | 4.9 | 4.5 |
| Redis (ceiling) | 4.8 | 8.7 | 15.0 | 21.3 | 39.6 |
| Valkey (realistic) | 3.0 | 4.9 | 4.9 | 4.7 | 4.4 |
| Valkey (ceiling) | 4.8 | 8.5 | 14.7 | 21.1 | 39.4 |

### SCALING — read-heavy, NO pipeline  (SET:GET 1:10, 100B, pipeline 1) — Mops/s by cores
| series | 4c | 8c | 16c | 24c | 48c |
|---|---|---|---|---|---|
| Dragonfly | 0.6 | 1.2 | 2.3 | 2.8 | 2.8 |
| Redis (realistic) | 0.7 | 1.3 | 1.5 | 1.5 | 1.4 |
| Redis (ceiling) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| Valkey (realistic) | 0.7 | 1.3 | 1.5 | 1.5 | 1.5 |
| Valkey (ceiling) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |

### SCALING — read-heavy, 1KB values  (SET:GET 1:10, 1024B, pipeline 16) — Mops/s by cores
| series | 4c | 8c | 16c | 24c | 48c |
|---|---|---|---|---|---|
| Dragonfly | 1.0 | 1.8 | 3.4 | 4.8 | 4.8 |
| Redis (realistic) | 2.0 | 3.0 | 3.8 | 3.7 | 3.7 |
| Redis (ceiling) | 2.8 | 5.0 | 5.5 | 6.0 | 7.7 |
| Valkey (realistic) | 1.9 | 3.0 | 3.9 | 3.8 | 3.6 |
| Valkey (ceiling) | 2.7 | 5.0 | 5.5 | 5.9 | 7.6 |

### 48-CORE throughput per node (Mops/s) across workloads
| workload | DF | Redis real | Redis ceil | Valkey real | Valkey ceil |
|---|---|---|---|---|---|
| 1:10, 100B, p1 | 2.8 | 1.4 | 0.0 | 1.5 | 0.0 |
| 1:10, 100B, p16 | 15.5 | 4.6 | 40.6 | 4.5 | 40.2 |
| 1:10, 1024B, p1 | 2.8 | 1.4 | 0.0 | 1.4 | 0.0 |
| 1:10, 1024B, p16 | 4.8 | 3.7 | 7.7 | 3.6 | 7.6 |
| 1:1, 100B, p1 | 2.7 | 1.3 | 0.0 | 1.2 | 0.0 |
| 1:1, 100B, p16 | 15.5 | 4.5 | 39.6 | 4.4 | 39.4 |
| 1:1, 1024B, p1 | 2.8 | 1.2 | 0.0 | 1.2 | 0.0 |
| 1:1, 1024B, p16 | 8.3 | 3.7 | 0.0 | 3.6 | 0.0 |

### LATENCY at 48 cores — read-heavy pipelined (ms)
| series | p50 | p99 | p99.9 |
|---|---|---|---|
| Dragonfly | 0.883 | 2.423 | 3.327 |
| Redis (realistic) | 83.967 | 138.239 | 150.527 |
| Redis (ceiling) | 0.559 | 1.511 | 4.639 |
| Valkey (realistic) | 85.759 | 140.799 | 157.695 |
| Valkey (ceiling) | 0.567 | 1.319 | 3.503 |

### MULTI-KEY (Dragonfly single; Redis/Valkey cluster reject cross-slot) — Mops/s by cores
- MGET(10), p16: 4c=0.3M 8c=0.5M 16c=0.9M 24c=1.3M 48c=2.4M
- MSET(10), p16: 4c=0.2M 8c=0.4M 16c=0.7M 24c=1.1M 48c=1.3M

### HEADLINE NUMBERS (read-heavy pipelined, 48 cores)
- Dragonfly: 15.5M | Redis realistic: 4.6M | Redis ceiling: 40.6M
- Dragonfly vs realistic cluster: **3.4x**
- Dragonfly as fraction of the raw ceiling: **38%** (for ~zero client effort)
- Ceiling vs Dragonfly: 2.6x (only with optimal per-shard routing + huge client)
- Dragonfly overtakes the realistic cluster at ~16 cores
