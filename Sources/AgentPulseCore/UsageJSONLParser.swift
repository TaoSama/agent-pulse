import CryptoKit
import CoreFoundation
import Foundation

/// 单个来源文件解析结果。
///
/// - events: token 用量事件（每条带稳定 id、血缘字段与可选血缘指纹）。
/// - sessionEvents: 原始会话活动事件（user / synthetic_user / assistant），
///   用于重建 session 聚合；不含正文 / cwd / path。
/// - checkpoint: 该文件的读取水位与解析器版本。
/// - diagnostics: 逐行诊断（无效 JSON / 无效时间戳 / 累计回退等）。
public struct ParsedUsageFile: Sendable, Equatable {
    public let events: [UsageEvent]
    public let sessionEvents: [UsageSessionEvent]
    public let checkpoint: UsageFileCheckpoint
    public let diagnostics: [String]
    /// 已应用、去重前的编辑行记录（代码行数指标 v2 的原始载体）。
    public let editEntries: [UsageEditEntry]

    public init(events: [UsageEvent], sessionEvents: [UsageSessionEvent], checkpoint: UsageFileCheckpoint, diagnostics: [String], editEntries: [UsageEditEntry] = []) {
        self.events = events
        self.sessionEvents = sessionEvents
        self.checkpoint = checkpoint
        self.diagnostics = diagnostics
        self.editEntries = editEntries
    }
}

public enum UsageJSONLParser {
    /// 解析器版本。v2：稳健 RFC3339（无 distantPast 回退）、原始 session 活动事件、
    /// 基于原始 session id 的稳定 session hash、血缘证明去重（rollout/parent/inherited +
    /// 完整 total 快照指纹）、unknown model backfill。
    /// v3：新增 Claude subagent transcript 处理（token 计入、不产生 session 事件、
    /// 不做 thinking 拆分）与「原生 reasoning 缺失时按 thinking/其余输出字符比例
    /// 拆分 output→reasoning（round-half-up，仅 Anthropic 家族）」。
    /// v4：来源分派泛化 —— 仅内建 codex 走 rollout 解析路径，其余任意来源（包括
    ///   用户在本地配置里声明的 Claude-compatible transcript 来源）统一走 Claude
    ///   transcript 解析路径。thinking→reasoning 拆分仍仅对 Anthropic 家族模型生效
    ///   （model 门控 isAnthropicModel），因此 seed 类模型不会被拆分。
    /// v5：原始事件开始携带 tool 指标（技能 / MCP 调用计数）与已应用编辑行记录
    ///   （Edit / Write / MultiEdit / NotebookEdit 结构化差分，及 Codex apply_patch
    ///   正文的 +/- 计数），均以成功 gate 与 toolUseID 去重为准；用于代码行数指标 v2。
    /// v6：count-only 事件改用 source/session/turn/call 稳定身份并按同 turn 取最大，
    ///   直接 MCP 调用也必须由匹配 output 确认成功；修正 total 快照语义与 reasoning
    ///   比例拆分的 Int64 溢出边界。
    /// v7：codex token 事件新增内容型去重键（codexDedupKey：model + 归一化 last 分量 +
    ///   原始 total 快照分量，不含 timestamp/path/session/rollout），供跨文件折叠
    ///   fork/subagent 回放出的重复 turn，消除历史累计的重复计数。
    public static let parserVersion = 7

    /// 内建 rollout 来源标识。仅此来源走 Codex rollout 解析；其余一切来源按
    /// Claude transcript 处理。集中定义，避免分派处散落魔法字符串。
    public static let codexSource = "codex"

    public static func fileID(for identity: String) -> String { hash(identity) }

    /// 解析一个来源文件。
    ///
    /// - isSubagent: 该文件是否为子代理（subagent / Task）transcript。子代理转录只计入
    ///   token 用量，不产生任何 session 活动事件（否则会按 fork 数量放大会话计数 /
    ///   活跃时间），且不做 thinking→reasoning 拆分（拆分只在 output 与 reasoning 之间
    ///   移动 token，二者同价，总量与成本不变；子代理属次要路径，省略该细分可接受）。
    ///   仅 Claude-compatible 来源（除内建 codex 外的一切来源）会使用此标志。
    public static func parse(data: Data, source: String, fileIdentity: String, modifiedAt: Date = Date(), isSubagent: Bool = false) -> ParsedUsageFile {
        let fileHash = fileID(for: fileIdentity)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var diagnostics: [String] = []
        var sessionEvents: [UsageSessionEvent] = []
        var editEntries: [UsageEditEntry] = []
        // 唯一的 rollout 来源是内建 codex；其余任意来源都按 Claude-compatible
        // transcript 解析（用户本地配置声明的来源即走这条路径）。
        let events = source == codexSource
            ? parseCodex(lines, source: source, fileHash: fileHash, sessionEvents: &sessionEvents, editEntries: &editEntries, diagnostics: &diagnostics)
            : parseClaude(lines, source: source, fileHash: fileHash, isSubagent: isSubagent, sessionEvents: &sessionEvents, editEntries: &editEntries, diagnostics: &diagnostics)
        return ParsedUsageFile(
            events: events,
            sessionEvents: sessionEvents,
            checkpoint: UsageFileCheckpoint(fileID: fileHash, source: source, pathHash: fileHash, offset: Int64(data.count), size: Int64(data.count), modifiedAt: modifiedAt, parserVersion: parserVersion, status: diagnostics.isEmpty ? "complete" : "degraded"),
            diagnostics: diagnostics,
            editEntries: editEntries
        )
    }

    // MARK: - Codex

    private struct CodexMetadata {
        var sessionHash: String
        var rolloutKey: String
        var parentRolloutKey: String
        var project: String
        var hasSessionIdentity: Bool
        var hasParentReference: Bool
        var hasParentConflict: Bool
    }

