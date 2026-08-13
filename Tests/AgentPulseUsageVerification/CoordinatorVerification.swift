import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage

/// TokenSyncCoordinator 当前属于 App executable target，且账本、扫描根目录、
/// token supplier 与网络 sender 都是生产实现。这里用两层 verifier 锁住边界：
/// 1. 对可注入的 FullSyncReporter 做真正的无进程、无网络行为验证；
/// 2. 对 Coordinator 做源码结构契约验证，防止门禁、互斥、取消和脱敏约束回归。
enum CoordinatorVerification {
    static func run() async throws {
        try await verifyMissingConfigurationStopsBeforeTokenAndNetwork()
        try await verifyReservedResumeAndGenerationDriftStopsBeforeUpload()
        try await verifyOldHostnameDebtUsesEmptyFullSync()

        let source = try coordinatorSource()
        try verifyMissingConfigurationRemainsBlocked(source)
        try verifyManualFullSyncIgnoresReportingToggle(source)
        try verifyOperationsAreMutuallyExclusive(source)
        try verifyStopCancelsEveryOperation(source)
        try verifyFullSyncGatesPrecedeSideEffects(source)
        try verifyFullSyncOrderingAndOffMainLedgerAccess(source)
        try verifyStaleGenerationAndEmptySnapshotStopBeforeUpload(source)
        try verifyStartupPrioritizesFullSyncRecovery(source)
        try verifyFullSyncErrorsAreSanitized(source)
        print("TokenSyncCoordinator verification passed")
    }

    private static func verifyMissingConfigurationStopsBeforeTokenAndNetwork() async throws {
        let sender = CountingSender()
        let tokens = CountingTokenSupplier()
        let reporter = FullSyncReporter(
            configuration: FullSyncConfiguration(),
            sender: sender,
            tokenSupplier: tokens,
            retrySleeper: NoDelaySleeper()
        )
        let snapshot = FullSyncPayloadSnapshot(buckets: [], sessions: [], rawGeneration: 1)
        let stateDirectory = FileManager.default.temporaryDirectory
            .appending(path: "coordinator-verification-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        do {
            _ = try await reporter.upload(
                snapshot: snapshot,
                authIdentity: "verification-account",
                store: FullSyncStateStore(directory: stateDirectory)
            )
            throw CoordinatorVerificationError.failed("缺配置的 full sync 未被阻止")
        } catch FullSyncError.configurationMissing {
            // Expected: configuration is validated before credentials or transport.
        }

        try require(sender.callCount == 0, "缺配置时仍发起了网络请求")
        try require(tokens.callCount == 0, "缺配置时仍启动了 token 获取")
    }

