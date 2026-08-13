# 实时 TPS 计算调研

## 结论

目标实现中的“实时 TPS”定义为：**所有已识别会话在最近 180 秒内产生的输出 token 数，除以固定窗口 180 秒**。

```text
TPS(t) = sum(outputTokens overlapping [t - 180s, t]) / 180
TPM(t) = TPS(t) × 60
```

它只统计 output/completion token，不包含 input、cache、reasoning token；返回结果明确标记 `basis = "output"`。实现先把不同日志格式归一化成“瞬时事件”或“区间事件”，再计算滑动窗口，而不是用相邻 UI 刷新值直接相减。

需要特别区分另一种口径：`output_speed` 是 `会话累计输出 token / 累计 API 耗时` 的会话平均速度，不是菜单栏实时 TPS。Agent Pulse 采用实时窗口算法，不采用该会话平均公式。

## 设计基线

- 定义与常量：固定 180 秒计算窗口、5 分钟状态过期阈值、5 秒未来时间戳容忍度。
- 口径：仅统计 output/completion token，明确标记 `basis = "output"`。
- 方法：先把不同日志格式归一化为“瞬时事件”或“区间事件”，再对滑动窗口求和，而不是对相邻刷新值直接相减。

以下章节给出可独立实现与验证的算法规格。

## 输入来源

### 会话 JSONL

采样器递归发现以下本地目录中的 `.jsonl`：
- Codex、Orca、TraeX：各配置根目录下的 `sessions/` 与 `archived_sessions/`。
- Claude Code、Seed CLI：优先读取配置根目录下的 `projects/`。
- Codex 默认根目录包含 `~/.codex`，并支持 `CODEX_HOME`、额外运行时目录；Claude 默认包含 `~/.claude`，也支持显式配置目录。
- 实时采样器如何将这些配置目录映射为 roots。

发现逻辑每 10 秒运行一次；未变化目录最多 2 分钟重扫一次。只接纳非空、最近 15 分钟修改过的候选文件，最多跟踪 96 个；文件名含 `summary`、`aggregate`、`snapshot`、`live-rate` 或 `live_rate` 的聚合 JSONL 会被排除，避免重复计数。

可识别的输出字段包括：
- 增量字段：`output_tokens`、`outputTokens`、`completion_tokens`、`completionTokens`。
- 累计字段：`total_output_tokens`、`totalOutputTokens`，以及已知 `payload.info.total_token_usage` 结构。
- 已知嵌套位置包括 `payload.info.last_token_usage`、`payload.usage`、顶层 `usage`、`message.usage`；必要时递归查找 usage。

测试明确证明 input/cache/reasoning 不进入 TPS，且没有 output 维度的记录会被忽略。

### 本地状态快照

当 Claude/Seed 配置目录没有 `projects/`，以及 Relay 场景，采样器读取 `statusline-tmux-snapshot.json`。快照形状使用：
- `updated_at`
- `session_id`
- `tokens.output`，仅为兼容解析才读取 `tokens.total`

`tokens.total` 但缺少显式 `tokens.output` 时只能作为“信号存在”的依据，不能产生 output TPS，避免把输入和缓存误算为输出。

## 归一化与可复用算法

### 1. 初始基线

首次发现文件时从文件尾开始跟踪，并读取末尾最多 512 KiB 只用于建立累计值和消息去重基线；已有历史不会被回放成“当前速率”。

### 2. 累计计数器差分

若一条记录含累计输出总量：
```text
delta = currentTotal - previousTotal, only when currentTotal > previousTotal
event = (previousTimestamp, currentTimestamp, delta)
```

第一次观测只建立基线。累计值下降视为计数器重置/会话切换，当前观测不产生 token；后续从新基线继续。JSONL 路径实现快照路径。累计差分、计数器重置。

### 3. 消息级去重

Claude 风格的同一 assistant message 可能被反复写出不断增长的 usage。身份键为 `sessionId + message.id`，缺少 message ID 时回退到记录 `uuid`；同一身份只计 `max(0, currentOutput - previousOutput)`，并保持已见最大值，避免回退后重复计数。

消息身份最多保存 2,048 个、保留 10 分钟，超限按最后出现时间及序号淘汰最旧项。

### 4. 区间摊分

累计计数器只能证明两个观测点之间增加了多少 token，不能证明它们集中在结束瞬间。因此区间事件按与当前 180 秒窗口的重叠比例线性摊分：
```text
includedTokens = round(deltaTokens × overlapDuration / eventDuration)
```

瞬时事件的 duration 为 0，只要时间戳落入窗口就整体计入。区间端点反转时先交换；负 token 归零；累加使用饱和加法防止 `Int64` 溢出。

该策略能避免稀疏写日志造成尖峰。例如 10 分钟累计增加 6,000 output token，在末端 180 秒窗口中只计 1,800，TPS 为 10。

### 5. 会话数

`active_sessions` 是窗口内具有正 output token 的去重会话数。无法识别的匿名事件统一额外计为一个匿名会话；快照会话 ID 与路径先做哈希，不对外暴露原值。

## 时间窗口与刷新方式

