import AppKit
import AgentPulseCore
import SwiftUI

let modelTPSPalette: [Color] = [
    Color(red: 0.00, green: 0.72, blue: 0.86),
    Color(red: 1.00, green: 0.58, blue: 0.10),
    Color(red: 0.64, green: 0.38, blue: 1.00),
    Color(red: 1.00, green: 0.82, blue: 0.12),
    Color(red: 0.95, green: 0.34, blue: 0.82),
    Color(red: 0.25, green: 0.52, blue: 1.00),
]

/// 按模型名在调色板中取稳定颜色：同名跨视图（TPS 图例、Token 明细）取色一致。
func modelPaletteColor(for model: String, among models: [String]) -> Color {
    let ordered = Set(models).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let index = ordered.firstIndex(of: model) ?? 0
    return modelTPSPalette[index % modelTPSPalette.count]
}

private func modelTPSColor(for model: String, in series: [ModelTPSHistory]) -> Color {
    modelPaletteColor(for: model, among: series.map(\.model))
}

extension SparklineTrend {
    func color(for mode: TrendColorMode) -> Color {
        switch self {
        case .rising: mode == .risingGreen ? .green : .red
        case .falling: mode == .risingGreen ? .red : .green
        case .flat: mode == .risingGreen ? .green : .red
        case .insufficient: Color(nsColor: .secondaryLabelColor)
        }
    }

    var accessibilityText: String {
        switch self {
        case .rising: "趋势上升"
        case .falling: "趋势下降"
        case .flat: "趋势横盘"
        case .insufficient: "趋势数据不足"
        }
    }
}

struct MenuBarPulseLabel: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        Image(systemName: "waveform.path.ecg")
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel("Agent Pulse，\(model.compactSummary)，\(model.sparklineRegression.trend.accessibilityText)")
    }
}

private struct SparklineView: View {
    let points: [SparklinePoint]
    let trend: SparklineTrend
    let colorMode: TrendColorMode
    var lineWidth: CGFloat = 2

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let shape = SparklineShape(values: points.map(\.normalized))
        let highContrast = colorSchemeContrast == .increased
        let color = trend.color(for: colorMode)

        shape.stroke(
            color.opacity(highContrast ? 1 : 0.88),
            style: strokeStyle(width: highContrast ? lineWidth + 0.8 : lineWidth)
        )
        .accessibilityHidden(true)
    }

    private func strokeStyle(width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
    }
}

private struct SparklineShape: Shape {
    let values: [Double?]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, rect.width > 0, rect.height > 0 else { return path }
        let denominator = CGFloat(max(1, values.count - 1))
        var segmentStart: Int?
        var previousWasValid = false

        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else {
                if let segmentStart, index - segmentStart == 1 {
                    addPoint(at: segmentStart, value: values[segmentStart] ?? 0, in: rect, denominator: denominator, to: &path)
                }
                segmentStart = nil
                previousWasValid = false
                continue
            }

            let point = point(at: index, value: value, in: rect, denominator: denominator)
            if previousWasValid {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                segmentStart = index
            }
            previousWasValid = true
        }

        if let segmentStart, values.count - segmentStart == 1 {
            addPoint(at: segmentStart, value: values[segmentStart] ?? 0, in: rect, denominator: denominator, to: &path)
        }
        return path
    }

    private func point(at index: Int, value: Double, in rect: CGRect, denominator: CGFloat) -> CGPoint {
        let normalized = min(max(value, 0), 1)
        return CGPoint(
            x: rect.minX + CGFloat(index) / denominator * rect.width,
            y: rect.maxY - CGFloat(normalized) * rect.height
        )
    }

    private func addPoint(at index: Int, value: Double, in rect: CGRect, denominator: CGFloat, to path: inout Path) {
        let center = point(at: index, value: value, in: rect, denominator: denominator)
        let diameter: CGFloat = 2
        path.addEllipse(in: CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
    }
}

struct MenuBarSummaryView: View {
    @ObservedObject var model: ApplicationModel
    @Environment(\.dismiss) private var dismiss

    /// 面板各分区之间的垂直间距。
    private static let sectionSpacing: CGFloat = 12

    /// Token 汇总卡与分模型明细卡共用同一时间窗口选择。
    @State private var tokenWindow: TokenUsageWindow = .day