    private static func parseCodex(_ lines: [Data.SubSequence], source: String, fileHash: String, sessionEvents: inout [UsageSessionEvent], editEntries: inout [UsageEditEntry], diagnostics: inout [String]) -> [UsageEvent] {
        let sourceName = "codex"
        let metadata = codexMetadata(lines, fileHash: fileHash)
        // A Codex rollout file is the session boundary. Session identity must be
        // stable across archival moves (sessions/ -> archived_sessions/), so it is
        // keyed by the rollout's own stable id rather than the mutable file path.
        // The conversation session_id is deliberately not used: it is shared by
        // many rollout files of the same conversation, so it would merge distinct
        // rollouts into one session. Rollouts without payload.id have no stable
        // per-rollout identity and fall back to the file identity (fail-safe).
        let activitySessionHash = codexActivitySessionHash(metadata: metadata, fileHash: fileHash)
        if metadata.hasParentConflict {
            diagnostics.append("session_meta: conflicting parent references; lineage replay disabled")
        }

        var turnModel = "unknown"
        var turnIdentity = "pre-context"
        var seenFirstTurnContext = false
        var previousCumulative: UsageTokenCounts?
        var result: [UsageEvent] = []
        var editAccumulator = CodexEditAccumulator(source: sourceName, project: metadata.project, sourceFileHash: fileHash)
        var codexEventOccurrences = [String: Int]()
        var seenSessionEventIDs = Set<String>()
        // 技能 / MCP count-only 事件统一按稳定的 session/turn/call 身份聚合；直接 MCP 与
        // programmatic JS 都由 mcpAccumulator 按 call_id 关联输出后结算。
        var codexToolCandidates: [String: CodexToolCandidate] = [:]
        var mcpAccumulator = CodexProgrammaticMCPAccumulator(source: sourceName, project: metadata.project)

        for (index, line) in lines.enumerated() {
            guard let object = json(line) else { diagnostics.append("line \(index + 1): invalid json"); continue }
            let type = string(object["type"])
            let payload = dictionary(object["payload"])

            if type == "turn_context" {
                if let authoritativeModel = nonemptyString(payload["model"]) {
                    turnModel = authoritativeModel
                }
                turnIdentity = nonemptyString(payload["turn_id"])
                    ?? nonemptyString(payload["id"])
                    ?? "context:\(hash(canonicalJSON(payload) ?? String(index)))"
                // The semantic boundary applies even when this record has no usable timestamp.
                seenFirstTurnContext = true
            }

            // 编辑关联：response_item 里的 apply_patch 调用与其执行输出（按 call_id 关联）。
            // 用当前 turn 的 model 与会话 project 归属；缺时间戳的调用行以 0 时间兜底归桶。
            if type == "response_item" {
                // 缺时间戳的调用记录无法归桶：不生成可计入 entry，仅发脱敏 diagnostic；
                // 但 *_call_output 记录仍照常处理，保证已有 pending 的成功 gate 不被漏掉。
                let editTimestamp = UsageTimestamp.parse(object["timestamp"])
                if editAccumulator.observe(payload: payload, model: turnModel, timestamp: editTimestamp) {
                    diagnostics.append("line \(index + 1): edit call skipped (missing timestamp)")
                }
                // Codex 无 Skill tool。技能调用两种信号（一条记录至多命中其一，不重复计数）：
                //   1. 旧格式 —— exec/shell function_call 命令真正读取 <name>/SKILL.md；
                //   2. 新格式 —— 用户消息里 [$name](…/SKILL.md) 的 $skill 提及。
                // 技能读取 / 提及可直接观察；直接 function_call 形态与 programmatic JS 的
                // MCP 都交由 mcpAccumulator，以匹配 output 成功 gate 后结算。
                var recordSkillCounts = UsageToolMetrics.countCodexSkillReads(object)
                if recordSkillCounts.isEmpty {
                    recordSkillCounts = UsageToolMetrics.countCodexSkillMarkers(object)
                }
                if !recordSkillCounts.isEmpty,
                   let toolTimestamp = UsageTimestamp.parse(object["timestamp"]) {
                    accumulateCodexToolCandidate(
                        into: &codexToolCandidates,
                        identity: codexToolIdentity(payload: payload, turnIdentity: turnIdentity),
                        model: turnModel, project: metadata.project, timestamp: toolTimestamp,
                        skillCounts: recordSkillCounts, mcpCounts: [:]
                    )
                }
                // programmatic MCP：custom_tool_call(name=exec) 的 JS 里 tools.mcp__… 调用，
                // 按 call_id 与其 *_call_output 关联，输出成功（Script completed）才计入。
                // 缺时间戳的调用记录跳过并上报；其输出记录仍处理以结算 gate。
                let mcpTimestamp = UsageTimestamp.parse(object["timestamp"])
                if mcpAccumulator.observe(
                    payload: payload, model: turnModel, timestamp: mcpTimestamp,
                    identity: codexToolIdentity(payload: payload, turnIdentity: turnIdentity)
                ) {
                    diagnostics.append("line \(index + 1): mcp call skipped (missing timestamp)")
                }
            }

            // Every timestamped rollout record participates in the session
            // timeline. session_meta/turn_context anchor user turns; all other
            // records, including token_count, extend assistant activity.
            let sessionRole: UsageSessionEvent.Role = (type == "session_meta")
                ? .syntheticUser
                : (type == "turn_context" ? .user : .assistant)
            if UsageTimestamp.parse(object["timestamp"]) != nil {
                appendSessionEvent(
                    &sessionEvents, source: sourceName, sessionHash: activitySessionHash,
                    sourceFileHash: fileHash,
                    identitySessionScope: activitySessionHash,
                    role: sessionRole,
                    object: object, seenIDs: &seenSessionEventIDs,
                    diagnostics: &diagnostics, index: index,
                    occurrence: index
                )
            }

            guard type == "event_msg", string(payload["type"]) == "token_count" else { continue }
            let info = dictionary(payload["info"])
            let lastUsage = dictionary(info["last_token_usage"])
            let totalUsage = dictionary(info["total_token_usage"])
            guard !lastUsage.isEmpty || !totalUsage.isEmpty else { continue }

            let normalizedLast = lastUsage.isEmpty ? codexCounts(totalUsage) : codexCounts(lastUsage)
            let normalizedTotal = totalUsage.isEmpty ? nil : codexCounts(totalUsage)
            let hasTotalSnapshot = completeCodexTotalSnapshot(totalUsage)
            let counts: UsageTokenCounts

            if lastUsage.isEmpty {
                diagnostics.append("line \(index + 1): cumulative fallback")
                if let priorCumulative = previousCumulative {
                    if cumulativeRegressed(normalizedLast, from: priorCumulative) {
                        diagnostics.append("line \(index + 1): cumulative rollback; baseline reset")
                        counts = normalizedLast
                    } else {
                        counts = subtract(normalizedLast, priorCumulative)
                    }
                } else {
                    counts = normalizedLast
                }
                previousCumulative = normalizedLast
            } else {
                counts = normalizedLast
                if let normalizedTotal {
                    previousCumulative = normalizedTotal
                }
            }

            guard counts.total > 0 else { continue }
            guard let timestamp = UsageTimestamp.parse(object["timestamp"]) else {
                diagnostics.append("line \(index + 1): invalid timestamp (usage skipped)")
                continue
            }

            let modelAtEmission = nonemptyString(info["model"]) ?? turnModel
            let inherited = metadata.hasParentReference && !seenFirstTurnContext
            let fingerprintRoot = inherited ? metadata.parentRolloutKey : metadata.rolloutKey
            let canProveLineage = hasTotalSnapshot && !metadata.hasParentConflict && !fingerprintRoot.isEmpty
            let lineageFingerprint = canProveLineage
                ? totalSnapshotFingerprint(root: fingerprintRoot, last: normalizedLast, total: normalizedTotal!)
                : ""
            let baseEventID = codexEventID(
                identityScope: codexEventIdentityScope(metadata), modelAtEmission: modelAtEmission,
                last: normalizedLast, completeTotal: hasTotalSnapshot ? normalizedTotal : nil
            )
            // Codex emits one token_count per turn; repeated identical events within
            // a file are real repeated usage and are each counted once (matching the
            // reference collector, which keeps every codex entry). The first
            // occurrence keeps its stable id; later occurrences get an ordinal
            // suffix so they are distinct events rather than collapsing into one.
            let occurrence = codexEventOccurrences[baseEventID, default: 0]
            codexEventOccurrences[baseEventID] = occurrence + 1
            let eventID = occurrence == 0 ? baseEventID : "\(baseEventID)#\(occurrence)"

            // 仅在有完整 total 快照时生成内容型去重键（与参考实现一致）；缺快照的行
            // 键为空，永不折叠，交由血缘层判定。
            let codexDedupKey = hasTotalSnapshot
                ? codexContentDedupKey(model: modelAtEmission, last: normalizedLast, rawTotal: totalUsage)
                : ""

            result.append(UsageEvent(
                id: eventID, source: sourceName, model: modelAtEmission, project: metadata.project,
                timestamp: timestamp, counts: counts, sessionHash: activitySessionHash, sourceFileHash: fileHash,
                rolloutKey: metadata.rolloutKey, parentRolloutKey: metadata.parentRolloutKey, inherited: inherited,
                hasTotalSnapshot: hasTotalSnapshot, lineageFingerprint: lineageFingerprint,
                codexDedupKey: codexDedupKey
            ))
        }

        // Only a rollout with no parent evidence can safely attribute pre-context unknown rows
        // to a model discovered later in this same file. IDs retain the emission-time model.
        if !metadata.hasParentReference, !isUnknownModel(turnModel) {
            result = result.map { event in
                guard isUnknownModel(event.model) else { return event }
                return UsageEvent(
                    id: event.id, source: event.source, model: turnModel, project: event.project,
                    timestamp: event.timestamp, counts: event.counts, sessionHash: event.sessionHash,
                    sourceFileHash: event.sourceFileHash, rolloutKey: event.rolloutKey,
                    parentRolloutKey: event.parentRolloutKey, inherited: event.inherited,
                    hasTotalSnapshot: event.hasTotalSnapshot, lineageFingerprint: event.lineageFingerprint,
                    codexDedupKey: event.codexDedupKey
                )
            }
        }
        editEntries.append(contentsOf: editAccumulator.finalize())
        // MCP 结算：直接 function_call 与 programmatic JS 都只在匹配 output 成功后计数。
        for pending in mcpAccumulator.finalize() {
            accumulateCodexToolCandidate(
                into: &codexToolCandidates, identity: pending.identity,
                model: pending.model, project: metadata.project, timestamp: pending.timestamp,
                skillCounts: [:], mcpCounts: pending.counts
            )
        }
        result.append(contentsOf: codexToolCandidates.values
            .sorted { $0.timestamp < $1.timestamp }
            .map {
                codexToolCountEvent(
                    source: sourceName, identity: $0.identity, model: $0.model, project: $0.project,
                    timestamp: $0.timestamp, sessionHash: activitySessionHash, fileHash: fileHash,
                    skillCounts: $0.skillCounts, mcpCounts: $0.mcpCounts
                )
            })
        return result
    }

