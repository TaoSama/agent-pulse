import Foundation

public struct UsageTokenCounts: Codable, Sendable, Equatable {
    public var input: Int64
    public var output: Int64
    public var cachedInput: Int64
    public var cacheCreationInput: Int64
    public var reasoningOutput: Int64
    public var reportedTotal: Int64

    public init(input: Int64 = 0, output: Int64 = 0, cachedInput: Int64 = 0, cacheCreationInput: Int64 = 0, reasoningOutput: Int64 = 0, reportedTotal: Int64 = 0) {
        self.input = max(0, input)
        self.output = max(0, output)
        self.cachedInput = max(0, cachedInput)
        self.cacheCreationInput = max(0, cacheCreationInput)
        self.reasoningOutput = max(0, reasoningOutput)
        self.reportedTotal = max(0, reportedTotal)
    }

    public var total: Int64 {
        max(reportedTotal, input + output + cachedInput + cacheCreationInput + reasoningOutput)
    }

    /// 五分量原始之和（不与 reportedTotal 取 max）。用于内容去重的 largest-total-wins
    /// 比较，须与参考实现逐字节对齐，故用环绕加法且不掺入 reportedTotal。
    public var billableTotal: Int64 {
        input &+ output &+ cachedInput &+ cacheCreationInput &+ reasoningOutput
    }
}

/// 稳健的 RFC3339 / ISO8601 时间戳解析。
///
/// 同时支持带小数秒（"2026-01-01T00:00:00.123Z"）与不带小数秒
/// （"2026-01-01T00:00:00Z"）两种格式，以及数值型 epoch（秒 / 毫秒）。
/// 解析失败返回 nil —— 调用方必须据此诊断并跳过，绝不能回退到 distantPast，
/// 否则错误时间会污染 bucket / session 聚合。
public enum UsageTimestamp {
    // ISO8601DateFormatter 非 Sendable，且内部可变；用锁保护的复用实例，
    // 避免每次解析都新建 formatter，同时满足 Swift 6 并发安全。
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    /// 从任意 JSON 值解析时间戳；无法解析时返回 nil。
    public static func parse(_ value: Any?) -> Date? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            lock.lock(); defer { lock.unlock() }
            return fractional.date(from: trimmed) ?? basic.date(from: trimmed)
        }
        if let value = value as? NSNumber {
            let number = value.doubleValue
            guard number.isFinite, number > 0 else { return nil }
            // 大于该阈值视为毫秒 epoch，否则视为秒 epoch。
            return number > 1_000_000_000_000
                ? Date(timeIntervalSince1970: number / 1_000)
                : Date(timeIntervalSince1970: number)
        }
        return nil
    }
}

public struct UsageEvent: Codable, Sendable, Equatable, Identifiable {
    /// 原始 token 事件在账本 UPSERT（同 event_id 再次入库）时的合并策略。
    ///
    /// 由「解析路径」决定，而非来源名硬编码 —— 任何 Claude-compatible 来源都必须携带
    /// cumulativeMax，否则同 msg.id 的流式累计增长行会被覆盖丢更新。
    public enum MergeStrategy: String, Codable, Sendable {
        /// Codex rollout 路径：event_id 稳定且每次携带修正后的独立计数，重解析直接覆盖。
        case overwrite
        /// Claude-compatible 路径：同 msg.id 多行携带单调增长的累计 usage，逐列取最大，
        /// 且 model 为 unknown 时保留既有 model（避免流式早行把已知 model 冲掉）。
        case cumulativeMax
    }

    public let id: String
    public let source: String
    public let model: String
    public let project: String
    public let timestamp: Date
    public let counts: UsageTokenCounts
    public let sessionHash: String
    public let sourceFileHash: String
    /// rollout 血缘键：Codex 本会话 rollout 标识（原始 session id 的短哈希）。
    public let rolloutKey: String
    /// 父 rollout 血缘键：fork / resume / subagent 情况下父会话的 rollout 标识；无则空串。
    public let parentRolloutKey: String
    /// 是否为继承回放行：子会话回放父会话既往 event_msg 时为 true。
    public let inherited: Bool
    /// 是否具备完整 total 快照（total_token_usage 全量存在且自洽）。
    ///
    /// 只有具备完整快照的行，才允许生成与 model / session / timestamp 无关的
    /// lineageFingerprint 用于跨文件、跨改写时间戳的血缘去重。
    public let hasTotalSnapshot: Bool
    /// 血缘指纹：仅当 hasTotalSnapshot 为真时非空。
    ///
    /// 由「完整累计 total 快照」派生，与 model / session / 具体 timestamp 无关，
    /// 因此即便子会话改写了 timestamp / model，只要底层是同一累计快照即可被折叠。
    /// 为空表示无法据此证明重复。
    public let lineageFingerprint: String
    /// 内容型去重键：仅 codex token 事件非空，由 model + 归一化 last 分量 + 原始 total
    /// 快照分量派生，与 timestamp / path / session / rollout 无关。fork / subagent
    /// 回放出的逐字节相同事件共享此键，供跨文件折叠去重。为空表示不参与内容折叠。
    public let codexDedupKey: String
    /// 账本 UPSERT 合并策略，随事件持久化；由解析路径决定，取代按来源名硬编码分支。
    public let mergeStrategy: MergeStrategy

