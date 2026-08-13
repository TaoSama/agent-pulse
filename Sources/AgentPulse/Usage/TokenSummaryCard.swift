import SwiftUI

/// 菜单栏 Token 汇总卡：全部时间累计 + 缓存/新增 + 实时 TPS。
///
/// 黑底白字，与 TPS 卡风格一致；不使用灰色承载主信息。
/// 无历史数据时展示「Token 历史采集中」，不把 0 冒充真实值。
struct TokenSummaryCard: View {
    let summary: TokenUsageSummary
    let tps: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("总 TOKENS")
                        .font(.system(size: 10, weight: .medium))
                    Text(TokenUsageFormatting.tokens(summary.totalTokens))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("估算费用")
                        .font(.system(size: 10, weight: .medium))
                    Text(TokenUsageFormatting.cost(summary.estimatedCost))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }

            TokenCacheRatioBar(cached: summary.cachedTokens, new: summary.newTokens)

            HStack(spacing: 6) {
                TokenFooterMetric(title: "缓存", value: TokenUsageFormatting.tokens(summary.cachedTokens))
                TokenFooterMetric(title: "新增", value: TokenUsageFormatting.tokens(summary.newTokens))
                TokenFooterMetric(title: "命中率", value: TokenUsageFormatting.percent(summary.cacheHitRate))
                Spacer(minLength: 4)
                Text("TPS \(TokenUsageFormatting.tps(tps))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
            }

            if summary.totalTokens == nil {
                Text("Token 历史采集中")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
        }
        .padding(12)
        .foregroundStyle(Color.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let tokens = summary.totalTokens.map(String.init) ?? "采集中"
        let cost = summary.estimatedCost.map { String(format: "$%.2f", $0) } ?? "未知"
        let hitRate = TokenUsageFormatting.percent(summary.cacheHitRate)
        let tpsText = tps.map { String(format: "%.1f", $0) } ?? "不可用"
        return "总 Tokens \(tokens)，估算费用 \(cost)，缓存命中率 \(hitRate)，实时 TPS \(tpsText)"
    }
}

private struct TokenFooterMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.72))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 缓存/新增占比条：缓存为纯白，新增为半透明白；无数据时只显示轨道。
private struct TokenCacheRatioBar: View {
    let cached: Int64?
    let new: Int64?

    var body: some View {
        GeometryReader { geometry in
            let widths = widths(in: geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                if widths.cached > 0 {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: widths.cached)
                }
                if widths.new > 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: widths.new)
                        .offset(x: widths.cached)
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func widths(in total: CGFloat) -> (cached: CGFloat, new: CGFloat) {
        let cachedValue = Double(max(0, cached ?? 0))
        let newValue = Double(max(0, new ?? 0))
        let sum = cachedValue + newValue
        guard sum > 0, total > 0 else { return (0, 0) }
        let cachedWidth = total * CGFloat(cachedValue / sum)
        let newWidth = total * CGFloat(newValue / sum)
        return (cachedWidth, min(newWidth, max(0, total - cachedWidth)))
    }
}
