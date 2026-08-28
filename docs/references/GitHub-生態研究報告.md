# DGX Spark (GB10) Monitoring Ecosystem — Research Report
**Goal:** inform design of our own HTTP status API for DGX Spark nodes.
Research method: GitHub Search API + raw README of verified repos. No clones/installs.

---

## 1. Repo Table → data sources → metrics → transport

| Repo (stars) | Data sources | Metrics / fields | Output transport |
|---|---|---|---|
| **MiaAI-Lab/sparkDash** (298) | Local: sysfs, `/proc`, `nvidia-smi`, `nvidia-smi dmon` (mem bw); Remote: over SSH. LLM via HTTP Prometheus `/metrics` probe. `tailscale status --json`. `smtp/ssh` | GPU util/temp/power/mem, **unified mem bw (dmon)**, CPU, RAM, storage, network /s, vLLM KV-cache%, run/wait queue, TTFT/E2E/ITL p95, decode/prefill tok/s, GPU processes, uptime, ComfyUI queue, Hermes update status | **WebSocket** `/ws` snapshot + REST `/api/sparks/:id/metrics`. No auth |
| **wentbackward/nv-monitor** (314) | NVML (dynamic load), `/proc/stat`, `/proc/meminfo`, `/sys/class/thermal`, `/sys/class/infiniband`, sysfs cpufreq, HugePages-aware meminfo | CPU per-core (X925/X725 labels), RAM used/bufcache, GPU util/temp/power/clock/mem/ENC-DEC, **unified mem handling**, per-disk, per-core freq; RDMA ports | TUI + **Prometheus/OpenMetrics** on `-p :9101`, **optional Bearer token** (`-t`/env). CSV export, headless |
| **niklasfrick/spark-dashboard** (105) | NVML, sysinfo, procfs; cgroup/Docker socket for **vLLM engine discovery**; vLLM **Prometheus `/metrics`** | GPU util/temp/power/clocks/fan + throttle events (thermal/hw-slowdown/power-brake), CPU/core heatmap, RAM+VRAM or **unified pool**, disk/network I/O, vLLM tok/s (gen+prompt), TTFT/ITL/E2E/queue, KV-cache%, prefix-cache hit, SLO goodput; multi-engine tabs | **WebSocket JSON** broadcast channel → React. `/api/dashboard` config doc (opaque bytes). No nginx auth |
| **metaspartan/sparktop** (6, most complete op-engineering) | Agentless over SSH: **single batched shell script per poll** w/ ASCII record separators. sysfs, `nvidia-smi`, `ethtool -S` (RDMA vports), `/sys/class/infiniband` (4-byte words), `docker stats`, DMI | Full cluster: GPU util, **unified mem (total=sys pool, used=Σ NVML proc allocs)**, per-core CPU, all thermals, disks, containers, **fabric RDMA per-link (tx/rx Gbps, pairing by subnet+traffic corroboration)**, vLLM decode/prefill/TTFT/queue/KV-cache/prefix/speculative; **silent low-clock (USB-C PD) detection** | **REST `/api/health`,`/api/snapshot`,`/api/history`,`/api/runs`** + **WS `/ws`** + Prometheus `/metrics` (cached projection). `SPARKTOP_TOKEN` bearer; read-only container |
| **tonyd2wild/The-Sparky-Command-Center** (36) | SSH per-node: `nvidia-smi --query-gpu`, hwmon temp scan, `free` (C locale). HTTP scrape of vLLM/llama.cpp **Prometheus `/metrics`** + `/v1/models`; RouterOS SSH for RoCE switch; ComfyUI `/system_stats`,`/queue` | GPU temp/power% of cap/util/VRAM/fan/clock, host temp+cpu, per-node RAM, decode/prefill tok/s, TTFT, KV-cache, running/waiting reqs, live per-request tok/s, cumulative token tracker (per-day buckets), Comfy VRAM/queue | **REST `/api/metrics` JSON snapshot** (browser polls) + `/api/tokens`,`/api/comfy`,`/healthz`. No deps (stdlib Python); per-node thread pollers → in-memory cache |
| **roninix/spark-mon** (1) | Agentless SSH: remote `python3 + psutil`, `nvidia-smi`, `lm-sensors` (SPBM power rails) | CPU, RAM, disk, GPU util/VRAM/temp/power/clocks, power rails; PM 1m/5m/15m. 48h SQLite history (WAL) | **REST `/api/v1/metrics`,`/history`,`/config`,`/health`**, typed JSON (Pydantic), optional **`X-API-Key`**. Offline nodes → `status:offline` not failure |
| **canberkys/sparkscope** (2) | SSH (asyncssh) single round-trip: `nvidia-smi --query` (GPU+ECC/throttle/PCIe/persistence), `/proc` CPU/mem, `nvme` SMART (60s), `lm-sensors`; vLLM Prometheus `/metrics`; `docker ps` auto-detect | GPU util/VRAM/temp/power/SM-mem clock + **ECC corrected/uncorrected**, throttle reasons; NVMe SMART temp/wear/media-errors; top processes; vLLM tok/s, active/queued, KV-cache, prefix hit | **WebSocket 2s push** from FastAPI; SQLite history + alert table (3-consecutive-sample threshold policy). Binds 127.0.0.1 |
| **chappa-ai-llc/spark-smi** (13) | NVML + `nvidia-smi --query` **per-field fallback**; sysfs `/sys/bus/pci`, `/sys/class/infiniband/*/hw_counters/` (RDMA, 4-byte words), spbm (`spark_hwmon`) power rails, smartctl | Full per-GPU (clocks/PCIe gen/throughput/power vs limit/throttle/ECC/NVENC-NVDEC), **unified mem (GB\d{2,3} → show sys RAM "(Unified)")**, RDMA CNP/ECN, PCIe link downtrain alerts (gen1-under-load), power/clock knobs, fabric validator | TUI + snapshot `--json` + **`--serve :8817` HTTP `/sample`,`/healthz`** (token via `X-Spark-Token`). Cluster: `host → :8817/sample` or `ssh:host spark-smi --json` |
| **parallelArchitect/sparkview** (28) | `nvitop`, `psutil`, `textual`; NVML; **`/proc/pressure/memory`** (PSI), `/proc/meminfo`, spbm hwmon; `/proc/stat` | GPU util/temp/power/mem; **UMA**: uses `vm.total - vm.available` (NVML reports ~121GB = MemTotal, wrong); PSI LOW/MOD/HIGH/CRIT; load-gated clock states IDLE/PASS/LOCKED/THROTTLED; GB10 power rails (gpu, dc_input, syspl1, PROCHOT, PL level); anomaly auto-logger (temp>80, throttled, PSI) | TUI (textual). Writes `summary.json` anomaly logs |
| **CINOAdam/nvml-unified-shim** (3) | `LD_PRELOAD` shim intercepting `nvmlDeviceGetMemoryInfo`; fallback to CUDA + **`/proc/meminfo`** | Returns `total=/proc/meminfo total`, `used=CUDA alloc`, `free=total-used` when NVML `NOT_SUPPORTED` | Library / env (not a server). Fixes tools that fail on NVML |
| **pgodlews/jetson-orin-exporter** (7) | **jetson-stats/jtop** daemon socket (unprivileged) | GPU %, freq, **unified mem used/free/total**, per-core CPU, temps by zone, power total + **per-rail**, fan rpm/%, engine freq (DLA/NVENC/NVDEC), EMC freq, disk, NV power model (nvpmodel), board info | **Prometheus** `:9101/metrics`; Grafana dashboard JSON |
| **ateska/dgx-spark-prometheus** (21) | `nvidia-smi --query-gpu`, `/proc/stat`, `/proc/meminfo`, `thermal_zone`, cpufreq sysfs, `/proc/diskstats`, `statfs`, `/sys/class/net/*/statistics` | CPU%/temp/freq, GPU util/temp/freq/power, mem, disk I/O + storage %, network bytes/packets (specific ifaces: enP7s7, enp1s0f1np1, enP2p1s0f1np1, etc.) | **Prometheus** `:9835/metrics`; Go binary + systemd |
| **mcampa/sparkrun-ui** (25) | Wraps `sparkrun` CLI (SSH to cluster). vLLM inference workloads, Ray; live per-host CPU/GPU/RAM (SSH via sparkrun) | Running workloads, recipes, YAML launch, logs, chat, benchmarks, per-host CPU/GPU/mem sparkline history | Web (Next.js). Cluster "what's running" source of truth = `sparkrun cluster status` (CLI) |
| **thx0701/dgx-spark-status** (21) | `systeminformation`, `nvidia-smi`, Docker for vLLM detect, Ollama API, llama.cpp (port 8001) | CPU/mem/GPU util/mem/temp/power, disk, network I/O, top procs, uptime; llama.cpp status/model, vLLM container status, Ollama model management | **SSE** `/api/metrics` (1s) via Express; REST `/api/ollama` (load/unload/pull/delete) |
| **cadaverine/dgx-spark-observability** (1) | **node-exporter, smartctl-exporter, cAdvisor, dcgm-exporter + nvidia-textfile sidecar** (fills DCGM gaps on UMA); vLLM `/metrics` optional | Host/GPU/thermal/storage/network/containers; 13 hardware alerts (RAM/disk/GPU temp/throttle/OOM/NVMe SMART); 38-panel Grafana; Loki logs | Prometheus + Grafana + Loki + Alertmanager + ntfy |
| **amer8/pulsebar** (2) | Consumes NVIDIA's **official DGX Dashboard** at `http://127.0.0.1:11000` (SSE telemetry stream) with username/password → token | Compact **RAM and GPU** status (whatever the DGX Dashboard SSE exposes) | macOS menu bar; signs into DGX Dashboard, listens to its SSE stream |
| **NVIDIA/dgx-spark-playbooks** (1302) | Official; includes **"DGX Dashboard"** playbook + "Connect to Your Spark", "NCCL/Connect Two Sparks" (fabric) | — (setup playbooks, not an exporter) | — |
| **ArgentAIOS/dgx-spark-cluster** (11) | Docs: 2-node cluster, InfiniBand/SSH checks, vLLM; `docs/12-monitoring.md` covers Prometheus+Grafana setup | GPU metrics, thermal alerts, cluster status scripts | Prometheus + Grafana (docs) |
| **GigCoder-ai/dgxtop** (36) | `/proc/diskstats`, `/proc/stat`, `/proc/meminfo`, `/proc/net/dev`, `nvidia-smi` | GB10 GPU, CPU, mem, network, **per-drive R/W transfer speed** (sector delta ×512/t) | TUI CLI (asitop-like), `.deb` |

