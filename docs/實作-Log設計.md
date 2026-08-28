# 實作 · 拎 Log / 睇 Log 功能 — 完整設計

> 目的：畀 Gateway 嘅 **Web 後台 + Agent API** 提供「睇 log / 拎 log」—— 將成個平台所有 software/hardware 嘅 log 統一攞到、**分類、排序、篩選**。
> 對應：SPEC ASM-20（log 睇/拎）+ 實作-部署與安全 §6。Research + 每個源嘅位置/格式/內容已整合。

---

## 1. Log 來源目錄（呢個平台所有 software/hardware 嘅 log）

> 攞法統一：**journald**（systemd/kernel）＋ **docker logs**（容器）＋ 專用檔。全部 read-only。

| # | Source（id） | 位置 | 攞法 | 格式 | 可能內容 |
|---|---|---|---|---|---|
| 1 | **kernel** `kernel` | journald kernel ring | `journalctl -k` | 純文字行 | **OOM**（`Out of memory/Killed process/oom-kill`）、**NVRM/Xid**（`Xid (PCI...): 13/31/41`）、**NVIDIA thermal**（`97.8°C`）、**NVMe**（`nvme0: I/O error` / `No NVMe Device`）、**hung_task**（`task blocked`）、**PMU/PCIe AER**、ACPI/EC |
| 2 | **systemd 服務** `services` | journald | `journalctl -u <unit>` | 純文字／結構化 | docker、containerd、sshd、`nvidia-*`、`dgx-dashboard`、`dgx-status` 自身 —— 每個 service 嘅 startup/error |
| 3 | **Docker/容器** `container:<name>` | docker json-file：`/var/lib/docker/containers/<id>/<id>-json.log` | `docker logs <ctr> --tail N` | **JSON 一匍一行** `{log,stream,time}`（json-file driver） | 每個容器 stdout/stderr；**vllm 容器**尤其是 |
| 4 | **vLLM** `vllm` | vllm 容胞 stdout → `docker logs vllm` | `docker logs <vllm-ctr>` | 行式 + `INFO... WARNING... ERROR...`；`--enable-log-requests` 每 request 一行 | engine 起動（model/GPU/config）、`request_id=... model=... max_tokens=... prompt_tokens=... generation_tokens=...`、OOM/超時、重試、「No available KV-cache」 |
| 5 | **SSH / auth** `ssh` | journald sshd / `/var/log/auth.log` | `journalctl _COMM=sshd` | 行式 | login、`Failed password for ... from <ip>`、key auth、`sudo` |
| 6 | **DGX Dashboard** `dgx-dashboard` | journald unit | `journalctl -u dgx-dashboard`（名待證） | 行式 | UMA/GPU telemetry、update agent、SSE 錯誤 |
| 7 | **NVMe 健康** `nvme` | 唔係 log —— `nvme smart-log` 輸出（D1 已做） | `sudo nvme smart-log`（60s tier） | 表格文字→parse | `critical_warning`、`percentage_used`（wear）、`media_errors`、`temp`（D1 已收） |
| 8 | **Boot / UEFI / EC** `boot` | journald | `journalctl -b`（本次開機）／`-b -1` | 行式 | 開機 kernel、UEFI/EC firmware、`fwupd`（`0x0300` EC bug 起「 fans-silent」）|
| 9 | **Agent API 自身** `api` | journald unit `dgx-status` | `journalctl -u dgx-status` | 行式 | 認證失敗、rate-limit、error、control action audit |

> ⚠️ 未有 `nvidia-bug-report`（offline，按需）；GPU 性能唔係 log（用 metrics）。log 統一由 journald+docker，**唔使裝 agent**。

---

## 2. 分類（Classification Taxonomy）

Log 分 **6 大類**（同時對應「警報/UI 分頁」）:

| Category | 包含 source | 大概用途 |
|---|---|---|
| `os` | kernel, boot | 硬件/內核/OOM 底層出事 |
| `services` | systemd 服務（docker/containerd/sshd/nvidia-*/dgx-status/dgx-dashboard）| 平台服務健康 |
| `container` | 各 docker 容器 | 應用層 |
| `inference`（vLLM）| vllm 容器特化 | ⭐ 推理 runtime/request |
| `security` | ssh, auth, sudo | 攻撃/登入異常 |
| `storage` | nvme, kernel-NVMe | 磁碟/NVMe 健康 |

每條 log 記 `category` + `source` + `node`。

---

## 3. 排序（Sort）

- **預設**：`node` → `source` → `ts`（**desc**，最新行先）。── 因為要跨 N 節點咁睇，先按 node 分組，再按時間。
- 可選 sort 欄：`ts`（time）、`level`（severity）、`source`、`node`、`size`（log 唔適用）。
- 尾追蹤（follow）：`?follow=1&last_ts=` → 返回新行（SSE 推送）。

---

## 4. 篩選（Filter）

| 篩選 | 參數 | 例子 |
|---|---|---|
| 節點 | `node=dgx-01,dgx-02` | 睇特定機 |
| 來源/type | `source=kernel\|vllm\|container:vllm` | 淨睇 kernel 或 vLLM |
| 分類 | `category=os\|inference\|security` | 粗篩 |
| 嚴重度 | `level=err,warn` | journald `-p err`；docker/vllm 行 parse level |
| 時間窗 | `since=2026-08-28T01:00:00Z&until=...` | 出事前後 |
| 關鍵字 | `q=OOM\|Xid\|TaskOver` | `grep -E` |
| 篩容器 | `container=vllm` （source=container 時）| |
| 行數上限 | `lines=500`（≤2000）| 防爆 |
| 輸出格式 | `fmt=text\|json` | JSON 結構化畀 agent |