    /// 本事件观测到的技能调用计数（skill 名 -> 次数）。缺省为空。
    public let skillCounts: [String: Int]
    /// 本事件观测到的 MCP server 调用计数（server 名 -> 次数）。缺省为空。
    public let mcpCounts: [String: Int]

    public init(id: String, source: String, model: String, project: String, timestamp: Date, counts: UsageTokenCounts, sessionHash: String, sourceFileHash: String, rolloutKey: String = "", parentRolloutKey: String = "", inherited: Bool = false, hasTotalSnapshot: Bool = false, lineageFingerprint: String = "", codexDedupKey: String = "", mergeStrategy: MergeStrategy = .overwrite, skillCounts: [String: Int] = [:], mcpCounts: [String: Int] = [:]) {
        self.id = id
        self.source = source
        self.model = model.isEmpty ? "unknown" : model
        self.project = project.isEmpty ? "unknown" : project
        self.timestamp = timestamp
        self.counts = counts
        self.sessionHash = sessionHash
        self.sourceFileHash = sourceFileHash
        self.rolloutKey = rolloutKey
        self.parentRolloutKey = parentRolloutKey
        self.inherited = inherited
        self.hasTotalSnapshot = hasTotalSnapshot
        self.lineageFingerprint = lineageFingerprint
        self.codexDedupKey = codexDedupKey
        self.mergeStrategy = mergeStrategy
        self.skillCounts = skillCounts
        self.mcpCounts = mcpCounts
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, model, project, timestamp, counts, sessionHash, sourceFileHash
        case rolloutKey, parentRolloutKey, inherited, hasTotalSnapshot, lineageFingerprint, codexDedupKey, mergeStrategy
        case skillCounts, mcpCounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(String.self, forKey: .source)
        model = try container.decode(String.self, forKey: .model)
        project = try container.decode(String.self, forKey: .project)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        counts = try container.decode(UsageTokenCounts.self, forKey: .counts)
        sessionHash = try container.decode(String.self, forKey: .sessionHash)
        sourceFileHash = try container.decode(String.self, forKey: .sourceFileHash)
        rolloutKey = try container.decodeIfPresent(String.self, forKey: .rolloutKey) ?? ""
        parentRolloutKey = try container.decodeIfPresent(String.self, forKey: .parentRolloutKey) ?? ""
        inherited = try container.decodeIfPresent(Bool.self, forKey: .inherited) ?? false
        hasTotalSnapshot = try container.decodeIfPresent(Bool.self, forKey: .hasTotalSnapshot) ?? false
        lineageFingerprint = try container.decodeIfPresent(String.self, forKey: .lineageFingerprint) ?? ""
        codexDedupKey = try container.decodeIfPresent(String.self, forKey: .codexDedupKey) ?? ""
        // 旧数据缺该字段时回退 overwrite（历史仅 Codex 覆盖 + Claude 靠源名分支，
        // 迁移由账本层按 source 归类补齐；解码默认取安全的 overwrite）。
        mergeStrategy = try container.decodeIfPresent(MergeStrategy.self, forKey: .mergeStrategy) ?? .overwrite
        // 后加内容字段：旧数据缺失时解码为空，保持向后兼容。
        skillCounts = try container.decodeIfPresent([String: Int].self, forKey: .skillCounts) ?? [:]
        mcpCounts = try container.decodeIfPresent([String: Int].self, forKey: .mcpCounts) ?? [:]
    }
}

