import SwiftUI

/// 菜单栏 Token 汇总卡：日/月/年/全部四窗口 + 实时 TPS。
///
/// 黑底白字，与 TPS 卡风格一致；不使用灰色承载信息。
/// 当前窗口无数据时明确展示空状态，不把 0 冒充真实值。
struct TokenSummaryCard: View {
    let summary: TokenUsageSummary
    let tps: Double?
    @Binding var selectedWindow: TokenUsageWindow

    init(summary: TokenUsageSummary, tps: Double?, selectedWindow: Binding<TokenUsageWindow>) {
        self.summary = summary
        self.tps = tps
        _selectedWindow = selectedWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Token 统计窗口", selection: $selectedWindow) {
                ForEach(TokenUsageWindow.allCases) { window in
                    Text(window.title)
                        .tag(window)
                        .accessibilityLabel(window.accessibilityLabel)
                        .accessibilityAddTraits(selectedWindow == window ? .isSelected : [])
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(.white)
            .colorScheme(.dark)
            .accessibilityLabel("Token 统计窗口")
            .accessibilityValue(selectedWindow.accessibilityLabel)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("总 TOKENS")
                            .font(.system(size: 10, weight: .medium))
                        Text(TokenUsageFormatting.tokens(selectedSummary?.totalTokens))
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("估算费用")
                            .font(.system(size: 10, weight: .medium))
                        Text(TokenUsageFormatting.cost(selectedSummary?.estimatedCost))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                }

                TokenCacheRatioBar(
                    cached: selectedSummary?.cachedTokens,
                    new: selectedSummary?.newTokens
                )

                HStack(spacing: 6) {
                    TokenFooterMetric(
                        title: "缓存",
                        value: TokenUsageFormatting.tokens(selectedSummary?.cachedTokens)
                    )
                    TokenFooterMetric(
                        title: "新增",
                        value: TokenUsageFormatting.tokens(selectedSummary?.newTokens)
                    )
                    TokenFooterMetric(
                        title: "命中率",
                        value: TokenUsageFormatting.percent(selectedSummary?.cacheHitRate)
                    )
                    Spacer(minLength: 4)
                    Text("TPS \(TokenUsageFormatting.tps(tps))")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }

                if selectedSummary == nil {
                    Text("本窗口暂无数据")
                        .font(.system(size: 10))
                }

                if !topModels.isEmpty {
                    Divider().overlay(Color.white.opacity(0.15))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("按模型")
                            .font(.system(size: 10, weight: .medium))
                            .opacity(0.7)
                        ForEach(topModels, id: \.model) { entry in
                            TokenModelRow(
                                model: entry.model,
                                tokens: entry.totalTokens,
                                total: selectedSummary?.totalTokens ?? 0
                            )
                        }
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
        .padding(12)
        .foregroundStyle(Color.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectedSummary: TokenUsageWindowSummary? { summary[selectedWindow] }

    /// 当前窗口按 token 降序的前若干个模型（原始模型名，与 TPS 曲线一致，不做映射）。
    private var topModels: [TokenModelUsage] {
        let entries = selectedSummary?.perModel ?? []
        return Array(entries.sorted { $0.totalTokens > $1.totalTokens }.prefix(Self.topModelCount))
    }

    private static let topModelCount = 5

    private var accessibilityLabel: String {
        let tokens = selectedSummary.map { String($0.totalTokens) } ?? "无数据"
        let cost = selectedSummary.map { String(format: "$%.2f", $0.estimatedCost) } ?? "未知"
        let hitRate = TokenUsageFormatting.percent(selectedSummary?.cacheHitRate)
        let tpsText = tps.map { String(format: "%.1f", $0) } ?? "不可用"
        return "\(selectedWindow.accessibilityLabel)，总 Tokens \(tokens)，估算费用 \(cost)，缓存命中率 \(hitRate)，实时 TPS \(tpsText)"
    }
}

private struct TokenFooterMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
    }
}

/// 单个模型的 token 行：原始模型名 + 2 位小数 token + 占窗口总量百分比。
private struct TokenModelRow: View {
    let model: String
    let tokens: Int64
    let total: Int64

    var body: some View {
        HStack(spacing: 6) {
            Text(model)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(percentText)
                .font(.system(size: 10, design: .monospaced))
                .opacity(0.7)
            Text(TokenUsageFormatting.tokens(tokens))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model)，\(TokenUsageFormatting.tokens(tokens))，\(percentText)")
    }

    private var percentText: String {
        guard total > 0 else { return "—" }
        return TokenUsageFormatting.percent(Double(tokens) / Double(total))
    }
}

/// 缓存/新增占比条：缓存为白、新增为黑，白线框标记总宽度。
private struct TokenCacheRatioBar: View {
    let cached: Int64?
    let new: Int64?

    var body: some View {
        GeometryReader { geometry in
            let widths = widths(in: geometry.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black)
                if widths.cached > 0 {
                    Capsule()
                        .fill(Color.white)
                        .frame(width: widths.cached)
                }
                if widths.new > 0 {
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: widths.new)
                        .offset(x: widths.cached)
                }
                Capsule().stroke(Color.white, lineWidth: 1)
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
