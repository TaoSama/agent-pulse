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

/// 每秒刷新时由样本历史派生的曲线集合。全部为纯计算结果，可在后台线程算好后
/// 一次性回主线程赋值，避免每秒在主线程重跑总曲线 + 每模型曲线 ×2 套口径。
private struct DerivedSeries: Sendable {
    var sparkline: Sparkline
    var modelTPSHistory: [ModelTPSHistory]
    var dashboardSparklinePoints: [SparklinePoint]
    var dashboardModelTPSHistory: [ModelTPSHistory]
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
    /// 点与趋势同源，合成一个值一次发布：分开发布会让订阅方看到新点配旧趋势的中间态。
    @Published public private(set) var sparkline: Sparkline = .empty
    @Published public private(set) var modelTPSHistory: [ModelTPSHistory] = []
    /// 看板专用曲线：不重叠桶（按当前跨度）的平均 TPS，前三档来自每秒逐秒净增量。
    /// 1 天跨度不走这里（改用 coordinator 的 day series）。
    @Published public private(set) var dashboardSparklinePoints: [SparklinePoint] = []
    @Published public private(set) var dashboardModelTPSHistory: [ModelTPSHistory] = []
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var isRunning = false
    @Published public private(set) var isShowingCachedSnapshot = false
    @Published public private(set) var collectionWarning: String?

    /// 冷启动 / 后台重建期间"显示缓存值"的提示语。抽为常量供 UI 判重：
    /// Token 扫描进度块会自带同款前缀行，此文案的 collectionWarning 不再重复展示。
    public static let refreshingCacheNotice = "正在刷新本地 rollout，当前显示上次缓存"

    private let configuration: Configuration
    private let collector: CodexRuntimeMetricsCollector?
    private let initializationError: String?
    private var refreshTask: Task<Void, Never>?
    /// 看板当前选中的时间跨度（前三档从每秒样本按不重叠桶算；1 天由 coordinator 账本 series 接管）。
    private var dashboardSpan: DashboardTPSSpan = .fifteenMinutes
    /// 最近一次刷新/恢复得到的看板用较长历史（最多 3600s）与其参考时刻，供跨度切换时即时重算。
    private var dashboardSampleCache: [LiveRateSample] = []
    private var dashboardSampleEnd: Date = .init(timeIntervalSince1970: 0)

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
        // 首轮可能需要解析体积很大的活跃 rollout；整个刷新循环都属于后台采样，
        // 从源头使用 background 优先级，避免继承 MainActor 的前台优先级。
        refreshTask = Task(priority: .background) { [weak self] in
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
            publish(result.liveRate.state, to: \.tpsState)
            publish(metric(from: result.liveRate), to: \.tps)
            tpsHistory = result.history.compactMap { sample in
                guard let value = sample.tps else { return nil }
                return TPSPoint(timestamp: sample.timestamp, tokensPerSecond: value, state: sample.state)
            }
            // 看板不重叠桶：缓存较长历史（最多 3600s）供跨度切换即时重算。
            dashboardSampleCache = result.dashboardHistory
            dashboardSampleEnd = result.sampledAt
            // 总曲线 + 每模型曲线 ×2 套口径都是无 UI 依赖的纯计算。放到后台线程算好，
            // 主线程只做一次批量赋值，避免每秒在 MainActor 上重跑整批 sparkline 管线。
            let span = dashboardSpan
            let derived = await Self.deriveSeries(
                history: result.history,
                dashboardSamples: result.dashboardHistory,
                end: result.sampledAt,
                span: span,
                model: makeModelTPSHistory,
                dashboardModel: makeDashboardModelTPSHistory
            )
            publish(derived.sparkline, to: \.sparkline)
            modelTPSHistory = derived.modelTPSHistory
            dashboardSparklinePoints = derived.dashboardSparklinePoints
            dashboardModelTPSHistory = derived.dashboardModelTPSHistory
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

    /// 值未变时跳过赋值。@Published 的 setter 无条件触发 objectWillChange，
    /// 而每秒采集里绝大多数字段实际未变；重复发布会让订阅方反复重建 SwiftUI 订阅。
    private func publish<Value: Equatable>(
        _ newValue: Value,
        to keyPath: ReferenceWritableKeyPath<MetricsStore, Value>
    ) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
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
        publish(.unavailable(reason: reason), to: \.tps)
        publish(.unavailable, to: \.tpsState)
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
        publish(snapshot.liveRate.state, to: \.tpsState)
        publish(metric(from: snapshot.liveRate), to: \.tps)
        tpsHistory = restored.history.compactMap { sample in
            guard let value = sample.tps else { return nil }
            return TPSPoint(timestamp: sample.timestamp, tokensPerSecond: value, state: sample.state)
        }
        let sparkline = SparklineAnalysis.makeSparkline(
            from: restored.history,
            end: snapshot.timestamp
        )
        publish(sparkline, to: \.sparkline)
        modelTPSHistory = makeModelTPSHistory(from: restored.history, end: snapshot.timestamp)
        // 看板不重叠桶：用恢复的较长历史（最多 3600s）按当前跨度重算并缓存。
        dashboardSampleCache = restored.dashboardHistory
        dashboardSampleEnd = snapshot.timestamp
        recomputeDashboardSeries()
        lastRefresh = snapshot.timestamp
        isShowingCachedSnapshot = true
    }

