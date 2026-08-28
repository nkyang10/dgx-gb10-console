# 狀態-07 · vLLM（行緊嘅 software）

> collector：`collectors/vllm.py` ｜ 優先級：⭐必備
> **Assumption：vLLM 喺 Docker container 入面行**（Docker + NVIDIA Container Toolkit，DGX OS 內建）—— 用 `docker ps` 偵測容器 + 攞 publish port，再 HTTP 撈。
> 來源：vLLM source（v0.20.1/0.22.1）+ NVIDIA 官方 playbook + sparkscope/sparktop/sparkdash 實作。

> ⚠️ **2026：vLLM 引擎已 Rust rewrite**（`vllm/engine/metrics.py` 喺 `main` 冇咗；metrics 搬去 `rust/src/metrics/`）。影響你個 collector 嘅**關鍵修正**（final verify @SHA c01b50）：
> 1. **counter 唔再用 `_total` 尾**（Rust `prometheus_client` crate 自動省略 `_total`）→ 現代名 `vllm:prompt_tokens`、`vllm:generation_tokens`、`vllm:request_success`。
> 2. **`vllm:engine_sleep_state` metric 已移除** → 改用 **`GET /is_sleeping` → `{"is_sleeping":bool}`**（＋ `/is_paused` → `{"is_paused":bool}`）判 idle vs asleep。
> 3. **`--enable-per-request-metrics` 冇咗** → 取代係 **`--per-request-spec-decode-metrics {none|summary|detailed}`**（spec-decode acceptance，n==1 only）。`--enable-log-requests` 仲喺度（default off）。
> 4. label **`engine_name`(str) → `engine`(u32 index)**；grouping 用 `{model_name, engine}`。
> 5. 新 flags：`--kv-cache-metrics`+(`--kv-cache-metrics-sample`) → `kv_block_lifetime_*`；`--cudagraph-metrics`、`--enable-mfu-metrics`、`--show-hidden-metrics-for-version`（escape hatch 恢復 hidden metric）。
> 6. 新 histogram：`request_inference/prefill/decode_time_seconds`、`request_time_per_output_token_seconds`、`http_request_duration_seconds`。
> 7. `/load` → `{"server_load": ...}`（structured）；/health 200=healthy、503=EngineDeadError，**render-only server 永遠 200**。
>
> **版本分界**：現代 vLLM（Rust, ~2026）= 上面；舊 Python ≤0.8 era = legacy（`_total` 尾、`engine_name`、有 `engine_sleep_state` metric）。**實作時要 detect 版本（`/version`）先對 metric 名。**

---

## 0. vLLM container 偵測（Assumption 對應做法）

```bash
# sparkscope 做法：用 Docker socket 自動偵測 vLLM container + publish 出嚟嘅 port
docker ps --filter name=vllm                       # ⚠️ -> container 有冇 in running state
# 攞 publish port（host 側：<hostIP>:<port>-><containerPort>）
docker port <vllm-container> 8000                   # 例: 8000/tcp -> 0.0.0.0:8000
# 然後喺節點上撈（container publish 咗, host 可 localhost:port / mgmt_ip:port）：
curl -s http://localhost:<port>/v1/models
curl -s http://localhost:<port>/metrics
```

- **「vLLM 真係 run 緊」最強信號 = `docker ps` 個 container 係 running + `curl :<port>/v1/models` 通**（container 可以 active 但 engine dead）。
- Docker compose 部署：`-p <host>:8000:8000`、`ipc: host`、`shm_size 2gb`、GPU `capabilities:[gpu]`、healthcheck 打 `/health`。
- 同一節點行多個 vLLM server → 唔同 host port（`nodes[].vllm_port` 記；[實作-多節點擴展](實作-多節點擴展.md)）。
- 想睇 container CPU/RAM/restart：`docker stats --no-stream` / `docker inspect`（可選）。

---

## 3.1 HTTP endpoints（`vllm serve`，預設 port **8000**，`--host` 預設綁 0.0.0.0 可遠端）

