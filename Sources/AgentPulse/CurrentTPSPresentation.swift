import AgentPulseCore
import Foundation

/// 所有入口的当前读数来自同一秒采样；历史曲线的桶值不参与当前读数。
struct CurrentTPSPresentation: Sendable, Equatable {
    static let unknownModel = "unknown"
    private static let roundingToleranceUlps = 16.0
    static let empty = CurrentTPSPresentation(sample: LiveRateSample(
        timestamp: Date(timeIntervalSince1970: 0), state: .noData,
        tokensInWindow: nil, latestSignalAt: nil
    ))

    let sampledAt: Date?
    let state: LiveRateState
    let totalTPS: Double?
    let modelTPS: [String: Double]

    init(sample: LiveRateSample) {
        sampledAt = sample.timestamp
        state = sample.state
        if sample.state == .zero {
            totalTPS = 0
            modelTPS = [:]
            return
        }
        guard sample.state == .live else {
            totalTPS = nil
            modelTPS = [:]
            return
        }
        let total = sample.tps ?? 0
        totalTPS = total
        var models = sample.modelTokensInWindow.mapValues { $0 / Double(LiveRateSample.windowSeconds) }
        // 旧缓存可能只有总量；保留其真实总量，把未归属部分明确列为 unknown。
        let missing = total - models.values.reduce(0, +)
        let tolerance = max(total.ulp * Self.roundingToleranceUlps, Double.ulpOfOne)
        if missing > tolerance || (models.isEmpty && missing > 0) {
            models[Self.unknownModel, default: 0] += missing
        }
        modelTPS = models
    }

    func tps(for model: String) -> Double? {
        totalTPS == nil ? nil : modelTPS[model] ?? 0
    }

    /// 历史中出现过的模型可以保留图例，但其数字始终取当前采样，缺失不回捞旧值。
    func models(including historicalModels: [String] = []) -> [CurrentTPSModelValue] {
        Set(historicalModels).union(modelTPS.keys)
            .map { CurrentTPSModelValue(model: $0, tps: tps(for: $0)) }
            .sorted {
                if $0.tps == $1.tps {
                    return $0.model.localizedStandardCompare($1.model) == .orderedAscending
                }
                return ($0.tps ?? 0) > ($1.tps ?? 0)
            }
    }
}

struct CurrentTPSModelValue: Sendable, Equatable, Identifiable {
    var id: String { model }
    let model: String
    let tps: Double?
}

/// 悬浮球、气泡、菜单小图共享投影；总曲线复用 Core 已补点、平滑和归一化的结果。
enum CompactTPSGeometry {
    /// 总曲线直接使用绘图值，避免重复计算；没有绘图点时用有效当前读数显示平线。
    static func normalizedValues(points: [SparklinePoint], fallbackTPS: Double? = nil) -> [Double?] {
        let values = points.map { point -> Double? in
            guard let value = point.normalized, value.isFinite else { return nil }
            return value
        }
        guard values.contains(where: { $0 != nil }) else {
            if let fallbackTPS, fallbackTPS.isFinite, fallbackTPS >= 0 { return [0.5, 0.5] }
            return []
        }
        return values
    }

    /// 分模型历史保留原始 TPS 投影及缺口，以参考历史的原始峰值为标尺。
    static func normalizedValues(points: [SparklinePoint], referencePoints: [SparklinePoint]) -> [Double?] {
        let upper = max(referencePoints.compactMap { validValue($0.value) }.max() ?? 1, 1)
        return points.map { point in validValue(point.value).map { min($0 / upper, 1) } }
    }

    private static func validValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
}
