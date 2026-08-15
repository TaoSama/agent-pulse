import Foundation

/// Codex 实时输出速率的固定窗口状态。
public enum LiveRateState: String, Codable, Sendable, Equatable, CaseIterable {
    case live
    case zero
    case noData = "no_data"
    case stale
    case unavailable
}

/// 一条可持久化的 1 秒 TPS 样本。
///
/// `live/zero` 必须携带数值；`no_data/stale/unavailable` 必须为缺失值，
/// 从而让曲线明确断开，而不是把未知错误画成 0。
public struct LiveRateSample: Codable, Sendable, Equatable, Identifiable, SnapshotPersistable {
    public static let basis = "output"
    public static let windowSeconds = 180
    /// 看板曲线用的短滑窗长度（秒）：每点显示为该时刻前 shortWindowSeconds 内的真实速率。
    public static let shortWindowSeconds = 5

    public let id: UUID
    public let timestamp: Date
    public let state: LiveRateState
    public let tps: Double?
    public let tokensInWindow: Double?
    public let latestSignalAt: Date?
    /// 按模型拆分的窗口内 token 数；仅 live/zero 状态有值，其余状态为空字典。
    public let modelTokensInWindow: [String: Double]
    /// 该时刻前 shortWindowSeconds（5s）滑窗内的 output token（看板 5s 滑窗曲线用）；
    /// 仅 live 状态有值，旧库/其它状态为 nil。
    public let tokensInShortWindow: Double?
    /// 5s 短滑窗按模型拆分的 token；仅 live 有值，旧库为空字典。
    public let modelTokensInShortWindow: [String: Double]
    /// 该 1 秒内真实新产出的 output token（逐秒净增量，相邻秒不重叠）；看板不重叠桶曲线的底层量。
    /// 与 tokensInShortWindow（5s 重叠口径）语义不同：后者相邻秒重叠、不能按秒求和。
    /// 仅 live 状态有值，旧库/其它状态为 nil。
    public let tokensInLastSecond: Double?
    /// 逐秒净增量按模型拆分；仅 live 有值，旧库为空字典。
    public let modelTokensInLastSecond: [String: Double]
    public var sourceIdentifier: String? { "live-rate" }