| Endpoint | 方法 | 返回 |
|---|---|---|
| `/health` | GET | HTTP `200` **空 body**（健康）；`503`（EngineDeadError）。**readiness check 正路** |
| `/metrics` | GET | **Prometheus text**（`Content-Type: text/plain; version=0.0.4`）。**冇** `/openmetrics`、**冇** `?format=` |
| `/version` | GET | `{"version":"0.11.x"}` |
| `/load` | GET | `{"server_load":{...}}`（要 `--enable-server-load-tracking`） |
| `/server_info` | GET | `{vllm_config,vllm_env,system_env}` — **DEV only**（`VLLM_SERVER_DEV_MODE=1`） |
| `/v1/models` | GET | OpenAI `ModelList` `{"data":[<ModelCard>...]}`，"已 load 咩 model" 最直接判斷 |
| `/tokenizer_info` | GET | tokenizer/chat-template（`--enable-tokenizer-info-endpoint`） |
| `/docs`, `/openapi.json` | GET | Swagger/OpenAPI（可 `--disable-fastapi-docs` 關） |

**exact curl**
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://<host>:8000/health     # 200 健康 / 503 死
curl -s http://<host>:8000/metrics                                      # 全 Prometheus
curl -s http://<host>:8000/v1/models | jq .                             # loaded models
curl -s http://<host>:8000/version
curl -s http://<host>:8000/metrics | grep -E '^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|num_preemptions)\b'
```

---

## 3.2 完整 status-metrics 表（vLLM `main` 版本，經 source 驗證）

> ⚠️ **版本敏感**：V1 重構後部分改名。下表係 current `main`；舊版/NGC 26.05 pin 嘅 vLLM 0.11.x 出 legacy 名。**實作時探測實際版本**。

**Server / scheduler（Gauge）**
| Metric | 意義 |
|---|---|
| `vllm:num_requests_running` | RUNNING batches 內 request |
| `vllm:num_requests_waiting` | WAITING queue 內 request |
| `vllm:num_requests_waiting_by_reason` | 按原因：`capacity`/`deferred` |
| `vllm:engine_sleep_state` | 引擎 sleep（awake/sleeping/weights_offloaded/discard_all）—— **DGX 重點** |
| `vllm:kv_cache_usage_perc` | KV-cache 用率 0–1（⚠️ legacy `vllm:gpu_cache_usage_perc`） |
| `vllm:cache_config_info` | CacheConfig labels（Info-style，讀 labels 唔理 value） |

**吞吐 / 計數（Counter）**
| Metric | 意義 |
|---|---|
| `vllm:num_preemptions` | 累計 preemption |
| `vllm:prompt_tokens` | 累計 prefill tokens（legacy `prompt_tokens_total`） |
| `vllm:prompt_tokens_by_source` / `_cached` | 按來源 / cached |
| `vllm:generation_tokens` | 累計生成 tokens（legacy `generation_tokens_total`） |
| `vllm:prefix_cache_queries` / `_hits` | prefix-cache hit rate = rate(hits)/rate(queries) |
| `vllm:request_success` | 完成 request（by `finished_reason`）（legacy `request_success_total`） |

**Request SLO（Histogram）**
| Metric | 意義 |
|---|---|
| `vllm:time_to_first_token_seconds` | **TTFT** latency |
| `vllm:inter_token_latency_seconds` | inter-token latency（TPOT） |
| `vllm:request_time_per_output_token_seconds` | TPOT/request（legacy `time_per_output_token_seconds`） |
| `vllm:e2e_request_latency_seconds` | 端到端 latency |
| `vllm:request_queue/inference/prefill/decode_time_seconds` | 各 phase 時間 |
| `vllm:request_prompt_tokens` / `request_generation_tokens` | 每 request 輸入/輸出 |
| `vllm:kv_block_lifetime/idle_before_evict/reuse_gap_seconds` | KV 區塊生命週期 |

**另外**：HTTP `http_requests_total{handler,method,status}`、`http_request_duration_seconds`；Python/process `process_cpu_seconds_total`、`process_resident_memory_bytes`（`--api-server-count>1` 時冇）。**唔存在**：`vllm:num_requests_swapped`（V1 無 SWAPPED）、Ray metrics（只喺 Ray dashboard :8265）。

---

## 版本 pin（NGC tag → vLLM）

| NGC tag | vLLM | era |
|---|---|---|
| `nvcr.io/nvidia/vllm:26.04-py3` | 0.19.0 | modern V1 |
| `nvcr.io/nvidia/vllm:26.05-py3` | **0.20.1** | modern V1 |
| `nvcr.io/nvidia/vllm:26.06-py3` | **0.22.1** | modern V1（同 0.20.1 同名 set） |
| ≤0.11.x | 0.11.x | legacy |

**舊→新對照（collector normalize 用）**：`prompt_tokens_total→prompt_tokens`、`generation_tokens_total→generation_tokens`、`request_success_total→request_success`、`num_preemptions_total→num_preemptions`、`gpu_cache_usage_perc→kv_cache_usage_perc`、`time_per_output_token_seconds→request_time_per_output_token_seconds`。
**穩定名（兩 era 一樣）**：`num_requests_running/waiting`、`request_queue_time_seconds`、`time_to_first_token_seconds`、`inter_token_latency_seconds`、`e2e_request_latency_seconds`。
所有 metric 有 `model_name` label = per-engine 過濾鍵。

---

## Python 解析（`prometheus_client` 一定可用——vLLM hard-pin ≥0.18）

```python
import requests
from prometheus_client.parser import text_string_to_metric_families