- 计算窗口固定为 180 秒；状态过期阈值为 5 分钟；未来时间戳容忍 5 秒。全部常量。
- 后端采样最多每秒执行一次；目录发现每 10 秒一次。
- macOS 菜单栏后台循环持续调用 `Sample`，即使动画关闭也继续推进文件 offset 和累计基线，避免恢复后把长时间增量压成一个突发。
- Web popover 可见时每秒 GET `./api/live-rate`，超时 2.5 秒；失败按 1、2、5、10、30 秒退避。
- API 返回 `tps`、`tpm`、`state`、`basis`、`window_seconds`、`active_sessions`、`sampled_at`、`latest_event_at`；端点只接受 GET 且受本地 token gate 保护。

## 状态和边界情况


| 条件 | 状态 | 曲线语义 |
|---|---|---|
| 从未读到有效 output 信号 | `no_data` | 缺失值，曲线断开 |
| 最近信号不超过 5 分钟，窗口内 token 为 0 | `zero` | 有效数值 0 |
| 最近信号不超过 5 分钟，窗口内 token 大于 0 | `live` | 有效 TPS |
| 最近信号超过 5 分钟 | `stale` | 缺失值，曲线断开 |
| 读取/API 失败（前端态） | `unavailable` | 缺失值，曲线断开 |

其余必须保留的边界规则：
- **不完整 JSONL 行**：只推进到最后一个换行，等待下次补齐；解析失败行跳过。
- **文件截断/轮转**：文件 size 小于 offset 时重建基线，不回放新文件已有历史。
- **长时间休眠**：两次采样间隔超过 180 秒时直接重建基线，不把休眠期间累计量算作当前突发。
- **追加过大**：单次未读追加超过 512 KiB 时只重建末端基线；测试证明后续正常差分。
- **旧式无 session ID 快照下降**：下降后第一次上升只重建基线，防止两个会话的累计总量串接。
- **会话长时间未观测**：同一快照身份超过 180 秒再次出现时先重建基线；快照身份保留 30 分钟、最多 256 个。
- **异常时间戳**：空时间戳或超过当前时间 5 秒的时间戳按当前时间处理；超过容忍范围的未来事件和窗口外旧事件不计。
- **溢出和负数**：负 token 不计，窗口总和饱和到 `Int64.max`，避免翻转为负。

## Swift/macOS 独立实现建议

### 组件拆分

建议保持四层，避免 UI、文件 IO 和口径耦合：
1. `SignalDiscovery`：解析各 provider 根目录，周期发现候选文件；对外只给规范化 URL 与 provider。
2. `TokenEventNormalizer`：为 JSONL、累计快照分别实现 adapter，输出统一 `TokenEvent(start, end, outputTokens, sessionKey)`。
3. `LiveRateEngine`：`actor` 持有 offset、累计基线、消息身份缓存和 180 秒事件环形缓冲；所有状态转换在 actor 内串行完成。
4. `LiveRateStore`：SQLite 批量持久化事件与曲线样本；SwiftUI/MenuBarExtra 只订阅不可变 `LiveRateSample`。

使用 `ContinuousClock` 控制 1 秒轮询和休眠 gap，使用 `Date`/UTC 毫秒保存源事件时间。文件变化可用 `DispatchSourceFileSystemObject` 降低空轮询，但仍保留每秒安全轮询和每 10 秒发现，因为目录 watcher 可能合并事件、文件会被原子替换。JSONL 用 `FileHandle.seek` 从 offset 增量读取，并保留未换行尾部；不要每秒重读全文件。

### SQLite schema

建议数据库启用 WAL、`foreign_keys=ON`、合理 `busy_timeout`，所有时间保存 UTC Unix 毫秒。路径和 session ID 默认存 SHA-256 摘要，避免把工作目录或会话标识泄露到诊断导出。

```sql
CREATE TABLE live_rate_sources (
  id INTEGER PRIMARY KEY,
  provider TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('jsonl', 'snapshot')),
  path_hash BLOB NOT NULL,
  file_identity TEXT,
  read_offset INTEGER NOT NULL DEFAULT 0 CHECK (read_offset >= 0),
  last_size INTEGER NOT NULL DEFAULT 0 CHECK (last_size >= 0),
  last_mtime_ms INTEGER,
  generation INTEGER NOT NULL DEFAULT 0,
  cumulative_initialized INTEGER NOT NULL DEFAULT 0 CHECK (cumulative_initialized IN (0, 1)),
  last_total_output INTEGER,
  last_total_at_ms INTEGER,
  last_seen_at_ms INTEGER NOT NULL,
  UNIQUE(provider, kind, path_hash)
);

CREATE TABLE live_message_baselines (
  source_id INTEGER NOT NULL REFERENCES live_rate_sources(id) ON DELETE CASCADE,
  message_key_hash BLOB NOT NULL,
  max_output INTEGER NOT NULL CHECK (max_output >= 0),
  last_seen_at_ms INTEGER NOT NULL,
  sequence INTEGER NOT NULL,
  PRIMARY KEY(source_id, message_key_hash)
);

CREATE TABLE live_token_events (
  id INTEGER PRIMARY KEY,
  source_id INTEGER REFERENCES live_rate_sources(id) ON DELETE SET NULL,
  session_key_hash BLOB,
  start_at_ms INTEGER NOT NULL,
  end_at_ms INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL CHECK (output_tokens > 0),
  ingested_at_ms INTEGER NOT NULL,
  CHECK (end_at_ms >= start_at_ms)
);
CREATE INDEX live_token_events_window_idx ON live_token_events(end_at_ms, start_at_ms);

CREATE TABLE live_rate_samples (
  sampled_at_ms INTEGER NOT NULL,
  resolution_seconds INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('live', 'zero', 'no_data', 'stale', 'unavailable')),
  tps REAL,
  min_tps REAL,
  max_tps REAL,
  tokens_in_window INTEGER,
  window_seconds INTEGER NOT NULL DEFAULT 180 CHECK (window_seconds = 180),
  active_sessions INTEGER NOT NULL DEFAULT 0 CHECK (active_sessions >= 0),
  latest_event_at_ms INTEGER,
  PRIMARY KEY(sampled_at_ms, resolution_seconds),
  CHECK ((state IN ('live', 'zero') AND tps IS NOT NULL AND tps >= 0)
      OR (state NOT IN ('live', 'zero') AND tps IS NULL))
);
```

