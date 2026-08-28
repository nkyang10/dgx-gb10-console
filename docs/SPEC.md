# DGX Status API — 設計 SPEC & Assumptions（累積文件）

> **本文檔係項目嘅單一 source of truth（規範 + 假設 + 決定 + 變更記錄）。**
> 依家：收集/部署/安全已有研究做底；**儲存/API 呈現方式未定**（開放決定）。
> 規則：每加一個規格/假設 → 喺下面 Assumptions 加一條（**ASM-xx**，append-only）＋ 喺「變更記錄」加一行。**唔好改史**——新決定 append，標 `effective`/`superseded`。
> 細節逐 category 喺 `docs/狀態-*.md`／`docs/實作-*.md`；本文檔 consolidates + 指向佢哋。

---

## 1. 目標 / 範圍 / 非目標

**目標**：一個 **Gateway**，對外兩面 —— **Web 管理後台**（router 式：監測＋控制）畀用戶／管理員，＋ **HTTP API**（agent／自動化撈）。背後攞到 **N 部 DGX Spark（GB10 Grace Blackwell，DGX OS Ubuntu 24.04 ARM64）** 集群狀態。

**範圍**（狀態分三類 + 性能）：
- **硬體**：GPU、CPU、記憶體(UMA)、溫度、功耗、時脈/util
- **軟體/系統**：OS、systemd 服務、Docker、process、磁碟、網絡/fabric
- **vLLM**（行緊嘅 software，喺 Docker）：running/waiting、KV cache、throughput、health、已載入 models
- **性能（Performance）**：推理吞吐/latency（tok/s、TTFT/ITL/e2e/P95、RPS、KV、prefix hit）＋ 系統性能（net B/s、disk IOPS、CPU/GPU util）→ `狀態-08`

**產品兩面（Gateway 對外）**（ASM-21）：
- **🟩 Web 後台（用戶）**：router 式 admin console —— 節點列表、即時圖表、告警、控制櫃（vue on-device 監測＋可控制），SQLite 歷史回溯。
- **🟦 Agent API（自動化）**：簡潔 read-only endpoint（`/cluster.json`、`/metrics`、`/logs`）俾 agent monitor ＋ 受控 control。

**非目標（明確唔做）**：
- 完整 cAdvisor / Loki / 38-panel Grafana 堆棧（純 status API 過重；要 dashboard 先另加）
- dcgm-exporter / DCGM（GB10 官方唔支援，確證）
- **預設唔對 vLLM 下指令**（read-only）；只可選 opt-in 受控控制模式（見 ASM-18）
- 本機安裝/測試（呢部機只備內容）

---

## 2. ASSUMPTIONS 註冊表（累積，append-only）

