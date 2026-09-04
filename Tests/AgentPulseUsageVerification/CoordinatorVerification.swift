import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage

/// TokenSyncCoordinator 属于 App executable target，账本、扫描根目录、token supplier
/// 与网络 sender 都是生产实现。这里对 Coordinator 做源码结构契约验证，锁住采集/上报的
/// 门禁、互斥、取消、rebuild pending 与脱敏约束，防止回归。
enum CoordinatorVerification {
    static func run() async throws {
        try verifyCalendarWindowBoundaries()

        let source = try coordinatorSource()
        try verifyLegacyHostnameRecoveryPrecedence(source)
        try verifyUsageSummaryCalendarInjection()
        try verifyOperationsAreMutuallyExclusive(source)
        try verifyStopCancelsEveryOperation(source)
        try verifyRebuildPendingBlocksNetworkUntilFullScan(source)
        try verifyFullScanEvidenceGatesRebuildCompletion(source)
        try verifyHostnameMismatchPromptNotGatedByAuthority(source)
        try verifyReportingAuthorityFromEnv(source)
        try verifyScanProgressReporting(source)
        try verifyCodexArchivedRolloutIdentityIsStable(source)
        try verifyAutoReportIntervalIsConfigurable(source)
        try verifyOperationTimestampsPersistAcrossLaunches(source)
        try verifyNoChangeRoundSkipsFinalize(source)
        print("TokenSyncCoordinator verification passed")
    }

    private static func verifyFileScannerProgress() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "usage-scanner-verification-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "large.jsonl")
        let first = #"{"type":"assistant","timestamp":"2026-09-01T00:00:01Z","sessionId":"fixture-session","cwd":"/fixture","message":{"id":"first","model":"fixture-model","content":[],"usage":{"output_tokens":5}}}"# + "\n"
        // This file exceeded the previous history admission budget and could never advance.
        let oldHistoryBudget = 4 * 1024 * 1024
        var data = Data(repeating: 0x0A, count: oldHistoryBudget + 1)
        data.append(Data(first.utf8))
        try data.write(to: file)
        let ledger = try UsageLedgerStore(path: ":memory:")
        let source = UsageScanRoot(root: directory, source: "fixture")
        let hostname = "scanner-verification"
        let manifest = try UsageScanManifest.discover(source: source)
        try require(manifest.files.count == 1 && manifest.files[0].size > oldHistoryBudget,
                    "discovery must retain oversized history files")
        var checkpoints = try ledger.checkpoints(source: source.source)
        let present = try UsageFileScanner.scan(manifest: manifest, ledger: ledger, hostname: hostname,
                                               checkpoints: &checkpoints)
        guard let fileID = present.first else { throw CoordinatorVerificationError.failed("scanner omitted history file") }
        try require(try ledger.checkpoint(fileID: fileID)?.offset == Int64(data.count),
                    "large history file did not reach its durable end")
        _ = try ledger.finalizeDerived(hostname: hostname)
        try require(try ledger.summary()?.counts.total == 5,
                    "large history file usage was not collected")
        _ = try UsageFileScanner.scan(manifest: manifest, ledger: ledger, hostname: hostname,
                                      checkpoints: &checkpoints)
        try require(try !ledger.requiresDerivationCompletion(), "unchanged file unnecessarily dirtied derived data")

        let second = #"{"type":"assistant","timestamp":"2026-09-01T00:00:02Z","sessionId":"fixture-session","cwd":"/fixture","message":{"id":"second","model":"fixture-model","content":[],"usage":{"output_tokens":6}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(second.utf8))
        try handle.close()
        _ = try UsageFileScanner.scan(manifest: UsageScanManifest.discover(source: source), ledger: ledger,
                                      hostname: hostname, checkpoints: &checkpoints)
        _ = try ledger.finalizeDerived(hostname: hostname)
        try require(try ledger.summary()?.counts.total == 11,
                    "appended usage failed to update the oversized file")

