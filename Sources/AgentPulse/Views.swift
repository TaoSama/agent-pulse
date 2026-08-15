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

    /// 概览面板宽度。
    private static let overviewWidth: CGFloat = 380
    /// 设置面板宽度：比概览宽以容纳凭证长路径。菜单栏弹窗左边缘由系统锚定图标不动、
    /// 窗宽随内容变，故设置页比概览宽的部分向右延伸（系统默认，无法反向固定右边缘）。
    private static let settingsWidth: CGFloat = 460
    /// 概览尚未测得高度时，设置页回落到的默认高度（首帧或异常兜底）。
    private static let settingsFallbackHeight: CGFloat = 640

    /// Token 汇总卡与分模型明细卡共用同一时间窗口选择；不持久化，面板每次重开默认「日」。
    @State private var tokenWindow: TokenUsageWindow = .day
    /// 面板内是否切到设置视图（复用同一弹窗，不再弹独立窗口）。
    @State private var showingSettings = false
    /// 概览面板的实时测量高度：设置页据此锁成同高，使两页切换严格对齐、不跳动。
    /// 概览高度随模型明细浮动，故实时测量而非写死；nil 表示尚未测得。
    @State private var overviewHeight: CGFloat?

    var body: some View {
        Group {
            if showingSettings {
                settingsScreen
            } else {
                overviewScreen
            }
        }
        .onAppear {
            // 供 ⌘, 与"设置"入口在面板内切换，不弹独立窗口。
            model.showSettings = { showingSettings = true }
        }
        .onDisappear {
            // 面板关闭后复位到默认菜单：下次打开回到概览而非停在设置界面。
            showingSettings = false
            // Token 窗口 tab 不记忆：面板每次重开默认回到「日」。
            tokenWindow = .day
        }
    }

    private var settingsScreen: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    showingSettings = false
                } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(BackHotZoneButtonStyle())
                Spacer()
                Text("设置").font(.subheadline.weight(.semibold))
                Spacer()
                // 占位与返回按钮等宽（含热区内边距），保证标题视觉居中。
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .opacity(0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // 设置内容撑满面板剩余高度：面板总高锁成概览同高（见下方 .frame(height:)），
            // 内容不足时下方留白，超出则内部滚动。顶部补一段留白，让首个卡片不贴住标题栏。
            ScrollView {
                AgentPulseSettingsView(model: model)
                    .padding(.top, 6)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: Self.settingsWidth)
        // 高度锁成概览实时测得的高度，两页切换严格对齐、不跳动；未测得时回落默认高。
        .frame(height: overviewHeight ?? Self.settingsFallbackHeight)
    }

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: Self.sectionSpacing) {
            HStack(alignment: .center, spacing: 8) {
                Text("Agent Pulse").font(.subheadline.weight(.semibold))
                Spacer()
                // 刷新（扫描数据）快捷入口：等价设置页「立即扫描」；扫描中转圈并禁用。
                Button {
                    model.scanTokenUsageNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .rotationEffect(.degrees(model.tokenSyncStatus.scanningInProgress ? 360 : 0))
                        .animation(
                            model.tokenSyncStatus.scanningInProgress
                                ? .linear(duration: 1).repeatForever(autoreverses: false)
                                : .default,
                            value: model.tokenSyncStatus.scanningInProgress
                        )
                }
                .buttonStyle(BackHotZoneButtonStyle())
                .focusable(false)
                .disabled(model.tokenSyncStatus.scanningInProgress)
                .accessibilityLabel(model.tokenSyncStatus.scanningInProgress ? "正在扫描" : "刷新数据")
                // 设置齿轮快捷入口：面板内切到设置页（与底部「设置」同一动作）。
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                }
                .buttonStyle(BackHotZoneButtonStyle())
                .focusable(false)
                .accessibilityLabel("设置")
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
                        Text("实时 output TPS · 180 秒滑窗均值")
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
            // collectionWarning 只承载真正的采集告警（计时器失败 / 文件不可读等）；
            // "正在刷新缓存"这句已不再走这里，改由下方 Token 扫描块随扫描周期展示。
            if let warning = model.metricsStore.collectionWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
            // Token 扫描底部块：更新中自带前缀行 + 进度行，与 Token 扫描周期同生共死，
            // 走到 100% 结束时整块消失。只读聚合数，不含文件路径、会话正文或凭证。
            if let scanDetail = TokenUsageFormatting.scanDetail(model.tokenSyncStatus) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(MetricsStore.refreshingCacheNotice, systemImage: "arrow.triangle.2.circlepath")
                    // 进度行用透明占位图标补齐图标宽度，与上方前缀行的文字左对齐。
                    Label {
                        Text(scanDetail)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath").hidden()
                    }
                }
                .font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    showingSettings = true
                } label: {
                    Label("设置", systemImage: "gearshape")
                }
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: Self.overviewWidth)
        // 实时测量概览渲染高度，供设置页锁成同高（两页严格对齐）。概览高度随模型明细
        // 浮动，故用 onGeometryChange 持续跟踪而非写死。
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if height > 0 { overviewHeight = height }
        }
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