- **全部 filter 落地喺節點再去 grep**（`journalctl --since --until -p <lvl> | grep -E "$q"`；`docker logs --tail N`），**限時 timeout 3–5s**，防 journalctl 卡。
- 關鍵字唔限大小寫，regex 支援（`grep -E`）；`level` 對 journald `-p`，對 docker/vllm 行做 pattern（`ERROR|WARN|INFO|DEBUG|FATAL`）。

---

## 5. 正規化（→ 結構化 schema）

每條 log 統一成：

```jsonc
{
  "ts": "2026-08-28T01:02:03.004Z",
  "node": "dgx-01",
  "source": "vllm",            // kernel|services|container:<name>|vllm|ssh|...
  "category": "inference",     // os|services|container|inference|security|storage
  "level": "WARN",             // DEBUG|INFO|WARN|ERROR|FATAL（容器/行式靠 pattern 估）
  "message": "the request ... failed after 60.0s",
  "fields": {"request_id": "...", "model": "mistralai/...", "tokens": 1234},  // parse 出嚟（可選）
  "raw": "…原行…"             // 未 parse 時 raw
}
```

- **journald**：`journalctl -o json` 一次過攞 `__REALTIME_TIMESTAMP`+`MESSAGE`+`PRIORITY`+`_SYSTEMD_UNIT`（結構化，最準）。
- **docker/vllm**：`docker logs` 攞行 → 本地 parse `level`+`key=val` fields（vLLM request 行）。
- 保留 `raw` 唔郁，先入 SQLite（歷史）再 search。

---

## 6. API（Agent 用）

```
GET /api/logs                                     # 預設全 cluster，最新 100 行
GET /api/logs?node=dgx-02&source=kernel&level=err&since=...&q=NVMe
GET /api/logs/follow?node=dgx-01&source=vllm      # SSE / 長輪詢 live tail → Web 後台用
GET /api/logs/stats?since=24h                     # 各 category 計數（有冇事一目了然，配合 D3 markers）
GET /api/nodes/{node}/logs/{source}?lines=&since=&filter=   # 單機單源（實作-部署與安全 §6）
```
回應 envelope：`{schema_version, count, node, source, offset, logs:[NormalizedLog], truncated}`。
⚠️ 全部 **auth**（vLLM request log 可含 prompts/tokens；token env；唔 log token）；每請求 timeout。

---

## 7. UI（Web 後台 `/ui` → 頁籤「Logs」）

Router 式後台 —— 一個「Logs」分頁：

```
┌ Logs ──────────────────────────────────────────────┐
│ [node ▾|dgx-01,dgx-02] [category ▾|all] [level ▾|err]│
│ [q: OOM|Xid________ ] [since: 24h ▾] [⏱ live] [⇅]  │   ← 篩選＋排序＋live toggle
│ ─────────────────────────────────────────────────── │
│ 01:02:03 WARN  dgx-02  vllm      request fail 60s... │   ← 每行：time·level色·node·source·msg
│ 01:02:01 ERR   dgx-01  kernel    Xid (PCI...): 41     │   ← 顏色：FATAL/ERR 紅、WARN 橙
│ 01:01:58 INFO  dgx-02  services  docker: requested  …
│ [marker banner: OOM 2 │ Xid 0 │ NVMe-IO 1 │ 24h]     │   ← D3 markers 一角落
└──────────────────────────────────────────────────────┘
```
- 左側：**node × source 樹**（`dgx-01/kernel`、`dgx-02/vllm`…）一撳即濾。
- Live：`/api/logs/follow` SSE 追尾，唔使刷新。
- Level 色：`FATAL/ERR`=紅、`WARN`=陶土橙、`INFO/DEBUG`=灰藍。
- 按行 click → 展開 raw＋fields（JSON）；「Copy」。
- marker banner：`{kernel_oom_24h, xid_24h, nvme_io_24h,...}`（D3 已有）成行睇。

---

## 8. Retention / 安全

- SQLite WAL 存正規化後 log（30d；設定 `storage.retention_days`）；journald 本身 bounded（`SystemMaxUse`）。
- **唔存 vLLM prompt/完整 request body**（只存 parsed `tokens`/`request_id`，唔存 message 內容含 prompt）。
- auth 必備（同 Agent API guard）；admin role 先睇 `security` category。
- 每請求 timeout + 行數上限；proxy 唔好跟嗰個唔見咗任 grep 貴爆。
- 唔 log token／secret；`fields` 過濾敏感 key。

---

## 9. 落 code 對應

- `src/collectors/log.py`：journald/docker 源攞 + parse → NormalizedLog（cache 一批）
- `src/schemas/log.py`：Pydantic `NormalizedLog` / `LogEnvelope`
- `src/api/logs.py`：上面 endpoints（read + follow/SSE + stats）
- `src/ui/`：Logs 頁籤（HTMX/JS，輪詢 + SSE）