*(Repos checked but not detailed above: canberkys/sparkscope done; raguraja/dgx-spark-status similar to thx0701; brainchillz/sparkdash similar to sparkrun-ui — Ray/vLLM/recipes; Jenpo/dgx-spark-monitoring = Grafana+Prometheus one-command setup.)*

---

## 2. KEY ENGINEERING PATTERNS TO ADOPT (with source)

1. **Unified-memory reporting is the #1 gotcha. Do NOT trust NVML meminfo on GB10.**
   - NVML returns `total ≈ MemTotal` (~121GB) which is misleading (sparkview); formats disagree (sparkDash empty; sparktop `[N/A]`); dcgm-exporter doesn't expose `FB_USED/FB_FREE` on UMA (cadaverine quirk doc).
   - Correct approach: **system total = `/proc/meminfo` (or `vm.total`)**, and `used` = either `vm.total - vm.available` (sparkview) or **Σ live NVML process allocs** (sparktop), labeled as *derived*. Keep RAM vs unified distinct for non-Spark (discrete VRAM) hosts (sparkDash).
   - `nvml-unified-shim` formalizes this: fall back to CUDA runtime + `/proc/meminfo` when NVML `NOT_SUPPORTED`.
2. **RDMA/RoCE traffic is invisible to netdev counters.** NCCL over RoCE bypasses the kernel. Read the **NICs' HCA hardware counters**: `ethtool -S` (sparktop) and `/sys/class/infiniband/<hca>/ports/<n>/hw_counters/port_xmit_data|port_rcv_data` — note these are **4-byte words, ×4 for bytes** (spark-smi/sparktop). Also read `port_rcv_errors/CNP/ECN` for congestion and NIC hwmon ASIC temp. Pair links by IPv4 subnet + corroborate tx/rx counters (sparktop).
3. **Two-tier polling with a single batched SSH round-trip per node.**
   - Fast tier (5s): GPU/CPU/mem/thermals/fabric counters. Slow tier (30s): docker inventory, disks, hardware detail (sparktop).
   - One long-lived SSH connection per node; run **one batched shell script** whose output is split on ASCII record separators — never one `ssh` per metric (sparktop cut ~100 forks / 890ms → 150ms per poll). Use whole-glob `grep -H .` instead of `cat` loops; name the ~18 RDMA counters explicitly (each hw_counters read traps into NIC firmware).
   - Merge multiple sources in a single SSH session: `nvidia-smi --query-gpu`, hwmon temp scan, `free` (C locale) (Sparky).
