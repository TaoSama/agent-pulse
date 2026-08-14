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
    @Published private(set) var sparklinePoints: [SparklinePoint] = []
    @Published private(set) var sparklineRegression = SparklineRegression(
        slopePerSecond: nil,
        normalizedSlope: nil,
        sampleCount: 0,
        trend: .insufficient
    )
    @Published private(set) var modelTPSHistory: [ModelTPSHistory] = []
    @Published private(set) var tokenSummary: TokenUsageSummary
    @Published private(set) var tokenSyncStatus: TokenSyncStatus
    @Published var configPath: String
    @Published var cliProxyConfigPath: String
    @Published var trendColorMode: TrendColorMode
    @Published private(set) var hotKeyWarning: String?
    @Published private(set) var toast: ToastState?
    @Published var isOrbVisible = true
    @Published private(set) var isOrbExpanded = false

    let metricsStore = MetricsStore()
    let uploadService: UploadService
    private let tokenSyncCoordinator: TokenSyncCoordinating
    var showDashboard: (@MainActor () -> Void)?
    var showOrb: ((Bool) -> Void)?
    var showToast: ((ToastState) -> Void)?
    var showSettings: (@MainActor () -> Void)?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 兼容旧值：历史默认路径迁移到新默认（家目录凭证文件），
        // 用户显式选择过的路径保持不变。迁移结果需回写以固化。
        let savedPath = UserDefaults.standard.string(forKey: "r2ConfigPath")
        let path = UploadService.resolveConfigPath(saved: savedPath)
        if path != savedPath {
            UserDefaults.standard.set(path, forKey: "r2ConfigPath")
        }
        configPath = path
        // cliproxyapi 采集：仅保存配置文件路径到 UserDefaults；凭证与目标 key 永不落盘。
        let savedCliProxyPath = UserDefaults.standard.string(forKey: CliProxyUsageService.configPathDefaultsKey)
        cliProxyConfigPath = CliProxyUsageService.resolveConfigPath(saved: savedCliProxyPath)
        let savedColorMode = UserDefaults.standard.string(forKey: "trendColorMode")
        trendColorMode = TrendColorMode(rawValue: savedColorMode ?? "") ?? .risingGreen
        uploadService = UploadService(configPath: path)
        let tokenCoordinator = TokenSyncCoordinator()
        tokenSyncCoordinator = tokenCoordinator
        tokenSummary = tokenCoordinator.summary
        tokenSyncStatus = tokenCoordinator.status
        tokenCoordinator.summaryPublisher.sink { [weak self] value in
            self?.tokenSummary = value
        }.store(in: &cancellables)
        tokenCoordinator.statusPublisher.sink { [weak self] value in
            self?.tokenSyncStatus = value
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
        metricsStore.$sparklinePoints.sink { [weak self] in
            self?.sparklinePoints = $0
        }.store(in: &cancellables)
        metricsStore.$sparklineRegression.sink { [weak self] in
            self?.sparklineRegression = $0
        }.store(in: &cancellables)
        metricsStore.$modelTPSHistory.sink { [weak self] in
            self?.modelTPSHistory = $0
        }.store(in: &cancellables)
        $configPath
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] path in
                UserDefaults.standard.set(path, forKey: "r2ConfigPath")
                self?.uploadService.configPath = path
            }
            .store(in: &cancellables)
        $cliProxyConfigPath
            .dropFirst()
            .removeDuplicates()
            .sink { path in
                // 仅持久化路径字符串；凭证与目标 key 绝不写入 UserDefaults。
                UserDefaults.standard.set(path, forKey: CliProxyUsageService.configPathDefaultsKey)
            }
            .store(in: &cancellables)
        $trendColorMode
            .dropFirst()
            .removeDuplicates()
            .sink { mode in
                UserDefaults.standard.set(mode.rawValue, forKey: "trendColorMode")
            }
            .store(in: &cancellables)
    }

    var compactSummary: String {
        "Tasks \(format(totalTasks)) · Active \(format(activeTasks)) · TPS \(format(tps))"
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
    func setTokenReporting(_ enabled: Bool) { tokenSyncCoordinator.setReportingEnabled(enabled) }
    func setTokenCanonicalHostname(_ hostname: String) { tokenSyncCoordinator.setCanonicalHostname(hostname) }
    func setTokenIngestBaseURL(_ url: String) { tokenSyncCoordinator.setIngestBaseURL(url) }
    func scanTokenUsageNow() { tokenSyncCoordinator.scanNow() }
    func reportTokenUsageNow() { tokenSyncCoordinator.reportNow() }
    func runTokenFullSync() { tokenSyncCoordinator.runFullSync() }

    private func format(_ value: Int?) -> String { value.map(String.init) ?? "—" }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
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
