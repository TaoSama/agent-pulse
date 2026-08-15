import SwiftUI

/// 刷新进度平滑器：把阶跃到达的目标百分比（0…1）在时间上缓动，
/// 让「正在更新: xx%」与底部「刷新进度：xx%」平滑爬升而非跳变。
///
/// 语义：
/// - 真实进度领先时：按指数缓动快速追上，封顶到真实目标。
/// - 真实目标停滞时：以最小步（约 0.15%/s）继续极缓慢爬升，但**绝不越过当前阶段的整体上界**——
///   封顶到「阶段上界 − stallMargin(1%)」，表示「本阶段快完了但还没进下一阶段」；
///   只有真实进度推进（阶段前进或达 100%）才允许越过该界。消除「数字卡死」观感又不假装跨阶段。
/// - 只增不减：目标小幅回退不倒退展示值；显著回退（新一轮扫描）时归零重来。
/// - 扫描结束（目标为 nil）时清零，供下次从 0 起步。
@MainActor
final class ScanProgressSmoother: ObservableObject {
    /// 当前展示值（0…1）。
    @Published private(set) var displayed: Double = 0

    private var target: Double = 0
    /// 当前阶段的整体上界（阶段起点 + 权重）；停滞爬升不得越过此界。默认 1（无阶段约束）。
    private var phaseCeiling: Double = 1
    private var ticker: Timer?

    /// 每帧向目标逼近的比例（指数缓动系数）。
    private let easing = 0.18
    /// 每帧最小推进量：即便目标停滞，也让数字极缓慢前移，消除「卡住」观感（约每秒 +0.15%）。
    private let minStepPerTick = 0.00005
    /// 展示帧率（秒）。30fps 足够顺滑且开销低。
    private let tickInterval = 1.0 / 30.0
    /// 目标显著回退阈值：低于此判定为「新一轮扫描重置」，展示值随之归零重来。
    private let resetDropThreshold = 0.05
    /// 停滞爬升与当前阶段上界之间保留的余量：展示值最多到「阶段上界 − 1%」，绝不贴到阶段边界。
    private let stallMargin = 0.01

    /// 设置目标进度与当前阶段上界。`value == nil` 表示未在扫描 → 停止并清零。
    /// `ceiling` 为当前阶段的整体上界（`TokenScanPhase.overallCeiling`）；nil 时按无阶段约束(1)。
    func setTarget(_ value: Double?, phaseCeiling ceiling: Double? = nil) {
        guard let value else {
            stop()
            displayed = 0
            target = 0
            phaseCeiling = 1
            return
        }
        let clamped = min(max(value, 0), 1)
        // 目标大幅回退：视作新扫描重置，展示值归零重新爬升。
        if clamped + resetDropThreshold < target {
            displayed = 0
        }
        target = clamped
        phaseCeiling = min(max(ceiling ?? 1, 0), 1)
        start()
    }

    private func start() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    private func step() {
        // 真实目标已达 100% 且展示也追平：收顶停帧。
        if target >= 1, displayed >= 1 {
            displayed = 1
            stop()
            return
        }
        if displayed < target {
            // 真实进度领先：按指数缓动快速追上（至少走最小步），封顶到目标。
            let remaining = target - displayed
            let advance = max(remaining * easing, min(minStepPerTick, remaining))
            displayed = min(displayed + advance, target)
        } else {
            // 已追平但真实目标停滞：以最小步继续极缓慢爬升，但绝不越过「当前阶段上界 − 1%」，
            // 即「本阶段快完但没进下一阶段」；真实进度到 100% 时才允许贴顶到 1.0。
            let stallCap = target >= 1 ? 1.0 : max(target, phaseCeiling - stallMargin)
            displayed = min(displayed + minStepPerTick, stallCap)
        }
    }
}


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
                smoother.setTarget(inProgress ? status.scanProgress : nil, phaseCeiling: status.scanPhase?.overallCeiling)
            }
            .onChange(of: status.scanProgress) { _, newValue in
                smoother.setTarget(inProgress ? newValue : nil, phaseCeiling: status.scanPhase?.overallCeiling)
            }
            .onChange(of: inProgress) { _, running in
                smoother.setTarget(running ? status.scanProgress : nil, phaseCeiling: status.scanPhase?.overallCeiling)
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
