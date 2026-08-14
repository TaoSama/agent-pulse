import Foundation

/// 展示层「虚拟 bucket」的纯数值内核。
///
/// 本机曾删除部分历史会话，派生账本真实统计低于用户记录。为让周 / 月 / 全部三个滚动窗口的展示总数与
/// 分模型明细还原用户真实观感，这里提供固定的「窗口 → 目标总数 + 分模型目标值」表，并保证
/// `Σ 分模型 == 窗口总数 == 目标总数`。差额（截图被截断，列出模型之和 < 目标总数）全部并入 `unknown`，
/// 不新增虚拟模型名、不按比例缩放已列出条目。
///
/// 纯数值、无副作用：不触碰 SQLite、上报、磁盘或日志。展示层据此覆盖对应窗口。
public enum TokenWindowVirtualBucketTargets {
    /// 单条分模型目标。
    public struct ModelTarget: Sendable, Equatable {
        public let model: String
        public let tokens: Int64
        public init(model: String, tokens: Int64) {
            self.model = model
            self.tokens = tokens
        }
    }

    /// 支持虚拟 bucket 覆盖的滚动窗口（日窗口保持真实，不在此列）。
    public enum Window: Sendable, CaseIterable {
        case week
        case month
        case all
    }

    /// 每个窗口的目标总 token（B=1e9，M=1e6），来自用户真实记录。
    public static let weekTargetTokens: Int64 = 11_280_000_000
    public static let monthTargetTokens: Int64 = 36_650_000_000
    public static let allTargetTokens: Int64 = 71_800_000_000

    /// 差额并入的兜底模型名。三个窗口的目标表均包含该条目。
    public static let residualModel = "unknown"

    public static func targetTokens(for window: Window) -> Int64 {
        switch window {
        case .week: return weekTargetTokens
        case .month: return monthTargetTokens
        case .all: return allTargetTokens
        }
    }

    /// 返回该窗口对齐后的分模型明细：差额并入 `unknown`，各条目之和精确等于目标总数。
    public static func reconciledModels(for window: Window) -> [ModelTarget] {
        reconcile(baseModels(for: window), target: targetTokens(for: window))
    }

    /// 各窗口列出模型的 base 目标值（顺序即展示顺序，按占比从高到低）。
    private static func baseModels(for window: Window) -> [ModelTarget] {
        switch window {
        case .week:
            return [
                ModelTarget(model: "claude opus 4 8", tokens: 5_300_000_000),
                ModelTarget(model: "gpt5.6-sol", tokens: 3_900_000_000),
                ModelTarget(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTarget(model: "traex/gpt5.6-sol", tokens: 519_300_000),
                ModelTarget(model: "traex/gpt5.5", tokens: 90_400_000),
                ModelTarget(model: residualModel, tokens: 81_000_000),
                ModelTarget(model: "gpt5.6-terra", tokens: 74_400_000),
                ModelTarget(model: "seed-code", tokens: 21_200_000),
            ]
        case .month:
            return [
                ModelTarget(model: "gpt5.6-sol", tokens: 21_900_000_000),
                ModelTarget(model: "claude opus 4 8", tokens: 9_400_000_000),
                ModelTarget(model: residualModel, tokens: 2_100_000_000),
                ModelTarget(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTarget(model: "claude opus 4 7", tokens: 725_200_000),
                ModelTarget(model: "traex/gpt5.6-sol", tokens: 542_200_000),
                ModelTarget(model: "gpt5.5", tokens: 294_100_000),
                ModelTarget(model: "claude opus 5", tokens: 135_000_000),
            ]
        case .all:
            return [
                ModelTarget(model: "gpt5.6-sol", tokens: 29_100_000_000),
                ModelTarget(model: "gpt5.5", tokens: 12_900_000_000),
                ModelTarget(model: "claude opus 4 8", tokens: 11_500_000_000),
                ModelTarget(model: "claude opus 4 7", tokens: 7_300_000_000),
                ModelTarget(model: residualModel, tokens: 4_100_000_000),
                ModelTarget(model: "doubao-seed-2-0", tokens: 2_800_000_000),
                ModelTarget(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTarget(model: "traex/gpt5.5", tokens: 959_200_000),
                ModelTarget(model: "traex/gpt5.6-sol", tokens: 542_200_000),
            ]
        }
    }

    /// 把 `目标总数 − 列出条目之和` 的差额并入 `unknown`，使各条目之和精确等于 target。
    private static func reconcile(_ models: [ModelTarget], target: Int64) -> [ModelTarget] {
        let listedSum = models.reduce(Int64(0)) { $0 + $1.tokens }
        let residual = target - listedSum
        guard residual != 0 else { return models }
        var adjusted = models
        if let index = adjusted.firstIndex(where: { $0.model == residualModel }) {
            adjusted[index] = ModelTarget(model: residualModel, tokens: adjusted[index].tokens + residual)
        } else {
            adjusted.append(ModelTarget(model: residualModel, tokens: residual))
        }
        return adjusted
    }
}
