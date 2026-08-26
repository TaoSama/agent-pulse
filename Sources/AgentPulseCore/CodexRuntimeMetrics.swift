import Foundation

public struct CompletedTaskMetric: Codable, Sendable, Equatable {
    public let value: Int?
    public let quality: PulseDataQuality
    public let scope: PulseScope
    public let isLowerBound: Bool

    public init(value: Int?, available: Bool) {
        if available {
            self.value = max(0, value ?? 0)
            self.quality = .partial
            self.scope = .allLocal
            self.isLowerBound = true
        } else {
            self.value = nil
            self.quality = .unavailable
            self.scope = .allLocal
            self.isLowerBound = false
        }
    }
}

public enum RuntimeTaskCategory: String, Codable, Sendable, Equatable, CaseIterable {
    case codexDesktop
    case codexCLI
    case claudeCLI
    case claudeDesktop
}

/// 单类运行时 task 的当前计数。`present` 表示该类当前是否有已打开的 task，
/// `quality` 则区分精确值、可用下界和不可用；nil 永远不会被解释成 0。
public struct RuntimeTaskCategoryMetric: Codable, Sendable, Equatable {
    public let totalTasks: Int?
    public let activeTasks: Int?
    public let present: Bool
    public let quality: PulseDataQuality

    public init(
        totalTasks: Int?,
        activeTasks: Int?,
        present: Bool,
        quality: PulseDataQuality
    ) {
        self.totalTasks = totalTasks.map { max(0, $0) }
        self.activeTasks = activeTasks.map { max(0, $0) }
        self.present = present
        self.quality = quality
    }

    public static let unavailable = RuntimeTaskCategoryMetric(
        totalTasks: nil,
        activeTasks: nil,
        present: false,
        quality: .unavailable
    )
}

public struct RuntimeTaskBreakdown: Codable, Sendable, Equatable {
    public let codexDesktop: RuntimeTaskCategoryMetric
    public let codexCLI: RuntimeTaskCategoryMetric
    public let claudeCLI: RuntimeTaskCategoryMetric
    public let claudeDesktop: RuntimeTaskCategoryMetric

    public init(
        codexDesktop: RuntimeTaskCategoryMetric,
        codexCLI: RuntimeTaskCategoryMetric,
        claudeCLI: RuntimeTaskCategoryMetric,
        claudeDesktop: RuntimeTaskCategoryMetric
    ) {
        self.codexDesktop = codexDesktop
        self.codexCLI = codexCLI
        self.claudeCLI = claudeCLI
        self.claudeDesktop = claudeDesktop
    }

    public static let unavailable = RuntimeTaskBreakdown(
        codexDesktop: .unavailable,
        codexCLI: .unavailable,
        claudeCLI: .unavailable,
        claudeDesktop: .unavailable
    )
}

/// App 唯一消费的 Codex 运行时采集结果。
public struct CodexRuntimeMetrics: Sendable, Equatable {
    public let sampledAt: Date
    public let totalTasks: Int?
    public let activeTasks: Int?
    public let taskBreakdown: RuntimeTaskBreakdown
    public let desktopActive: Int?
    public let terminalActive: Int?
    public let activeCountsArePartial: Bool
    public let completed: CompletedTaskMetric
    public let liveRate: LiveRateSample
    public let history: [LiveRateSample]
    /// 看板可选跨度用的较长历史（最多 3600s）；菜单/悬浮球仍用 history（900s）。
    public let dashboardHistory: [LiveRateSample]
    public let filesScanned: Int
    public let unreadableFiles: Int
    public let filesReusedFromCache: Int
    public let filesReadIncrementally: Int
    public let filesFullyParsed: Int
    public let diagnostics: CodexRuntimeMetricsDiagnostics
}

/// 只包含聚合计数的实时速率对账数据；不暴露路径、会话 ID、正文或凭证。
public struct CodexRuntimeMetricsDiagnostics: Sendable, Equatable {
    public let configuredRoots: Int
    public let canonicalRoots: Int
    public let discoveredJSONLFiles: Int
    public let excludedAggregateFiles: Int
    public let excludedEmptyFiles: Int
    public let excludedStaleFiles: Int
    public let duplicateFiles: Int
    public let trackedLiveFiles: Int
    public let cliFiles: Int
    public let desktopFiles: Int
    public let subagentFiles: Int
    public let unknownProviderFiles: Int
    public let parsedOutputObservations: Int
    public let cumulativeObservations: Int
    public let incrementalObservations: Int
    public let baselineObservations: Int
    public let counterResetObservations: Int
    public let duplicateMessageObservations: Int
    public let emittedTokenEvents: Int
    public let tokensBeforeDeduplication: Int
    public let tokensAfterDeduplication: Int
    public let overlapTokens180Seconds: Double
    public let activeSessions: Int
}

public struct CodexRuntimeMetricsConfiguration: Sendable, Equatable {
    public static let historyPointLimit = 900
    /// 看板曲线可选跨度最长到 1 小时，需要最近 3600 秒每秒样本（memoryHistory 已留 6h，足够）。
    /// 与 historyPointLimit（服务菜单/悬浮球 15min 曲线）分开，互不影响语义。
    public static let dashboardHistoryPointLimit = 3600
    public static let retainedSampleLimit = 21_600
    public static let retentionSeconds: TimeInterval = 6 * 60 * 60
    public static let staleAfterSeconds: TimeInterval = 5 * 60
    public static let activeTaskTimeoutSeconds: TimeInterval = 5 * 60
    public static let futureTimestampToleranceSeconds: TimeInterval = 5

    public let sessionsDirectories: [URL]
    public let automationRoots: [String]
    public let claudeSessionsDirectory: URL
    public let claudeProjectsDirectory: URL
    public let databaseURL: URL

    public init(
        sessionsDirectories: [URL],
        automationRoots: [String],
        databaseURL: URL,
        claudeSessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions", isDirectory: true)
            .resolvingSymlinksInPath(),
        claudeProjectsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .resolvingSymlinksInPath()
    ) {
        self.sessionsDirectories = sessionsDirectories
        self.automationRoots = automationRoots
        self.databaseURL = databaseURL
        self.claudeSessionsDirectory = claudeSessionsDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.claudeProjectsDirectory = claudeProjectsDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func live(fileManager: FileManager = .default) throws -> CodexRuntimeMetricsConfiguration {
        let codexHome = CodexStatusCollector.resolvedCodexHome(fileManager: fileManager)
        return CodexRuntimeMetricsConfiguration(
            sessionsDirectories: CodexStatusCollector.defaultSessionsDirectories(
                codexHome: codexHome,
                fileManager: fileManager
            ),
            automationRoots: CodexStatusCollector.defaultAutomationRoots(codexHome: codexHome),
            databaseURL: try defaultDatabaseURL(fileManager: fileManager),
            claudeSessionsDirectory: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/sessions", isDirectory: true)
                .resolvingSymlinksInPath(),
            claudeProjectsDirectory: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/projects", isDirectory: true)
                .resolvingSymlinksInPath()
        )
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PulseCollectionError.dataSourceMissing(path: "Application Support")
        }
        return applicationSupport
            .appendingPathComponent("AgentPulse", isDirectory: true)
            .appendingPathComponent("agent-pulse.sqlite", isDirectory: false)
    }
}

/// App 冷启动时可立即恢复的完整展示快照。
/// 只保存聚合数字，不保存 rollout 路径、正文、会话 ID 或 token baseline。
public struct CachedRuntimeMetricsSnapshot: SnapshotPersistable, Sendable, Equatable {
    public static let source = "runtime-display-v3"
    private static let stableID = UUID(uuidString: "A63D006E-C729-4C80-A8C1-8D36D22E6F41")!

    public let id: UUID
    public let timestamp: Date
    public let totalTasks: Int?
    public let activeTasks: Int?
    public let taskBreakdown: RuntimeTaskBreakdown
    public let desktopActive: Int?
    public let terminalActive: Int?
    public let activeCountsArePartial: Bool
    public let completed: CompletedTaskMetric
    public let liveRate: LiveRateSample
    public var sourceIdentifier: String? { Self.source }

    init(metrics: CodexRuntimeMetrics) {
        id = Self.stableID
        timestamp = metrics.sampledAt
        totalTasks = metrics.totalTasks
        activeTasks = metrics.activeTasks
        taskBreakdown = metrics.taskBreakdown
        desktopActive = metrics.desktopActive
        terminalActive = metrics.terminalActive
        activeCountsArePartial = metrics.activeCountsArePartial
        completed = metrics.completed
        liveRate = metrics.liveRate
    }
}

