# DGX Status API — TODO 待辦清單

> 將要整嘅嘢全部放喺度。✅=完成 ⬜=未做 🔬=進行中 ⏸️=等緊決定。
> **你可以直接喺下面加 item**（想加嗰陣喺任何 section 尾部開新行加 `- [ ] 你嘅 item` 就得）。

---

## 階段 0 — 研究 / 設計（✅ 完成）

- [x] 開 project 結構 + README + 本 TODO
- [x] 確認 DGX Spark 平台關鍵事實（UMA 統一記憶體、nvidia-smi 記憶體報 N/A、**DCGM 官方唔支援**、tegrastats 唔預載）
- [x] 4 條平行研究 thread（硬件 / GitHub repos / vLLM / 系統+架構）完成
- [x] 整合完整版 MD：`docs/研究-DGX狀態獲取方法.md`
  - [x] 硬體方法（nvidia-smi 可靠/唔可靠字段、/proc/meminfo、hwmon、spark_hwmon）
  - [x] vLLM 完整 metrics 表（V1 vs legacy 命名）+ endpoints + 遠端查詢
  - [x] 系統/報告（systemd/docker/NVMe/fabric）+ 網絡拓撲（ConnectX-7 multi-host 4 接口）
  - [x] GitHub 工程模式（§4）+ 推薦架構（§5）
- [x] MD 完整版 review

### 第 2 期深研（5 輪，✅ 全部完成 → 已整合入 MD §7–§11）
- [x] R1 官方 DGX Dashboard 逆向（`127.0.0.1:11000` SSE/登入/字段）→ MD §7
- [x] R2 vLLM /metrics 實務解析（parse→JSON、版本 pin NGC 26.x vs legacy、scrape cadence、failure 語義）→ MD §8
- [x] R3 Collector 效能&常駐（各指令成本、三層 polling、daemon budget、唔打擾 vLLM）→ MD §9
- [x] R4 部署方案（venv+systemd、systemd unit、Docker、2-node aggregator、install.sh）→ MD §10 + `deploy/`+`config/`+`scripts/`
- [x] R5 安全/歷史儲存/監控 alert（FastAPI auth、SQLite WAL schema、PromQL 警報）→ MD §11 + `docs/references/安全-監控-alert.md`
- [x] 完整報告收倉：`docs/references/硬件-研究報告.md`、`docs/references/GitHub-生態研究報告.md`、`docs/references/安全-監控-alert.md`

### 第 3 期深研（10 個 GitHub repo 源碼，✅ 完成 → 綜合入 `docs/資料收集決定.md`）
- [x] 10 repo 深研：sparktop / sparkDash / nv-monitor / spark-dashboard / Sparky / spark-smi / sparkview / sparkscope / spark-mon / dgx-spark-observability
- [x] 綜合「邊啲數據有用」→ `docs/資料收集決定.md`（每資料寫明點攞+證明 repo+優先級）
- [x] Recommended 最小集（§8）+ Alert 閾值（§9）+ 可偷工程模式（§10）
- [x] ✅ 研究文件按 **data category 分拆**：`docs/狀態-0X-*.md`（7 類）＋ `docs/實作-*.md`（收集器/部署）+ `docs/00-總覽.md` 索引；舊大檔已刪
- [x] ✅ 設計擴大到 **N 節點**：`config/config.yaml` 通用 `nodes[]` 註冊表 + `aggregation.pull`；`install.sh` 加 `--node-id/--mgmt-ip/--role`；新增 `docs/實作-多節點擴展.md`（星型聚合/端口分配/fabric 配對/加節點）
- [x] ✅ 加設計假設「**vLLM 喺 Docker container 入面行**」→ 記落 `00-總覽` Assumptions + `狀態-07` container 偵測段 + README/config
- [x] ✅ 開始累積設計 **SPEC**：`docs/SPEC.md` = 單一 source of truth（目標/Assumptions 註冊表 ASM-xx/需求/架構/資料SPEC/API/deploy/開放決定/變更記錄）——之後每加規格/假設都 append 落去
- [x] ✅ 加「**性能收集**」(ASM-14)：新增 `docs/狀態-08-性能.md`（推理 tok/s/latency/P95/RPS + 系統 net/disk/util；窗 10–60s 度率）+ SPEC/索引更新
- ✅ 全部候選收集 items research 完成（A1-A3✅ / B1-B5✅ / C1-C4✅ / D1-D4✅ / E1-E2✅ / F1-F2✅）→ 整合入 SPEC ASM-16/17/19 + `狀態-10..13`
- ✅ vLLM job queue + on-the-fly 管理（R7）完成 → ASM-18 + `狀態-11`（+ 開放決定 OD-4）
- ⏸️ 等用戶 review：SPEC §8 開放決定 OD-1..4（儲存/API 方法 + vLLM 控制模式）→ 照 spark-mon schema + sparktop snapshot 寫 N-node-aware collectors

> 🔑 研究重點結論（實作前必讀）：
> - **DCGM / dcgm-exporter / dcgmi 喺 GB10 唔支援**（官方無計畫）→ ❌ 唔實作硬體時的 DCGM 對接
> - **記憶體監測用 `/proc/meminfo`（MemAvailable+SwapFree）+ `free -h`**，唔靠 nvidia-smi
> - **tegrastats / jtop 唔可靠**（DGX OS 唔含 tegrastats）
> - vLLM 狀態正路 = `:8000/metrics` + `/health` + `/v1/models`
> - fabric 用 `ethtool -S` + `/sys/class/infiniband/*/hw_counters/`（4-byte ×4）

