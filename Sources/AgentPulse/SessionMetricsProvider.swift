import AgentPulseCore
import Combine
import Foundation

public enum MetricValue<Wrapped: Sendable & Equatable>: Sendable, Equatable {
    case value(Wrapped)
    case partial(Wrapped)
    case unavailable(reason: String)
}

public struct TPSPoint: Sendable, Equatable, Identifiable {
    public let id: Date
    public let timestamp: Date
    public let tokensPerSecond: Double
    public let state: LiveRateState

    init(timestamp: Date, tokensPerSecond: Double, state: LiveRateState) {
        id = timestamp
        self.timestamp = timestamp
        self.tokensPerSecond = tokensPerSecond
        self.state = state
    }
}

/// 单个模型的 TPS 历史序列（UI 展示用）。
///
/// `points` 与总曲线共享同一 15 分钟窗口和 1 秒重采样栅格，
/// 保证分模型曲线与总曲线在时间轴上严格对齐。
public struct ModelTPSHistory: Sendable, Equatable, Identifiable {
    public var id: String { model }
    public let model: String
    public let latestTPS: Double
    public let points: [SparklinePoint]

    public init(model: String, latestTPS: Double, points: [SparklinePoint]) {
        self.model = model
        self.latestTPS = latestTPS
        self.points = points
    }
}

/// App 的轻量展示适配器。所有 rollout 解析、TPS 与持久化均由 AgentPulseCore 完成。
@MainActor
public final class MetricsStore: ObservableObject {
    public struct Configuration: Sendable {
        public var sessionsDirectory: URL
        public var automationDirectories: [URL]
        public var claudeSessionsDirectory: URL
        public var claudeProjectsDirectory: URL
        public var scanInterval: TimeInterval
        public var databaseURL: URL?

        public init(
            sessionsDirectory: URL = CodexStatusCollector.resolvedCodexHome()
                .appendingPathComponent("sessions", isDirectory: true),
            automationDirectories: [URL] = [
                CodexStatusCollector.resolvedCodexHome()
                    .appendingPathComponent("automations", isDirectory: true)
            ],
            claudeSessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions", isDirectory: true)
                .resolvingSymlinksInPath(),
            claudeProjectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
                .resolvingSymlinksInPath(),
            databaseURL: URL? = nil
        ) {
            self.sessionsDirectory = sessionsDirectory
            self.automationDirectories = automationDirectories
            self.claudeSessionsDirectory = claudeSessionsDirectory
            self.claudeProjectsDirectory = claudeProjectsDirectory
            // 运行时必须每秒产生一个持久化样本。
            self.scanInterval = 1
            self.databaseURL = databaseURL
        }
    }

    @Published public private(set) var desktopActive: MetricValue<Int> = .unavailable(reason: "正在读取会话")
    @Published public private(set) var totalTasks: MetricValue<Int> = .unavailable(reason: "正在读取会话")
    @Published public private(set) var activeTasks: MetricValue<Int> = .unavailable(reason: "正在读取会话")
    @Published public private(set) var taskBreakdown: RuntimeTaskBreakdown = .unavailable
    @Published public private(set) var completedTotal: MetricValue<Int> = .unavailable(reason: "正在读取会话")
    @Published public private(set) var completedScope: PulseScope = .allLocal
    @Published public private(set) var completedIsLowerBound = false
    @Published public private(set) var terminalActive: MetricValue<Int> = .unavailable(reason: "正在读取会话")
    @Published public private(set) var tps: MetricValue<Double> = .unavailable(reason: "正在读取会话")
    @Published public private(set) var tpsState: LiveRateState = .noData
    @Published public private(set) var tpsHistory: [TPSPoint] = []
    @Published public private(set) var sparklinePoints: [SparklinePoint] = []
    @Published public private(set) var sparklineRegression = SparklineRegression(
        slopePerSecond: nil,
        normalizedSlope: nil,
        sampleCount: 0,
        trend: .insufficient
    )
    @Published public private(set) var modelTPSHistory: [ModelTPSHistory] = []
    /// 看板专用曲线：每点为 5s 滑窗真实速率（不平滑不插值）。菜单/悬浮球仍用上面的平滑序列。
    @Published public private(set) var dashboardSparklinePoints: [SparklinePoint] = []
    @Published public private(set) var dashboardModelTPSHistory: [ModelTPSHistory] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var isRunning = false
    @Published public private(set) var isShowingCachedSnapshot = false
    @Published public private(set) var collectionWarning: String?