        do {
            _ = try UsageScanManifest.discover(source: UsageScanRoot(root: file, source: "fixture"))
            throw CoordinatorVerificationError.failed("regular file must not count as an empty source directory")
        } catch UsageFileScanError.rootNotEnumerable {
            // An incomplete discovery must not become a successful missing-file update.
        }
    }

    /// 设置页展示的最近扫描/上报状态必须跨进程恢复，同时保持既有语义：
    /// 扫描成功才更新时间；上报失败只更新结果，不覆盖最近一次成功上报时间。
    private static func verifyOperationTimestampsPersistAcrossLaunches(_ source: String) throws {
        let initializer = try functionBody(matching: "init(", in: source)
        try require(
            initializer.contains("defaults.object(forKey: DefaultsKey.lastScanAt) as? Date")
                && initializer.contains("defaults.object(forKey: DefaultsKey.lastReportAt) as? Date")
                && initializer.contains("defaults.object(forKey: DefaultsKey.lastReportSucceeded) as? Bool")
                && initializer.contains("lastScanAt: persistedLastScanAt")
                && initializer.contains("lastReportAt: persistedLastReportAt")
                && initializer.contains("lastReportSucceeded: persistedLastReportSucceeded"),
            "init 未恢复最近扫描/上报状态"
        )

        let finishScan = try functionBody(matching: "private func finishScan(", in: source)
        try require(
            finishScan.contains("defaults.set(completedAt, forKey: DefaultsKey.lastScanAt)"),
            "成功扫描未持久化完成时间"
        )

        let finishReport = try functionBody(matching: "private func finishReport(", in: source)
        try require(
            finishReport.contains("defaults.set(succeeded, forKey: DefaultsKey.lastReportSucceeded)")
                && finishReport.contains("self.defaults.set(completedAt, forKey: DefaultsKey.lastReportAt)")
                && finishReport.contains("defaults.set(false, forKey: DefaultsKey.lastReportSucceeded)"),
            "上报完成状态未持久化"
        )
    }

    /// 扫描进度上报契约（E1）：
    /// - 进入扫描时置位阶段/百分比，结束时统一 clearScanProgress 归零；
    /// - scanning 阶段先预扫全部来源 root 的 jsonl 总数（setPhaseTotal）再逐文件 advanceItem；
    /// - 进度回调只在当前 generation 且仍在扫描时写（applyScanProgress 门禁），避免旧扫描覆盖新扫描；
    /// - 各阶段边界都通过 ScanProgressReporter 报点（cliproxy / scanning / finalizing / compacting / summarizing）。
    private static func verifyScanProgressReporting(_ source: String) throws {
        let scan = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        try require(scan.contains("status.scanPhase = .scanning"), "local scan must publish progress immediately")
        try require(scan.contains("UsageScanManifest.discover") && scan.contains("UsageFileScanner.scan"),
                    "progress and ingestion must share discovery")
        try require(scan.contains("progressReporter.advanceItem(.scanning)"), "missing file progress")
        let apply = try functionBody(named: "applyScanProgress", in: source)
        try require(apply.contains("generation == scanGeneration, statusSubject.value.scanningInProgress"),
                    "stale progress must not replace current activity")
        try verifyFileScannerProgress()
    }

    private static func verifyCodexArchivedRolloutIdentityIsStable(_ source: String) throws {
        let name = "rollout-2026-09-01T10-00-00-session.jsonl"
        let active = URL(fileURLWithPath: "/fixture/sessions/2026/09/01/" + name)
        let archived = URL(fileURLWithPath: "/fixture/archived/" + name)
        try require(UsageFileScanner.fileIdentity(for: active, source: "codex")
                    == UsageFileScanner.fileIdentity(for: archived, source: "codex"),
                    "archiving must preserve Codex file identity")
        try require(UsageFileScanner.fileIdentity(for: active, source: "claude-code") !=
                    UsageFileScanner.fileIdentity(for: archived, source: "claude-code"),
                    "other sources must retain path identity")
    }
    private static func verifyAutoReportIntervalIsConfigurable(_ source: String) throws {
        try require(
            source.contains("private var autoReportInterval: TokenReportInterval"),
            "autoReportInterval 未改为可配置的实例属性"
        )
        try require(
            !source.contains("private static let autoReportInterval: TimeInterval"),
            "autoReportInterval 仍是硬编码静态常量"
        )
        // init 从 defaults 读取间隔。
        let initializer = try functionBody(matching: "init(", in: source)
        try require(
            initializer.contains("DefaultsKey.autoReportInterval")
                && initializer.contains("self.autoReportInterval = reportInterval"),
            "init 未从 defaults 读取并回填自动上报间隔"
        )
        // setter：写 defaults + 重启循环。
        let setter = try functionBody(named: "setAutoReportInterval", in: source)
        try require(
            setter.contains("defaults.set(interval.rawValue, forKey: DefaultsKey.autoReportInterval)")
                && setter.contains("autoLoopTask?.cancel()")
                && setter.contains("startAutoLoopIfNeeded()"),
            "setAutoReportInterval 未写 defaults 或未重启自动循环"
        )
        // 自动循环读取实例间隔。
        let autoLoop = try functionBody(named: "startAutoLoopIfNeeded", in: source)
        try require(
            autoLoop.contains("self?.autoReportInterval.seconds"),
            "自动循环未读取实例级上报间隔"
        )
    }

    /// 上报权威（hostname / base URL）改由合并 env 供给，reporting.json 只留纯协议结构：
    /// - `makeEnvBackedReporter` 注入 configurationLoader，用 env 的 REPORT_CANONICAL_HOSTNAME 覆盖 canonicalHostname；
    /// - `configurationAuthority` 的 hostname 来自 `envCanonicalHostname`，不再从 reporting.json 读；
    /// - `setIngestBaseURL` / `setCanonicalHostname` 写回 env（EnvFile.writeBack），绝不把值写进 UserDefaults；
    /// - 隐私：base URL / hostname 的写入路径不含 `defaults.set(...forKey: DefaultsKey.ingestBaseURL)` 之类的值落盘。
    private static func verifyReportingAuthorityFromEnv(_ source: String) throws {
        // reporter 合成 loader：以 env hostname 覆盖协议结构里的 canonicalHostname。
        let makeReporter = try functionBody(matching: "private static func makeEnvBackedReporter(", in: source)
        try require(
            makeReporter.contains("TokenUsageReporter.loadConfiguration(from: configURL)")
                && makeReporter.contains("configuration.canonicalHostname = envCanonicalHostname(url: envURL)"),
            "makeEnvBackedReporter 未用 env hostname 覆盖 reporting.json 的 canonicalHostname"
        )

        // configurationAuthority 的 hostname 来自 env，不再读 reporting.json 的字段。
        let authorityBody = try functionBody(matching: "private static func configurationAuthority(", in: source)
        try require(
            authorityBody.contains("envCanonicalHostname(url: envURL)"),
            "configurationAuthority 未从合并 env 读取 hostname"
        )
        try require(
            !authorityBody.contains("configuration.canonicalHostname"),
            "configurationAuthority 仍从 reporting.json 读取 hostname 权威"
        )

        // base URL 权威来自 env；env helper 读 REPORT_BASE_URL / REPORT_CANONICAL_HOSTNAME。
        let envHostname = try functionBody(matching: "nonisolated private static func envCanonicalHostname(", in: source)
        try require(envHostname.contains("MergedEnvKeys.reportCanonicalHostname"), "envCanonicalHostname 未读取 REPORT_CANONICAL_HOSTNAME")
        let envBase = try functionBody(matching: "nonisolated private static func envBaseURL(", in: source)
        try require(envBase.contains("MergedEnvKeys.reportBaseURL"), "envBaseURL 未读取 REPORT_BASE_URL")

        // setIngestBaseURL：写回 env，不把值写进 UserDefaults。
        let setBase = try functionBody(named: "setIngestBaseURL", in: source)
        try require(
            setBase.contains("EnvFile.writeBack([MergedEnvKeys.reportBaseURL: trimmed], to: mergedEnvURL)"),
            "setIngestBaseURL 未写回合并 env"
        )
        try require(
            !setBase.contains("defaults.set(trimmed, forKey: DefaultsKey.ingestBaseURL)"),
            "setIngestBaseURL 仍把 base URL 值写入 UserDefaults"
        )

        // setCanonicalHostname：写回 env，不把值写进 UserDefaults。
        let setHost = try functionBody(named: "setCanonicalHostname", in: source)
        try require(
            setHost.contains("EnvFile.writeBack([MergedEnvKeys.reportCanonicalHostname: trimmed], to: mergedEnvURL)"),
            "setCanonicalHostname 未写回合并 env"
        )
        try require(
            !setHost.contains("defaults.set(trimmed, forKey: DefaultsKey.canonicalHostname)"),
            "setCanonicalHostname 仍把 hostname 值写入 UserDefaults"
        )
    }

    /// 设备标识改名弹窗必须只依赖 effectiveHostname（权威或本地），不得挂在 configReady/
    /// authority 上——否则没配 reporting.json、只改本地设备标识的用户永远进不到弹窗分支。
    private static func verifyHostnameMismatchPromptNotGatedByAuthority(_ source: String) throws {
        let scanBody = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        // mismatch 判定与弹窗触发必须存在。
        let mismatchOffset = try offset(of: "case let .success(.mismatch(stored)):", in: scanBody)
        try require(scanBody.contains("presentHostnameMismatch(old: stored, new: hostname)"), "scanNow 未在 mismatch 时触发确认弹窗")
        // configReady 不得再作为 mismatch 弹窗的门禁（若仍存在 configReady，必须不在弹窗触发之前把它作为条件）。
        try require(
            !scanBody.contains("let configReady ="),
            "mismatch 弹窗仍被 configReady 门禁：本地设备标识路径将无法触发弹窗"
        )
        // hostname 非空 guard 必须在 mismatch 判定之前（保证 effectiveHostname 口径已生效）。
        let hostnameGuardOffset = try offset(of: "guard !hostname.isEmpty else {", in: scanBody)
        try require(hostnameGuardOffset < mismatchOffset, "mismatch 判定必须在 effectiveHostname 非空 guard 之后")
    }

    private static func verifyLegacyHostnameRecoveryPrecedence(_ source: String) throws {
        let initialization = try functionBody(matching: "private func initializeLedger(", in: source)
        try require(initialization.contains("authorityHostname.isEmpty ? storedHostname : authorityHostname")
                    && initialization.contains("if hostname.isEmpty, let candidate")
                    && initialization.contains("CanonicalHostname.normalize(candidate) == candidate"),
                    "legacy hostname recovery must preserve config/defaults precedence and exact durable identity")
        try require(initialization.contains("Self.runOffMain") && initialization.contains("uniqueLegacyHostnameCandidate()"),
                    "legacy recovery must run outside the UI actor")
    }

    private static func verifyUsageSummaryCalendarInjection() throws {
        guard let newYork = TimeZone(identifier: "America/New_York"),
              let utc = TimeZone(secondsFromGMT: 0) else {
            throw CoordinatorVerificationError.failed("missing calendar fixture time zones")
        }
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = newYork
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let reference = try localDate(2024, 3, 10, 12, 0, calendar: localCalendar)
        let events = [
            ("prior-local-day", try localDate(2024, 3, 9, 23, 30, calendar: localCalendar), Int64(2)),
            ("current-local-day", try localDate(2024, 3, 10, 0, 30, calendar: localCalendar), Int64(4))
        ].map { id, timestamp, tokens in
            UsageEvent(id: id, source: "fixture", model: "fixture-model", project: "fixture",
                       timestamp: timestamp, counts: UsageTokenCounts(output: tokens),
                       sessionHash: "fixture-session", sourceFileHash: "timezone-file")
        }
        let ledger = try UsageLedgerStore(path: ":memory:")
        try ledger.record(events: events, checkpoint: UsageFileCheckpoint(
            fileID: "timezone-file", source: "fixture", pathHash: "timezone-file",
            offset: 1, size: 1, modifiedAt: reference, parserVersion: UsageJSONLParser.parserVersion,
            status: "complete"
        ), hostname: "timezone-fixture")
        _ = try ledger.finalizeDerived(hostname: "timezone-fixture")
        let local = try ledger.summarySnapshot(containing: reference, calendar: localCalendar)
        let universal = try ledger.summarySnapshot(containing: reference, calendar: utcCalendar)
        for (snapshot, expectedDay) in [(local, Int64(4)), (universal, Int64(6))] {
            try require(snapshot.windows.count == 4, "snapshot omitted a calendar window")
            for item in snapshot.windows {
                let expected = item.window == .day ? expectedDay : Int64(6)
                try require(item.summary?.counts.total == expected,
                            "injected calendar did not control snapshot window totals")
                try require(item.models.reduce(Int64(0)) { $0 + $1.counts.total } == expected,
                            "per-model totals and summary used different calendar boundaries")
            }
        }
        try require(universal.revision > local.revision, "calendar snapshots must preserve publication ordering")
    }

    private static func verifyCalendarWindowBoundaries() throws {
        guard let timeZone = TimeZone(identifier: "America/Los_Angeles") else {
            throw CoordinatorVerificationError.failed("missing deterministic verification time zone")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let springReference = try localDate(2024, 3, 10, 12, 0, calendar: calendar)
        let fallReference = try localDate(2024, 11, 3, 12, 0, calendar: calendar)
        let springDay = try requireInterval(.day, containing: springReference, calendar: calendar)
        let fallDay = try requireInterval(.day, containing: fallReference, calendar: calendar)
        try require(springDay.duration == 23 * 60 * 60, "spring DST day must contain 23 hours")
        try require(fallDay.duration == 25 * 60 * 60, "fall DST day must contain 25 hours")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "coordinator-calendar-verification-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = try UsageLedgerStore(path: directory.appending(path: "usage.sqlite3").path)
        let hostname = "calendar-verification"
        // day = 自然日 [03-10 00:00, 03-11 00:00)；week/month = 以 springReference 为右界向前 7/30×24h 的滚动窗口。
        // 事件时刻均早于 springReference，且远离滚动窗口起点，避免 DST 偏移导致的临界翻转。
        let samples: [(String, Date, Int64)] = [
            ("day", try localDate(2024, 3, 10, 11, 0, calendar: calendar), 1),   // day + week + month
            ("week", try localDate(2024, 3, 5, 12, 0, calendar: calendar), 2),   // week + month，非 day
            ("month", try localDate(2024, 2, 20, 12, 0, calendar: calendar), 4), // month，非 week
            ("all", try localDate(2024, 1, 1, 12, 0, calendar: calendar), 8),    // 早于 month 起点，仅 all-time
        ]
        let events = samples.map { label, timestamp, tokens in
            UsageEvent(
                id: "calendar-\(label)", source: "verification", model: "model", project: "project",
                timestamp: timestamp, counts: UsageTokenCounts(output: tokens),
                sessionHash: "session-\(label)", sourceFileHash: "calendar-file"
            )
        }
        let checkpoint = UsageFileCheckpoint(
            fileID: "calendar-file", source: "verification", pathHash: "calendar-path",
            offset: 1, size: 1, modifiedAt: springReference,
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try ledger.record(events: events, checkpoint: checkpoint, hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)

        let day = try ledger.summary(window: .day, containing: springReference, hostname: hostname, calendar: calendar)
        let week = try ledger.summary(window: .week, containing: springReference, hostname: hostname, calendar: calendar)
        let month = try ledger.summary(window: .month, containing: springReference, hostname: hostname, calendar: calendar)
        let all = try ledger.summary(window: nil, containing: springReference, hostname: hostname, calendar: calendar)
        try require(day?.counts.total == 1, "day summary crossed the natural-day boundary")
        try require(week?.counts.total == 3, "week summary is not the rolling 7-day range ending at the reference")
        try require(month?.counts.total == 7, "month summary is not the rolling 30-day range ending at the reference")
        try require(all?.counts.total == 15, "all summary omitted host history")
    }

    /// A3：无变化轮跳过全库重算。
    /// - 契约信号：`requiresDerivationCompletion()`（读 raw 派生 dirty 位）——文件 record 置位，
    ///   一次成功 finalizeDerived 清除。协调层据此在 finalize 前 gate，跳过时不做 O(全库) 重算。
    /// - 行为断言（真实 ledger）：record→finalize 后 dirty 清除（可跳过）；重复 finalize 后仍清除；
    ///   网络事件同事务局部派生、不置位全库 dirty；空事件也不置位。
    /// - 源文断言：scanNow 闭包用 requiresDerivationCompletion() 门禁 finalizeDerived，跳过分支从
    ///   reportingEligible 读回资格而非重算。
    private static func verifyNoChangeRoundSkipsFinalize(_ source: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "coordinator-skip-finalize-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let ledger = try UsageLedgerStore(path: directory.appending(path: "usage.sqlite3").path)
        let hostname = "skip-verification"
        let event = UsageEvent(
            id: "skip-1", source: "verification", model: "model", project: "project",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000), counts: UsageTokenCounts(output: 5),
            sessionHash: "session-skip", sourceFileHash: "skip-file"
        )
        let checkpoint = UsageFileCheckpoint(
            fileID: "skip-file", source: "verification", pathHash: "skip-path",
            offset: 1, size: 1, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )

        // record 置 dirty：finalize 前必须为 true。
        try ledger.record(events: [event], checkpoint: checkpoint, hostname: hostname)
        try require(try ledger.requiresDerivationCompletion(), "record 后 raw 派生 dirty 位未置位")

        // 一次成功 finalize 清除 dirty：下一轮可跳过。
        _ = try ledger.finalizeDerived(hostname: hostname)
        try require(!(try ledger.requiresDerivationCompletion()), "finalizeDerived 后 dirty 位未清除，无法跳过无变化轮")

        // 无新事件再 finalize：仍保持清除（幂等，不重新置位）。
        _ = try ledger.finalizeDerived(hostname: hostname)
        try require(!(try ledger.requiresDerivationCompletion()), "无变化的重复 finalize 不应重新置位 dirty")

        // 空网络事件：入口 guard 提前返回，绝不置位。
        try ledger.recordNetworkEvents([], source: CliProxyUsageParser.source, hostname: hostname)
        try require(!(try ledger.requiresDerivationCompletion()), "空 recordNetworkEvents 不应置位 dirty（不该触发无谓 finalize）")

        // 非空网络事件：同事务局部派生，不得触发全库 finalize。
        let networkEvent = UsageEvent(
            id: "skip-net-1", source: CliProxyUsageParser.source, model: "model", project: "project",
            timestamp: Date(timeIntervalSince1970: 1_700_000_100), counts: UsageTokenCounts(output: 3),
            sessionHash: "session-net", sourceFileHash: "network\u{1}\(CliProxyUsageParser.source)"
        )
        try ledger.recordNetworkEvents([networkEvent], source: CliProxyUsageParser.source, hostname: hostname)
        try require(!(try ledger.requiresDerivationCompletion()), "网络局部派生不应置位全库 dirty")
        let networkBuckets = try ledger.buckets(hostname: hostname).filter { $0.source == CliProxyUsageParser.source }
        try require(networkBuckets.count == 1 && networkBuckets[0].counts.total == 3, "网络局部派生未写入完整 bucket")

        // 文件全部仍在：markFilesMissing 无事可做，不得置位（否则每轮都退化成全库重算）。
        try ledger.markFilesMissing(source: "verification", presentFileIDs: ["skip-file"], hostname: hostname)
        try require(
            !(try ledger.requiresDerivationCompletion()),
            "无文件转 missing 时 markFilesMissing 不应置位 dirty（会导致每轮全库重算）"
        )

        // 文件消失：scan_status 转 missing 会改变事件 tier，进而可能改变 logical dedup 结果，
        // 必须置位 dirty，否则派生表沿用旧 tier 的陈旧结论。
        try ledger.markFilesMissing(source: "verification", presentFileIDs: [], hostname: hostname)
        try require(
            try ledger.requiresDerivationCompletion(),
            "文件转 missing 后未置位 dirty（tier 变化不会反映到派生表）"
        )
        _ = try ledger.finalizeDerived(hostname: hostname)

        // fileIDs 重载：未登记的 fileID 与已经 missing 的行都没有 tier 变化，同样不得置位。
        try ledger.markFilesMissing(fileIDs: ["never-registered-file"], hostname: hostname)
        try require(
            !(try ledger.requiresDerivationCompletion()),
            "未登记的 fileID 不应置位 dirty（无 tier 变化）"
        )
        try ledger.markFilesMissing(fileIDs: ["skip-file"], hostname: hostname)
        try require(
            !(try ledger.requiresDerivationCompletion()),
            "已经 missing 的文件重复标记不应置位 dirty（无 tier 变化）"
        )

        // 源文断言：scanNow 闭包必须以 requiresDerivationCompletion() 门禁 finalize，跳过时读 reportingEligible。
        let scanNowBody = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        try require(
            scanNowBody.contains("requiresDerivationCompletion()"),
            "scanNow 未用 requiresDerivationCompletion() 门禁 finalize（无变化轮不会跳过全库重算）"
        )
        try require(
            scanNowBody.contains("baselineRecovery == .deferred")
                && scanNowBody.contains("strategy: .fullRecompute"),
            "scanNow 未在大账本 baseline recovery deferred 时转入全量 finalize 恢复基线"
        )
        try require(
            scanNowBody.contains("baselineRecovery == .deferred")
                && scanNowBody.contains("compactFrozen: false, strategy: .fullRecompute"),
            "scanNow deferred baseline 恢复必须跳过冻结压实，避免大账本上报门禁长期不解除"
        )
        try require(
            !scanNowBody.contains("compactFrozen: compactionEnabled"),
            "scanNow 的扫描/上报关键路径不应执行冻结压实；压实应拆成独立维护任务"
        )
        try require(
            scanNowBody.contains("ledger.compactFrozenRaw(hostname: hostname)")
                && scanNowBody.contains("progressReporter.enterPhase(.compacting"),
            "冻结压实未作为独立维护阶段接入扫描完成后的进度链路"
        )
        try require(
            !scanNowBody.contains("baselineRecovery == .deferred ? (buckets: 0, sessions: 0) : try ledger.pendingCounts"),
            "scanNow deferred 分支不应伪造 pendingCounts；full finalize 后应读取真实 pending"
        )
        try require(
            scanNowBody.contains("ledger.reportingEligible(hostname:"),
            "scanNow 跳过分支未从 reportingEligible 读回上报资格（会伪造 eligible）"
        )
    }

    private static func localDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        guard let date = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute
        )) else {
            throw CoordinatorVerificationError.failed("failed to construct deterministic local date")
        }
        return date
    }

    private static func requireInterval(
        _ window: UsageSummaryWindow,
        containing date: Date,
        calendar: Calendar
    ) throws -> DateInterval {
        guard let interval = window.interval(containing: date, calendar: calendar) else {
            throw CoordinatorVerificationError.failed("failed to construct calendar window")
        }
        return interval
    }

    /// scan / report 必须两两互斥，避免并发写账与在途上传竞争。
    private static func verifyOperationsAreMutuallyExclusive(_ source: String) throws {
        let scanBody = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        try require(
            scanBody.contains("scanTask == nil, reportTask == nil"),
            "scan 未与 report 互斥"
        )

        let reportBody = try functionBody(named: "reportNow", in: source)
        try require(
            reportBody.contains("reportTask == nil, scanTask == nil"),
            "report 未与 scan 互斥"
        )
    }

    private static func verifyStopCancelsEveryOperation(_ source: String) throws {
        let body = try functionBody(named: "stop", in: source)
        for required in [
            "scanTask?.cancel()",
            "reportTask?.cancel()",
            "scanGeneration &+= 1",
            "reportGeneration &+= 1",
            "Self.clearScanProgress(&status)",
            "status.reportingInProgress = false",
        ] {
            try require(body.contains(required), "stop() 缺少取消/失效保护：\(required)")
        }
    }

    /// rebuild pending（已 reset 未确认重扫完成）期间，绝不能发起任何网络请求：
    /// start() 必须先于上报检查 pending 并只做扫描；report / startAutoLoop 都必须在 pending 时短路。
    private static func verifyRebuildPendingBlocksNetworkUntilFullScan(_ source: String) throws {
        let report = try functionBody(named: "reportNow", in: source)
        try require(try offset(of: "Self.isRebuildCompletionPending(ledger: ledger)", in: report)
                    < offset(of: "reporter.report(", in: report),
                    "reporting must inspect durable recovery state before network side effects")
        let loop = try functionBody(named: "startAutoLoopIfNeeded", in: source)
        try require(!loop.contains("isRebuildCompletionPending"),
                    "pending recovery must retain automatic local retries without synchronous ledger reads")
    }
    private static func verifyFullScanEvidenceGatesRebuildCompletion(_ source: String) throws {
        let scan = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        try require(try offset(of: "ledger.finalizeDerived(hostname: hostname", in: scan)
                    < offset(of: "ledger.markRebuildCompleted()", in: scan),
                    "rebuild completion must follow successful discovery, ingestion and derivation")
        let finish = try functionBody(named: "finishScan", in: source)
        try require(finish.contains("outcome.recoveryPending")
                    && finish.contains("status.scanError =")
                    && !finish.contains("markRebuildCompleted()"),
                    "failed scans must stay retryable without clearing persistent recovery")
    }

    private static func coordinatorSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appending(path: "Sources/AgentPulse/Usage/TokenSyncCoordinator.swift")
        do {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw CoordinatorVerificationError.failed("无法读取 Coordinator 源码：\(sourceURL.path)")
        }
    }

    private static func ledgerSource() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appending(path: "Sources/AgentPulseCore/UsageLedgerStore.swift")
        do {
            return try String(contentsOf: sourceURL, encoding: .utf8)
        } catch {
            throw CoordinatorVerificationError.failed("无法读取 UsageLedgerStore 源码：\(sourceURL.path)")
        }
    }

    private static func functionBody(named name: String, in source: String) throws -> String {
        try functionBody(matching: "func \(name)(", in: source)
    }

    private static func functionBody(matching marker: String, in source: String) throws -> String {
        guard let markerRange = source.range(of: marker),
              let parametersStart = source[markerRange.lowerBound...].firstIndex(of: "(") else {
            throw CoordinatorVerificationError.failed("找不到函数：\(marker)")
        }

        // Default closure arguments may contain braces before the actual function body.
        var parameterDepth = 0
        var parameterCursor = parametersStart
        repeat {
            if source[parameterCursor] == "(" { parameterDepth += 1 }
            if source[parameterCursor] == ")" { parameterDepth -= 1 }
            parameterCursor = source.index(after: parameterCursor)
        } while parameterDepth > 0 && parameterCursor < source.endIndex
        guard parameterDepth == 0,
              let openingBrace = source[parameterCursor...].firstIndex(of: "{") else {
            throw CoordinatorVerificationError.failed("函数参数不完整：\(marker)")
        }

        var depth = 0
        var cursor = openingBrace
        while cursor < source.endIndex {
            switch source[cursor] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 {
                    return String(source[openingBrace...cursor])
                }
            default: break
            }
            cursor = source.index(after: cursor)
        }
        throw CoordinatorVerificationError.failed("函数大括号不完整：\(marker)")
    }

    private static func offset(of needle: String, in source: String) throws -> Int {
        guard let range = source.range(of: needle) else {
            throw CoordinatorVerificationError.failed("找不到源码契约：\(needle)")
        }
        return source.distance(from: source.startIndex, to: range.lowerBound)
    }
}

private enum CoordinatorVerificationError: Error {
    case failed(String)
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CoordinatorVerificationError.failed(message) }
}
