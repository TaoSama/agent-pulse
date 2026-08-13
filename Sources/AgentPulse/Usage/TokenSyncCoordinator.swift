import Combine
import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage

/// 维护本地长期采集、普通上报开关和状态展示，并串起完整生产链：
/// 扫描（record 原始 token + session 事件）→ 按需 rebuild → finalizeDerived → summary →
/// 上报资格门禁 → 可选普通上报。
///
/// canonical hostname 以 0600 reporting.json 配置为“上报权威”，每次刷新时读取；
/// 配置缺失仍允许纯本地采集（用用户保存的本地 hostname），但绝不 fallback 到
/// Host.current / local。配置就绪时，本地 hostname 必须与配置权威对齐，否则重建或明确阻止。
///
/// 未开启上报、未配置 API 地址，或本地 reporting.json 缺失时，不会创建网络
/// 请求，也不会启动取 token 的外部进程。
@MainActor
final class TokenSyncCoordinator: TokenSyncCoordinating {
    private enum DefaultsKey {
        static let localCollectionEnabled = "tokenSync.localCollectionEnabled"
        static let reportingEnabled = "tokenSync.reportingEnabled"
        static let ingestBaseURL = "tokenSync.ingestBaseURL"
        static let canonicalHostname = "tokenSync.canonicalHostname"
    }

    private let defaults: UserDefaults
    private let ledger: UsageLedgerStore?
    private let configurationURL: URL
    private let reporter: TokenUsageReporter

    /// 扫描 / 上报任务句柄，用于防重入与 stop 取消。
    private var scanTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    /// 每次启动 scan/report 时递增；对应任务完成回调只有在其 generation 仍是
    /// 当前值时才更新句柄，避免旧任务取消后完成回调覆盖新任务句柄的竞态。
    private var scanGeneration: UInt64 = 0
    private var reportGeneration: UInt64 = 0
    /// 当自动上报在已有扫描期间被触发时，记住“扫描结束后上报”的意图。
    /// 关闭上报或 stop() 会清空，避免过期动作越过用户当前设置。
    private var reportAfterCurrentScan = false
    /// 自动上报循环任务；nil 表示当前未启动或已停止。
    private var autoLoopTask: Task<Void, Never>?
    /// 应用生命周期：start() 后置 true；stop() 置 false 后阻止后续自动动作。
    private var isRunning: Bool = false

    private let summarySubject: CurrentValueSubject<TokenUsageSummary, Never>
    private let statusSubject: CurrentValueSubject<TokenSyncStatus, Never>

    var summary: TokenUsageSummary { summarySubject.value }
    var status: TokenSyncStatus { statusSubject.value }

