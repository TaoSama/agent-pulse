import AppKit
import AgentPulseCore
import AgentPulseUsage
import Combine
import Foundation

enum TrendColorMode: String, CaseIterable, Identifiable {
    case risingGreen
    case risingRed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .risingGreen: "上升绿 · 下降红"
        case .risingRed: "上升红 · 下降绿"
        }
    }
}

/// 悬浮球渲染所需的最小状态快照。
/// 只包含 OrbView 真正读取的字段；Equatable 用于在值未变时跳过发布，
/// 避免与悬浮球无关的 @Published 变化触发 OrbView 重建与 SwiftUI keypath 重订阅。
struct OrbSnapshot: Equatable {
    let tps: Double?
    let sparklinePoints: [SparklinePoint]
    let trend: SparklineTrend
    let trendColorMode: TrendColorMode
    let dayTotalTokens: Int64?
    let isExpanded: Bool
}

/// 悬浮球专用的可观察对象。ApplicationModel 每秒刷新的 20+ 个 @Published 字段
/// 不会触发它；只有当 OrbSnapshot 真正变化时才发布，从根上切断观察抖动回路。
@MainActor
final class OrbViewModel: ObservableObject {
    @Published private(set) var snapshot: OrbSnapshot

    init(snapshot: OrbSnapshot) {
        self.snapshot = snapshot
    }

    /// 仅在快照真正变化时发布，no-op 赋值不触发 objectWillChange。
    func update(_ newSnapshot: OrbSnapshot) {
        guard newSnapshot != snapshot else { return }
        snapshot = newSnapshot
    }
}

@MainActor
final class ApplicationModel: ObservableObject {
    static let shared = ApplicationModel()

    @Published private(set) var desktopActive: Int?
    @Published private(set) var totalTasks: Int?
    @Published private(set) var totalTasksIsLowerBound = false
    @Published private(set) var activeTasks: Int?
    @Published private(set) var taskBreakdown: RuntimeTaskBreakdown = .unavailable
    @Published private(set) var completedTotal: Int?
    @Published private(set) var completedIsPartial = false
    @Published private(set) var completedScope: PulseScope = .allLocal
    @Published private(set) var completedIsLowerBound = false
    @Published private(set) var terminalActive: Int?
    @Published private(set) var tps: Double?
    @Published private(set) var tpsState: LiveRateState = .noData
    @Published private(set) var tpsHistory: [TPSPoint] = []
    /// 点与趋势同源，作为一个值镜像，避免视图看到新点配旧趋势的中间态。
    @Published private(set) var sparkline: Sparkline = .empty
    var sparklinePoints: [SparklinePoint] { sparkline.points }
    var sparklineRegression: SparklineRegression { sparkline.regression }
    @Published private(set) var modelTPSHistory: [ModelTPSHistory] = []
    /// 看板不重叠桶曲线（前三档跨度，来自每秒样本）。1 天跨度改用 dashboardDaySeries。
    @Published private(set) var dashboardSparklinePoints: [SparklinePoint] = []
    @Published private(set) var dashboardModelTPSHistory: [ModelTPSHistory] = []
    /// 看板 1 天曲线（长期账本 30min bucket → 平均 TPS）。
    @Published private(set) var dashboardDaySeries: DashboardDaySeries = .empty
    @Published private(set) var tokenSummary: TokenUsageSummary
    @Published private(set) var tokenSyncStatus: TokenSyncStatus
    @Published var trendColorMode: TrendColorMode
    @Published private(set) var hotKeyWarning: String?
    @Published private(set) var toast: ToastState?
    @Published var isOrbVisible = true
    @Published private(set) var isOrbExpanded = false
    /// 悬浮球专用观察模型：只在 OrbSnapshot 变化时发布，隔离其余 @Published 的抖动。
    let orbViewModel: OrbViewModel