    var body: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            HStack(alignment: .center, spacing: 8) {
                Text("Agent Pulse").font(.subheadline.weight(.semibold))
                Spacer()
                Circle()
                    .fill(model.tps == nil ? Color.primary : trendColor)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(formatTPS(model.tps))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("实时 output TPS · 180 秒窗口")
                            .font(.caption2)
                            .foregroundStyle(Color.white)
                    }
                    Spacer(minLength: 8)
                    SparklineView(
                        points: model.sparklinePoints,
                        trend: model.sparklineRegression.trend,
                        colorMode: model.trendColorMode,
                        lineWidth: 1.8
                    )
                    .frame(width: 126, height: 42)
                }
                if !model.modelTPSHistory.isEmpty {
                    Divider().overlay(Color.white.opacity(0.22))
                    HStack(alignment: .top, spacing: 12) {
                        CompactModelTPSLegend(series: model.modelTPSHistory)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        ModelTPSSparkline(series: model.modelTPSHistory)
                            .frame(width: 126)
                            .frame(minHeight: 54, maxHeight: .infinity)
                    }
                }
            }
            .padding(12)
            .foregroundStyle(Color.white)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 12))

            TokenSummaryCard(summary: model.tokenSummary, tps: model.tps, syncStatus: model.tokenSyncStatus, selectedWindow: $tokenWindow)

            ModelTokenBreakdownCard(summary: model.tokenSummary, window: tokenWindow)

            HStack(spacing: 8) {
                CompactMetric(title: "Active", value: format(model.activeTasks), symbol: "bolt.fill")
                CompactMetric(
                    title: "Total",
                    value: format(model.totalTasks, lowerBound: model.totalTasksIsLowerBound),
                    symbol: "square.stack.3d.up"
                )
            }
            RuntimeSourceGrid(breakdown: model.taskBreakdown)
            if let warning = model.hotKeyWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let warning = model.metricsStore.collectionWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Button("打开 TPS 看板") { presentFromMenuBar(model.showDashboard) }
                Spacer()
                Button("上传图片  ⌘⌥V") { model.uploadClipboard() }
                    .disabled(model.uploadService.isUploading)
            }
            Divider()
            HStack {
                Button(model.isOrbVisible ? "隐藏悬浮球" : "显示悬浮球") { model.toggleOrb() }
                Spacer()
                Button {
                    presentFromMenuBar(model.showSettings)
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private var trendColor: Color {
        model.sparklineRegression.trend.color(for: model.trendColorMode)
    }

    private func presentFromMenuBar(_ action: (@MainActor () -> Void)?) {
        guard let action else { return }
        dismiss()
        Task { @MainActor in action() }
    }

    private func format(_ value: Int?, lowerBound: Bool = false) -> String {
        value.map { "\(lowerBound ? "≥" : "")\($0)" } ?? "—"
    }
}

private struct CompactMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(Color.white)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// 菜单栏中的四来源 2×2 网格；每行两个来源。
private struct RuntimeSourceGrid: View {
    let breakdown: RuntimeTaskBreakdown

    var body: some View {
        VStack(spacing: 6) {
            RuntimeSourcePairRow(
                leftTitle: "Codex Desktop",
                leftMetric: breakdown.codexDesktop,
                rightTitle: "Codex CLI",
                rightMetric: breakdown.codexCLI
            )
            RuntimeSourcePairRow(
                leftTitle: "Claude CLI",
                leftMetric: breakdown.claudeCLI,
                rightTitle: "Claude Desktop",
                rightMetric: breakdown.claudeDesktop
            )
        }
    }
}

private struct RuntimeSourcePairRow: View {
    let leftTitle: String
    let leftMetric: RuntimeTaskCategoryMetric
    let rightTitle: String
    let rightMetric: RuntimeTaskCategoryMetric

    var body: some View {
        HStack(spacing: 10) {
            AgentCategoryCell(title: leftTitle, metric: leftMetric)
            Rectangle().fill(Color.white).frame(width: 1, height: 20)
            AgentCategoryCell(title: rightTitle, metric: rightMetric)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentCategoryCell: View {
    let title: String
    let metric: RuntimeTaskCategoryMetric

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
            Spacer(minLength: 4)
            Text(CategoryFormatting.value(for: metric))
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(CategoryFormatting.value(for: metric))
    }
}

/// 分类计数的统一格式化：默认 "active / total"，缺失以 — 占位，
/// CLI 未开启（present=false）显示 "closed"。
enum CategoryFormatting {
    static func value(for metric: RuntimeTaskCategoryMetric) -> String {
        if !metric.present { return "closed" }
        let active = metric.activeTasks.map(String.init) ?? "—"
        let total = metric.totalTasks.map(String.init) ?? "—"
        return "\(active) / \(total)"
    }
}

struct OrbView: View {
    @ObservedObject var model: ApplicationModel

    private static let selectedShell = Color.white
    private static let shellThickness: CGFloat = 4

    var body: some View {
        let trend = model.sparklineRegression.trend
        ZStack {
            Circle().fill(model.isOrbExpanded ? Self.selectedShell : Color.black)
            Circle()
                .fill(Color.black)
                .padding(Self.shellThickness)
            VStack(spacing: 1) {
                SparklineView(
                    points: model.sparklinePoints,
                    trend: trend,
                    colorMode: model.trendColorMode,
                    lineWidth: 1.35
                )
                    .frame(width: 30, height: 12)
                Text(formatTPS(model.tps))
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
            }
        }
        .contentShape(Circle())
        .accessibilityLabel("Agent Pulse 悬浮球")
        .accessibilityValue(
            model.tps.map {
                "实时输出每秒 \(String(format: "%.1f", $0)) token，\(model.sparklineRegression.trend.accessibilityText)"
            } ?? "实时输出不可用"
        )
    }
}

struct OrbTaskListItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct OrbTaskListView: View {
    let allTasksValue: String
    let items: [OrbTaskListItem]

    var body: some View {
        VStack(spacing: 6) {
            OrbTaskListRow(title: "All tasks", value: allTasksValue, emphasized: true)
            ForEach(items) { item in
                OrbTaskListRow(title: item.title, value: item.value)
            }
        }
        .padding(8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct OrbTaskListRow: View {
    let title: String
    let value: String
    var emphasized = false

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(emphasized ? .callout.weight(.semibold) : .callout)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

struct TPSDashboardView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("TPS 趋势").font(.largeTitle.bold())
                    Text("最近 15 分钟 · SQLite 恢复 · 180 秒固定窗口").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tpsStatusText)
                        .font(.title2.monospacedDigit())
                    Text(trendRateText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.sparklineRegression.trend.color(for: model.trendColorMode))
                }
            }
            HStack(alignment: .top, spacing: 18) {
                ModelTPSLegend(series: model.modelTPSHistory)
                    .frame(width: 190, alignment: .topLeading)
                TPSAxisChartView(
                    points: model.sparklinePoints,
                    modelSeries: model.modelTPSHistory,
                    trend: model.sparklineRegression.trend,
                    colorMode: model.trendColorMode
                )
            }
            .padding(16)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
            .frame(minHeight: 320)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("TPS 趋势图")
            .accessibilityValue("最近十五分钟，\(model.sparklineRegression.trend.accessibilityText)，\(summary)")
            Text(summary)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("TPS 文本摘要")
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 460)
    }

    private var summary: String {
        let values = model.sparklinePoints.compactMap(\.value)
        guard !values.isEmpty else { return "暂无 TPS 数据" }
        let average = values.reduce(0, +) / Double(values.count)
        return String(format: "当前 %.1f · 峰值 %.1f · 平均 %.1f TPS", model.tps ?? 0, values.max() ?? 0, average)
    }

    private var trendRateText: String {
        guard let change = model.sparklineRegression.normalizedSlope else {
            return model.sparklineRegression.trend.accessibilityText
        }
        return String(
            format: "%@ · 回归变化 %+.0f%%",
            model.sparklineRegression.trend.accessibilityText,
            change * 100
        )
    }

    private var tpsStatusText: String {
        switch model.tpsState {
        case .live: model.tps.map { String(format: "%.1f TPS", $0) } ?? "—"
        case .zero: "0.0 TPS · zero"
        case .noData: "no data"
        case .stale: "stale"
        case .unavailable: "unavailable"
        }
    }
}

private struct ModelTPSLegend: View {
    let series: [ModelTPSHistory]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(series) { item in
                HStack(spacing: 8) {
                    Capsule()
                        .fill(modelTPSColor(for: item.model, in: series))
                        .frame(width: 26, height: 3)
                    Text(item.model)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f", item.latestTPS))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            if series.isEmpty {
                Text("暂无分模型数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 28)
    }
}

private struct CompactModelTPSLegend: View {
    let series: [ModelTPSHistory]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(series) { item in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(modelTPSColor(for: item.model, in: series))
                        .frame(width: 18, height: 3)
                    Text(item.model)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 3)
                    Text(String(format: "%.1f", item.latestTPS))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }
        }
    }
}

