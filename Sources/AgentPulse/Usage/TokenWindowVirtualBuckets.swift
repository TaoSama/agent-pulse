import AgentPulseCore
import Foundation

/// 展示层「虚拟 bucket」对齐（数值内核见 `AgentPulseCore.TokenWindowVirtualBucketTargets`）。
///
/// 口径：
/// - 日窗口：纯真实——总数 / 缓存 / 分模型均来自真实账本，不叠加基线。
/// - 周 / 月 / 全部：虚拟基线 + 真实增量。总数、按模型明细、缓存都在基线之上叠加真实用量；
///   模型名用账本原始名（与 TPS 曲线一致），差额并入 `unknown`。
///
/// 边界（务必保持）：只作用于展示层 `TokenUsageSummary`，绝不改写 SQLite 账本、绝不进入上报 payload、
/// 不落盘、不写日志。
enum TokenWindowVirtualBuckets {
    /// 覆盖周 / 月 / 全部三窗口为「基线 + 真实」；日窗口只补真实分模型明细。
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

    /// 日窗口：保持真实总数 / 缓存，仅补上真实的按模型明细。
    private static func withRealModels(
        _ original: TokenUsageWindowSummary?,
        models: [UsageModelTokenSummary]
    ) -> TokenUsageWindowSummary? {
        guard var summary = original else { return nil }
        summary.perModel = models.map { TokenModelUsage(model: $0.model, totalTokens: $0.counts.total) }
        return summary
    }

    /// 周 / 月 / 全部：展示 = 虚拟基线 + 真实增量。
    /// - 总数 = 基线总数 + 真实总量
    /// - 分模型 = 基线各模型 ⊕ 真实各模型（同名累加，差额并入 unknown）
    /// - 缓存 = 基线 cached（按合并命中率推算）+ 真实 cached；new = 总数 − cached；命中率 = cached / 总数
    private static func baselinePlusReal(
        _ original: TokenUsageWindowSummary?,
        window: TokenWindowVirtualBucketTargets.Window,
        real: [UsageModelTokenSummary]
    ) -> TokenUsageWindowSummary {
        let baselineTotal = TokenWindowVirtualBucketTargets.baselineTokens(for: window)
        let realTotal = real.reduce(Int64(0)) { $0 + $1.counts.total }
        let total = baselineTotal + realTotal

        let realModelTokens = real.map {
            TokenWindowVirtualBucketTargets.ModelTokens(model: $0.model, tokens: $0.counts.total)
        }
        let perModel = TokenWindowVirtualBucketTargets.merged(window: window, real: realModelTokens)
            .map { TokenModelUsage(model: $0.model, totalTokens: $0.tokens) }

        // 缓存：真实部分用真实 cached；基线部分按原窗口真实命中率（无则兜底）推算。
        let realCached = real.reduce(Int64(0)) { $0 + $1.counts.cachedInput }
        let baselineHitRate = original?.cacheHitRate ?? fallbackCacheHitRate
        let baselineCached = Int64((Double(baselineTotal) * baselineHitRate).rounded())
        let cached = max(0, min(total, baselineCached + realCached))
        let hitRate = total > 0 ? Double(cached) / Double(total) : nil

        return TokenUsageWindowSummary(
            totalTokens: total,
            estimatedCost: original?.estimatedCost ?? 0,
            cachedTokens: cached,
            newTokens: total - cached,
            cacheHitRate: hitRate,
            perModel: perModel
        )
    }

    /// 原窗口无真实派生数据（cacheHitRate 为 nil）时的兜底命中率。
    /// AI 编码会话缓存命中普遍偏高，取 0.8 作为展示层的稳定占位。
    private static let fallbackCacheHitRate = 0.8
}