    public init(
        timestamp: Date,
        state: LiveRateState,
        tokensInWindow: Double?,
        latestSignalAt: Date?,
        modelTokensInWindow: [String: Double] = [:],
        tokensInShortWindow: Double? = nil,
        modelTokensInShortWindow: [String: Double] = [:],
        tokensInLastSecond: Double? = nil,
        modelTokensInLastSecond: [String: Double] = [:]
    ) {
        let second = Date(timeIntervalSince1970: floor(timestamp.timeIntervalSince1970))
        self.id = Self.stableID(for: second)
        self.timestamp = second
        self.state = state
        self.latestSignalAt = latestSignalAt
        switch state {
        case .live:
            let normalizedTokens = max(0, tokensInWindow ?? 0)
            self.tokensInWindow = normalizedTokens
            self.tps = normalizedTokens / Double(Self.windowSeconds)
            self.modelTokensInWindow = Self.normalizedModelTokens(modelTokensInWindow, total: normalizedTokens)
            let normalizedShort = tokensInShortWindow.map { max(0, $0) }
            self.tokensInShortWindow = normalizedShort
            self.modelTokensInShortWindow = normalizedShort.map {
                Self.normalizedModelTokens(modelTokensInShortWindow, total: $0)
            } ?? [:]
            let normalizedLast = tokensInLastSecond.map { max(0, $0) }
            self.tokensInLastSecond = normalizedLast
            self.modelTokensInLastSecond = normalizedLast.map {
                Self.normalizedModelTokens(modelTokensInLastSecond, total: $0)
            } ?? [:]
        case .zero:
            self.tokensInWindow = 0
            self.tps = 0
            self.modelTokensInWindow = [:]
            self.tokensInShortWindow = 0
            self.modelTokensInShortWindow = [:]
            self.tokensInLastSecond = 0
            self.modelTokensInLastSecond = [:]
        case .noData, .stale, .unavailable:
            self.tokensInWindow = nil
            self.tps = nil
            self.modelTokensInWindow = [:]
            self.tokensInShortWindow = nil
            self.modelTokensInShortWindow = [:]
            self.tokensInLastSecond = nil
            self.modelTokensInLastSecond = [:]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, state, tps, tokensInWindow, latestSignalAt, modelTokensInWindow
        case tokensInShortWindow, modelTokensInShortWindow
        case tokensInLastSecond, modelTokensInLastSecond
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.state = try container.decode(LiveRateState.self, forKey: .state)
        self.tps = try container.decodeIfPresent(Double.self, forKey: .tps)
        self.tokensInWindow = try container.decodeIfPresent(Double.self, forKey: .tokensInWindow)
        self.latestSignalAt = try container.decodeIfPresent(Date.self, forKey: .latestSignalAt)
        let decodedModels = try container.decodeIfPresent([String: Double].self, forKey: .modelTokensInWindow) ?? [:]
        self.modelTokensInWindow = Self.normalizedModelTokens(decodedModels, total: self.tokensInWindow ?? 0)
        // 旧库无这两列：decodeIfPresent 缺省，看板会退化用 tokensInWindow 保底（见 SparklineAnalysis）。
        let decodedShort = try container.decodeIfPresent(Double.self, forKey: .tokensInShortWindow)
        self.tokensInShortWindow = decodedShort
        let decodedShortModels = try container.decodeIfPresent([String: Double].self, forKey: .modelTokensInShortWindow) ?? [:]
        self.modelTokensInShortWindow = Self.normalizedModelTokens(decodedShortModels, total: decodedShort ?? 0)
        // 旧库无逐秒净增量列：decodeIfPresent 缺省 nil。看板不重叠桶对该秒标缺口（不回退），
        // 避免把 5s 重叠量误当逐秒净增量而算错量级。
        let decodedLast = try container.decodeIfPresent(Double.self, forKey: .tokensInLastSecond)
        self.tokensInLastSecond = decodedLast
        let decodedLastModels = try container.decodeIfPresent([String: Double].self, forKey: .modelTokensInLastSecond) ?? [:]
        self.modelTokensInLastSecond = Self.normalizedModelTokens(decodedLastModels, total: decodedLast ?? 0)
    }

    /// 归一化模型 token 字典：过滤非有限/负值，并将总和截断到 total 以内。
    static func normalizedModelTokens(_ raw: [String: Double], total: Double) -> [String: Double] {
        var result: [String: Double] = [:]
        var sum: Double = 0
        for (key, value) in raw {
            guard value.isFinite, value > 0 else { continue }
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else { continue }
            result[normalizedKey, default: 0] += value
            sum += value
        }
        guard sum > total, total >= 0, sum > 0 else { return result }
        let scale = total / sum
        for key in result.keys { result[key]! *= scale }
        return result
    }

    private static func stableID(for timestamp: Date) -> UUID {
        let seconds = UInt64(max(0, timestamp.timeIntervalSince1970.rounded(.down)))
        let suffix = String(format: "%012llx", seconds & 0xFFFF_FFFF_FFFF)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }
}

/// 线程安全的固定 180 秒 output-token 窗口。
///
/// `TPSSample.timestamp` 是区间终点，`durationSeconds` 决定区间起点。
/// 区间只按与 `[now-180s, now]` 的重叠比例计入；瞬时事件落在窗口内时整体计入。
/// 最终速率始终除以固定分母 180，而不是活动时长或采样间隔。
public final class TPSWindow: @unchecked Sendable {
    public static let windowSeconds: Double = 180
    static let futureTimestampToleranceSeconds: Double = 5
    public let windowSeconds: Double = TPSWindow.windowSeconds

    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "com.agentpulse.tpswindow")
    private var samples: [TPSSample] = []

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    @discardableResult
    public func record(_ sample: TPSSample) -> Bool {
        guard sample.isValid else { return false }
        return queue.sync {
            samples.append(sample)
            pruneLocked(referenceDate: max(now(), sample.timestamp))
            return true
        }
    }

    /// 批量记录，单次排序与淘汰，供每秒聚合路径避免逐条插入的二次复杂度。
    @discardableResult
    public func record(contentsOf newSamples: [TPSSample], referenceDate: Date? = nil) -> Int {
        let validSamples = newSamples.filter(\.isValid)
        guard !validSamples.isEmpty else { return 0 }
        let reference = referenceDate ?? now()
        return queue.sync {
            samples.append(contentsOf: validSamples)
            pruneLocked(referenceDate: reference)
            return validSamples.count
        }
    }

    @discardableResult
    public func record(
        tokenCount: Int,
        durationSeconds: Double,
        source: PulseSource,
        timestamp: Date? = nil
    ) -> Bool {
        record(TPSSample(
            timestamp: timestamp ?? now(),
            tokenCount: tokenCount,
            durationSeconds: durationSeconds,
            source: source
        ))
    }