/// 会话原始活动事件（token 无关）。
///
/// 用于重建 session 聚合（活跃秒数 / user 回合数 / UTC 小时直方图），
/// 只保留 hash 化的 session 标识、来源、事件角色与时间戳，绝不落正文 / cwd / path。
public struct UsageSessionEvent: Codable, Sendable, Equatable, Identifiable {
    /// 会话事件角色。
    public enum Role: String, Codable, Sendable {
        /// 真实用户输入（非 synthetic）。
        case user
        /// 合成 / 系统注入的 user 消息，不计入 user 回合数，但仍参与时间线。
        case syntheticUser = "synthetic_user"
        /// 助手输出。
        case assistant
    }

    public let id: String
    public let source: String
    public let sessionHash: String
    public let sourceFileHash: String
    public let role: Role
    public let timestamp: Date

    public init(id: String, source: String, sessionHash: String, sourceFileHash: String = "", role: Role, timestamp: Date) {
        self.id = id
        self.source = source
        self.sessionHash = sessionHash
        self.sourceFileHash = sourceFileHash
        self.role = role
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case id, source, sessionHash, sourceFileHash, role, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            source: try container.decode(String.self, forKey: .source),
            sessionHash: try container.decode(String.self, forKey: .sessionHash),
            sourceFileHash: try container.decodeIfPresent(String.self, forKey: .sourceFileHash) ?? "",
            role: try container.decode(Role.self, forKey: .role),
            timestamp: try container.decode(Date.self, forKey: .timestamp)
        )
    }
}

public struct UsageFileCheckpoint: Codable, Sendable, Equatable {
    public let fileID: String
    public let source: String
    public let pathHash: String
    public let offset: Int64
    public let size: Int64
    public let modifiedAt: Date
    public let parserVersion: Int
    public let status: String

    public init(fileID: String, source: String, pathHash: String, offset: Int64, size: Int64, modifiedAt: Date, parserVersion: Int, status: String) {
        self.fileID = fileID; self.source = source; self.pathHash = pathHash
        self.offset = max(0, offset); self.size = max(0, size); self.modifiedAt = modifiedAt
        self.parserVersion = parserVersion; self.status = status
    }
}

public struct UsageBucket: Codable, Sendable, Equatable {
    public let hostname: String
    public let source: String
    public let model: String
    public let project: String
    public let bucketStart: Date
    public let counts: UsageTokenCounts
    public let skills: [String]
    public let skillCounts: [String: Int]
    public let mcpCounts: [String: Int]
    public let linesAdded: Int64
    public let linesDeleted: Int64
    public let linesNet: Int64
    public let codeMetricVersion: Int

    public init(
        hostname: String,
        source: String,
        model: String,
        project: String,
        bucketStart: Date,
        counts: UsageTokenCounts,
        skills: [String] = [],
        skillCounts: [String: Int] = [:],
        mcpCounts: [String: Int] = [:],
        linesAdded: Int64 = 0,
        linesDeleted: Int64 = 0,
        codeMetricVersion: Int = 0
    ) {
        self.hostname = hostname
        self.source = source
        self.model = model
        self.project = project
        self.bucketStart = bucketStart
        self.counts = counts
        let normalizedSkillCounts = UsageToolMetrics.normalizeCounts(skillCounts)
        self.skillCounts = normalizedSkillCounts
        self.skills = UsageToolMetrics.mergeSkillCountKeys(skills: skills, counts: normalizedSkillCounts)
        self.mcpCounts = UsageToolMetrics.normalizeCounts(mcpCounts)
        self.linesAdded = max(0, linesAdded)
        self.linesDeleted = max(0, linesDeleted)
        let (net, overflowed) = self.linesAdded.subtractingReportingOverflow(self.linesDeleted)
        self.linesNet = overflowed ? (self.linesAdded >= self.linesDeleted ? Int64.max : Int64.min) : net
        self.codeMetricVersion = max(0, codeMetricVersion)
    }

    private enum CodingKeys: String, CodingKey {
        case hostname, source, model, project, bucketStart, counts
        case skills, skillCounts, mcpCounts, linesAdded, linesDeleted, linesNet, codeMetricVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hostname: try container.decode(String.self, forKey: .hostname),
            source: try container.decode(String.self, forKey: .source),
            model: try container.decode(String.self, forKey: .model),
            project: try container.decode(String.self, forKey: .project),
            bucketStart: try container.decode(Date.self, forKey: .bucketStart),
            counts: try container.decode(UsageTokenCounts.self, forKey: .counts),
            skills: try container.decodeIfPresent([String].self, forKey: .skills) ?? [],
            skillCounts: try container.decodeIfPresent([String: Int].self, forKey: .skillCounts) ?? [:],
            mcpCounts: try container.decodeIfPresent([String: Int].self, forKey: .mcpCounts) ?? [:],
            linesAdded: try container.decodeIfPresent(Int64.self, forKey: .linesAdded) ?? 0,
            linesDeleted: try container.decodeIfPresent(Int64.self, forKey: .linesDeleted) ?? 0,
            codeMetricVersion: try container.decodeIfPresent(Int.self, forKey: .codeMetricVersion) ?? 0
        )
    }
}

