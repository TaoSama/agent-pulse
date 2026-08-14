# CLIProxyAPI 用量采集：接口调研与映射方案

调研日期：2026-08-14。目标：为 Agent Pulse 新增 cliproxyapi 采集源，读取「某个 apikey」的 token 用量，经现有上报链路上报。

所有结论均以对目标部署 `http://10.37.80.152:18317` 的**真实带鉴权探测**为准（脱敏后记录），并交叉核对开源仓库 `router-for-me/CLIProxyAPI` 源码。

---

## 1. 鉴权

- **Header**：`Authorization: Bearer <management-key>`（也接受不带 `Bearer` 前缀的裸 `Authorization: <key>`，以及 `X-Management-Key: <key>`）。
- management key 在服务端 `config.yaml` 的 `remote-management.secret-key` 配置（明文启动时 bcrypt 化）；空则整个 `/v0/management/*` 返回 404。非 loopback 访问要求 `remote-management.allow-remote: true`。
- 本机凭证放在 `~/.claude/.credentials/tokens/cpa-manager-plus-devbox-admin-key`（0600），**不入仓库、不写日志**。

证据：`internal/api/handlers/management/handler.go` 鉴权中间件；`config.example.yaml` 的 `remote-management`。实测带 Bearer 的请求对下列端点返回 200。

---

## 2. 端点

> ⚠️ 版本差异：开源 CLIProxyAPI 自 v6.10.0 起**移除**了内建持久化 usage 存储，仅保留 `api-key-usage`（仅计数、无 token）与 `usage-queue`（破坏性 FIFO，需 Redis 插件）。**但目标部署（`commercial-mode: true`，即 CPA-Manager-Plus）额外提供了持久化聚合的 `/v0/management/usage`**，返回全量明细。本项目以目标部署实测为准。

| Method | Path | 说明 | 实测 |
|---|---|---|---|
| GET | `/v0/management/usage` | **本项目采用**。返回全量按 endpoint→model→details[] 分组的逐请求明细 + 顶层汇总。 | 200，~90 MB 且随时间增长 |
| GET | `/v0/management/api-keys` | 列出入站 apikey 字符串（非用量）。 | 200，`{"api-keys":[...]}` |
| GET | `/v0/management/config` | 服务端配置（含 `usage-statistics-enabled: true`）。 | 200 |
| GET | `/v0/management/api-key-usage` | 上游版：每 key 成功/失败计数 + 20×10min 滚动桶，**无 token 计数**。 | 目标部署未采用 |

### 关键约束（已实测）

- **无服务端过滤**：`?api_key=` / `?key=` / `?limit=` / 任意子路径（`/usage/summary`、`/usage/<key>`、`/usage/zzz-random`）**全部被忽略**，每次都返回整份 firehose。→ 只能整包下载后在客户端按 apikey 过滤。
- **响应无界**：当前 ~90 MB（39941 条请求），随使用持续增长。采集端必须设**上限保护**并做**流式/分段解析**，避免 OOM 与阻塞。

---

## 3. 响应结构（实测字段名）

```jsonc
{
  "total_requests": 39941,
  "success_count": 38854,
  "failure_count": 1073,
  "total_tokens": 4932689017,
  "apis": {
    "POST /v1/chat/completions": {        // 也有 "POST /v1/messages"、"POST /v1/responses"
      "models": {
        "deepseek-v4-flash": {
          "details": [
            {
              "timestamp": "2026-08-09T16:24:58.595620692Z",   // RFC3339 纳秒
              "source": "m:sk-f...8b06",                        // 掩码 key / 邮箱，脱敏用
              "api_key_hash": "1eaa840f...3356010",             // = SHA256(明文 apikey) hex
              "resolved_model": "deepseek-v4-flash",
              "executor_type": "CodexExecutor",
              "tokens": {
                "input_tokens": 86,
                "output_tokens": 34,
                "reasoning_tokens": 32,
                "cached_tokens": 0,
                "cache_tokens": 0,
                "cache_read_tokens": 0,
                "cache_creation_tokens": 0,
                "total_tokens": 120
              },
              "failed": false,
              "fail_status_code": 200
              // 另有 latency_ms/ttft_ms/service_tier/fail_summary/response_metadata 等，本项目不用
            }
          ]
        }
      }
    }
  }
}
```

### apikey 身份 = `SHA256(明文 apikey)`（已验证）

对目标部署实测：