    var summaryPublisher: AnyPublisher<TokenUsageSummary, Never> {
        summarySubject.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<TokenSyncStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    /// 自动上报循环周期：启动时执行首轮，之后每 30 分钟触发一次。
    /// 关闭上报开关 / stop() 时立即取消。
    private static let autoReportInterval: TimeInterval = 30 * 60

    init(
        defaults: UserDefaults = .standard,
        configurationURL: URL = TokenSyncCoordinator.defaultConfigurationURL(),
        reporter: TokenUsageReporter = TokenUsageReporter()
    ) {
        self.defaults = defaults
        self.configurationURL = configurationURL
        self.reporter = reporter
        ledger = Self.openLedger()

        // 从 DB 立即恢复 summary（同步读取，后续异步刷新）。
        let initialSummary: TokenUsageSummary
        if let ledger, let dbSummary = try? ledger.summary() {
            initialSummary = Self.summary(from: dbSummary)
        } else {
            initialSummary = .empty
        }
        summarySubject = CurrentValueSubject(initialSummary)

        let localCollection = defaults.object(forKey: DefaultsKey.localCollectionEnabled) as? Bool ?? true
        let storedReporting = defaults.object(forKey: DefaultsKey.reportingEnabled) as? Bool ?? false
        let baseURL = defaults.string(forKey: DefaultsKey.ingestBaseURL) ?? ""
        let storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")

        // 配置权威：以 reporting.json 的 canonical hostname 为准；配置未就绪时为空。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        // 上报所用 hostname 权威优先；否则回落到用户保存的本地 hostname（仅用于本地采集）。
        let effectiveHostname = authority.hostname.isEmpty ? storedHostname : authority.hostname
        let canReport = !baseURL.isEmpty && !effectiveHostname.isEmpty && authority.status == .ready
        let reporting = canReport ? storedReporting : false
        if storedReporting && !canReport {
            // 配置已失效时持久化关闭，避免配置日后恢复后自动“复活”上报。
            defaults.set(false, forKey: DefaultsKey.reportingEnabled)
        }

        let eligible = ledger.flatMap { (try? $0.reportingEligible(hostname: effectiveHostname)) } ?? true
        let pending = ledger.flatMap { (try? $0.pendingCounts(hostname: effectiveHostname)) } ?? (0, 0)

        statusSubject = CurrentValueSubject(TokenSyncStatus(
            localCollectionEnabled: localCollection,
            reportingEnabled: reporting,
            ingestBaseURL: baseURL,
            canonicalHostname: effectiveHostname.isEmpty ? nil : effectiveHostname,
            lastScanAt: nil,
            lastReportAt: nil,
            configurationStatus: Self.presentationStatus(authority.status),
            configurationError: authority.errorText,
            scanningInProgress: false,
            reportingInProgress: false,
            reportingError: nil,
            reportingEligible: eligible,
            reportingBlockedReasons: [],
            pendingBuckets: pending.0,
            pendingSessions: pending.1,
            lastReportSucceeded: nil,
            fullSyncState: .blocked,
            fullSyncBlockReasons: ["全量同步需要完整且可恢复的远端协议配置"]
        ))
    }

    // MARK: - Settings

    func setLocalCollectionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.localCollectionEnabled)
        updateStatus { $0.localCollectionEnabled = enabled }
    }

    func setReportingEnabled(_ enabled: Bool) {
        // 关闭永远成功：无论配置状态如何都写盘 false，并停掉自动上报循环。
        // 用户手动在途的 report 不取消（可能还想看结果）；scan 同理不动。
        guard enabled else {
            defaults.set(false, forKey: DefaultsKey.reportingEnabled)
            autoLoopTask?.cancel()
            autoLoopTask = nil
            reportAfterCurrentScan = false
            updateStatus { status in
                status.reportingEnabled = false
                status.reportingError = nil
            }
            return
        }
        // 开启需要配置就绪。
        refreshConfigurationAuthority()
        let current = statusSubject.value
        guard !current.ingestBaseURL.isEmpty,
              current.canonicalHostname != nil,
              current.configurationStatus == .ready else {
            updateStatus { status in
                status.reportingEnabled = false
                status.reportingError = "配置未就绪，无法启用上报"
            }
            defaults.set(false, forKey: DefaultsKey.reportingEnabled)
            autoLoopTask?.cancel()
            autoLoopTask = nil
            return
        }
        defaults.set(true, forKey: DefaultsKey.reportingEnabled)
        updateStatus { status in
            status.reportingEnabled = true
            status.reportingError = nil
        }
        // 立即触发一轮：若本地采集开启则先扫描再上报；否则直接上报当前 pending。
        if current.localCollectionEnabled {
            triggerScanThenReport()
        } else {
            reportNow()
        }
        // 启动 30 分钟自动循环；已在跑则不重启。
        startAutoLoopIfNeeded()
    }

    func setIngestBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: DefaultsKey.ingestBaseURL)
        var stopAutoLoop = false
        updateStatus { status in
            status.ingestBaseURL = trimmed
            status.reportingError = nil
            if trimmed.isEmpty || status.canonicalHostname == nil {
                if status.reportingEnabled { stopAutoLoop = true }
                status.reportingEnabled = false
                self.defaults.set(false, forKey: DefaultsKey.reportingEnabled)
            }
        }
        if stopAutoLoop {
            autoLoopTask?.cancel()
            autoLoopTask = nil
        }
    }

    /// 保存用户 hostname：仅用于“配置权威缺失时”的本地采集标识；
    /// 若配置就绪，则以配置为权威（保存值不会覆盖权威）。
    func setCanonicalHostname(_ hostname: String) {
        let trimmed = Self.normalize(hostname)
        defaults.set(trimmed, forKey: DefaultsKey.canonicalHostname)
        refreshConfigurationAuthority()
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        // 配置就绪时权威优先；否则采用用户保存值。
        let effective = authority.hostname.isEmpty ? trimmed : authority.hostname
        var stopAutoLoop = false
        updateStatus { status in
            status.canonicalHostname = effective.isEmpty ? nil : effective
            status.reportingError = nil
            if effective.isEmpty || status.ingestBaseURL.isEmpty {
                if status.reportingEnabled { stopAutoLoop = true }
                status.reportingEnabled = false
                self.defaults.set(false, forKey: DefaultsKey.reportingEnabled)
            }
        }
        if stopAutoLoop {
            autoLoopTask?.cancel()
            autoLoopTask = nil
        }
    }

    // MARK: - Scan (production chain)

    func scanNow() {
        scanNow(chainedReport: false)
    }

    /// 触发扫描；chainedReport=true 则扫描成功后串接一次上报（无论开关变化，
    /// 在 finishScan 里再校验 reportingEnabled）。
    private func scanNow(chainedReport: Bool) {
        // 防重入；且不在上报进行时启动扫描，避免 reset/rebuild 与在途上传竞争。
        guard scanTask == nil, reportTask == nil, statusSubject.value.localCollectionEnabled, let ledger else { return }
        refreshConfigurationAuthority()

        // 解析有效 hostname：配置权威优先，否则用户保存的本地 hostname。绝不 fallback Host.current。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        let storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")
        let hostname = authority.hostname.isEmpty ? storedHostname : authority.hostname
        guard !hostname.isEmpty else {
            updateStatus { status in
                status.scanningInProgress = false
                status.configurationError = status.configurationError ?? "hostname 未配置，无法采集"
            }
            return
        }

        // 配置就绪时必须与账本 hostname 对齐：mismatch 时以权威重建；unset 时首次落库即对齐。
        let configReady = authority.status == .ready && !authority.hostname.isEmpty
        updateStatus { $0.scanningInProgress = true }

        let currentParserVersion = UsageJSONLParser.parserVersion
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            // 阻塞式 SQLite/文件扫描在后台队列执行（不阻塞主线程），不使用 detached 分叉。
            let result = await Self.runOffMain { gate in
                try gate.throwIfCancelled()
                // 配置就绪：确保账本派生对齐到权威 hostname。
                if configReady {
                    switch try ledger.hostnameState(current: hostname) {
                    case .match, .unset:
                        break
                    case .mismatch:
                        try ledger.rebuildForHostname(hostname)
                    }
                }
                // 解析器升级或历史非法数据：完整重扫前显式重建。
                if try ledger.requiresParserRebuild(currentParserVersion: currentParserVersion) {
                    try ledger.resetForRebuild()
                }
                try gate.throwIfCancelled()
                // 两来源扫描：同时 record parsed.events + parsed.sessionEvents。
                try Self.scan(root: Self.codexSessionsRoot, source: "codex", ledger: ledger, hostname: hostname, cancellation: gate)
                try gate.throwIfCancelled()
                try Self.scan(root: Self.claudeProjectsRoot, source: "claude-code", ledger: ledger, hostname: hostname, cancellation: gate)
                try gate.throwIfCancelled()
                // 两来源扫描后统一 finalizeDerived：全局去重 + 聚合 + 上报资格门禁。
                let finalize = try ledger.finalizeDerived(hostname: hostname)
                let summary = try ledger.summary()
                let pending = try ledger.pendingCounts(hostname: hostname)
                return ScanOutcome(summary: summary, finalize: finalize, pending: pending)
            }
            let cancelled = Task.isCancelled
            self?.finishScan(generation: generation, cancelled: cancelled, chainedReport: chainedReport, result: result)
        }
    }

    private func finishScan(generation: UInt64, cancelled: Bool, chainedReport: Bool, result: Result<ScanOutcome, Error>) {
        // 只处理当前 generation 的完成回调；旧任务被取消后再回到主线程时，
        // 若新任务已启动，generation 会不同，直接忽略避免覆盖新句柄。
        guard generation == scanGeneration else { return }
        scanTask = nil
        if cancelled {
            reportAfterCurrentScan = false
            updateStatus { $0.scanningInProgress = false }
            return
        }
        switch result {
        case let .success(outcome):
            publish(outcome.summary)
            updateStatus { status in
                status.lastScanAt = Date()
                status.scanningInProgress = false
                status.reportingEligible = outcome.finalize.reportingEligible
                status.reportingBlockedReasons = outcome.finalize.blockedReasons
                status.pendingBuckets = outcome.pending.buckets
                status.pendingSessions = outcome.pending.sessions
            }
            let shouldReport = chainedReport || reportAfterCurrentScan
            reportAfterCurrentScan = false
            if shouldReport, statusSubject.value.reportingEnabled {
                reportNow()
            }
        case let .failure(error) where error is CancellationError:
            reportAfterCurrentScan = false
            updateStatus { $0.scanningInProgress = false }
        case .failure:
            reportAfterCurrentScan = false
            updateStatus { status in
                status.scanningInProgress = false
                status.configurationError = "本地扫描失败"
            }
        }
    }

    // MARK: - Report

    func reportNow() {
        // 防重入；且不在扫描进行时上报，避免与 reset/rebuild 竞争。
        guard reportTask == nil, scanTask == nil else { return }
        refreshConfigurationAuthority()
        let current = statusSubject.value
        guard current.reportingEnabled, let ledger else {
            updateStatus { $0.reportingError = "上报未启用" }
            return
        }
        guard current.configurationStatus == .ready else {
            updateStatus { $0.reportingError = "配置未就绪，无法上报" }
            return
        }
        // 上报 hostname 以配置权威为准。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        guard !authority.hostname.isEmpty else {
            updateStatus { $0.reportingError = "hostname 未配置，禁止上报" }
            return
        }
        guard let baseURL = URL(string: current.ingestBaseURL), TokenUsageReporter.isValidBaseURL(baseURL) else {
            updateStatus { $0.reportingError = "API 地址无效" }
            return
        }
        let hostname = authority.hostname
        updateStatus { status in
            status.reportingInProgress = true
            status.reportingError = nil
        }
        let configurationURL = self.configurationURL
        let reporter = self.reporter
        reportGeneration &+= 1
        let generation = reportGeneration
        reportTask = Task { [weak self] in
            // reporter.report 是异步 I/O（含单事务 ack）；直接在持有的任务里 await，不再 detached 分叉。
            let result: Result<TokenUsageReport, Error>
            do {
                let report = try await reporter.report(
                    ledger: ledger,
                    hostname: hostname,
                    baseURL: baseURL,
                    configurationURL: configurationURL
                )
                result = .success(report)
            } catch {
                result = .failure(error)
            }
            self?.finishReport(generation: generation, result: result)
        }
    }

    private func finishReport(generation: UInt64, result: Result<TokenUsageReport, Error>) {
        // 与 finishScan 同理：只有当前 generation 的完成回调可以更新句柄，
        // 防止 stop() 之后旧任务的完成误清掉 stop() 后新启动任务的句柄。
        guard generation == reportGeneration else { return }
        reportTask = nil
        switch result {
        case let .success(report):
            // 读取 TokenUsageReport：partialFailures / pending 非零不显示成功。
            let succeeded = !report.hasPartialFailures
                && report.bucketsPending == 0
                && report.sessionsPending == 0
            updateStatus { status in
                status.reportingInProgress = false
                status.pendingBuckets = report.bucketsPending
                status.pendingSessions = report.sessionsPending
                status.lastReportSucceeded = succeeded
                if succeeded {
                    status.lastReportAt = Date()
                    status.reportingError = nil
                } else {
                    status.reportingError = Self.partialFailureText(report)
                }
            }
        case let .failure(error) where error is CancellationError:
            // 取消：恢复状态，不写错误。
            updateStatus { $0.reportingInProgress = false }
        case let .failure(error):
            updateStatus { status in
                status.reportingInProgress = false
                status.lastReportSucceeded = false
                status.reportingError = Self.errorText(error)
            }
        }
    }

    func runFullSync() {
        // 占位实现：全量同步安全门未通过，不执行。
    }

    /// 应用启动：触发首轮 scan（本地采集开启时）并按需串接上报；
    /// 若上报已启用则同时启动 30 分钟循环。多次调用幂等。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        if statusSubject.value.localCollectionEnabled {
            triggerScanThenReport()
        } else if statusSubject.value.reportingEnabled {
            reportNow()
        }
        startAutoLoopIfNeeded()
    }

    /// 停止：取消 auto loop + 扫描 + 上报任务，并递增 generation
    /// 使得任何旧的完成回调都被判定为过期，避免覆盖 stop 之后启动的新任务。
    func stop() {
        isRunning = false
        autoLoopTask?.cancel()
        autoLoopTask = nil
        reportAfterCurrentScan = false
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        reportTask?.cancel()
        reportTask = nil
        reportGeneration &+= 1
    }

    /// 触发扫描并在扫描完成后按当前上报开关串接一次上报（scan 已在跑则直接尝试上报）。
    private func triggerScanThenReport() {
        guard statusSubject.value.localCollectionEnabled else {
            if statusSubject.value.reportingEnabled { reportNow() }
            return
        }
        if scanTask != nil {
            // 已有扫描在跑：不叠加第二次扫描，但把上报意图挂到当前扫描完成后。
            // finishScan 仍会重新检查 reportingEnabled，因此关闭开关可安全撤销。
            if statusSubject.value.reportingEnabled { reportAfterCurrentScan = true }
            return
        }
        scanNow(chainedReport: true)
    }

    /// 在 reportingEnabled=true 且未启动过时创建 30 分钟自动循环任务。
    /// 循环内每轮先判断当前开关，一旦被关掉即退出，不再触发。
    private func startAutoLoopIfNeeded() {
        guard autoLoopTask == nil, isRunning, statusSubject.value.reportingEnabled else { return }
        autoLoopTask = Task { [weak self] in
            let interval = TokenSyncCoordinator.autoReportInterval
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch { return }
                guard let self, self.isRunning, self.statusSubject.value.reportingEnabled else { return }
                if self.statusSubject.value.localCollectionEnabled {
                    self.triggerScanThenReport()
                } else {
                    self.reportNow()
                }
            }
        }
    }

    // MARK: - Configuration authority

    private struct ConfigurationAuthority {
        let hostname: String
        let status: TokenReportingConfigurationStatus
        let errorText: String?
    }

    private struct ScanOutcome {
        let summary: UsageSummary?
        let finalize: UsageFinalizeResult
        let pending: (buckets: Int, sessions: Int)
    }

    /// 读取 0600 reporting.json 的 canonical hostname 与配置状态，作为上报权威。
    /// 配置缺失 / 无效时 hostname 为空，但仍允许纯本地采集。
    private static func configurationAuthority(
        reporter: TokenUsageReporter,
        url: URL
    ) -> ConfigurationAuthority {
        let status = reporter.configurationStatus(for: url)
        let hostname: String
        if let configuration = try? TokenUsageReporter.loadConfiguration(from: url) {
            hostname = CanonicalHostname.normalize(configuration.canonicalHostname)
        } else {
            hostname = ""
        }
        return ConfigurationAuthority(hostname: hostname, status: status, errorText: errorText(for: status))
    }

    /// 刷新配置状态与权威 hostname 到 UI；配置就绪但 baseURL/hostname 缺失时禁用上报。
    private func refreshConfigurationAuthority() {
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        let storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")
        let effective = authority.hostname.isEmpty ? storedHostname : authority.hostname
        var stopAutoLoop = false
        updateStatus { status in
            status.configurationStatus = Self.presentationStatus(authority.status)
            status.configurationError = authority.errorText
            status.canonicalHostname = effective.isEmpty ? nil : effective
            let canReport = !status.ingestBaseURL.isEmpty && !effective.isEmpty && authority.status == .ready
            if !canReport && status.reportingEnabled {
                status.reportingEnabled = false
                self.defaults.set(false, forKey: DefaultsKey.reportingEnabled)
                stopAutoLoop = true
            }
        }
        if stopAutoLoop {
            autoLoopTask?.cancel()
            autoLoopTask = nil
        }
    }

    // MARK: - Helpers

    private static func defaultConfigurationURL() -> URL {
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        return directory.appending(path: "AgentPulse/reporting.json")
    }

    private static func normalize(_ value: String) -> String {
        CanonicalHostname.normalize(value)
    }

    nonisolated private static var codexSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    }

    nonisolated private static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    /// 在专用后台队列上执行阻塞式工作（SQLite/文件 I/O），避免阻塞主线程，
    /// 同时不使用 Task.detached 分叉。以 Result 返回，保留取消/错误语义。
    /// GCD worker 上没有 Task 上下文，Task.checkCancellation() 在其中恒为 false；
    /// 通过 withTaskCancellationHandler 把取消桥接到显式闸门，worker 内逐文件检查。
    nonisolated private static let workerQueue = DispatchQueue(label: "com.agentpulse.token-sync.worker", qos: .utility)

    /// 线程安全的取消闸门：由 Task 取消回调置位，GCD worker 在每个文件边界检查。
    private final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func throwIfCancelled() throws {
            if isCancelled { throw CancellationError() }
        }
    }

    nonisolated private static func runOffMain<T: Sendable>(
        _ work: @escaping @Sendable (CancellationGate) throws -> T
    ) async -> Result<T, Error> {
        let gate = CancellationGate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                workerQueue.async {
                    continuation.resume(returning: Result { try work(gate) })
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    private static func presentationStatus(_ status: TokenReportingConfigurationStatus) -> TokenConfigurationStatus {
        switch status {
        case .ready: return .ready
        case .missing: return .missing
        case .invalid, .pathMissing, .commandMissing, .headersMissing, .hostnameMissing: return .invalid
        }
    }

    private static func errorText(for status: TokenReportingConfigurationStatus) -> String? {
        switch status {
        case .ready: return nil
        case .missing: return "本地上报配置缺失"
        case .invalid: return "本地上报配置无效"
        case .pathMissing: return "上报路径未配置"
        case .commandMissing: return "本地凭证未配置"
        case .headersMissing: return "上报 Header 未配置"
        case .hostnameMissing: return "hostname 未配置"
        }
    }

    /// 上报错误文案（脱敏）：覆盖 reporter 与 ingest 客户端的关键错误分类。
    private static func errorText(_ error: Error) -> String {
        switch error {
        case TokenUsageReporterError.configurationMissing:
            return "本地上报配置不完整"
        case TokenUsageReporterError.invalidConfigurationPermissions:
            return "配置文件权限不安全（需 0600）"
        case TokenUsageReporterError.invalidBaseURL:
            return "API 地址无效"
        case TokenUsageReporterError.canonicalHostnameMissing:
            return "hostname 未配置，禁止上报"
        case TokenUsageReporterError.hostnameRebuildRequired:
            return "hostname 与配置权威不一致，需重建后再上报"
        case TokenUsageReporterError.reportingIneligible:
            return "存在无法证明的潜在重复，上报已被门禁阻止"
        case IngestClientError.notAuthenticated:
            return "凭证无效或已过期"
        case IngestClientError.authIdentityChanged:
            return "凭证账号不一致"
        case IngestClientError.configurationMissing:
            return "本地上报配置不完整"
        case IngestClientError.invalidURL:
            return "API 地址无效"
        case let IngestClientError.httpFailure(statusCode):
            return "上报失败（HTTP \(statusCode)）"
        case let IngestClientError.lockContention(statusCode):
            return "服务端锁竞争，请稍后重试（HTTP \(statusCode)）"
        case IngestClientError.transportFailure:
            return "网络传输失败，请稍后重试"
        case IngestClientError.malformedResponse:
            return "上报响应无法解析"
        case TokenProviderError.launchFailed, TokenProviderError.commandFailed,
             TokenProviderError.malformedOutput,
             TokenProviderError.unsuccessfulResponse, TokenProviderError.missingToken:
            return "本地凭证获取失败"
        case TokenProviderError.configurationMissing:
            return "本地凭证未配置"
        default:
            return "上报失败"
        }
    }

    /// 部分失败文案：从 TokenUsageReport.partialFailures 取首个错误分类。
    private static func partialFailureText(_ report: TokenUsageReport) -> String {
        if let failure = report.partialFailures.first {
            return errorText(failure.error)
        }
        if report.bucketsPending > 0 || report.sessionsPending > 0 {
            return "部分数据仍待上报（buckets \(report.bucketsPending) / sessions \(report.sessionsPending)）"
        }
        return "上报未完全成功"
    }

    private func updateStatus(_ mutate: (inout TokenSyncStatus) -> Void) {
        var current = statusSubject.value
        mutate(&current)
        statusSubject.send(current)
    }

    private func publish(_ summary: UsageSummary?) {
        guard let summary else { summarySubject.send(.empty); return }
        summarySubject.send(Self.summary(from: summary))
    }

    private static func summary(from summary: UsageSummary) -> TokenUsageSummary {
        TokenUsageSummary(
            totalTokens: summary.counts.total,
            estimatedCost: summary.estimatedCostUSD,
            cachedTokens: summary.cachedTokens,
            newTokens: summary.newTokens,
            cacheHitRate: summary.cachePercentage
        )
    }

    private static func openLedger() -> UsageLedgerStore? {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appending(path: "AgentPulse", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try UsageLedgerStore(path: directory.appending(path: "usage.sqlite3").path)
        } catch { return nil }
    }

    /// 扫描单一来源根目录：逐 jsonl 文件按 checkpoint 跳过未变更文件，
    /// 变更文件解析后同时写入 token 事件与 session 事件。不触发派生重算。
    nonisolated private static func scan(root: URL, source: String, ledger: UsageLedgerStore, hostname: String, cancellation: CancellationGate) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try cancellation.throwIfCancelled()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modifiedAt = values.contentModificationDate ?? Date.distantPast
            let fileID = UsageJSONLParser.fileID(for: url.path)
            if let checkpoint = try ledger.checkpoint(fileID: fileID),
               checkpoint.size == fileSize,
               abs(checkpoint.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001,
               checkpoint.parserVersion == UsageJSONLParser.parserVersion {
                continue
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let parsed = UsageJSONLParser.parse(data: data, source: source, fileIdentity: url.path, modifiedAt: modifiedAt)
            try ledger.record(events: parsed.events, sessionEvents: parsed.sessionEvents, checkpoint: parsed.checkpoint, hostname: hostname)
        }
    }
}
