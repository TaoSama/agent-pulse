import AgentPulseCore
import Foundation

/// 展示层「虚拟 bucket」对齐（数值内核见 `AgentPulseCore.TokenWindowVirtualBucketTargets`）。
///
/// 口径「目标 = 起点，之后只加新增」：
/// - 日窗口：纯真实——总数 / 缓存 / 分模型均来自真实账本，不叠加基线。
/// - 周 / 月 / 全部：显示总数 = 标量基线(目标 − 锚定真实) + 实时真实总量 = 目标 + 锚定后的新增；
///   分模型 = 目标各模型基线 + 实时真实（余量并入 unknown，模型名用账本原始名）；缓存按命中率随总数重算。
///
/// 边界（务必保持）：只作用于展示层 `TokenUsageSummary`，绝不改写 SQLite 账本、绝不进入上报 payload、
/// 不落盘、不写日志。
enum TokenWindowVirtualBuckets {
    /// 覆盖周 / 月 / 全部三窗口为「目标起点 + 新增」；日窗口只补真实分模型明细。
    /// `realModels` 为各窗口真实的按模型 token（原始名）。
    static func apply(
        to summary: TokenUsageSummary,
        realModels: [TokenUsageWindow: [UsageModelTokenSummary]]
    ) -> TokenUsageSummary {
        var result = summary
        result.day = withRealModels(summary.day, models: realModels[.day] ?? [])
        result.week = baselinePlusReal(summary.week, window: .week, real: realModels[.week] ?? [])
        result.month = baselinePlusReal(summary.month, window: .month, real: realModels[.month] ?? [])
        result.all = baselinePlusReal(summary.all, window: .all, real: realModels[.all] ?? [])
        return result
    }

    /// 日窗口：真实总数不变，补上真实的按模型明细，并统一缓存条口径——
    /// 缓存 = 真实 cache read，新增 = 总数 − 缓存（含 output / cache creation），使缓存 + 新增 == 总数，
    /// 与周 / 月 / 全部展示一致；命中率 = 缓存 / 总数。不改账本原始分量语义。
    private static func withRealModels(
        _ original: TokenUsageWindowSummary?,
        models: [UsageModelTokenSummary]
    ) -> TokenUsageWindowSummary? {
        guard var summary = original else { return nil }
        summary.perModel = models.map { TokenModelUsage(model: $0.model, totalTokens: $0.counts.total) }
        let total = summary.totalTokens
        let cached = max(0, min(total, summary.cachedTokens))
        summary.cachedTokens = cached
        summary.newTokens = total - cached
        summary.cacheHitRate = total > 0 ? Double(cached) / Double(total) : nil
        return summary
    }

    /// 周 / 月 / 全部：显示 = 目标起点 + 锚定后新增。
    /// - 总数 = 标量基线(目标 − 锚定真实) + 实时真实总量
    /// - 分模型 = 目标各模型基线 + 实时真实（余量并入 unknown）
    /// - 缓存 = round(总数 × 命中率)；命中率复用原窗口真实值，空则兜底；new = 总数 − cached
    private static func baselinePlusReal(
        _ original: TokenUsageWindowSummary?,
        window: TokenWindowVirtualBucketTargets.Window,
        real: [UsageModelTokenSummary]
    ) -> TokenUsageWindowSummary {
        let realModelTokens = real.map {
            TokenWindowVirtualBucketTargets.ModelTokens(model: $0.model, tokens: $0.counts.total)
        }
        let total = TokenWindowVirtualBucketTargets.displayTotal(for: window, real: realModelTokens)

        let perModel = TokenWindowVirtualBucketTargets.displayModels(window: window, real: realModelTokens)
            .map { TokenModelUsage(model: $0.model, totalTokens: $0.tokens) }

        let hitRate = original?.cacheHitRate ?? fallbackCacheHitRate
        let cached = max(0, min(total, Int64((Double(total) * hitRate).rounded())))

        return TokenUsageWindowSummary(
            totalTokens: total,
            estimatedCost: original?.estimatedCost ?? 0,
            cachedTokens: cached,
            newTokens: total - cached,
            cacheHitRate: total > 0 ? Double(cached) / Double(total) : nil,
            perModel: perModel
        )
    }

    /// 原窗口无真实派生数据（cacheHitRate 为 nil）时的兜底命中率。
    /// AI 编码会话缓存命中普遍偏高，取 0.8 作为展示层的稳定占位。
    private static let fallbackCacheHitRate = 0.8
}
