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

    public init(id: String, source: String, model: String, project: String, timestamp: Date, counts: UsageTokenCounts, sessionHash: String, sourceFileHash: String, rolloutKey: String = "", parentRolloutKey: String = "", inherited: Bool = false, hasTotalSnapshot: Bool = false, lineageFingerprint: String = "") {
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
    public let role: Role
    public let timestamp: Date

    public init(id: String, source: String, sessionHash: String, role: Role, timestamp: Date) {
        self.id = id
        self.source = source
        self.sessionHash = sessionHash
        self.role = role
        self.timestamp = timestamp
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

    public init(hostname: String, source: String, model: String, project: String, bucketStart: Date, counts: UsageTokenCounts) {
        self.hostname = hostname
        self.source = source
        self.model = model
        self.project = project
        self.bucketStart = bucketStart
        self.counts = counts
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
    public let firstActivity: Date
    public let lastActivity: Date
    public let activeSeconds: Int64
    public let messageCount: Int64
    public let userMessageCount: Int64
    public let assistantEvents: Int64
    public let hourHistogramUTC: [Int64]

    public init(hostname: String, source: String, sessionHash: String, firstActivity: Date, lastActivity: Date, activeSeconds: Int64, messageCount: Int64, userMessageCount: Int64, assistantEvents: Int64, hourHistogramUTC: [Int64]) {
        self.hostname = hostname
        self.source = source
        self.sessionHash = sessionHash
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
}

public struct UsageSummary: Codable, Sendable, Equatable {
    public let updatedAt: Date?
    public let counts: UsageTokenCounts
    public let estimatedCostUSD: Double
    public var cachedTokens: Int64 { counts.cachedInput + counts.cacheCreationInput }
    public var newTokens: Int64 { max(0, counts.total - cachedTokens) }
    public var cachePercentage: Double? { counts.total > 0 ? Double(cachedTokens) / Double(counts.total) : nil }
}

public struct UsageModelPrice: Sendable, Equatable {
    public let pattern: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cacheReadPerMillion: Double
    public let cacheCreationPerMillion: Double
    public let reasoningPerMillion: Double
}

public enum UsageCostEstimator {
    public static let fallback = UsageModelPrice(pattern: "", inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheCreationPerMillion: 3.75, reasoningPerMillion: 15)

    public static func cost(model: String, counts: UsageTokenCounts, prices: [UsageModelPrice] = []) -> Double {
        let lowered = model.lowercased()
        let price = prices.filter { !$0.pattern.isEmpty && lowered.contains($0.pattern.lowercased()) }.max { $0.pattern.count < $1.pattern.count } ?? fallback
        return (Double(counts.input) * price.inputPerMillion + Double(counts.output) * price.outputPerMillion + Double(counts.cachedInput) * price.cacheReadPerMillion + Double(counts.cacheCreationInput) * price.cacheCreationPerMillion + Double(counts.reasoningOutput) * price.reasoningPerMillion) / 1_000_000
    }
}