    private let configuration: Configuration
    private let collector: CodexRuntimeMetricsCollector?
    private let initializationError: String?
    private var refreshTask: Task<Void, Never>?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        do {
            let databaseURL: URL
            if let configured = configuration.databaseURL {
                databaseURL = configured
            } else {
                databaseURL = try CodexRuntimeMetricsConfiguration.defaultDatabaseURL()
            }
            collector = try CodexRuntimeMetricsCollector(configuration: .init(
                sessionsDirectories: [configuration.sessionsDirectory],
                automationRoots: configuration.automationDirectories.map(\.path),
                databaseURL: databaseURL,
                claudeSessionsDirectory: configuration.claudeSessionsDirectory,
                claudeProjectsDirectory: configuration.claudeProjectsDirectory
            ))
            initializationError = nil
        } catch {
            collector = nil
            initializationError = "初始化本地指标数据库失败：\(Self.safeErrorDescription(error))"
        }
    }

    public func start() {
        guard refreshTask == nil else { return }
        isRunning = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await restoreCachedDisplayState()
            let clock = ContinuousClock()
            while !Task.isCancelled {
                let nextTick = clock.now.advanced(by: .seconds(configuration.scanInterval))
                await refreshNow()
                do {
                    try await clock.sleep(until: nextTick)
                } catch is CancellationError {
                    break
                } catch {
                    collectionWarning = "采样计时器失败"
                    break
                }
            }
        }
    }

    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        isRunning = false
    }

    public func refreshNow() async {
        guard let collector else {
            applyUnavailable(reason: initializationError ?? "采集器不可用")
            return
        }
        do {
            let result = try await collector.scan(at: Date())
            totalTasks = metric(result.totalTasks, partial: result.activeCountsArePartial)
            activeTasks = metric(result.activeTasks, partial: result.activeCountsArePartial)
            taskBreakdown = result.taskBreakdown
            desktopActive = metric(result.desktopActive, partial: result.activeCountsArePartial)
            terminalActive = metric(result.terminalActive, partial: result.activeCountsArePartial)
            if let completed = result.completed.value {
                completedTotal = .partial(completed)
            } else {
                completedTotal = .unavailable(reason: "本地 rollout 不可读")
            }
            completedScope = result.completed.scope
            completedIsLowerBound = result.completed.isLowerBound
            tpsState = result.liveRate.state
            tps = metric(from: result.liveRate)
            tpsHistory = result.history.compactMap { sample in
                guard let value = sample.tps else { return nil }
                return TPSPoint(timestamp: sample.timestamp, tokensPerSecond: value, state: sample.state)
            }
            let sparkline = SparklineAnalysis.makeSparkline(
                from: result.history,
                end: result.sampledAt
            )
            sparklinePoints = sparkline.points
            sparklineRegression = sparkline.regression
            modelTPSHistory = makeModelTPSHistory(from: result.history, end: result.sampledAt)
            dashboardSparklinePoints = SparklineAnalysis.makeDashboardSparkline(from: result.history, end: result.sampledAt)
            dashboardModelTPSHistory = makeModelTPSHistory(from: result.history, end: result.sampledAt, dashboard: true)
            lastRefresh = result.sampledAt
            isShowingCachedSnapshot = false
            collectionWarning = result.unreadableFiles > 0
                ? "有 \(result.unreadableFiles) 个 rollout 文件不可读，计数为下界"
                : nil
        } catch {
            applyUnavailable(reason: "采集或持久化失败：\(Self.safeErrorDescription(error))")
        }
    }

    private func metric(_ value: Int?, partial: Bool) -> MetricValue<Int> {
        guard let value else { return .unavailable(reason: "会话状态不可用") }
        return partial ? .partial(value) : .value(value)
    }

    private func metric(from sample: LiveRateSample) -> MetricValue<Double> {
        switch sample.state {
        case .live:
            return .value(sample.tps ?? 0)
        case .zero:
            return .value(0)
        case .noData:
            return .unavailable(reason: "尚无 output token 数据")
        case .stale:
            return .unavailable(reason: "output token 数据已陈旧")
        case .unavailable:
            return .unavailable(reason: "output token 数据源不可用")
        }
    }

    private func applyUnavailable(reason: String) {
        totalTasks = .unavailable(reason: reason)
        activeTasks = .unavailable(reason: reason)
        taskBreakdown = .unavailable
        desktopActive = .unavailable(reason: reason)
        completedTotal = .unavailable(reason: reason)
        completedScope = .allLocal
        completedIsLowerBound = false
        terminalActive = .unavailable(reason: reason)
        tps = .unavailable(reason: reason)
        tpsState = .unavailable
        modelTPSHistory = []
        dashboardSparklinePoints = []
        dashboardModelTPSHistory = []
        collectionWarning = reason
        lastRefresh = Date()
    }

    private func restoreCachedDisplayState() async {
        guard let collector else { return }
        let restored = await collector.restoredDisplayState()
        guard let snapshot = restored.snapshot else { return }

        totalTasks = metric(snapshot.totalTasks, partial: snapshot.activeCountsArePartial)
        activeTasks = metric(snapshot.activeTasks, partial: snapshot.activeCountsArePartial)
        taskBreakdown = snapshot.taskBreakdown
        desktopActive = metric(snapshot.desktopActive, partial: snapshot.activeCountsArePartial)
        terminalActive = metric(snapshot.terminalActive, partial: snapshot.activeCountsArePartial)
        if let completed = snapshot.completed.value {
            completedTotal = .partial(completed)
        }
        completedScope = snapshot.completed.scope
        completedIsLowerBound = snapshot.completed.isLowerBound
        tpsState = snapshot.liveRate.state
        tps = metric(from: snapshot.liveRate)
        tpsHistory = restored.history.compactMap { sample in
            guard let value = sample.tps else { return nil }
            return TPSPoint(timestamp: sample.timestamp, tokensPerSecond: value, state: sample.state)
        }
        let sparkline = SparklineAnalysis.makeSparkline(
            from: restored.history,
            end: snapshot.timestamp
        )
        sparklinePoints = sparkline.points
        sparklineRegression = sparkline.regression
        modelTPSHistory = makeModelTPSHistory(from: restored.history, end: snapshot.timestamp)
        dashboardSparklinePoints = SparklineAnalysis.makeDashboardSparkline(from: restored.history, end: snapshot.timestamp)
        dashboardModelTPSHistory = makeModelTPSHistory(from: restored.history, end: snapshot.timestamp, dashboard: true)
        lastRefresh = snapshot.timestamp
        isShowingCachedSnapshot = true
        collectionWarning = "正在刷新本地 rollout，当前显示上次缓存"
    }

    private func makeModelTPSHistory(
        from history: [LiveRateSample],
        end: Date,
        dashboard: Bool = false
    ) -> [ModelTPSHistory] {
        let models = Set(history.flatMap { sample in
            sample.modelTokensInWindow.keys
        })
        let currentModels = history.reversed().first(where: {
            $0.state == .live || $0.state == .zero
        })?.modelTokensInWindow ?? [:]
        return models.compactMap { model in
            // 图例数字（latestTPS）始终用 180s 口径，稳定且与右上角总数可加；
            // dashboard 曲线点用 5s 滑窗（形态更贴近瞬时），菜单/悬浮球用平滑序列。
            let latestTokens = currentModels[model] ?? 0
            let latestTPS = latestTokens / Double(LiveRateSample.windowSeconds)
            guard latestTPS > 0 || history.contains(where: { ($0.modelTokensInWindow[model] ?? 0) > 0 }) else {
                return nil
            }
            let points = dashboard
                ? SparklineAnalysis.makeDashboardModelSparkline(from: history, model: model, end: end)
                : SparklineAnalysis.makeModelSparkline(from: history, model: model, end: end)
            return ModelTPSHistory(model: model, latestTPS: latestTPS, points: points)
        }
        .sorted {
            if $0.latestTPS == $1.latestTPS { return $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            return $0.latestTPS > $1.latestTPS
        }
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        switch error {
        case let value as SQLiteSnapshotStoreError:
            return String(describing: value)
        case let value as PulseCollectionError:
            return value.description
        default:
            return String(describing: type(of: error))
        }
    }
}