    /// 在后台线程一次算好每秒刷新所需的全部派生曲线（总 + 分模型 ×2 套口径）。
    /// 纯计算，无 MainActor 状态依赖：`span` 与两个计算函数由调用方传入。
    private nonisolated static func deriveSeries(
        history: [LiveRateSample],
        dashboardSamples: [LiveRateSample],
        end: Date,
        span: DashboardTPSSpan,
        model: @Sendable @escaping ([LiveRateSample], Date) -> [ModelTPSHistory],
        dashboardModel: @Sendable @escaping ([LiveRateSample], Date, DashboardTPSSpan) -> [ModelTPSHistory]
    ) async -> DerivedSeries {
        await Task.detached(priority: .userInitiated) {
            let sparkline = SparklineAnalysis.makeSparkline(from: history, end: end)
            let modelHistory = model(history, end)
            let dashboardPoints: [SparklinePoint]
            let dashboardModelHistory: [ModelTPSHistory]
            if span.source == .perSecondSamples {
                dashboardPoints = SparklineAnalysis.makeBucketedDashboardSparkline(
                    from: dashboardSamples, end: end, span: span
                )
                dashboardModelHistory = dashboardModel(dashboardSamples, end, span)
            } else {
                // 1 天跨度由 coordinator 账本 series 接管，这两条置空。
                dashboardPoints = []
                dashboardModelHistory = []
            }
            return DerivedSeries(
                sparkline: sparkline,
                modelTPSHistory: modelHistory,
                dashboardSparklinePoints: dashboardPoints,
                dashboardModelTPSHistory: dashboardModelHistory
            )
        }.value
    }

    private nonisolated func makeModelTPSHistory(
        from history: [LiveRateSample],
        end: Date
    ) -> [ModelTPSHistory] {
        let models = Set(history.flatMap { sample in
            sample.modelTokensInWindow.keys
        })
        let currentModels = history.reversed().first(where: {
            $0.state == .live || $0.state == .zero
        })?.modelTokensInWindow ?? [:]
        return models.compactMap { model in
            // 图例数字（latestTPS）始终用 180s 口径，稳定且与右上角总数可加。
            let latestTokens = currentModels[model] ?? 0
            let latestTPS = latestTokens / Double(LiveRateSample.windowSeconds)
            guard latestTPS > 0 || history.contains(where: { ($0.modelTokensInWindow[model] ?? 0) > 0 }) else {
                return nil
            }
            let points = SparklineAnalysis.makeModelSparkline(from: history, model: model, end: end)
            return ModelTPSHistory(model: model, latestTPS: latestTPS, points: points)
        }
        .sorted {
            if $0.latestTPS == $1.latestTPS { return $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            return $0.latestTPS > $1.latestTPS
        }
    }

    /// 看板当前跨度切换：更新状态并用缓存样本即时重算前三档曲线（1 天由 view 改用账本 series）。
    public func setDashboardSpan(_ span: DashboardTPSSpan) {
        guard span != dashboardSpan else { return }
        dashboardSpan = span
        recomputeDashboardSeries()
    }

    /// 用缓存的较长历史按当前跨度重算看板不重叠桶曲线（总 + 分模型）。
    /// 1 天跨度不在此计算（改用 coordinator 账本 day series），这两个 @Published 置空。
    private func recomputeDashboardSeries() {
        guard dashboardSpan.source == .perSecondSamples else {
            dashboardSparklinePoints = []
            dashboardModelTPSHistory = []
            return
        }
        let samples = dashboardSampleCache
        let end = dashboardSampleEnd == Date(timeIntervalSince1970: 0) ? Date() : dashboardSampleEnd
        dashboardSparklinePoints = SparklineAnalysis.makeBucketedDashboardSparkline(
            from: samples, end: end, span: dashboardSpan
        )
        dashboardModelTPSHistory = makeDashboardModelTPSHistory(from: samples, end: end, span: dashboardSpan)
    }

    /// 看板分模型不重叠桶曲线：与总曲线同栅格；latestTPS 仍 180s 口径（图例数字不变）。
    private nonisolated func makeDashboardModelTPSHistory(
        from history: [LiveRateSample],
        end: Date,
        span: DashboardTPSSpan
    ) -> [ModelTPSHistory] {
        let models = Set(history.flatMap { $0.modelTokensInLastSecond.keys }
            .filter { !$0.isEmpty })
            .union(history.flatMap { $0.modelTokensInWindow.keys })
        let currentModels = history.reversed().first(where: {
            $0.state == .live || $0.state == .zero
        })?.modelTokensInWindow ?? [:]
        return models.compactMap { model in
            let latestTokens = currentModels[model] ?? 0
            let latestTPS = latestTokens / Double(LiveRateSample.windowSeconds)
            let points = SparklineAnalysis.makeBucketedDashboardModelSparkline(
                from: history, model: model, end: end, span: span
            )
            // 该跨度内完全无产出的模型不列（曲线全缺口且 latestTPS=0）。
            guard latestTPS > 0 || points.contains(where: { ($0.value ?? 0) > 0 }) else { return nil }
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