    /// 返回窗口内按重叠比例计入的 output token 数。
    public func tokensInWindow(referenceDate: Date? = nil) -> Double {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            return samples.reduce(0) { partial, sample in
                partial + Self.includedTokens(for: sample, referenceDate: reference)
            }
        }
    }

    /// 返回窗口内按模型分组的 output token 数；model 为 nil 的归入 "unknown"。
    public func tokensInWindowByModel(referenceDate: Date? = nil) -> [String: Double] {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            var result: [String: Double] = [:]
            for sample in samples {
                let included = Self.includedTokens(for: sample, referenceDate: reference)
                guard included > 0 else { continue }
                let key = sample.model ?? "unknown"
                result[key, default: 0] += included
            }
            return result
        }
    }

    /// 只要窗口内存在已记录事件就返回固定窗口 TPS；无事件返回 nil。
    public func currentTPS(referenceDate: Date? = nil) -> Double? {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            let included = samples.map { Self.includedTokens(for: $0, referenceDate: reference) }
            guard included.contains(where: { $0 > 0 }) else { return nil }
            return included.reduce(0, +) / Self.windowSeconds
        }
    }

    /// 返回自定义短窗口内按重叠比例计入的 output token 数（供看板 5s 滑窗曲线取每秒的短窗值）。
    /// 语义与 180s 窗口一致（同一 includedTokens 重叠摊分），只是窗口长度可变。
    public func tokensInShortWindow(referenceDate: Date? = nil, windowSeconds: Double) -> Double {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            return samples.reduce(0) { partial, sample in
                partial + Self.includedTokens(for: sample, referenceDate: reference, windowSeconds: windowSeconds)
            }
        }
    }

    /// 返回自定义短窗口内按模型分组的 output token 数；model 为 nil 归入 "unknown"。
    public func tokensInShortWindowByModel(referenceDate: Date? = nil, windowSeconds: Double) -> [String: Double] {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            var result: [String: Double] = [:]
            for sample in samples {
                let included = Self.includedTokens(for: sample, referenceDate: reference, windowSeconds: windowSeconds)
                guard included > 0 else { continue }
                let key = sample.model ?? "unknown"
                result[key, default: 0] += included
            }
            return result
        }
    }

    public func sampleCount(referenceDate: Date? = nil) -> Int {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            return samples.count
        }
    }

    /// 严格的"该 1 秒净增量"：只把 token 摊到 (referenceDate-1, referenceDate] 这个精确 1 秒窗口。
    /// 与 tokensInShortWindow(windowSeconds:1) 不同——后者右边界带 5s 未来容差，长跨度事件会重复计入
    /// 相邻秒；这里右边界严格取 referenceDate，保证相邻秒不重叠、逐秒求和 = 事件总量。
    /// 供看板不重叠桶曲线做底层量。
    public func tokensInLastSecond(referenceDate: Date? = nil) -> Double {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            return samples.reduce(0) { $0 + Self.strictSecondTokens(for: $1, referenceDate: reference) }
        }
    }

    /// 逐秒净增量按模型拆分（严格 1 秒窗口，右边界不含未来容差）。
    public func tokensInLastSecondByModel(referenceDate: Date? = nil) -> [String: Double] {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            var result: [String: Double] = [:]
            for sample in samples {
                let included = Self.strictSecondTokens(for: sample, referenceDate: reference)
                guard included > 0 else { continue }
                result[sample.model ?? "unknown", default: 0] += included
            }
            return result
        }
    }

    /// 把一个 sample 摊到精确的 (referenceDate-1, referenceDate] 秒窗内（不含未来容差）。
    /// 瞬时事件（durationSeconds==0）只在其时间戳落入该秒时整额计入；持续事件按与该秒的重叠比例摊分。
    static func strictSecondTokens(for sample: TPSSample, referenceDate: Date) -> Double {
        guard sample.tokenCount > 0 else { return 0 }
        let windowStart = referenceDate.addingTimeInterval(-1)
        if sample.durationSeconds == 0 {
            return (sample.timestamp > windowStart && sample.timestamp <= referenceDate) ? Double(sample.tokenCount) : 0
        }
        let eventEnd = sample.timestamp
        let eventStart = eventEnd.addingTimeInterval(-sample.durationSeconds)
        let overlapStart = max(eventStart, windowStart)
        let overlapEnd = min(eventEnd, referenceDate)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        guard overlap > 0 else { return 0 }
        return Double(sample.tokenCount) * min(1, overlap / sample.durationSeconds)
    }

    public func reset() {
        queue.sync { samples.removeAll(keepingCapacity: true) }
    }

    private func pruneLocked(referenceDate: Date) {
        let cutoff = referenceDate.addingTimeInterval(-Self.windowSeconds)
        let maximumEnd = referenceDate.addingTimeInterval(Self.futureTimestampToleranceSeconds)
        samples.removeAll { sample in
            let start = sample.timestamp.addingTimeInterval(-sample.durationSeconds)
            return sample.timestamp < cutoff || start > maximumEnd
        }
    }

    static func includedTokens(
        for sample: TPSSample,
        referenceDate: Date,
        windowSeconds: Double = TPSWindow.windowSeconds
    ) -> Double {
        guard sample.tokenCount > 0 else { return 0 }
        let windowStart = referenceDate.addingTimeInterval(-windowSeconds)
        let maximumEnd = referenceDate.addingTimeInterval(Self.futureTimestampToleranceSeconds)
        if sample.durationSeconds == 0 {
            guard sample.timestamp >= windowStart, sample.timestamp <= maximumEnd else { return 0 }
            return Double(sample.tokenCount)
        }

        let eventEnd = sample.timestamp
        let eventStart = eventEnd.addingTimeInterval(-sample.durationSeconds)
        let overlapStart = max(eventStart, windowStart)
        let overlapEnd = min(eventEnd, maximumEnd)
        let overlap = overlapEnd.timeIntervalSince(overlapStart)
        guard overlap > 0 else { return 0 }
        return (Double(sample.tokenCount) * min(1, overlap / sample.durationSeconds)).rounded()
    }
}