/// 返回按钮样式：给整个"返回"标签一块可点热区，悬停 / 按下时用明显的圆角高亮背景 + 描边，
/// 让用户明确知道点哪、有反馈。标题栏是系统浅色 material，故用较深的中性填充，
/// 保证选中态清晰可见（此前 0.08 primary 在浅背景上几乎不可见）。
private struct BackHotZoneButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = configuration.isPressed ? 0.22 : (isHovering ? 0.14 : 0)
        return configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(active))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(isHovering || configuration.isPressed ? 0.35 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
    @AppStorage("dashboard.tpsSpan") private var span: DashboardTPSSpan = .fifteenMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("TPS 趋势").font(.largeTitle.bold())
                    Text(span.subtitle).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(tpsStatusText)
                        .font(.title2.monospacedDigit())
                    Text(trendRateText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(model.sparklineRegression.trend.color(for: model.trendColorMode))
                }
                .help("最新一桶的瞬时 TPS，与曲线最右点一致")
            }
            Picker("时间跨度", selection: $span) {
                ForEach(DashboardTPSSpan.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)
            HStack(alignment: .top, spacing: 18) {
                ModelTPSLegend(
                    series: legendSeries,
                    totalColor: model.sparklineRegression.trend.color(for: model.trendColorMode),
                    totalTPS: latestTotalTPS
                )
                    .frame(width: 190, alignment: .topLeading)
                TPSAxisChartView(
                    points: displayPoints,
                    modelSeries: displayModelSeries,
                    span: span,
                    trend: model.sparklineRegression.trend,
                    colorMode: model.trendColorMode
                )
            }
            .padding(16)
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
            .frame(minHeight: 320)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("TPS 趋势图")
            .accessibilityValue("\(span.accessibilityText())，\(model.sparklineRegression.trend.accessibilityText)，\(summary)")
            Text(summary)
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityLabel("TPS 文本摘要")
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.setDashboardSpan(span) }
        .onChange(of: span) { _, newValue in model.setDashboardSpan(newValue) }
    }

    /// 曲线总点集：前三档来自每秒不重叠桶，1 天来自账本 day series。
    private var displayPoints: [SparklinePoint] {
        span == .oneDay ? model.dashboardDaySeries.total : model.dashboardSparklinePoints
    }

    /// 看板统一「当前值」口径：当前跨度总曲线最右一个有效桶的瞬时 TPS。
    /// 与曲线最右点严格一致（前三档=最后一个 5s 桶，1 天=最后一个 30min 桶）。
    /// 短窗天然会抖、模型停顿时归零，这是所选「真正瞬时」口径的预期表现。
    private var latestTotalTPS: Double {
        Self.latestValue(of: displayPoints) ?? 0
    }

    /// 取点集里最后一个非缺口的值；全缺口返回 nil。
    static func latestValue(of points: [SparklinePoint]) -> Double? {
        points.last(where: { ($0.value?.isFinite ?? false) })?.value
    }

    /// 分模型曲线：前三档来自每秒不重叠桶，1 天来自账本 day series。
    /// latestTPS 统一取各自曲线最右有效桶的瞬时值，与图例数字口径一致。
    private var displayModelSeries: [ModelTPSHistory] {
        let base: [ModelTPSHistory]
        if span == .oneDay {
            let day = model.dashboardDaySeries
            base = day.perModel.map { entry in
                ModelTPSHistory(model: entry.key, latestTPS: 0, points: entry.value)
            }
        } else {
            base = model.dashboardModelTPSHistory
        }
        return base
            .map { ModelTPSHistory(model: $0.model, latestTPS: Self.latestValue(of: $0.points) ?? 0, points: $0.points) }
            .sorted {
                if $0.latestTPS == $1.latestTPS { return $0.model.localizedStandardCompare($1.model) == .orderedAscending }
                return $0.latestTPS > $1.latestTPS
            }
    }

    /// 图例分模型行：与曲线同源、latestTPS 取各自曲线最右有效桶的瞬时值。
    private var legendSeries: [ModelTPSHistory] {
        displayModelSeries
    }

    private var summary: String {
        // 峰值/平均基于当前跨度曲线（与图形一致）；当前值取曲线最右点（与右上角总数一致）。
        let values = displayPoints.compactMap(\.value)
        guard !values.isEmpty else { return "暂无 TPS 数据" }
        let average = values.reduce(0, +) / Double(values.count)
        return String(format: "当前 %.1f · 峰值 %.1f · 平均 %.1f TPS", latestTotalTPS, values.max() ?? 0, average)
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
        case .live:
            // 右上角大数字 = 当前跨度曲线最右有效桶的瞬时 TPS（与曲线最右点一致）。
            // 曲线全缺口时回落到 180s 口径，避免 live 状态下显示 0/—。
            if let latest = Self.latestValue(of: displayPoints) {
                return String(format: "%.1f TPS", latest)
            }
            return model.tps.map { String(format: "%.1f TPS", $0) } ?? "—"
        case .zero: return "0.0 TPS · zero"
        case .noData: return "no data"
        case .stale: return "stale"
        case .unavailable: return "unavailable"
        }
    }
}

