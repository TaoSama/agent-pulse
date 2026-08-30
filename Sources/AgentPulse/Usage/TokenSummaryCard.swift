import AgentPulseUI
import SwiftUI

///
/// 黑底白字，与 TPS 卡风格一致；不使用灰色承载信息。
/// 当前窗口无数据时明确展示空状态，不把 0 冒充真实值。
struct TokenSummaryCard: View {
    let summary: TokenUsageSummary
    let tps: Double?
    let syncStatus: TokenSyncStatus
    @Binding var selectedWindow: TokenUsageWindow

    init(
        summary: TokenUsageSummary,
        tps: Double?,
        syncStatus: TokenSyncStatus,
        selectedWindow: Binding<TokenUsageWindow>
    ) {
        self.summary = summary
        self.tps = tps
        self.syncStatus = syncStatus
        _selectedWindow = selectedWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
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

                Spacer(minLength: 8)

                TokenSyncUpdateStatusView(status: syncStatus)
            }

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
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
        .padding(12)
        .foregroundStyle(Color.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
    }

    private var selectedSummary: TokenUsageWindowSummary? { summary[selectedWindow] }

    private var accessibilityLabel: String {
        let tokens = selectedSummary.map { String($0.totalTokens) } ?? "无数据"
        let cost = selectedSummary.map { String(format: "$%.2f", $0.estimatedCost) } ?? "未知"
        let hitRate = TokenUsageFormatting.percent(selectedSummary?.cacheHitRate)
        let tpsText = tps.map { String(format: "%.1f", $0) } ?? "不可用"
        return "\(selectedWindow.accessibilityLabel)，总 Tokens \(tokens)，估算费用 \(cost)，缓存命中率 \(hitRate)，实时 TPS \(tpsText)"
    }
}

/// Token 卡右上角更新状态：平时显示「上次更新: 相对时间」（随计时器自动刷新）；
/// 扫描/上报中显示「正在更新: 整体百分比」。阶段名、文件计数等完整详情移到菜单底部状态行。
///
/// 只读展示聚合数（百分比 / 相对时间），不显示文件路径、会话正文或凭证。
struct TokenSyncUpdateStatusView: View {
    let status: TokenSyncStatus

    @State private var now = Date()
    @StateObject private var smoother = ScanProgressSmoother()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// 扫描或上报任一进行中，右上角都展示百分比。
    private var inProgress: Bool {
        status.scanningInProgress || status.reportingInProgress
    }

    var body: some View {
        Text(statusText)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Color.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .onReceive(ticker) { now = $0 }
            .onAppear {
                smoother.setTarget(inProgress ? status.scanProgress : nil)
            }
            .onChange(of: status.scanProgress) { _, newValue in
                smoother.setTarget(inProgress ? newValue : nil)
            }
            .onChange(of: inProgress) { _, running in
                smoother.setTarget(running ? status.scanProgress : nil)
            }
            .onDisappear {
                smoother.cancelAnimation()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(statusText)
    }

    /// 右上角文案：更新中「正在更新: xx%」（平滑值）；空闲「上次更新: 相对时间」。
    private var statusText: String {
        if inProgress {
            return "正在更新: \(TokenUsageFormatting.percent(smoother.displayed))"
        }
        return "上次更新: \(TokenUsageFormatting.relativeTime(status.lastScanAt, now: now))"
    }
}

/// 白色刷新图标：`spinning=true` 时持续匀速旋转，否则静止。用于 Token 概览卡的更新状态行。
private struct SpinningRefreshIcon: View {
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.white)
            .rotationEffect(.degrees(angle))
            .onAppear { if spinning { startSpin() } else { stopSpin() } }
            .onChange(of: spinning) { _, running in
                if running { startSpin() } else { stopSpin() }
            }
    }

    private func startSpin() {
        angle = 0
        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
            angle = 360
        }
    }

    /// 刷新结束：用一个即时（0 秒）动画覆盖残留的 repeatForever，把角度归零并真正停转。
    private func stopSpin() {
        withAnimation(.linear(duration: 0)) {
            angle = 0
        }
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

/// 悬浮球气泡用的今日 Token 概览卡：与 `TokenSummaryCard` 同款视觉，但去掉顶部窗口切换器
/// 与右下角 TPS 展示，固定「日」窗口（今日）。费用上方加一行更新时间（转圈 icon + 英文相对时间，
/// 无前缀）。只读展示聚合数，不含路径/正文/凭证。
struct OrbTokenOverviewCard: View {
    let summary: TokenUsageSummary
    let syncStatus: TokenSyncStatus

    @State private var now = Date()
    @StateObject private var smoother = ScanProgressSmoother()
    private let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var day: TokenUsageWindowSummary? { summary[.day] }
    private var inProgress: Bool { syncStatus.scanningInProgress || syncStatus.reportingInProgress }

    /// 刷新中显示平滑百分比，否则显示英文相对时间（just now / 3m ago）。
    private var statusText: String {
        if inProgress {
            return TokenUsageFormatting.percent(smoother.displayed)
        }
        return TokenUsageFormatting.relativeTimeEnglish(syncStatus.lastScanAt, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 左侧大号 token 数字；右侧一列：上=更新状态（转圈 icon + 进度百分比 / 英文相对时间），
            // 下=估算费用。右列整体与左侧数字等高、右对齐。
            HStack(alignment: .center) {
                Text(TokenUsageFormatting.tokens(day?.totalTokens))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        SpinningRefreshIcon(spinning: smoother.isAnimating)
                        Text(statusText)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Color.white)
                    Text(TokenUsageFormatting.cost(day?.estimatedCost))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .onReceive(ticker) { now = $0 }
            .onAppear { smoother.setTarget(inProgress ? syncStatus.scanProgress : nil) }
            .onChange(of: syncStatus.scanProgress) { _, newValue in
                smoother.setTarget(inProgress ? newValue : nil)
            }
            .onChange(of: inProgress) { _, running in
                smoother.setTarget(running ? syncStatus.scanProgress : nil)
            }
            .onDisappear {
                smoother.cancelAnimation()
            }

            TokenCacheRatioBar(cached: day?.cachedTokens, new: day?.newTokens)

            HStack(spacing: 6) {
                TokenFooterMetric(title: "缓存", value: TokenUsageFormatting.tokens(day?.cachedTokens))
                TokenFooterMetric(title: "新增", value: TokenUsageFormatting.tokens(day?.newTokens))
                TokenFooterMetric(title: "命中率", value: TokenUsageFormatting.percent(day?.cacheHitRate))
                Spacer(minLength: 4)
            }

            if day == nil {
                Text("今日暂无数据")
                    .font(.system(size: 10))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
    }
}
