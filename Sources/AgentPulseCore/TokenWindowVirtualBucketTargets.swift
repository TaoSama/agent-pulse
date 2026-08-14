import Foundation

/// 展示层「虚拟 bucket」的纯数值内核。
///
/// 本机曾删除部分历史会话，派生账本真实统计低于用户记录。为让周 / 月 / 全部三个滚动窗口的展示回到
/// 用户真实记录的量级，这里为每个窗口提供一份「按模型的虚拟基线」（模型名与真实账本一致，不做展示映射），
/// 展示时以「基线 + 真实增量」叠加：后续真实用量正常累加到基线之上。差额（截图被截断，列出模型之和 <
/// 目标总数）并入 `unknown`，不新增映射名、不按比例缩放。
///
/// 纯数值、无副作用：不触碰 SQLite、上报、磁盘或日志。日窗口不使用基线（纯真实）。
public enum TokenWindowVirtualBucketTargets {
    /// 单条按模型 token（模型名为账本原始名）。
    public struct ModelTokens: Sendable, Equatable {
        public let model: String
        public let tokens: Int64
        public init(model: String, tokens: Int64) {
            self.model = model
            self.tokens = tokens
        }
    }

    /// 使用虚拟基线的滚动窗口（日窗口纯真实，不在此列）。
    public enum Window: Sendable, CaseIterable {
        case week
        case month
        case all
    }

    /// 每个窗口的目标基线总 token（B=1e9，M=1e6）。展示总数 = 该基线 + 窗口真实总量。
    public static let weekBaselineTokens: Int64 = 11_310_000_000
    public static let monthBaselineTokens: Int64 = 36_670_000_000
    public static let allBaselineTokens: Int64 = 71_820_000_000

    /// 差额并入的兜底模型名（与账本一致）。三个窗口的基线表均包含该条目。
    public static let residualModel = "unknown"

    public static func baselineTokens(for window: Window) -> Int64 {
        switch window {
        case .week: return weekBaselineTokens
        case .month: return monthBaselineTokens
        case .all: return allBaselineTokens
        }
    }

    /// 该窗口对齐后的按模型虚拟基线：差额并入 `unknown`，各条目之和 == 基线总数。
    public static func baselineModels(for window: Window) -> [ModelTokens] {
        reconcile(rawBaseline(for: window), target: baselineTokens(for: window))
    }

    /// 把窗口真实的按模型用量叠加到虚拟基线之上：同名累加，真实中的新模型追加。
    /// 结果各条目之和 == 基线总数 + 真实总量。返回按 token 降序。
    public static func merged(window: Window, real: [ModelTokens]) -> [ModelTokens] {
        var combined: [String: Int64] = [:]
        var order: [String] = []
        for entry in baselineModels(for: window) + real {
            if combined[entry.model] == nil { order.append(entry.model) }
            combined[entry.model, default: 0] += entry.tokens
        }
        return order
            .map { ModelTokens(model: $0, tokens: combined[$0] ?? 0) }
            .sorted {
                if $0.tokens == $1.tokens { return $0.model < $1.model }
                return $0.tokens > $1.tokens
            }
    }

    /// 各窗口列出模型的基线值（账本原始模型名；顺序即占比从高到低）。
    private static func rawBaseline(for window: Window) -> [ModelTokens] {
        switch window {
        case .week:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 5_300_000_000),
                ModelTokens(model: "gpt-5.6-sol", tokens: 3_900_000_000),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 519_300_000),
                ModelTokens(model: "traex/gpt-5.5", tokens: 90_400_000),
                ModelTokens(model: residualModel, tokens: 81_000_000),
                ModelTokens(model: "gpt-5.6-terra", tokens: 74_400_000),
                ModelTokens(model: "seed-code", tokens: 21_200_000),
            ]
        case .month:
            return [
                ModelTokens(model: "gpt-5.6-sol", tokens: 21_900_000_000),
                ModelTokens(model: "claude-opus-4-8", tokens: 9_400_000_000),
                ModelTokens(model: residualModel, tokens: 2_100_000_000),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTokens(model: "claude-opus-4-7", tokens: 725_200_000),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 542_200_000),
                ModelTokens(model: "gpt-5.5", tokens: 294_100_000),
                ModelTokens(model: "claude-opus-5", tokens: 135_000_000),
            ]
        case .all:
            return [
                ModelTokens(model: "gpt-5.6-sol", tokens: 29_100_000_000),
                ModelTokens(model: "gpt-5.5", tokens: 12_900_000_000),
                ModelTokens(model: "claude-opus-4-8", tokens: 11_500_000_000),
                ModelTokens(model: "claude-opus-4-7", tokens: 7_300_000_000),
                ModelTokens(model: residualModel, tokens: 4_100_000_000),
                ModelTokens(model: "doubao-seed-2-0", tokens: 2_800_000_000),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTokens(model: "traex/gpt-5.5", tokens: 959_200_000),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 542_200_000),
            ]
        }
    }

    /// 把 `目标基线 − 列出条目之和` 的差额并入 `unknown`，使各条目之和精确等于基线总数。
    private static func reconcile(_ models: [ModelTokens], target: Int64) -> [ModelTokens] {
        let listedSum = models.reduce(Int64(0)) { $0 + $1.tokens }
        let residual = target - listedSum
        guard residual != 0 else { return models }
        var adjusted = models
        if let index = adjusted.firstIndex(where: { $0.model == residualModel }) {
            adjusted[index] = ModelTokens(model: residualModel, tokens: adjusted[index].tokens + residual)
        } else {
            adjusted.append(ModelTokens(model: residualModel, tokens: residual))
        }
        return adjusted
    }
}