private struct ModelTPSLegend: View {
    let series: [ModelTPSHistory]
    /// 总曲线（图中最粗的那条）的颜色与当前值，作为图例首行，避免主曲线在图例里缺席。
    var totalColor: Color? = nil
    var totalTPS: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let totalColor {
                HStack(spacing: 8) {
                    Capsule()
                        .fill(totalColor)
                        .frame(width: 26, height: 4)
                    Text("总计")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(String(format: "%.1f", totalTPS ?? 0))
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
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
    let span: DashboardTPSSpan
    let trend: SparklineTrend
    let colorMode: TrendColorMode

    private var bounds: (lower: Double, upper: Double) {
        let values = points.compactMap(\.value) + modelSeries.flatMap { $0.points.compactMap(\.value) }
        guard let minimum = values.min(), let maximum = values.max() else { return (0, 1) }
        // 看板如实显示真实 TPS：纵轴上界用真实最大值，大值就该显示大，不做分位裁剪压峰。
        let padding = max((maximum - minimum) * 0.08, 0.5)
        return (max(0, minimum - padding), maximum + padding)
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

                    let span = max(scale.upper - scale.lower, 0.000_001)
                    // 曲线只画真实值（point.value），遇缺口断开，绝不跨缺口连线造假斜坡；
                    // 相邻真实点之间用 Catmull-Rom 平滑连线，仅美化连线、不改点值也不新增数据点。
                    let curve = Self.smoothedCurve(
                        for: points, size: size, lower: scale.lower, span: span
                    )
                    for series in modelSeries {
                        let modelCurve = Self.smoothedCurve(
                            for: series.points, size: size, lower: scale.lower, span: span
                        )
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
                let ticks = span.axisTicks()
                ForEach(Array(ticks.enumerated()), id: \.offset) { index, tick in
                    Text(tick.label)
                    if index < ticks.count - 1 { Spacer() }
                }
            }
            .padding(.leading, 48)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func axisLabel(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 把真实值序列转成平滑曲线 Path：遇缺口（value 为 nil/非有限）断开成独立段，
    /// 每段内相邻真实点用 Catmull-Rom 生成三次贝塞尔平滑连线（仅美化连线，不改点 y 值、不跨缺口造点）。
    private static func smoothedCurve(
        for points: [SparklinePoint],
        size: CGSize,
        lower: Double,
        span: Double
    ) -> Path {
        let denominator = Double(max(1, points.count - 1))
        // 按缺口切分连续段，段内收集屏幕坐标点。
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        for (index, point) in points.enumerated() {
            guard let value = point.value, value.isFinite else {
                if !current.isEmpty { segments.append(current); current = [] }
                continue
            }
            let x = size.width * Double(index) / denominator
            let normalized = min(max((value - lower) / span, 0), 1)
            current.append(CGPoint(x: x, y: size.height * (1 - normalized)))
        }
        if !current.isEmpty { segments.append(current) }

        var path = Path()
        for pts in segments {
            guard let first = pts.first else { continue }
            if pts.count == 1 {
                // 孤立真实点：画一个极短线段以可见（不与邻段相连）。
                path.move(to: first)
                path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y))
                continue
            }
            path.move(to: first)
            // Catmull-Rom → 三次贝塞尔：控制点由相邻四点推出，曲线穿过每个真实点。
            for i in 0..<(pts.count - 1) {
                let p0 = pts[max(0, i - 1)]
                let p1 = pts[i]
                let p2 = pts[i + 1]
                let p3 = pts[min(pts.count - 1, i + 2)]
                let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
                let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
                path.addCurve(to: p2, control1: c1, control2: c2)
            }
        }
        return path
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