    /// 合并 env 的双源字段状态与写回（R2 / cliproxy / 上报简单值同源）。
    let envSettings = EnvSettingsModel()
    let metricsStore = MetricsStore()
    let uploadService: UploadService
    private let tokenSyncCoordinator: TokenSyncCoordinating
    var showDashboard: (@MainActor () -> Void)?
    var showOrb: ((Bool) -> Void)?
    var showToast: ((ToastState) -> Void)?
    var showSettings: (@MainActor () -> Void)?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 合并 env 路径：R2 / cliproxy / 上报简单值统一收敛到一个 0600 文件；
        // 历史遗留路径键平滑迁移到规范键（见 MergedEnvPreferences）。
        let path = MergedEnvPreferences.resolvePath()
        let savedColorMode = UserDefaults.standard.string(forKey: "trendColorMode")
        let initialColorMode = TrendColorMode(rawValue: savedColorMode ?? "") ?? .risingGreen
        trendColorMode = initialColorMode
        uploadService = UploadService(configPath: path)
        let tokenCoordinator = TokenSyncCoordinator()
        tokenCoordinator.hostnameRenamePrompt = { old, new, decide in
            // 决策回调在主线程弹出确认框；NSAlert 需在主线程运行。
            Task { @MainActor in
                decide(Self.confirmHostnameRename(old: old, new: new))
            }
        }
        tokenSyncCoordinator = tokenCoordinator
        let initialSummary = tokenCoordinator.summary
        tokenSummary = initialSummary
        tokenSyncStatus = tokenCoordinator.status
        orbViewModel = OrbViewModel(snapshot: OrbSnapshot(
            tps: nil,
            sparklinePoints: [],
            trend: .insufficient,
            trendColorMode: initialColorMode,
            dayTotalTokens: initialSummary.day?.totalTokens,
            isExpanded: false
        ))
        tokenCoordinator.summaryPublisher.sink { [weak self] value in
            self?.tokenSummary = value
        }.store(in: &cancellables)
        tokenCoordinator.statusPublisher.sink { [weak self] value in
            self?.tokenSyncStatus = value
        }.store(in: &cancellables)
        tokenCoordinator.dashboardDaySeriesPublisher.sink { [weak self] value in
            self?.dashboardDaySeries = value
        }.store(in: &cancellables)
        metricsStore.$desktopActive.sink { [weak self] value in
            self?.desktopActive = value.displayValue
        }.store(in: &cancellables)
        metricsStore.$totalTasks.sink { [weak self] value in
            self?.totalTasks = value.displayValue
            self?.totalTasksIsLowerBound = value.isPartial
        }.store(in: &cancellables)
        metricsStore.$activeTasks.sink { [weak self] value in
            self?.activeTasks = value.displayValue
        }.store(in: &cancellables)
        metricsStore.$taskBreakdown.sink { [weak self] in
            self?.taskBreakdown = $0
        }.store(in: &cancellables)
        metricsStore.$completedTotal.sink { [weak self] value in
            self?.completedTotal = value.displayValue
            self?.completedIsPartial = value.isPartial
        }.store(in: &cancellables)
        metricsStore.$completedScope.sink { [weak self] in
            self?.completedScope = $0
        }.store(in: &cancellables)
        metricsStore.$completedIsLowerBound.sink { [weak self] in
            self?.completedIsLowerBound = $0
        }.store(in: &cancellables)
        metricsStore.$terminalActive.sink { [weak self] value in
            self?.terminalActive = value.displayValue
        }.store(in: &cancellables)
        metricsStore.$tps.sink { [weak self] value in
            self?.tps = value.displayValue
        }.store(in: &cancellables)
        metricsStore.$tpsState.sink { [weak self] in
            self?.tpsState = $0
        }.store(in: &cancellables)
        metricsStore.$tpsHistory.sink { [weak self] in
            self?.tpsHistory = $0
        }.store(in: &cancellables)
        metricsStore.$sparkline.sink { [weak self] in
            self?.sparkline = $0
        }.store(in: &cancellables)
        metricsStore.$modelTPSHistory.sink { [weak self] in
            self?.modelTPSHistory = $0
        }.store(in: &cancellables)
        metricsStore.$dashboardSparklinePoints.sink { [weak self] in
            self?.dashboardSparklinePoints = $0
        }.store(in: &cancellables)
        metricsStore.$dashboardModelTPSHistory.sink { [weak self] in
            self?.dashboardModelTPSHistory = $0
        }.store(in: &cancellables)
        // 合并 env 路径变化：仅同步给 UploadService（路径字符串），凭证不落盘。
        envSettings.$path
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] path in
                self?.uploadService.configPath = path
            }
            .store(in: &cancellables)
        // REPORT_* 简单值由 TokenSyncCoordinator 统一写回 env 并刷新上报状态（单一写者），
        // EnvSettingsModel 只负责回显；此处把这两个键的写回委托给 coordinator。
        envSettings.setExternalWriter({ [weak self] value in
            self?.setTokenIngestBaseURL(value)
        }, for: MergedEnvKeys.reportBaseURL)
        envSettings.setExternalWriter({ [weak self] value in
            self?.setTokenCanonicalHostname(value)
        }, for: MergedEnvKeys.reportCanonicalHostname)
        $trendColorMode
            .dropFirst()
            .removeDuplicates()
            .sink { mode in
                UserDefaults.standard.set(mode.rawValue, forKey: "trendColorMode")
            }
            .store(in: &cancellables)
        subscribeOrbSnapshotInputs()
    }

    /// 悬浮球的输入分布在多个 @Published 上。曲线的点与趋势已合成 Sparkline 单值，
    /// 一轮采集只会各赋值一次；合成一路订阅后同一轮只重建并发布一次快照。
    private func subscribeOrbSnapshotInputs() {
        let metrics = Publishers.CombineLatest(
            metricsStore.$tps,
            metricsStore.$sparkline
        ).map { _ in () }
        let presentation = Publishers.CombineLatest(
            $tokenSummary,
            $trendColorMode
        ).map { _ in () }
        Publishers.Merge(metrics, presentation)
            .sink { [weak self] _ in self?.refreshOrbSnapshot() }
            .store(in: &cancellables)
    }

    var compactSummary: String {
        "Tasks \(format(totalTasks)) · Active \(format(activeTasks)) · TPS \(format(tps))"
    }

    /// 用当前悬浮球相关字段重建快照并推送给 OrbViewModel。
    /// 仅在快照真正变化时发布（OrbViewModel.update 内部 Equatable 守卫），
    /// 与悬浮球无关的 @Published 变化不会走到这里。
    private func refreshOrbSnapshot() {
        let snapshot = OrbSnapshot(
            tps: tps,
            sparklinePoints: sparklinePoints,
            trend: sparklineRegression.trend,
            trendColorMode: trendColorMode,
            dayTotalTokens: tokenSummary.day?.totalTokens,
            isExpanded: isOrbExpanded
        )
        orbViewModel.update(snapshot)
    }

    func start() {
        metricsStore.start()
        tokenSyncCoordinator.start()
    }
    func stop() {
        metricsStore.stop()
        tokenSyncCoordinator.stop()
    }

    func setHotKeyRegistration(_ succeeded: Bool) {
        hotKeyWarning = succeeded ? nil : "⌘⌥V 注册失败，请使用菜单上传"
    }

    func setOrbExpanded(_ expanded: Bool) {
        isOrbExpanded = expanded
        refreshOrbSnapshot()
    }

    func toggleOrb() {
        isOrbVisible.toggle()
        showOrb?(isOrbVisible)
    }

    func uploadClipboard() {
        presentToast(.progress("正在上传剪贴板图片…"))
        Task {
            do {
                let receipt = try await uploadService.uploadClipboardImage()
                presentToast(.success(receipt.publicURL))
            } catch is CancellationError {
                return
            } catch {
                presentToast(.failure(error.localizedDescription))
            }
        }
    }

    func copyURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func presentToast(_ state: ToastState) {
        toast = state
        showToast?(state)
    }

    func setTokenLocalCollection(_ enabled: Bool) { tokenSyncCoordinator.setLocalCollectionEnabled(enabled) }
    func setTokenCompaction(_ enabled: Bool) { tokenSyncCoordinator.setCompactionEnabled(enabled) }
    func setTokenReporting(_ enabled: Bool) { tokenSyncCoordinator.setReportingEnabled(enabled) }
    func setTokenAutoReportInterval(_ interval: TokenReportInterval) { tokenSyncCoordinator.setAutoReportInterval(interval) }
    func setTokenCanonicalHostname(_ hostname: String) { tokenSyncCoordinator.setCanonicalHostname(hostname) }
    func setTokenIngestBaseURL(_ url: String) { tokenSyncCoordinator.setIngestBaseURL(url) }
    func scanTokenUsageNow() { tokenSyncCoordinator.scanNow() }
    func reportTokenUsageNow() { tokenSyncCoordinator.reportNow() }

    /// 看板时间跨度切换：前三档下沉到 MetricsStore 按不重叠桶重算；1 天让 coordinator 刷新账本曲线
    /// 并开启随扫描自动刷新，离开 1 天时停止自动刷新。
    func setDashboardSpan(_ span: DashboardTPSSpan) {
        metricsStore.setDashboardSpan(span)
        if span == .oneDay {
            tokenSyncCoordinator.refreshDashboardDaySeries(active: true, now: Date())
        } else {
            tokenSyncCoordinator.refreshDashboardDaySeries(active: false, now: Date())
        }
    }

    private func format(_ value: Int?) -> String { value.map(String.init) ?? "—" }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }

    /// 设备标识改名确认框：检测到设备标识由旧名改为新名时，询问是否把本地历史一并改名。
    /// 返回 true=确认改名（原地统一历史），false=否（新名生效、历史保留旧名）。
    /// 深色外观与主面板一致；两个按钮分别为「确认改名」/「否」。
    @MainActor
    private static func confirmHostnameRename(old: String, new: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "设备标识已更改"
        alert.informativeText = "检测到设备标识由「\(old)」改为「\(new)」。是否把本地历史数据中的「\(old)」一并改为「\(new)」？"
        alert.addButton(withTitle: "确认改名")
        alert.addButton(withTitle: "否")
        alert.window.appearance = NSAppearance(named: .darkAqua)
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private extension MetricValue {
    var displayValue: Wrapped? {
        switch self {
        case let .value(value), let .partial(value): value
        case .unavailable: nil
        }
    }

    var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }
}

enum ToastState: Equatable {
    case progress(String)
    case success(URL)
    case failure(String)
}