    /// 从单个 Codex rollout 提取「已应用且成功」的 apply_patch 编辑行记录。
    ///
    /// 覆盖三种真实形态：(a) custom_tool_call（input 为原始补丁正文）；(b) function_call
    /// exec_command（arguments 为含 cmd 的 JSON 字符串，cmd 内含补丁）；(c) Programmatic
    /// Tool Calling —— custom_tool_call(name=exec)，其 JavaScript 里可证明地调用
    /// tools.apply_patch(<静态字符串>)。按 call_id 关联对应的 *_call_output：programmatic
    /// 调用以「Script completed」包装状态为权威 gate，其余以通用成功标记 gate；仅成功才计入。
    /// 调用与输出可能乱序到达（输出先于调用），两侧都记录、finalize 时按 call_id 结算。
    private struct CodexEditAccumulator {
        let source: String
        let project: String
        let sourceFileHash: String
        var pending: [String: UsageEditEntry] = [:]
        var applied: [String: Bool] = [:]
        /// call_id -> 该调用是否为 programmatic exec（决定用哪套输出成功 gate）。
        var programmatic: [String: Bool] = [:]
        /// call_id -> 已到达输出的两套判定，供乱序（输出先到）时结算。
        var outputGate: [String: (legacy: Bool, programmatic: Bool)] = [:]

        /// 观察一条 response_item。返回 true 表示：本记录是一笔可归桶的 apply_patch 调用，
        /// 但因缺少可用时间戳而被跳过（调用者据此发脱敏 diagnostic）。*_call_output 记录
        /// 不依赖自身时间戳，永远参与成功 gate 结算，返回 false。
        @discardableResult
        mutating func observe(payload: [String: Any], model: String, timestamp: Date?) -> Bool {
            let itemType = (payload["type"] as? String) ?? ""
            if let callID = Self.callID(payload), itemType.hasSuffix("call_output") {
                let output = Self.outputText(payload["output"])
                let gate = (legacy: UsageEditLines.codexExecIsApplied(output),
                            programmatic: UsageEditLines.codexProgrammaticExecIsApplied(output))
                outputGate[callID] = gate
                // 已知调用形态则立即结算；否则等 finalize 时按记录的形态选 gate。
                if let isProgrammatic = programmatic[callID] {
                    applied[callID] = isProgrammatic ? gate.programmatic : gate.legacy
                }
                return false
            }
            guard let callID = Self.callID(payload) else { return false }
            let extracted = Self.patchBodyWithProtocol(payload)
            guard let command = extracted.body else { return false }
            guard let delta = UsageEditLines.codexApplyPatchLines(command) else { return false }
            if delta.added == 0 && delta.deleted == 0 { return false }
            // 缺时间戳的调用无法归桶：不生成 pending，但仍登记调用形态，让其输出到达时
            // 不至于被当成孤立 output（success gate 仍按形态选择，只是没有可计入的 entry）。
            guard let timestamp else {
                programmatic[callID] = extracted.programmatic
                return true
            }
            pending[callID] = UsageEditEntry(
                source: source, model: model, project: project, sourceFileHash: sourceFileHash, timestamp: timestamp,
                added: delta.added, deleted: delta.deleted, toolUseID: callID
            )
            programmatic[callID] = extracted.programmatic
            if extracted.programmatic {
                // programmatic：若输出已先到，用 programmatic gate 结算。
                if let gate = outputGate[callID] { applied[callID] = gate.programmatic }
            } else {
                // 非 programmatic：调用 payload 可能带权威 status；输出到达时会覆盖它。
                if let status = payload["status"] as? String {
                    if status == "completed" { applied[callID] = true }
                    else if status == "failed" { applied[callID] = false }
                }
                if let gate = outputGate[callID] { applied[callID] = gate.legacy }
            }
            return false
        }

        func finalize() -> [UsageEditEntry] {
            pending.compactMap { id, entry in applied[id] == true ? entry : nil }
        }

        private static func callID(_ payload: [String: Any]) -> String? {
            if let id = payload["call_id"] as? String, !id.isEmpty { return id }
            if let id = payload["id"] as? String, !id.isEmpty { return id }
            return nil
        }

        /// 从调用 payload 里取出含 apply_patch 的命令文本，并标注是否为 programmatic 形态。
        /// - custom_tool_call(name=exec)：input 是 JS，仅在可证明 tools.apply_patch 时还原正文（programmatic）；
        ///   否则若 input 本身是裸补丁正文则按非 programmatic 处理，避免 JS 诊断脚本落入 marker-only 判定。
        /// - custom_tool_call（其余）：input 直接是补丁正文。
        /// - function_call(exec_command)：arguments 是 JSON 字符串，优先解出内层 cmd（还原被转义的换行），
        ///   否则回退到 arguments 原文。
        private static func patchBodyWithProtocol(_ payload: [String: Any]) -> (body: String?, programmatic: Bool) {
            let payloadType = (payload["type"] as? String) ?? ""
            let name = (payload["name"] as? String) ?? ""
            if let input = payload["input"] as? String, !input.isEmpty {
                if payloadType == "custom_tool_call" && name == "exec" {
                    if let body = UsageEditLines.codexProgrammaticPatchBody(input) {
                        return (body, true)
                    }
                    // 保留假想的裸补丁 custom exec，同时不让 JS 诊断脚本落入 marker-only 检测。
                    if input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("*** Begin Patch") {
                        return (input, false)
                    }
                    return (nil, false)
                }
                if input.contains("*** Begin Patch") { return (input, false) }
            }
            if let arguments = payload["arguments"] as? String, arguments.contains("*** Begin Patch") {
                // 现代 Codex Desktop 把 exec_command 参数记为 JSON 串：{"cmd":"…\n*** Begin Patch\n…"}。
                // 外层 JSONL 解析后内层换行仍是字面 "\n"，直接扫 wrapper 找得到标记却无法按行切分
                // （每笔补丁贡献 0 行）。故优先解出内层 cmd，其次回退裸 arguments。
                if let data = arguments.data(using: .utf8),
                   let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let cmd = object["cmd"] as? String, cmd.contains("*** Begin Patch") {
                    return (cmd, false)
                }
                return (arguments, false)
            }
            return (nil, false)
        }

        /// 把 *_call_output 的 output 字段归一为可判定成功的字符串。
        /// output 可能是字符串、含 output/text/content 等字段的对象，或 programmatic 形态的
        /// [{type:"input_text",text:…}] 数组（按 input_text 文本以换行拼接）。
        private static func outputText(_ value: Any?) -> String {
            if let s = value as? String { return s }
            if let items = value as? [Any] {
                var parts: [String] = []
                for item in items {
                    guard let m = item as? [String: Any] else { continue }
                    if (m["type"] as? String) == "input_text", let text = m["text"] as? String, !text.isEmpty {
                        parts.append(text)
                    }
                }
                return parts.joined(separator: "\n")
            }
            if let object = value as? [String: Any] {
                for key in ["output", "text", "content", "stdout"] {
                    if let s = object[key] as? String { return s }
                }
                if let data = try? JSONSerialization.data(withJSONObject: object),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
            }
            return ""
        }
    }

    private struct CodexToolCandidate {
        let identity: String
        var model: String
        var project: String
        var timestamp: Date
        var skillCounts: [String: Int]
        var mcpCounts: [String: Int]
    }

