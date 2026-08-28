# 狀態-02 · CPU 與 記憶體（每節點）

> collector：`collectors/system.py` ｜ 優先級：⭐必備
> ⚠️ **RAM 喺 DGX Spark = GPU 可用記憶體（UMA）** —— `/proc/meminfo` 先係真源。

---

## 指令

```bash
lscpu                    # ARM aarch64、20-core（10×Cortex-X925 P + 10×Cortex-A725 E，big.LITTLE）
free -h
cat /proc/meminfo        # MemTotal / MemAvailable / SwapFree / HugePages
cat /proc/stat           # 每 core / 負載
cat /proc/loadavg        # 1min/5min/15min
cat /proc/uptime         # uptime + idle
cat /proc/pressure/memory  # PSI（可選，anomaly）
```

---

## CPU

| 資料 | 點攞 | 單位 |
|---|---|---|
| CPU usage（per-core + 總） | `/proc/stat` delta：`busy = 1 − idle_jiffy/Δtotal ×100`，對每個 cpuN | % |
| loadavg 1/5/15 | `/proc/loadavg` | — |
| CPU 頻率 | `scaling_cur_freq`（`/sys/devices/system/cpu/cpu*/cpufreq/`）取 active core 最大 | MHz |
| 核心數 | `nproc` / `lscpu`（20-core big.LITTLE） | — |
| uptime | `/proc/uptime` / `uptime` | s |
| PSI 記憶體壓力 | `/proc/pressure/memory` `avg10 some`、`full` | — |

> ⚠️ 只用 **memory PSI**；**IO PSI 喺 vLLM idle 會 false-CRITICAL**（sparkview changelog 確認）→ 唔好用 IO PSI。

---

## 記憶體（UMA = GPU pool）

⚠️ **GPU 可用記憶體 = 系統記憶體**。官方指引：`MemAvailable + SwapFree`（CPU 可把 DRAM swap 走）。

| 資料 | 點攞 | 單位 |
|---|---|---|
| total | `/proc/meminfo MemTotal` | bytes |
| available | `/proc/meminfo MemAvailable` | bytes |
| used | `= MemTotal − MemAvailable`（sparkview 做法） | bytes |
| swap total/free | `/proc/meminfo SwapTotal/SwapFree` | bytes |
| HugePages（vLLM KV cache） | `/proc/meminfo HugePages_Total/Free` | pages |

🟢 **確認主做法**（sparkview/sparktop/sparkscope/spark-mon/observability 一致）：`used=FREE=MemTotal−MemAvailable`；`/proc/meminfo` 直接讀（唔好 `free` buffers 算術，HugePages 會誤導）。

⚠️ 唔好用 `cudaMemGetInfo()`（回報偏細）；唔好信 NVML total（會報 ≈MemTotal 誤導）。

---

## ✅ 建議收（每節點，fast tier）

- `cpu.usage_pct`（per-core + 總）、`cpu.load_1m/5m/15m`、`cpu.freq_mhz`(可選)、`memory.total_kb`/`available_kb`/`used_pct`/`swap`
- PSI memory（可選，anomaly logger gate）

## 🚨 相關警報

- **HostMemoryHigh/Critical**：`(MemTotal−MemAvailable)/MemTotal > 0.85`（15m/warn）/ `>0.95`（5m/crit）+ swap 重度用
- 高 context switches：`rate(node_context_switches_total[1m]) > 100000`（可選）
