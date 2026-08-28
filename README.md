# DGX Status API

HTTP API 畀另一部機攞取 **N 部 DGX Spark（GB10 Grace Blackwell）cluster**（2 部即基本部署）狀態。

- **硬體狀態**：GPU/CPU/記憶體(RAM)/溫度/功耗/時脈/util
- **軟體系統狀態**：OS、systemd 服務、Docker、process、記憶體、磁碟、網絡/fabric
- **vLLM 狀態**：running/waiting requests、KV cache 用率、throughput、health、已載入 models

架構：**一部 aggregator 拉晒 `nodes[]` 其餘（星型）**，支援 N 節點（詳見 `docs/實作-多節點擴展.md`）。

**Assumption：vLLM 喺 Docker container 入面行**（Docker + NVIDIA Container Toolkit）——用 `docker ps` 偵測 + 攞 publish port 再撈。

## 狀態
- ✅ **Phase 0 — 研究**（完成）：4+5+10 條平行研究 thread，已整合並**按 data category 分拆**每類一個 MD（`docs/狀態-*.md`）
- 🏗️ Phase 1 + — 已備好部署產物（deploy/config/scripts），等用戶定「儲存/API 呈現方式」後落 code
- 📋 完整待辦：見 [TODO.md](./TODO.md)

## Project 結構

```
dgx-status-api/
├── README.md                    # 本檔：結構總覽
├── TODO.md                      # 待辦清單（可持續加 item）
├── docs/
│   ├── 00-總覽.md                # ⭐ 索引 + Assumptions + API 架構 + 來源
│   ├── SPEC.md                  # ⭐⭐ 設計 SPEC + Assumptions 註冊表 + 變更記錄（單一 source of truth）
│   ├── 狀態-01-GPU.md            # 每個 data category 一個檔（寫 collector 直接睇）
│   ├── 狀態-02-CPU與記憶體.md
│   ├── 狀態-03-溫度與功率.md
│   ├── 狀態-04-儲存磁碟.md
│   ├── 狀態-05-網絡與Fabric.md
│   ├── 狀態-06-軟體與服務.md
│   ├── 狀態-07-vLLM.md
│   ├── 狀態-08-性能.md            # 推理吞吐/延遲 + 系統性能
│   ├── 狀態-09-熱控制與降頻.md     # 過熱降頻觀測矩陣
│   ├── 狀態-10-成本與容量.md       # 能量/成本 + Token 會計 + 容量預測
│   ├── 狀態-11-vLLM-隊列與管理.md  # vLLM 隊列觀看 + on-the-fly 管理
│   ├── 狀態-12-深觀察與基準.md     # vLLM 深觀察 + 主動基準(Only maintenance)
│   ├── 狀態-13-可靠與安全.md       # NVMe/container/Kernel + RDMA/PCIe + security
│   ├── 實作-收集器設計.md          # 效能/常駐/snapshot/聚合
│   ├── 實作-架構分層圖.md          # ⭐ 分層/parallel/exposure review
│   ├── 實作-多節點擴展.md          # ⭐ N 節點 cluster
│   ├── 實作-部署與安全.md          # 部署/認證/歷史/監控Alert
│   ├── 資料收集決定.md             # 「收咩數據」決策清單 + alert
│   └── references/              # 完整研究報告
│       ├── 硬件-研究報告.md
│       ├── GitHub-生態研究報告.md
│       └── 安全-監控-alert.md
├── config/
│   └── config.yaml              # 2 節點 aggregator/exporter 設定
├── src/
│   ├── main.py                  # FastAPI / API 入口（待定方案）
│   ├── collectors/              # hardware / system / network / services / vllm
│   ├── schemas/                 # Pydantic 狀態模型（JSON 結構）
│   └── api/                     # API routes / 集群 aggregation
├── deploy/                      # 部署產物（研究 R4 已備）
│   ├── dgx-status-exporter.service   # systemd unit（hardened）
│   ├── Dockerfile / docker-compose.yml
│   └── status.env.example       # token/port/role 設定範本
├── scripts/
│   └── install.sh               # 冪等安裝（由用戶搬去 DGX 執行）
├── prometheus/                  # 如用 Prometheus scrape 設定
├── tests/                       # unit tests（本地可跑，非 DGX）
└── requirements.txt
```

> ⚠️ 本機只負責**準備 project 內容**，唔裝唔 test。完成後「搬」去 DGX 安裝。

## Algorithm / 設計決策待定
見 `TODO.md` 嘅 **Phase 2**（用戶尚未決定儲存/API 呈現方式）。
