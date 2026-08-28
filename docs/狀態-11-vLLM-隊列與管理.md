# 狀態-11 · vLLM 隊列觀看 & On-The-Fly 管理

> collector：`collectors/vllm.py`（觀看）＋ 控制層（控制，opt-in）
> 來源：R7 research（直接對 vLLM **v0.28.0** source 驗證）+ GitHub issues。Serper down，全靠 primary source。
> **Headline**：on-the-fly 管理**做得到**，但每個 vLLM 原生控制端點都 gate 喺 `VLLM_SERVER_DEV_MODE=1`（server 自己 log "SECURITY WARNING — not for production"）。**冇公開 admin route**。

---

## 1. QUEUE 觀看 —— 深層

| Endpoint | Content | 註 |
|---|---|---|
| `/metrics` | Prometheus（`num_requests_running/waiting/waiting_by_reason`、`request_queue_time_(sum/count)`、`num_preemptions`） | 你已撈。**冇 per-request metric** |
| `/load` | `{"server_load":{<name>:count}}`（**dict**，per-route） | ⚠️ 新版係 dict，唔係舊 array |
| `/health` `/version` | liveness / version | |
| `/v1/models` | OpenAI models list | |
| `/server_info`（DEV） | 完整 resolved config：`world_size`/`tp/pp/dp`/`max_num_seqs`/KV size | ⭐ status API 攞 `max_num_seqs` 用（read-only） |
| `/is_paused` `/is_sleeping`（DEV） | `{"is_paused":bool}` / `{"is_sleeping":bool}` | read-only，**可以 expose** |

**❌ 確認 negative result**：**vLLM 冇 per-request / live-queue listing endpoint**（冇 running/waiting 清單、冇 `/v1/sessions`、冇 debug dump）——scan 晒成個 v0.28.0 `api_router.py` 證實。
**想要 live 清單點算**：由 `/metrics`（count）→ 自己 proxy `/v1/responses/{id}` 追 request_id＋stream token count；真係要 cancel，就 tracking request_ids 後 call abort。

---

## 2. 管理 MATRIX（v0.28.0 source 驗證）

Gate：**DEV** = `VLLM_SERVER_DEV_MODE=1`｜**STARTUP** = 啟動 flag｜**NATIVE** = 只有 engine 內部。

