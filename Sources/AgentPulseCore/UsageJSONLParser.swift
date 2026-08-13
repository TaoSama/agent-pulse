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

    public init(events: [UsageEvent], sessionEvents: [UsageSessionEvent], checkpoint: UsageFileCheckpoint, diagnostics: [String]) {
        self.events = events
        self.sessionEvents = sessionEvents
        self.checkpoint = checkpoint
        self.diagnostics = diagnostics
    }
}

public enum UsageJSONLParser {
    /// 解析器版本。v2：稳健 RFC3339（无 distantPast 回退）、原始 session 活动事件、
    /// 基于原始 session id 的稳定 session hash、血缘证明去重（rollout/parent/inherited +
    /// 完整 total 快照指纹）、unknown model backfill。
    /// v3：新增 Claude subagent transcript 处理（token 计入、不产生 session 事件、
    /// 不做 thinking 拆分）与「原生 reasoning 缺失时按 thinking/其余输出字符比例
    /// 拆分 output→reasoning（round-half-up，仅 Anthropic 家族）」。
    public static let parserVersion = 3

    public static func fileID(for identity: String) -> String { hash(identity) }

    /// 解析一个来源文件。
    ///
    /// - isSubagent: 该文件是否为子代理（subagent / Task）transcript。子代理转录只计入
    ///   token 用量，不产生任何 session 活动事件（否则会按 fork 数量放大会话计数 /
    ///   活跃时间），且不做 thinking→reasoning 拆分（拆分只在 output 与 reasoning 之间
    ///   移动 token，二者同价，总量与成本不变；子代理属次要路径，省略该细分可接受）。
    ///   目前仅 Claude（claude-code）来源使用此标志。
    public static func parse(data: Data, source: String, fileIdentity: String, modifiedAt: Date = Date(), isSubagent: Bool = false) -> ParsedUsageFile {
        let fileHash = fileID(for: fileIdentity)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var diagnostics: [String] = []
        var sessionEvents: [UsageSessionEvent] = []
        let events = source == "claude-code"
            ? parseClaude(lines, source: source, fileHash: fileHash, isSubagent: isSubagent, sessionEvents: &sessionEvents, diagnostics: &diagnostics)
            : parseCodex(lines, source: source, fileHash: fileHash, sessionEvents: &sessionEvents, diagnostics: &diagnostics)
        return ParsedUsageFile(
            events: events,
            sessionEvents: sessionEvents,
            checkpoint: UsageFileCheckpoint(fileID: fileHash, source: source, pathHash: fileHash, offset: Int64(data.count), size: Int64(data.count), modifiedAt: modifiedAt, parserVersion: parserVersion, status: diagnostics.isEmpty ? "complete" : "degraded"),
            diagnostics: diagnostics
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

    private static func parseCodex(_ lines: [Data.SubSequence], source: String, fileHash: String, sessionEvents: inout [UsageSessionEvent], diagnostics: inout [String]) -> [UsageEvent] {
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
        var seenFirstTurnContext = false
        var previousCumulative: UsageTokenCounts?
        var result: [UsageEvent] = []
        var seenEventIDs = Set<String>()
        var seenSessionEventIDs = Set<String>()

        for (index, line) in lines.enumerated() {
            guard let object = json(line) else { diagnostics.append("line \(index + 1): invalid json"); continue }
            let type = string(object["type"])
            let payload = dictionary(object["payload"])

            if type == "turn_context" {
                if let authoritativeModel = nonemptyString(payload["model"]) {
                    turnModel = authoritativeModel
                }
                // The semantic boundary applies even when this record has no usable timestamp.
                seenFirstTurnContext = true
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
            let eventID = codexEventID(
                identityScope: codexEventIdentityScope(metadata), modelAtEmission: modelAtEmission,
                last: normalizedLast, completeTotal: hasTotalSnapshot ? normalizedTotal : nil
            )
            guard seenEventIDs.insert(eventID).inserted else { continue }

            result.append(UsageEvent(
                id: eventID, source: sourceName, model: modelAtEmission, project: metadata.project,
                timestamp: timestamp, counts: counts, sessionHash: activitySessionHash, sourceFileHash: fileHash,
                rolloutKey: metadata.rolloutKey, parentRolloutKey: metadata.parentRolloutKey, inherited: inherited,
                hasTotalSnapshot: hasTotalSnapshot, lineageFingerprint: lineageFingerprint
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
                    hasTotalSnapshot: event.hasTotalSnapshot, lineageFingerprint: event.lineageFingerprint
                )
            }
        }
        return result
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

    private struct ClaudeCandidate { var model: String; var project: String; var timestamp: Date; var counts: UsageTokenCounts; var index: Int; var sessionHash: String }

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

    private static func parseClaude(_ lines: [Data.SubSequence], source: String, fileHash: String, isSubagent: Bool, sessionEvents: inout [UsageSessionEvent], diagnostics: inout [String]) -> [UsageEvent] {
        var messages: [String: ClaudeCandidate] = [:]
        // 记录每个候选 entry 归属的稳定 turn id（msg.id 优先，回退 uuid），
        // 用于扫描结束后按整 turn 字符比例做 thinking 拆分。空串表示不需要拆分。
        var candidateStableID: [String: String] = [:]
        var turnChars: [String: ClaudeTurnSplit] = [:]
        var seenSessionEventIDs = Set<String>()
        for (index, line) in lines.enumerated() {
            guard let object = json(line) else { diagnostics.append("line \(index + 1): invalid json"); continue }
            let type = string(object["type"])
            let rawSessionID = string(object["sessionId"]) ?? string(object["session_id"])
            // 保留真实 sessionHash（每行自带 sessionId）；缺失时才以文件兜底。
            let sessionHash = rawSessionID.map(shortHash) ?? shortHash(fileHash)

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
                    identitySessionScope: rawSessionID == nil ? "missing-session" : sessionHash,
                    role: role, object: object,
                    seenIDs: &seenSessionEventIDs,
                    diagnostics: &diagnostics, index: index
                )
            }

            guard type == "assistant" else { continue }
            let message = dictionary(object["message"]); let usage = dictionary(message["usage"]); guard !usage.isEmpty else { continue }
            let id = string(message["id"]) ?? string(object["uuid"]) ?? "line-\(index)"
            // 累计该 turn 的 thinking / 其余输出字符（仅主转录需要，子代理不拆分）。
            if !isSubagent {
                accumulateClaudeTurnChars(message: message, turnID: id, into: &turnChars)
            }
            guard let timestamp = UsageTimestamp.parse(object["timestamp"]) else {
                diagnostics.append("line \(index + 1): invalid timestamp (usage skipped)")
                continue
            }
            let counts = UsageTokenCounts(input: integer(usage["input_tokens"]), output: integer(usage["output_tokens"]), cachedInput: integer(usage["cache_read_input_tokens"]), cacheCreationInput: integer(usage["cache_creation_input_tokens"]), reasoningOutput: integer(usage["reasoning_output_tokens"]), reportedTotal: integer(usage["total_tokens"]))
            let candidate = ClaudeCandidate(model: string(message["model"]) ?? "unknown", project: string(object["cwd"]).map(component) ?? "unknown", timestamp: timestamp, counts: counts, index: index, sessionHash: sessionHash)
            if let old = messages[id] {
                // 同 msg.id 保留最大累计 usage（Claude 流式增量）。真实 sessionHash 以先出现者为准。
                messages[id] = ClaudeCandidate(model: candidate.model == "unknown" ? old.model : candidate.model, project: candidate.project == "unknown" ? old.project : candidate.project, timestamp: max(old.timestamp, candidate.timestamp), counts: maximum(old.counts, candidate.counts), index: min(old.index, candidate.index), sessionHash: old.sessionHash.isEmpty ? candidate.sessionHash : old.sessionHash)
            } else { messages[id] = candidate }
            candidateStableID[id] = id
        }
        return messages.sorted { $0.value.index < $1.value.index }.map { id, value in
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
            return UsageEvent(
                id: hash("\(source)|message:\(id)"),
                source: source, model: value.model, project: value.project, timestamp: value.timestamp, counts: counts,
                sessionHash: value.sessionHash, sourceFileHash: fileHash,
                rolloutKey: value.sessionHash, parentRolloutKey: "", inherited: false,
                hasTotalSnapshot: true, lineageFingerprint: ""
            )
        }
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
        let denom = Int64(thinkingChars + otherChars)
        guard denom > 0 else { return 0 }
        // round-half-up 整数拆分，无浮点、无分词器。
        var est = (outputTokens * Int64(thinkingChars) + denom / 2) / denom
        if est > outputTokens { est = outputTokens }
        return est
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

    private static func appendSessionEvent(_ sink: inout [UsageSessionEvent], source: String, sessionHash: String, identitySessionScope: String, role: UsageSessionEvent.Role, object: [String: Any], seenIDs: inout Set<String>, diagnostics: inout [String], index: Int, occurrence: Int? = nil) {
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
        sink.append(UsageSessionEvent(id: id, source: source, sessionHash: sessionHash, role: role, timestamp: timestamp))
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
        return ["input_tokens", "output_tokens", "total_tokens"].allSatisfy { key in
            guard let number = usage[key] as? NSNumber else { return false }
            return CFGetTypeID(number) != CFBooleanGetTypeID()
        }
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
    /// 原始 session id 的 SHA256 前 16 hex。
    private static func shortHash(_ value: String) -> String { String(hash(value).prefix(16)) }
}
