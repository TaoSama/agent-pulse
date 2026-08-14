import Combine
import CryptoKit
import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage

/// 本地扫描的致命失败：来源根目录存在却无法枚举/访问。
/// 用于区分“无内容”（非失败）与“无法证明已完整扫描”（失败），
/// 从而绝不把源目录枚举失败当成“全量成功”。
private enum TokenSyncScanError: Error {
    case sourceRootNotEnumerable(source: String)
}

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
    /// cliproxyapi 主动拉取采集服务；配置缺失/失败时跳过，不影响本地文件采集。
    private let cliProxyService: CliProxyUsageService
    private let usageSummaryCalendar: Calendar
    /// 可选本地采集来源配置文件（owner-only 0600），独立于 reporting.json。
    /// 缺失/非法不影响内建来源采集。
    private let localCollectionURL: URL

    /// 扫描 / 上报任务句柄，用于防重入与 stop 取消。
    private var scanTask: Task<Void, Never>?
    private var reportTask: Task<Void, Never>?
    /// 每次启动 scan/report 时递增；对应任务完成回调只有在其 generation 仍是
    /// 当前值时才更新句柄，避免旧任务取消后完成回调覆盖新任务句柄的竞态。
    private var scanGeneration: UInt64 = 0
    private var reportGeneration: UInt64 = 0
    /// 全量同步任务句柄；与 scan/report 三方互斥，stop() 取消。
    private var fullSyncTask: Task<Void, Never>?
    /// 全量同步 generation：与 scan/report 同理，取消后旧回调按 generation 过期忽略。
    private var fullSyncGeneration: UInt64 = 0
    /// 最近一次全量同步的一次性结果文案（成功/失败原因）。
    /// 用于在状态回落到 .ready/.blocked 后仍向用户展示“上次结果”，避免 completed/failed 永久粘滞
    /// 而堵住重新/重试。nil 表示尚无历史结果。
    private var fullSyncLastResultNote: String?
    /// 当自动上报在已有扫描期间被触发时，记住“扫描结束后上报”的意图。
    /// 关闭上报或 stop() 会清空，避免过期动作越过用户当前设置。
    private var reportAfterCurrentScan = false
    /// 自动上报循环任务；nil 表示当前未启动或已停止。
    private var autoLoopTask: Task<Void, Never>?
    /// 应用生命周期：start() 后置 true；stop() 置 false 后阻止后续自动动作。
    private var isRunning: Bool = false
    /// 启动时检测到 rebuild pending（已 reset 但未确认全部来源重扫成功）：
    /// 置 true 后禁止一切网络动作（普通上报 / 恢复或执行全量同步），
    /// 先完整重扫全部来源；扫描成功清除 pending 后，再由 finishScan 恢复正常启动链路。
    private var rebuildRecoveryPending: Bool = false

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
        reporter: TokenUsageReporter = TokenUsageReporter(),
        cliProxyService: CliProxyUsageService = CliProxyUsageService(),
        usageSummaryCalendar: Calendar = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.configurationURL = configurationURL
        self.reporter = reporter
        self.cliProxyService = cliProxyService
        self.usageSummaryCalendar = usageSummaryCalendar
        self.localCollectionURL = TokenSyncCoordinator.defaultLocalCollectionURL()
        ledger = Self.openLedger()

        let localCollection = defaults.object(forKey: DefaultsKey.localCollectionEnabled) as? Bool ?? true
        let storedReporting = defaults.object(forKey: DefaultsKey.reportingEnabled) as? Bool ?? false
        let baseURL = defaults.string(forKey: DefaultsKey.ingestBaseURL) ?? ""
        var storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")

        // 配置权威：以 reporting.json 的 canonical hostname 为准；配置未就绪时为空。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        // 旧版数据库已经把 hostname 持久化在派生表，却没有写 UserDefaults。仅当配置和
        // 用户保存值都为空、且账本能证明恰好一个非空 hostname 时，采纳并持久化该值，
        // 让冷启动摘要立即恢复。多 hostname / 空库一律不猜；配置权威始终优先。
        if authority.hostname.isEmpty,
           storedHostname.isEmpty,
           let candidate = ledger.flatMap({ try? $0.uniqueLegacyHostnameCandidate() }),
           !candidate.isEmpty {
            let normalizedCandidate = Self.normalize(candidate)
            // Recovery must preserve the exact durable natural-key namespace. If normalization
            // would alter it (for example, surrounding whitespace or an overlong legacy value),
            // fail closed instead of selecting a hostname that has no matching derived rows.
            if !normalizedCandidate.isEmpty, normalizedCandidate == candidate {
                storedHostname = normalizedCandidate
                defaults.set(storedHostname, forKey: DefaultsKey.canonicalHostname)
            }
        }
        // 上报所用 hostname 权威优先；否则回落到用户保存的本地 hostname（仅用于本地采集）。
        let effectiveHostname = authority.hostname.isEmpty ? storedHostname : authority.hostname

        // 冷启动只按已知 canonical hostname 恢复四个派生窗口。hostname 未知时保持空，
        // 等首次扫描 record 播种账本身份后再发布，禁止回退到跨 hostname 的 legacy summary。
        let initialSummary: TokenUsageSummary
        if let ledger, !effectiveHostname.isEmpty {
            initialSummary = (try? Self.summaries(
                from: ledger,
                hostname: effectiveHostname,
                containing: Date(),
                calendar: usageSummaryCalendar
            )) ?? .empty
        } else {
            initialSummary = .empty
        }
        summarySubject = CurrentValueSubject(initialSummary)

        let canReport = !baseURL.isEmpty && !effectiveHostname.isEmpty && authority.status == .ready
        let reporting = canReport ? storedReporting : false
        if storedReporting && !canReport {
            // 配置已失效时持久化关闭，避免配置日后恢复后自动“复活”上报。
            defaults.set(false, forKey: DefaultsKey.reportingEnabled)
        }

        let eligible = ledger.flatMap { (try? $0.reportingEligible(hostname: effectiveHostname)) } ?? true
        let pending = ledger.flatMap { (try? $0.pendingCounts(hostname: effectiveHostname)) } ?? (0, 0)

        // 全量同步初始 readiness：依据当前配置能力动态判定（就绪→.ready，否则→.blocked）。
        let initialFullSync = Self.initialFullSyncReadiness(
            reporter: reporter,
            configurationURL: configurationURL,
            ingestBaseURL: baseURL,
            authorityStatus: authority.status,
            authorityHostname: authority.hostname,
            hasLedger: ledger != nil
        )
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
            fullSyncState: initialFullSync.0,
            fullSyncBlockReasons: initialFullSync.1
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
        // baseURL 变化会改变全量同步的目标端点：取消在途 full sync（可恢复，不清 state/gate），
        // 递增 generation 使旧完成回调过期，并让状态回落到当前 readiness（.ready/.blocked）。
        cancelInFlightFullSync()
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
        refreshFullSyncReadiness()
    }

    /// 保存用户 hostname：仅用于“配置权威缺失时”的本地采集标识；
    /// 若配置就绪，则以配置为权威（保存值不会覆盖权威）。
    func setCanonicalHostname(_ hostname: String) {
        let trimmed = Self.normalize(hostname)
        // hostname 变化会改变全量同步绑定的身份/账本口径：取消在途 full sync（可恢复），
        // 递增 generation 使旧回调过期，状态回落到当前 readiness。
        cancelInFlightFullSync()
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
        refreshFullSyncReadiness()
    }

    // MARK: - Scan (production chain)

    func scanNow() {
        scanNow(chainedReport: false)
    }

    /// 触发扫描；chainedReport=true 则扫描成功后串接一次上报（无论开关变化，
    /// 在 finishScan 里再校验 reportingEnabled）。
    private func scanNow(chainedReport: Bool) {
        // 防重入；且不在上报或全量同步进行时启动扫描，避免 reset/rebuild 与在途上传竞争。
        guard scanTask == nil, reportTask == nil, fullSyncTask == nil,
              statusSubject.value.localCollectionEnabled, let ledger else { return }
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
        // 在启动后台 Task 前捕获为局部常量：闭包内 self 为弱引用，不能直接访问实例存储属性。
        let localSourcesURL = localCollectionURL
        let summaryCalendar = usageSummaryCalendar
        scanGeneration &+= 1
        let generation = scanGeneration
        let cliProxyService = self.cliProxyService
        let cliProxyConfigPath = Self.cliProxyConfigPath(defaults: defaults)
        scanTask = Task { [weak self] in
            // cliproxy 主动拉取（异步 HTTP）在进入阻塞式文件扫描之前完成；失败仅记状态、
            // 返回空事件，绝不影响本地文件采集与既有链路。
            var cliProxyEvents: [UsageEvent] = []
            var cliProxyError: String?
            let cliProxyConfigured = CliProxyUsageService.isConfigured(atPath: cliProxyConfigPath)
            if cliProxyConfigured {
                do {
                    cliProxyEvents = try await cliProxyService.fetchUsageEvents(atPath: cliProxyConfigPath)
                } catch is CancellationError {
                    // 取消：走后续 cancelled 分支统一处理。
                } catch {
                    cliProxyError = (error as? LocalizedError)?.errorDescription ?? "cliproxyapi 采集失败"
                }
            }
            self?.updateCliProxyStatus(configured: cliProxyConfigured, error: cliProxyError, generation: generation)

            // 绑定为不可变值再进入 @Sendable worker，满足 Swift 6 并发捕获约束。
            let networkEvents = cliProxyEvents
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
                // 解析器升级或历史非法数据：绝不再 resetForRebuild（那会清空磁盘上已删除历史
                // session 的 raw，无法恢复）。改为设置持久 parser rebuild pending（不清 raw），
                // 随后本轮对所有 configured root 做文件级原子重解析：每个变化文件在 record 内
                // 事务性替换该 fileID 的旧 raw 并置派生 dirty；已消失文件仅标 missing、保留 raw。
                // 仅当所有来源无致命失败、finalize 成功、且达到目标 parser 版本后，才显式清除。
                if try ledger.requiresParserRebuild(currentParserVersion: currentParserVersion) {
                    try ledger.beginParserRebuild(targetParserVersion: currentParserVersion)
                }
                try gate.throwIfCancelled()
                // 逐来源扫描并收集磁盘 present fileID；record 只处理变化文件（status!=complete 或
                // size/mtime/parserVersion 不匹配），不触发派生重算。
                // Codex sessions 与 archived_sessions 同为 source="codex"：必须合并两 root 的
                // present 集合后，对 "codex" 只调用一次 markFilesMissing，否则会互相误标 missing。
                var codexPresentFileIDs: [String] = []
                codexPresentFileIDs += try Self.scan(root: Self.codexSessionsRoot, source: "codex", ledger: ledger, hostname: hostname, cancellation: gate)
                try gate.throwIfCancelled()
                // 归档会话不属于运行中 task 口径，但其已产生的 token 仍属于累计用量。
                codexPresentFileIDs += try Self.scan(root: Self.codexArchivedSessionsRoot, source: "codex", ledger: ledger, hostname: hostname, cancellation: gate)
                try gate.throwIfCancelled()
                try ledger.markFilesMissing(source: "codex", presentFileIDs: codexPresentFileIDs)
                try gate.throwIfCancelled()
                let claudePresentFileIDs = try Self.scan(root: Self.claudeProjectsRoot, source: "claude-code", includeSubagents: true, ledger: ledger, hostname: hostname, cancellation: gate)
                try gate.throwIfCancelled()
                try ledger.markFilesMissing(source: "claude-code", presentFileIDs: claudePresentFileIDs)
                try gate.throwIfCancelled()
                // 可选的用户声明本地来源（Claude-compatible transcript）。配置缺失/非法不影响内建来源。
                // 每个自定义 source 独立聚合 present 集合，再各自按 source 标 missing。
                var localPresentBySource: [String: [String]] = [:]
                for local in Self.loadLocalCollectionSources(url: localSourcesURL) {
                    let present = try Self.scan(root: local.root, source: local.source, includeSubagents: local.includeSubagents, ledger: ledger, hostname: hostname, cancellation: gate)
                    localPresentBySource[local.source, default: []] += present
                    try gate.throwIfCancelled()
                }
                for (source, present) in localPresentBySource {
                    try ledger.markFilesMissing(source: source, presentFileIDs: present)
                    try gate.throwIfCancelled()
                }
                // cliproxy 主动拉取事件：只写原始层，不写文件 checkpoint（网络来源无偏移语义）。
                try ledger.recordNetworkEvents(networkEvents, source: CliProxyUsageParser.source, hostname: hostname)
                try gate.throwIfCancelled()
                // 全部来源扫描后统一 finalizeDerived：全局去重 + 聚合 + 上报资格门禁。
                let finalize = try ledger.finalizeDerived(hostname: hostname)
                // 只有在所有来源都完整扫描（无致命失败：任一来源枚举失败 / 单文件 I/O 失败都会
                // 在上面抛出并终止本次扫描，不会到达此处）后，才显式清除 rebuild pending。
                // record/finalize 不会推断重扫已完成，清除是此处唯一入口。
                if try ledger.requiresRebuildCompletion() {
                    try ledger.markRebuildCompleted()
                }
                let summary = try Self.summaries(
                    from: ledger,
                    hostname: hostname,
                    containing: Date(),
                    calendar: summaryCalendar
                )
                let pending = try ledger.pendingCounts(hostname: hostname)
                return ScanOutcome(summary: summary, finalize: finalize, pending: pending)
            }
            let cancelled = Task.isCancelled
            self?.finishScan(generation: generation, cancelled: cancelled, chainedReport: chainedReport, result: result)
        }
    }

    /// 把 cliproxy 采集配置状态与错误刷新到 UI（只在当前 generation 有效时）。
    private func updateCliProxyStatus(configured: Bool, error: String?, generation: UInt64) {
        guard generation == scanGeneration else { return }
        updateStatus { status in
            status.cliProxyConfigured = configured
            status.cliProxyError = error
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
                status.configurationError = nil
                status.reportingEligible = outcome.finalize.reportingEligible
                status.reportingBlockedReasons = outcome.finalize.blockedReasons
                status.pendingBuckets = outcome.pending.buckets
                status.pendingSessions = outcome.pending.sessions
            }
            // 扫描链路会完成 hostname 对齐；此前因此 blocked 的 full sync 现在可重新评估。
            refreshFullSyncReadiness()
            // rebuild pending 恢复路径：本次扫描已完整跑完全部来源（无致命失败），
            // 且 off-main 已在 finalize 后清除 pending。此处确认已清除后再恢复正常启动链路
            // （恢复全量同步 / 上报）。若因某种原因仍未清除，则保持 pending、绝不发网络请求。
            if rebuildRecoveryPending {
                reportAfterCurrentScan = false
                if isRebuildCompletionPending() {
                    // 未清除（例如刚被并发再次 reset）：保持恢复态，等待下一轮重扫，不做任何网络动作。
                    return
                }
                resumeStartupAfterRebuildRecovery()
                return
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
            // 扫描失败（含来源目录枚举失败、单文件 I/O 失败）：保持 rebuild pending，
            // 绝不清除、绝不发网络请求。恢复标记保留，待下次扫描重试。
            updateStatus { status in
                status.scanningInProgress = false
                status.configurationError = "本地扫描失败"
            }
        }
    }

    // MARK: - Report

    func reportNow() {
        // 防重入；且不在扫描或全量同步进行时上报，避免与 reset/rebuild/对账竞争。
        guard reportTask == nil, scanTask == nil, fullSyncTask == nil else { return }
        // rebuild pending 期间绝不发网络请求：必须先完整重扫全部来源并清除 pending。
        if isRebuildCompletionPending() {
            updateStatus { $0.reportingError = "本地重建未完成，请先完成完整扫描后再上报" }
            return
        }
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

    /// 手动触发一次全量同步（reconciliation）。
    ///
    /// 与普通上报不同，全量同步**不依赖 reportingEnabled**：它是一次“把本机全部派生行与
    /// 远端对齐”的显式修复动作，用户可在上报关闭时手动执行。但它仍要求：
    /// - 本地账本可用；
    /// - 配置就绪且携带 full-sync 协议段（reporting.json 的 fullSync）；
    /// - baseURL 合法且 hostname 与配置权威一致（绝不 fallback Host.current）；
    /// - 与 scan/report 三方互斥、无在途任务。
    ///
    /// 严格链路：hostname 校验 → generation baseline → token identity → remote reserve →
    /// 同 generation ledger snapshot → remote complete → ledger atomic commit → finalize。
    /// 远端已 committed 但本地 ledger commit 尚未完成时崩溃/重启：下次 reserve 会复用持久化
    /// fence，completeUpload 命中幂等 committed 分支（零网络）并重跑 ledger commit + finalize。
    /// 任一围栏（generation / row-set / identity）失败都 fail-closed：不清 state、不清 gate。
    func runFullSync() {
        // 三方互斥 + 防重入。
        guard scanTask == nil, reportTask == nil, fullSyncTask == nil, let ledger else { return }
        // rebuild pending 期间绝不 performFullSync（不发任何网络请求）：先完整重扫全部来源。
        if isRebuildCompletionPending() {
            updateStatus { status in
                status.fullSyncState = .blocked
                status.fullSyncBlockReasons = self.decorateWithLastResult(["本地重建未完成，需先完成完整扫描"])
            }
            return
        }
        refreshConfigurationAuthority()

        // 统一 readiness 守门：缺配置 / 未 ready / 地址无效 / 缺 full-sync 协议段，一律保持 .blocked，
        // 绝不置 .failed（缺配置属默认验收态，不是一次失败）。仅在满足全部条件后才进入 .running。
        let (readiness, reasons) = Self.fullSyncReadiness(
            reporter: reporter,
            configurationURL: configurationURL,
            status: statusSubject.value,
            ledger: ledger
        )
        guard readiness == .ready else {
            updateStatus { status in
                status.fullSyncState = .blocked
                status.fullSyncBlockReasons = self.decorateWithLastResult(reasons)
            }
            return
        }

        // readiness 已确保下列解析全部成功；仍以 guard 兜底，失败回落 .blocked。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        guard !authority.hostname.isEmpty,
              let baseURL = URL(string: statusSubject.value.ingestBaseURL),
              TokenUsageReporter.isValidBaseURL(baseURL),
              let configuration = try? TokenUsageReporter.loadConfiguration(from: configurationURL),
              configuration.isFullSyncReady,
              configuration.fullSyncConfiguration(baseURL: baseURL, hostname: authority.hostname) != nil else {
            updateStatus { status in
                status.fullSyncState = .blocked
                status.fullSyncBlockReasons = self.decorateWithLastResult(["全量同步需要完整且可恢复的远端协议配置"])
            }
            return
        }
        let authorityHost = authority.hostname
        // The worker resolves the actual target off-main: an older hostname with
        // reconciliation debt takes priority over the current authority hostname.
        updateStatus { status in
            status.fullSyncState = .running
            status.fullSyncBlockReasons = []
        }

        fullSyncGeneration &+= 1
        let generation = fullSyncGeneration
        fullSyncTask = Task { [weak self] in
            let result = await Self.performFullSync(
                ledger: ledger,
                authorityHost: authorityHost,
                baseURL: baseURL,
                configuration: configuration
            )
            self?.finishFullSync(generation: generation, result: result)
        }
    }

    /// 全量同步结果。均携带本次使用的 hostname，使完成回调用**同一** hostname 刷新账本派生态，
    /// 避免期间 canonicalHostname 变化导致刷错口径。
    private enum FullSyncOutcome {
        /// 远端 committed 且账本已原子 commit（含幂等重放场景）。
        case committed(hostname: String)
        /// 无待同步行：账本快照为空且无对账 gate（已全部对齐），视作成功完成。
        case nothingToSync(hostname: String)
        /// 围栏失败（generation / row-set / identity）：fail-closed，未清 state/gate。
        case fenced(hostname: String, reason: String)
        /// 运行前置条件在离主线程核验时不满足。
        case blocked(hostname: String, reason: String)
        /// 取消。
        case cancelled
        /// 其他错误（脱敏文案）。
        case failure(hostname: String, text: String)
    }

    /// 全量同步的后台执行：所有阻塞式 SQLite（快照/commit/finalize）都经 runOffMain 在专用队列执行，
    /// 绝不在 MainActor 或 Swift cooperative 执行器上直接跑 SQLite；网络 I/O 在 URLSession。
    /// 不触及 UI；结果经 finishFullSync 回主线程落状态。
    nonisolated private static func performFullSync(
        ledger: UsageLedgerStore,
        authorityHost: String,
        baseURL: URL,
        configuration: TokenReportingConfiguration
    ) async -> FullSyncOutcome {
        var outcomeHostname = authorityHost
        do {
            // 1) SQLite target selection and hostname gate run off-main. A debt
            // host is allowed to differ from the current authority host because
            // it must receive an empty full sync to delete its stale remote rows.
            // Without debt, the current authority host must match the ledger.
            let target = try await runOffMain { gate -> (hostname: String, isDebtHost: Bool, state: UsageHostnameState) in
                try gate.throwIfCancelled()
                let debtHosts = try ledger.pendingReconciliationHosts()
                let hostname = debtHosts.first ?? authorityHost
                return (hostname, debtHosts.contains(hostname), try ledger.hostnameState(current: hostname))
            }.get()
            let hostname = target.hostname
            outcomeHostname = hostname
            if !target.isDebtHost, case .match = target.state {
                // Current authority host is aligned.
            } else if target.isDebtHost {
                // The per-host debt itself authorizes cleanup of this old host.
            } else {
                return .blocked(
                    hostname: hostname,
                    reason: "本机标识与配置权威不一致，请先完成采集对齐"
                )
            }
            try Task.checkCancellation()

            guard let fullSyncConfig = configuration.fullSyncConfiguration(
                baseURL: baseURL, hostname: hostname
            ) else {
                return .blocked(hostname: hostname, reason: "全量同步配置未就绪")
            }

            // 2) reserve 前固定账本 generation；后续 snapshot 必须读取同一 generation。
            let generationBaseline = try await runOffMain { gate in
                try gate.throwIfCancelled()
                return try ledger.fullSyncGenerationBaseline()
            }.get()
            try Task.checkCancellation()

            // 2.5) Preflight：在预取 token、reserve fence 或任何网络/状态副作用之前，
            // 先按同一 baseline 读一份只读快照，做与增量链路完全一致的 wire 规范化
            // （canonical hostname + 字段字节截断）与全量自然键碰撞校验。这一步是纯函数、
            // 零副作用：
            //   - 自然键碰撞 → 直接 fenced 返回，绝不 reserve、绝不取 token、绝不触网；
            //   - generation 漂移（staleGeneration）→ 同样在任何副作用前提前返回。
            // 通过后再进入 reserve → 按同一 baseline 重读 → completeUpload 流程，两次读取
            // 用的 expectedGeneration 与传给 reserve 的 generationBaseline 一致，故
            // reservation 的 generation fence 仍然成立。
            let preflightSnapshot: UsageFullSyncSnapshot
            do {
                preflightSnapshot = try await runOffMain { gate in
                    try gate.throwIfCancelled()
                    return try ledger.fullSyncSnapshot(
                        hostname: hostname,
                        expectedGeneration: generationBaseline
                    )
                }.get()
            } catch let snapshotError as UsageFullSyncSnapshotError {
                switch snapshotError {
                case .staleGeneration:
                    return .fenced(hostname: hostname, reason: "本地数据已变化，请重新采集后再全量同步")
                case .localDerivationPending:
                    return .fenced(hostname: hostname, reason: "本地采集尚未完成，请完成扫描后再全量同步")
                }
            }
            try Task.checkCancellation()
            // 与后续 begin/stage/commit 相同的“空快照不可直接 no-op”判定：仅当既空且无
            // 对账 gate 时才是真正无事可做，此时在任何 token/网络前直接返回。
            if preflightSnapshot.isEmpty, preflightSnapshot.reconciliationReason == nil {
                return .nothingToSync(hostname: hostname)
            }
            do {
                _ = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(
                    from: preflightSnapshot, hostname: hostname
                )
            } catch let ingestError as IngestClientError {
                if case .duplicateNaturalKey = ingestError {
                    // 整份快照存在自然键碰撞：与增量链路一致地拒绝，且发生在 token/网络/状态
                    // 之前，故本次全量同步零副作用。
                    return .fenced(hostname: hostname, reason: "本地数据存在重复自然键，请重新采集后再全量同步")
                }
                return .failure(hostname: hostname, text: fullSyncErrorText(ingestError))
            }
            try Task.checkCancellation()

           // 3) 组装配置驱动的可恢复上传核心，并预取一次稳定账号身份。reserve 与
           // completeUpload 始终复用这一 pinned identity。
           // baseURL is passed so the identity endpoint resolves the account
           // namespace over the same origin the full-sync requests target.
           let tokenSupplier = CommandFullSyncTokenSupplier(
               configuration: configuration, baseURL: baseURL
           )
            let reporter = FullSyncReporter(
                configuration: fullSyncConfig,
                sender: URLSessionFullSyncRequestSender(),
                tokenSupplier: tokenSupplier
            )
            let authIdentity = try await tokenSupplier.prefetchIdentity()
            try Task.checkCancellation()

            // 4) 先向远端预留 fence，并原子持久化 reserved state。崩溃恢复会按相同
            // hostname + identity + generation baseline 复用该 fence，不重复 reserve。
            let store = FullSyncStateStore(directory: try fullSyncStateDirectory(hostname: hostname))
            do {
                _ = try await reporter.reserve(
                    hostname: hostname,
                    authIdentity: authIdentity,
                    generationBaseline: generationBaseline,
                    store: store
                )
            } catch FullSyncError.rescanRequired {
                // 已持久化 state 与当前 baseline 不一致，不能开始上传；清掉过期 reservation，
                // 下次重试将重新 reserve。
                try reporter.finalize(store: store)
                return .fenced(hostname: hostname, reason: "本地数据已变化，请重新采集后再全量同步")
            }
            try Task.checkCancellation()

            // 5) reserve 后按 baseline 在单事务内取完整快照。generation 漂移时 ledger 不返回
            // 半快照；清理刚才的 reservation，且绝不调用 begin/stage/commit。
            let snapshot: UsageFullSyncSnapshot
            do {
                snapshot = try await runOffMain { gate in
                    try gate.throwIfCancelled()
                    return try ledger.fullSyncSnapshot(
                        hostname: hostname,
                        expectedGeneration: generationBaseline
                    )
                }.get()
            } catch let snapshotError as UsageFullSyncSnapshotError {
                switch snapshotError {
                case .staleGeneration:
                    try reporter.finalize(store: store)
                    return .fenced(hostname: hostname, reason: "本地数据已变化，请重新采集后再全量同步")
                case .localDerivationPending:
                    try reporter.finalize(store: store)
                    return .fenced(hostname: hostname, reason: "本地采集尚未完成，请完成扫描后再全量同步")
                }
            }
            // 关键：空快照不可直接 no-op。
            // reconciliation gate 可能是因为“曾经已同步的行被本地重算删除、且本机现为 0 行”而置位
            //（远端协议无 tombstone，删除不会自动传播）。此时若跳过协议，远端会永久残留旧行，
            // 且本地 gate 永不清除、上报资格永久 fail-closed。
            // 因此只有当快照为空**且**没有待对账原因（gate 未置位）时，才是真正的“无事可做”；
            // 此时安全清理仅含 fence 的 reserved state，不发送 begin/commit。
            // 否则即便快照为空，也必须继续走 begin→(0 行 stage)→commit，
            // 让远端据整份（空）快照删除旧行并回执确认，随后本地 commitFullSync 清 gate、恢复资格。
            if snapshot.isEmpty, snapshot.reconciliationReason == nil {
                try reporter.finalize(store: store)
                return .nothingToSync(hostname: hostname)
            }
            try Task.checkCancellation()

            // 6) snapshot 与 reservation generation 完全绑定后，才允许 begin/stage/commit。
            // 用与增量链路完全一致的共享 normalizer 规范化整份快照并复核自然键；此处快照与
            // preflight 同一 generation，规范化结果逐字节相同，因此 fingerprint / staged
            // bytes 与增量 wire 一致。理论上 preflight 已放行，这里再核一次以保证送入
            // completeUpload 的正是规范化后的 payload（fail-closed，零副作用地清理 reservation）。
            let payload: FullSyncPayloadSnapshot
            do {
                payload = try UsageFullSyncSnapshotMapper.normalizedPayloadSnapshot(
                    from: snapshot, hostname: hostname
                )
            } catch let ingestError as IngestClientError {
                try reporter.finalize(store: store)
                if case .duplicateNaturalKey = ingestError {
                    return .fenced(hostname: hostname, reason: "本地数据存在重复自然键，请重新采集后再全量同步")
                }
                return .failure(hostname: hostname, text: fullSyncErrorText(ingestError))
            }
            do {
                _ = try await reporter.completeUpload(
                    snapshot: payload,
                    authIdentity: authIdentity,
                    store: store
                )
            } catch FullSyncError.rescanRequired {
                // 同 generation 下 payload 仍无法绑定，视作需要重扫；reporter 已 fail-closed，
                // 这里确保任何过期 state 都被清理。
                try reporter.finalize(store: store)
                return .fenced(hostname: hostname, reason: "本地数据已变化，请重新采集后再全量同步")
            }
            try Task.checkCancellation()

            // 7) 远端已确认整份快照 → 账本原子 commit（generation 围栏 + 逐行 revision 精确核对）。
            //    严格顺序：先 remote committed，后 ledger commit。围栏失败=fail-closed，不清 state/gate。
            //    SQLite→runOffMain。
            let commitResult = try await runOffMain { _ in
                try ledger.commitFullSync(UsageFullSyncCommit(snapshot: snapshot))
            }.get()
            guard commitResult.committed else {
                // 账本围栏拒绝（快照期间被重算 / 行集变化）：保留远端已 committed 的 state，
                // 不调用 finalize，使下次重试仍能命中幂等 committed 分支并重跑 ledger commit。
                return .fenced(hostname: hostname, reason: commitResult.failureReason ?? "全量同步账本围栏拒绝")
            }

            // 8) 账本已持久记录成功 → 清理可恢复上传 state（remote-ack → ledger-commit 窗口已闭合）。
            try reporter.finalize(store: store)
            return .committed(hostname: hostname)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(hostname: outcomeHostname, text: fullSyncErrorText(error))
        }
    }

    /// 全量同步完成回调（主线程）：仅当前 generation 有效，避免 stop 后旧回调覆盖。
    /// 取消在途全量同步：cancel + 递增 generation（旧回调过期）+ 状态从 .running 回落到当前 readiness。
    /// 不清 state/gate，可恢复。无在途任务时仅确保状态不停留在 .running。
    private func cancelInFlightFullSync() {
        fullSyncTask?.cancel()
        fullSyncTask = nil
        fullSyncGeneration &+= 1
        if statusSubject.value.fullSyncState == .running {
            // 直接落到一个非 running 的中间态，随后 refreshFullSyncReadiness 精确定级。
            updateStatus { $0.fullSyncState = .blocked }
            refreshFullSyncReadiness()
        }
    }

    /// 全量同步完成回调（主线程）：仅当前 generation 有效，避免 stop 后旧回调覆盖。
    /// 关键：completed/failed 不永久粘滞——记录“上次结果”文案后，状态立即依据当前 readiness
    /// 回落到 .ready/.blocked，使 UI 可立即重新/重试；账本派生态用**本次 hostname**离主线程刷新。
    private func finishFullSync(generation: UInt64, result: FullSyncOutcome) {
        guard generation == fullSyncGeneration else { return }
        fullSyncTask = nil
        switch result {
        case let .committed(hostname), let .nothingToSync(hostname):
            fullSyncLastResultNote = "上次全量同步已完成"
            refreshLedgerDerivedStatus(hostname: hostname, generation: generation)
        case let .fenced(hostname, reason):
            fullSyncLastResultNote = "上次全量同步未完成：\(reason)"
            refreshLedgerDerivedStatus(hostname: hostname, generation: generation)
        case let .blocked(hostname, reason):
            _ = hostname
            fullSyncLastResultNote = nil
            updateStatus { status in
                status.fullSyncState = .blocked
                status.fullSyncBlockReasons = [reason]
            }
        case let .failure(hostname, text):
            fullSyncLastResultNote = "上次全量同步失败：\(text)"
            refreshLedgerDerivedStatus(hostname: hostname, generation: generation)
        case .cancelled:
            // 取消：不写“上次结果”，状态直接由 readiness 决定。
            refreshFullSyncReadiness()
        }
    }

    /// 用**指定 hostname**离主线程刷新账本派生态（pending + 上报资格），随后回主线程落状态，
    /// 并把全量同步状态从 .running 回落到当前 readiness（.ready/.blocked，附“上次结果”文案）。
    /// generation 守门：期间若 stop()/新任务推进了 generation，则丢弃这次刷新，避免 running 粘滞或错刷。
    private func refreshLedgerDerivedStatus(hostname: String, generation: UInt64) {
        guard let ledger else {
            refreshFullSyncReadiness()
            return
        }
        Task { [weak self] in
            let derived = await Self.runOffMain { _ -> (Bool, Int, Int) in
                let eligible = (try? ledger.reportingEligible(hostname: hostname)) ?? true
                let pending = (try? ledger.pendingCounts(hostname: hostname)) ?? (0, 0)
                return (eligible, pending.0, pending.1)
            }
            guard let self else { return }
            // 只处理当前 generation：stop() 或新一轮 full sync 会推进 generation。
            guard generation == self.fullSyncGeneration else { return }
            if case let .success((eligible, pendingBuckets, pendingSessions)) = derived {
                self.updateStatus { status in
                    status.reportingEligible = eligible
                    status.pendingBuckets = pendingBuckets
                    status.pendingSessions = pendingSessions
                }
            }
            self.refreshFullSyncReadiness()
        }
    }

    /// 计算全量同步 readiness 并落状态：只要不在 .running，就依据当前配置能力回到 .ready/.blocked，
    /// 并附带“上次结果”文案。绝不停留在 .completed/.failed（否则按钮永久禁用，无法重新/重试）。
    private func refreshFullSyncReadiness() {
        // 运行中不打断。
        if statusSubject.value.fullSyncState == .running { return }
        let (state, reasons) = Self.fullSyncReadiness(
            reporter: reporter,
            configurationURL: configurationURL,
            status: statusSubject.value,
            ledger: ledger
        )
        updateStatus { status in
            status.fullSyncState = state
            status.fullSyncBlockReasons = self.decorateWithLastResult(reasons)
        }
    }

    /// 把“上次全量同步结果”文案并入展示原因列表（置顶），使结果不粘滞在 .completed/.failed 的同时
    /// 仍向用户可见。无历史结果时原样返回。
    private func decorateWithLastResult(_ reasons: [String]) -> [String] {
        guard let note = fullSyncLastResultNote else { return reasons }
        return [note] + reasons
    }

    /// 依据配置 + baseURL + hostname + full-sync 协议段，判定全量同步是否 ready。
    private static func fullSyncReadiness(
        reporter: TokenUsageReporter,
        configurationURL: URL,
        status: TokenSyncStatus,
        ledger: UsageLedgerStore?
    ) -> (TokenFullSyncState, [String]) {
        guard ledger != nil else { return (.blocked, ["本地长期账本尚未接入"]) }
        let authority = configurationAuthority(reporter: reporter, url: configurationURL)
        guard authority.status == .ready, !authority.hostname.isEmpty else {
            return (.blocked, ["全量同步需要完整且可恢复的远端协议配置"])
        }
        guard let baseURL = URL(string: status.ingestBaseURL), TokenUsageReporter.isValidBaseURL(baseURL) else {
            return (.blocked, ["API 地址无效，无法全量同步"])
        }
        guard let configuration = try? TokenUsageReporter.loadConfiguration(from: configurationURL),
              configuration.isFullSyncReady,
              configuration.fullSyncConfiguration(baseURL: baseURL, hostname: authority.hostname) != nil else {
            return (.blocked, ["全量同步需要完整且可恢复的远端协议配置"])
        }
        return (.ready, [])
    }

    /// init 期 readiness 判定：此时尚无 TokenSyncStatus，直接以已解析的配置权威/地址判定，
    /// 与 fullSyncReadiness 语义一致。
    private static func initialFullSyncReadiness(
        reporter: TokenUsageReporter,
        configurationURL: URL,
        ingestBaseURL: String,
        authorityStatus: TokenReportingConfigurationStatus,
        authorityHostname: String,
        hasLedger: Bool
    ) -> (TokenFullSyncState, [String]) {
        guard hasLedger else { return (.blocked, ["本地长期账本尚未接入"]) }
        guard authorityStatus == .ready, !authorityHostname.isEmpty else {
            return (.blocked, ["全量同步需要完整且可恢复的远端协议配置"])
        }
        guard let baseURL = URL(string: ingestBaseURL), TokenUsageReporter.isValidBaseURL(baseURL) else {
            return (.blocked, ["API 地址无效，无法全量同步"])
        }
        guard let configuration = try? TokenUsageReporter.loadConfiguration(from: configurationURL),
              configuration.isFullSyncReady,
              configuration.fullSyncConfiguration(baseURL: baseURL, hostname: authorityHostname) != nil else {
            return (.blocked, ["全量同步需要完整且可恢复的远端协议配置"])
        }
        return (.ready, [])
    }

    /// 全量同步状态目录：AppSupport/AgentPulse/full-sync/<safe-name>-<sha256 短 hash>。
    /// hostname 先做文件系统安全化，再拼接对**原始** hostname 的 SHA256 短 hash：安全化可能把
    /// 不同 hostname 折叠成同一 safe-name（如 "a/b" 与 "a_b"），附加原始 hash 可保证不同 hostname
    /// 永不共享同一状态目录，避免跨 host 的 full-sync 状态互相污染。
    nonisolated private static func fullSyncStateDirectory(hostname: String) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base
            .appending(path: "AgentPulse", directoryHint: .isDirectory)
            .appending(path: "full-sync", directoryHint: .isDirectory)
            .appending(path: stateDirectoryComponent(hostname), directoryHint: .isDirectory)
    }

    /// 稳定的单一安全路径分量：<safe-name>-<sha256 前 16 hex>。safe-name 供人读，短 hash 防碰撞。
    nonisolated private static func stateDirectoryComponent(_ hostname: String) -> String {
        "\(sanitizedHostname(hostname))-\(stableShortHash(hostname))"
    }

    /// 把 hostname 映射为单一安全路径分量：仅保留字母数字/点/连字符/下划线，其余替换为下划线；
    /// 空结果回落到确定性占位，绝不产生空分量或路径穿越。
    nonisolated private static func sanitizedHostname(_ hostname: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var mapped = String(hostname.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        // 防御性：去掉纯点分量（"." / ".."）与前导点导致的隐藏/穿越语义。
        while mapped.hasPrefix(".") { mapped.removeFirst() }
        if mapped.isEmpty || mapped.allSatisfy({ $0 == "." }) { mapped = "host" }
        return mapped
    }

    /// 原始 hostname 的稳定 SHA256 短 hash（前 16 位小写 hex）。确定性、跨进程一致，用于防碰撞。
    nonisolated private static func stableShortHash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// 全量同步错误脱敏文案：覆盖核心围栏/传输/身份错误与账本围栏，绝不泄露凭证或原始响应体。
    nonisolated private static func fullSyncErrorText(_ error: Error) -> String {
        switch error {
        case FullSyncError.configurationMissing:
            return "全量同步配置不完整"
        case FullSyncError.invalidURL:
            return "API 地址无效"
        case FullSyncError.authIdentityMissing, FullSyncError.authIdentityUnverifiable:
            return "无法验证凭证账号，全量同步已被阻止"
        case FullSyncError.authIdentityChanged:
            return "凭证账号不一致，全量同步已被阻止"
        case FullSyncError.notAuthenticated:
            return "凭证无效或已过期"
       case FullSyncError.rescanRequired:
           return "本地数据已变化，请重新采集后再全量同步"
        case FullSyncError.stateInvalidated:
            return "远端已作废本次全量同步，请重新采集后再试"
        case FullSyncError.rejoinRequired:
            return "凭证或会话已失效，请重新登录后再全量同步"
        case FullSyncError.unsupported:
            return "远端暂不支持全量同步"
        case FullSyncError.payloadTooLarge:
            return "单块数据超过大小上限，无法全量同步"
        case FullSyncError.chunkDigestMismatch:
            return "本地暂存数据校验失败，请重试全量同步"
        case FullSyncError.acknowledgementCountMismatch:
            return "远端确认计数不一致，全量同步未完成"
        case let FullSyncError.httpFailure(statusCode):
            return "全量同步失败（HTTP \(statusCode)）"
        case FullSyncError.transportFailure:
            return "网络传输失败，请稍后重试"
        case FullSyncError.malformedResponse:
            return "全量同步响应无法解析"
        case FullSyncError.corruptState:
            return "本地全量同步状态损坏，请重试"
        case let FullSyncError.invalidFenceRevision(revision):
            return "远端围栏版本无效（\(revision)）"
        default:
            return errorText(error)
        }
    }

    /// 应用启动：触发首轮 scan（本地采集开启时）并按需串接上报；
    /// 若上报已启用则同时启动 30 分钟循环。多次调用幂等。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // 启动即刷新配置权威与全量同步 readiness，使 UI 一开始就反映真实能力。
        refreshConfigurationAuthority()
        // 崩溃安全恢复的最高优先级：存在 rebuild pending（上次已 reset 清库但未确认全部来源
        // 重扫成功）时，绝不能 resumeFullSync / performFullSync / 普通 report（即不发任何网络
        // 请求）。必须先完整重扫全部 configured roots；仅当所有来源无致命失败、pending 被显式
        // 清除后，finishScan 才恢复正常启动链路（恢复全量同步 / 上报）。
        // 空库 + 债务 + pending 场景同样先重扫，不因存在 full-sync 债务而先行恢复上报。
        if isRebuildCompletionPending() {
            rebuildRecoveryPending = true
            if statusSubject.value.localCollectionEnabled {
                scanNow(chainedReport: false)
            }
            // 采集关闭时无法自动重扫：保持 pending，等待用户开启本地采集或手动扫描，
            // 期间仍禁止一切网络动作。不启动自动上报循环。
            return
        }
        // 必须先恢复可恢复的 full-sync state，再启动新的扫描。若远端已经 committed、
        // 本地 ledger commit 尚未完成，先扫描可能推进 generation，使恢复被永久围栏。
        if resumeFullSyncIfPending() {
            startAutoLoopIfNeeded()
            return
        }
        if statusSubject.value.localCollectionEnabled {
            triggerScanThenReport()
        } else if statusSubject.value.reportingEnabled {
            reportNow()
        }
        startAutoLoopIfNeeded()
    }

    /// 是否存在未确认完成的 rebuild（只读；账本不可用时视作无）。
    private func isRebuildCompletionPending() -> Bool {
        guard let ledger else { return false }
        // 网络门禁：只要存在「parser 显式重建未确认完成」或「文件已 replace 但派生尚未成功
        // 重算（raw derivation dirty）」任一挂起，都必须 fail-closed，绝不发任何网络请求。
        let rebuildPending = (try? ledger.requiresRebuildCompletion()) ?? false
        let derivationPending = (try? ledger.requiresDerivationCompletion()) ?? false
        return rebuildPending || derivationPending
    }

    /// rebuild pending 期间完成一次全量重扫后：清除恢复标记并驱动正常启动链路
    /// （恢复可续的全量同步，否则按开关扫描/上报），最后按需启动自动上报循环。
    private func resumeStartupAfterRebuildRecovery() {
        rebuildRecoveryPending = false
        guard isRunning else { return }
        if resumeFullSyncIfPending() {
            startAutoLoopIfNeeded()
            return
        }
        if statusSubject.value.reportingEnabled {
            reportNow()
        }
        startAutoLoopIfNeeded()
    }

    /// 启动恢复：枚举“存在待恢复全量同步工作”的 hostname，据 readiness 分流恢复。
    ///
    /// 关键（P1 修复）：hostname 变更后，remote finalize 已完成但本地 ledger commit 尚未落地时
    /// 崩溃，可恢复的 state 落在**旧 host** 的状态目录，且账本对该旧 host 记着 reconciliation 债务。
    /// 若只看当前配置/本地 hostname，旧 host 的 state 永远发现不了：reconciliation gate 会持续
    /// 全局 fail-closed 阻断增量上报，直到用户手动再次触发全量同步。因此这里必须枚举
    /// pendingReconciliationHosts() 得到的债务 host（连同当前有效 hostname），逐个检查其状态目录，
    /// 只要**任一** host 存在持久化 state 或对账债务，就认定有待恢复工作。
    ///
    /// 分流：
    /// - readiness 就绪：触发 runFullSync（其 worker 会优先选择债务 host、命中已有 state 时对
    ///   remote-committed 场景零网络重放），完成本地 ledger commit + finalize，闭合
    ///   remote-ack → ledger-commit 窗口，并清除旧 host 的对账债务；
    /// - 配置缺失/未就绪：无法安全恢复，给出“待恢复”提示（不改动 state/gate，等配置补齐后再来）。
    @discardableResult
    private func resumeFullSyncIfPending() -> Bool {
        // 已有在途任务或非法前置，跳过。
        guard fullSyncTask == nil, scanTask == nil, reportTask == nil, let ledger else { return false }
        // rebuild / raw-derivation pending 期间绝不恢复/发起全量同步：先完整重扫全部来源、
        // 成功 finalize 并清除全部 pending 后才允许任何网络动作。
        if isRebuildCompletionPending() { return false }

        // 候选 host 集合 = 账本对账债务 host ∪ 当前有效 hostname（配置权威优先，其次用户保存值）。
        // 债务 host 可能与当前 hostname 不同（改名后的旧 host），绝不能只看当前配置。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL)
        let storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")
        let currentHostname = authority.hostname.isEmpty ? storedHostname : authority.hostname
        let debtHosts = (try? ledger.pendingReconciliationHosts()) ?? []

        var candidates: [String] = debtHosts
        if !currentHostname.isEmpty, !candidates.contains(currentHostname) {
            candidates.append(currentHostname)
        }

        // 是否存在待恢复工作：任一候选 host 有持久化 state（可续传）或有对账债务（需空全量同步清远端残留）。
        let hasResumableState = candidates.contains { host in
            guard let directory = try? Self.fullSyncStateDirectory(hostname: host) else { return false }
            return FullSyncStateStore(directory: directory).hasState()
        }
        let hasPending = hasResumableState || !debtHosts.isEmpty
        guard hasPending else { return false }

        // 有待恢复工作：按当前 readiness 分流。
        let (readiness, _) = Self.fullSyncReadiness(
            reporter: reporter,
            configurationURL: configurationURL,
            status: statusSubject.value,
            ledger: ledger
        )
        if readiness == .ready {
            // runFullSync 的 worker 会 pendingReconciliationHosts().first 优先恢复旧 host，
            // 对已有 state 命中幂等 committed 分支（零网络），并重跑 ledger commit + finalize。
            runFullSync()
        } else {
            // 配置未就绪：无法安全恢复，明确提示待恢复，等待用户补齐配置。
            fullSyncLastResultNote = "检测到未完成的全量同步，配置就绪后可自动恢复（待恢复）"
            refreshFullSyncReadiness()
        }
        return true
    }

    /// 停止：取消 auto loop + 扫描 + 上报任务，并递增 generation
    /// 使得任何旧的完成回调都被判定为过期，避免覆盖 stop 之后启动的新任务。
    func stop() {
        isRunning = false
        autoLoopTask?.cancel()
        autoLoopTask = nil
        reportAfterCurrentScan = false
        // 清除 rebuild 恢复标记：下次 start() 会重新读取账本 pending 状态并重新分流。
        rebuildRecoveryPending = false
        scanTask?.cancel()
        scanTask = nil
        scanGeneration &+= 1
        reportTask?.cancel()
        reportTask = nil
        reportGeneration &+= 1
        // 取消在途全量同步：递增 generation 使旧回调过期，不清 state/gate（可恢复），
        // 且状态不得停留在 .running——回落到当前 readiness（.ready/.blocked，附上次结果文案）。
        fullSyncTask?.cancel()
        fullSyncTask = nil
        fullSyncGeneration &+= 1
        if statusSubject.value.fullSyncState == .running {
            updateStatus { $0.fullSyncState = .blocked }
            refreshFullSyncReadiness()
        }
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
        // rebuild pending 期间不启动自动上报循环（不发网络请求）。
        guard autoLoopTask == nil, isRunning, statusSubject.value.reportingEnabled,
              !isRebuildCompletionPending() else { return }
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
        let summary: TokenUsageSummary
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
        // 配置/地址/hostname 变化会影响全量同步能力：动态刷新 readiness。
        refreshFullSyncReadiness()
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

    /// 解析 cliproxy 配置路径：UserDefaults 只存路径（不含凭证），为空回退默认。
    private static func cliProxyConfigPath(defaults: UserDefaults) -> String {
        CliProxyUsageService.resolveConfigPath(
            saved: defaults.string(forKey: CliProxyUsageService.configPathDefaultsKey)
        )
    }

    nonisolated private static var codexSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    }

    nonisolated private static var codexArchivedSessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/archived_sessions")
    }

    nonisolated private static var claudeProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/projects")
    }

    /// 可选本地采集来源配置文件（owner-only 0600），与 reporting.json 同目录、独立文件。
    nonisolated private static func defaultLocalCollectionURL() -> URL {
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )) ?? FileManager.default.temporaryDirectory
        return directory.appending(path: "AgentPulse/local-sources.json")
    }

    /// 读取并校验本地采集来源；任何失败（权限/格式）都降级为空，不影响内建来源采集。
    nonisolated private static func loadLocalCollectionSources(url: URL) -> [LocalCollectionSource] {
        ((try? LocalCollectionConfigurationLoader.load(from: url)) ?? .empty).sources
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
    nonisolated private static func errorText(_ error: Error) -> String {
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
             TokenProviderError.unsuccessfulResponse, TokenProviderError.missingToken,
             TokenProviderError.timedOut:
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

    private func publish(_ summary: TokenUsageSummary) {
        summarySubject.send(summary)
    }

    /// 四个窗口共享同一参考时刻、时区与 hostname，并且全部从 derived bucket 查询。
    nonisolated private static func summaries(
        from ledger: UsageLedgerStore,
        hostname: String,
        containing date: Date,
        calendar: Calendar
    ) throws -> TokenUsageSummary {
        return TokenUsageSummary(
            day: try ledger.summary(
                window: .day,
                containing: date,
                hostname: hostname,
                calendar: calendar
            ).map(windowSummary(from:)),
            month: try ledger.summary(
                window: .month,
                containing: date,
                hostname: hostname,
                calendar: calendar
            ).map(windowSummary(from:)),
            year: try ledger.summary(
                window: .year,
                containing: date,
                hostname: hostname,
                calendar: calendar
            ).map(windowSummary(from:)),
            all: try ledger.summary(
                window: nil,
                containing: date,
                hostname: hostname,
                calendar: calendar
            ).map(windowSummary(from:))
        )
    }

    nonisolated private static func windowSummary(from summary: UsageSummary) -> TokenUsageWindowSummary {
        TokenUsageWindowSummary(
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
            let ownerOnlyDirectoryPermissions = NSNumber(value: Int16(0o700))
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: ownerOnlyDirectoryPermissions]
            )
            // createDirectory does not tighten an existing directory. Apply the
            // owner-only mode explicitly so the database path cannot be traversed
            // by another local account even when it was created by an older build.
            try FileManager.default.setAttributes(
                [.posixPermissions: ownerOnlyDirectoryPermissions],
                ofItemAtPath: directory.path
            )
            return try UsageLedgerStore(path: directory.appending(path: "usage.sqlite3").path)
        } catch { return nil }
    }

    /// 扫描单一来源根目录：逐 jsonl 文件按 checkpoint 跳过未变更文件，
    /// 变更文件解析后同时写入 token 事件与 session 事件。不触发派生重算。
    /// 扫描单个来源根目录。includeSubagents 控制是否把 subagents/agent-*.jsonl 视为子代理转录
    /// （计入 token、不产 session 事件）。内建 codex 传 false，claude-compatible 来源可开启。
    /// 返回本次在磁盘上实际枚举到的该来源文件 fileID 列表（present set）。调用方据此在扫描
    /// 全部 root 后按 source 聚合，交给 Ledger 标记「磁盘已消失」文件为 missing（保留 raw 历史）。
    @discardableResult
    nonisolated private static func scan(root: URL, source: String, includeSubagents: Bool = false, ledger: UsageLedgerStore, hostname: String, cancellation: CancellationGate) throws -> [String] {
        // 不存在的来源根目录：无需扫描，视作该来源“无内容”（非失败）。
        // 但根目录存在却无法枚举，属致命失败：绝不能当作扫描成功静默吞掉，
        // 否则会在数据缺失的情况下清除 rebuild pending / 误判“全量成功”。
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else {
            throw TokenSyncScanError.sourceRootNotEnumerable(source: source)
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            throw TokenSyncScanError.sourceRootNotEnumerable(source: source)
        }
        var presentFileIDs: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            try cancellation.throwIfCancelled()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let modifiedAt = values.contentModificationDate ?? Date.distantPast
            let fileID = UsageJSONLParser.fileID(for: url.path)
            presentFileIDs.append(fileID)
            if let checkpoint = try ledger.checkpoint(fileID: fileID),
               checkpoint.status == "complete",
               checkpoint.size == fileSize,
               abs(checkpoint.modifiedAt.timeIntervalSince(modifiedAt)) < 0.001,
               checkpoint.parserVersion == UsageJSONLParser.parserVersion {
                continue
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let parsed = UsageJSONLParser.parse(
                data: data,
                source: source,
                fileIdentity: url.path,
                modifiedAt: modifiedAt,
                isSubagent: includeSubagents && isClaudeSubagentTranscript(url)
            )
            try ledger.record(
                events: parsed.events,
                sessionEvents: parsed.sessionEvents,
                editEntries: parsed.editEntries,
                editMetricsSupported: true,
                checkpoint: parsed.checkpoint,
                hostname: hostname
            )
        }
        return presentFileIDs
    }

    /// Claude Task 子代理转录的稳定磁盘布局：`subagents/agent-*.jsonl`。
    /// 子代理用量计入总量，但不会生成独立 session 聚合。
    nonisolated private static func isClaudeSubagentTranscript(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
            && url.deletingLastPathComponent().lastPathComponent == "subagents"
    }
}