/// 统一完成计数、活跃状态、180 秒 TPS 与 SQLite 历史的 Core 采集器。
/// App/R2 不再各自解析 Codex rollout。
public actor CodexRuntimeMetricsCollector {
    private enum FileProvider {
        case cli
        case desktop
        case unknown
    }

    private enum TokenFileProvider {
        case codex
        case claude
    }

    private struct TrackedTokenEvent {
        let sample: TPSSample
        let sessionKey: String
    }

    private struct MessageUsage {
        let output: Int
        let lastSeen: Date
        let sequence: UInt64
    }

    private struct TokenDiagnostics {
        var parsedOutputObservations = 0
        var cumulativeObservations = 0
        var incrementalObservations = 0
        var baselineObservations = 0
        var counterResetObservations = 0
        var duplicateMessageObservations = 0
        var emittedTokenEvents = 0
        var tokensBeforeDeduplication = 0
        var tokensAfterDeduplication = 0
    }

    private struct DiscoveryDiagnostics {
        var configuredRoots = 0
        var canonicalRoots = 0
        var discoveredJSONLFiles = 0
        var excludedAggregateFiles = 0
        var excludedEmptyFiles = 0
        var excludedStaleFiles = 0
        var duplicateFiles = 0
    }

    private struct DiscoveryResult {
        let files: [URL]
        let codexDirectoryReadable: Bool
        let tokenDirectoryReadable: Bool
        let codexEnumerationFailed: Bool
        let tokenEnumerationFailed: Bool
    }

    private struct ParsedTokenLine {
        let timestamp: Date
        let tokens: Int
        let total: Int?
        let messageIdentity: String?
        let model: String?
    }

    private struct FileSignature: Equatable {
        let modifiedAt: Date?
        let createdAt: Date?
        let size: Int?
        let resourceIdentifier: String?
    }

    private struct FileSummary {
        let completedIdentities: Set<String>
        let desktopTask: SessionTaskState?
        let codexCLITask: SessionTaskState?
        let latestOutputSignal: Date?
        let tokenEvents: [TrackedTokenEvent]
    }

    private struct SessionTaskState {
        let sessionID: String
        let lifecycleStarted: Bool
        let activityAt: Date?
    }

    private struct FileCacheEntry {
        let signature: FileSignature
        let summary: FileSummary
        let lastSeen: Date
        let readOffset: UInt64
        let meta: CodexSessionMeta?
        let previousTotalOutput: Int?
        let previousOutputTimestamp: Date?
        let currentModel: String?
        /// 是否已在该文件里见过权威的 turn_context 模型；见过后不再回退 knownModelName。
        let hasSeenTurnContext: Bool
        /// 子 agent 文件首行 session_meta 的时间戳，作为「继承前缀」时间簇锚点；仅子 agent 文件有值。
        /// 子会话开头是父线程逐字节副本，这些前缀行时间戳全部紧贴 meta（同一瞬间批量灌入），
        /// 其 total_output 是父累计快照；本会话真实产出在其后一个明显时间 gap 之后才开始。
        let metaStartedAt: Date?
        /// 是否已越过继承前缀（出现第一条时间戳明显晚于 metaStartedAt 的 token）。
        /// 未越过时，前缀 token 只更新 previousTotal 基线、不产出 TPS 事件，避免把父会话累计量
        /// 在子文件里复算成重复 output（并消除该段因 model 未声明而产生的 unknown 归属）。
        let crossedInheritedPrefix: Bool
        let initializedForLiveTracking: Bool
        let messageUsage: [String: MessageUsage]
        let messageSequence: UInt64
        let tokenDiagnostics: TokenDiagnostics
        let tailGuard: Data
    }

    private struct ScanAccumulator {
        var completedIdentities = Set<String>()
        var desktopTasks: [String: SessionTaskState] = [:]
        var codexCLITasks: [String: SessionTaskState] = [:]
        var latestOutputSignal: Date?
        var filesScanned = 0
        var unreadableFiles = 0
        var tokenEvents: [TrackedTokenEvent] = []
        var filesReusedFromCache = 0
        var filesReadIncrementally = 0
        var filesFullyParsed = 0
    }

    private struct ClaudeSessionRegistry: Decodable {
        let pid: Int32
        let sessionId: String
        let kind: String?
        let entrypoint: String?
        let status: String?
    }

    /// Claude 桌面会话事件流单行的最小解码结构；仅取生命周期判定所需字段。
    private struct ClaudeDesktopRecord: Decodable {
        struct Message: Decodable {
            let role: String?
            let stopReason: String?

            private enum CodingKeys: String, CodingKey {
                case role
                case stopReason = "stop_reason"
            }
        }

        let type: String?
        let sessionId: String?
        let entrypoint: String?
        let timestamp: String?
        let message: Message?
    }

    private enum ClaudeDesktopSessionSummary {
        case unreadable
        case notDesktopSession
        case session(sessionID: String, activityAt: Date?, unfinished: Bool)
    }

    private struct ClaudeDesktopFileCacheEntry {
        let modifiedAt: Date?
        let fileSize: Int?
        let summary: ClaudeDesktopSessionSummary
    }

    private let configuration: CodexRuntimeMetricsConfiguration
    private let processScanner: any ProcessScanning
    private let canonicalSessionDirectories: [URL]
    private let canonicalClaudeProjectsDirectory: URL
    private let store: SQLiteSnapshotStore
    private var memoryHistory: [Date: LiveRateSample]
    private var restoredDisplaySnapshot: CachedRuntimeMetricsSnapshot?
    private var fileCache: [String: FileCacheEntry] = [:]
    private var lastFullSignatureCheck: Date?
    private var cachedFiles: [URL] = []
    private var lastDiscoveryAt: Date?
    private var lastScanAt: Date?
    private var liveTrackedPaths = Set<String>()
    private var tokenFileProviders: [String: TokenFileProvider] = [:]
    private var discoveryDiagnostics = DiscoveryDiagnostics()
    private var cachedCodexDirectoryReadable = false
    private var cachedTokenDirectoryReadable = false
    private var cachedCodexEnumerationFailed = false
    private var cachedTokenEnumerationFailed = false
    private var cachedClaudeDesktopMetric: RuntimeTaskCategoryMetric?
    private var lastClaudeDesktopMetricAt: Date?
    private var claudeDesktopFileCache: [String: ClaudeDesktopFileCacheEntry] = [:]
    private let fractionalISO8601: ISO8601DateFormatter
    private let basicISO8601: ISO8601DateFormatter

    public init(
        configuration: CodexRuntimeMetricsConfiguration,
        processScanner: any ProcessScanning = SystemProcessScanner()
    ) throws {
        self.configuration = configuration
        self.processScanner = processScanner
        var seenRoots = Set<String>()
        canonicalSessionDirectories = configuration.sessionsDirectories.compactMap { root in
            guard root.standardizedFileURL.lastPathComponent != "archived_sessions" else { return nil }
            let canonical = root.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.lastPathComponent != "archived_sessions" else { return nil }
            return seenRoots.insert(canonical.path).inserted ? canonical : nil
        }
        canonicalClaudeProjectsDirectory = configuration.claudeProjectsDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let parent = configuration.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        store = try SQLiteSnapshotStore(path: configuration.databaseURL.path)

        let restored = try store.query(LiveRateSample.self, source: "live-rate")
        memoryHistory = Dictionary(uniqueKeysWithValues: restored.suffix(Self.retainedLimit).map {
            ($0.timestamp, $0)
        })
        restoredDisplaySnapshot = try store.query(
            CachedRuntimeMetricsSnapshot.self,
            source: CachedRuntimeMetricsSnapshot.source
        ).last

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        fractionalISO8601 = fractional
        basicISO8601 = ISO8601DateFormatter()
    }

    public func scan(at requestedDate: Date = Date()) throws -> CodexRuntimeMetrics {
        let sampledAt = Date(timeIntervalSince1970: floor(requestedDate.timeIntervalSince1970))
        let window = TPSWindow(now: { sampledAt })
        var accumulator = ScanAccumulator()
        var codexDirectoryReadable = false
        var tokenDirectoryReadable = false
        var codexEnumerationFailed = false
        var tokenEnumerationFailed = false
        let forceFullSignatureCheck = lastFullSignatureCheck.map {
            sampledAt.timeIntervalSince($0) >= Self.fullReconcileInterval
        } ?? true
        let discoveryDue = lastDiscoveryAt.map {
            sampledAt.timeIntervalSince($0) >= Self.discoveryInterval
        } ?? true
        let observationGap = lastScanAt.map {
            sampledAt.timeIntervalSince($0) > TPSWindow.windowSeconds
        } ?? false
        lastScanAt = sampledAt
        let files: [URL]
        if discoveryDue {
            let discovery = discoverFiles(at: sampledAt)
            cachedFiles = discovery.files
            codexDirectoryReadable = discovery.codexDirectoryReadable
            tokenDirectoryReadable = discovery.tokenDirectoryReadable
            codexEnumerationFailed = discovery.codexEnumerationFailed
            tokenEnumerationFailed = discovery.tokenEnumerationFailed
            cachedCodexDirectoryReadable = codexDirectoryReadable
            cachedTokenDirectoryReadable = tokenDirectoryReadable
            cachedCodexEnumerationFailed = codexEnumerationFailed
            cachedTokenEnumerationFailed = tokenEnumerationFailed
            lastDiscoveryAt = sampledAt
            let retainedPaths = Set(cachedFiles.map(\.path))
            fileCache = fileCache.filter { retainedPaths.contains($0.key) }
            files = cachedFiles
        } else {
            files = cachedFiles
            codexDirectoryReadable = cachedCodexDirectoryReadable
            tokenDirectoryReadable = cachedTokenDirectoryReadable
            codexEnumerationFailed = cachedCodexEnumerationFailed
            tokenEnumerationFailed = cachedTokenEnumerationFailed
        }
        for file in files {
            scan(
                file: file,
                now: sampledAt,
                forceSignatureCheck: forceFullSignatureCheck,
                allowIncrementalRead: !observationGap,
                accumulator: &accumulator
            )
        }
        _ = window.record(contentsOf: accumulator.tokenEvents.map(\.sample), referenceDate: sampledAt)
        if forceFullSignatureCheck { lastFullSignatureCheck = sampledAt }

        let desktopMetric: RuntimeTaskCategoryMetric
        let codexCLIMetric: RuntimeTaskCategoryMetric
        let claudeCLIMetric: RuntimeTaskCategoryMetric
        let claudeDesktopMetric: RuntimeTaskCategoryMetric
        let processScanFailed: Bool
        let desktopTotal = accumulator.desktopTasks.count
        let desktopActive = activeSessionCount(in: accumulator.desktopTasks, now: sampledAt)
        if codexDirectoryReadable {
            desktopMetric = RuntimeTaskCategoryMetric(
                totalTasks: desktopTotal,
                activeTasks: desktopActive,
                present: desktopTotal > 0,
                quality: accumulator.unreadableFiles > 0 || codexEnumerationFailed ? .partial : .complete
            )
        } else {
            desktopMetric = .unavailable
        }
        do {
            let processes = try processScanner.scan()
            let codexProcesses = processes.filter {
                CodexProcessClassifier.isCodexCLI(executablePath: $0.executablePath)
            }
            let claudeProcesses = processes.filter {
                CodexProcessClassifier.isClaudeCLI(executablePath: $0.executablePath)
            }
            let claudeDesktopRunning = processes.contains {
                CodexProcessClassifier.isClaudeDesktopApp(executablePath: $0.executablePath)
            }
            if codexProcesses.isEmpty {
                codexCLIMetric = RuntimeTaskCategoryMetric(
                    totalTasks: 0,
                    activeTasks: 0,
                    present: false,
                    quality: .complete
                )
            } else if codexDirectoryReadable {
                codexCLIMetric = RuntimeTaskCategoryMetric(
                    totalTasks: codexProcesses.count,
                    activeTasks: min(
                        codexProcesses.count,
                        activeSessionCount(in: accumulator.codexCLITasks, now: sampledAt)
                    ),
                    present: true,
                    quality: accumulator.unreadableFiles > 0 || codexEnumerationFailed ? .partial : .complete
                )
            } else {
                codexCLIMetric = RuntimeTaskCategoryMetric(
                    totalTasks: codexProcesses.count,
                    activeTasks: nil,
                    present: true,
                    quality: .partial
                )
            }
            claudeCLIMetric = scanClaudeSessions(for: claudeProcesses)
            claudeDesktopMetric = scanClaudeDesktopSessions(
                desktopRunning: claudeDesktopRunning,
                now: sampledAt
            )
            processScanFailed = false
        } catch {
            codexCLIMetric = .unavailable
            claudeCLIMetric = .unavailable
            claudeDesktopMetric = .unavailable
            processScanFailed = true
        }
        let breakdown = RuntimeTaskBreakdown(
            codexDesktop: desktopMetric,
            codexCLI: codexCLIMetric,
            claudeCLI: claudeCLIMetric,
            claudeDesktop: claudeDesktopMetric
        )
        let totalTasks = sumAvailable([
            desktopMetric.totalTasks,
            codexCLIMetric.totalTasks,
            claudeCLIMetric.totalTasks,
            claudeDesktopMetric.totalTasks,
        ])
        let activeTasks = sumAvailable([
            desktopMetric.activeTasks,
            codexCLIMetric.activeTasks,
            claudeCLIMetric.activeTasks,
            claudeDesktopMetric.activeTasks,
        ])
        let terminalActive = sumAvailable([
            codexCLIMetric.activeTasks,
            claudeCLIMetric.activeTasks,
        ])

        let sourceAvailable = tokenDirectoryReadable && !tokenEnumerationFailed
        let overlapTokens = window.tokensInWindow(referenceDate: sampledAt)
        let modelTokens = window.tokensInWindowByModel(referenceDate: sampledAt)
        // 看板 5s 滑窗曲线：额外取该时刻前 5 秒的真实 output（总 + 分模型），存入样本供曲线逐点绘制。
        let shortWindow = Double(LiveRateSample.shortWindowSeconds)
        let shortTokens = window.tokensInShortWindow(referenceDate: sampledAt, windowSeconds: shortWindow)
        let shortModelTokens = window.tokensInShortWindowByModel(referenceDate: sampledAt, windowSeconds: shortWindow)
        // 看板不重叠桶曲线：额外取该 1 秒的逐秒净增量（总 + 分模型），严格 (t-1, t] 窗口、
        // 右边界不含未来容差，相邻秒不重叠，可按桶求和不重复计。与 5s 重叠口径分开存。
        let lastSecondTokens = window.tokensInLastSecond(referenceDate: sampledAt)
        let lastSecondModelTokens = window.tokensInLastSecondByModel(referenceDate: sampledAt)
        let liveRate = makeLiveRateSample(
            at: sampledAt,
            sourceAvailable: sourceAvailable,
            latestSignalAt: accumulator.latestOutputSignal,
            tokensInWindow: overlapTokens,
            modelTokensInWindow: modelTokens,
            tokensInShortWindow: shortTokens,
            modelTokensInShortWindow: shortModelTokens,
            tokensInLastSecond: lastSecondTokens,
            modelTokensInLastSecond: lastSecondModelTokens
        )
        try persistLiveRate(liveRate)
        let metrics = CodexRuntimeMetrics(
            sampledAt: sampledAt,
            totalTasks: totalTasks,
            activeTasks: activeTasks,
            taskBreakdown: breakdown,
            desktopActive: desktopMetric.activeTasks,
            terminalActive: terminalActive,
            activeCountsArePartial: processScanFailed
                || [desktopMetric, codexCLIMetric, claudeCLIMetric, claudeDesktopMetric]
                .contains(where: { $0.quality != .complete }),
            completed: CompletedTaskMetric(
                value: accumulator.completedIdentities.count,
                available: codexDirectoryReadable
            ),
            liveRate: liveRate,
            history: recentHistory(at: sampledAt),
            dashboardHistory: dashboardHistory(at: sampledAt),
            filesScanned: accumulator.filesScanned,
            unreadableFiles: accumulator.unreadableFiles,
            filesReusedFromCache: accumulator.filesReusedFromCache,
            filesReadIncrementally: accumulator.filesReadIncrementally,
            filesFullyParsed: accumulator.filesFullyParsed,
            diagnostics: makeDiagnostics(
                accumulator: accumulator,
                overlapTokens: overlapTokens,
                referenceDate: sampledAt
            )
        )
        try persistDisplaySnapshot(metrics, now: sampledAt)
        return metrics
    }

    /// 不触发 rollout 扫描，立即返回 SQLite 中上次完整展示快照和 TPS 历史。
    /// history 为菜单/悬浮球用的 900s；dashboardHistory 为看板可选跨度用的 3600s。
    public func restoredDisplayState() -> (
        snapshot: CachedRuntimeMetricsSnapshot?,
        history: [LiveRateSample],
        dashboardHistory: [LiveRateSample]
    ) {
        let end = restoredDisplaySnapshot?.timestamp ?? Date()
        return (restoredDisplaySnapshot, recentHistory(at: end), dashboardHistory(at: end))
    }

    private func sumAvailable(_ values: [Int?]) -> Int? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, saturatingAdd)
    }

    /// Claude Code 为每个已打开的 CLI task 写一份仅含运行元数据的 PID registry。
    /// 这里仅解码 pid/sessionId/kind/entrypoint/status，不读取项目正文或对话内容。
    private func scanClaudeSessions(
        for processes: [RunningProcess]
    ) -> RuntimeTaskCategoryMetric {
        guard !processes.isEmpty else {
            return RuntimeTaskCategoryMetric(
                totalTasks: 0,
                activeTasks: 0,
                present: false,
                quality: .complete
            )
        }
        let livePIDs = Set(processes.map(\.pid))
        let directory = configuration.claudeSessionsDirectory
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: directory.path) else {
            return RuntimeTaskCategoryMetric(
                totalTasks: nil,
                activeTasks: nil,
                present: true,
                quality: .unavailable
            )
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return RuntimeTaskCategoryMetric(
                totalTasks: nil,
                activeTasks: nil,
                present: true,
                quality: .unavailable
            )
        }

        var sessionIDs = Set<String>()
        var busySessionIDs = Set<String>()
        var degraded = false
        let decoder = JSONDecoder()
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let filenamePID = Int32(file.deletingPathExtension().lastPathComponent),
                  livePIDs.contains(filenamePID) else {
                continue
            }
            do {
                let registry = try decoder.decode(ClaudeSessionRegistry.self, from: Data(contentsOf: file))
                guard registry.pid == filenamePID,
                      registry.kind?.lowercased() == "interactive",
                      registry.entrypoint?.lowercased() == "cli",
                      !registry.sessionId.isEmpty else {
                    degraded = true
                    continue
                }
                sessionIDs.insert(registry.sessionId)
                if registry.status?.lowercased() == "busy" {
                    busySessionIDs.insert(registry.sessionId)
                }
            } catch {
                degraded = true
            }
        }
        return RuntimeTaskCategoryMetric(
            totalTasks: sessionIDs.count,
            activeTasks: busySessionIDs.intersection(sessionIDs).count,
            present: true,
            quality: degraded ? .partial : .complete
        )
    }

    /// Claude 桌面版为每个对话在 ~/.claude/projects/<slug>/<sessionId>.jsonl 追加事件流。
    /// total = 顶层（非 subagents）JSONL 中 entrypoint == "claude-desktop-3p" 的 distinct sessionId；
    /// active = 最近活动在超时窗口内、且尾部处于“仍在生成/等待模型”的会话
    ///         （最新 assistant 的 stop_reason 非 end_turn，或最新一条 user 之后无 assistant 回复）。
    /// 仅解析生命周期所需的最小字段（type / message.role / stop_reason / timestamp / entrypoint / sessionId），
    /// 不读取正文以外的对话内容。Claude.app 主进程未运行时返回 closed(0/0, present=false)。
    private func scanClaudeDesktopSessions(
        desktopRunning: Bool,
        now: Date
    ) -> RuntimeTaskCategoryMetric {
        guard desktopRunning else {
            let closed = RuntimeTaskCategoryMetric(
                totalTasks: 0,
                activeTasks: 0,
                present: false,
                quality: .complete
            )
            cachedClaudeDesktopMetric = closed
            lastClaudeDesktopMetricAt = now
            return closed
        }
        if let cachedClaudeDesktopMetric,
           let lastClaudeDesktopMetricAt,
           now.timeIntervalSince(lastClaudeDesktopMetricAt) >= 0,
           now.timeIntervalSince(lastClaudeDesktopMetricAt) < Self.discoveryInterval {
            return cachedClaudeDesktopMetric
        }
        let metric = computeClaudeDesktopSessions(now: now)
        cachedClaudeDesktopMetric = metric
        lastClaudeDesktopMetricAt = now
        return metric
    }

    private func computeClaudeDesktopSessions(now: Date) -> RuntimeTaskCategoryMetric {
        let directory = canonicalClaudeProjectsDirectory
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: directory.path) else {
            return RuntimeTaskCategoryMetric(
                totalTasks: nil,
                activeTasks: nil,
                present: true,
                quality: .unavailable
            )
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return RuntimeTaskCategoryMetric(
                totalTasks: nil,
                activeTasks: nil,
                present: true,
                quality: .unavailable
            )
        }

        var sessionIDs = Set<String>()
        var activeSessionIDs = Set<String>()
        var seenPaths = Set<String>()
        var degraded = false
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "jsonl" else { continue }
            // 只统计顶层会话文件，排除 subagents/workflows 派生轨迹。
            let standardized = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard !standardized.pathComponents.contains("subagents") else { continue }
            seenPaths.insert(standardized.path)
            let values = try? standardized.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let summary: ClaudeDesktopSessionSummary
            if let cached = claudeDesktopFileCache[standardized.path],
               cached.modifiedAt == values?.contentModificationDate,
               cached.fileSize == values?.fileSize {
                summary = cached.summary
            } else {
                summary = summarizeClaudeDesktopSession(at: standardized, now: now)
                claudeDesktopFileCache[standardized.path] = ClaudeDesktopFileCacheEntry(
                    modifiedAt: values?.contentModificationDate,
                    fileSize: values?.fileSize,
                    summary: summary
                )
            }
            switch summary {
            case .unreadable:
                degraded = true
            case .notDesktopSession:
                continue
            case let .session(sessionID, activityAt, unfinished):
                sessionIDs.insert(sessionID)
                if unfinished, let activityAt {
                    let age = now.timeIntervalSince(activityAt)
                    if age >= -Self.futureTimestampTolerance && age <= Self.activeTaskTimeout {
                        activeSessionIDs.insert(sessionID)
                    }
                }
            }
        }
        claudeDesktopFileCache = claudeDesktopFileCache.filter { seenPaths.contains($0.key) }
        return RuntimeTaskCategoryMetric(
            totalTasks: sessionIDs.count,
            activeTasks: activeSessionIDs.intersection(sessionIDs).count,
            present: true,
            quality: degraded ? .partial : .complete
        )
    }

    /// 单条会话文件的最小解析：判定是否为 claude-desktop-3p 顶层会话，并推断当前是否活跃。
    private func summarizeClaudeDesktopSession(at url: URL, now: Date) -> ClaudeDesktopSessionSummary {
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            return .unreadable
        }
        let decoder = JSONDecoder()
        var sessionID: String?
        var isDesktopSession = false
        var latestActivity: Date?
        // 尾部会话状态：最后一条“消息”是 user（无后续 assistant）视为进行中；
        // 最后一条 assistant 的 stop_reason == end_turn 视为已结束，否则视为进行中。
        var lastMessageRole: String?
        var lastAssistantEndTurn = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            guard let record = try? decoder.decode(ClaudeDesktopRecord.self, from: data) else { continue }
            if let id = record.sessionId, sessionID == nil { sessionID = id }
            if record.entrypoint == "claude-desktop-3p" { isDesktopSession = true }
            guard let type = record.type, type == "user" || type == "assistant" else { continue }
            if let ts = record.timestamp, let parsed = parseTimestamp(ts) {
                if latestActivity.map({ parsed > $0 }) ?? true { latestActivity = parsed }
            }
            lastMessageRole = record.message?.role ?? type
            if type == "assistant" {
                lastAssistantEndTurn = record.message?.stopReason == "end_turn"
            }
        }
        guard isDesktopSession, let resolvedID = sessionID else {
            return .notDesktopSession
        }
        // 尾部“仍在进行”：最后一条是 user（模型尚未回复），或最后一条 assistant 未以 end_turn 收尾。
        let unfinishedTail: Bool
        if lastMessageRole == "user" {
            unfinishedTail = true
        } else if lastMessageRole == "assistant" {
            unfinishedTail = !lastAssistantEndTurn
        } else {
            unfinishedTail = false
        }
        return .session(sessionID: resolvedID, activityAt: latestActivity, unfinished: unfinishedTail)
    }

    private func discoverFiles(at now: Date) -> DiscoveryResult {
        struct Candidate {
            let url: URL
            let modifiedAt: Date
        }

        var diagnostics = DiscoveryDiagnostics()
        diagnostics.configuredRoots = configuration.sessionsDirectories.count
        diagnostics.canonicalRoots = canonicalSessionDirectories.count
        diagnostics.duplicateFiles = max(0, diagnostics.configuredRoots - diagnostics.canonicalRoots)

        var codexDirectoryReadable = false
        var claudeDirectoryReadable = false
        var codexEnumerationFailed = false
        var claudeEnumerationFailed = false
        var seenPaths = Set<String>()
        var completedMetricFiles: [String: URL] = [:]
        var candidates: [Candidate] = []
        let fileManager = FileManager.default

        func enumerate(
            directory: URL,
            provider: TokenFileProvider,
            includesCodexCompleted: Bool
        ) -> (readable: Bool, failed: Bool) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  fileManager.isReadableFile(atPath: directory.path) else {
                return (false, false)
            }
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                return (true, true)
            }
            for case let discoveredURL as URL in enumerator {
                guard discoveredURL.pathExtension.lowercased() == "jsonl" else { continue }
                diagnostics.discoveredJSONLFiles += 1
                let canonicalURL = discoveredURL.resolvingSymlinksInPath().standardizedFileURL
                guard seenPaths.insert(canonicalURL.path).inserted else {
                    diagnostics.duplicateFiles += 1
                    continue
                }
                tokenFileProviders[canonicalURL.path] = provider
                if includesCodexCompleted, canonicalURL.lastPathComponent.hasPrefix("rollout-") {
                    completedMetricFiles[canonicalURL.path] = canonicalURL
                }
                guard shouldTrackLiveJSONL(canonicalURL) else {
                    diagnostics.excludedAggregateFiles += 1
                    continue
                }
                guard !liveTrackedPaths.contains(canonicalURL.path) else { continue }
                guard let attributes = try? fileManager.attributesOfItem(atPath: canonicalURL.path),
                      let size = (attributes[.size] as? NSNumber)?.intValue,
                      let modifiedAt = attributes[.modificationDate] as? Date else {
                    continue
                }
                guard size > 0 else {
                    diagnostics.excludedEmptyFiles += 1
                    continue
                }
                guard now.timeIntervalSince(modifiedAt) <= Self.recentFileInterval else {
                    diagnostics.excludedStaleFiles += 1
                    continue
                }
                candidates.append(Candidate(url: canonicalURL, modifiedAt: modifiedAt))
            }
            return (true, false)
        }

        for directory in canonicalSessionDirectories {
            let result = enumerate(
                directory: directory,
                provider: .codex,
                includesCodexCompleted: true
            )
            codexDirectoryReadable = codexDirectoryReadable || result.readable
            codexEnumerationFailed = codexEnumerationFailed || result.failed
        }
        let claudeResult = enumerate(
            directory: canonicalClaudeProjectsDirectory,
            provider: .claude,
            includesCodexCompleted: false
        )
        claudeDirectoryReadable = claudeResult.readable
        claudeEnumerationFailed = claudeResult.failed

        let expiredTrackedPaths = liveTrackedPaths.filter { path in
            guard fileManager.fileExists(atPath: path), let cached = fileCache[path] else { return true }
            return now.timeIntervalSince(cached.lastSeen) > Self.trackedFileRetention
        }
        liveTrackedPaths.subtract(expiredTrackedPaths)
        candidates.sort { left, right in
            if left.modifiedAt == right.modifiedAt { return left.url.path < right.url.path }
            return left.modifiedAt > right.modifiedAt
        }
        for candidate in candidates where liveTrackedPaths.count < Self.maximumTrackedFiles {
            liveTrackedPaths.insert(candidate.url.path)
        }

        var filesByPath = completedMetricFiles
        for path in liveTrackedPaths {
            filesByPath[path] = URL(fileURLWithPath: path)
        }
        tokenFileProviders = tokenFileProviders.filter { filesByPath[$0.key] != nil }
        discoveryDiagnostics = diagnostics
        let tokenDirectoryReadable = codexDirectoryReadable || claudeDirectoryReadable
        let tokenEnumerationFailed = (codexDirectoryReadable ? codexEnumerationFailed : true)
            && (claudeDirectoryReadable ? claudeEnumerationFailed : true)
        return DiscoveryResult(
            files: filesByPath.values.sorted { $0.path < $1.path },
            codexDirectoryReadable: codexDirectoryReadable,
            tokenDirectoryReadable: tokenDirectoryReadable,
            codexEnumerationFailed: codexEnumerationFailed,
            tokenEnumerationFailed: tokenEnumerationFailed
        )
    }

    private func scan(
        file: URL,
        now: Date,
        forceSignatureCheck: Bool,
        allowIncrementalRead: Bool,
        accumulator: inout ScanAccumulator
    ) {
        if let cached = fileCache[file.path],
           !liveTrackedPaths.contains(file.path),
           !forceSignatureCheck,
           cached.summary.desktopTask?.lifecycleStarted != true,
           cached.summary.codexCLITask?.lifecycleStarted != true,
           cached.signature.modifiedAt.map({ now.timeIntervalSince($0) > Self.recentFileInterval }) == true {
            accumulator.filesReusedFromCache += 1
            apply(cached.summary, now: now, accumulator: &accumulator)
            return
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        } catch {
            accumulator.unreadableFiles += 1
            return
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let resourceIdentifier: String? = if let device, let inode {
            "\(device):\(inode)"
        } else {
            nil
        }
        let signature = FileSignature(
            modifiedAt: attributes[.modificationDate] as? Date,
            createdAt: attributes[.creationDate] as? Date,
            size: (attributes[.size] as? NSNumber)?.intValue,
            resourceIdentifier: resourceIdentifier
        )
        if let cached = fileCache[file.path], cached.signature == signature {
            accumulator.filesReusedFromCache += 1
            apply(cached.summary, now: now, accumulator: &accumulator)
            return
        }
        if allowIncrementalRead, let cached = fileCache[file.path],
           cached.initializedForLiveTracking || !liveTrackedPaths.contains(file.path),
           canReadIncrementally(from: cached, to: signature),
           let updated = updateIncrementally(file: file, cached: cached, signature: signature, now: now) {
            accumulator.filesReadIncrementally += 1
            fileCache[file.path] = updated
            apply(updated.summary, now: now, accumulator: &accumulator)
            return
        }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: file, options: [.mappedIfSafe])
        } catch {
            accumulator.unreadableFiles += 1
            return
        }
        accumulator.filesFullyParsed += 1
        let completeLength = completeLineLength(in: fileData)
        guard let contents = String(data: fileData.prefix(completeLength), encoding: .utf8) else {
            accumulator.unreadableFiles += 1
            return
        }
        let isCodexFile: Bool = switch tokenFileProviders[file.path] {
        case .claude: false
        case .codex, nil: true
        }
        let meta = isCodexFile
            ? contents.split(whereSeparator: { $0.isNewline }).first.flatMap {
                CodexSessionParser.parseSessionMeta(line: String($0))
            }
            : nil
        // 子 agent 文件才需要继承前缀锚点：取首行 session_meta 的时间戳作为时间簇基准。
        // 顶层文件 metaStartedAt 为 nil，crossedInheritedPrefix 恒 true（不做任何前缀跳过）。
        let isSubagentFile = meta?.threadSource == "subagent"
        let metaStartedAt: Date? = isSubagentFile
            ? contents.split(whereSeparator: { $0.isNewline }).first.flatMap { sessionMetaTimestamp(String($0)) }
            : nil
        var crossedInheritedPrefix = (metaStartedAt == nil)
        let completed = meta.map { _ in
            CodexSessionParser.completedTasks(
                inSessionContents: contents,
                automationRoots: configuration.automationRoots
            )
        } ?? .empty
        let source = meta.flatMap { CodexSessionParser.source(forOriginator: $0.originator) }
        let lifecycleStarted = CodexSessionParser.lastLifecycle(inSessionContents: contents) == .started
        var previousTotal: Int?
        var previousTimestamp: Date?
        var currentModel: String?
        var hasSeenTurnContext = false
        var latestOutputSignal: Date?
        var messageUsage: [String: MessageUsage] = [:]
        var messageSequence: UInt64 = 0
        var tokenDiagnostics = TokenDiagnostics()
        // 会话级 model 播种无条件执行（不受 live-track 门禁）：Codex 的 turn_context 全生命周期
        // 只在文件顶部出现一次，其后正文再无 model 声明。若首解析时文件未 live-tracked 就跳过播种，
        // cache 里 currentModel 会一直是 nil；待该文件晋升 live-tracked 走增量路径时，增量预播种只回看
        // 当前追加批次（顶部 turn_context 早已消费），永远拿不到 model → 整段 output 归 "unknown"。
        // 首解析即无条件播种、存入 cache，可让 model 成为会话级粘性值，杜绝这条 nil 竞态。
        if let contextModel = latestTurnContextModel(in: fileData) {
            currentModel = contextModel
            hasSeenTurnContext = true
        } else {
            currentModel = latestKnownModel(in: fileData)
        }
        if liveTrackedPaths.contains(file.path) {
            let baseline = baselineData(from: fileData)
            for line in completeLines(in: baseline.data, skippingLeadingPartialLine: baseline.skipsLeadingPartialLine) {
                if let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                    if let model = turnContextModel(object) {
                        currentModel = model
                        hasSeenTurnContext = true
                    } else if !hasSeenTurnContext, let model = knownModelName(object) {
                        currentModel = model
                    }
                }
                guard let parsed = parseTokenLine(line, now: now) else { continue }
                tokenDiagnostics.parsedOutputObservations += 1
                tokenDiagnostics.baselineObservations += 1
                // 子 agent 继承前缀跟踪：一旦某条 token 时间戳越过 meta 时间簇，标记已越过。
                // baseline 分支本就只建 previousTotal 基线、不产出事件，所以前缀在 baseline 里天然不入账；
                // 此处推进 crossedInheritedPrefix 只为把越过状态存入 cache，供后续增量路径判定。
                if !crossedInheritedPrefix, let anchor = metaStartedAt,
                   parsed.timestamp.timeIntervalSince(anchor) >= Self.inheritedPrefixClusterTolerance {
                    crossedInheritedPrefix = true
                }
                if let total = parsed.total {
                    tokenDiagnostics.cumulativeObservations += 1
                    previousTotal = total
                    previousTimestamp = parsed.timestamp
                    latestOutputSignal = laterSignal(
                        latestOutputSignal,
                        normalizedSignalTime(parsed.timestamp, now: now)
                    )
                } else {
                    tokenDiagnostics.incrementalObservations += 1
                    latestOutputSignal = laterSignal(
                        latestOutputSignal,
                        normalizedSignalTime(parsed.timestamp, now: now)
                    )
                    guard let identity = parsed.messageIdentity else { continue }
                    messageSequence &+= 1
                    let existing = messageUsage[identity]
                    messageUsage[identity] = MessageUsage(
                        output: max(existing?.output ?? 0, parsed.tokens),
                        lastSeen: now,
                        sequence: messageSequence
                    )
                }
            }
            pruneMessageUsage(&messageUsage, now: now)
        }

        let taskActivityAt = [signature.modifiedAt, latestOutputSignal].compactMap { $0 }.max()
        let isNonAutomationTopLevel = meta.map { meta in
            meta.isTopLevel && meta.cwd.map {
                !CodexSessionParser.isUnderAutomation(
                    cwd: $0,
                    automationRoots: configuration.automationRoots
                )
            } == true
        } ?? false
        let desktopTask: SessionTaskState? = if let meta, source == .desktop, isNonAutomationTopLevel {
            SessionTaskState(
                sessionID: meta.sessionID,
                lifecycleStarted: lifecycleStarted,
                activityAt: taskActivityAt
            )
        } else {
            nil
        }
        let codexCLITask: SessionTaskState? = if let meta, source == .cli, meta.isTopLevel {
            SessionTaskState(
                sessionID: meta.sessionID,
                lifecycleStarted: lifecycleStarted,
                activityAt: taskActivityAt
            )
        } else {
            nil
        }
        let summary = FileSummary(
            completedIdentities: completed.identities,
            desktopTask: desktopTask,
            codexCLITask: codexCLITask,
            latestOutputSignal: latestOutputSignal,
            tokenEvents: []
        )
        fileCache[file.path] = FileCacheEntry(
            signature: signature,
            summary: summary,
            lastSeen: now,
            readOffset: UInt64(fileData.count),
            meta: meta,
            previousTotalOutput: previousTotal,
            previousOutputTimestamp: previousTimestamp,
            currentModel: currentModel,
            hasSeenTurnContext: hasSeenTurnContext,
            metaStartedAt: metaStartedAt,
            crossedInheritedPrefix: crossedInheritedPrefix,
            initializedForLiveTracking: liveTrackedPaths.contains(file.path),
            messageUsage: messageUsage,
            messageSequence: messageSequence,
            tokenDiagnostics: tokenDiagnostics,
            tailGuard: tailGuard(for: fileData)
        )
        apply(summary, now: now, accumulator: &accumulator)
    }

    private func canReadIncrementally(from cached: FileCacheEntry, to signature: FileSignature) -> Bool {
        guard cached.signature.resourceIdentifier == signature.resourceIdentifier,
              cached.signature.createdAt == signature.createdAt,
              let oldSize = cached.signature.size,
              let newSize = signature.size else {
            return false
        }
        let appendedBytes = newSize - Int(cached.readOffset)
        return newSize > oldSize
            && appendedBytes >= 0
            && appendedBytes <= Self.maximumAppendReadBytes
    }

    private func updateIncrementally(
        file: URL,
        cached: FileCacheEntry,
        signature: FileSignature,
        now: Date
    ) -> FileCacheEntry? {
        let appendedData: Data
        do {
            let handle = try FileHandle(forReadingFrom: file)
            guard cached.readOffset >= UInt64(cached.tailGuard.count) else { return nil }
            let guardOffset = cached.readOffset - UInt64(cached.tailGuard.count)
            try handle.seek(toOffset: guardOffset)
            let guardedAppend = try handle.readToEnd() ?? Data()
            try handle.close()
            guard guardedAppend.starts(with: cached.tailGuard) else { return nil }
            appendedData = Data(guardedAppend.dropFirst(cached.tailGuard.count))
        } catch {
            return nil
        }

        let completeLength = completeLineLength(in: appendedData)
        guard completeLength > 0 else {
            return FileCacheEntry(
                signature: cached.signature,
                summary: cached.summary,
                lastSeen: now,
                readOffset: cached.readOffset,
                meta: cached.meta,
                previousTotalOutput: cached.previousTotalOutput,
                previousOutputTimestamp: cached.previousOutputTimestamp,
                currentModel: cached.currentModel,
                hasSeenTurnContext: cached.hasSeenTurnContext,
                metaStartedAt: cached.metaStartedAt,
                crossedInheritedPrefix: cached.crossedInheritedPrefix,
                initializedForLiveTracking: cached.initializedForLiveTracking,
                messageUsage: cached.messageUsage,
                messageSequence: cached.messageSequence,
                tokenDiagnostics: cached.tokenDiagnostics,
                tailGuard: cached.tailGuard
            )
        }
        guard let text = String(data: appendedData.prefix(completeLength), encoding: .utf8) else {
            return nil
        }

        var completedIdentities = cached.summary.completedIdentities
        var lifecycleStarted = cached.summary.desktopTask?.lifecycleStarted
            ?? cached.summary.codexCLITask?.lifecycleStarted
            ?? false
        var latestOutputSignal = cached.summary.latestOutputSignal
        var tokenEvents = cached.summary.tokenEvents.filter {
            eventCanOverlapWindow($0.sample, referenceDate: now)
        }
        var previousTotal = cached.previousTotalOutput
        var previousTimestamp = cached.previousOutputTimestamp
        var currentModel = cached.currentModel
        var hasSeenTurnContext = cached.hasSeenTurnContext
        // 前瞻 seed：冷启动时 codex 先写 session_meta + 前几个 token_count，turn_context 稍后才
        // append，导致首次全量解析把 currentModel 播种成 nil。若本批次里 turn_context 排在若干
        // token_count 之后，这些更早的 token_count 逐行处理时 currentModel 仍是 nil，会被归成
        // "unknown"。这里在逐行循环前，对本批次已裁好的完整行（≤512KB，仅本文件）反查一次权威
        // turn_context model，让批次内早于 turn_context 的行也能拿到 model。仅在 currentModel 为
        // nil 时触发，稳态零开销；per-file 数据反查，不会跨会话误判。
        if currentModel == nil {
            let batch = Data(appendedData.prefix(completeLength))
            if let seeded = latestTurnContextModel(in: batch) {
                currentModel = seeded
                hasSeenTurnContext = true
            }
        }
        var messageUsage = cached.messageUsage
        var messageSequence = cached.messageSequence
        // 子 agent 继承前缀状态从 cache 恢复：未越过前缀时，前缀 token 只更新 previousTotal 基线、
        // 不产出事件，避免复算父会话累计量（并消除该段的 unknown 归属）。顶层文件 metaStartedAt 为 nil、
        // crossedInheritedPrefix 恒 true，走原逻辑不受影响。
        let metaStartedAt = cached.metaStartedAt
        var crossedInheritedPrefix = cached.crossedInheritedPrefix
        // 内容指纹去重，只作用于「无 message id 的增量（incremental）路径」——主要是 Claude CLI
        // 中缺 message.id 的逐条 usage 行：同一次真实 output 会被重复刷新成多条除时间戳外逐字节相同
        // 的行，不去重会按刷新条数重复累加（实测约 2x）。指纹取 model + token 增量（不含时间戳，避免
        // fork 改写时间戳绕过折叠），同指纹只计一次。
        // 注意：codex token_count 行恒带 total_token_usage，永远走下方 cumulative 差分分支（靠文件级
        // previousTotal 天然去重），不经过这里；此指纹对 codex 恒不命中，仅为 incremental 源兜底。
        var seenIncrementalFingerprints = Set<String>()
        var tokenDiagnostics = cached.tokenDiagnostics
        let source: PulseSource = switch tokenFileProviders[file.path] {
        case .claude: .cli
        case .codex, nil:
            cached.meta.flatMap { CodexSessionParser.source(forOriginator: $0.originator) } ?? .cli
        }
        let isInteractive = cached.meta.map { meta in
            meta.isTopLevel && meta.cwd.map {
                !CodexSessionParser.isUnderAutomation(cwd: $0, automationRoots: configuration.automationRoots)
            } == true
        } ?? false

        for (lineIndex, rawLine) in text.split(whereSeparator: { $0.isNewline }).enumerated() {
            let line = String(rawLine)
            if let data = line.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                // 权威 turn 模型只从 turn_context 事件取；仅当从未见过 turn_context
                // 时才回退到宽松的 knownModelName，避免被非权威 model 字段污染。
                if let model = turnContextModel(object) {
                    currentModel = model
                    hasSeenTurnContext = true
                } else if !hasSeenTurnContext, let model = knownModelName(object) {
                    currentModel = model
                }
            }
            if let data = line.data(using: .utf8),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               (object["type"] as? String) == "event_msg",
               let payload = object["payload"] as? [String: Any],
               let eventType = payload["type"] as? String,
               let meta = cached.meta {
                if meta.isTopLevel {
                    switch eventType {
                    case "task_started":
                        lifecycleStarted = true
                    case "task_complete", "turn_aborted":
                        lifecycleStarted = false
                    default:
                        break
                    }
                }
                if eventType == "task_complete", isInteractive {
                    if let turnID = payload["turn_id"] as? String, !turnID.isEmpty {
                        completedIdentities.insert(meta.sessionID + "\u{0}" + turnID)
                    } else {
                        completedIdentities.insert(
                            meta.sessionID + CodexSessionParser.missingTurnMarker
                                + "\(cached.readOffset)-\(lineIndex)"
                        )
                    }
                }
            }

            guard liveTrackedPaths.contains(file.path),
                  let parsed = parseTokenLine(Data(line.utf8), now: now) else { continue }
            tokenDiagnostics.parsedOutputObservations += 1
            // 子 agent 继承前缀：时间戳仍在 meta 时间簇内的 token 属于父线程副本，不产出 TPS 事件。
            // 但仍推进 previousTotal/previousTimestamp 基线，使越过前缀后的第一条真实产出从继承末值
            // 起差分（而非从 0 暴涨）；越过一次后 crossedInheritedPrefix 恒 true，本会话产出正常入账。
            if !crossedInheritedPrefix, let anchor = metaStartedAt {
                if parsed.timestamp.timeIntervalSince(anchor) >= Self.inheritedPrefixClusterTolerance {
                    crossedInheritedPrefix = true
                } else {
                    if let total = parsed.total {
                        previousTotal = total
                        previousTimestamp = parsed.timestamp
                    }
                    continue
                }
            }
            var emittedTokens = 0
            if let total = parsed.total {
                tokenDiagnostics.cumulativeObservations += 1
                latestOutputSignal = laterSignal(
                    latestOutputSignal,
                    normalizedSignalTime(parsed.timestamp, now: now)
                )
                if let previousTotal, let previousTimestamp {
                    if total > previousTotal {
                        emittedTokens = safePositiveDifference(total, previousTotal)
                        tokenDiagnostics.tokensBeforeDeduplication = saturatingAdd(
                            tokenDiagnostics.tokensBeforeDeduplication,
                            emittedTokens
                        )
                        tokenEvents.append(TrackedTokenEvent(
                            sample: intervalSample(
                                start: previousTimestamp,
                                end: parsed.timestamp,
                                tokens: emittedTokens,
                                source: source,
                                model: parsed.model ?? currentModel
                            ),
                            sessionKey: file.path
                        ))
                    } else if total < previousTotal {
                        tokenDiagnostics.counterResetObservations += 1
                    }
                }
                previousTotal = total
                previousTimestamp = parsed.timestamp
            } else {
                tokenDiagnostics.incrementalObservations += 1
                latestOutputSignal = laterSignal(
                    latestOutputSignal,
                    normalizedSignalTime(parsed.timestamp, now: now)
                )
                tokenDiagnostics.tokensBeforeDeduplication = saturatingAdd(
                    tokenDiagnostics.tokensBeforeDeduplication,
                    parsed.tokens
                )
                emittedTokens = parsed.tokens
                if let identity = parsed.messageIdentity {
                    let previous = messageUsage[identity]
                    if let previous {
                        emittedTokens = max(0, parsed.tokens - previous.output)
                        if emittedTokens != parsed.tokens {
                            tokenDiagnostics.duplicateMessageObservations += 1
                        }
                    }
                    messageSequence &+= 1
                    messageUsage[identity] = MessageUsage(
                        output: max(parsed.tokens, previous?.output ?? 0),
                        lastSeen: now,
                        sequence: messageSequence
                    )
                } else {
                    // 无 message id：按内容指纹去重（model + token 增量，不含时间戳）。
                    // 同一 turn 重复刷新的 token_count 行内容相同 → 指纹相同 → 只计首条。
                    let fingerprint = "\(parsed.model ?? currentModel ?? "unknown")\u{1}\(parsed.tokens)"
                    if seenIncrementalFingerprints.contains(fingerprint) {
                        emittedTokens = 0
                        tokenDiagnostics.duplicateMessageObservations += 1
                    } else {
                        seenIncrementalFingerprints.insert(fingerprint)
                    }
                }
                if emittedTokens > 0 {
                    tokenEvents.append(TrackedTokenEvent(
                        sample: TPSSample(
                            timestamp: parsed.timestamp,
                            tokenCount: emittedTokens,
                            durationSeconds: 0,
                            source: source,
                            model: parsed.model ?? currentModel
                        ),
                        sessionKey: file.path
                    ))
                }
            }
            if emittedTokens > 0 {
                tokenDiagnostics.emittedTokenEvents += 1
                tokenDiagnostics.tokensAfterDeduplication = saturatingAdd(
                    tokenDiagnostics.tokensAfterDeduplication,
                    emittedTokens
                )
            }
        }
        pruneMessageUsage(&messageUsage, now: now)

        var newGuardData = cached.tailGuard
        newGuardData.append(contentsOf: appendedData.prefix(completeLength))
        let newReadOffset = cached.readOffset + UInt64(completeLength)
        let consumedSignature = FileSignature(
            modifiedAt: signature.modifiedAt,
            createdAt: signature.createdAt,
            size: Int(newReadOffset),
            resourceIdentifier: signature.resourceIdentifier
        )
        let taskActivityAt = [signature.modifiedAt, latestOutputSignal].compactMap { $0 }.max()
        let desktopTask: SessionTaskState? = if let meta = cached.meta,
                             source == .desktop,
                             isInteractive {
            SessionTaskState(
                sessionID: meta.sessionID,
                lifecycleStarted: lifecycleStarted,
                activityAt: taskActivityAt
            )
        } else {
            nil
        }
        let codexCLITask: SessionTaskState? = if let meta = cached.meta,
                              source == .cli,
                              meta.isTopLevel {
            SessionTaskState(
                sessionID: meta.sessionID,
                lifecycleStarted: lifecycleStarted,
                activityAt: taskActivityAt
            )
        } else {
            nil
        }
        return FileCacheEntry(
            signature: consumedSignature,
            summary: FileSummary(
                completedIdentities: completedIdentities,
                desktopTask: desktopTask,
                codexCLITask: codexCLITask,
                latestOutputSignal: latestOutputSignal,
                tokenEvents: tokenEvents
            ),
            lastSeen: now,
            readOffset: newReadOffset,
            meta: cached.meta,
            previousTotalOutput: previousTotal,
            previousOutputTimestamp: previousTimestamp,
            currentModel: currentModel,
            hasSeenTurnContext: hasSeenTurnContext,
            metaStartedAt: metaStartedAt,
            crossedInheritedPrefix: crossedInheritedPrefix,
            initializedForLiveTracking: true,
            messageUsage: messageUsage,
            messageSequence: messageSequence,
            tokenDiagnostics: tokenDiagnostics,
            tailGuard: tailGuard(for: newGuardData)
        )
    }

    private func completeLineLength(in data: Data) -> Int {
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: data.index(after: lastNewline))
    }

    private func tailGuard<D: DataProtocol>(for data: D) -> Data {
        Data(data.suffix(64))
    }

    private func baselineData(from data: Data) -> (data: Data, skipsLeadingPartialLine: Bool) {
        guard data.count > Self.maximumAppendReadBytes else { return (data, false) }
        return (Data(data.suffix(Self.maximumAppendReadBytes)), true)
    }

    private func completeLines(in data: Data, skippingLeadingPartialLine: Bool) -> [Data] {
        var readable = data
        if skippingLeadingPartialLine {
            guard let firstNewline = readable.firstIndex(of: 0x0A) else { return [] }
            readable = Data(readable[readable.index(after: firstNewline)...])
        }
        return readable.split(whereSeparator: { $0 == 0x0A }).map { Data($0) }
    }

    private func parseTokenLine(_ line: Data, now: Date) -> ParsedTokenLine? {
        let lowercased = String(decoding: line, as: UTF8.self).lowercased()
        guard lowercased.contains("token") || lowercased.contains("usage"),
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        let timestamp = parsedTimestamp(from: object, fallback: now)
        let total = recursiveTotalOutputTokens(object)
        let messageIdentity = parsedMessageIdentity(object)
        let model = knownModelName(object)
        if let tokens = knownUsageTokens(object) ?? recursiveUsageTokens(object) {
            return ParsedTokenLine(
                timestamp: timestamp,
                tokens: tokens,
                total: total,
                messageIdentity: messageIdentity,
                model: model
            )
        }
        guard let total else { return nil }
        return ParsedTokenLine(timestamp: timestamp, tokens: 0, total: total, messageIdentity: nil, model: model)
    }

    private func knownModelName(_ object: [String: Any]) -> String? {
        let payload = object["payload"] as? [String: Any]
        let threadSettings = payload?["thread_settings"] as? [String: Any]
        let candidates: [Any?] = [
            object["model"],
            payload?["model"],
            threadSettings?["model"],
            (object["message"] as? [String: Any])?["model"],
            (payload?["message"] as? [String: Any])?["model"],
        ]
        for candidate in candidates {
            guard let raw = candidate as? String else { continue }
            let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty { return model }
        }
        return nil
    }

    /// Codex rollout 里每一个 turn 的权威模型来自 `turn_context` 事件的 `payload.model`；
    /// `token_count` 事件本身不带 model。只从 turn_context 取模型可避免被
    /// session_meta / message / reasoning 等行的其它 model 字段污染成错误归属。
    private func turnContextModel(_ object: [String: Any]) -> String? {
        guard (object["type"] as? String) == "turn_context",
              let payload = object["payload"] as? [String: Any],
              let raw = payload["model"] as? String else { return nil }
        let model = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? nil : model
    }

    /// baseline 预读阶段确定“最近一次 turn 的模型”。优先反向扫描 `turn_context`
    /// 事件的权威模型；只有在整段数据里都找不到 turn_context 时，才回退到
    /// 宽松的 `knownModelName`，保证不丢模型也不误判成 Other。
    private func latestKnownModel(in data: Data) -> String? {
        if let contextModel = latestTurnContextModel(in: data) { return contextModel }
        var searchEnd = data.endIndex
        let needle = Data("\"model\"".utf8)
        while searchEnd > data.startIndex,
              let match = data[data.startIndex..<searchEnd].range(of: needle, options: .backwards) {
            let lineStart = data[data.startIndex..<match.lowerBound].lastIndex(of: 0x0A)
                .map { data.index(after: $0) } ?? data.startIndex
            let lineEnd = data[match.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
            if let object = (try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd])) as? [String: Any],
               let model = knownModelName(object) {
                return model
            }
            searchEnd = match.lowerBound
        }
        return nil
    }

    private func latestTurnContextModel(in data: Data) -> String? {
        var searchEnd = data.endIndex
        let needle = Data("turn_context".utf8)
        while searchEnd > data.startIndex,
              let match = data[data.startIndex..<searchEnd].range(of: needle, options: .backwards) {
            let lineStart = data[data.startIndex..<match.lowerBound].lastIndex(of: 0x0A)
                .map { data.index(after: $0) } ?? data.startIndex
            let lineEnd = data[match.upperBound..<data.endIndex].firstIndex(of: 0x0A) ?? data.endIndex
            if let object = (try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd])) as? [String: Any],
               let model = turnContextModel(object) {
                return model
            }
            searchEnd = match.lowerBound
        }
        return nil
    }

    private func knownUsageTokens(_ object: [String: Any]) -> Int? {
        if let payload = object["payload"] as? [String: Any] {
            if let info = payload["info"] as? [String: Any] {
                if let usage = info["last_token_usage"] as? [String: Any],
                   let tokens = outputTokens(usage) { return tokens }
                if let usage = info["total_token_usage"] as? [String: Any],
                   let tokens = outputTokens(usage) { return tokens }
            }
            if let usage = payload["usage"] as? [String: Any],
               let tokens = outputTokens(usage) { return tokens }
        }
        if let usage = object["usage"] as? [String: Any],
           let tokens = outputTokens(usage) { return tokens }
        if let message = object["message"] as? [String: Any],
           let usage = message["usage"] as? [String: Any],
           let tokens = outputTokens(usage) { return tokens }
        return outputTokens(object)
    }

    private func recursiveUsageTokens(_ value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            if let tokens = outputTokens(dictionary) { return tokens }
            for child in dictionary.values {
                if let tokens = recursiveUsageTokens(child) { return tokens }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let tokens = recursiveUsageTokens(child) { return tokens }
            }
        }
        return nil
    }

    private func recursiveTotalOutputTokens(_ value: Any) -> Int? {
        if let dictionary = value as? [String: Any] {
            if let tokens = totalOutputTokens(dictionary) { return tokens }
            if let payload = dictionary["payload"] as? [String: Any],
               let info = payload["info"] as? [String: Any],
               let usage = info["total_token_usage"] as? [String: Any],
               let tokens = outputTokens(usage) { return tokens }
            for child in dictionary.values {
                if let tokens = recursiveTotalOutputTokens(child) { return tokens }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let tokens = recursiveTotalOutputTokens(child) { return tokens }
            }
        }
        return nil
    }

    private func outputTokens(_ dictionary: [String: Any]) -> Int? {
        for key in ["output_tokens", "outputTokens", "completion_tokens", "completionTokens"] {
            if dictionary.keys.contains(key) {
                return max(0, integerValue(dictionary[key]) ?? 0)
            }
        }
        return nil
    }

    private func totalOutputTokens(_ dictionary: [String: Any]) -> Int? {
        for key in ["total_output_tokens", "totalOutputTokens"] where dictionary.keys.contains(key) {
            return max(0, integerValue(dictionary[key]) ?? 0)
        }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let decimal = number.doubleValue
            guard decimal.isFinite else { return nil }
            if decimal >= Double(Int.max) { return Int.max }
            if decimal <= Double(Int.min) { return Int.min }
            return Int(decimal)
        }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    private func parsedMessageIdentity(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        var messageID = (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if messageID.isEmpty {
            messageID = (object["uuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !messageID.isEmpty else { return nil }
        var sessionID = ""
        for key in ["sessionId", "session_id"] {
            let candidate = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !candidate.isEmpty {
                sessionID = candidate
                break
            }
        }
        return sessionID + "\u{0}" + messageID
    }

    private func parsedTimestamp(from object: [String: Any], fallback: Date) -> Date {
        for key in ["timestamp", "ts", "created_at", "createdAt"] {
            if let parsed = parseTimestampValue(object[key]) { return parsed }
        }
        return fallback
    }

    private func parseTimestampValue(_ value: Any?) -> Date? {
        if let value = value as? String {
            return parseTimestamp(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard let integer = integerValue(value), integer > 0 else { return nil }
        if integer > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: Double(integer) / 1_000)
        }
        return Date(timeIntervalSince1970: Double(integer))
    }

    private func normalizedSignalTime(_ timestamp: Date, now: Date) -> Date {
        timestamp > now.addingTimeInterval(Self.futureTimestampTolerance) ? now : timestamp
    }

    private func laterSignal(_ current: Date?, _ candidate: Date) -> Date {
        max(current ?? candidate, candidate)
    }

    private func intervalSample(
        start: Date,
        end: Date,
        tokens: Int,
        source: PulseSource,
        model: String? = nil
    ) -> TPSSample {
        let intervalStart = min(start, end)
        let intervalEnd = max(start, end)
        return TPSSample(
            timestamp: intervalEnd,
            tokenCount: tokens,
            durationSeconds: intervalEnd.timeIntervalSince(intervalStart),
            source: source,
            model: model
        )
    }

    private func eventCanOverlapWindow(_ sample: TPSSample, referenceDate: Date) -> Bool {
        let cutoff = referenceDate.addingTimeInterval(-TPSWindow.windowSeconds)
        let start = sample.timestamp.addingTimeInterval(-sample.durationSeconds)
        return sample.tokenCount > 0
            && sample.timestamp >= cutoff
            && start <= referenceDate.addingTimeInterval(Self.futureTimestampTolerance)
    }

    private func pruneMessageUsage(_ usage: inout [String: MessageUsage], now: Date) {
        usage = usage.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.messageRetention }
        guard usage.count > Self.maximumMessageIdentities else { return }
        let sorted = usage.sorted { left, right in
            if left.value.lastSeen == right.value.lastSeen {
                if left.value.sequence == right.value.sequence { return left.key < right.key }
                return left.value.sequence < right.value.sequence
            }
            return left.value.lastSeen < right.value.lastSeen
        }
        for entry in sorted.prefix(usage.count - Self.maximumMessageIdentities) {
            usage[entry.key] = nil
        }
    }

    private func shouldTrackLiveJSONL(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        guard name.hasSuffix(".jsonl") else { return false }
        // 排除 Claude 子会话转录（subagents/*.jsonl）：子会话把父响应以不同 message.id / 文件路径
        // 重新落盘，跨文件无法按 message 身份折叠，会把同一次真实 output 重复计入实时 TPS
        // （实测把速率放大到约 3 倍）。与任务计数扫描（discoverFiles 中排除 subagents）口径对齐，
        // 只统计顶层会话文件。
        guard !url.resolvingSymlinksInPath().standardizedFileURL
            .pathComponents.contains("subagents") else { return false }
        return !["summary", "aggregate", "snapshot", "live-rate", "live_rate"].contains {
            name.contains($0)
        }
    }

    private func saturatingAdd(_ left: Int, _ right: Int) -> Int {
        let (sum, overflow) = left.addingReportingOverflow(right)
        return overflow ? (right >= 0 ? Int.max : Int.min) : sum
    }

    private func apply(
        _ summary: FileSummary,
        now: Date,
        accumulator: inout ScanAccumulator
    ) {
        accumulator.filesScanned += 1
        accumulator.completedIdentities.formUnion(summary.completedIdentities)
        merge(summary.desktopTask, into: &accumulator.desktopTasks)
        merge(summary.codexCLITask, into: &accumulator.codexCLITasks)
        if let signal = summary.latestOutputSignal {
            accumulator.latestOutputSignal = max(accumulator.latestOutputSignal ?? signal, signal)
        }
        accumulator.tokenEvents.append(contentsOf: summary.tokenEvents)
    }

    private func merge(
        _ state: SessionTaskState?,
        into tasks: inout [String: SessionTaskState]
    ) {
        guard let state else { return }
        guard let existing = tasks[state.sessionID] else {
            tasks[state.sessionID] = state
            return
        }
        switch (existing.activityAt, state.activityAt) {
        case let (old?, new?) where new >= old:
            tasks[state.sessionID] = state
        case (nil, _?):
            tasks[state.sessionID] = state
        case (nil, nil):
            tasks[state.sessionID] = state
        default:
            break
        }
    }

    private func activeSessionCount(in tasks: [String: SessionTaskState], now: Date) -> Int {
        // active = 会话最近 activeTaskTimeout(5 分钟)内仍有活动(rollout 写入或 output token 信号)。
        // 不再要求最后生命周期为 task_started:正在生成回复的会话尾部常是上一轮的 task_complete,
        // 之后跟着仍在产出的 output 流,activityAt(= max(mtime, latestOutputSignal))会持续刷新到最近时刻,
        // 是比刚性生命周期更可靠的活跃信号。彻底结束、之后无 output 的会话其 activityAt 停在结束时刻,
        // 超过窗口自然被排除。
        tasks.values.lazy.filter { state in
            guard let activityAt = state.activityAt else { return false }
            let age = now.timeIntervalSince(activityAt)
            return age >= -Self.futureTimestampTolerance && age <= Self.activeTaskTimeout
        }.count
    }

    private func makeDiagnostics(
        accumulator: ScanAccumulator,
        overlapTokens: Double,
        referenceDate: Date
    ) -> CodexRuntimeMetricsDiagnostics {
        var cliFiles = 0
        var desktopFiles = 0
        var subagentFiles = 0
        var unknownProviderFiles = 0
        var totals = TokenDiagnostics()
        for path in liveTrackedPaths {
            guard let cached = fileCache[path] else { continue }
            if cached.meta?.threadSource == "subagent" {
                subagentFiles += 1
            } else {
                switch cached.meta.flatMap({ CodexSessionParser.source(forOriginator: $0.originator) }) {
                case .cli: cliFiles += 1
                case .desktop: desktopFiles += 1
                case nil: unknownProviderFiles += 1
                }
            }
            let diagnostics = cached.tokenDiagnostics
            totals.parsedOutputObservations += diagnostics.parsedOutputObservations
            totals.cumulativeObservations += diagnostics.cumulativeObservations
            totals.incrementalObservations += diagnostics.incrementalObservations
            totals.baselineObservations += diagnostics.baselineObservations
            totals.counterResetObservations += diagnostics.counterResetObservations
            totals.duplicateMessageObservations += diagnostics.duplicateMessageObservations
            totals.emittedTokenEvents += diagnostics.emittedTokenEvents
            totals.tokensBeforeDeduplication = saturatingAdd(
                totals.tokensBeforeDeduplication,
                diagnostics.tokensBeforeDeduplication
            )
            totals.tokensAfterDeduplication = saturatingAdd(
                totals.tokensAfterDeduplication,
                diagnostics.tokensAfterDeduplication
            )
        }
        let activeSessions = Set(accumulator.tokenEvents.compactMap { event in
            TPSWindow.includedTokens(for: event.sample, referenceDate: referenceDate) > 0
                ? event.sessionKey
                : nil
        }).count
        return CodexRuntimeMetricsDiagnostics(
            configuredRoots: discoveryDiagnostics.configuredRoots,
            canonicalRoots: discoveryDiagnostics.canonicalRoots,
            discoveredJSONLFiles: discoveryDiagnostics.discoveredJSONLFiles,
            excludedAggregateFiles: discoveryDiagnostics.excludedAggregateFiles,
            excludedEmptyFiles: discoveryDiagnostics.excludedEmptyFiles,
            excludedStaleFiles: discoveryDiagnostics.excludedStaleFiles,
            duplicateFiles: discoveryDiagnostics.duplicateFiles,
            trackedLiveFiles: liveTrackedPaths.count,
            cliFiles: cliFiles,
            desktopFiles: desktopFiles,
            subagentFiles: subagentFiles,
            unknownProviderFiles: unknownProviderFiles,
            parsedOutputObservations: totals.parsedOutputObservations,
            cumulativeObservations: totals.cumulativeObservations,
            incrementalObservations: totals.incrementalObservations,
            baselineObservations: totals.baselineObservations,
            counterResetObservations: totals.counterResetObservations,
            duplicateMessageObservations: totals.duplicateMessageObservations,
            emittedTokenEvents: totals.emittedTokenEvents,
            tokensBeforeDeduplication: totals.tokensBeforeDeduplication,
            tokensAfterDeduplication: totals.tokensAfterDeduplication,
            overlapTokens180Seconds: overlapTokens,
            activeSessions: activeSessions
        )
    }

    private func makeLiveRateSample(
        at timestamp: Date,
        sourceAvailable: Bool,
        latestSignalAt: Date?,
        tokensInWindow: Double,
        modelTokensInWindow: [String: Double] = [:],
        tokensInShortWindow: Double = 0,
        modelTokensInShortWindow: [String: Double] = [:],
        tokensInLastSecond: Double = 0,
        modelTokensInLastSecond: [String: Double] = [:]
    ) -> LiveRateSample {
        guard sourceAvailable else {
            return LiveRateSample(
                timestamp: timestamp,
                state: .unavailable,
                tokensInWindow: nil,
                latestSignalAt: latestSignalAt
            )
        }
        guard let latestSignalAt else {
            return LiveRateSample(
                timestamp: timestamp,
                state: .noData,
                tokensInWindow: nil,
                latestSignalAt: nil
            )
        }
        guard timestamp.timeIntervalSince(latestSignalAt) <= Self.staleAfter else {
            return LiveRateSample(
                timestamp: timestamp,
                state: .stale,
                tokensInWindow: nil,
                latestSignalAt: latestSignalAt
            )
        }
        let state: LiveRateState = tokensInWindow > 0 ? .live : .zero
        return LiveRateSample(
            timestamp: timestamp,
            state: state,
            tokensInWindow: tokensInWindow,
            latestSignalAt: latestSignalAt,
            modelTokensInWindow: modelTokensInWindow,
            tokensInShortWindow: tokensInShortWindow,
            modelTokensInShortWindow: modelTokensInShortWindow,
            tokensInLastSecond: tokensInLastSecond,
            modelTokensInLastSecond: modelTokensInLastSecond
        )
    }

    private func persistLiveRate(_ sample: LiveRateSample) throws {
        try store.upsert(sample)
        memoryHistory[sample.timestamp] = sample
    }

    private func persistDisplaySnapshot(_ metrics: CodexRuntimeMetrics, now: Date) throws {
        let displaySnapshot = CachedRuntimeMetricsSnapshot(metrics: metrics)
        try store.upsert(displaySnapshot)
        restoredDisplaySnapshot = displaySnapshot

        let cutoff = now.addingTimeInterval(-CodexRuntimeMetricsConfiguration.retentionSeconds)
        _ = try store.deleteSnapshots(olderThan: cutoff)
        _ = try store.enforceRetention(maxCount: Self.retainedLimit)
        memoryHistory = memoryHistory.filter { $0.key >= cutoff }
        if memoryHistory.count > Self.retainedLimit {
            for key in memoryHistory.keys.sorted().dropLast(Self.retainedLimit) {
                memoryHistory[key] = nil
            }
        }
    }

    private func recentHistory(at now: Date) -> [LiveRateSample] {
        historySlice(at: now, pointLimit: CodexRuntimeMetricsConfiguration.historyPointLimit)
    }

    /// 看板专用较长历史（最多 3600 秒），供 1 小时及以内跨度的不重叠桶曲线截取。
    /// 不改 recentHistory（900s，服务菜单/悬浮球 15min 曲线）。
    private func dashboardHistory(at now: Date) -> [LiveRateSample] {
        historySlice(at: now, pointLimit: CodexRuntimeMetricsConfiguration.dashboardHistoryPointLimit)
    }

    private func historySlice(at now: Date, pointLimit: Int) -> [LiveRateSample] {
        let cutoff = now.addingTimeInterval(-Double(pointLimit - 1))
        return memoryHistory.values
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(pointLimit)
            .map { $0 }
    }

    private func parseTimestamp(_ value: String) -> Date? {
        fractionalISO8601.date(from: value) ?? basicISO8601.date(from: value)
    }

    /// 从 session_meta 首行 JSON 提取时间戳（顶层 "timestamp" 字段），作为子 agent 继承前缀的时间簇锚点。
    /// 解析失败返回 nil（此时不启用前缀跳过，退回原行为）。
    private func sessionMetaTimestamp(_ line: String) -> Date? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["timestamp"] as? String else { return nil }
        return parseTimestamp(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func safePositiveDifference(_ current: Int, _ previous: Int) -> Int {
        let (difference, overflow) = current.subtractingReportingOverflow(previous)
        if overflow { return Int.max }
        return max(0, difference)
    }

    private static let retainedLimit = CodexRuntimeMetricsConfiguration.retainedSampleLimit
    private static let staleAfter = CodexRuntimeMetricsConfiguration.staleAfterSeconds
    private static let activeTaskTimeout = CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds
    private static let recentFileInterval: TimeInterval = 15 * 60
    private static let discoveryInterval: TimeInterval = 10
    private static let fullReconcileInterval: TimeInterval = 5 * 60
    private static let trackedFileRetention: TimeInterval = 30 * 60
    private static let messageRetention: TimeInterval = 10 * 60
    private static let futureTimestampTolerance = CodexRuntimeMetricsConfiguration.futureTimestampToleranceSeconds
    /// 子 agent「继承前缀」时间簇容差：token 时间戳与首行 session_meta 之差在此以内视为仍在
    /// 继承前缀（父线程逐字节副本，同一瞬间批量灌入）。实测继承段全部紧贴 meta（<1s），
    /// 本会话真实产出在其后 17-37s 的大 gap 之后，2s 阈值有充足安全边际。
    private static let inheritedPrefixClusterTolerance: TimeInterval = 2
    private static let maximumAppendReadBytes = 512 * 1024
    private static let maximumTrackedFiles = 96
    private static let maximumMessageIdentities = 2_048
}