- `sk-dummy` → `SHA256` = `1eaa840f0577...` ✅ 与 details 中的 `api_key_hash` 完全匹配
- `sk-fas-779a01c4...` → `SHA256` = `beb8eebb14e9...` ✅ 匹配

因此**配置里填明文 apikey，采集端本地算 SHA256 与 `api_key_hash` 比对**即可精确锁定目标 key，无需把明文发给服务端做过滤（也不支持）。

---

## 4. Token 字段 → `UsageTokenCounts` 映射

目标部署两个 key 的实测聚合（用于验证字段语义）：

| 字段 | key `1eaa84…`(sk-dummy) | key `beb8ee…`(sk-fas) |
|---|---|---|
| input_tokens | 4 075 441 133 | 449 644 |
| output_tokens | 21 885 760 | 9 900 |
| reasoning_tokens | 4 990 979 | 6 551 |
| cache_read_tokens | 3 545 463 544 | 22 016 |
| cache_creation_tokens | 35 010 212 | 0 |
| cached_tokens / cache_tokens | 0 | 0 |
| total_tokens | 4 932 229 473 | 459 544 |

观察：`input_tokens` 是**原始 prompt 总量**（包含随后单列出的 cache_read / cache_creation），与仓库现有 Codex parser 的口径一致——Codex parser 也把 `cached_input` / `cache_creation` 从 raw input 里减出来。因此复用同一口径：

```
cachedInput        = min(input_tokens, cache_read_tokens + cached_tokens + cache_tokens)
cacheCreationInput = min(max(0, input_tokens - cachedInput), cache_creation_tokens)
input              = input_tokens - cachedInput - cacheCreationInput   // 纯新增 input
output             = output_tokens - reasoningOutput
reasoningOutput    = min(output_tokens, reasoning_tokens)
reportedTotal      = total_tokens
```

`UsageTokenCounts.total` 取 `max(reportedTotal, 各分量之和)`，与账本一致。

---

## 5. 映射进现有 usage bucket / 上报链路

复用 `UsageEvent → UsageLedgerStore.record → finalizeDerived → UsageBucket → TokenUsageReporter` 全链路，**不新造上报通道**。

| 账本维度 | cliproxy 取值 |
|---|---|
| `source` | 固定常量 `"cliproxy"`（与 `codex` / `claude-code` 并列，新来源） |
| `model` | detail 的 `resolved_model`（回退到分组 model 名） |
| `project` | 目标 apikey 的稳定短哈希（**不落明文 key**），用于区分被监控的 key |
| `timestamp` | detail 的 `timestamp`（RFC3339 纳秒，账本 30min bucket 落桶） |
| `counts` | 上文映射 |
| `sessionHash` | 目标 apikey 短哈希（cliproxy 无会话概念，用 key 身份占位） |
| 稳定 `event.id` | `SHA256("cliproxy|"+api_key_hash+"|"+resolved_model+"|"+timestamp+"|"+usageIdentity)`，幂等去重 |

- **幂等**：同一条 detail（同 key_hash + model + timestamp + 各 token 分量）生成稳定 `event.id`，`record` 的 `INSERT ... ON CONFLICT(event_id)` 幂等，重复整包下载不会重复计数。
- cliproxy 不产生 session 活动事件（`usage_session_events`），因此不写 session 派生行；只贡献 buckets。
- 隐私：只保留 hash 后的 key 身份、model、token 计数与时间，**不落明文 apikey、掩码 source、base URL、management key、正文**。

### 与现有 bucket 模型的差异与取舍

1. cliproxy 明细带纳秒时间戳，天然可落 30min bucket，无需额外结构 —— 完全契合。
2. cliproxy 无「会话」维度：sessions 表不写入，仅 buckets。对上报协议无影响（buckets/sessions 各自独立 ack）。
3. 采集为**主动拉取**（HTTP），不同于 codex/claude 的**本地文件扫描**；因此采集在 scan 阶段以「可选来源」并入，缺配置或拉取失败时**跳过**，绝不影响本地文件采集与既有链路。

---

## 6. 未决 / 风险

- **响应体无界**：需设最大字节保护（默认 64 MB，可配）与超时；超限则本轮跳过并记状态，不 OOM。
- 上游开源版无此持久 `/usage`，若目标部署升级/切换到纯开源版，此端点可能消失 → 采集失败即跳过，不阻塞。
- `total_tokens` 的服务端口径若与分量和不一致，以 `max` 兜底（账本既有行为）。