| ID | Assumption | 狀態 |
|---|---|---|
| **ASM-01** | **vLLM 喺 Docker container 入面行**（Docker + NVIDIA Container Toolkit，DGX OS 內建）。偵測 = `docker ps --filter name=vllm` → 攞 publish port → HTTP 撈 `/metrics`/`/health`/`/v1/models`。**唔當** bare-metal `vllm serve`。 | ✅ effective |
| **ASM-02** | **N 節點 cluster**（≥2；2 部=基本部署）：一部 **gateway** 拉晒 `nodes[]` 唔係自身嗰啲，一部一寫 **exporter**（leaf）。星型。 | ✅ effective |
| **ASM-03** | **每節點都係一等公民**，各自 run exporter；加/減一部唔影響其他。 | ✅ effective |
| **ASM-04** | **Fabric（ConnectX-7 RoCE）淨係畀 NCCL/compute**；status API 經 **10GbE mgmt IP** 拉。 | ✅ effective |
| **ASM-05** | 本機**只備內容，唔裝唔 test**；完成後搬去 DGX 由用戶安裝。 | ✅ effective |
| **ASM-06** | **DCGM / dcgm-exporter / dcgmi 喺 GB10 官方唔支援**（「no plans to support DCGM on Spark」）→ ❌ 唔實作。tegrastats/jtop 都唔可靠。 | ✅ effective（確證） |
| **ASM-07** | **UMA 統一記憶體** → nvidia-smi memory 字段 N/A；GPU 記憶體用：`total=/proc/meminfo MemTotal`、`used=Σ --query-compute-apps=used_memory`、`free=MemAvailable`，加 **`vramUsedIsDerived`** flag。 | ✅ effective |
| **ASM-08** | **收集唔好打擾 vLLM**：resident NVML（唔 spawn）；零 GPU work；budget <2–5% 一核 + <50MB RAM。 | ✅ effective |
| **ASM-09** | **三層 polling tier**：fast 2–5s（GPU/CPU/RAM/thermal/netdev）、slow 30–60s（docker/df/ethtool/RDMA/systemctl）、slowest 60–120s（NVMe SMART）。 | ✅ effective |
| **ASM-10** | **in-memory `ClusterSnapshot`**：/metrics、/api/snapshot、WS 都係同一個 snapshot 嘅 cached projection（sparktop 模式）。 | ✅ effective |
| **ASM-11** | **關節點 graceful**：node down → `status:"offline"`+`error_message`，request 唔 5xx。 | ✅ effective |
| **ASM-12** | **儲存/API 呈現方式** → 已定（§8 OD-1/2）：**SQLite 做歷史/回溯**（WAL，8h–30d）＋ in-memory snapshot 做 live；Agent API = JSON REST + Prometheus text；User = **Web admin console**。 | ✅ effective（取代舊「未定」） |
| **ASM-13** | **聚合安全（含 inter-node communication）**：token 用 env（`DGX_STATUS_TOKEN`）唔喺 argv；Bind mgmt-LAN；API read-only。**站與站 hop（gateway→exporter）用 MCP（ASM-22）**：分離信任邊界用 mTLS / WireGuard；vLLM :8000 預設 0.0.0.0 要 firewall 收返做 inside。 | ✅ effective |
| **ASM-14** | **系統要 gather 性能資訊**：推理性能（vLLM tok/s、TTFT/ITL/e2e、RPS、KV、prefix hit）+ 系統性能（net B/s、disk IOPS、CPU/GPU util）——**由 counter/histogram 喺時間窗度 rate/latency，唔抄即時數**。 | ✅ effective |
| **ASM-15** | **熱降頻觀測用矩陣（四樣夾埋）：溫度 + SM 時脈比例 + throttle reason 邊隻 bit + 負載 util**——單靠溫度或少時脈判唔到；throttle reason 分「熱」(hw/sw_thermal) vs「功率」(sw_power_cap) vs「GB10 卡死」(無 reason 但 clock<45%)。 | ✅ effective |
| **ASM-16** | **能量/成本追蹤**：`spbm` hwmon（`power1 sys_total`/`power8 gpu` µW、`energy1 pkg`/`energy4 gpu` µJ，wrap-safe）→ kWh/day + $/day（R config）；token 會計 per(model,day)→per-model $ + cache 慳。 | ✅ effective |
| **ASM-17** | **容量預測用 Prometheus `predict_linear`**（唔手寫）：`disk_ttf_hours`（avail/slope，4h warn / 6h crit）；`kv_cache_headroom`/`uma_mem_used_ratio`；KV 飽和唔單靠 %（GB10 UMA headroom==system RAM）。 | ✅ effective |
| **ASM-18** | **vLLM 控制（v0.28.0 source 驗證）**：所有原生控制端點都 gate 喺 `VLLM_SERVER_DEV_MODE=1`；**冇 per-request queue listing**（要靠 proxy `/v1/responses` 追）；status API **預設 read-only**，控制 = **opt-in 自己 proxy**（abort-by-id / pause(keep|wait) / resume / expose is_paused|is_sleeping）。⚠️ **GB10 sleep→wake crash #50011** → 唔 surface sleep/wake 1–2。 | ✅ effective |
| **ASM-19** | **額外收集（D+C+E+F，全部 research 完成）**：🟢 D2 container OOM/restart、F1/F2 security snapshot+service diff、E1 RDMA 擁塞 rate；🟡 D1 NVMe 壽命（×1000 單位）、D3 journalctl markers、D4b throttle timeline；🔵 B3 per-model（已有 label）、B2 /load、B4 --kv-cache-metrics-sample、C4 被動 throttle、C3 稀疏 TTFT probe；⚠️ **主動基準 C1/C2 只喺 maintenance window（唔 serving）**；E2 冇 NVLink 可攞（單 SoC），用 PCIe counter。 | ✅ effective |
| **ASM-20** | **Log 睇/拎（read-only）**：分兩層 —— 輕量 markers（`{count,last_ts}` 入 snapshot 警報）＋ on-demand tail（`GET /api/nodes/{n}/logs/{source}?lines&since&filter`，source=vllm\|kernel\|services\|<ctr>，經 mgmt IP 去節點 `journalctl`/`docker logs`）。**⚠️ vLLM request log 可含 prompts/tokens → log endpoint 要 auth**（唔似 /health）；唔好 log token；限行數/filter。Loki 只係要全文搜尋先加。 | ✅ effective |
| **ASM-21** | **Gateway 對外兩面**：**Web 管理後台**（router 式：監測＋控制，serve on `/ui`）畀用戶；**Agent API**（read-only `/cluster.json`/`/metrics`/`/logs` ＋ 受控 control）畀自動化。兩面共用同一 guard（auth + read-only default；control opt-in）。 | ✅ effective |
| **ASM-22** | **inter-node 通訊用 MCP（基本保安）**：每節點行一個 **secured MCP server**（streamable HTTP + **Bearer token**）expose collector 工具（`get_hardware_status`、`get_vllm_status`、`read_log`、`control_*`…）；gateway 用 **MCP client** 撈各節點（替代裸 HTTP exporter）。基本保安 = 每 node 各自 token + TLS（離信任邊界用 mTLS/WireGuard）。 | ✅ effective |