| Action | Route/flag | LIVE? | 喺 busy box 安唔安全 | 我哋 API 使唔使 |
|---|---|---|---|---|
| **PAUSE** | `POST /pause?mode=abort\|wait\|keep&clear_cache`（DEV） | ✅ on-the-fly | `wait`=graceful drain、`keep`=freeze queue（安全）；`abort`=殺掉 in-flight（危險） | Control (opt-in) |
| **RESUME** | `POST /resume`（DEV） | ✅ | flush 排隊 req | Control |
| **is_paused** | `GET /is_paused`（DEV） | ✅ read | — | ✅ **expose**（read） |
| **SLEEP (level)** | `POST /sleep?level=0\|1\|2&mode=abort`（DEV） | ✅ | 警惕 — destructive | ⚠️ 睇 DGX bug 下 |
| **WAKE** | `POST /wake_up?tags`（DEV） | ✅ | **⚠️ GB10 UNSAFE** | **❌ 唔 expose**（bug 未 fix） |
| **is_sleeping** | `GET /is_sleeping`（DEV） | ✅ read | — | ✅ **expose**（read） |
| **REQUEST ABORT** | `POST /abort_requests {"request_ids":[...]}`（DEV） | ✅ | 只 abort 指名 ids（精準）；**空 array = abort 全部**（危險） | ⭐ **HIGH-VALUE control**：cancel 特定 request |
| **ADMISSION/concurrency**（max_num_seqs、KV、max_num_batched_tokens） | ❌ **runtime 冇得改**（startup-fixed） | ❌ NO | — | Read-only reflect |
| **MODEL HOT-SWAP** | `/update_weights` 家族（DEV） | ✅ experimental | risky（RL/multi-agent，external weight host） | ❌ 唔建議 |
| **LoRA live-load** | `/v1/load_lora_adapter`（`VLLM_ALLOW_RUNTIME_LORA_UPDATING`） | ✅ real | safe（busy 會 error） | Maybe 後期 |
| **RAY/scale-out** | 冇 autoscaler；只有 Elastic EP `scale_elastic_ep`（`--enable-elastic-ep`） | ✅ MoE/EP only | fragile/recent (#30942) | 當 experimental |
| **fault-recovery** | `/fault_tolerance/apply + /status`（`--enable-fault-tolerance`） | ✅ | internal | status poll OK |

**唔支援 runtime**：改 `max_num_seqs`/admission/KV size/batching/TP size —— 全部 restart。

---

## 3. ⚠️ DGX Spark 致命 bug：sleep→wake crash（直接關你事）

- **GitHub #50011（open）**：DGX Spark（GB10, unified mem, Docker, NVFP4 MoE, big KV）**`wake_up` crash EngineCore**；sleep level 1 得，wake 死。
  - Reproducer ≈ 你 stack；kv ≥60GiB / `--gpu-memory-utilization 0.85` 會出事；細 KV（40GiB、`--max-num-seqs 4`）就正常。歸咎 cumem allocator。
- **#39078（closed）**：早期 sleep-mode error。
- **結論**：喺你部機上 **sleep→wake 唔可靠、會 dead EngineCore**。status API 對 sleep/wake **read-mostly**（surface `is_sleeping`/`is_paused`）；真要 wake 要 hard guard + warn。

---

## 4. 建議（對呢個 status API）

1. **預設 read-only**（match SPEC 非目標）。免費 expose 一切 viewing：`/health`、`/version`、`/load`（flat dict）、`/metrics`、`/v1/models`，＋ 若開咗 dev-mode 就 `/is_paused`/`/is_sleeping`/`/server_info`。
2. **加 opt-in guarded CONTROL MODE** —— **自己做 proxy，唔好 raw pass-through**：
   - 要 vLLM container 有 `VLLM_SERVER_DEV_MODE=1`（唯有咁先有 native 端點）。⚠️ server 會 log SECURITY WARNING（個 port 任何人摸到都有 pause/abort/sleep）→ 放 internal-only network 或加 token。
   - 我哋控制面：**abort-by-request_id**（surgical）、**pause/resume**（`keep`/`wait`）、expose `is_paused`/`is_sleeping` read。
   - **唔好** surface sleep/wake level 1–2 / weight-swap / elastic-EP 喺 GB10（#50011 未 fix）；真要就 gate 喺「我接受 DGX wake-crash 風險」flag + 永遠唔 auto-wake。
   - 每個 control action 收喺我哋 auth 後 + 冪等 + **先 dry-run「會 pull 幾多 running/waiting」**（由 /metrics 攞）。
3. 因為冇 native per-request list：想要「cancel request X」→ API 追 request_id（proxy `/v1/responses/{id}`）→ call `/abort_requests {request_ids:[id]}`。

## 5. 版本敏感

- v0.28.0：控制全 dev-gated；`/load` 係 dict。
- ≤0.8/0.9：`/sleep`/`/wake_up`/`/is_sleeping` 喺**公開 server**（無 dev gate）、`/load` 係 array。
→ **pin vLLM image 先得**，route 要跟版本 re-derive。

## 6. Source
`github.com/vllm-project/vllm` tag v0.28.0：`entrypoints/serve/dev/*/api_router.py`（rlhf=sleep/pause/abort/weight）、`dev/server_info`、`serve/lora`、`serve/elastic_ep`；`VLLM_SERVER_DEV_MODE`（envs.py）；GitHub issues **#50011**（open）、**#39078**（closed）。
