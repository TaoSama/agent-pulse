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

    public let id: UUID
    public let timestamp: Date
    public let state: LiveRateState
    public let tps: Double?
    public let tokensInWindow: Double?
    public let latestSignalAt: Date?
    /// 按模型拆分的窗口内 token 数；仅 live/zero 状态有值，其余状态为空字典。
    public let modelTokensInWindow: [String: Double]
    public var sourceIdentifier: String? { "live-rate" }

    public init(
        timestamp: Date,
        state: LiveRateState,
        tokensInWindow: Double?,
        latestSignalAt: Date?,
        modelTokensInWindow: [String: Double] = [:]
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
        case .zero:
            self.tokensInWindow = 0
            self.tps = 0
            self.modelTokensInWindow = [:]
        case .noData, .stale, .unavailable:
            self.tokensInWindow = nil
            self.tps = nil
            self.modelTokensInWindow = [:]
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, state, tps, tokensInWindow, latestSignalAt, modelTokensInWindow
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

    public func sampleCount(referenceDate: Date? = nil) -> Int {
        let reference = referenceDate ?? now()
        return queue.sync {
            pruneLocked(referenceDate: reference)
            return samples.count
        }
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

    static func includedTokens(for sample: TPSSample, referenceDate: Date) -> Double {
        guard sample.tokenCount > 0 else { return 0 }
        let windowStart = referenceDate.addingTimeInterval(-Self.windowSeconds)
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