/// 会话级派生聚合，从 append-only 的 usage_session_events 事务重建。
///
/// - activeSeconds: 依据「user → 首个 assistant 开始计时 → 后续 assistant 延长 →
///   下一个 user 关闭」的规则累计的活跃秒数。
/// - messageCount: 去重后的全部会话事件计数（user + synthetic_user + assistant）。
/// - userMessageCount: 非 synthetic 的 user 消息计数。
/// - assistantEvents: assistant 事件计数。
/// - hourHistogramUTC: 长度 24 的 UTC 小时直方图，按「非 synthetic user prompt」落桶。
public struct UsageSession: Codable, Sendable, Equatable {
    public let hostname: String
    public let source: String
    public let sessionHash: String
    /// 内容字段：会话归属的 project（内容字段，不参与自然键）。
    /// 自然键仍为 hostname/source/sessionHash；project 仅描述内容，缺失时为空串。
    public let project: String
    /// 会话内观测到的技能名（排序、去重）；不参与自然键。
    public let skills: [String]
    public let firstActivity: Date
    public let lastActivity: Date
    public let activeSeconds: Int64
    public let messageCount: Int64
    public let userMessageCount: Int64
    public let assistantEvents: Int64
    public let hourHistogramUTC: [Int64]

    public init(hostname: String, source: String, sessionHash: String, project: String = "", skills: [String] = [], firstActivity: Date, lastActivity: Date, activeSeconds: Int64, messageCount: Int64, userMessageCount: Int64, assistantEvents: Int64, hourHistogramUTC: [Int64]) {
        self.hostname = hostname
        self.source = source
        self.sessionHash = sessionHash
        self.project = project
        self.skills = UsageToolMetrics.normalizeSkills(skills).sorted()
        self.firstActivity = firstActivity
        self.lastActivity = lastActivity
        self.activeSeconds = max(0, activeSeconds)
        self.messageCount = max(0, messageCount)
        self.userMessageCount = max(0, userMessageCount)
        self.assistantEvents = max(0, assistantEvents)
        // 规整为定长 24；越界索引丢弃，缺失补 0。
        var histogram = [Int64](repeating: 0, count: 24)
        for (index, value) in hourHistogramUTC.enumerated() where index < 24 {
            histogram[index] = max(0, value)
        }
        self.hourHistogramUTC = histogram
    }

    private enum CodingKeys: String, CodingKey {
        case hostname, source, sessionHash, project, skills, firstActivity, lastActivity
        case activeSeconds, messageCount, userMessageCount, assistantEvents, hourHistogramUTC
    }

    // project 为后加内容字段：旧数据缺失时解码为空串，保持向后兼容。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hostname = try container.decode(String.self, forKey: .hostname)
        let source = try container.decode(String.self, forKey: .source)
        let sessionHash = try container.decode(String.self, forKey: .sessionHash)
        let project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        let skills = try container.decodeIfPresent([String].self, forKey: .skills) ?? []
        let firstActivity = try container.decode(Date.self, forKey: .firstActivity)
        let lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        let activeSeconds = try container.decode(Int64.self, forKey: .activeSeconds)
        let messageCount = try container.decode(Int64.self, forKey: .messageCount)
        let userMessageCount = try container.decode(Int64.self, forKey: .userMessageCount)
        let assistantEvents = try container.decode(Int64.self, forKey: .assistantEvents)
        let hourHistogramUTC = try container.decode([Int64].self, forKey: .hourHistogramUTC)
        self.init(
            hostname: hostname, source: source, sessionHash: sessionHash, project: project, skills: skills,
            firstActivity: firstActivity, lastActivity: lastActivity,
            activeSeconds: activeSeconds, messageCount: messageCount,
            userMessageCount: userMessageCount, assistantEvents: assistantEvents,
            hourHistogramUTC: hourHistogramUTC
        )
    }
}