    /// A crash after reserve must reuse the persisted fence. If the later
    /// snapshot generation does not match that reservation, no begin/stage/commit
    /// request may escape and the stale reservation must be discarded.
    private static func verifyReservedResumeAndGenerationDriftStopsBeforeUpload() async throws {
        let sender = RecordingFullSyncSender()
        let tokens = CountingTokenSupplier()
        let reporter = FullSyncReporter(
            configuration: FullSyncConfiguration(
                baseURL: URL(string: "https://example.invalid"),
                path: "/usage/full-sync",
                hostname: "verification-host"
            ),
            sender: sender,
            tokenSupplier: tokens,
            retrySleeper: NoDelaySleeper()
        )
        let stateDirectory = FileManager.default.temporaryDirectory
            .appending(path: "coordinator-reservation-verification-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = FullSyncStateStore(directory: stateDirectory)
        defer { try? FileManager.default.removeItem(at: stateDirectory) }

        let first = try await reporter.reserve(
            hostname: "verification-host",
            authIdentity: "verification-account",
            generationBaseline: 7,
            store: store
        )
        let resumed = try await reporter.reserve(
            hostname: "verification-host",
            authIdentity: "verification-account",
            generationBaseline: 7,
            store: store
        )
        try require(first == resumed, "reserved crash resume 未复用原 fence")
        try require(sender.actions == ["reserve"], "reserved crash resume 重复请求了 reserve")

        do {
            _ = try await reporter.completeUpload(
                snapshot: FullSyncPayloadSnapshot(rawGeneration: 8),
                authIdentity: "verification-account",
                store: store
            )
            throw CoordinatorVerificationError.failed("generation drift 未被阻止")
        } catch FullSyncError.rescanRequired {
            // Expected before begin/stage/commit.
        }

        try require(
            sender.actions == ["reserve"],
            "generation drift 后仍发送了 begin/stage/commit：\(sender.actions)"
        )
        try require(!store.hasState(), "generation drift 后未丢弃过期 reservation")
    }

    /// A hostname rebuild removes rows under the old hostname locally while the
    /// remote still owns them. The debt host must therefore receive an empty
    /// full sync; syncing the new host cannot discharge that debt.
    private static func verifyOldHostnameDebtUsesEmptyFullSync() async throws {
        let database = FileManager.default.temporaryDirectory
            .appending(path: "coordinator-host-debt-\(UUID().uuidString).sqlite3")
        let stateDirectory = FileManager.default.temporaryDirectory
            .appending(path: "coordinator-host-debt-state-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: database)
            try? FileManager.default.removeItem(at: stateDirectory)
        }

        let ledger = try UsageLedgerStore(path: database.path)
        let oldHost = "old-host"
        let newHost = "new-host"
        let event = UsageEvent(
            id: "host-debt-event", source: "codex", model: "model", project: "project",
            timestamp: Date(timeIntervalSince1970: 1_800), counts: UsageTokenCounts(output: 7),
            sessionHash: "session", sourceFileHash: "file"
        )
        let checkpoint = UsageFileCheckpoint(
            fileID: "host-debt-file", source: "codex", pathHash: "path",
            offset: 1, size: 1, modifiedAt: Date(timeIntervalSince1970: 1_800),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try ledger.record(events: [event], checkpoint: checkpoint, hostname: oldHost)
        _ = try ledger.finalizeDerived(hostname: oldHost)
        let initial = try ledger.fullSyncSnapshot(hostname: oldHost)
        try require(try ledger.commitFullSync(UsageFullSyncCommit(snapshot: initial)).committed, "seed full sync failed")

        try ledger.rebuildForHostname(newHost)
        let debtHosts = try ledger.pendingReconciliationHosts()
        try require(debtHosts == [oldHost], "old hostname debt was not retained")
        let snapshot = try ledger.fullSyncSnapshot(hostname: oldHost)
        try require(snapshot.isEmpty && snapshot.reconciliationReason != nil, "old-host cleanup snapshot must be empty and gated")

        let sender = RecordingFullSyncSender()
        let reporter = FullSyncReporter(
            configuration: FullSyncConfiguration(
                baseURL: URL(string: "https://example.invalid"),
                path: "/usage/full-sync", hostname: oldHost
            ),
            sender: sender, tokenSupplier: CountingTokenSupplier(),
            retrySleeper: NoDelaySleeper(), makeUploadID: { String(repeating: "a", count: 64) }
        )
        let store = FullSyncStateStore(directory: stateDirectory)
        _ = try await reporter.upload(
            snapshot: UsageFullSyncSnapshotMapper.payloadSnapshot(from: snapshot),
            authIdentity: "verification-account", store: store
        )

        try require(sender.actions == ["reserve", "begin", "commit"], "empty cleanup sent unexpected phases: \(sender.actions)")
        let requests = sender.requests
        try require(requests.count == 3, "empty cleanup request count mismatch")
        try require(requests.allSatisfy { $0["hostname"] as? String == oldHost }, "cleanup wire targeted the wrong hostname")
        for request in requests.dropFirst() {
            try require(request["expectedBuckets"] == nil, "zero expected buckets must stay zero/omitted")
            try require(request["expectedSessions"] == nil, "zero expected sessions must stay zero/omitted")
            try require(request["expectedAutonomy"] == nil, "zero expected autonomy must stay zero/omitted")
        }

        try require(try ledger.commitFullSync(UsageFullSyncCommit(snapshot: snapshot)).committed, "old-host ledger cleanup commit failed")
        try reporter.finalize(store: store)
        try require(try ledger.pendingReconciliationHosts().isEmpty, "old-host debt was not cleared")
    }

    private static func verifyMissingConfigurationRemainsBlocked(_ source: String) throws {
        let triggerBody = try functionBody(named: "runFullSync", in: source)
        try require(
            triggerBody.contains("guard readiness == .ready else")
                && triggerBody.contains("status.fullSyncState = .blocked"),
            "手动 full sync 在缺配置时必须保持 blocked，而不是标记为一次执行失败"
        )

        let initialReadiness = try functionBody(
            matching: "private static func initialFullSyncReadiness(",
            in: source
        )
        try require(
            initialReadiness.contains("authorityStatus == .ready")
                && initialReadiness.contains("return (.blocked"),
            "缺配置的初始 full sync 状态没有 fail-closed"
        )
    }

    private static func verifyManualFullSyncIgnoresReportingToggle(_ source: String) throws {
        let body = try functionBody(named: "runFullSync", in: source)
        try require(
            !body.contains("reportingEnabled"),
            "手动 full sync 不应依赖普通上报开关 reportingEnabled"
        )
    }

    private static func verifyOperationsAreMutuallyExclusive(_ source: String) throws {
        let fullSyncBody = try functionBody(named: "runFullSync", in: source)
        try require(
            fullSyncBody.contains("scanTask == nil, reportTask == nil, fullSyncTask == nil"),
            "full sync 未与 scan/report 三方互斥"
        )

        let scanBody = try functionBody(matching: "private func scanNow(chainedReport:", in: source)
        try require(
            scanBody.contains("scanTask == nil, reportTask == nil, fullSyncTask == nil"),
            "scan 未与 report/full sync 三方互斥"
        )

        let reportBody = try functionBody(named: "reportNow", in: source)
        try require(
            reportBody.contains("reportTask == nil, scanTask == nil, fullSyncTask == nil"),
            "report 未与 scan/full sync 三方互斥"
        )
    }

    private static func verifyStopCancelsEveryOperation(_ source: String) throws {
        let body = try functionBody(named: "stop", in: source)
        for required in [
            "scanTask?.cancel()",
            "reportTask?.cancel()",
            "fullSyncTask?.cancel()",
            "scanGeneration &+= 1",
            "reportGeneration &+= 1",
            "fullSyncGeneration &+= 1",
        ] {
            try require(body.contains(required), "stop() 缺少取消/失效保护：\(required)")
        }
    }

    private static func verifyFullSyncGatesPrecedeSideEffects(_ source: String) throws {
        let triggerBody = try functionBody(named: "runFullSync", in: source)
        let taskOffset = try offset(of: "fullSyncTask = Task", in: triggerBody)
        try require(
            try offset(of: "guard readiness == .ready else", in: triggerBody) < taskOffset,
            "full sync 副作用任务早于 readiness 门禁"
        )

        let workerBody = try functionBody(matching: "nonisolated private static func performFullSync(", in: source)
        let hostnameGateOffset = try offset(of: "let target = try await runOffMain", in: workerBody)
        let reserveOffset = try offset(of: "reporter.reserve(", in: workerBody)
        try require(
            workerBody.contains("ledger.pendingReconciliationHosts()")
                && workerBody.contains("target.isDebtHost")
                && workerBody.contains("case .match = target.state")
                && hostnameGateOffset < reserveOffset,
            "hostname/debt 门禁没有阻止 reserve 副作用"
        )
        try require(
            workerBody.contains("catch is CancellationError"),
            "full sync worker 未保留取消语义"
        )
    }

    private static func verifyFullSyncOrderingAndOffMainLedgerAccess(_ source: String) throws {
        let body = try functionBody(matching: "nonisolated private static func performFullSync(", in: source)
        let orderedMarkers = [
            "ledger.pendingReconciliationHosts()",
            "ledger.hostnameState(current: hostname)",
            "ledger.fullSyncGenerationBaseline()",
            "tokenSupplier.prefetchIdentity()",
            "reporter.reserve(",
            "ledger.fullSyncSnapshot(",
            "UsageFullSyncSnapshotMapper.payloadSnapshot(from: snapshot)",
            "reporter.completeUpload(",
            "ledger.commitFullSync(",
        ]
        var prior = -1
        for marker in orderedMarkers {
            let current = try offset(of: marker, in: body)
            try require(current > prior, "full sync 调用时序错误：\(marker)")
            prior = current
        }
        try require(
            try lastOffset(of: "reporter.finalize(store: store)", in: body) > prior,
            "ledger commit 成功前清理了 committed state"
        )

        let hostnameRead = try sourceSlice(
            from: "let target = try await runOffMain",
            through: "}.get()",
            in: body
        )
        let baselineRead = try sourceSlice(
            from: "let generationBaseline = try await runOffMain",
            through: "}.get()",
            in: body
        )
        let snapshotRead = try sourceSlice(
            from: "snapshot = try await runOffMain",
            through: "}.get()",
            in: body
        )
        let commitWrite = try sourceSlice(
            from: "let commitResult = try await runOffMain",
            through: "}.get()",
            in: body
        )
        for (label, segment, ledgerCall) in [
            ("hostname", hostnameRead, "ledger.hostnameState(current: hostname)"),
            ("generation baseline", baselineRead, "ledger.fullSyncGenerationBaseline()"),
            ("snapshot", snapshotRead, "ledger.fullSyncSnapshot("),
            ("commit", commitWrite, "ledger.commitFullSync("),
        ] {
            try require(
                segment.contains(ledgerCall),
                "\(label) SQLite 操作未包在 runOffMain 中"
            )
        }
    }

    private static func verifyStaleGenerationAndEmptySnapshotStopBeforeUpload(_ source: String) throws {
        let body = try functionBody(matching: "nonisolated private static func performFullSync(", in: source)
        let staleBranch = try sourceSlice(
            from: "} catch let snapshotError as UsageFullSyncSnapshotError {",
            through: "// 关键：空快照不可直接 no-op。",
            in: body
        )
        try require(
            staleBranch.contains("case .staleGeneration:")
                && staleBranch.contains("try reporter.finalize(store: store)")
                && staleBranch.contains("return .fenced")
                && !staleBranch.contains("reporter.completeUpload(")
                && !staleBranch.contains("ledger.commitFullSync("),
            "stale generation 未在 begin/commit 前丢弃 reservation 并 fenced"
        )

        let emptyBranch = try sourceSlice(
            from: "if snapshot.isEmpty, snapshot.reconciliationReason == nil {",
            through: "return .nothingToSync(hostname: hostname)",
            in: body
        )
        try require(
            emptyBranch.contains("try reporter.finalize(store: store)")
                && !emptyBranch.contains("reporter.completeUpload(")
                && !emptyBranch.contains("ledger.commitFullSync("),
            "空快照且无 gate 时未安全清理 reservation 后直接完成"
        )
    }

    private static func verifyStartupPrioritizesFullSyncRecovery(_ source: String) throws {
        let startBody = try functionBody(named: "start", in: source)
        let resume = try offset(of: "resumeFullSyncIfPending()", in: startBody)
        try require(
            resume < offset(of: "triggerScanThenReport()", in: startBody)
                && resume < offset(of: "reportNow()", in: startBody),
            "启动时未优先恢复 pending full-sync state"
        )

        let resumeBody = try functionBody(named: "resumeFullSyncIfPending", in: source)
        try require(
            resumeBody.contains("store.hasState()")
                && resumeBody.contains("runFullSync()"),
            "pending full-sync state 未进入恢复链路"
        )
    }

    private static func verifyFullSyncErrorsAreSanitized(_ source: String) throws {
        let body = try functionBody(matching: "nonisolated private static func fullSyncErrorText", in: source)
        for unsafeRendering in ["localizedDescription", "String(describing:", "error.debugDescription"] {
            try require(!body.contains(unsafeRendering), "full sync 错误可能透传内部详情：\(unsafeRendering)")
        }
        for safeMessage in [
            "凭证无效或已过期",
            "网络传输失败，请稍后重试",
            "全量同步响应无法解析",
            "本地全量同步状态损坏，请重试",
        ] {
            try require(body.contains(safeMessage), "full sync 缺少脱敏错误映射：\(safeMessage)")
        }

        let finishBody = try functionBody(named: "finishFullSync", in: source)
        try require(
            finishBody.contains("case let .committed")
                && finishBody.contains("case let .failure")
                && finishBody.contains("case .cancelled")
                && finishBody.contains("refreshFullSyncReadiness()"),
            "full sync 完成、失败或取消状态转换不完整"
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

    private static func lastOffset(of needle: String, in source: String) throws -> Int {
        guard let range = source.range(of: needle, options: .backwards) else {
            throw CoordinatorVerificationError.failed("找不到源码契约：\(needle)")
        }
        return source.distance(from: source.startIndex, to: range.lowerBound)
    }

    private static func sourceSlice(from start: String, through end: String, in source: String) throws -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.lowerBound..<source.endIndex) else {
            throw CoordinatorVerificationError.failed("找不到源码区间：\(start) ... \(end)")
        }
        return String(source[startRange.lowerBound..<endRange.upperBound])
    }
}

private enum CoordinatorVerificationError: Error {
    case failed(String)
}

private final class CountingSender: FullSyncRequestSending, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func send(_ request: FullSyncTransportRequest) async throws -> HTTPResponse {
        lock.withLock { calls += 1 }
        return HTTPResponse(statusCode: 500, body: Data())
    }
}

private final class RecordingFullSyncSender: FullSyncRequestSending, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedActions: [String] = []
    private var recordedRequests: [[String: Any]] = []

