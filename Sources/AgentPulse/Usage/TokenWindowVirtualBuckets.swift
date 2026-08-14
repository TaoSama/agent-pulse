import AgentPulseCore
import Foundation

/// 展示层「虚拟 bucket」对齐（数值内核见 `AgentPulseCore.TokenWindowVirtualBucketTargets`）。
///
/// 把周 / 月 / 全部三个窗口的展示总数与分模型明细覆盖为固定目标，使
/// 「分模型各条目之和 == 该窗口总 TOKENS == 目标总数」，尽量还原用户真实记录的每模型数值与占比观感。
///
/// 边界（务必保持）：只作用于展示层 `TokenUsageSummary`，绝不改写 SQLite 账本、绝不进入上报 payload、
/// 不落盘、不写日志；日窗口保持真实，不做任何覆盖。
enum TokenWindowVirtualBuckets {
    /// 覆盖周 / 月 / 全部三窗口为目标值；日窗口原样返回。
    static func apply(to summary: TokenUsageSummary) -> TokenUsageSummary {
        var result = summary
        result.week = overridden(summary.week, window: .week)
        result.month = overridden(summary.month, window: .month)
        result.all = overridden(summary.all, window: .all)
        return result
    }

    /// 用目标总数与分模型明细覆盖单窗口。其余展示字段（费用 / 缓存 / 命中率）保留原真实值；
    /// 原窗口为 nil（无派生数据）时用零值起底，避免把虚拟总数伪装成真实的缓存 / 费用。
    private static func overridden(
        _ original: TokenUsageWindowSummary?,
        window: TokenWindowVirtualBucketTargets.Window
    ) -> TokenUsageWindowSummary {
        let perModel = TokenWindowVirtualBucketTargets.reconciledModels(for: window)
            .map { TokenModelUsage(model: $0.model, totalTokens: $0.tokens) }
        var summary = original ?? TokenUsageWindowSummary(
            totalTokens: 0,
            estimatedCost: 0,
            cachedTokens: 0,
            newTokens: 0,
            cacheHitRate: nil
        )
        summary.totalTokens = TokenWindowVirtualBucketTargets.targetTokens(for: window)
        summary.perModel = perModel
        return summary
    }
}