---

## 階段 1 — 狀態收集器（collectors）

### 硬體
- [ ] `collectors/hardware.py`：nvidia-smi query-gpu（util/temp/power/clocks/name/driver/pstate，**避開 N/A 記憶體欄位**）
- [ ] `collectors/hardware.py`：記憶體用 `/proc/meminfo`（MemTotal/MemAvailable/SwapFree）+ `free -h`（UMA 正確讀法）；另有 `--query-compute-apps=used_memory`（每 process）
- [ ] `collectors/hardware.py`：per-process GPU 記憶體（nvidia-smi compute-apps）
- [ ] `collectors/hardware.py`：溫度（/sys/class/thermal tj_max/gpu/soc + sensors）
- [ ] `collectors/hardware.py`：功率（nvidia-smi power.draw/limit；可選 spark_hwmon 整機 rails）
- [ ] `collectors/hardware.py`：GPU throttling 偵測（clocks.sm < 0.45×max.sm 而 util高）
- [ ] （❌ 唔做）DCGM/dcgm-exporter/tegrastats/jtop —— 官方唔支援
- [ ] 統一「硬體」輸出 schema（Pydantic）

### 系統 / 軟體
- [ ] `collectors/system.py`：CPU（lscpu/core、/proc/stat、loadavg）
- [ ] `collectors/system.py`：記憶體（/proc/meminfo、free -h）
- [ ] `collectors/system.py`：磁碟（df、NVMe smart-log、smartctl、iostat）
- [ ] `collectors/system.py`：溫度（/sys/class/thermal、sensors）
- [ ] `collectors/services.py`：systemd（vllm/docker/dcgm-exporter/sshd is-active）
- [ ] `collectors/services.py`：Docker `docker ps`
- [ ] `collectors/services.py`：process 檢查（pgrep vllm/python）+ 端口偵測（ss/lsof :8000）
- [ ] `collectors/system.py`：OS 版本 / kernel / uptime

### 網絡 / Fabric
- [ ] `collectors/network.py`：eth0/接口速率及流量（ethtool -S、ip -s link）
- [ ] `collectors/network.py`：ConnectX-7 / RDMA telemetry（ibstat、rdma link、mlx5 計數器）
- [ ] 兩節點 fabric link 狀態（200G）

### vLLM
- [ ] `collectors/vllm.py`：`GET /health`
- [ ] `collectors/vllm.py`：`GET /metrics`（Prometheus）parse → 關鍵指標
- [ ] `collectors/vllm.py`：`GET /v1/models`（已載入 models）
- [ ] vLLM 指標抽「健康 + 繁忙度」摘要（running/waiting/KV cache/throughput）

---

## 階段 2 — API 層（⚠️ **等用戶決定儲存/API 方式**）

- ⏸️ 決定用咩方法儲存 / 攞資料去 API（用戶話畀我知）
  - [ ] 選項 A：FastAPI 即時 REST 回 JSON
  - [ ] 選項 B：Prometheus exporter pattern（/metrics 被 scrape）
  - [ ] 選項 C：內建 Prometheus + Grafana dashboard
  - [ ] 選項 D：WebSocket/SSE 推送 vs HTTP polling
  - [ ] 快取層（幾秒 cache → 避免每次撈原始指令）
  - [ ] 認證/安全（遠端存取，token/API key）
- [ ] `src/main.py` API 入口
- [ ] `src/api/` routes（`/status`、`/health`、`/metrics`、`/vllm`、`/hardware`...）
- [ ] `src/schemas/` Pydantic 狀態模型
- [ ] `config/config.yaml`：節點列表 + collector 開關 + 輪詢間隔 + 端口

---

## 階段 3 — 集群（2 節點）

- [ ] 2 節點 aggregation（一個 API server 對 local + 另一節點，或每節點一 port）
- [ ] 節點角色 / 顯示兩節點
- [ ] 節點之間 fabric 連通性偵測

---

## 階段 4 — 部署準備（本機只備份內容，唔裝）

- [ ] `scripts/install.sh`：DGX 上安裝依賴 + 起服務
- [ ] systemd unit（`dgx-status-api.service`）模板
- [ ] 或 Dockerfile / compose
- [ ] `requirements.txt` / `pyproject.toml`
- [ ] 排程：監測落實（如用 Prometheus scrape config）

---

## 階段 5 — 測試 / 文件

- [ ] unit tests（collectors 輸入 parsing，可用 mock 輸出）
- [ ] README 使用說明（另一部機點 call API）
- [ ] API 文件 / example curl

---

## 階段 6 — 遷移至 DGX（⚠️ 由用戶喺 DGX 執行，我唔喺 DGX 上做）

- [ ] 內容搬去 DGX 兩部
- [ ] 喺 DGX 照 `scripts/install.sh` 安裝
- [ ] DGX 上實測 + 驗收

---

## 📝 用戶可自行添加區（新增 item 加喺下面）

- [ ] _（例如：做個兩節點 unified dashboard、加告警、加歷史儲存…）_