/// 输入 token 的展示口径。
///
/// 与权威看板保持一致：cache creation（本次写入缓存的输入）既不计入新增，也不参与
/// 命中率的分子或分母——它对主力数据源本就不进入用量聚合。
///
/// - cachedTokens: 仅包含 cache read（命中）。
/// - newTokens: 仅纯输入（cache miss 部分）；不含 cache read、cache creation、output、reasoning。
/// - cacheHitRate: cache read /（纯输入 + cache read）；没有输入时为 nil。
public struct UsageInputSummary: Codable, Sendable, Equatable {
    public let cachedTokens: Int64
    public let newTokens: Int64
    public let cacheHitRate: Double?

    public init(counts: UsageTokenCounts) {
        cachedTokens = counts.cachedInput
        newTokens = counts.input

        let denominator = Double(counts.input) + Double(counts.cachedInput)
        cacheHitRate = denominator > 0 ? Double(counts.cachedInput) / denominator : nil
    }
}

/// 本地汇总可选的时间窗口。区间为左闭右开。
///
/// - `day`：调用方日历时区下的自然日历日（保留 DST 语义）。
/// - `week`：以参考时刻为右界向前 7×24h 的滚动窗口（非自然周）。
/// - `month`：以参考时刻为右界向前 30×24h 的滚动窗口（非自然月）。
public enum UsageSummaryWindow: String, Codable, Sendable, CaseIterable {
    case day
    case week
    case month

    /// 滚动窗口天数：周 = 最近 7 天，月 = 最近 30 天。
    static let rollingWeekDays = 7
    static let rollingMonthDays = 30
    private static let secondsPerDay: TimeInterval = 24 * 60 * 60

    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        switch self {
        case .day:
            return calendar.dateInterval(of: .day, for: date)
        case .week:
            return DateInterval(start: date.addingTimeInterval(-Double(Self.rollingWeekDays) * Self.secondsPerDay), end: date)
        case .month:
            return DateInterval(start: date.addingTimeInterval(-Double(Self.rollingMonthDays) * Self.secondsPerDay), end: date)
        }
    }
}

public struct UsageSummary: Codable, Sendable, Equatable {
    public let updatedAt: Date?
    public let counts: UsageTokenCounts
    public let estimatedCostUSD: Double
    public var inputSummary: UsageInputSummary { UsageInputSummary(counts: counts) }
    public var cachedTokens: Int64 { inputSummary.cachedTokens }
    public var newTokens: Int64 { inputSummary.newTokens }
    public var cachePercentage: Double? { inputSummary.cacheHitRate }
}

/// 单一模型的每百万 token 单价。
///
/// 与权威看板一致，只保留四档：input / output / cache read / reasoning。
/// cache creation 没有独立计价档——它对主力数据源不进入计费。
public struct UsageModelPrice: Sendable, Equatable {
    public let pattern: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let reasoningPerMillion: Double

    public init(pattern: String, inputPerMillion: Double, outputPerMillion: Double, cacheReadPerMillion: Double, reasoningPerMillion: Double) {
        self.pattern = pattern
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.reasoningPerMillion = reasoningPerMillion
    }
}

public enum UsageCostEstimator {
    /// 未匹配到任何模型时的兜底单价（每百万 token）：取当代中端会话模型量级，无 reasoning 档。
    public static let fallback = UsageModelPrice(pattern: "", inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, reasoningPerMillion: 0)