private struct ModelTPSSparkline: View {
    let series: [ModelTPSHistory]

    var body: some View {
        Canvas { context, size in
            let allValues = series.flatMap { $0.points.compactMap(\.value) }
            let upper = max(allValues.max() ?? 1, 1)
            for item in series {
                var path = Path()
                var hasPrevious = false
                let denominator = Double(max(1, item.points.count - 1))
                for (index, point) in item.points.enumerated() {
                    guard let value = point.value, value.isFinite else {
                        hasPrevious = false
                        continue
                    }
                    let location = CGPoint(
                        x: size.width * Double(index) / denominator,
                        y: size.height * (1 - min(max(value / upper, 0), 1))
                    )
                    if hasPrevious { path.addLine(to: location) } else { path.move(to: location) }
                    hasPrevious = true
                }
                context.stroke(
                    path,
                    with: .color(modelTPSColor(for: item.model, in: series)),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct TPSAxisChartView: View {
    let points: [SparklinePoint]
    let modelSeries: [ModelTPSHistory]
    let trend: SparklineTrend
    let colorMode: TrendColorMode

    private var bounds: (lower: Double, upper: Double) {
        let values = points.compactMap(\.value) + modelSeries.flatMap { $0.points.compactMap(\.value) }
        guard let minimum = values.min() else { return (0, 1) }
        // 上界对异常值稳健：稀疏大跳增（累计计数一次落盘）会制造孤立尖峰，若用绝对 max 定轴，
        // 单个尖峰会把整条轴撑高、其余曲线被压扁贴底。改用 P95 分位定上界，尖峰顶到轴顶被裁，
        // 其余曲线获得合理纵向展开；仍保留对真实最大值的下限保护，避免分位过低截掉正常波峰。
        let sorted = values.sorted()
        let robustUpper = SparklineAnalysis.quantile(sorted, 0.95)
        let upper = max(robustUpper, minimum + 0.5)
        let padding = max((upper - minimum) * 0.08, 0.5)
        return (max(0, minimum - padding), upper + padding)
    }

    var body: some View {
        let scale = bounds
        VStack(alignment: .leading, spacing: 6) {
            Text("TPS")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing) {
                    Text(axisLabel(scale.upper))
                    Spacer()
                    Text(axisLabel((scale.lower + scale.upper) / 2))
                    Spacer()
                    Text(axisLabel(scale.lower))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40)

                Canvas { context, size in
                    let gridColor = Color.secondary.opacity(0.16)
                    for fraction in [0.0, 0.5, 1.0] {
                        var horizontal = Path()
                        let y = size.height * fraction
                        horizontal.move(to: CGPoint(x: 0, y: y))
                        horizontal.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(horizontal, with: .color(gridColor), lineWidth: 1)
                    }
                    for fraction in [0.0, 1.0 / 3.0, 2.0 / 3.0, 1.0] {
                        var vertical = Path()
                        let x = size.width * fraction
                        vertical.move(to: CGPoint(x: x, y: 0))
                        vertical.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(vertical, with: .color(gridColor), lineWidth: 1)
                    }

                    let denominator = Double(max(1, points.count - 1))
                    let span = max(scale.upper - scale.lower, 0.000_001)
                    var curve = Path()
                    var previousWasValid = false
                    for (index, point) in points.enumerated() {
                        guard let value = point.value, value.isFinite else {
                            previousWasValid = false
                            continue
                        }
                        let x = size.width * Double(index) / denominator
                        let normalized = min(max((value - scale.lower) / span, 0), 1)
                        let location = CGPoint(x: x, y: size.height * (1 - normalized))
                        if previousWasValid { curve.addLine(to: location) } else { curve.move(to: location) }
                        previousWasValid = true
                    }
                    for series in modelSeries {
                        var modelCurve = Path()
                        var hasPrevious = false
                        let seriesDenominator = Double(max(1, series.points.count - 1))
                        for (index, point) in series.points.enumerated() {
                            guard let value = point.value, value.isFinite else {
                                hasPrevious = false
                                continue
                            }
                            let x = size.width * Double(index) / seriesDenominator
                            let normalized = min(max((value - scale.lower) / span, 0), 1)
                            let location = CGPoint(x: x, y: size.height * (1 - normalized))
                            if hasPrevious { modelCurve.addLine(to: location) } else { modelCurve.move(to: location) }
                            hasPrevious = true
                        }
                        context.stroke(
                            modelCurve,
                            with: .color(modelTPSColor(for: series.model, in: modelSeries)),
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                        )
                    }
                    context.stroke(
                        curve,
                        with: .color(trend.color(for: colorMode)),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                    )
                }
            }

            HStack {
                Text("15 分钟前")
                Spacer()
                Text("10 分钟")
                Spacer()
                Text("5 分钟")
                Spacer()
                Text("现在")
            }
            .padding(.leading, 48)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func axisLabel(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}

private func formatTPS(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "—"
}

struct UploadToastView: View {
    let state: ToastState
    let copy: (URL) -> Void
    let close: () -> Void
    let hover: (Bool) -> Void
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case let .progress(message):
                ProgressView().controlSize(.small)
                Text(message)
            case let .success(url):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("上传成功").font(.headline)
                    Text(url.absoluteString).lineLimit(1).truncationMode(.middle).font(.caption.monospaced())
                }
                Button(copied ? "已复制" : "复制 URL") {
                    copy(url); copied = true
                }
            case let .failure(message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(3)
                Button("关闭", action: close)
            }
        }
        .padding(12)
        .frame(maxWidth: 460)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 13))
        .onHover(perform: hover)
        .accessibilityElement(children: .contain)
    }
}