    private static func accumulateCodexToolCandidate(
        into candidates: inout [String: CodexToolCandidate], identity: String,
        model: String, project: String, timestamp: Date,
        skillCounts: [String: Int], mcpCounts: [String: Int]
    ) {
        let normalizedSkills = UsageToolMetrics.normalizeCounts(skillCounts)
        let normalizedMCP = UsageToolMetrics.normalizeCounts(mcpCounts)
        if normalizedSkills.isEmpty && normalizedMCP.isEmpty { return }
        if var existing = candidates[identity] {
            if isUnknownModel(existing.model), !isUnknownModel(model) { existing.model = model }
            if existing.project == "unknown", project != "unknown" { existing.project = project }
            existing.timestamp = max(existing.timestamp, timestamp)
            existing.skillCounts = maxCounts(existing.skillCounts, normalizedSkills)
            existing.mcpCounts = maxCounts(existing.mcpCounts, normalizedMCP)
            candidates[identity] = existing
        } else {
            candidates[identity] = CodexToolCandidate(
                identity: identity, model: model, project: project, timestamp: timestamp,
                skillCounts: normalizedSkills, mcpCounts: normalizedMCP
            )
        }
    }

    private static func codexToolIdentity(payload: [String: Any], turnIdentity: String) -> String {
        if let callID = nonemptyString(payload["call_id"]) ?? nonemptyString(payload["id"]) {
            return "turn:\(turnIdentity)|call:\(callID)"
        }
        let message = dictionary(payload["message"])
        if let messageID = nonemptyString(message["id"]) {
            return "turn:\(turnIdentity)|message:\(messageID)"
        }
        return "turn:\(turnIdentity)"
    }

    /// 物化一条 Codex 技能 / MCP 的零-token count-only 事件（稳定逻辑身份 id）。
    /// 与 Claude count-only 路径同构：token 恒 0（工具记录不是模型调用，不重复计 token），
    /// id 绑定 source/session/turn/call —— 同一 turn 的重写折叠为一条，而不同会话或调用
    /// 不会被并掉；账本层以 cumulativeMax 逐维取最大。
    private static func codexToolCountEvent(
        source: String, identity: String, model: String, project: String, timestamp: Date,
        sessionHash: String, fileHash: String,
        skillCounts: [String: Int], mcpCounts: [String: Int]
    ) -> UsageEvent {
        let normalizedSkills = UsageToolMetrics.normalizeCounts(skillCounts)
        let normalizedMCP = UsageToolMetrics.normalizeCounts(mcpCounts)
        let id = hash("\(source)|tool-count-only|session:\(sessionHash)|\(identity)")
        return UsageEvent(
            id: id, source: source, model: model, project: project, timestamp: timestamp,
            counts: UsageTokenCounts(),
            sessionHash: sessionHash, sourceFileHash: fileHash,
            rolloutKey: sessionHash, parentRolloutKey: "", inherited: false,
            hasTotalSnapshot: false, lineageFingerprint: "",
            mergeStrategy: .cumulativeMax,
            skillCounts: normalizedSkills, mcpCounts: normalizedMCP
        )
    }

    /// MCP 累加器：直接 function_call 与 custom_tool_call(name=exec) 的 programmatic JS
    /// 调用都按 call_id 记为待定，仅当匹配 *_call_output 成功时才结算。programmatic 路径
    /// 仅认「Script completed」终态，并支持 wait-cell 续接：输出返回
    /// 「Script running with cell ID …」时记录 cell→origin，后续 wait 调用的输出据此归回原调用。
    /// 调用 / 输出可能乱序（输出先到），两侧都留痕，finalize 只吐已成功的。
    ///
    /// 说明（跨扫描持久化缺口）：本累加器仅在「单次整文件扫描」内成立。要在增量追加扫描里
    /// 跨批次续接一个仍在 running 的 wait-cell，需把未决调用（含 running cell / wait 关联）
    /// 持久化到解析检查点。此处的 ParsedUsageFile / UsageFileCheckpoint 没有对应字段，
    /// 故不做跨扫描续接，也不用进程内状态伪造。
    private struct CodexProgrammaticMCPAccumulator {
        let source: String
        let project: String
        private var pending: [String: PendingMCP] = [:]
        private var applied: [String: Bool] = [:]
        private var outputOutcomes: [String: OutputGate] = [:]
        private var runningByCell: [String: String] = [:]
        private var waitOrigins: [String: String] = [:]

        init(source: String, project: String) {
            self.source = source
            self.project = project
        }

        private enum GateKind { case direct, programmatic }
        private struct PendingMCP { let identity: String; let model: String; let timestamp: Date; let counts: [String: Int]; let gate: GateKind }
        struct Resolved { let identity: String; let model: String; let timestamp: Date; let counts: [String: Int] }
        private struct OutputGate {
            let programmaticApplied: Bool
            let programmaticResolved: Bool
            let directApplied: Bool
            let runningCellID: String
        }

