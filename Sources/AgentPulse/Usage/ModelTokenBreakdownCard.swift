import SwiftUI

/// 「Top 3 按模型统计 TOKENS」卡：黑底白字，与 TPS / Token 汇总卡同一视觉语言。
///
/// 每行 = 圆点色标 + 模型名 + 进度条 + token 缩写值 + 百分比。默认只展示占比最高的
/// Top 3，其余折叠在「+N 更多」下；点击在面板内就地展开 / 收起完整列表，不弹新窗口。
/// 数据来自展示层 `TokenUsageWindowSummary.perModel`，随所选窗口切换；无分模型数据时整卡隐藏。
struct ModelTokenBreakdownCard: View {
    let summary: TokenUsageSummary
    let window: TokenUsageWindow
    /// 是否显示「TOP 3 · 按模型 TOKENS」标题行。悬浮球气泡里传 false 隐藏标题。
    var showsTitle: Bool = true
    /// 是否支持「+N 更多」展开。悬浮球气泡里传 false：硬截 Top3、不足则显示实际数、无展开按钮。
    var expandable: Bool = true

    /// 默认折叠时展示的模型条目数。
    private static let collapsedLimit = 3
    private static let cardCornerRadius: CGFloat = 12

    @State private var expanded = false

    var body: some View {
        let models = sortedModels
        if !models.isEmpty {
            let total = max(1, models.reduce(Int64(0)) { $0 + max(0, $1.totalTokens) })
            // 不可展开时永远只取 Top3（不足则实际数）；可展开时随 expanded 决定。
            let visible = (expandable && expanded) ? models : Array(models.prefix(Self.collapsedLimit))
            let hiddenCount = models.count - visible.count

            VStack(alignment: .leading, spacing: 10) {
                if showsTitle {
                    Text("TOP 3 · 按模型 TOKENS")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white)
                }

                VStack(spacing: 8) {
                    ForEach(visible, id: \.model) { item in
                        ModelTokenRow(
                            color: modelPaletteColor(for: item.model, among: models.map(\.model)),
                            model: item.model,
                            tokens: item.totalTokens,
                            fraction: Double(max(0, item.totalTokens)) / Double(total)
                        )
                    }
                }

                if expandable, hiddenCount > 0 || expanded {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text(expanded ? "收起" : "+\(hiddenCount) 更多")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "收起模型列表" : "展开其余 \(hiddenCount) 个模型")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black, in: RoundedRectangle(cornerRadius: Self.cardCornerRadius))
        }
    }

    /// 当前窗口的分模型明细，按 token 降序；同值按模型名稳定排序。
    /// 过滤掉 token ≤ 0 的条目（如账本占位 model `<synthetic>`），避免 0 值行混入列表。
    private var sortedModels: [TokenModelUsage] {
        (summary[window]?.perModel ?? [])
            .filter { $0.totalTokens > 0 }
            .sorted {
                if $0.totalTokens == $1.totalTokens {
                    return $0.model.localizedStandardCompare($1.model) == .orderedAscending
                }
                return $0.totalTokens > $1.totalTokens
            }
    }
}

/// 单个模型行：色点 + 模型名 + 进度条 + 缩写值 + 百分比。
private struct ModelTokenRow: View {
    let color: Color
    let model: String
    let tokens: Int64
    let fraction: Double

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(model)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(color)
                        .frame(width: max(0, min(1, fraction)) * geometry.size.width)
                }
            }
            .frame(height: 5)
            Text(TokenUsageFormatting.tokens(tokens))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .frame(width: 56, alignment: .trailing)
            Text(TokenUsageFormatting.percent(fraction))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.white)
                .frame(width: 44, alignment: .trailing)
        }
        .foregroundStyle(Color.white)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(model)
        .accessibilityValue("\(TokenUsageFormatting.tokens(tokens))，\(TokenUsageFormatting.percent(fraction))")
    }
}
