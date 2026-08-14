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
        try verifyUsageSummaryCalendarInjection(source)
        try verifyOperationsAreMutuallyExclusive(source)
        try verifyStopCancelsEveryOperation(source)
        try verifyRebuildPendingBlocksNetworkUntilFullScan(source)
        try verifyFullScanEvidenceGatesRebuildCompletion(source)
        try verifyHostnameMismatchPromptNotGatedByAuthority(source)
        print("TokenSyncCoordinator verification passed")
    }

    /// 设备标识改名弹窗必须只依赖 effectiveHostname（权威或本地），不得挂在 configReady/
    /// authority 上——否则没配 reporting.json、只改本地设备标识的用户永远进不到弹窗分支。
    private static func verifyHostnameMismatchPromptNotGatedByAuthority(_ source: String) throws {
        let scanBody = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        // mismatch 判定与弹窗触发必须存在。
        let mismatchOffset = try offset(of: "case let .mismatch(stored) = (try? ledger.hostnameState(current: hostname))", in: scanBody)
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
        let initializer = try functionBody(matching: "init(", in: source)
        let authority = try offset(of: "configurationAuthority(reporter: reporter, url: configurationURL)", in: initializer)
        let candidate = try offset(of: "uniqueLegacyHostnameCandidate()", in: initializer)
        let effective = try offset(of: "let effectiveHostname = authority.hostname.isEmpty ? storedHostname : authority.hostname", in: initializer)
        try require(authority < candidate && candidate < effective, "legacy hostname recovery precedence is not config > defaults > unique ledger candidate")
        try require(
            initializer.contains("authority.hostname.isEmpty")
                && initializer.contains("storedHostname.isEmpty")
                && initializer.contains("normalizedCandidate == candidate")
                && initializer.contains("defaults.set(storedHostname, forKey: DefaultsKey.canonicalHostname)"),
            "legacy hostname candidate is not gated or persisted"
        )
    }

    private static func verifyUsageSummaryCalendarInjection(_ source: String) throws {
        guard let initializerStart = source.range(
            of: "    init(\n        defaults: UserDefaults = .standard,"
        )?.lowerBound else {
            throw CoordinatorVerificationError.failed("TokenSyncCoordinator initializer missing")
        }
        let initializer = try functionBody(
            matching: "init(",
            in: String(source[initializerStart...])
        )
        try require(
            source.contains("usageSummaryCalendar: Calendar = .autoupdatingCurrent")
                && initializer.contains("self.usageSummaryCalendar = usageSummaryCalendar"),
            "usage summary calendar must default to the system calendar and remain injectable"
        )
        try require(!source.contains("Asia/Shanghai"), "usage summary calendar still hard-codes Asia/Shanghai")

        let summaries = try functionBody(matching: "nonisolated private static func summaries(", in: source)
        try require(
            source.contains("containing date: Date,\n        calendar: Calendar")
                && summaries.components(separatedBy: "calendar: calendar").count - 1 == 8,
            "day/week/month/all token + per-model summaries must share the injected calendar"
        )

        let scan = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        try require(
            initializer.contains("calendar: usageSummaryCalendar")
                && scan.contains("let summaryCalendar = usageSummaryCalendar")
                && scan.contains("calendar: summaryCalendar"),
            "startup and post-scan summaries must both use the injected calendar"
        )
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
        ] {
            try require(body.contains(required), "stop() 缺少取消/失效保护：\(required)")
        }
    }

    /// rebuild pending（已 reset 未确认重扫完成）期间，绝不能发起任何网络请求：
    /// start() 必须先于上报检查 pending 并只做扫描；report / startAutoLoop 都必须在 pending 时短路。
    private static func verifyRebuildPendingBlocksNetworkUntilFullScan(_ source: String) throws {
        // start(): rebuild pending 分支必须早于上报副作用。
        let startBody = try functionBody(named: "start", in: source)
        let pendingGate = try offset(of: "isRebuildCompletionPending()", in: startBody)
        try require(
            pendingGate < offset(of: "triggerScanThenReport()", in: startBody),
            "启动时 rebuild pending 门禁未先于上报"
        )
        try require(
            startBody.contains("rebuildRecoveryPending = true")
                && startBody.contains("scanNow(chainedReport: false)"),
            "rebuild pending 启动分支未先触发完整扫描"
        )
        // rebuild pending 分支内不得直接触发上报（先扫描）。
        let pendingBranch: String
        if let branchRange = startBody.range(of: "if isRebuildCompletionPending() {"),
           let branchEnd = startBody.range(of: "return", range: branchRange.upperBound..<startBody.endIndex) {
            pendingBranch = String(startBody[branchRange.lowerBound..<branchEnd.upperBound])
        } else {
            throw CoordinatorVerificationError.failed("找不到 start() 的 rebuild pending 分支")
        }
        try require(
            !pendingBranch.contains("reportNow()")
                && !pendingBranch.contains("triggerScanThenReport()"),
            "rebuild pending 启动分支仍触发了网络动作（上报）"
        )

        // reportNow(): pending 时短路且不进入配置刷新 / 网络路径。
        let reportBody = try functionBody(named: "reportNow", in: source)
        try require(
            offset(of: "isRebuildCompletionPending()", in: reportBody)
                < offset(of: "reportTask = Task", in: reportBody),
            "reportNow 未在发起上报任务前检查 rebuild pending"
        )

        // startAutoLoopIfNeeded(): pending 时不启动自动上报循环。
        let autoLoopBody = try functionBody(named: "startAutoLoopIfNeeded", in: source)
        try require(
            autoLoopBody.contains("!isRebuildCompletionPending()"),
            "自动上报循环在 rebuild pending 时仍会启动"
        )
    }

    /// “全量成功”证据：只有所有来源无致命失败地完整扫描后，才显式清除 rebuild pending。
    /// - scan 对存在却无法枚举的来源根抛错（不静默 return），degraded 单文件错误经 record 抛出传播；
    /// - markRebuildCompleted() 只在 scan 闭包内、finalizeDerived 之后调用（此前任一 throw 都到不了）；
    /// - finishScan 失败分支保持 pending、不发网络请求。
    private static func verifyFullScanEvidenceGatesRebuildCompletion(_ source: String) throws {
        // scan(): 源根存在却无法枚举必须抛错，不能当作扫描成功。
        let scanBody = try functionBody(matching: "nonisolated private static func scan(", in: source)
        try require(
            scanBody.contains("TokenSyncScanError.sourceRootNotEnumerable"),
            "scan 未把来源根不可枚举视作致命失败"
        )
        // 不存在的根允许安静跳过；但可枚举失败必须抛错，二者都必须显式区分。
        try require(
            scanBody.contains("fileExists(atPath: root.path")
                && scanBody.contains("isDirectory.boolValue"),
            "scan 未区分“来源根缺失（跳过）”与“存在却不可枚举（失败）”"
        )

        // scanNow() 的 off-main 闭包：markRebuildCompleted 必须在 finalizeDerived 之后。
        let scanNowBody = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        let finalizeOffset = try offset(of: "ledger.finalizeDerived(hostname: hostname)", in: scanNowBody)
        let markOffset = try offset(of: "ledger.markRebuildCompleted()", in: scanNowBody)
        try require(finalizeOffset < markOffset, "markRebuildCompleted 未在 finalizeDerived 之后调用")
        try require(
            scanNowBody.contains("ledger.requiresRebuildCompletion()"),
            "scanNow 未在清除前确认存在 rebuild pending"
        )

        // finishScan 失败分支：保持 pending（不 mark）、不触发上报。
        let finishScanBody = try functionBody(named: "finishScan", in: source)
        try require(
            !finishScanBody.contains("markRebuildCompleted()"),
            "finishScan 不应在主线程清除 rebuild pending（清除只在扫描成功的 off-main 闭包内）"
        )
        try require(
            finishScanBody.contains("rebuildRecoveryPending")
                && finishScanBody.contains("isRebuildCompletionPending()"),
            "finishScan 未在恢复前确认 pending 已清除"
        )
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

    private static func functionBody(named name: String, in source: String) throws -> String {
        try functionBody(matching: "func \(name)(", in: source)
    }

    private static func functionBody(matching marker: String, in source: String) throws -> String {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.lowerBound...].firstIndex(of: "{") else {
            throw CoordinatorVerificationError.failed("找不到函数：\(marker)")
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