        /// 观察一条 response_item。返回 true 表示：本记录是一笔可计数的 programmatic MCP 调用
        /// （JS 里可达的 tools.mcp__…），但因缺少可用时间戳被跳过（调用者据此发脱敏 diagnostic）。
        /// wait 调用与 *_call_output 记录不依赖自身时间戳，返回 false。
        @discardableResult
        mutating func observe(payload: [String: Any], model: String, timestamp: Date?, identity: String) -> Bool {
            let itemType = (payload["type"] as? String) ?? ""
            let name = ((payload["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if itemType == "custom_tool_call" || itemType == "function_call" {
                guard let id = Self.callID(payload) else { return false }
                if name == "wait" {
                    observeWaitCall(waitID: id, arguments: (payload["arguments"] as? String) ?? "")
                    return false
                }
                let counts: [String: Int]
                let gate: GateKind
                if itemType == "function_call" {
                    counts = UsageToolMetrics.countCodexMCPToolUsePayload(payload)
                    gate = .direct
                } else if name == "exec" {
                    counts = CodexProgrammaticMCP.toolUses((payload["input"] as? String) ?? "")
                    gate = .programmatic
                } else {
                    return false
                }
                if counts.isEmpty { return false }
                // 缺时间戳的调用无法归桶：不生成 pending（也不登记 running/wait），跳过并上报。
                guard let timestamp else { return true }
                pending[id] = PendingMCP(identity: identity, model: model, timestamp: timestamp, counts: counts, gate: gate)
                if let outcome = outputOutcomes[id] {
                    applyOutcome(origin: id, outcome: outcome)
                    outputOutcomes[id] = nil
                }
                return false
            }
            if itemType == "custom_tool_call_output" || itemType == "function_call_output" {
                guard let id = Self.callID(payload) else { return false }
                let output = Self.outputText(payload["output"])
                let programmatic = UsageEditLines.codexProgrammaticExecOutcome(output)
                let outcome = OutputGate(
                    programmaticApplied: programmatic.applied,
                    programmaticResolved: programmatic.resolved,
                    directApplied: UsageToolMetrics.codexMCPFunctionOutputIsSuccess(output),
                    runningCellID: UsageEditLines.codexProgrammaticRunningCellID(output)
                )
                if let origin = waitOrigins[id] {
                    applyOutcome(origin: origin, outcome: outcome)
                    waitOrigins[id] = nil
                    outputOutcomes[id] = nil
                } else if pending[id] != nil {
                    applyOutcome(origin: id, outcome: outcome)
                    outputOutcomes[id] = nil
                } else {
                    outputOutcomes[id] = outcome
                }
                return false
            }
            return false
        }

        private mutating func applyOutcome(origin: String, outcome: OutputGate) {
            if origin.isEmpty { return }
            guard let entry = pending[origin] else { return }
            if entry.gate == .direct {
                applied[origin] = outcome.directApplied
                return
            }
            if !outcome.runningCellID.isEmpty {
                runningByCell[outcome.runningCellID] = origin
            }
            if outcome.programmaticResolved {
                applied[origin] = outcome.programmaticApplied
                for (cellID, cellOrigin) in runningByCell where cellOrigin == origin {
                    runningByCell[cellID] = nil
                }
            }
        }

        private mutating func observeWaitCall(waitID: String, arguments: String) {
            if waitID.isEmpty || arguments.isEmpty { return }
            let origin = runningByCell[Self.waitCellID(arguments)] ?? ""
            if origin.isEmpty { return }
            waitOrigins[waitID] = origin
            if let outcome = outputOutcomes[waitID] {
                applyOutcome(origin: origin, outcome: outcome)
                waitOrigins[waitID] = nil
                outputOutcomes[waitID] = nil
            }
        }

        func finalize() -> [Resolved] {
            var out: [Resolved] = []
            for (id, entry) in pending where applied[id] == true {
                out.append(Resolved(identity: entry.identity, model: entry.model, timestamp: entry.timestamp, counts: entry.counts))
            }
            return out.sorted { $0.timestamp < $1.timestamp }
        }

        private static func callID(_ payload: [String: Any]) -> String? {
            if let id = payload["call_id"] as? String, !id.isEmpty { return id }
            if let id = payload["id"] as? String, !id.isEmpty { return id }
            return nil
        }

        /// 从 wait 调用的 arguments（JSON 串）里取 cell id（session_id / cell_id / id）。
        private static func waitCellID(_ arguments: String) -> String {
            guard let data = arguments.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
            for key in ["session_id", "cell_id", "cellID", "id"] {
                if let v = object[key] as? String, !v.isEmpty { return v }
                if let n = object[key] as? NSNumber { return n.stringValue }
            }
            return ""
        }

        private static func outputText(_ value: Any?) -> String {
            if let s = value as? String { return s }
            if let items = value as? [Any] {
                var parts: [String] = []
                for item in items {
                    guard let m = item as? [String: Any] else { continue }
                    if (m["type"] as? String) == "input_text", let text = m["text"] as? String, !text.isEmpty {
                        parts.append(text)
                    }
                }
                return parts.joined(separator: "\n")
            }
            if let object = value as? [String: Any] {
                for key in ["output", "text", "content", "stdout"] {
                    if let s = object[key] as? String { return s }
                }
                if let data = try? JSONSerialization.data(withJSONObject: object),
                   let s = String(data: data, encoding: .utf8) {
                    return s
                }
            }
            return ""
        }
    }

    private static func codexMetadata(_ lines: [Data.SubSequence], fileHash: String) -> CodexMetadata {
        let fallback = String(fileHash.prefix(16))
        var metadata = CodexMetadata(
            sessionHash: fallback, rolloutKey: "", parentRolloutKey: "", project: "unknown",
            hasSessionIdentity: false,
            hasParentReference: false, hasParentConflict: false
        )
        for line in lines {
            guard let object = json(line), string(object["type"]) == "session_meta" else { continue }
            let payload = dictionary(object["payload"])
            if let rolloutID = nonemptyString(payload["id"]) {
                metadata.rolloutKey = shortHash(rolloutID)
            }
            if let sessionID = nonemptyString(payload["session_id"]) {
                metadata.sessionHash = shortHash(sessionID)
                metadata.hasSessionIdentity = true
            }
            if let cwd = nonemptyString(payload["cwd"]) {
                metadata.project = component(cwd)
            }

            let source = dictionary(payload["source"])
            let subagent = dictionary(source["subagent"])
            let threadSpawn = dictionary(subagent["thread_spawn"])
            let parents = [
                nonemptyString(payload["parent_thread_id"]),
                nonemptyString(payload["forked_from_id"]),
                nonemptyString(threadSpawn["parent_thread_id"]),
            ].compactMap { $0 }
            let uniqueParents = Set(parents)
            metadata.hasParentReference = !uniqueParents.isEmpty
            metadata.hasParentConflict = uniqueParents.count > 1
            if uniqueParents.count == 1, let parent = uniqueParents.first {
                metadata.parentRolloutKey = shortHash(parent)
            }
            return metadata
        }
        return metadata
    }

    /// Codex 会话活动身份：rollout 文件在 sessions/ 与 archived_sessions/ 之间移动时路径会变，
    /// 因此不能用文件路径做 session key。优先 rollout 自带的稳定 ID（payload.id，每个 rollout
    /// 文件唯一）。会话 ID（session_id）不能用：同一会话的多个 rollout 共享它，会把不同
    /// rollout 合并成一个 session。缺 payload.id 时没有稳定的 per-rollout 身份，直接以文件
    /// 身份兜底（保持旧的路径键控行为，是该退化场景下的 fail-safe）。
    private static func codexActivitySessionHash(metadata: CodexMetadata, fileHash: String) -> String {
        if !metadata.rolloutKey.isEmpty { return metadata.rolloutKey }
        return String(fileHash.prefix(16))
    }

    private static func codexMessageRole(_ payload: [String: Any]) -> UsageSessionEvent.Role? {
        let rawRole = string(payload["role"]) ?? string(dictionary(payload["message"])["role"])
        return rawRole == "assistant" ? .assistant : nil
    }

    // MARK: - Claude

    private struct ClaudeCandidate { var model: String; var project: String; var timestamp: Date; var counts: UsageTokenCounts; var index: Int; var sessionHash: String; var skillCounts: [String: Int] = [:]; var mcpCounts: [String: Int] = [:] }

    private struct ClaudeToolCandidate {
        let identity: String
        var model: String
        var project: String
        var timestamp: Date
        var index: Int
        var sessionHash: String
        var skillCounts: [String: Int]
        var mcpCounts: [String: Int]
    }

    /// 从单个 Claude transcript 提取「已应用且成功」的编辑行记录。
    ///
    /// 把每个编辑 tool_use（在 assistant 消息里）与其 tool_result（在随后的 user 消息里）
    /// 按 tool_use.id 关联；仅当结果存在且非错误时才计入 —— 被提出 / 被拒 / 失败的编辑
    /// 绝不虚增指标。
    private struct ClaudeEditAccumulator {
        let source: String
        let sourceFileHash: String
        var pending: [String: UsageEditEntry] = [:]
        var applied: [String: Bool] = [:]

        /// 观察一条 assistant / user 记录。返回 true 表示：本记录含至少一笔可归桶的编辑
        /// tool_use，但因缺少可用时间戳被跳过（调用者据此发脱敏 diagnostic）。tool_result
        /// 只决定 applied gate、不依赖自身时间戳，永远处理。
        @discardableResult
        mutating func observe(_ object: [String: Any], model: String, project: String, timestamp: Date?) -> Bool {
            let message = object["message"] as? [String: Any] ?? [:]
            guard let content = message["content"] as? [Any] else { return false }
            var skippedForMissingTimestamp = false
            for item in content {
                guard let part = item as? [String: Any] else { continue }
                switch part["type"] as? String {
                case "tool_use":
                    guard let id = part["id"] as? String, !id.isEmpty else { continue }
                    guard let delta = UsageEditLines.claudeToolUseEditLines(part) else { continue }
                    if delta.added == 0 && delta.deleted == 0 { continue }
                    // 缺时间戳的编辑无法归桶：不生成 pending，标记以便上报（其 tool_result
                    // 仍会照常更新 applied，但没有可计入的 entry）。
                    guard let timestamp else { skippedForMissingTimestamp = true; continue }
                    pending[id] = UsageEditEntry(
                        source: source, model: model, project: project, sourceFileHash: sourceFileHash, timestamp: timestamp,
                        added: delta.added, deleted: delta.deleted, toolUseID: id
                    )
                case "tool_result":
                    guard let id = part["tool_use_id"] as? String, !id.isEmpty else { continue }
                    let isError = (part["is_error"] as? Bool) == true
                    applied[id] = !isError
                default:
                    break
                }
            }
            return skippedForMissingTimestamp
        }

        func finalize() -> [UsageEditEntry] {
            pending.compactMap { id, entry in applied[id] == true ? entry : nil }
        }
    }

    /// 单个 assistant turn 的 thinking 与其余输出（text / tool_use）的字符量累计。
    ///
    /// Claude Code 把一个 turn 写成共享同一 msg.id 的多行 jsonl —— 每行携带一个内容块，
    /// 但重复整 turn 的 usage（output_tokens 在每行相同，非叠加）。因此要在 thinking 与
    /// 其余输出之间分摊该 turn 的 output_tokens，必须跨该 turn 全部行 union 内容块。
    /// seen 去重 streaming / fork 重刷造成的逐字节相同块（同一块只计一次）。
    /// 加密的 signature 字段不计入；redacted_thinking 无明文，thinking 主导的 turn 只会
    /// 在 thinking 侧低估 —— 是诚实下界，绝不高估。
    private struct ClaudeTurnSplit {
        var thinkingChars: Int = 0
        var otherChars: Int = 0
        var seen: Set<String> = []

        mutating func mark(_ kind: String, _ payload: String) -> Bool {
            seen.insert("\(kind)\u{0}\(payload)").inserted
        }
    }

    private static func parseClaude(_ lines: [Data.SubSequence], source: String, fileHash: String, isSubagent: Bool, sessionEvents: inout [UsageSessionEvent], editEntries: inout [UsageEditEntry], diagnostics: inout [String]) -> [UsageEvent] {
        var messages: [String: ClaudeCandidate] = [:]
        // 记录每个候选 entry 归属的稳定 turn id（msg.id 优先，回退 uuid），
        // 用于扫描结束后按整 turn 字符比例做 thinking 拆分。空串表示不需要拆分。
        var candidateStableID: [String: String] = [:]
        var turnChars: [String: ClaudeTurnSplit] = [:]
        var seenSessionEventIDs = Set<String>()
        // 编辑累计器：跨全文件关联 tool_use 与 tool_result；子代理转录也计入代码行数
        // （代码行数只按 toolUseID 去重，不涉及会话计数放大问题）。
        var editAccumulator = ClaudeEditAccumulator(source: source, sourceFileHash: fileHash)
        // 所有结构化工具观测都按 source/session/message(turn) 稳定身份聚合。同一 turn 从
        // usage-less 重写为 usage-bearing 时只保留 token 事件，避免工具计数重复。
        var toolCandidates: [String: ClaudeToolCandidate] = [:]
        var usageToolIdentities = Set<String>()
        var candidateToolIdentity: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            guard let object = json(line) else { diagnostics.append("line \(index + 1): invalid json"); continue }
            let type = string(object["type"])
            let rawSessionID = string(object["sessionId"]) ?? string(object["session_id"])
            // 保留真实 sessionHash（每行自带 sessionId）；缺失时才以文件兜底。
            let sessionHash = rawSessionID.map { shortHash($0) } ?? shortHash(fileHash)

            // 编辑关联：assistant 记录里的编辑 tool_use 用该记录的 model/project/timestamp
            // 归属，user 记录里的 tool_result 决定是否已应用成功。缺时间戳时跳过（无法归桶）。
            if type == "assistant" || type == "user" {
                // 缺时间戳的编辑 tool_use 无法归桶：跳过并发脱敏 diagnostic；
                // 但 tool_result 仍照常处理，保证已有 pending 的 applied gate 不被漏掉。
                let editTimestamp = UsageTimestamp.parse(object["timestamp"])
                let editMessage = dictionary(object["message"])
                if editAccumulator.observe(
                    object,
                    model: string(editMessage["model"]) ?? "unknown",
                    project: string(object["cwd"]).map(component) ?? "unknown",
                    timestamp: editTimestamp
                ) {
                    diagnostics.append("line \(index + 1): edit call skipped (missing timestamp)")
                }
            }

            // 子代理转录不产生 session 事件：其会话计数 / 活跃时间只应反映主会话。
            if !isSubagent, type == "user" || type == "assistant" {
                let role: UsageSessionEvent.Role
                if type == "assistant" {
                    role = .assistant
                } else {
                    let message = dictionary(object["message"])
                    let isSynthetic = (object["isMeta"] as? Bool) == true
                        || (message["synthetic"] as? Bool) == true
                        || containsToolResult(message["content"])
                    role = isSynthetic ? .syntheticUser : .user
                }
                appendSessionEvent(
                    &sessionEvents, source: source, sessionHash: sessionHash,
                    sourceFileHash: fileHash,
                    identitySessionScope: rawSessionID == nil ? "missing-session" : sessionHash,
                    role: role, object: object,
                    seenIDs: &seenSessionEventIDs,
                    diagnostics: &diagnostics, index: index
                )
            }

            guard type == "assistant" else { continue }
            let message = dictionary(object["message"]); let usage = dictionary(message["usage"])
            let turnID = string(message["id"]) ?? string(object["uuid"]) ?? "line-\(index)"
            let toolIdentity = "session:\(sessionHash)|turn:\(turnID)"
            // 结构化技能 / MCP 计数：无论本记录是否带 usage 都先算，以便 usage-less turn 也能
            // 物化 count-only 事件。同 msg.id 的流式重刷携带相同内容，按维度取最大避免重复计数。
            let recordSkillCounts = UsageToolMetrics.countSkillToolUses(object)
            let recordMCPCounts = UsageToolMetrics.countMCPToolUses(object)
            if !recordSkillCounts.isEmpty || !recordMCPCounts.isEmpty,
               let timestamp = UsageTimestamp.parse(object["timestamp"]) {
                let model = string(message["model"]) ?? "unknown"
                let project = string(object["cwd"]).map(component) ?? "unknown"
                if var existing = toolCandidates[toolIdentity] {
                    if isUnknownModel(existing.model), !isUnknownModel(model) { existing.model = model }
                    if existing.project == "unknown", project != "unknown" { existing.project = project }
                    existing.timestamp = max(existing.timestamp, timestamp)
                    existing.index = min(existing.index, index)
                    existing.skillCounts = maxCounts(existing.skillCounts, recordSkillCounts)
                    existing.mcpCounts = maxCounts(existing.mcpCounts, recordMCPCounts)
                    toolCandidates[toolIdentity] = existing
                } else {
                    toolCandidates[toolIdentity] = ClaudeToolCandidate(
                        identity: toolIdentity, model: model, project: project, timestamp: timestamp,
                        index: index, sessionHash: sessionHash,
                        skillCounts: recordSkillCounts, mcpCounts: recordMCPCounts
                    )
                }
            }
            if usage.isEmpty {
                continue
            }
            let id = turnID
            // 累计该 turn 的 thinking / 其余输出字符（仅主转录需要，子代理不拆分）。
            if !isSubagent {
                accumulateClaudeTurnChars(message: message, turnID: id, into: &turnChars)
            }
            guard let timestamp = UsageTimestamp.parse(object["timestamp"]) else {
                diagnostics.append("line \(index + 1): invalid timestamp (usage skipped)")
                continue
            }
            usageToolIdentities.insert(toolIdentity)
            let counts = UsageTokenCounts(input: integer(usage["input_tokens"]), output: integer(usage["output_tokens"]), cachedInput: integer(usage["cache_read_input_tokens"]), cacheCreationInput: integer(usage["cache_creation_input_tokens"]), reasoningOutput: integer(usage["reasoning_output_tokens"]), reportedTotal: integer(usage["total_tokens"]))
            let candidate = ClaudeCandidate(model: string(message["model"]) ?? "unknown", project: string(object["cwd"]).map(component) ?? "unknown", timestamp: timestamp, counts: counts, index: index, sessionHash: sessionHash, skillCounts: recordSkillCounts, mcpCounts: recordMCPCounts)
            if let old = messages[id] {
                // 同 msg.id 保留最大累计 usage（Claude 流式增量）。真实 sessionHash 以先出现者为准。
                messages[id] = ClaudeCandidate(model: candidate.model == "unknown" ? old.model : candidate.model, project: candidate.project == "unknown" ? old.project : candidate.project, timestamp: max(old.timestamp, candidate.timestamp), counts: maximum(old.counts, candidate.counts), index: min(old.index, candidate.index), sessionHash: old.sessionHash.isEmpty ? candidate.sessionHash : old.sessionHash, skillCounts: maxCounts(old.skillCounts, candidate.skillCounts), mcpCounts: maxCounts(old.mcpCounts, candidate.mcpCounts))
            } else { messages[id] = candidate }
            candidateStableID[id] = id
            candidateToolIdentity[id] = toolIdentity
        }
        editEntries.append(contentsOf: editAccumulator.finalize())
        var events = messages.sorted { $0.value.index < $1.value.index }.map { id, value -> UsageEvent in
            var counts = value.counts
            // 原生 reasoning 缺失时，按 thinking / 其余输出字符比例把 output 拆一部分入
            // reasoning（round-half-up）。仅限 Anthropic 家族（该家族 reasoning 与 output
            // 同价，拆分不改变总花费），且非子代理路径。有原生 reasoning 时优先，不拆。
            if !isSubagent, counts.reasoningOutput == 0, counts.output > 0, isAnthropicModel(value.model),
               let split = turnChars[candidateStableID[id] ?? id] {
                let est = splitOutputTokens(thinkingChars: split.thinkingChars, otherChars: split.otherChars, outputTokens: counts.output)
                if est > 0 {
                    counts = UsageTokenCounts(
                        input: counts.input, output: counts.output - est,
                        cachedInput: counts.cachedInput, cacheCreationInput: counts.cacheCreationInput,
                        reasoningOutput: est, reportedTotal: counts.reportedTotal
                    )
                }
            }
            // Claude 同 msg.id 的累计增长依靠稳定 event id 在账本层 UPSERT 取最大，
            // 因此不生成 lineage 指纹（Claude 无跨文件继承回放问题）。
            let toolCandidate = candidateToolIdentity[id].flatMap { toolCandidates[$0] }
            return UsageEvent(
                id: hash("\(source)|message:\(id)"),
                source: source, model: value.model, project: value.project, timestamp: value.timestamp, counts: counts,
                sessionHash: value.sessionHash, sourceFileHash: fileHash,
                rolloutKey: value.sessionHash, parentRolloutKey: "", inherited: false,
                hasTotalSnapshot: false, lineageFingerprint: "",
                // Claude-compatible 路径：同 msg.id 流式累计增长，账本必须逐列取最大而非覆盖。
                mergeStrategy: .cumulativeMax,
                skillCounts: maxCounts(value.skillCounts, toolCandidate?.skillCounts ?? [:]),
                mcpCounts: maxCounts(value.mcpCounts, toolCandidate?.mcpCounts ?? [:])
            )
        }
        events.append(contentsOf: toolCandidates.values
            .filter { !usageToolIdentities.contains($0.identity) }
            .sorted { $0.index < $1.index }
            .map { candidate in
                UsageEvent(
                    id: hash("\(source)|tool-count-only|\(candidate.identity)"),
                    source: source, model: candidate.model, project: candidate.project,
                    timestamp: candidate.timestamp, counts: UsageTokenCounts(),
                    sessionHash: candidate.sessionHash, sourceFileHash: fileHash,
                    rolloutKey: candidate.sessionHash, parentRolloutKey: "", inherited: false,
                    hasTotalSnapshot: false, lineageFingerprint: "",
                    mergeStrategy: .cumulativeMax,
                    skillCounts: candidate.skillCounts, mcpCounts: candidate.mcpCounts
                )
            })
        return events
    }

