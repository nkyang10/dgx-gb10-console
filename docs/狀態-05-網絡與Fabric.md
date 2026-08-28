# 狀態-05 · 網絡 / Fabric（每節點）

> collector：`collectors/network.py` ｜ 優先級：⭐必備（cluster 重點）
> ⚠️ **最關鍵**：`/proc/net/dev` 睇唔到 RoCE/RDMA 流量（NCCL bypass kernel）→ 一定要讀 HCA 硬件 counters。

---

## 物理拓撲（已確認）

- **10GbE RJ-45**：一般/oob 網絡（`enp2s0`/`enp3s0` 系）——**管理/aggregator 用呢條，唔係 fabric**
- **ConnectX-7 200Gbps**：fabric。⚠️ GB10 SoC 只有 PCIe Gen5 x4/device → NVIDIA 用 **ConnectX-7 Multi-Host 模式** bond 兩個 x4（各 100G）做一個 200G physical port → OS 顯示 **4 個接口**（2 port × 2 root complex）：
  - `enp1s0f0np0` + `enP2p1s0f0np0`（port 1）；`enp1s0f1np1` + `enP2p1s0f1np1`（port 2）
- **GPU Direct RDMA 唔支援**；兩節點間 fabric 常接做 `bond0`（`balance-xor`，單條 DAC/QSA-28）

---

## 讀法

| 資料 | 點攞 | 用途 |
|---|---|---|
| TCP/netdev 流量（平） | `/proc/net/dev`（rx/tx bytes field 0,8）delta | kernel-only 流量 |
| 接口狀態 | `/sys/class/net/*/carrier`、`operstate`、`ethtool <iface>`（speed `100000Mb/s`=200G）、`ip -o -4 addr` | link up? |
| Link counter（慢 tier） | `ethtool -S <iface>`：mlx5 `rx_packets_phy`、`rx_crc_errors_phy`、pause | errors/hw |
| **RDMA/RoCE 設備** | `ibstat`（ibtools）/ `ibv_devinfo`（rdma-core）/ `rdma link show` / `rdma device` | `state=="ACTIVE"`、`phys_state=="Up"`、rate(200G) |
| **RDMA 流量（fabric 真源）** | `/sys/class/infiniband/<hca>/ports/<n>/counters/{port_rcv_data,port_xmit_data}`（**×4 bytes**）＋ `.../hw_counters/`（CNP/ECN/discards/retries）│ ethtool `vport_rdma_unicast_bytes` | RoCE/rDMA bytes |

> 💡 **RDMA throughput source of truth**（sparktop）：prefer `ethtool -S` `rx/tx_vport_rdma_unicast_bytes`；fallback IB `counters/port_rcv_data` ×4（IB words 4-octet）。
> ⚠️ `ethtool -S` hw counter group 每次 **trap 入 NIC firmware**（1–50ms）→ 只慢 tier 30–60s + cache，唔好狂打。
> 🟢 Prometheus：`yuuki/rdma_exporter`（`rdma_port_octets`）。

**PCIe 有效頻寬（可選）**：`current_link_speed/width` → `pcieThroughputGbps = GT/s × lanes × encoding × 0.8 TLP` ⇒ Gen5×4 ≈ 100Gb/s（capacity 唔好信 200G 廣告值）。

---

## ✅ 建議收（每節點）

- netdev TCP `rxBps/txBps`（fast，平）⭐
- 接口 `carrier/operstate/speed/MAC`、fabric link `state/physState/rate` ⭐
- **RDMA per-link** `rdmaRx/TxBytes`（ethtool vport prefer，fallback ×4）⭐
- `ethtool -S` mlx5 counters（slow tier）＋ fabric error counters（`portRcvErrors`、`linkDowned`、CNP/ECN、discards）🟡
- fabric link pairing（A-tx≈B-rx, `CONFIRM_RATIO`），`effectiveRateGbps = min(rate, pcie)` 🟡

## 🚨 相關警報

- **ConnectXLinkDown**：`phys_state != 1/Up`；**RDMADead**：`port_state != 4(ACTIVE)` — crit
- **Fabric faults**：RDMA error counters delta > 0（`linkDowned`、`symbolErrors`、`portRcvErrors`）
- PCIe link downtrain to gen1-under-load = power-safety fault（3+ consecutive busy samples 先 flag）
