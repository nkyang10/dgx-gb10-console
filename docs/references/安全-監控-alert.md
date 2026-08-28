# DGX Spark Status API — Round 5: Security, History Storage, Monitoring & Alerting

Scope: two-node NVIDIA DGX Spark cluster (MSI EdgeXpert MS-C931 / DGX Spark GB10, 128GB/1TB) connected over 10GbE management LAN. Prior rounds established: NVMe `critical_warning` / `percentage_used` (known platform drive-failure issue), GPU temp near 96–97 °C throttle line on GB10, GPU SM clock dropping <0.45×max while util stays high = USB-C-PD under-supply fault, ConnectX `phys_state != Up` / rdma link down, `systemctl` failed units, vLLM `/health != 200`.

Research method: no browser, no Serper key available in env → verified against authoritative docs via direct curl (FastAPI, sqlite.org, prometheus.io, NVIDIA/dcgm-exporter, node_exporter). **Design only — nothing installed/tested.**

---

## 1. Security for the remote HTTP status endpoint

### Binding (defense in depth, default-deny)
- **Do NOT bind `0.0.0.0`** on the public/upstream NIC. Bind only to the **10GbE management-LAN address** per node, e.g. `--host 192.168.50.11` / `192.168.50.12`. This is the primary control; auth is the second layer.
- If a firewall (ufw/nftables) is present, default-deny inbound on that interface except the port + SSH + RDMA/ConnectX control traffic.
- Prometheus/Grafana/Loki **also bind to the mgmt LAN or localhost only**; never expose the API or Grafana to upstream internet.

### Auth — API key / bearer token via FastAPI dependency
Token must come from **environment** (`DGX_STATUS_TOKEN`), never a CLI arg, so it never appears in `ps`, shell history, or `/proc/<pid>/cmdline`.

```python
# security.py
import os, secrets, json
from fastapi import Header, HTTPException, Request, Depends
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials

# load from env ONLY (NOT argv) to avoid `ps` leakage
token = os.environ.get("DGX_STATUS_TOKEN") or secrets.token_urlsafe(32)
if not os.environ.get("DGX_STATUS_TOKEN"):
    import logging; logging.warning("DGX_STATUS_TOKEN unset; generating ephemeral token")
_expected = secrets.compare_digest  # constant-time

_bearer = HTTPBearer(auto_error=False)

async def require_token(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> None:
    """Dependency for EVERY auth'd endpoint. Read-only by design."""
    if credentials is None or not _expected(credentials.credentials, token):
        raise HTTPException(status_code=401, detail="invalid token",
                            headers={"WWW-Authenticate": "Bearer"})

# main.py
from fastapi import FastAPI
app = FastAPI(docs_url="/api/docs", redoc_url=None, openapi_url="/api/openapi.json")

@app.get("/api/v1/status", dependencies=[Depends(require_token)])
async def status(): ...          # reads our exporter-side state

@app.post("/api/v1/reboot")      # NOT present: all endpoints are read-only.
async def _deny(): raise HTTPException(400, "read-only API")
```

Key points:
- `HTTPBearer(auto_error=False)` + constant-time `secrets.compare_digest` → no timing side-channel, clean 401.
- **Default-deny on mutating endpoints**: the API is **read-only** — there is no POST/PUT/reboot. If a control action is ever needed, guard it behind a *separate* token with distinct perms, and require TLS.
- `docs_url`/`openapi_url` default: if N/A expose docs only on the mgmt LAN; simplest is to disable `/docs` entirely on prod (`docs_url=None`) — see §5.
- If you prefer an `X-API-Key` header instead of Bearer, swap the dependency to `Header`:

```python
async def require_token(x_api_key: str | None = Header(default=None)):
    if not x_api_key or not _expected(x_api_key, token):
        raise HTTPException(401, "invalid api key")
```

### TLS termination
- **Preferred: reverse proxy** — caddy (automatic HTTP→HTTPS + easy `import { env }`) or nginx. Terminate TLS at Caddy on each node; upstream to uvicorn bound to `127.0.0.1:9401` (so the private token channel is loopback).
  - **mTLS for cross-node**: since these are only 2 nodes on a trusted mgmt LAN, mutual TLS client-cert auth at the proxy is the strongest option. Both nodes get CA-signed client certs; each proxy rejects TLS clients without a cert valid for node-A/node-B. This protects even if the token leaks.