4. **Graceful degradation everywhere.** Collectors catch errors → return zero/defaults or mark node `status:"offline"` with an error message; the REST request never 5xx (spark-mon). Unreachable nodes show "stale" with last-known values; render never blocks on network (spark-smi, Sparky). Capability-driven probing: detect what hardware supports once into a `.caps` dict, skip absent sensors (no fake 0%/N/A) — e.g. no fan on UMA, `power_draw` but no `power_limit` on GB10 (spark-smi).
5. **vLLM polling — scrape its Prometheus `/metrics`, derive rates from counter deltas, average over rolling windows.**
   - Detect engine by banner (`vllm:`, `sglang:`, `llamacpp:`, `tgi_`, `nv_inference_`, Ollama `/api/ps`, fallback OpenAI `/v1/models`) on each locally-bound port (sparktop, sparkDash).
   - **Cumulative counters → per-second rate via monotonic deltas**, not nominal interval (sparktop fixed interval distortion; sparkDash). Speculative decoding bursts mean **average over ~10s** (vLLM's own window), not 1s.
   - **Latency = histogram `_sum/_count` over rolling 60s**, not lifetime (lifetime mean barely moves). Prefill = **computed tokens** (subtract prefix-cache hits), not ingested. Aggregate decode ≠ per-request speed; show both. Absent readings omitted, not zero.
   - Token tracking across server restarts: bank deltas; on counter going backwards treat as restart (Sparky). Probe **on the node** (engines bind 127.0.0.1) and filter response node-side to the engine's metric families (~32KB vLLM body trimmed).
6. **Aggregation/caching so scrapes never open an SSH session.** Keep a continuously-updated in-memory `ClusterSnapshot`; make `/metrics`, `/api/snapshot`, and WS **projections of that same snapshot** cached against its timestamp (sparktop: scrape ≈0.4ms; slow node can't stall collection). Same in-memory-cache + decouple browser poll from node poll (Sparky). Background poll loops run even with no clients so rate metrics stay correct (sparkDash).
7. **Auth posture:** default unauthenticated on trusted LAN, with **optional bearer/X-API-Key** token. Bind loopback by default; set `BIND_HOST`/`0.0.0.0` explicitly to expose (sparkDash, spark-mon `X-API-Key`, sparktop `SPARKTOP_TOKEN`, nv-monitor env-preferred token, spark-smi `X-Spark-Token`). **Never log secrets** (nv-monitor uses env not `-t` because CLI args show in `ps`). `/api/health` stays reachable without token but reports only liveness (sparktop). Read-only by default; gate mutating ops (control/Eco/reboot) behind opt-in + confirm (sparktop `SPARKTOP_DISABLE_CONTROL`, Sparky `eco_key.txt`, sparkscope whitelisted commands).
8. **History in SQLite WAL with retention; in-memory ring for live.** 48h–30d retention, prune by data's own clock not wall clock (sparktop, sparkscope, spark-mon). 1Hz forever = tens of millions of rows → persist samples at 1/min; keep in-memory ring (15-min) for live charts (sparktop, spark-dashboard).
9. **TL-DH-power / thermal quirk detection worth surfacing:** GB10 USB-C PD fault pins GPU at low SM clock while util/power/throttle all look normal — alert when `sm_clock < 0.45*clocks.max.sm` AND util ≥ 0.5 AND power < 35W AND no throttle reason (sparktop). PCIe link downtrain to gen1 under load = power-safety fault, flagged only after 3+ consecutive busy samples (spark-smi). PROCHOT from spbm hwmon (sparkview). CPU temp from `acpitz` zones relabeled Zone-A/B (spark-smi).
10. **Official data source to also leverage:** NVIDIA's own **DGX Dashboard** runs locally on port **11000**, exposes an SSE telemetry stream, and requires sign-in → token (pulsebar). Our status API could either re-scrape it or complement it with the agentless sources above.

---

## 3. Source URLs
- MiaAI-Lab/sparkDash — https://github.com/MiaAI-Lab/sparkDash
- wentbackward/nv-monitor — https://github.com/wentbackward/nv-monitor
- niklasfrick/spark-dashboard — https://github.com/niklasfrick/spark-dashboard
- metaspartan/sparktop — https://github.com/metaspartan/sparktop
- tonyd2wild/The-Sparky-Command-Center — https://github.com/tonyd2wild/The-Sparky-Command-Center
- roninix/spark-mon — https://github.com/roninix/spark-mon
- canberkys/sparkscope — https://github.com/canberkys/sparkscope
- chappa-ai-llc/spark-smi — https://github.com/chappa-ai-llc/spark-smi
- parallelArchitect/sparkview — https://github.com/parallelArchitect/sparkview
- CINOAdam/nvml-unified-shim — https://github.com/CINOAdam/nvml-unified-shim
- pgodlews/jetson-orin-exporter — https://github.com/pgodlews/jetson-orin-exporter
- ateska/dgx-spark-prometheus — https://github.com/ateska/dgx-spark-prometheus
- mcampa/sparkrun-ui — https://github.com/mcampa/sparkrun-ui
- thx0701/dgx-spark-status — https://github.com/thx0701/dgx-spark-status
- cadaverine/dgx-spark-observability — https://github.com/cadaverine/dgx-spark-observability
- amer8/pulsebar — https://github.com/amer8/pulsebar
- NVIDIA/dgx-spark-playbooks — https://github.com/NVIDIA/dgx-spark-playbooks (DGX Dashboard playbook)
- ArgentAIOS/dgx-spark-cluster — https://github.com/ArgentAIOS/dgx-spark-cluster
- GigCoder-ai/dgxtop — https://github.com/GigCoder-ai/dgxtop
- Also: parallelArchitect/spark-gpu-throttle-check, /cuda-unified-memory-analyzer, /nvidea-uma-fault-probe, /dgx-forensic-collect; antheas/spark_hwmon (GB10 power rails); NVIDIA build.nvidia.com/spark/connect-two-sparks / /open-eks-node-sessions. 