    /// 跨该 turn 的所有行累计 thinking 与其余输出（text / tool_use）的字符量。
    private static func accumulateClaudeTurnChars(message: [String: Any], turnID: String, into turnChars: inout [String: ClaudeTurnSplit]) {
        guard let content = message["content"] as? [Any] else { return }
        var split = turnChars[turnID] ?? ClaudeTurnSplit()
        for item in content {
            guard let part = item as? [String: Any] else { continue }
            switch string(part["type"]) {
            case "thinking":
                if let value = string(part["thinking"]), !value.isEmpty, split.mark("t", value) {
                    split.thinkingChars += value.utf8.count
                }
            case "text":
                if let value = string(part["text"]), !value.isEmpty, split.mark("x", value) {
                    split.otherChars += value.utf8.count
                }
            case "tool_use":
                let name = string(part["name"]) ?? ""
                let inputJSON = canonicalJSONValue(part["input"]) ?? ""
                if name.utf8.count + inputJSON.utf8.count > 0, split.mark("u", "\(name)\u{0}\(inputJSON)") {
                    split.otherChars += name.utf8.count + inputJSON.utf8.count
                }
            default:
                break
            }
        }
        turnChars[turnID] = split
    }

    /// 按 thinking 字符占比把已知 output_tokens 分摊给 reasoning（round-half-up 整数拆分）。
    ///
    /// 不估算绝对 token（那需要无法内置且可能与计费不一致的分词器），而是拆分「已知总量」：
    /// 调用方从 output 中扣除该结果，turn 总量不变，字符→token 的换算偏差在比例里相消。
    /// 无 thinking 文本或无可拆分量时返回 0。
    private static func splitOutputTokens(thinkingChars: Int, otherChars: Int, outputTokens: Int64) -> Int64 {
        guard outputTokens > 0, thinkingChars > 0 else { return 0 }
        guard let thinking = UInt64(exactly: thinkingChars),
              let other = UInt64(exactly: otherChars) else { return 0 }
        let (denom, denomOverflow) = thinking.addingReportingOverflow(other)
        guard !denomOverflow, denom > 0 else { return 0 }

        // 用 128-bit full-width 乘法完成 round-half-up，避免 outputTokens * thinking
        // 以及 thinkingChars + otherChars 在 Int64 边界溢出。
        var product = UInt64(outputTokens).multipliedFullWidth(by: thinking)
        let half = denom / 2
        let (low, carry) = product.low.addingReportingOverflow(half)
        product.low = low
        if carry {
            let (high, highOverflow) = product.high.addingReportingOverflow(1)
            guard !highOverflow else { return outputTokens }
            product.high = high
        }
        let estimate = denom.dividingFullWidth(product).quotient
        return min(outputTokens, Int64(estimate))
    }