（將來新假設繼續加，ID 遞增。）

---

## 3. 需求 → 覆蓋對應

| # | 需求（用戶） | 覆蓋 | 狀態 |
|---|---|---|---|
| R1 | HTTP API 畀另一部機攞 DGX 狀態 | SPEC §4/§5 + `00-總覽` §5 | ✅ |
| R2 | 支援硬體/軟體/vLLM 狀態 | `狀態-01..07` | ✅ |
| R3 | 支援 2 部 DGX（擴到 N） | `實作-多節點擴展.md` + ASM-02 | ✅ |
| R4 | 本機唔裝唔 test | ASM-05 + README | ✅ |
| R5 | 儲存/攞資料方法由我話你知 | §8 開放決定 + ASM-12 | ⏸️ |

---

## 4. 架構（N 節點，星型）

```
gateway(dgx-01, :9101) ──(10GbE mgmt switch)──▶ dgx-02..N (exporter, :9101)
     │                                                    │
     └─ 拉晒 nodes[] 其餘 (HTTP :9101, Bearer token)      └─ 本地收集 /proc,/sys,nvidia-smi,...
     └─ 合併成 ClusterSnapshot → /health /cluster.json /metrics
ConnectX-7 200G fabric（全網 mesh / switch）= 只畀 NCCL/compute
```
- 元件：每節點 exporter daemon（FastAPI，venv+systemd）；一部 gateway（節點 0 上）。
- 收集器：`hardware.py`（GPU/UMA）、`system.py`（CPU/RAM/disk/thermal/power）、`network.py`（netdev/fabric/RDMA）、`services.py`（systemd/docker）、`vllm.py`（Docker 偵測→/metrics）。
- Startup：gateway 讀 `nodes[]` → 為每個遠端 leaf 開 async poll loop（fast/slow tier）→ 寫入 snapshot。

---

## 5. 資料收集 SPEC（每 category 簡版；細節見各檔）

| Category | 必收（fast tier） | 慢 tier | 見 |
|---|---|---|---|
| GPU | utilization.gpu、temperature.gpu、power.draw/limit、clocks.sm/max、throttle_reasons、GPU mem(UMA derived) | — | `狀態-01` |
| CPU/RAM | cpu usage per-core、loadavg、mem(UMA)、PSI(可選) | — | `狀態-02` |
| 溫度/功率 | thermal zones (tj_max/gpu/soc)、GPU power | spbm power rails(可選) | `狀態-03` |
| 儲存 | — | df/diskstats | NVMe SMART(60s) | `狀態-04` |
| 網絡/Fabric | netdev TCP | ethtool -S、RDMA hw_counters、fabric link | `狀態-05` |
| 軟體/服務 | systemd、docker ps、ports、節點 probe | — | `狀態-06` |
| vLLM | /health、/v1/models、/metrics（10–15s） | — | `狀態-07` |
| **性能** | **推理**：tokens/s、RPS、TTFT/ITL/e2e（avg+P95）、KV、prefix hit（窗 10–60s）｜**系統**：net B/s、disk IOPS/MB/s、CPU/GPU util | fabric Gbps、spec-decode | `狀態-08` |

Alert 閾值全集：`docs/資料收集決定.md` §9 + `實作-部署與安全.md` §5。

---

## 6. API 合約（草案，schema 照 spark-mon envelope）

```
GET /health            → {status:"ok"}（liveness，唔 auth）
GET /cluster.json      → {schema_version:"1.0", nodes:[NodeMetrics]}   # gateway，agent 用
GET /metrics           → Prometheus text（cached projection）
GET /logs/{node}/{src} → 日誌 tail（auth）
GET /ui                → Web 管理後台（router 式 HTML SPA，serve by gateway）   # 用戶用
POST /control/*        → 受控控制（opt-in；OD-4）
NodeMetrics = { node_name, status: online|offline, cpu, ram, gpus[], disks[], power, network, services, vllm, error_message }
```
> Agent API 以 `/cluster.json` + `/metrics` 為主（簡潔、read-only）；Web console `/ui` serve 前端的 SPA，輪詢 `/cluster.json` 即時展示與控制。

---

## 7. 部署 SPEC

