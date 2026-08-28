# 狀態-01 · GPU（每節點）

> collector：`collectors/hardware.py` ｜ 優先級：⭐必備
> ⚠️ 此類係 DGX Spark 最特殊嘅類 —— **UMA 統一記憶體**令所有 VRAM/metrics 相關做法同一般 GPU 唔同。

---

## 1.1 主力：nvidia-smi / NVML

**通用指令**
```bash
nvidia-smi --query-gpu=FIELD,... --format=csv,noheader,nounits
nvidia-smi dmon    # 連續監測
nvidia-smi pmon    # 每 process
nvidia-smi -L      # 列出 GPU
```

**各 query-gpu 字段喺 GB10 上可信度**（官方 Known Issues + 社群實測 + 10 repo）：

| 字段 | 狀態 | 說明 |
|---|---|---|
| `name` | ✅ | "NVIDIA GB10" |
| `driver_version` | ✅ | 如 **580.159.03**（DGX OS 7.5.0 / CUDA 13.0.2，2026-07） |

> **2026 更新（final verify）**：
> - **SW stack**（2026-07 版本）：DGX OS **7.5.0**・GPU driver **580.159.03**・CUDA **13.0.2**・Kernel 6.17・EC 3.5.8。
> - **pynvml pin**：`nvidia-ml-py` 最新 13.610.43（NYML 13.x）；**喺 driver 580 上用 `13.580` line**（NVML ABI 要 match driver），唔好盲裝最新。
> - **`nvidia-smi soc`（v590+）係 Tegra-Linux only → 唔喺 DGX OS 用**（CPU/SoC power 唔靠佢）。
> - **power_smoothing.\*（v570+）設計畀 rack DGX/GB200 → 單 GB10 報 N/A**，唔收，只 detect-if-available。
> - DGX Dashboard UMA 記憶體 bug **已喺 2026 R580-era fix**（memory 而家 CUDA-consistent）→ `dashboard.memory_*` 可當 trustworthy 次要源。
| `pstate` | ✅ | P0..P8 效能狀態 |
| `persistence_mode` | ✅ | |
| `utilization.gpu` | ✅ | SM 利用率 % |
| `utilization.memory` | ⚠️ 報 0 | UMA 無獨立記憶體控制器，**不可信** |
| `temperature.gpu` | ✅ | GPU 核心 °C |
| `temperature.memory` | ⚠️ N/A | 無離散感測器 |
| `power.draw` | ✅ | GPU 功耗 W（idle 實測 ~4.5W） |
| `power.limit` | ✅ | 功耗上限 |
| `clocks.sm` / `clocks.graphics` | ✅ | 頻率（正常滿載 ~2400MHz；**被 throttled <850MHz**） |
| `clocks.mem` | ⚠️ N/A | UMA 無獨立 memory clock |
| `pcie.link.gen` | ⚠️ N/A | iGPU 無 PCIe link |
| `compute_mode` | ✅ | |
| `fan.speed` | ⚠️ 常 N/A | 風扇由 EC 控制 |
| `memory.used` / `memory.total` / `memory.free` | ❌ **N/A** | **用系統 RAM 代替（§1.2）** |

**唯一 nvidia-smi 可攞到嘅「GPU 記憶體」值 = per-process**
```bash
nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv
# 每 process 嘅 resident unified memory（例 19135MB）—— NVML 內唯一記憶體近似值
```
來源：llama-swap#782、docs.nvidia.com/dgx/dgx-spark/known-issues.html、nvidia.custhelp.com a_id/5775

> 💡 **resident NVML 快徑（唔 spawn）**：`nvidia-ml-py`(pynvml) 直接 call `nvmlDeviceGetUtilizationRates / GetTemperature / GetPowerUsage / GetClockInfo`（50–300µs，無 fork）。`watch nvidia-smi` 每 1s re-spawn 會令 tight inference loop 慢 ~20% → **長駐 NVML reader，唔好 per-tick exec nvidia-smi**（詳見 [實作-收集器設計](實作-收集器設計.md)）。