    /// 是否为 Anthropic / Claude 家族模型 —— 唯一保证 reasoning 与 output 同价的家族，
    /// thinking 拆分据此门控：拆分把 token 从 output（计费）移入 reasoning，若非该家族
    /// 且 reasoning 定价为 0，拆分会静默丢失总花费。
    private static func isAnthropicModel(_ model: String) -> Bool {
        let value = model.lowercased()
        return value.contains("claude") || value.contains("sonnet") || value.contains("haiku") || value.contains("opus")
    }

    /// 把任意 JSON 值稳定序列化为字符串（sortedKeys），用于 tool_use.input 的字符计量。
    private static func canonicalJSONValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let object = value as? [String: Any] { return canonicalJSON(object) }
        guard JSONSerialization.isValidJSONObject(["v": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["v": value], options: [.sortedKeys, .withoutEscapingSlashes]),
              let wrapped = String(data: data, encoding: .utf8)
        else { return String(describing: value) }
        return wrapped
    }

    // MARK: - Shared helpers

    private static func appendSessionEvent(_ sink: inout [UsageSessionEvent], source: String, sessionHash: String, sourceFileHash: String, identitySessionScope: String, role: UsageSessionEvent.Role, object: [String: Any], seenIDs: inout Set<String>, diagnostics: inout [String], index: Int, occurrence: Int? = nil) {
        guard let timestamp = UsageTimestamp.parse(object["timestamp"]) else {
            diagnostics.append("line \(index + 1): invalid timestamp (session event skipped)")
            return
        }
        guard let identity = semanticSessionEventIdentity(object) ?? canonicalJSON(object).map({ "json:\($0)" }) else {
            diagnostics.append("line \(index + 1): session event identity serialization failed")
            return
        }
        let occurrenceIdentity = occurrence.map { "|occurrence:\($0)" } ?? ""
        let id = hash("\(source)|session-event|\(identitySessionScope)|\(role.rawValue)|\(identity)\(occurrenceIdentity)")
        guard seenIDs.insert(id).inserted else { return }
        sink.append(UsageSessionEvent(id: id, source: source, sessionHash: sessionHash, sourceFileHash: sourceFileHash, role: role, timestamp: timestamp))
    }

    private static func semanticSessionEventIdentity(_ object: [String: Any]) -> String? {
        let type = nonemptyString(object["type"]) ?? ""
        let payload = dictionary(object["payload"])
        let message = dictionary(object["message"])
        switch type {
        case "session_meta":
            if let id = nonemptyString(payload["id"]) ?? nonemptyString(payload["session_id"]) {
                return "session-meta:\(id)"
            }
        case "turn_context":
            if let id = nonemptyString(payload["turn_id"]) ?? nonemptyString(payload["id"]) {
                return "turn-context:\(id)"
            }
        case "response_item":
            if string(payload["type"]) == "message",
               let id = nonemptyString(payload["id"]) ?? nonemptyString(dictionary(payload["message"])["id"])
            {
                return "message:\(id)"
            }
        case "event_msg":
            if let payloadType = nonemptyString(payload["type"]) {
                return "event:\(payloadType):\(canonicalJSON(payload) ?? "")"
            }
        case "user", "assistant":
            if let id = nonemptyString(message["id"]) ?? nonemptyString(object["uuid"]) {
                return "message:\(id)"
            }
        default:
            break
        }
        return nil
    }