`live_token_events` 是口径真源；`live_rate_samples` 是展示缓存。offset、累计 baseline 和事件应在同一个事务提交，防止崩溃后 offset 已推进但事件未落库，或事件重复落库。文件 identity/generation 用于识别原子替换与截断；generation 增加时只建立新基线。

### 曲线采样与保留

- **采样频率**：前台/菜单栏进程活跃时每 1 秒产生一个 sample，与源实现刷新节奏一致；同一秒只保留一个最终值。SQLite 可每 5 秒批量提交，UI 仍从内存流每秒更新。
- **计算原则**：每个 sample 都从规范化事件按 180 秒窗口计算，不从相邻 sample 差分；区间事件按重叠比例计算。
- **分层保留**：建议保留 1 秒样本 6 小时、10 秒聚合 7 天、60 秒聚合 90 天。聚合桶保存时间加权 `avg(tps)`、`min_tps`、`max_tps` 和末值；曲线画 avg，tooltip 可展示 peak，避免降采样吞掉短峰。
- **状态聚合**：桶内只要存在 `live`，数值仅聚合 `live/zero` 样本；全为 `zero` 则为 `zero`；没有数值且含 `unavailable` 优先标为 `unavailable`，其次 `stale`，否则 `no_data`。
- **缺口**：相邻有效样本间隔超过 2 倍 resolution 时画断线，禁止把休眠、权限失败或应用退出插值成零。`zero` 必须画为 0；`no_data/stale/unavailable` 必须存 NULL 并断线。
- **查询降采样**：视口点数超过约 1,000 时优先选择已有 10 秒/60 秒层；仍超限再使用 LTTB 或 min/max envelope，但不跨状态缺口合并。
- **清理**：每次批量写入后限频执行 retention delete；原始事件至少保留到最后一个 180 秒窗口完全过期，建议保留 24 小时便于诊断，随后由 1 秒/聚合样本承接历史曲线。

## 建议的验证用例

Swift 实现至少应以确定时钟覆盖以下表驱动用例：
1. 180 token 的瞬时事件在窗口内得到 TPS 1，越过 180 秒边界后归零。
2. 600 秒内累计增加 6,000 token，在末端 180 秒只计 1,800，TPS 10。
3. 累计值 `100 → 280` 只计 180；`1000 → 100 → 280` 在重置后只计最后 180。
4. 同一 message `100 → 100 → 140` 只计 40；不同 session 的相同 message ID 分开计。
5. input/cache/reasoning 巨大但 output 为 7 时只计 7；缺少 output 字段时不初始化为有效 TPS。
6. 首次发现、文件截断、追加超过 512 KiB、采样休眠超过 180 秒均只重建基线，不产生尖峰。
7. `now + 5s` 事件可接受，超过 5 秒不进入窗口；负值忽略，总和溢出时饱和。
8. `zero` 写入数值 0；`no_data/stale/unavailable` 写入 NULL，曲线必须断开。
9. 两个并发会话的 token 合计进入 TPS，`active_sessions` 为 2；任何导出均不出现原始路径和 session ID。

上述边界均由确定时钟的表驱动用例覆盖验证。

## 已知取舍

- 180 秒固定分母使短暂 burst 在三分钟内逐渐衰减，指标稳定但不是模型原生流式解码瞬时速度；产品文案应写“最近三分钟输出 TPS”。
- 区间线性摊分是假设 token 在两次累计观测间均匀产生。缺少逐 token 时间戳时，这是比把全部增量压在末端更稳健的估计，但不能还原真实微观峰值。
- 原实现采用轮询而不是文件系统事件作为正确性基础。Swift 侧可加 watcher 优化唤醒，但不能移除基线推进、定时发现和休眠重基线。
- Agent Pulse 当前 Swift package 仍是最小可执行骨架，因此上述设计未绑定现有应用源码或第三方数据库框架，可独立实现并逐层测试。