---

## 1.2 GPU 記憶體（UMA → 正確讀法）

⚠️ **GPU 可用記憶體 = 系統記憶體**。官方指引：用 `/proc/meminfo` 嘅 `MemAvailable + SwapFree` 估可分配 device memory。

```bash
free -h                              # Mem/Swap 用量+總量（128GB）
cat /proc/meminfo                    # MemTotal / MemAvailable / SwapFree / HugePages
nvidia-smi --query-compute-apps=...  # (§1.1) 每 process GPU 用量
```

**確認嘅 UMA 做法**（sparktop / sparkDash / observability / nv-monitor / 10 repo 一致）：
- `vramTotalBytes` = NVML `memory.total` ??（N/A 時）=`/proc/meminfo MemTotal`
- `vramUsedBytes`  = NVML `memory.used` ??（N/A 時）=Σ `--query-compute-apps=used_memory`
- `vramFreeBytes`  = MemAvailable
- 要加 **`vramUsedIsDerived`** flag（因為係 derived，唔係直接讀）

⚠️ 唔好用 `cudaMemGetInfo()`（回報偏細）／唔好信 NVML `total`（會報 ≈MemTotal 121GB 誤導）。

---

## 1.3 ❌ 唔可用嘅：DCGM / tegrastats / jtop

- **DCGM / dcgm-exporter / dcgmi**：❌ 官方「no plans to support DCGM on Spark」→ exporter 靜默失敗，`DCGM_FI_DEV_FB_*`/NVLINK/ECC/XID 多數無實值。**唔好實作**。
- **XID / ECC**：依賴 framebuffer 計數 → UMA iGPU 唔支援。替代健康信號 = nvidia-smi 回報正常 + `dmesg` + **感知器存活 flag**。
- **tegrastats**：❌ 唔預載喺 DGX OS（JetPack/Jetson 專用）。
- **jtop / jetson-stats**：依賴 tegrastats → 唔可靠。
- ⚠️ 例外：ECC `ecc.errors.corrected/uncorrected.volatile.total` 喺 sparkscope parse 到 int（health 用，可選）。

---

## 1.4 DGX Dashboard（官方 UMA / GPU subscribe）

- 內置喺 DGX OS，綁 `http://127.0.0.1:11000`；**SSE `POST /api/login` → Bearer token → `GET /api/v1/gpu_telemetry/stream`**。
- SSE 內容（每 GPU 3 field）：`percentage_utilization`、`memory_total_in_mb`、`memory_available_in_mb`（UMA）。
- ⚠️ stream 好「薄」、官方認咗有 memory-reporting bug、API 無對外保證（internal，可能 drift）、login 用**系統 sudo account** → token 存 env/vault。
- **定位**：做「GPU util + UMA」嘅官方 primary 補充源（可選），主力仍係 nvidia-smi + /proc。
- curl 詳見 [00-總覽](00-總覽.md) §5 ／ 逆向報告喺研究記錄。

---

## ✅ 建議收（每節點，fast tier）

`name`、`driver_version`、`pstate`、`utilization.gpu`、`temperature.gpu`、`power.draw`、`power.limit`、`clocks.sm`/`clocks.graphics`、`clocks.max.sm`、`clocks_throttle_reasons.active`（underscore，bitmask）、`--query-compute-apps=used_memory`（每 process）＋ `vramUsedIsDerived` flag（UMA）。

## 🚨 相關警報（GPU）

- **GpuTempCritical**：`temp > 80`，`for:2m`（GB10 throttle line 96–97°C）
- **GpuThermalThrottle**：`throttle_active==1`，`for:5m`
- **SMClockCollapse**（USB-C PD 供電故障）：`sm_clock/sm_clock_max < 0.45` AND util>50% AND power<35W AND throttle_reasons==0（hysteresis on≥55%/off<45%），`for:2m` — **crit**
- **GpuMemoryHigh**：`(Σcompute-apps / MemTotal) > 0.90`，`for:10m`