- **Alternative: uvicorn native TLS** — `--ssl-keyfile /etc/status/key.pem --ssl-certfile /etc/status/cert.pem --ssl-ca-certs /etc/status/ca.pem --ssl-cert-reqs CERC_REQUIRED --host 192.168.50.11`. Simpler (no extra process) but harder to rotate certs and to do mTLS broadly. For "API key only, LAN-only" this is acceptable; for cross-node scrape add the CA-required flags.
- Recommend: **Caddy on each node, mgmt-LAN bind, mTLS optional**, uvicorn on loopback so the exporter endpoint and reverse proxy share localhost trust.

---

## 2. History storage design

### Recommendation ladder
| Option | Fit | Verdict |
|---|---|---|
| **SQLite WAL, time-series samples table** | 2 nodes × ~20 metrics @ 1/min, keep 30 d → ~ 2×20×1440×30 ≈ 1.7 M rows, well under SQLite's comfort zone | **Primary choice** — zero extra infra, one `status.db` file, survives node restart. |
| In-memory ring buffer (deque) for live charts | sub-second live view (last 5 min) | Use **in addition**, backed by SQLite for persistence. |
| TimescaleDB | Same metric volume needs no separate DB; adds a postgres server + tuning. Overkill for 2 nodes. | Only if node A already runs Postgres and you want time_bucket() SQL convenience. |
| **Let Prometheus TSDB hold history** | Prometheus already keeps 30 d of scrape at every scrape interval; exporter just needs current state. | **Do BOTH**: keep short SQLite history for the API's `/history` endpoint + rely on Prometheus for long-term dashboards. Avoid double-storing at 1/min — scrape interval on our exporter at, say, 15 s makes Prometheus the richer history source. |

**Bottom line:** SQLite WAL for the API's own short read-back (last hour/day, ring-buffer for live), Prometheus TSDB for 30 d+ history / dashboards. Don't mirror everything into both.

### SQLite WAL schema (status.db)

```sql
PRAGMA journal_mode=WAL;          -- readers don't block writer; fast appends
PRAGMA synchronous=NORMAL;        -- WAL + NORMAL is safe & fast
PRAGMA wal_autocheckpoint=1000;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS samples (
  id        INTEGER PRIMARY KEY,            -- rowid; index cheap
  node      TEXT    NOT NULL,               -- 'a' | 'b'
  ts        INTEGER NOT NULL,               -- unix seconds (UTC)
  metric    TEXT    NOT NULL,               -- e.g. 'gpu_temp_c', 'nvme_percent_used'
  value     REAL,                           -- gauge
  meta      TEXT                            -- optional JSON labels (nvme device, gpu idx)
);
CREATE INDEX IF NOT EXISTS idx_samples_node_ts ON samples(node, ts);
CREATE INDEX IF NOT EXISTS idx_samples_metric_ts ON samples(metric, ts);
```

- **Wide-vs-tall:** tall key/value (above) is simplest and most flexible for a metric *named in JSON*; if you emit one row per scrape with all metrics as columns, the wide table is faster for multivariate reads but brittle when metric set changes. For low volume either works — recommend **tall** for extensibility.
- **Insert** in a single transaction per scrape (one `executemany`), so each scrape = one atomic batch.
- **Retention/pruning**: keep 30 d @ 1/min. Daily or on-boot:
```sql
DELETE FROM samples WHERE ts < strftime('%s','now','-30 days');
-- optional: down-sample old rows to 1/10-min past day 7:
INSERT INTO samples(node, ts, metric, value)
  SELECT node, ts - (ts % 600), metric, avg(value)
  FROM samples WHERE ts < strftime('%s','now','-7 days')
  GROUP BY node, ts-(ts%600), metric;
DELETE FROM samples WHERE ts < strftime('%s','now','-7 days');
```
- **Ring buffer for live charts**: keep a `collections.deque(maxlen=N)` in memory holding the last N (e.g. 5 min @ 1/min = 300) samples per node, appended on each write; serve `/history?last=5m` from the deque for zero-IO live views; flush every write to SQLite for durability + long history.

### Why not TimescaleDB / hypertable here
For 2 nodes the SQLite+pynvml path is a single dependency, transactional, CRASH-SAFE via WAL, and trivially backed up (`sqlite3 status.db ".backup x"`). TimescaleDB's time_bucket/continuous-aggregates only pay off at 100+ nodes or sub-second rates. Documented trade-off: TimescaleDB gives `time_bucket` + native retention policies and better concurrent-writer scaling, at the cost of a full Postgres service on node A.

