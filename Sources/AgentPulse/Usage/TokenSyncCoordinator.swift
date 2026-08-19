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

/// off-main worker 向主线程回报的一次进度快照（Sendable）。
/// 只含聚合数（阶段、已完成/总数计数、整体百分比），不含路径或正文。
private struct ScanProgressUpdate: Sendable {
    let phase: TokenScanPhase
    /// 当前阶段的已完成 / 总数（量纲随阶段：文件 / 事件 / 步 / 窗口 / 行）。
    let done: Int
    let total: Int
    /// 整体进度 0~1（跨阶段带权重累加）。
    let overall: Double
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
        static let autoReportInterval = "tokenSync.autoReportIntervalSeconds"
    }

    private let defaults: UserDefaults
    private let ledger: UsageLedgerStore?
    private let configurationURL: URL
    /// 合并 env 文件（凭证 + 上报简单值 REPORT_BASE_URL / REPORT_CANONICAL_HOSTNAME 的单一来源）。
    private let mergedEnvURL: URL
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
    /// 当自动上报在已有扫描期间被触发时，记住“扫描结束后上报”的意图。
    /// 关闭上报或 stop() 会清空，避免过期动作越过用户当前设置。
    private var reportAfterCurrentScan = false
    /// 自动上报循环任务；nil 表示当前未启动或已停止。
    private var autoLoopTask: Task<Void, Never>?
    /// 应用生命周期：start() 后置 true；stop() 置 false 后阻止后续自动动作。
    private var isRunning: Bool = false
    /// 启动时检测到 rebuild pending（已 reset 但未确认全部来源重扫成功）：
    /// 置 true 后禁止一切网络动作（普通上报），
    /// 先完整重扫全部来源；扫描成功清除 pending 后，再由 finishScan 恢复正常启动链路。
    private var rebuildRecoveryPending: Bool = false
    /// 设备标识改名确认弹窗：检测到配置权威 hostname 与账本旧 canonical 不一致（.mismatch）时，
    /// 由此回调向用户征询「是否把本地历史一并改名」。参数为 (旧名, 新名, 决策回调)；
    /// 决策回调传 true=确认改名（原地 UPDATE 历史），false=否（仅新名生效、历史保留旧名）。
    /// 由 App 层安装（NSAlert 实现）；缺失时（如无头/测试）默认走非破坏性的「否」路径。
    var hostnameRenamePrompt: ((_ old: String, _ new: String, _ decide: @escaping (Bool) -> Void) -> Void)?
    /// 改名弹窗已弹出、等待用户决策：置位期间不再重复弹窗，避免每轮扫描重复打扰。
    private var pendingHostnamePrompt: Bool = false

    private let summarySubject: CurrentValueSubject<TokenUsageSummary, Never>
    private let statusSubject: CurrentValueSubject<TokenSyncStatus, Never>
    /// 看板 1 天曲线（账本 30min bucket → 平均 TPS）；仅看板选中 1 天时刷新。
    private let daySeriesSubject = CurrentValueSubject<DashboardDaySeries, Never>(.empty)
    /// 看板当前是否停在 1 天视图：为 true 时每轮 scan 完成顺带刷新 day series，否则不做无谓账本查询。
    private var dashboardDayActive = false

    var summary: TokenUsageSummary { summarySubject.value }
    var status: TokenSyncStatus { statusSubject.value }

    var summaryPublisher: AnyPublisher<TokenUsageSummary, Never> {
        summarySubject.eraseToAnyPublisher()
    }

    var statusPublisher: AnyPublisher<TokenSyncStatus, Never> {
        statusSubject.eraseToAnyPublisher()
    }

    var dashboardDaySeriesPublisher: AnyPublisher<DashboardDaySeries, Never> {
        daySeriesSubject.eraseToAnyPublisher()
    }

    /// 自动上报循环周期：启动时执行首轮，之后每隔本间隔触发一次（本机行为，可在设置调整）。
    /// 关闭上报开关 / stop() 时立即取消；改动间隔会重启循环使新值生效。
    private var autoReportInterval: TokenReportInterval

    init(
        defaults: UserDefaults = .standard,
        configurationURL: URL = TokenSyncCoordinator.defaultConfigurationURL(),
        reporter: TokenUsageReporter? = nil,
        cliProxyService: CliProxyUsageService = CliProxyUsageService(),
        usageSummaryCalendar: Calendar = .autoupdatingCurrent
    ) {
        self.defaults = defaults
        self.configurationURL = configurationURL
        // 合并 env 路径：上报的 hostname / base URL 等简单值收敛到此文件（凭证同源）。
        let mergedEnvPath = MergedEnvKeys.resolvePath(saved: defaults.string(forKey: MergedEnvPreferences.pathDefaultsKey))
        self.mergedEnvURL = URL(fileURLWithPath: (mergedEnvPath as NSString).expandingTildeInPath)
        // reporter 默认注入「合成 loader」：解码 reporting.json 纯协议结构后，把 canonicalHostname
        // 覆盖为合并 env 的值——reporting.json 只留协议结构，hostname 权威来自 env。测试可显式注入 reporter。
        let effectiveReporter = reporter ?? TokenSyncCoordinator.makeEnvBackedReporter(envURL: self.mergedEnvURL)
        self.reporter = effectiveReporter
        self.cliProxyService = cliProxyService
        self.usageSummaryCalendar = usageSummaryCalendar
        self.localCollectionURL = TokenSyncCoordinator.defaultLocalCollectionURL()
        ledger = Self.openLedger()

        let localCollection = defaults.object(forKey: DefaultsKey.localCollectionEnabled) as? Bool ?? true
        let storedReporting = defaults.object(forKey: DefaultsKey.reportingEnabled) as? Bool ?? false
        // 自动上报间隔（本机行为，不进上报身份）：缺省 30 分钟；非法值回落 30 分钟。
        let reportInterval = TokenReportInterval.from(
            seconds: defaults.object(forKey: DefaultsKey.autoReportInterval) as? Int ?? TokenReportInterval.default.rawValue
        )
        self.autoReportInterval = reportInterval
        // base URL 权威改为合并 env 的 REPORT_BASE_URL；env 缺失时回落到旧 UserDefaults 值（平滑迁移）。
        let baseURL = Self.envBaseURL(url: self.mergedEnvURL) ?? (defaults.string(forKey: DefaultsKey.ingestBaseURL) ?? "")
        var storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")

        // 配置权威：hostname 以合并 env 的 REPORT_CANONICAL_HOSTNAME 为准；配置未就绪时为空。
        let authority = Self.configurationAuthority(reporter: effectiveReporter, url: configurationURL, envURL: self.mergedEnvURL)
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

        // 冷启动展示账本中所有 hostname 的派生数据。canonical hostname 仅决定后续采集与上报身份。
        let initialSummary: TokenUsageSummary
        if let ledger {
            initialSummary = (try? Self.summaries(
                from: ledger,
                containing: Date(),
                calendar: usageSummaryCalendar,
                mergedEnvURL: self.mergedEnvURL
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
            lastReportSucceeded: nil
        ))
        // status literal 未显式列出的字段走默认值；间隔单独回填以回显持久化档位。
        var initialStatus = statusSubject.value
        initialStatus.autoReportInterval = reportInterval
        statusSubject.send(initialStatus)
    }

    // MARK: - Settings

    func setLocalCollectionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: DefaultsKey.localCollectionEnabled)
        updateStatus { $0.localCollectionEnabled = enabled }
        if enabled {
            // 开启采集：按间隔周期性扫描（不依赖上报开关）。已在跑则 startAutoLoopIfNeeded 幂等不重启。
            startAutoLoopIfNeeded()
        } else if !statusSubject.value.reportingEnabled {
            // 采集与上报都关：循环无事可做，停掉。
            autoLoopTask?.cancel()
            autoLoopTask = nil
        }
    }

    func setReportingEnabled(_ enabled: Bool) {
        // 关闭永远成功：无论配置状态如何都写盘 false，并停掉自动上报意图。
        // 用户手动在途的 report 不取消（可能还想看结果）；scan 同理不动。
        // 注意：若本地采集仍开着，自动循环需保留以继续周期性扫描（只是不再串接上报）。
        guard enabled else {
            defaults.set(false, forKey: DefaultsKey.reportingEnabled)
            reportAfterCurrentScan = false
            updateStatus { status in
                status.reportingEnabled = false
                status.reportingError = nil
            }
            if statusSubject.value.localCollectionEnabled {
                // 采集仍开：循环继续扫描；此前若因故未启动则补启。
                startAutoLoopIfNeeded()
            } else {
                // 采集也关了：循环无事可做，停掉。
                autoLoopTask?.cancel()
                autoLoopTask = nil
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
            // 上报未就绪不影响本地采集：采集仍开则保留循环继续扫描，否则停掉。
            if statusSubject.value.localCollectionEnabled {
                startAutoLoopIfNeeded()
            } else {
                autoLoopTask?.cancel()
                autoLoopTask = nil
            }
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

    /// 设置自动上报间隔（本机行为，不进上报身份）：写 defaults + 回显 status，
    /// 并重启自动上报循环使新间隔立即生效（若循环当前活跃）。
    func setAutoReportInterval(_ interval: TokenReportInterval) {
        guard interval != autoReportInterval else { return }
        autoReportInterval = interval
        defaults.set(interval.rawValue, forKey: DefaultsKey.autoReportInterval)
        updateStatus { $0.autoReportInterval = interval }
        // 重启循环使新间隔生效：仅当条件仍满足时 startAutoLoopIfNeeded 才会重建。
        autoLoopTask?.cancel()
        autoLoopTask = nil
        startAutoLoopIfNeeded()
    }

    /// 保存上报 base URL：权威落在合并 env 的 REPORT_BASE_URL（0600 写回），不写 UserDefaults。
    func setIngestBaseURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        // 写回合并 env（空串表示清除该键）；写回失败仅记状态，不阻断 UI。
        try? EnvFile.writeBack([MergedEnvKeys.reportBaseURL: trimmed], to: mergedEnvURL)
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

    /// 保存上报 canonical hostname：权威落在合并 env 的 REPORT_CANONICAL_HOSTNAME（0600 写回），
    /// 不写 UserDefaults。写回后以 env 权威刷新状态。
    func setCanonicalHostname(_ hostname: String) {
        let trimmed = Self.normalize(hostname)
        try? EnvFile.writeBack([MergedEnvKeys.reportCanonicalHostname: trimmed], to: mergedEnvURL)
        refreshConfigurationAuthority()
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL, envURL: mergedEnvURL)
        // env 权威优先；env 缺失时采用刚写入的值（trim 归一化后一致）。
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
        // 防重入；且不在上报进行时启动扫描，避免 rebuild 与在途上传竞争。
        guard scanTask == nil, reportTask == nil,
              statusSubject.value.localCollectionEnabled, let ledger else { return }
        refreshConfigurationAuthority()

        // 解析有效 hostname：配置权威优先，否则用户保存的本地 hostname。绝不 fallback Host.current。
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL, envURL: mergedEnvURL)
        let storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")
        let hostname = authority.hostname.isEmpty ? storedHostname : authority.hostname
        guard !hostname.isEmpty else {
            updateStatus { status in
                status.scanningInProgress = false
                status.configurationError = status.configurationError ?? "hostname 未配置，无法采集"
            }
            return
        }

        // 有效 hostname（权威或本地设备标识，此处已保证非空）与账本旧 canonical 不一致时，
        // 弹确认框征询用户，不再静默自动改名；unset 时首次落库即对齐。
        // 触发只依赖 effectiveHostname，不挂 configReady——否则没配 reporting.json、只改本地
        // 设备标识的用户（权威缺失）永远进不到弹窗分支。
        if case let .mismatch(stored) = (try? ledger.hostnameState(current: hostname)) ?? .unset {
            // 已有弹窗等待决策时不重复弹，避免每轮扫描重复打扰；本轮不扫描，待用户决策后再触发。
            guard !pendingHostnamePrompt else {
                updateStatus { $0.scanningInProgress = false }
                return
            }
            presentHostnameMismatch(old: stored, new: hostname)
            updateStatus { $0.scanningInProgress = false }
            return
        }
        // 置位扫描进度：起点为 cliproxy 阶段 0%。文件计数在 scanning 阶段登记。
        updateStatus { status in
            status.scanningInProgress = true
            status.scanPhase = .cliproxy
            status.scanDone = 0
            status.scanTotal = 0
            status.scanProgress = 0
        }

        let currentParserVersion = UsageJSONLParser.parserVersion
        // 在启动后台 Task 前捕获为局部常量：闭包内 self 为弱引用，不能直接访问实例存储属性。
        let localSourcesURL = localCollectionURL
        let summaryCalendar = usageSummaryCalendar
        let summaryEnvURL = self.mergedEnvURL
        scanGeneration &+= 1
        let generation = scanGeneration
        let cliProxyService = self.cliProxyService
        let cliProxyConfigPath = Self.cliProxyConfigPath(defaults: defaults)
        // 进度回调：worker 各阶段 / 逐文件回报聚合快照，跨线程回到主 actor 更新 status；
        // 仅当仍是当前 generation 时才写，避免旧扫描回调覆盖新扫描。
        let progressReporter = ScanProgressReporter { [weak self] update in
            Task { @MainActor in
                self?.applyScanProgress(update, generation: generation)
            }
        }
        scanTask = Task { [weak self] in
            // cliproxy 主动拉取（异步 HTTP）在进入阻塞式文件扫描之前完成；失败仅记状态、
            // 返回空事件，绝不影响本地文件采集与既有链路。
            var cliProxyEvents: [UsageEvent] = []
            var cliProxyError: String?
            let cliProxyConfigured = CliProxyUsageService.isConfigured(atPath: cliProxyConfigPath)
            progressReporter.enterPhase(.cliproxy)
            if cliProxyConfigured {
                do {
                    cliProxyEvents = try await cliProxyService.fetchUsageEvents(atPath: cliProxyConfigPath)
                } catch is CancellationError {
                    // 取消：走后续 cancelled 分支统一处理。
                } catch {
                    cliProxyError = (error as? LocalizedError)?.errorDescription ?? "cliproxyapi 采集失败"
                }
            }
            // 登记本阶段计数：拉取到的事件数（未配置或失败时为 0，则该阶段不显示计数）。
            progressReporter.setPhaseTotal(.cliproxy, total: cliProxyEvents.count)
            progressReporter.completePhase(.cliproxy)
            self?.updateCliProxyStatus(configured: cliProxyConfigured, error: cliProxyError, generation: generation)

            // 绑定为不可变值再进入 @Sendable worker，满足 Swift 6 并发捕获约束。
            let networkEvents = cliProxyEvents
            // 无变化轮跳过全库重算时，上报资格布尔从账本持久标志读回，blocked 原因（未持久化）
            // 沿用上轮：raw 未变则派生不变，原因列表必与上次 finalize 一致。
            let priorBlockedReasons = self?.status.reportingBlockedReasons ?? []
            // 阻塞式 SQLite/文件扫描在后台队列执行（不阻塞主线程），不使用 detached 分叉。
            let result = await Self.runOffMain { gate in
                try gate.throwIfCancelled()
                // hostname 对齐已在启动本 Task 前于主线程处理（mismatch 已由用户弹窗决策为
                // rebuild 或 adopt，account 已对齐；此处账本状态必为 match/unset），无需再判定。
                // 解析器升级或历史非法数据：绝不再 resetForRebuild（那会清空磁盘上已删除历史
                // session 的 raw，无法恢复）。改为设置持久 parser rebuild pending（不清 raw），
                // 随后本轮对所有 configured root 做文件级原子重解析：每个变化文件在 record 内
                // 事务性替换该 fileID 的旧 raw 并置派生 dirty；已消失文件仅标 missing、保留 raw。
                // 仅当所有来源无致命失败、finalize 成功、且达到目标 parser 版本后，才显式清除。
                if try ledger.requiresParserRebuild(currentParserVersion: currentParserVersion) {
                    try ledger.beginParserRebuild(targetParserVersion: currentParserVersion)
                }
                try gate.throwIfCancelled()
                // 进入 scanning 阶段：先枚举全部来源 root 的 jsonl 总数作为进度分母，
                // 再逐文件处理并回报（已处理/总数）。totalFiles 为 0 时进度按阶段权重阶跃。
                let localSources = Self.loadLocalCollectionSources(url: localSourcesURL)
                var scanRoots: [URL] = [Self.codexSessionsRoot, Self.codexArchivedSessionsRoot, Self.claudeProjectsRoot]
                scanRoots += localSources.map(\.root)
                let totalFiles = scanRoots.reduce(0) { $0 + Self.countJSONLFiles(root: $1) }
                progressReporter.setPhaseTotal(.scanning, total: totalFiles)
                // 逐来源扫描并收集磁盘 present fileID；record 只处理变化文件（status!=complete 或
                // size/mtime/parserVersion 不匹配），不触发派生重算。
                // Codex sessions 与 archived_sessions 同为 source="codex"：必须合并两 root 的
                // present 集合后，对 "codex" 只调用一次 markFilesMissing，否则会互相误标 missing。
                var codexPresentFileIDs: [String] = []
                codexPresentFileIDs += try Self.scan(root: Self.codexSessionsRoot, source: "codex", ledger: ledger, hostname: hostname, cancellation: gate, progress: progressReporter)
                try gate.throwIfCancelled()
                // 归档会话不属于运行中 task 口径，但其已产生的 token 仍属于累计用量。
                codexPresentFileIDs += try Self.scan(root: Self.codexArchivedSessionsRoot, source: "codex", ledger: ledger, hostname: hostname, cancellation: gate, progress: progressReporter)
                try gate.throwIfCancelled()
                try ledger.markFilesMissing(source: "codex", presentFileIDs: codexPresentFileIDs)
                try gate.throwIfCancelled()
                let claudePresentFileIDs = try Self.scan(root: Self.claudeProjectsRoot, source: "claude-code", includeSubagents: true, ledger: ledger, hostname: hostname, cancellation: gate, progress: progressReporter)
                try gate.throwIfCancelled()
                try ledger.markFilesMissing(source: "claude-code", presentFileIDs: claudePresentFileIDs)
                try gate.throwIfCancelled()
                // 可选的用户声明本地来源（Claude-compatible transcript）。配置缺失/非法不影响内建来源。
                // 每个自定义 source 独立聚合 present 集合，再各自按 source 标 missing。
                var localPresentBySource: [String: [String]] = [:]
                for local in localSources {
                    let present = try Self.scan(root: local.root, source: local.source, includeSubagents: local.includeSubagents, ledger: ledger, hostname: hostname, cancellation: gate, progress: progressReporter)
                    localPresentBySource[local.source, default: []] += present
                    try gate.throwIfCancelled()
                }
                for (source, present) in localPresentBySource {
                    try ledger.markFilesMissing(source: source, presentFileIDs: present)
                    try gate.throwIfCancelled()
                }
                progressReporter.completePhase(.scanning)
                // cliproxy 主动拉取事件：只写原始层，不写文件 checkpoint（网络来源无偏移语义）。
                try ledger.recordNetworkEvents(networkEvents, source: CliProxyUsageParser.source, hostname: hostname)
                try gate.throwIfCancelled()
                // 全部来源扫描后统一 finalizeDerived：全局去重 + 聚合 + 上报资格门禁。
                // 无变化轮（raw 派生 dirty 位未置 且 无 rebuild 待完成）跳过 O(全库) 重算：
                // 派生已是最新，仅从持久标志读回上报资格，避免每轮全表读+排序（9.4G 库约 90s）。
                progressReporter.enterPhase(.finalizing)
                let needsFinalize = try ledger.requiresDerivationCompletion() || ledger.requiresRebuildCompletion()
                let finalize: UsageFinalizeResult
                if needsFinalize {
                    finalize = try ledger.finalizeDerived(hostname: hostname) { done, total in
                        // 重算内部子阶段回调：映射到 .finalizing 段的 done/total（8 步），显示「3/8 步」。
                        progressReporter.advance(.finalizing, done: done, total: total)
                    }
                } else {
                    // 跳过重算：collapsed 计数本轮为 0（无新折叠工作），eligible 读持久标志，
                    // blocked 原因沿用上轮（raw 未变则不变）。
                    let eligible = try ledger.reportingEligible(hostname: hostname)
                    finalize = UsageFinalizeResult(
                        reportingEligible: eligible,
                        blockedReasons: eligible ? [] : priorBlockedReasons,
                        collapsedInheritedEvents: 0,
                        collapsedContentDuplicates: 0
                    )
                }
                progressReporter.completePhase(.finalizing)
                // 只有在所有来源都完整扫描（无致命失败：任一来源枚举失败 / 单文件 I/O 失败都会
                // 在上面抛出并终止本次扫描，不会到达此处）后，才显式清除 rebuild pending。
                // record/finalize 不会推断重扫已完成，清除是此处唯一入口。
                if try ledger.requiresRebuildCompletion() {
                    try ledger.markRebuildCompleted()
                }
                // summarizing 聚合日/周/月/全部四个窗口：登记总数为窗口数，显示「n/4 窗口」。
                progressReporter.enterPhase(.summarizing, total: TokenUsageWindow.allCases.count)
                let summary = try Self.summaries(
                    from: ledger,
                    containing: Date(),
                    calendar: summaryCalendar,
                    mergedEnvURL: summaryEnvURL
                )
                let pending = try ledger.pendingCounts(hostname: hostname)
                progressReporter.completePhase(.summarizing)
                return ScanOutcome(summary: summary, finalize: finalize, pending: pending)
            }
            let cancelled = Task.isCancelled
            self?.finishScan(generation: generation, cancelled: cancelled, chainedReport: chainedReport, result: result)
        }
    }

    /// 弹出「设备标识改名」确认弹窗（或在无回调时走非破坏性默认），并在用户决策后落地。
    private func presentHostnameMismatch(old: String, new: String) {
        pendingHostnamePrompt = true
        guard let prompt = hostnameRenamePrompt else {
            // 无 UI 回调（无头 / 测试）：默认走「否」——新名生效、历史保留旧名，非破坏且不进入循环。
            resolveHostnameMismatch(old: old, new: new, rename: false)
            return
        }
        prompt(old, new) { [weak self] rename in
            // 决策回调可能在任意线程返回，统一回到主 actor 落地。
            Task { @MainActor in
                self?.resolveHostnameMismatch(old: old, new: new, rename: rename)
            }
        }
    }

    /// 落地用户对设备标识改名的决策：
    /// - rename==true：原地把历史全部改名为新名（rebuildForHostname）。
    /// - rename==false：仅让新名生效、历史保留旧名（adoptHostname）。
    /// 两者都会把 canonical_hostname 更新为新名，因此之后比对为 .match，不再重复弹窗；
    /// 落地后重新触发一次扫描，让新名承接后续采集。
    private func resolveHostnameMismatch(old: String, new: String, rename: Bool) {
        pendingHostnamePrompt = false
        guard let ledger else { return }
        do {
            if rename {
                try ledger.rebuildForHostname(new)
            } else {
                try ledger.adoptHostname(new)
            }
        } catch {
            updateStatus { $0.configurationError = "设备标识改名失败" }
            return
        }
        // 新名已生效，重新触发扫描；此时 hostnameState 为 .match，不会再弹窗。
        if isRunning, statusSubject.value.localCollectionEnabled { scanNow(chainedReport: false) }
    }

    /// 把 cliproxy 采集配置状态与错误刷新到 UI（只在当前 generation 有效时）。
    private func updateCliProxyStatus(configured: Bool, error: String?, generation: UInt64) {
        guard generation == scanGeneration else { return }
        updateStatus { status in
            status.cliProxyConfigured = configured
            status.cliProxyError = error
        }
    }

    /// 应用一次扫描进度快照（只在当前 generation 且仍在扫描时写；旧扫描回调直接忽略）。
    private func applyScanProgress(_ update: ScanProgressUpdate, generation: UInt64) {
        guard generation == scanGeneration, statusSubject.value.scanningInProgress else { return }
        updateStatus { status in
            status.scanPhase = update.phase
            status.scanDone = update.done
            status.scanTotal = update.total
            status.scanProgress = update.overall
        }
    }

    private func finishScan(generation: UInt64, cancelled: Bool, chainedReport: Bool, result: Result<ScanOutcome, Error>) {
        // 只处理当前 generation 的完成回调；旧任务被取消后再回到主线程时，
        // 若新任务已启动，generation 会不同，直接忽略避免覆盖新句柄。
        guard generation == scanGeneration else { return }
        scanTask = nil
        if cancelled {
            reportAfterCurrentScan = false
            updateStatus { Self.clearScanProgress(&$0) }
            return
        }
        switch result {
        case let .success(outcome):
            publish(outcome.summary)
            // 看板停在 1 天视图时，随本轮扫描顺带刷新账本曲线（30min 粒度，实时性要求低）。
            if dashboardDayActive { refreshDashboardDaySeries(active: true) }
            updateStatus { status in
                status.lastScanAt = Date()
                Self.clearScanProgress(&status)
                status.configurationError = nil
                status.reportingEligible = outcome.finalize.reportingEligible
                status.reportingBlockedReasons = outcome.finalize.blockedReasons
                status.pendingBuckets = outcome.pending.buckets
                status.pendingSessions = outcome.pending.sessions
            }
            // rebuild pending 恢复路径：本次扫描已完整跑完全部来源（无致命失败），
            // 且 off-main 已在 finalize 后清除 pending。此处确认已清除后再恢复正常启动链路
            // （恢复上报）。若因某种原因仍未清除，则保持 pending、绝不发网络请求。
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
            updateStatus { Self.clearScanProgress(&$0) }
        case .failure:
            reportAfterCurrentScan = false
            // 扫描失败（含来源目录枚举失败、单文件 I/O 失败）：保持 rebuild pending，
            // 绝不清除、绝不发网络请求。恢复标记保留，待下次扫描重试。
            updateStatus { status in
                Self.clearScanProgress(&status)
                status.configurationError = "本地扫描失败"
            }
        }
    }

    /// 复位扫描进度展示字段：结束扫描时把百分比 / 文件计数 / 阶段清零。
    private static func clearScanProgress(_ status: inout TokenSyncStatus) {
        status.scanningInProgress = false
        status.scanPhase = nil
        status.scanDone = 0
        status.scanTotal = 0
        status.scanProgress = nil
    }

    // MARK: - Report

    func reportNow() {
        // 防重入；且不在扫描进行时上报，避免与 rebuild 竞争。
        guard reportTask == nil, scanTask == nil else { return }
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
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL, envURL: mergedEnvURL)
        guard !authority.hostname.isEmpty else {
            updateStatus { $0.reportingError = "hostname 未配置，禁止上报" }
            return
        }
        guard let baseURL = URL(string: current.ingestBaseURL), TokenUsageReporter.isValidBaseURL(baseURL) else {
            updateStatus { $0.reportingError = "API 地址无效" }
            return
        }
        let hostname = authority.hostname
        // 上报阶段进度：展示待上报行数（buckets+sessions）作为 .reporting 阶段计数「n/m 行」。
        // reporter.report 为不透明网络 I/O，不逐行回报，故仅在起止两端登记总数与完成。
        let pendingRows = (try? ledger.pendingCounts(hostname: hostname)).map { $0.buckets + $0.sessions } ?? 0
        updateStatus { status in
            status.reportingInProgress = true
            status.reportingError = nil
            status.scanPhase = .reporting
            status.scanDone = 0
            status.scanTotal = pendingRows
            status.scanProgress = TokenScanPhase.reporting.baseProgress
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
        // 上报结束：清除 .reporting 阶段的进度字段，避免残留状态泄漏到后续读取。
        updateStatus { Self.clearScanProgress(&$0) }
    }

    /// 应用启动：触发首轮 scan（本地采集开启时）并按需串接上报；
    /// 本地采集或上报任一开启时启动自动循环（采集驱动周期扫描，不依赖上报开关）。多次调用幂等。
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // 启动即刷新配置权威，使 UI 一开始就反映真实能力。
        refreshConfigurationAuthority()
        // 崩溃安全恢复的最高优先级：存在 rebuild pending（上次已 reset 清库但未确认全部来源
        // 重扫成功）时，绝不发任何网络请求（普通 report）。必须先完整重扫全部 configured roots；
        // 仅当所有来源无致命失败、pending 被显式清除后，finishScan 才恢复正常启动链路（上报）。
        if isRebuildCompletionPending() {
            rebuildRecoveryPending = true
            if statusSubject.value.localCollectionEnabled {
                scanNow(chainedReport: false)
            }
            // 采集关闭时无法自动重扫：保持 pending，等待用户开启本地采集或手动扫描，
            // 期间仍禁止一切网络动作。不启动自动上报循环。
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
    /// （按开关扫描/上报），最后按需启动自动上报循环。
    private func resumeStartupAfterRebuildRecovery() {
        rebuildRecoveryPending = false
        guard isRunning else { return }
        if statusSubject.value.reportingEnabled {
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
        // 清除 rebuild 恢复标记：下次 start() 会重新读取账本 pending 状态并重新分流。
        rebuildRecoveryPending = false
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

    /// 在「本地采集或上报」任一开启且未启动过时创建自动循环任务。
    /// 循环内每轮先判断当前开关，一旦采集与上报都被关掉即退出，不再触发。
    private func startAutoLoopIfNeeded() {
        // rebuild pending 期间不启动自动上报循环（不发网络请求）。
        // 采集开启即可周期性扫描（不依赖上报开关）；上报另需其自身就绪，由循环体内分支决定。
        let status = statusSubject.value
        guard autoLoopTask == nil, isRunning,
              status.localCollectionEnabled || status.reportingEnabled,
              !isRebuildCompletionPending() else { return }
        autoLoopTask = Task { [weak self] in
            let interval = self?.autoReportInterval.seconds ?? TokenReportInterval.default.seconds
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } catch { return }
                guard let self, self.isRunning else { return }
                let current = self.statusSubject.value
                // 采集或上报都关了才退出循环；否则按当前开关驱动扫描 / 上报。
                guard current.localCollectionEnabled || current.reportingEnabled else { return }
                if current.localCollectionEnabled {
                    // 采集开启：扫描一轮；是否串接上报由 finishScan 按 reportingEnabled 再校验。
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

    /// 读取上报权威：hostname 来自合并 env 的 REPORT_CANONICAL_HOSTNAME；配置就绪状态走注入了
    /// env-hostname 的 reporter.configurationStatus（reporting.json 只提供纯协议结构）。
    /// 配置缺失 / env-hostname 空时 hostname 为空，但仍允许纯本地采集。
    private static func configurationAuthority(
        reporter: TokenUsageReporter,
        url: URL,
        envURL: URL
    ) -> ConfigurationAuthority {
        let status = reporter.configurationStatus(for: url)
        let hostname = envCanonicalHostname(url: envURL)
        return ConfigurationAuthority(hostname: hostname, status: status, errorText: errorText(for: status))
    }

    /// 构造 env 支撑的 reporter：注入 configurationLoader，把 reporting.json 解码为纯协议结构后，
    /// 用合并 env 的 REPORT_CANONICAL_HOSTNAME 覆盖 canonicalHostname，使 reporter 内部围栏/就绪判定
    /// 均以 env hostname 为准，reporting.json 无需再携带 hostname 权威。
    private static func makeEnvBackedReporter(envURL: URL) -> TokenUsageReporter {
        TokenUsageReporter(configurationLoader: { configURL in
            var configuration = try TokenUsageReporter.loadConfiguration(from: configURL)
            configuration.canonicalHostname = envCanonicalHostname(url: envURL)
            return configuration
        })
    }

    /// 从合并 env 读取并归一化 REPORT_CANONICAL_HOSTNAME；文件缺失/非法/键缺失时返回空串。
    nonisolated private static func envCanonicalHostname(url: URL) -> String {
        guard let environment = try? EnvFile.load(url: url),
              let raw = environment[MergedEnvKeys.reportCanonicalHostname] else { return "" }
        return CanonicalHostname.normalize(raw)
    }

    /// 从合并 env 读取 REPORT_BASE_URL（trim）；缺失/非法时返回 nil，调用方回落旧值。
    nonisolated private static func envBaseURL(url: URL) -> String? {
        guard let environment = try? EnvFile.load(url: url),
              let raw = environment[MergedEnvKeys.reportBaseURL]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    /// 刷新配置状态与权威 hostname / base URL 到 UI；配置就绪但 baseURL/hostname 缺失时禁用上报。
    private func refreshConfigurationAuthority() {
        let authority = Self.configurationAuthority(reporter: reporter, url: configurationURL, envURL: mergedEnvURL)
        let storedHostname = Self.normalize(defaults.string(forKey: DefaultsKey.canonicalHostname) ?? "")
        let effective = authority.hostname.isEmpty ? storedHostname : authority.hostname
        // base URL 权威同为合并 env；env 缺失时保留当前 status（可能来自旧 UserDefaults 迁移值）。
        let envBaseURL = Self.envBaseURL(url: mergedEnvURL)
        var stopAutoLoop = false
        updateStatus { status in
            status.configurationStatus = Self.presentationStatus(authority.status)
            status.configurationError = authority.errorText
            status.canonicalHostname = effective.isEmpty ? nil : effective
            if let envBaseURL { status.ingestBaseURL = envBaseURL }
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

    /// worker 内的进度累加器：把「阶段权重 + scanning 逐文件计数」折算成整体 0~1，
    /// 并把聚合快照回调给主线程。只在 worker 队列上顺序调用，无需加锁。
    /// 只搬运聚合数（阶段、文件计数、百分比），绝不携带路径 / 正文 / 凭证。
    private final class ScanProgressReporter: @unchecked Sendable {
        private let emit: @Sendable (ScanProgressUpdate) -> Void
        // 通用「已完成 / 总数」计数：每个阶段各自登记自己的量纲（文件 / 事件 / 步 / 窗口 / 行），
        // 阶段切换时清零重置，供 scanDetail 统一显示「done/total 单位」。
        private var total = 0
        private var done = 0

        init(_ emit: @escaping @Sendable (ScanProgressUpdate) -> Void) {
            self.emit = emit
        }

        /// 进入某阶段：清零本阶段计数并按已完成阶段权重报出阶段起点（阶跃）。
        /// `total` 已知时同时登记，未知（0）则本阶段先不显示计数、待后续 setPhaseTotal 补登。
        func enterPhase(_ phase: TokenScanPhase, total: Int = 0) {
            self.total = max(0, total)
            self.done = 0
            send(phase: phase, fraction: 0)
        }

        /// 完成某阶段：报出阶段终点（满权重），并把已完成计数对齐到总数。
        func completePhase(_ phase: TokenScanPhase) {
            if total > 0 { done = total }
            send(phase: phase, fraction: 1)
        }

        /// 登记当前阶段的总数（如 scanning 多来源枚举后一次性得到文件总数）。
        func setPhaseTotal(_ phase: TokenScanPhase, total: Int) {
            self.total = max(0, total)
            self.done = 0
            send(phase: phase, fraction: 0)
        }

        /// 当前阶段完成一项：自增并按 done/total 回报（含计数）。
        func advanceItem(_ phase: TokenScanPhase) {
            done += 1
            let fraction = total > 0 ? Double(done) / Double(total) : 1
            send(phase: phase, fraction: fraction)
        }

        /// 按外部给定的 done/total 推进当前阶段（如 finalize 的 8 子阶段）。
        func advance(_ phase: TokenScanPhase, done: Int, total: Int) {
            self.total = max(0, total)
            self.done = max(0, min(done, self.total))
            let fraction = total > 0 ? Double(done) / Double(total) : 1
            send(phase: phase, fraction: fraction)
        }

        private func send(phase: TokenScanPhase, fraction: Double) {
            let clamped = min(max(fraction, 0), 1)
            let overall = min(phase.baseProgress + clamped * phase.weight, 1)
            emit(ScanProgressUpdate(
                phase: phase,
                done: done,
                total: total,
                overall: overall
            ))
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

    /// 刷新看板 1 天曲线：off-main 读取所有 hostname 的 30min bucket → 换算平均 TPS →
    /// 回主线程 send。仅在看板选中 1 天时由 App 触发（span 切换 + 每轮 scan 完成）。
    /// 账本不可用时发空序列（视图显示无数据），绝不阻塞主线程。
    /// `active` 标记看板是否停在 1 天视图：true 时后续每轮 scan 完成会自动刷新。
    func refreshDashboardDaySeries(active: Bool = true, now: Date = Date()) {
        dashboardDayActive = active
        guard active else { return }
        guard let ledger else {
            daySeriesSubject.send(.empty)
            return
        }
        Task { [weak self] in
            let result = await Self.runOffMain { _ in
                try Self.buildDaySeries(from: ledger, now: now)
            }
            await MainActor.run {
                guard let self else { return }
                if case let .success(series) = result {
                    self.daySeriesSubject.send(series)
                }
                // 失败保持上次值（不覆盖为空，避免闪烁）。
            }
        }
    }

    /// 账本里非真实模型的占位名（合成锚点事件的 model），无真实 output，恒 0 TPS。
    nonisolated private static let syntheticModelPlaceholder = "<synthetic>"
    /// 未知 / 占位模型统一归入的展示名，与账本缺省口径一致。
    nonisolated private static let unknownModelName = "n"

    /// 把账本 model 归一为展示用名：合成占位与空串收敛到 unknown，其余原样返回。
    /// 由此 `<synthetic>` 等占位不再单独成行，而是并入 unknown。
    nonisolated private static func displayModelName(_ model: String) -> String {
        model.isEmpty || model == syntheticModelPlaceholder ? unknownModelName : model
    }

    /// off-main：从账本读 [now-24h, now) 的 30min output bucket，换算成 48 桶平均 TPS 曲线（总 + 分模型）。
    nonisolated private static func buildDaySeries(
        from ledger: UsageLedgerStore,
        now: Date
    ) throws -> DashboardDaySeries {
        let span = DashboardTPSSpan.oneDay
        let start = now.addingTimeInterval(-span.totalSeconds)
        let totalBuckets = try ledger.outputTokenBuckets(start: start, end: now)
        let modelBuckets = try ledger.outputTokenBucketsByModel(start: start, end: now)
        let total = SparklineAnalysis.makeUsageLedgerTPSPoints(buckets: totalBuckets, end: now)

        var byModel: [String: [(bucketStart: Date, outputTokens: Int64)]] = [:]
        var modelOutputSum: [String: Int64] = [:]
        for row in modelBuckets {
            // 归一后 `<synthetic>` 等占位并入 unknown，同名跨 bucket 累加，不再单独成行。
            let model = displayModelName(row.model)
            byModel[model, default: []].append((row.bucketStart, row.outputTokens))
            modelOutputSum[model, default: 0] += row.outputTokens
        }
        var perModel: [String: [SparklinePoint]] = [:]
        for (model, buckets) in byModel {
            perModel[model] = SparklineAnalysis.makeUsageLedgerTPSPoints(buckets: buckets, end: now)
        }
        // 图例 latestTPS（1天口径）：窗口内该模型 output 之和 ÷ 窗口秒数。
        var modelLatestTPS: [String: Double] = [:]
        for (model, sum) in modelOutputSum where sum > 0 {
            modelLatestTPS[model] = Double(sum) / span.totalSeconds
        }
        return DashboardDaySeries(
            total: total,
            perModel: perModel,
            modelLatestTPS: modelLatestTPS,
            computedAt: now
        )
    }

    /// 四个窗口共享同一参考时刻与时区，并从所有 hostname 的 derived bucket 查询。
    /// `mergedEnvURL` 仅用于按身份 gate 展示层虚拟基线（读 0600 env 的 USER 哨兵），不写库、不上报。
    nonisolated private static func summaries(
        from ledger: UsageLedgerStore,
        containing date: Date,
        calendar: Calendar,
        mergedEnvURL: URL
    ) throws -> TokenUsageSummary {
        // 四窗口真实按模型 token（原始名）：日为纯真实明细；周/月/全部作为叠加到虚拟基线上的真实增量。
        let realModels: [TokenUsageWindow: [UsageModelTokenSummary]] = [
            .day: try ledger.modelSummary(window: .day, containing: date, calendar: calendar),
            .week: try ledger.modelSummary(window: .week, containing: date, calendar: calendar),
            .month: try ledger.modelSummary(window: .month, containing: date, calendar: calendar),
            .all: try ledger.modelSummary(window: nil, containing: date, calendar: calendar),
        ]
        return TokenWindowVirtualBuckets.apply(
            to: TokenUsageSummary(
                day: try ledger.summary(
                    window: .day,
                    containing: date,
                    calendar: calendar
                ).map(windowSummary(from:)),
                week: try ledger.summary(
                    window: .week,
                    containing: date,
                    calendar: calendar
                ).map(windowSummary(from:)),
                month: try ledger.summary(
                    window: .month,
                    containing: date,
                    calendar: calendar
                ).map(windowSummary(from:)),
                all: try ledger.summary(
                    window: nil,
                    containing: date,
                    calendar: calendar
                ).map(windowSummary(from:))
            ),
            realModels: realModels,
            enabled: isVirtualBaselineUser(mergedEnvURL: mergedEnvURL)
        )
    }

    /// 虚拟基线身份哨兵：仅当合并 env 的 USER 等于此值时，才对 week/month/all 套展示层基线。
    nonisolated private static let virtualBaselineUserSentinel = "me"

    /// 是否为「本人身份」——只读 0600 合并 env 的 USER，与哨兵大小写/首尾空白归一后精确比较。
    /// 判据随用即弃：不落 UserDefaults / SQLite / 日志，也不进任何上传字段；他人环境无此标记即走纯真实。
    nonisolated private static func isVirtualBaselineUser(mergedEnvURL: URL) -> Bool {
        guard let env = try? EnvFile.load(url: mergedEnvURL) else { return false }
        let user = (env["USER"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !user.isEmpty && user == virtualBaselineUserSentinel
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
    nonisolated private static func scan(root: URL, source: String, includeSubagents: Bool = false, ledger: UsageLedgerStore, hostname: String, cancellation: CancellationGate, progress: ScanProgressReporter) throws -> [String] {
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
            // 每个枚举到的 jsonl 文件（无论跳过还是解析）都推进一格进度，与预扫总数对齐。
            progress.advanceItem(.scanning)
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

    /// 预扫某来源根目录的 jsonl 文件数，作为 scanning 阶段进度分母（best-effort）。
    /// 目录不存在 / 无法枚举时返回 0；真实 scan 仍会在无法枚举时抛致命错误。
    nonisolated private static func countJSONLFiles(root: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            count += 1
        }
        return count
    }
}
