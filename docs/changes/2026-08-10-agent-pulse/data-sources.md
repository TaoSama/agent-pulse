# Codex task 计数的数据源调查

## 结论

截至 2026-08-10（Asia/Shanghai）的只读快照：

| 指标 | 当前脱敏计数 | 结论等级 | 推荐口径 | 完整性 |
|---|---:|---|---|---|
| Codex Desktop active task | 10 | **权威（当前窗口）** | Desktop `list_threads` 返回项中 `status == "active"` | 当前可见任务准确；接口最多返回最近 50 个非置顶任务，不能证明全历史无更老 active |
| 已完成且不在 automations 项目/目录下 | 至少 37 | **权威下界** | `status == "idle"`，并排除 automation `projectId` 与路径 | 当前可见任务准确；同受 50 个非置顶任务上限影响，全量精确值 **unavailable** |
| 终端/CLI active task | 约 1 | **近似** | rollout 首行 `originator == "codex_exec"`，最后一个生命周期事件为 `task_started`，并由独立 CLI 进程交叉确认 | 两个独立信号均为 1，但单次探测无法证明 PID 与 rollout 的一一绑定 |

这里把 Desktop 的 `idle` 解释为“当前 turn 已结束、任务可继续”，即产品所需的“已完成”；它不等于 `archived`。`active` 表示当前有 turn 在运行；`notLoaded` 表示该任务的后端/来源尚未加载，不能归入完成。本次 Desktop 快照的状态分布为 `active=10`、`idle=37`、`notLoaded=3`；其中 2 个 `notLoaded` 属于 automations 项目。

最可靠的实现是：Desktop 计数优先使用应用自身的 `list_threads`/`list_projects` 只读接口；CLI 计数扫描 rollout JSONL 的结构化生命周期字段，并用进程存活作交叉验证。SQLite 适合作任务索引、项目归属和增量水位，但 `threads` 表没有运行状态，不能单独算 active/completed。

## 数据源与可靠性

本机 `~/.codex` 是数据根目录的符号链接。不要硬编码其实际目标；实现时先做 `realpath ~/.codex`。`~/Library/Application Support/Codex` 主要是 Electron/Chromium 缓存、Cookie 和 Crashpad 数据，不是任务状态源。