---

## 3. Monitoring stack integration

**Recommendation: run Prometheus + Grafana (+ optional Loki) as containers (podman/docker) on Node-A**, on the mgmt LAN:
- Prometheus scrapes both node exporters + both vLLM endpoints + both our status exporters.
- Node-A is already the gateway for the API; co-locating the stack avoids a third machine and keeps the num-link traffic local to the 10GbE LAN.
- **Grafana binds to mgmt LAN** (or localhost + SSH tunnel) — never 0.0.0.0 on public NIC.

### prometheus.yml — scrape_config snippet

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 30s   # alert rules evaluated this often

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  # our DGX status exporter (exposes node/GPU/NVMe/ConnectX/RDMA/systemctl/vLLM-derived state)
  - job_name: dgx_status
    static_configs:
      - targets: ['node-a:9401']     # mgmt-LAN, reverse-proxied on node-a
        labels: { node: 'a' }
      - targets: ['node-b:9401']
        labels: { node: 'b' }
    metrics_path: /metrics
    scheme: https                     # if TLS with client certs:
    #tls_config:
    #  ca_file: /etc/prometheus/ca.pem
    #  cert_file: /etc/prometheus/client.pem
    #  key_file:  /etc/prometheus/client.key
    #  insecure_skip_verify: false
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/status_token   # same token, file (not ps)

  # node_exporter (system, disk, nvme, network)
  - job_name: node
    static_configs:
      - targets: ['node-a:9100']
        labels: { node: 'a' }
      - targets: ['node-b:9100']
        labels: { node: 'b' }

  # vLLM OpenAI-compatible servers (health endpoint)
  - job_name: vllm
    static_configs:
      - targets: ['node-a:8000', 'node-b:8000']   # via /metrics scrape (vLLM /metrics) 
    metrics_path: /metrics
    # Engine-dead detection also uses plain health check: see blackbox below.

  # Blackbox probe of the vLLM /health endpoint (200 = engine alive)
  - job_name: blackbox
    metrics_path: /probe
    params: { module: [http_2xx] }
    static_configs:
      - targets: ['https://node-a:8000/health', 'https://node-b:8000/health']
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: node-a:9115   # blackbox_exporter on node-a
```

### Grafana
- Single datasource = this Prometheus. Build dashboards:
  1. **Cluster Overview** — per-node GPU util, mem, temp, SM clock vs max, power, "+NVLink/C2C".
  2. **Storage health** — per-NVMe `node_nvme_smart_critical_warning_<flag>`, `percentage_used`, `temperature_celsius`, `node_filesystem_avail_bytes` per mount.
  3. **Fabric/network** — ConnectX `phys_state`, `rate`, `rx/tx`, `rdma_*` link state, port flaps.
  4. **Service** — `up{job="dgx_status"}`, `up{job="node"}`, `up{job="vllm"}`, `systemctl_failed{...}`, vLLM `/health == 200` from blackbox (`probe_success`).
- Provision dashboards as JSON in `/etc/grafana/provisioning/dashboards/` for reproducibility.

### Optional Loki (logs)
- Run Loki as a container on node-A; ship logs from both nodes' journald via `promtail`:
```yaml
# promtail.yml (per node)
server: { http_listen_port: 9080 }
clients: [ { url: http://node-a:3100/loki/api/v1/push } ]
scrape_configs:
  - job_name: journald
    journal:
      max_age: 12h
      labels: { job: "journald", node: "<a|b>" }
```
- Correlate a GPU-throttle alert with the board's thermal-power-cap log lines in one Grafana dashboard. **Loki is optional** — add only if you want grep-able history of dmesg/systemd during fault forensics. Scrape noise (4 jobs) is trivial for Loki.

---

## 4. Alerting thresholds (PromQL) — concrete rules

Metric sources: our exporter (`dgx_*`), `node_exporter` (`node_nvme_*`, `node_filesystem_*`), `dcgm-exporter` (`DCGM_FI_*`), `blackbox` (`probe_success`), Prometheus `up`.

```yaml
# /etc/prometheus/rules/dgx.yml
groups:
  - name: dgx_storage
    rules:
      # NVMe drive-failure precursor (known DGX Spark platform issue)
      - alert: NVMeCriticalWarning
        expr: (node_nvme_smart_critical_warning_available_spare
               + node_nvme_smart_critical_warning_device_reliability{job="node"}) > 0
        for: 2m
        labels: { severity: critical }
        annotations: { summary: "NVMe {{ $labels.device }} on node-{{ $labels.node }} reports critical warning",
                       description: "Drive reports smart critical_warning bit set; known failure precursor on this platform. Back up + stage replacement." }

      # percentage_used climbing toward end-of-life: warn at 85, crit at 95
      - alert: NVMeWearHigh
        expr: node_nvme_smart_percentage_used{job="node"} > 85
        for: 15m
        labels: { severity: warning }
        annotations: { summary: "NVMe wear {{ $labels.device }} {{ $value }}% used on node-{{ $labels.node }}" }
      - alert: NVMeWearCritical
        expr: node_nvme_smart_percentage_used{job="node"} > 95
        for: 5m
        labels: { severity: critical }
        annotations: { summary: "NVMe {{ $labels.device }} at {{ $value }}% — replace now" }

      # disk > 85%
      - alert: DiskSpaceHigh
        expr: (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} /
                      node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100 > 85
        for: 10m
        labels: { severity: warning }
        annotations: { summary: "Disk {{ $labels.mountpoint }} on node-{{ $labels.node }} > 85% ({{ $value }}%)" }

  - name: dgx_thermal
    rules:
      # GB10 throttle line ~96–97 C; sustained approach = cooling/PD fault
      - alert: GPUHot
        expr: DCGM_FI_DEV_GPU_TEMP > 92
        for: 3m
        labels: { severity: warning }
        annotations: { summary: "GPU node-{{ $labels.node }} temp {{ $value }}C" }
      - alert: GPUThrottle
        expr: DCGM_FI_DEV_GPU_TEMP > 96
        for: 2m
        labels: { severity: critical }
        annotations: { summary: "GPU node-{{ $labels.node }} at {{ $value }}C — throttling risk" }

  - name: dgx_power_fault
    rules:
      # SM clock crushed to <45% of max while util stays high => under-supply /
      # USB-C PD fault (prior research finding).
      - alert: SMClockCollapse
        expr: (DCGM_FI_DEV_SM_CLOCK / clamp_min(DCGM_FI_DEV_SM_CLOCK_MAX, 1)) < 0.45
               and DCGM_FI_DEV_GPU_UTIL > 80
        for: 2m
        labels: { severity: critical }
        annotations: { summary: "SM clock {{ $value | humanize }}x max on node-{{ $labels.node }} at high util",
                       description: "Power delivery / USB-C PD under-supply fault suspected on node-{{ $labels.node }}." }
      # (depends on exporter also publishing DCGM_FI_DEV_SM_CLOCK_MAX; scale factor may vary by rep)

  - name: dgx_fabric
    rules:
      - alert: ConnectXLinkDown
        expr: dgx_connectx_phys_state { job="dgx_status" } != 1       # 1 = Up
        for: 1m
        labels: { severity: critical }
        annotations: { summary: "ConnectX port {{ $labels.port }} down on node-{{ $labels.node }}" }
      - alert: RDMAOpenFabricsDead
        expr: dgx_rdma_port_state { job="dgx_status" } != 4           # 4 = ACTIVE
        for: 1m
        labels: { severity: critical }
        annotations: { summary: "RDMA link inactive on node-{{ $labels.node }}" }

  - name: dgx_services
    rules:
      - alert: StatusExporterDown
        expr: up{job="dgx_status"} == 0
        for: 3m
        labels: { severity: warning }
        annotations: { summary: "dgx status exporter down on {{ $labels.instance }}" }
      - alert: NodeExporterDown
        expr: up{job="node"} == 0
        for: 3m
        labels: { severity: warning }
        annotations: { summary: "node_exporter down on {{ $labels.instance }}" }
      - alert: VllmEngineDead
        expr: probe_success{job="blackbox"} == 0
        for: 2m
        labels: { severity: critical }
        annotations: { summary: "vLLM /health != 200 on {{ $labels.instance }}",
                       description: "Inference engine unresponsive on node {{ $labels.node }}." }
      - alert: FailedSystemdUnit
        expr: node_systemd_unit_state{state="failed"} == 1
        for: 2m
        labels: { severity: warning }
        annotations: { summary: "systemd unit {{ $labels.name }} failed on node-{{ $labels.node }}" }
```

Notes on thresholds:
- Drive-failure `critical_warning` is the **known platform failure precursor** → set it `critical` with short `for:`. `percentage_used` thresholds (85/95) avoid false positives from the write-heavy training load.
- GPU temp: 92 °C warn / 96 °C crit sits **just below** the ~96–97 °C GB10 throttle line; sustained = cooling or PD fault, not a transient.
- SM-clock collapse uses a **ratio with high util** so a legit idle low clock doesn't fire — that combination is the PD-fault signature.
- Link/RDMA/dead-there is no delay: `for: 1m` since link drops are instant and unambiguous.

---

## 5. Secrets & hardening checklist

- **Rotate default DGX Dashboard / OpenBMC / IPMI credentialspost-confirm** — the DGX Spark ships with known default admin credentials; change them immediately (both the OS user and the NVIDIA DCGM/Dashboard web UI). Use unique per-node passwords stored in a password manager / vault, never in the repo.
- **Disable `/docs` on prod**: `docs_url=None, redoc_url=None, openapi_url=None`, or gate the docs behind the mgmt-LAN + auth. Unauthenticated OpenAPI leaks internal field names.
- **Tokens via env/files only** (never argv → `ps`). For Prometheus use `authorization.credentials_file` + `chmod 600`; for caddy use `import { env.DGX_STATUS_TOKEN }`. Log sanitization: **never log the Authorization header or the token**; any exception/repr that could include headers must redact it. Test with a deliberately-bad scrape and confirm logs show no token echo.
- **API is read-only** (default-deny): no mutating methods exposed; if a reboot endpoint is ever added, use a second, separate high-privilege token + require client cert (mTLS).
- **Rate limiting** on the proxy (`caddy` `rate_limit` or nginx `limit_req_zone`) to blunt token brute-force and accidental hammering (scrape interval already bounds legitimate load).
- **TLS everywhere**: mgmt-LAN/broadcast or not, never send the token in plaintext across the wire — every client-to-exporter hop is HTTPS/mTLS (see §1).
- **Bind the whole stack to mgmt LAN / loopback**, ufw default-deny inbound on the upstream NIC.
- **Backups**: `status.db` WAL → periodic `sqlite3 .backup` + ship to loki-independent storage; set `PRAGMA` per §2 so the WAL checkpoint doesn't balloon.
- **Harden the exporter container**: run as non-root, `read_only_root_filesystem`, drop unnecessary capabilities, `no-new-privileges`, and mount `/ `/sys`/`/proc` (for nvidia-smi/smartctl/rdma/systemctl) read-only where possible.

---

## Source URLs (verified during research)
- FastAPI security / dependencies (HTTPBearer, APIKey, dependencies): https://fastapi.tiangolo.com/tutorial/security/ , https://fastapi.tiangolo.com/tutorial/security/simple-oauth2/ , https://fastapi.tiangolo.com/tutorial/dependencies/
- SQLite WAL: https://www.sqlite.org/wal.html (checkpoint, concurrency, persistence)
- Prometheus configuration (scrape_config / static_configs, scrape_interval, tls_config, authorization): https://prometheus.io/docs/prometheus/latest/configuration/configuration/
- Prometheus alerting rules (groups, `for:`, `keep_firing_for:`): https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/
- NVIDIA DCGM metric names — `DCGM_FI_DEV_SM_CLOCK/.GPU_TEMP/.GPU_UTIL`, thermal-violation counters (comment-disabled by default): https://github.com/NVIDIA/dcgm-exporter/blob/main/etc/dcp-metrics-included.csv ; docs https://docs.nvidia.com/datacenter/dcgm/
- node_exporter collectors (incl. `nvme`, `systemd`, `filesystem`): https://raw.githubusercontent.com/prometheus/node_exporter/master/README.md
- NVIDIA DGX Spark platform (GB10, ConnectX up to 4 systems, USB-C DP-alt, 150×150×50.5 mm / 1.2 kg): https://www.nvidia.com/en-us/products/workstations/dgx-spark/
- Grafana docs: https://grafana.com/docs/grafana/latest/ ; Loki overview: https://grafana.com/docs/loki/latest/get-started/overview/
- vLLM `/health` (HTTP 200 when engine ready) — OpenAI-compatible server health endpoint.

*Environment note: advertised Serper search was unavailable (no API key in env) and browser is disabled; equivalents were verified by direct fetch of the authoritative primary sources above.*