    private static func canonicalJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 逐键取最大合并两个计数字典。用于同一逻辑记录被流式 / fork 重刷成多行、每行携带
    /// 相同内容时避免重复累加（同键的重复观测取一次的最大值）。
    private static func maxCounts(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
        var out = a
        for (key, value) in b {
            out[key] = max(out[key] ?? 0, value)
        }
        return out
    }

    private static func codexCounts(_ usage: [String: Any]) -> UsageTokenCounts {
        let rawInput = integer(usage["input_tokens"]); let rawOutput = integer(usage["output_tokens"])
        let cached = min(rawInput, integer(usage["cached_input_tokens"]) + integer(usage["cache_read_input_tokens"]))
        let creation = min(max(0, rawInput - cached), integer(usage["cache_creation_input_tokens"]))
        let reasoning = min(rawOutput, integer(usage["reasoning_output_tokens"]))
        return UsageTokenCounts(input: rawInput - cached - creation, output: rawOutput - reasoning, cachedInput: cached, cacheCreationInput: creation, reasoningOutput: reasoning, reportedTotal: integer(usage["total_tokens"]))
    }

    private static func maximum(_ a: UsageTokenCounts, _ b: UsageTokenCounts) -> UsageTokenCounts {
        UsageTokenCounts(input: max(a.input, b.input), output: max(a.output, b.output), cachedInput: max(a.cachedInput, b.cachedInput), cacheCreationInput: max(a.cacheCreationInput, b.cacheCreationInput), reasoningOutput: max(a.reasoningOutput, b.reasoningOutput), reportedTotal: max(a.total, b.total))
    }

    private static func subtract(_ current: UsageTokenCounts, _ prior: UsageTokenCounts) -> UsageTokenCounts {
        UsageTokenCounts(
            input: max(0, current.input - prior.input),
            output: max(0, current.output - prior.output),
            cachedInput: max(0, current.cachedInput - prior.cachedInput),
            cacheCreationInput: max(0, current.cacheCreationInput - prior.cacheCreationInput),
            reasoningOutput: max(0, current.reasoningOutput - prior.reasoningOutput),
            reportedTotal: max(0, current.total - prior.total)
        )
    }

    private static func cumulativeRegressed(_ current: UsageTokenCounts, from prior: UsageTokenCounts) -> Bool {
        let currentSum = current.input + current.output + current.cachedInput + current.cacheCreationInput + current.reasoningOutput
        let priorSum = prior.input + prior.output + prior.cachedInput + prior.cacheCreationInput + prior.reasoningOutput
        return current.total < prior.total || currentSum < priorSum
    }

    private static func completeCodexTotalSnapshot(_ usage: [String: Any]) -> Bool {
        guard !usage.isEmpty else { return false }
        func tokenValue(_ key: String) -> Int64? {
            guard let number = usage[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let numeric = number.doubleValue
            guard numeric.isFinite, numeric >= 0, numeric <= Double(Int64.max),
                  numeric.rounded(.towardZero) == numeric else { return nil }
            let value = number.int64Value
            return value >= 0 ? value : nil
        }
        guard let input = tokenValue("input_tokens"),
              let output = tokenValue("output_tokens"),
              let total = tokenValue("total_tokens") else { return false }
        let (sum, overflow) = input.addingReportingOverflow(output)
        return !overflow && sum == total
    }

    private static func codexEventIdentityScope(_ metadata: CodexMetadata) -> String {
        if !metadata.rolloutKey.isEmpty { return "rollout:\(metadata.rolloutKey)" }
        if metadata.hasSessionIdentity { return "session:\(metadata.sessionHash)" }
        return "missing-rollout"
    }

    private static func codexEventID(identityScope: String, modelAtEmission: String, last: UsageTokenCounts, completeTotal: UsageTokenCounts?) -> String {
        let totalIdentity: String
        if let completeTotal {
            totalIdentity = "complete|\(usageIdentity(completeTotal))"
        } else {
            totalIdentity = "incomplete"
        }
        return hash("codex-token|\(identityScope)|\(modelAtEmission)|\(usageIdentity(last))|\(totalIdentity)")
    }

    private static func usageIdentity(_ counts: UsageTokenCounts) -> String {
        "\(counts.input)|\(counts.output)|\(counts.cachedInput)|\(counts.cacheCreationInput)|\(counts.reasoningOutput)|\(counts.reportedTotal)"
    }

    /// 完整 total 快照指纹：绑定血缘根 + 归一化累计 total 快照，
    /// 与 model / session / timestamp 无关。父子会话回放同一累计快照时指纹一致，
    /// 可用于血缘证明去重。
    private static func totalSnapshotFingerprint(root: String, last: UsageTokenCounts, total: UsageTokenCounts) -> String {
        hash("total|\(root)|last|\(usageIdentity(last))|snapshot|\(usageIdentity(total))")
    }

    /// 内容型去重键：仅由 model、归一化后的 last 分量与**原始** total 快照分量决定，
    /// 与 timestamp / path / session / rollout 无关。fork / subagent 回放出的逐字节
    /// 相同的 token_count 事件（只改时间戳或路径）会落到同一键上，供跨文件折叠。
    /// last 分量取归一化值（input 已扣 cached/creation、output 已扣 reasoning），
    /// total 分量取原始累计值（不扣减），cached 合并 cached_input + cache_read_input。
    /// 键为 SHA256 前 16 字节（32 hex），带 "codex:" 命名空间前缀。
    private static func codexContentDedupKey(model: String, last: UsageTokenCounts, rawTotal: [String: Any]) -> String {
        let totalInput = integer(rawTotal["input_tokens"])
        let totalOutput = integer(rawTotal["output_tokens"])
        let totalCached = integer(rawTotal["cached_input_tokens"]) + integer(rawTotal["cache_read_input_tokens"])
        let totalCacheCreation = integer(rawTotal["cache_creation_input_tokens"])
        let totalReasoning = integer(rawTotal["reasoning_output_tokens"])
        let totalTokens = integer(rawTotal["total_tokens"])
        let payload = "codex-token|\(model)"
            + "|\(last.input)|\(last.output)|\(last.cachedInput)|\(last.cacheCreationInput)|\(last.reasoningOutput)"
            + "|\(totalInput)|\(totalOutput)|\(totalCached)|\(totalCacheCreation)|\(totalReasoning)|\(totalTokens)|\(last.reportedTotal)"
        return "codex:" + shortHash(payload, hexLength: 32)
    }

    private static func containsToolResult(_ value: Any?) -> Bool {
        if let object = value as? [String: Any] {
            if string(object["type"]) == "tool_result" { return true }
            return object.values.contains(where: containsToolResult)
        }
        if let array = value as? [Any] {
            return array.contains(where: containsToolResult)
        }
        return false
    }

    private static func json(_ data: Data.SubSequence) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(data))) as? [String: Any] }
    private static func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func string(_ value: Any?) -> String? { value as? String }
    private static func nonemptyString(_ value: Any?) -> String? {
        guard let value = string(value)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    private static func isUnknownModel(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.caseInsensitiveCompare("unknown") == .orderedSame
    }
    private static func integer(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? Int64(value as? String ?? "") ?? 0 }
    private static func component(_ path: String) -> String { let value = URL(fileURLWithPath: path).lastPathComponent; return value.isEmpty ? "unknown" : value }
    private static func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    /// 原始 session id 的 SHA256 前 `hexLength` 个 hex 字符（默认 16，即前 8 字节）。
    /// content dedup key 传 32（前 16 字节），与参考实现的 `sha256[:16]` 逐字节一致。
    private static func shortHash(_ value: String, hexLength: Int = 16) -> String { String(hash(value).prefix(hexLength)) }
}