    var actions: [String] { lock.withLock { recordedActions } }
    var requests: [[String: Any]] { lock.withLock { recordedRequests } }

    func send(_ request: FullSyncTransportRequest) async throws -> HTTPResponse {
        let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        let action = object?["action"] as? String ?? ""
        lock.withLock {
            recordedActions.append(action)
            recordedRequests.append(object ?? [:])
        }
        let response: [String: Any]
        switch action {
        case "reserve":
            response = ["status": "reserved", "fenceRevision": 41]
        case "commit":
            response = [
                "status": "committed",
                "buckets_upserted": 0,
                "sessions_upserted": 0,
                "autonomy_sessions_upserted": 0,
            ]
        default:
            response = ["status": "staging"]
        }
        return HTTPResponse(
            statusCode: 200,
            body: try JSONSerialization.data(withJSONObject: response)
        )
    }
}

private final class CountingTokenSupplier: FullSyncTokenSupplying, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func token(forceRefresh: Bool) async throws -> SecretToken {
        lock.withLock { calls += 1 }
        return SecretToken("unused-verification-token")
    }

    func stableAccountIdentity(forToken token: SecretToken) -> String {
        "verification-account"
    }
}

private struct NoDelaySleeper: RetrySleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CoordinatorVerificationError.failed(message) }
}
