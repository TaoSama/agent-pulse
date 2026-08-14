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
    /// 原窗口无真实派生数据（cacheHitRate 为 nil）时的兜底命中率。
    /// AI 编码会话缓存命中普遍偏高，取 0.8 作为展示层的稳定占位。
    private static let fallbackCacheHitRate = 0.8

    /// 覆盖周 / 月 / 全部三窗口为目标值；日窗口原样返回。
    static func apply(to summary: TokenUsageSummary) -> TokenUsageSummary {
        var result = summary
        result.week = overridden(summary.week, window: .week)
        result.month = overridden(summary.month, window: .month)
        result.all = overridden(summary.all, window: .all)
        return result
    }

    /// 用目标总数与分模型明细覆盖单窗口。缓存 / 新增按虚拟总数与命中率重算：
    /// `cached = round(total × hitRate)`、`new = total − cached`；命中率复用原窗口真实值，
    /// 原窗口为空（无派生数据）时用兜底命中率。费用保留原真实值（为空则 0）。
    private static func overridden(
        _ original: TokenUsageWindowSummary?,
        window: TokenWindowVirtualBucketTargets.Window
    ) -> TokenUsageWindowSummary {
        let perModel = TokenWindowVirtualBucketTargets.reconciledModels(for: window)
            .map { TokenModelUsage(model: $0.model, totalTokens: $0.tokens) }
        let total = TokenWindowVirtualBucketTargets.targetTokens(for: window)
        let hitRate = original?.cacheHitRate ?? fallbackCacheHitRate
        let cached = Int64((Double(total) * hitRate).rounded())
        let boundedCached = max(0, min(total, cached))
        return TokenUsageWindowSummary(
            totalTokens: total,
            estimatedCost: original?.estimatedCost ?? 0,
            cachedTokens: boundedCached,
            newTokens: total - boundedCached,
            cacheHitRate: hitRate,
            perModel: perModel
        )
    }
}