| 数据源 | 关键字段 | 能回答什么 | 可靠性与限制 |
|---|---|---|---|
| Desktop `list_threads` | `id`, `kind`, `projectId`, `hostId`, `status`, `cwd`, `updatedAt` | 当前 active/idle/notLoaded，包含本地 Codex 与 ChatGPT task | 状态最权威；非置顶项 `limit <= 50`，无分页游标；置顶项始终全量返回 |
| Desktop `list_projects` | `projectId`, `projectKind`, `path`, `hostId`, `isGitRepository` | 用稳定 project ID 过滤 automations | 权威；属于 Desktop 内部工具面，不是面向第三方承诺稳定的公开 REST API |
| `~/.codex/state_5.sqlite` | `threads.id`, `rollout_path`, `source`, `thread_source`, `cwd`, `archived`, `updated_at_ms`, `recency_at_ms` | 全量本地 thread 索引、来源、归档、增量水位 | 高；没有 active/completed 列，`archived` 不是完成态 |
| `~/.codex/.codex-global-state.json` | `local-projects`, `thread-project-assignments` | thread 到项目的映射、automation 项目识别 | 高；应用内部格式，升级后需 schema 探测 |
| `~/.codex/automations/*/automation.toml` | `target_thread_id`, automation 配置 | 精确排除 automation 的目标 thread | 高；只覆盖采用 automation TOML 的任务，脚本型目录可能没有 TOML |
| `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | `session_meta.payload.originator`, `event_msg.payload.type` | CLI/Desktop 来源及 turn 生命周期 | CLI active 的最佳本地证据；文件含大量敏感正文，只能选择性解析字段 |
| `~/.codex/session_index.jsonl` | `id`, `thread_name`, `updated_at` | rollout 的轻量索引 | 辅助；无运行态 |
| `ps`/`pgrep` | PID、PPID、elapsed、可执行文件路径 | 独立 CLI 进程是否仍存活 | 中；进程存活不等于 turn 正在生成，不能单独计数 |
| `~/.codex/process_manager/chat_processes.json` | `conversationId`, `osPid`, `command`, timestamps | 历史派生 shell 进程 | 不可用于 task active；本次样本明显陈旧，记录中的 PID 无存活者 |
| `thread_spawn_edges.status` | `parent_thread_id`, `child_thread_id`, `status` | subagent 拓扑 | 不能判完成；观察到旧边长期保持 `open` |
| app-server Unix socket | 本地事件流 | 理论上可获得秒级实时状态 | 协议未公开且需要主动交互；不属于纯只读文件探测，不推荐首版依赖 |

`goals_1.sqlite.thread_goals.status` 的枚举是 `active | paused | blocked | usage_limited | budget_limited | complete`，但它只覆盖显式创建 goal 的少数 thread。它描述 goal 生命周期，不是 Desktop 所有 task 的运行状态，不能拿 `status='complete'` 代替 task 完成计数。

## 状态语义

### Desktop

- `active`：task 当前有活跃 turn。这是 active task 的产品口径。
- `idle`：当前没有活跃 turn，上一轮已结束，仍可继续对话。本报告将其计为“已完成”。
- `notLoaded`：后端/远端来源未加载或当前不可解析；既不计 active，也不计 completed。
- `archived`：收纳/隐藏属性，与 turn 是否完成正交。
- `kind`：本次观察到 `codex` 与 `chatgpt`；若产品只展示本地 Codex，应额外要求 `kind == "codex"`，但“Codex Desktop 当前任务”默认按应用聚合口径统计两类。

### CLI rollout

rollout 的首个 `session_meta` 事件含来源：

- `payload.originator == "codex_exec"`：独立终端/CLI。
- `payload.originator == "Codex Desktop"`：Desktop 启动的会话；即使 SQLite 的 `source` 是 `exec`，也不能据此误判为独立 CLI。

turn 生命周期只读取结构化字段 `.type == "event_msg"` 下的 `.payload.type`：

- `task_started`：turn 开始。
- `task_complete`：turn 正常结束。
- `turn_aborted`：turn 被中断，按非 active 处理。

不要用 grep 在整行中搜索这些字符串，因为消息正文也可能恰好包含同名文本；必须用 `jq` 按 JSON 路径筛选。

## automations 过滤

推荐按以下优先级建立 automation thread 排除集：

1. 调用 `list_projects`，把规范化后的 `path` 中任一路径段等于 `automations` 的项目 `projectId` 放入集合；Desktop 结果按 `projectId` 排除。
2. 同时对 task 的规范化 `cwd` 做路径段判断，兼容没有项目归属的任务。不要用宽泛的 `contains("automations")`，以免误伤诸如 `my-automations-demo`。
3. 本地离线模式读取 `.codex-global-state.json`：从 `local-projects[].rootPaths` 找 automation 项目 ID，再用 `thread-project-assignments[thread_id].projectId` 映射。
4. 再合并 `automations/*/automation.toml` 的 `target_thread_id`，覆盖目标 thread 被移动或项目映射暂缺的情况。

经脱敏聚合验证，本机识别到 1 个 automation 项目；全局映射中有 4 个 thread 归属该项目，当前 `list_threads(limit=50)` 窗口中有 2 个。路径比较前应执行 `realpath`（路径存在时）、移除尾斜杠，并按路径组件比较。

离线过滤的只读样例：

```bash
CODEX_ROOT="$(realpath "$HOME/.codex")"
jq '
  ([.["local-projects"][]
    | select(any(.rootPaths[]?; test("(^|/)automations(/|$)"; "i")))
    | .id]) as $automation_project_ids
  | {
      automation_project_count: ($automation_project_ids | length),
      assigned_automation_thread_count: ([
        .["thread-project-assignments"][]
        | select(
            (.projectId as $id | $automation_project_ids | index($id)) != null
            or ((.path // .cwd // "") | test("(^|/)automations(/|$)"; "i"))
          )
      ] | length)
    }
' "$CODEX_ROOT/.codex-global-state.json"
```

该命令只输出计数，不输出项目名、本地路径或 thread ID。

## 可复现的只读探测

### SQLite schema 与聚合

活写 SQLite 使用 WAL。常驻采集器应以 `mode=ro` 打开，执行 `PRAGMA query_only=ON`，让 SQLite 正常合并 WAL；`immutable=1` 只适合对数据库、`-wal`、`-shm` 的一致快照副本查询，直接用于活库可能漏掉 WAL 中的新记录。

```bash
CODEX_ROOT="$(realpath "$HOME/.codex")"
DB_URI="file:$CODEX_ROOT/state_5.sqlite?mode=ro"

sqlite3 "$DB_URI" 'PRAGMA query_only=ON; PRAGMA table_info(threads);'

sqlite3 "$DB_URI" '
  PRAGMA query_only=ON;
  SELECT COALESCE(thread_source, "<null>"), COUNT(*)
  FROM threads
  GROUP BY thread_source
  ORDER BY 1;
'

sqlite3 "$DB_URI" '
  PRAGMA query_only=ON;
  SELECT MAX(updated_at_ms), MAX(recency_at_ms)
  FROM threads;
'
```

这些 SQL 不选择 `title`、`preview`、`first_user_message`、`git_origin_url` 等敏感列。

### CLI active 计数

下面全量扫描本机 rollout，只读取首行来源和结构化生命周期字段。它没有武断的“最近 10 分钟”超时：长任务可以合法运行超过 10 分钟。结果仍需与独立 CLI 进程交叉确认，以排除异常退出后遗留的 `task_started`。

```bash
CODEX_ROOT="$(realpath "$HOME/.codex")"
active_rollouts=0

while IFS= read -r -d '' rollout; do
  originator="$(
    head -n 1 "$rollout" \
      | jq -r 'if .type == "session_meta" then (.payload.originator // "") else "" end'
  )"
  [ "$originator" = "codex_exec" ] || continue

  last_lifecycle="$(
    jq -r '
      select(
        .type == "event_msg"
        and (
          .payload.type == "task_started"
          or .payload.type == "task_complete"
          or .payload.type == "turn_aborted"
        )
      )
      | .payload.type
    ' "$rollout" | tail -n 1
  )"

  [ "$last_lifecycle" = "task_started" ] \
    && active_rollouts=$((active_rollouts + 1))
done < <(find -L "$CODEX_ROOT/sessions" -type f -name '*.jsonl' -print0)

printf 'cli_active_rollout_candidates=%d\n' "$active_rollouts"

# 仅显示聚合数，不显示可能含敏感参数的 argv。
ps -axo comm= \
  | awk '/(^|\/)codex$/ && /\/(@openai\/codex|codex\/vendor)\// {count++} END {print "live_cli_processes=" count+0}'
```

经此规则全量复核，本次为 1 个未结束的 CLI rollout 候选，并存在 1 个独立 Homebrew/npm Codex CLI 进程，因此报告近似值 1。

更严谨的常驻实现应记录启动时看到的 CLI PID、rollout thread ID 与创建时间三元组；只有生命周期未结束且对应进程仍存活才计 active。单次无历史探测无法可靠把任意 PID 绑定到 rollout，因此冲突时输出 `unknown`，不要猜测。

### Desktop 接口快照

Codex Desktop 当前暴露的只读工具语义为：

```text
list_threads({ limit: 50 })
  -> pinnedThreads[] + threads[]
  -> item: id, kind, projectId, hostId, status, cwd, updatedAt, title, summary

list_projects({})
  -> projects[]
  -> item: projectId, projectKind, path, hostId, isGitRepository
```

采集器只应保留 `id` 的进程内哈希、`status`、`projectId`、规范化路径的 automation 布尔值和 `updatedAt`；不得记录 `title`、`summary`。`limit` 的实测最大值为 50，传入更大值会被拒绝。接口没有分页 cursor，因此“全历史已完成数”目前无法从该接口可靠获得；应在 UI 中明确标注“当前窗口”或“至少 N 个”。

## 增量刷新

推荐刷新管线：

1. Desktop：每 2–5 秒调用一次 `list_threads(limit=50)`；以 `(hostId, id)` 为键，对 `status`、`updatedAt`、`projectId` 做差分。项目列表低频刷新（例如 60 秒）或路径配置变更后刷新。
2. SQLite：保存 `(updated_at_ms, id)` 复合水位，查询 `updated_at_ms > ? OR (updated_at_ms = ? AND id > ?)`；不要只用 `MAX(id)`，UUID/ULID 排序不能替代更新时间。
3. JSONL：按文件保存 `(device, inode, byte_offset)`；文件增长时只解析新增完整行，截断或 inode 变化时从头重建该文件的生命周期状态。
4. 进程：用系统进程事件或 2–5 秒低频轮询，仅作 CLI 候选校验。不要读取完整 argv。
5. 每隔数分钟做一次全量 reconcile，修复丢失的文件事件、SQLite WAL 切换和应用重启造成的漂移。

若 Desktop 接口返回 `unavailableHosts`/`unavailableSources`，保留上一次值但标记 `stale`，不要把不可用任务瞬间计为完成。

## 隐私与安全风险

- rollout JSONL 含完整用户消息、模型输出、reasoning、工具参数和命令；解析器必须白名单选择 `.type`、`.payload.type`、`.payload.originator`，禁止通用日志转储。
- `threads` 表含 `title`、`preview`、`first_user_message`、仓库地址；只做指定列的聚合，不使用 `SELECT *`。
- `.codex-global-state.json` 暴露本地项目路径、远端主机与 thread 映射；持久化前只保留 automation 布尔值或不可逆哈希。
- `process_manager/chat_processes.json` 的 `command` 可能含文件名、prompt 或凭证；不要读取或上报该字段。
- `auth.json`、浏览器 Cookies、MCP/OAuth 文件、shell snapshots 可能含凭证，完全排除在扫描范围外。
- `ps -ef`/`pgrep -af` 会暴露完整命令行；只读取 `comm`、PID、PPID、elapsed，展示时只给聚合计数。
- 所有本机数据留在本机；若未来上传遥测，需单独征得同意，并采用最小字段、短保留期和每设备盐化哈希。

## 推荐实现与降级

### 推荐

- **Desktop active/completed**：`list_threads(limit=50)` 的 `status`；由 `list_projects` 的 automation `projectId` 加路径段规则过滤。
- **CLI active**：rollout `originator=codex_exec` + 最后生命周期为 `task_started`；由独立 CLI 进程存活交叉确认。
- **本地索引与增量**：只读 `state_5.sqlite` 的 `updated_at_ms`/`recency_at_ms`；项目归属离线回退到 `.codex-global-state.json`。
- 展示层必须携带 `scope=current-window|all-local`、`freshness`、`isLowerBound`，避免把窗口计数伪装成全量精确值。

### 降级顺序

1. `list_threads` 不可用：按 rollout 生命周期分别统计 Desktop/CLI；这是本地会话全量，但不含仅云端存在且未同步的 ChatGPT task。
2. rollout 不可读：SQLite 仅按 `recency_at_ms` 给“最近活动”近似值，并显著标注 estimated；不能宣称 active。
3. 项目映射不可用：合并 automation TOML 的 `target_thread_id` 与严格路径段过滤；仍无法归类的任务标记 unknown，不计入“非 automation 已完成”。
4. 进程不可读：CLI 生命周期未结束者标记 `possibly_active`，不要直接计入严格 active。
5. 不建议首版连接 app-server socket；协议变化、交互副作用与维护成本都高于轮询只读源。

## 已验证与仍未知

已验证：真实数据根目录、SQLite schema、Desktop 状态枚举与 50 项上限、automation 项目/线程映射、rollout 来源与生命周期、独立 CLI 进程交叉检查，以及 `chat_processes.json`/`thread_spawn_edges.status` 的反例。

仍未知：Desktop 内部工具与 app-server IPC 没有公开兼容性承诺；`list_threads` 无分页导致全历史 completed 只能给下界；远端 host 不可用时本机无法证明其真实状态；异常崩溃可能留下未闭合 `task_started`。实现应进行 schema capability detection，并在这些情况下返回 `unknown`/`stale`/`estimated`，而不是静默给出错误精确数。