    /// 按模型的每百万 token 单价表（USD），取当代公开牌价（含 OpenRouter 标准价）。
    ///
    /// pattern 以“子串命中且最长者优先”匹配（如 `claude-opus-4-8` 命中 `claude-opus-4-8`，
    /// `traex/gpt-5.6-sol` 命中 `gpt-5.6-sol`）。未命中走 `fallback`。cache read 单价按各厂商
    /// 实际牌价（并非统一比例）；cache creation 不参与计价。价格会随厂商调整而漂移，更新时
    /// 请以厂商官方 / OpenRouter 牌价为准，勿散落魔法值。
    public static let defaultPrices: [UsageModelPrice] = [
        // Anthropic Claude（cache creation 不计费）
        UsageModelPrice(pattern: "claude-fable-5", inputPerMillion: 10, outputPerMillion: 50, cacheReadPerMillion: 1.0, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-opus-5", inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-opus-4-8", inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-opus-4-7", inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-opus-4-6", inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-opus-4-5", inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        // 旧 Opus 4/4.1 仍为 15/75/1.5；置于 4-x 新价之后，靠最长匹配区分。
        UsageModelPrice(pattern: "claude-opus-4", inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-sonnet-5", inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0.2, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-sonnet-4", inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-haiku-4-5", inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: 0.1, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-3-5-sonnet", inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-3-5-haiku", inputPerMillion: 0.8, outputPerMillion: 4, cacheReadPerMillion: 0.08, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "claude-3-opus", inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, reasoningPerMillion: 0),
        // OpenAI GPT-5.6 分档（Sol / Terra / Luna）与 5.5
        UsageModelPrice(pattern: "gpt-5.6-sol", inputPerMillion: 5, outputPerMillion: 30, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5.6-terra", inputPerMillion: 1, outputPerMillion: 6, cacheReadPerMillion: 0.1, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5.6-luna", inputPerMillion: 0.1, outputPerMillion: 0.6, cacheReadPerMillion: 0.01, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5.5", inputPerMillion: 5, outputPerMillion: 30, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5.4", inputPerMillion: 2.5, outputPerMillion: 15, cacheReadPerMillion: 0.25, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5.2", inputPerMillion: 1.75, outputPerMillion: 14, cacheReadPerMillion: 0.175, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5.1", inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-5", inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125, reasoningPerMillion: 0),
        // OpenAI GPT-4 系列
        UsageModelPrice(pattern: "gpt-4o", inputPerMillion: 2.5, outputPerMillion: 10, cacheReadPerMillion: 1.25, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-4o-mini", inputPerMillion: 0.15, outputPerMillion: 0.6, cacheReadPerMillion: 0.075, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-4-turbo", inputPerMillion: 10, outputPerMillion: 30, cacheReadPerMillion: 0, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-4.1", inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-4.1-mini", inputPerMillion: 0.4, outputPerMillion: 1.6, cacheReadPerMillion: 0.1, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gpt-4.1-nano", inputPerMillion: 0.1, outputPerMillion: 0.4, cacheReadPerMillion: 0.025, reasoningPerMillion: 0),
        // OpenAI reasoning
        UsageModelPrice(pattern: "o1", inputPerMillion: 15, outputPerMillion: 60, cacheReadPerMillion: 7.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "o1-pro", inputPerMillion: 150, outputPerMillion: 600, cacheReadPerMillion: 0, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "o3", inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "o3-mini", inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.55, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "o4-mini", inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.275, reasoningPerMillion: 0),
        // DeepSeek V4 / V3
        UsageModelPrice(pattern: "deepseek-v4-flash", inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.028, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "deepseek-v4-pro", inputPerMillion: 1.168, outputPerMillion: 2.336, cacheReadPerMillion: 0.09855, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "deepseek-v3", inputPerMillion: 0.27, outputPerMillion: 1.12, cacheReadPerMillion: 0.135, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "deepseek-r1", inputPerMillion: 0.7, outputPerMillion: 2.5, cacheReadPerMillion: 0, reasoningPerMillion: 0),
        // Google Gemini
        UsageModelPrice(pattern: "gemini-2.5-pro", inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gemini-2.5-flash", inputPerMillion: 0.3, outputPerMillion: 2.5, cacheReadPerMillion: 0.03, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "gemini-2.5-flash-lite", inputPerMillion: 0.1, outputPerMillion: 0.4, cacheReadPerMillion: 0.01, reasoningPerMillion: 0),
        // xAI Grok
        UsageModelPrice(pattern: "grok-4", inputPerMillion: 2, outputPerMillion: 6, cacheReadPerMillion: 0.5, reasoningPerMillion: 0),
        UsageModelPrice(pattern: "grok-3", inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0, reasoningPerMillion: 0),
    ]

    /// 估算单个模型的费用（USD）。
    ///
    /// - prices 为空时使用与权威看板一致的 `defaultPrices`；显式传入则覆盖之。
    /// - 计价 = input×单价 + output×单价 + cacheRead×单价 + reasoning×单价；cache creation 不计费。
    public static func cost(model: String, counts: UsageTokenCounts, prices: [UsageModelPrice] = []) -> Double {
        let lowered = model.lowercased()
        let table = prices.isEmpty ? defaultPrices : prices
        let price = table.filter { !$0.pattern.isEmpty && lowered.contains($0.pattern.lowercased()) }.max { $0.pattern.count < $1.pattern.count } ?? fallback
        let inputCost = Double(counts.input) * price.inputPerMillion
        let outputCost = Double(counts.output) * price.outputPerMillion
        let cacheReadCost = Double(counts.cachedInput) * price.cacheReadPerMillion
        let reasoningCost = Double(counts.reasoningOutput) * price.reasoningPerMillion
        return (inputCost + outputCost + cacheReadCost + reasoningCost) / 1_000_000
    }
}