- **每節點** bare Python venv + systemd（`deploy/dgx-status-exporter.service`）；Docker = opt-in 後備。
- **N 節點**：`config/config.yaml` `nodes[]` 註冊表；`install.sh --role --node-id --mgmt-ip`。
- 依賴：fastapi/uvicorn/pydantic/psutil/nvidia-ml-py/prometheus-client；host: nvidia-smi/nvme/sensors/ethtool。
- 認證：env token + optional X-API-Key；read-only。TLS：Caddy（可選）。
- 歷史：SQLite WAL（4 8h–30d）／live ring buffer。監控：Prometheus+Grafana（可選，架喺 Node-A）。
- 詳見 `實作-部署與安全.md`。

---

## 8. 開放決定（⏳ 等用戶）

| # | 決定 | 狀態 |
|---|---|---|
| OD-1 | **儲存**：SQLite 歷史/回溯（WAL，8h–30d）＋ in-memory snapshot 做 live | ✅ **已定（SQLite）** |
| OD-2 | **API 呈現**：Agent = JSON REST + Prometheus text；User = Web admin console（`/ui`） | ✅ **已定** |
| OD-3 | 端口（預設 9101）、認證開關、N 大型時 federation vs 多級 gateway | ⏳ |
| OD-4 | **vLLM 控制模式開唔開**（opt-in guarded proxy）：abort-by-id / pause/resume ／ 或維持 read-only | ⏳（§狀態-11 有可行性 + GB10 sleep-wake 風險） |
| OD-5 | **Log 暴露深度**：淨 markers + on-demand tail（推薦）／ 定要加 Loki 全文搜尋 | ⏳ |
| OD-6 | **UI 技術棧**：輕量 HTML/JS SPA（推薦）vs Flutter Web（要原身 apps 先生） | ⏳ |

---

## 9. 變更記錄（Changelog，累積）

| Date | 改動 | 影響 |
|---|---|---|
| 2026-08-28 | 開始 SPEC 累積文件；確立 Assumptions 註冊表 + 變更記錄機制 | — |
| 2026-08-28 | ASM-01：vLLM 喺 Docker container 行 | `狀態-07` 偵測方式 |
| 2026-08-28 | ASM-02/03：N 節點、每節點一等公民 | `實作-多節點擴展.md` |
| 2026-08-28 | ASM-13：認證（env token + read-only） | `實作-部署與安全.md` |
| 2026-08-28 | **ASM-14：加「性能」收集**（推理吞吐/latency + 系統性能） | `狀態-08-performance` |
| 2026-08-28 | **ASM-15：熱降頻觀測矩陣**（temp+clock+throttle reason+util 四樣夾埋） | `狀態-09-熱控制與降頻` |
| 2026-08-28 | **ASM-16/17：成本/能量 + 容量預測**（A1/A2/A3 research 完成） | `狀態-10-成本與容量` |
| 2026-08-28 | A3 詳細報告 | `capacity_prediction_A3_report.md`（docs/references 收埋） |
| 2026-08-28 | **ASM-18：vLLM 隊列觀看 + on-the-fly 管理**（R7 verified v0.28.0；control 全 dev-gate + GB10 sleep-wake bug） | `狀態-11-vLLM-隊列與管理` |
| 2026-08-28 | **ASM-19：額外收集全部完成**（B deep-obs / C benchmarks / D health / E network-deep / F security） | `狀態-12`+`狀態-13` |
| 2026-08-28 | **ASM-20：Log 睇/拎**（read-only：markers + on-demand tail；auth；vLLM log 敏感） | SPEC §6 + OD-5 |
| 2026-08-28 | **Final verification pass（6 thread）**：driver→580.159.03/OS7.5.0；**vLLM Rust rewrite**（engine_sleep metric→/is_sleeping、per-request flag 取代、counter 冇 _total、engine label）；DGX Dashboard UMA bug 已 fix；schema 產物收 references | `狀態-01/03/07/12` + `references/` |
| 2026-08-28 | **Inter-node communication secure**：ASM-13 強化 + **改用 MCP（ASM-22）**；vLLM :8000 收做 inside | `實作-部署與安全` §2 |
| 2026-08-28 | **Gateway 對外兩面（ASM-21）+ OD-1/2 已定**：Web admin console `/ui`（router 式）＋ Agent API；**SQLite** 歷史 | SPEC §1/§6/§8 |
| 2026-08-28 | **inter-node 用 MCP + 基本保安（ASM-22）**：每節點 secured MCP server expose collector tools，gateway 用 MCP client 撈 | `實作-多節點擴展` + `架構分層圖` |

---

*文件狀態：🏗️ 累積中。收到用戶決定（OD-1..3）就落 code。*