def scrape(url, timeout=5.0):
    txt = requests.get(url, timeout=timeout).text
    return [{"metric": f.name, "type": f.type,
             "samples": [{"name": s.name, "labels": dict(s.labels), "value": s.value}
                          for s in f.samples]}
            for f in text_string_to_metric_families(txt) if f.name.startswith("vllm")]
```
- **Counter** → 記 prev value+ts，`rate=(cur−prev)/(t−t_prev)`；**reset（cur<prev）→ rate=0 + re-baseline**
- **Histogram** → latency 平均 = `_sum/_count`（rolling 窗）；P95 要 `_bucket`+`histogram_quantile`
- `vllm:cache_config_info` 係 Info-style（value=1，意義喺 labels）
- regex fallback 可用！（若環境冇 prometheus_client）
- **scrape 10–15s**；rate window ~5m

---

## Failure 語義（/health vs /metrics vs /v1/models）

| Probe | 結果 | 意思 | 動作 |
|---|---|---|---|
| `/health` 200（空）+`/metrics` 200 | alive & serving | parse，status=UP |
| `/health` 200 +`/metrics` 404/timeout | API up 但 prometheus 冇/忙 | retry，degrade 只攞 gauges，log warning |
| `/health` 503 | **EngineDeadError（死咗）** | mark DOWN，停 scrape，可 restart |
| conn refused/timeout 兩個 | process/container 冇咗 | mark DOWN |
| `/v1/models` 200 但 `/metrics` 404 | port 係 SGLang/TRT-LLM 等其他引擎 | 唔當 vLLM fail |
| **healthy-but-idle vs asleep vs dead** | `/health` 分唔到 | 用 **`vllm:engine_sleep_state`**（awake/weights_offloaded/discard_all）；⚠️ DGX 有 sleep→wake_up crash EngineCore bug | 

> per-endpoint timeout 3–5s + consecutive-failure counter 先宣告 DOWN（避免 flap）。

---

## 遠端 + dual-node

```bash
NODE_IP=192.168.1.10
curl -s http://$NODE_IP:8000/health; curl -s http://$NODE_IP:8000/v1/models | jq '.data[].id'
curl -s http://$NODE_IP:8000/metrics | grep -E '^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|num_preemptions)\{'
```

**兩種官方部署形態**：
1. **跨兩節點單 server**（大 model）：Ray，`--tensor-parallel-size 2 --distributed-executor-backend ray`，API 只喺 Node1 :8000（metrics 撈 Node1；Ray dashboard :8265 要 ssh -L）
2. **兩套獨立 single-TP**：每節點 `--tensor-parallel-size 1 --host 0.0.0.0 --port <8000|8001>` → **用唔同端口** 分開撈

**Docker**：`-p 8000:8000`；compose 用 `ipc: host`、`shm_size 2gb`、GPU `capabilities:[gpu]`、healthcheck 打 `/health`。
**DGX 貼士**：設 `CUDA_MANAGED_FORCE_DEVICE_ALLOC=1`、`PYTORCH_ALLOC_CONF=expandable_segments:True`、`--gpu-memory-utilization 0.7–0.9`。

---

## ✅ NVIDIA 推薦監測 + 被低估

- NVIDIA 推薦：TTFT、TPOT、e2e latency、throughput（`prompt/generation_tokens` rate）、`num_preemptions`、`kv_cache_usage_perc`、memory headroom
- **被低估但有價值**：`engine_sleep_state`（DGX）、prefix-cache hit rate、`kv_block_lifetime`、`waiting_by_reason`、`corrupted_requests`、`prompt_tokens_cached`

## 🚨 相關警報

- **VllmEngineDead**：`probe_success==0`（health 200 係 alive）
- **VllmAsleep**（可選）：`engine_sleep_state` = weights_offloaded/discard_all + 唔好誤報 unhealthy
