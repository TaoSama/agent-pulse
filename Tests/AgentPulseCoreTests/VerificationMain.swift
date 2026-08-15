import Foundation
import AgentPulseCore
import SQLite3

private enum VerificationFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): return message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw VerificationFailure.assertion(message) }
}

private func requireApproximatelyEqual(
    _ actual: Double?,
    _ expected: Double,
    accuracy: Double = 0.000_001,
    _ message: String
) throws {
    guard let actual, abs(actual - expected) <= accuracy else {
        throw VerificationFailure.assertion("\(message): actual=\(String(describing: actual)), expected=\(expected)")
    }
}

private struct FixedClock: PulseClock {
    let date: Date
    func now() -> Date { date }
}

private struct FakeScanner: ProcessScanning {
    let processes: [RunningProcess]
    let error: ProcessScanError?

    init(processes: [RunningProcess] = [], error: ProcessScanError? = nil) {
        self.processes = processes
        self.error = error
    }

    func scan() throws -> [RunningProcess] {
        if let error { throw error }
        return processes
    }
}

private final class SequencedScanner: ProcessScanning, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [[RunningProcess]]

    init(snapshots: [[RunningProcess]]) {
        self.snapshots = snapshots
    }

    func scan() throws -> [RunningProcess] {
        lock.lock()
        defer { lock.unlock() }
        guard snapshots.count > 1 else { return snapshots.first ?? [] }
        return snapshots.removeFirst()
    }
}

private struct LegacyRuntimeSnapshotFixture: SnapshotPersistable {
    let id: UUID
    let timestamp: Date
    let desktopActive: Int?
    let terminalActive: Int?
    var sourceIdentifier: String? { "runtime-display-v1" }

    init(timestamp: Date, desktopActive: Int?, terminalActive: Int?) {
        id = UUID(uuidString: "A63D006E-C729-4C80-A8C1-8D36D22E6F41")!
        self.timestamp = timestamp
        self.desktopActive = desktopActive
        self.terminalActive = terminalActive
    }
}

@main
struct AgentPulseCoreVerification {
    static func main() async throws {
        if try await reconcileFrozenSnapshotIfConfigured() {
            return
        }
        if ProcessInfo.processInfo.environment["AGENT_PULSE_VERIFY_PARSER_METRICS_ONLY"] == "1" {
            try verifyV2ParserProtocol()
            try verifyV2ClaudeReasoningSplit()
            try verifyToolMetricsAndEditLines()
            print("AgentPulseCoreVerification(parser-metrics): PASS")
            return
        }
        try verifyTPSBoundaries()
        try verifySQLiteRoundTripAndRetention()
        try verifyUsageSummarySemantics()
        try verifyVirtualBucketTargets()
        try verifyUsageLedgerAndParsers()
        try verifyUsageV2()
        try verifyV8LegacyOwnedDedup()
        try await verifyLegacyRuntimeSnapshotIgnored()
        try verifyParserFixturesAndCollector()
        try verifyToolMetricsAndEditLines()
        try await verifyOracleColdStartAndCandidateRules()
        try await verifyClaudeTPSIntegration()
        try await verifyActiveCountingRules()
        try await verifyClaudeDesktopCounting()
        try await verifyRuntimeCollectorAndPersistence()
        try verifySparklineAnalysis()
        try verifyCliProxyUsageParser()
        print("AgentPulseCoreVerification: PASS")
    }

    private static func verifyUsageSummarySemantics() throws {
        let inputSummary = UsageInputSummary(counts: UsageTokenCounts(
            input: 30,
            output: 1_000,
            cachedInput: 60,
            cacheCreationInput: 10,
            reasoningOutput: 500,
            reportedTotal: 2_000
        ))
        try require(inputSummary.cachedTokens == 60, "cache hits must include cache reads only")
        try require(inputSummary.newTokens == 30, "new tokens must include uncached input only, excluding cache creation")
        try requireApproximatelyEqual(inputSummary.cacheHitRate, 60.0 / 90.0, "cache hit denominator must be uncached input + cache reads only")

        let outputOnly = UsageInputSummary(counts: UsageTokenCounts(output: 100, reasoningOutput: 20))
        try require(outputOnly.cacheHitRate == nil, "cache hit rate must be nil without input tokens")

        // 复现权威看板『日』窗口量级：cache read 主导 → 命中率 ≈ 99%，新增仅纯输入。
        let dayWindow = UsageInputSummary(counts: UsageTokenCounts(
            input: 243_718,
            output: 190_630,
            cachedInput: 44_850_423,
            cacheCreationInput: 1_678_909
        ))
        try require(dayWindow.newTokens == 243_718, "day-window new tokens must be pure input, not input + cache creation")
        try require(dayWindow.cachedTokens == 44_850_423, "day-window cached tokens must be cache reads")
        try requireApproximatelyEqual(dayWindow.cacheHitRate, 44_850_423.0 / (243_718.0 + 44_850_423.0), "day-window cache hit rate must be cache read / (input + cache read) ≈ 99.5%")

        // 费用口径：opus-4-8 精确命中当代单价 5/25/0.5，cache creation 不计费。
        let opusCounts = UsageTokenCounts(input: 243_718, output: 190_630, cachedInput: 44_850_423, cacheCreationInput: 1_678_909)
        let opusCost = UsageCostEstimator.cost(model: "claude-opus-4-8", counts: opusCounts)
        let expectedOpusCost = (243_718.0 * 5 + 190_630.0 * 25 + 44_850_423.0 * 0.5) / 1_000_000
        try requireApproximatelyEqual(opusCost, expectedOpusCost, "opus-4-8 must price via 5/25/0.5 and ignore cache creation")

        // 更长的模型串优先：opus-4-8 不得回退到旧 Opus 4 的 15/75/1.5。
        try require(opusCost < (243_718.0 * 15 + 190_630.0 * 75 + 44_850_423.0 * 1.5) / 1_000_000, "opus-4-8 must not fall back to legacy Opus-4 pricing")

        // 未匹配模型走 fallback 3/15/0.3，无 reasoning 档，cache creation 不计费。
        let unknownCounts = UsageTokenCounts(input: 1_000_000, output: 1_000_000, cachedInput: 1_000_000, cacheCreationInput: 1_000_000, reasoningOutput: 1_000_000)
        let unknownCost = UsageCostEstimator.cost(model: "some-unlisted-model", counts: unknownCounts)
        try requireApproximatelyEqual(unknownCost, 3 + 15 + 0.3, "fallback pricing must be 3/15/0.3 with no reasoning or cache-creation charge")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .gmt
        guard let reference = calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 15, minute: 30)),
              let day = UsageSummaryWindow.day.interval(containing: reference, calendar: calendar),
              let week = UsageSummaryWindow.week.interval(containing: reference, calendar: calendar),
              let month = UsageSummaryWindow.month.interval(containing: reference, calendar: calendar) else {
            throw VerificationFailure.assertion("usage summary calendar intervals must be constructible")
        }
        // 日 = 自然日历日（保留时区边界）。
        try require(day.start == calendar.date(from: DateComponents(year: 2024, month: 2, day: 29)), "day window start")
        try require(day.end == calendar.date(from: DateComponents(year: 2024, month: 3, day: 1)), "day window end")
        // 周 = 以参考时刻为右界向前 7×24h 的滚动窗口（非自然周）。
        try require(week.end == reference, "week window end must be the reference instant")
        try require(week.start == reference.addingTimeInterval(-7 * 24 * 60 * 60), "week window start must be 7×24h before reference")
        // 月 = 以参考时刻为右界向前 30×24h 的滚动窗口（非自然月）。
        try require(month.end == reference, "month window end must be the reference instant")
        try require(month.start == reference.addingTimeInterval(-30 * 24 * 60 * 60), "month window start must be 30×24h before reference")
    }

    /// 虚拟 bucket 一致性（口径：目标=起点，之后只加新增）：
    /// - 对任意实时真实用量 real：`Σ displayModels == scalarBaseline + Σ real`（余量并入 unknown）。
    /// - 追加真实增量后，展示总数正好增加该增量（起点之上正常累加）。
    /// - 模型名保持原始名（不新增映射名），token 降序。
    private static func verifyVirtualBucketTargets() throws {
        let targets: [(TokenWindowVirtualBucketTargets.Window, Int64)] = [
            (.week, 11_748_392_811),
            (.month, 37_117_728_838),
            (.all, 72_264_735_012),
        ]
        for (window, target) in targets {
            try require(TokenWindowVirtualBucketTargets.targetTokens(for: window) == target, "target total mismatch for \(window)")

            // Σ分模型 == displayTotal（恒等，二者同源）。
            let baseTotal = TokenWindowVirtualBucketTargets.displayTotal(for: window, real: [])
            let emptyModels = TokenWindowVirtualBucketTargets.displayModels(window: window, real: [])
            let emptySum = emptyModels.reduce(Int64(0)) { $0 + $1.tokens }
            try require(emptySum == baseTotal, "empty display per-model sum \(emptySum) != displayTotal \(baseTotal) for \(window)")

            // 追加真实增量：Σ分模型 == displayTotal，且总数随增量单调增长。
            let real = [
                TokenWindowVirtualBucketTargets.ModelTokens(model: "claude-opus-4-8", tokens: 1_000_000_000),
                TokenWindowVirtualBucketTargets.ModelTokens(model: "brand-new-model", tokens: 500_000_000),
            ]
            let total = TokenWindowVirtualBucketTargets.displayTotal(for: window, real: real)
            let models = TokenWindowVirtualBucketTargets.displayModels(window: window, real: real)
            let sum = models.reduce(Int64(0)) { $0 + $1.tokens }
            try require(sum == total, "display per-model sum \(sum) != displayTotal \(total) for \(window)")
            try require(total >= baseTotal, "display total must not shrink when real usage grows for \(window)")

            // unknown 唯一；真实新模型出现在明细里；降序。
            try require(models.filter { $0.model == TokenWindowVirtualBucketTargets.residualModel }.count <= 1, "residual model duplicated for \(window)")
            try require(models.contains { $0.model == "brand-new-model" }, "real new model missing for \(window)")
            try require(zip(models, models.dropFirst()).allSatisfy { $0.tokens >= $1.tokens }, "display breakdown not sorted descending for \(window)")

            // 缓存 / 创建维度（口径同总量：目标=起点，之后只加新增）：
            // - displayCached / displayNew = max(0, 目标 + (real − anchor))，随真实增量单调增，截 0 不为负。
            let cachedZero = TokenWindowVirtualBucketTargets.displayCached(for: window, realCached: 0)
            let newZero = TokenWindowVirtualBucketTargets.displayNew(for: window, realNew: 0)
            try require(cachedZero >= 0 && newZero >= 0, "cached/new display must clamp at 0 for \(window)")

            // 追加真实增量：显示缓存 / 创建不随真实增量收缩（起点之上正常累加）。
            let cachedGrown = TokenWindowVirtualBucketTargets.displayCached(for: window, realCached: 5_000_000_000)
            let newGrown = TokenWindowVirtualBucketTargets.displayNew(for: window, realNew: 5_000_000_000)
            try require(cachedGrown >= cachedZero, "display cached must not shrink when real cached grows for \(window)")
            try require(newGrown >= newZero, "display new must not shrink when real new grows for \(window)")

            // 命中率由放大后的 cached /(new + cached) 重算，落在 [0,1]。
            let denominator = cachedGrown + newGrown
            try require(denominator > 0, "cache/new denominator must be positive for \(window)")
            let hitRate = Double(cachedGrown) / Double(denominator)
            try require(hitRate >= 0 && hitRate <= 1, "cache hit rate out of range for \(window)")
        }
    }

    private static func verifyUsageLedgerAndParsers() throws {
        let timestamp = "2026-01-01T00:05:00Z"
        let codex = """
        {"type":"session_meta","payload":{"cwd":"/workspace/demo"}}
        {"type":"turn_context","payload":{"model":"model-a"}}
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":30,"cached_input_tokens":60,"cache_creation_input_tokens":10,"reasoning_output_tokens":5,"total_tokens":130}}}}
        """
        let parsedCodex = UsageJSONLParser.parse(data: Data(codex.utf8), source: "codex", fileIdentity: "codex-fixture")
        try require(parsedCodex.events.count == 1, "codex parser event count")
        let codexCounts = parsedCodex.events[0].counts
        try require(codexCounts.input == 30 && codexCounts.cachedInput == 60 && codexCounts.cacheCreationInput == 10, "codex input split")
        try require(codexCounts.output == 25 && codexCounts.reasoningOutput == 5, "codex output split")

        let claude = """
        {"type":"assistant","timestamp":"\(timestamp)","cwd":"/workspace/demo","uuid":"row-1","message":{"id":"message-1","model":"model-b","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}
        {"type":"assistant","timestamp":"\(timestamp)","cwd":"/workspace/demo","uuid":"row-2","message":{"id":"message-1","model":"model-b","usage":{"input_tokens":10,"output_tokens":25,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}
        """
        let parsedClaude = UsageJSONLParser.parse(data: Data(claude.utf8), source: "claude-code", fileIdentity: "claude-fixture")
        // 一次真实响应被拆成多条 uuid（同 message.id、usage 相同或流式渐增）应折叠为一条、逐分量取最大，
        // 与上游按请求计费口径对齐（逐 uuid 会成倍高估）。两行同 message.id → 一个事件。
        try require(parsedClaude.events.count == 1, "claude same-message.id rows fold to one event")
        let claudeEvent = parsedClaude.events[0].counts
        try require(claudeEvent.input == 10 && claudeEvent.cachedInput == 30 && claudeEvent.cacheCreationInput == 40, "claude folded input/cache take max")
        try require(claudeEvent.output == 25, "claude folded output takes max across streamed lines")

        let database = FileManager.default.temporaryDirectory.appending(path: "usage-ledger-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) } }
        let ledger = try UsageLedgerStore(path: database.path)
        // v8：record 是对 checkpoint.fileID 的文件级原子替换，每个文件各自 record（其行 sourceFileHash 与 fileID 相符）。
        // 重复 record 同一文件验证幂等（替换而非累加）。
        try ledger.record(events: parsedCodex.events, checkpoint: parsedCodex.checkpoint, hostname: "test-host")
        try ledger.record(events: parsedClaude.events, checkpoint: parsedClaude.checkpoint, hostname: "test-host")
        try ledger.record(events: parsedCodex.events, checkpoint: parsedCodex.checkpoint, hostname: "test-host")
        try ledger.record(events: parsedClaude.events, checkpoint: parsedClaude.checkpoint, hostname: "test-host")
        try ledger.finalizeDerived(hostname: "test-host")
        let eventCount = try ledger.eventCount()
        let buckets = try ledger.buckets(hostname: "test-host")
        let summary = try ledger.summary()
        try require(eventCount == 2, "ledger idempotent event insert (codex 1 + claude 1 folded)")
        try require(buckets.count == 2, "half-hour bucket dimensions")
        let claudeTotal = parsedClaude.events.reduce(Int64(0)) { $0 + $1.counts.total }
        try require(summary?.counts.total == codexCounts.total + claudeTotal, "ledger summary total")
    }

    private static func tempUsageDB() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "usage-v2-\(UUID().uuidString).sqlite")
    }

    private static func cleanupDB(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    private static func verifyUsageV2() throws {
        try verifyV2Timestamps()
        try verifyV2ParserProtocol()
        try verifyV2ClaudeReasoningSplit()
        try verifyV2ClaudeSubagent()
        try verifyV2SessionAlgorithm()
        try verifyV2ClaudeGrowth()
        try verifyV2InheritedReplayDedup()
        try verifyV2ArchivedSessionIdentity()
        try verifyV2DirtyAckRaceAndRestart()
        try verifyV2AcknowledgeProgressTimestamp()
        try verifyV2HostnameRebuild()
        try verifyUniqueLegacyHostnameCandidate()
        try verifyV2Migration()
        try verifyV2ParserRebuildSafety()
        try verifyV2RebuildCompletionPersistence()
        try verifyV2ProjectFromRawNotDeduped()
        try verifyV2SessionProjectWireAndMigration()
        try verifyV5CleanUpgradeAndPermissions()
    }

    // 1) fractional + 非 fractional RFC3339 解析；无效 timestamp 诊断并跳过（绝不 distantPast）。
    private static func verifyV2Timestamps() throws {
        let fractional = UsageTimestamp.parse("2026-01-01T00:00:00.123Z")
        let basic = UsageTimestamp.parse("2026-01-01T00:00:00Z")
        try require(fractional != nil, "fractional RFC3339 must parse")
        try require(basic != nil, "non-fractional RFC3339 must parse")
        try require(abs((fractional!.timeIntervalSince1970) - (basic!.timeIntervalSince1970) - 0.123) < 0.0005, "fractional seconds must be honored")
        try require(UsageTimestamp.parse("not-a-date") == nil, "invalid timestamp must be nil")
        try require(UsageTimestamp.parse(nil) == nil, "missing timestamp must be nil")

        // parser 跳过无效时间戳的 usage 行，且不落 distantPast。
        let codex = """
        {"type":"session_meta","payload":{"session_id":"s-ts","thread_source":"user","cwd":"/w/p"}}
        {"type":"turn_context","payload":{"model":"m"}}
        {"timestamp":"bogus","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":50,"total_tokens":50}}}}
        {"timestamp":"2026-01-01T00:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":30,"total_tokens":30}}}}
        """
        let parsed = UsageJSONLParser.parse(data: Data(codex.utf8), source: "codex", fileIdentity: "ts-fixture")
        try require(parsed.events.count == 1, "invalid-timestamp usage line must be skipped")
        try require(parsed.events[0].timestamp.timeIntervalSince1970 > 1_000_000, "surviving event must not be distantPast")
        try require(parsed.diagnostics.contains { $0.contains("invalid timestamp") }, "invalid timestamp must be diagnosed")
    }

    private static func verifyV2ParserProtocol() throws {
        func tokenLine(
            _ timestamp: String,
            model: String? = nil,
            lastInput: Int,
            lastOutput: Int,
            totalInput: Int? = nil,
            totalOutput: Int? = nil,
            total: Int? = nil
        ) -> String {
            let modelField = model.map { "\"model\":\"\($0)\"," } ?? ""
            let totalField: String
            if let totalInput, let totalOutput, let total {
                totalField = ",\"total_token_usage\":{\"input_tokens\":\(totalInput),\"output_tokens\":\(totalOutput),\"total_tokens\":\(total)}"
            } else {
                totalField = ""
            }
            return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\(modelField)\"last_token_usage\":{\"input_tokens\":\(lastInput),\"output_tokens\":\(lastOutput),\"total_tokens\":\(lastInput + lastOutput)}\(totalField)}}}"
        }

        let parentData = Data("""
            {"timestamp":"2026-02-01T00:00:00Z","type":"session_meta","payload":{"id":"rollout-parent","session_id":"session-parent","cwd":"/workspace/protocol-fixture"}}
            {"timestamp":"2026-02-01T00:00:01Z","type":"turn_context","payload":{"model":"model-context"}}
            \(tokenLine("2026-02-01T00:00:02Z", model: "model-info", lastInput: 6, lastOutput: 4, totalInput: 16, totalOutput: 9, total: 25))
            {"timestamp":"2026-02-01T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant"}}
            """.utf8)
        let parent = UsageJSONLParser.parse(data: parentData, source: "codex", fileIdentity: "protocol-parent-a")
        try require(parent.events.count == 1, "protocol parent token count")
        try require(parent.events[0].model == "model-info", "info.model must override turn_context model")
        try require(parent.events[0].project == "protocol-fixture", "session_meta cwd must determine project")
        try require(
            parent.sessionEvents.map(\.role) == [.syntheticUser, .user, .assistant, .assistant],
            "every timestamped Codex rollout record must contribute to the session timeline"
        )
        let rolloutSessionHash = String(UsageJSONLParser.fileID(for: "rollout-parent").prefix(16))
        try require(
            parent.sessionEvents.allSatisfy { $0.sessionHash == rolloutSessionHash }
                && parent.events[0].sessionHash == rolloutSessionHash,
            "Codex session identity must be derived from the stable rollout id, not the file path"
        )

        // 归档稳定性：同一 rollout 内容从 sessions/ 移到 archived_sessions/ 后路径变化，
        // session 身份与 session 事件 id 必须保持不变，否则会产生重复 session 行。
        let archivedParent = UsageJSONLParser.parse(data: parentData, source: "codex", fileIdentity: "protocol-parent-archived")
        try require(
            archivedParent.sessionEvents.map(\.id) == parent.sessionEvents.map(\.id)
                && archivedParent.sessionEvents.map(\.sessionHash) == parent.sessionEvents.map(\.sessionHash)
                && archivedParent.events.map(\.sessionHash) == parent.events.map(\.sessionHash),
            "archival move must not change Codex session identity"
        )

        let relocatedParent = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-01-31T23:59:59Z","type":"event_msg","payload":{"type":"task_started"}}
            {"timestamp":"2026-02-01T00:00:00Z","type":"session_meta","payload":{"id":"rollout-parent","session_id":"session-parent","cwd":"/workspace/protocol-fixture"}}
            {"timestamp":"2026-02-01T00:00:01Z","type":"turn_context","payload":{"model":"model-context"}}
            {"timestamp":"2026-02-01T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant"}}
            """.utf8),
            source: "codex", fileIdentity: "protocol-parent-relocated"
        )
        try require(
            parent.sessionEvents.map(\.id) != relocatedParent.sessionEvents.map(\.id),
            "distinct rollout content must not produce identical session event sets"
        )

        let missingSessionEventA = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:00:05Z","type":"turn_context","payload":{"model":"model-context"}}
            """.utf8),
            source: "codex", fileIdentity: "missing-session-path-a"
        )
        let missingSessionEventB = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:00:05Z","type":"turn_context","payload":{"model":"model-context"}}
            """.utf8),
            source: "codex", fileIdentity: "missing-session-path-b"
        )
        try require(
            missingSessionEventA.sessionEvents[0].id != missingSessionEventB.sessionEvents[0].id,
            "Codex rollout path must distinguish session event identity"
        )

        let sameRolloutDifferentSession = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:01:00Z","type":"session_meta","payload":{"id":"rollout-parent","session_id":"session-other"}}
            \(tokenLine("2026-02-01T00:01:01Z", lastInput: 1, lastOutput: 1, totalInput: 1, totalOutput: 1, total: 2))
            """.utf8),
            source: "codex", fileIdentity: "protocol-parent-b"
        )
        try require(parent.events[0].rolloutKey == sameRolloutDifferentSession.events[0].rolloutKey, "payload.id must determine rollout identity")
        try require(parent.events[0].sessionHash == sameRolloutDifferentSession.events[0].sessionHash, "same rollout id must map to one session regardless of session_id")

        let sameSessionDifferentRollout = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:02:00Z","type":"session_meta","payload":{"id":"rollout-other","session_id":"session-parent"}}
            \(tokenLine("2026-02-01T00:02:01Z", lastInput: 1, lastOutput: 1, totalInput: 1, totalOutput: 1, total: 2))
            """.utf8),
            source: "codex", fileIdentity: "protocol-parent-c"
        )
        try require(parent.events[0].sessionHash != sameSessionDifferentRollout.events[0].sessionHash, "equal payload session_id must not merge distinct rollout files")
        try require(parent.events[0].rolloutKey != sameSessionDifferentRollout.events[0].rolloutKey, "rollout identity must not use session_id")

        let legacyIdentityA = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:03:00Z","type":"session_meta","payload":{"session_id":"legacy-session"}}
            \(tokenLine("2026-02-01T00:03:01Z", lastInput: 1, lastOutput: 1))
            """.utf8),
            source: "codex", fileIdentity: "legacy-path-a"
        )
        let legacyIdentityB = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:04:00Z","type":"session_meta","payload":{"session_id":"legacy-session"}}
            \(tokenLine("2026-02-01T00:04:01Z", lastInput: 1, lastOutput: 1))
            """.utf8),
            source: "codex", fileIdentity: "legacy-path-b"
        )
        try require(legacyIdentityA.events[0].id == legacyIdentityB.events[0].id, "event id fallback must remain path-independent when rollout id is absent")
        // 缺 payload.id 时不能回退到共享的 session_id（同会话的多个 rollout 共享它，会被合并），
        // 直接以文件身份兜底：共享 session_id 的不同文件仍是不同 session。
        try require(
            legacyIdentityA.sessionEvents[0].sessionHash != legacyIdentityB.sessionEvents[0].sessionHash,
            "rollouts without payload.id must not merge via the shared session_id"
        )

        let child = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T01:00:00Z","type":"session_meta","payload":{"id":"rollout-child","session_id":"session-child","parent_thread_id":"rollout-parent"}}
            \(tokenLine("2026-02-01T01:00:01Z", lastInput: 6, lastOutput: 4, totalInput: 16, totalOutput: 9, total: 25))
            {"timestamp":"not-a-date","type":"turn_context","payload":{"model":"model-child"}}
            \(tokenLine("2026-02-01T01:00:03Z", lastInput: 3, lastOutput: 2, totalInput: 19, totalOutput: 11, total: 30))
            """.utf8),
            source: "codex", fileIdentity: "protocol-child"
        )
        try require(child.events.count == 2, "child token count")
        try require(child.events[0].parentRolloutKey == parent.events[0].rolloutKey, "parent_thread_id must resolve to parent rollout")
        try require(child.events[0].inherited && child.events[0].model == "unknown", "parent prefix must remain inherited and must not backfill unknown model")
        try require(!child.events[1].inherited && child.events[1].model == "model-child", "first turn_context must close inherited prefix even with invalid timestamp")
        try require(child.events[0].lineageFingerprint == parent.events[0].lineageFingerprint, "parent and inherited replay must share proof fingerprint")

        let nestedParent = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T02:00:00Z","type":"session_meta","payload":{"id":"rollout-nested-child","session_id":"session-nested-child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"rollout-parent"}}}}}
            \(tokenLine("2026-02-01T02:00:01Z", lastInput: 1, lastOutput: 1))
            """.utf8),
            source: "codex", fileIdentity: "protocol-nested-parent"
        )
        try require(nestedParent.events[0].parentRolloutKey == parent.events[0].rolloutKey && nestedParent.events[0].inherited, "nested thread_spawn parent reference")

        let forkedParent = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T02:10:00Z","type":"session_meta","payload":{"id":"rollout-fork-child","session_id":"session-fork-child","forked_from_id":"rollout-parent"}}
            \(tokenLine("2026-02-01T02:10:01Z", lastInput: 1, lastOutput: 1))
            """.utf8),
            source: "codex", fileIdentity: "protocol-fork-parent"
        )
        try require(forkedParent.events[0].parentRolloutKey == parent.events[0].rolloutKey && forkedParent.events[0].inherited, "forked_from_id parent reference")

        let conflict = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T03:00:00Z","type":"session_meta","payload":{"id":"rollout-conflict","session_id":"session-conflict","parent_thread_id":"parent-a","forked_from_id":"parent-b"}}
            \(tokenLine("2026-02-01T03:00:01Z", lastInput: 2, lastOutput: 1, totalInput: 2, totalOutput: 1, total: 3))
            """.utf8),
            source: "codex", fileIdentity: "protocol-conflict"
        )
        try require(conflict.events[0].inherited && conflict.events[0].parentRolloutKey.isEmpty, "conflicting parents must retain fail-safe inherited state without choosing a parent")
        try require(conflict.events[0].lineageFingerprint.isEmpty, "conflicting parents must disable lineage proof")
        try require(conflict.diagnostics.contains { $0.contains("conflicting parent") }, "conflicting parents must be diagnosed")

        let noParentBackfill = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T04:00:00Z","type":"session_meta","payload":{"id":"rollout-backfill","session_id":"session-backfill"}}
            \(tokenLine("2026-02-01T04:00:01Z", lastInput: 2, lastOutput: 2, totalInput: 2, totalOutput: 2, total: 4))
            {"timestamp":"2026-02-01T04:00:02Z","type":"turn_context","payload":{"model":"model-backfilled"}}
            """.utf8),
            source: "codex", fileIdentity: "protocol-backfill"
        )
        try require(noParentBackfill.events[0].model == "model-backfilled", "no-parent unknown model should be safely backfilled")

        let stableSourceA = """
        {"timestamp":"2026-02-01T05:00:00Z","type":"session_meta","payload":{"id":"rollout-stable","session_id":"session-stable"}}
        {"timestamp":"2026-02-01T05:00:01Z","type":"turn_context","payload":{"model":"model-stable"}}
        \(tokenLine("2026-02-01T05:00:02Z", lastInput: 7, lastOutput: 3, totalInput: 17, totalOutput: 8, total: 25))
        \(tokenLine("2026-02-01T05:00:03Z", lastInput: 7, lastOutput: 3, totalInput: 17, totalOutput: 8, total: 25))
        """
        let stableSourceB = """
        {"timestamp":"2026-02-01T05:30:00Z","type":"session_meta","payload":{"id":"rollout-stable","session_id":"session-stable"}}
        {"timestamp":"2026-02-01T05:30:01Z","type":"turn_context","payload":{"model":"model-stable"}}
        {"timestamp":"2026-02-01T05:30:02Z","type":"response_item","payload":{"type":"message","role":"assistant"}}
        \(tokenLine("2026-02-01T05:30:03Z", lastInput: 7, lastOutput: 3, totalInput: 17, totalOutput: 8, total: 25))
        """
        let stableA = UsageJSONLParser.parse(data: Data(stableSourceA.utf8), source: "codex", fileIdentity: "stable-a")
        let stableB = UsageJSONLParser.parse(data: Data(stableSourceB.utf8), source: "codex", fileIdentity: "stable-b")
        try require(stableA.events.count == 2, "repeated codex token_count events in one rollout are each counted once")
        try require(stableA.events[0].id == stableB.events[0].id, "Codex event id must ignore path, timestamp, and line index")
        try require(stableA.events[1].id != stableA.events[0].id, "a repeated codex event gets a distinct ordinal id, not a collapsed duplicate")
        // Content dedup key is content-only: byte-identical turns (same model + last +
        // total snapshot) share it across files/timestamps, so the finalize fold can
        // collapse fork/replay copies into one bucket contribution.
        try require(!stableA.events[0].codexDedupKey.isEmpty, "a complete-snapshot codex event must carry a content dedup key")
        try require(stableA.events[0].codexDedupKey == stableA.events[1].codexDedupKey, "byte-identical repeated turns share one content dedup key")
        try require(stableA.events[0].codexDedupKey == stableB.events[0].codexDedupKey, "content dedup key ignores path and timestamp across files")

        let incompleteTotal = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T06:00:00Z","type":"session_meta","payload":{"id":"rollout-incomplete","session_id":"session-incomplete"}}
            {"timestamp":"2026-02-01T06:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3},"total_token_usage":{"output_tokens":1,"total_tokens":3}}}}
            """.utf8),
            source: "codex", fileIdentity: "protocol-incomplete"
        )
        try require(!incompleteTotal.events[0].hasTotalSnapshot && incompleteTotal.events[0].lineageFingerprint.isEmpty, "complete total snapshot requires numeric input/output/total fields")
        try require(incompleteTotal.events[0].codexDedupKey.isEmpty, "an incomplete total snapshot yields no content dedup key (never folded)")

        let inconsistentTotal = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T06:10:00Z","type":"session_meta","payload":{"id":"rollout-inconsistent","session_id":"session-inconsistent"}}
            {"timestamp":"2026-02-01T06:10:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3},"total_token_usage":{"input_tokens":2,"output_tokens":1,"total_tokens":99}}}}
            """.utf8),
            source: "codex", fileIdentity: "protocol-inconsistent"
        )
        try require(!inconsistentTotal.events[0].hasTotalSnapshot && inconsistentTotal.events[0].lineageFingerprint.isEmpty, "total snapshot must be numerically self-consistent")

        let cumulative = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T07:00:00Z","type":"session_meta","payload":{"id":"rollout-cumulative","session_id":"session-cumulative"}}
            {"timestamp":"2026-02-01T07:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":80,"output_tokens":20,"total_tokens":100}}}}
            {"timestamp":"2026-02-01T07:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":30,"total_tokens":130}}}}
            {"timestamp":"2026-02-01T07:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":8,"output_tokens":2,"total_tokens":10}}}}
            {"timestamp":"2026-02-01T07:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18,"output_tokens":7,"total_tokens":25}}}}
            """.utf8),
            source: "codex", fileIdentity: "protocol-cumulative"
        )
        try require(cumulative.events.map { $0.counts.total } == [100, 30, 10, 15], "cumulative rollback snapshot must emit and establish a fresh baseline")
        try require(cumulative.diagnostics.contains { $0.contains("baseline reset") }, "cumulative rollback must be diagnosed")

        let claude = UsageJSONLParser.parse(
            data: Data("""
            {"type":"user","timestamp":"2026-02-01T08:00:00Z","sessionId":"claude-session","message":{"content":[{"type":"tool_result","tool_use_id":"fixture-tool","content":"fixture-result"}]}}
            {"type":"user","timestamp":"2026-02-01T08:00:01Z","sessionId":"claude-session","message":{"content":[{"type":"text","text":"fixture-prompt"}]}}
            {"type":"assistant","timestamp":"2026-02-01T08:00:02Z","sessionId":"claude-session","message":{"id":"fixture-message","model":"claude-fixture","usage":{"output_tokens":1,"total_tokens":1}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-tool-result-fixture"
        )
        try require(claude.sessionEvents.map(\.role) == [.syntheticUser, .user, .assistant], "Claude tool_result user row must not count as a real prompt")
        try require(!claude.events[0].hasTotalSnapshot, "Claude message usage is not a Codex total_token_usage lineage snapshot")

        let relocatedClaude = UsageJSONLParser.parse(
            data: Data("""
            {"type":"progress","timestamp":"2026-02-01T07:59:59Z"}
            {"type":"user","timestamp":"2026-02-01T08:00:00Z","sessionId":"claude-session","message":{"content":[{"type":"tool_result","tool_use_id":"fixture-tool","content":"fixture-result"}]}}
            {"type":"user","timestamp":"2026-02-01T08:00:01Z","sessionId":"claude-session","message":{"content":[{"type":"text","text":"fixture-prompt"}]}}
            {"type":"assistant","timestamp":"2026-02-01T08:00:02Z","sessionId":"claude-session","message":{"id":"fixture-message","model":"claude-fixture","usage":{"output_tokens":1,"total_tokens":1}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-tool-result-relocated"
        )
        try require(
            claude.sessionEvents.map(\.id) == relocatedClaude.sessionEvents.map(\.id),
            "Claude session event ids must survive path changes and line relocation"
        )
    }


    // 1b) Claude 原生 reasoning 缺失时，按 thinking / 其余输出字符比例把 output 拆入 reasoning
    //     （round-half-up，仅 Anthropic 家族）；有原生 reasoning 时优先，不拆；非 Anthropic 不拆。
    private static func verifyV2ClaudeReasoningSplit() throws {
        // thinking 6 字符 + text 2 字符（"hi"），一 turn output=100。
        // est = round-half-up(100*6 / 8) = round-half-up(600/8=75) = 75；output 变 25。
        let split = UsageJSONLParser.parse(
            data: Data("""
            {"type":"assistant","timestamp":"2026-02-02T00:00:00Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-split","model":"claude-opus","content":[{"type":"thinking","thinking":"abcdef"},{"type":"text","text":"hi"}],"usage":{"output_tokens":100,"input_tokens":0,"total_tokens":100}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-split"
        )
        try require(split.events.count == 1, "reasoning split single turn")
        try require(split.events[0].counts.reasoningOutput == 75, "thinking split must carve round-half-up reasoning: got \(split.events[0].counts.reasoningOutput)")
        try require(split.events[0].counts.output == 25, "carved reasoning must be subtracted from output: got \(split.events[0].counts.output)")
        try require(split.events[0].counts.total == 100, "split must not change turn total: got \(split.events[0].counts.total)")

        // thinking 跨同 turn 多行 union（每行重复整 turn usage，output 不叠加）。
        // 行1 thinking 6，行2 text 2；合并后同上 est=75。usage 取最大（此处相同）。
        let multiline = UsageJSONLParser.parse(
            data: Data("""
            {"type":"assistant","timestamp":"2026-02-02T00:00:00Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-ml","model":"claude-sonnet","content":[{"type":"thinking","thinking":"abcdef"}],"usage":{"output_tokens":100,"total_tokens":100}}}
            {"type":"assistant","timestamp":"2026-02-02T00:00:01Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-ml","model":"claude-sonnet","content":[{"type":"text","text":"hi"}],"usage":{"output_tokens":100,"total_tokens":100}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-split-ml"
        )
        try require(multiline.events.count == 1, "multiline turn collapses to one event")
        try require(multiline.events[0].counts.reasoningOutput == 75 && multiline.events[0].counts.output == 25, "thinking split must union chars across a turn's lines")

        // 有原生 reasoning 时优先，不再拆分。
        let native = UsageJSONLParser.parse(
            data: Data("""
            {"type":"assistant","timestamp":"2026-02-02T00:00:00Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-native","model":"claude-opus","content":[{"type":"thinking","thinking":"abcdef"},{"type":"text","text":"hi"}],"usage":{"output_tokens":100,"reasoning_output_tokens":10,"total_tokens":100}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-native"
        )
        try require(native.events[0].counts.reasoningOutput == 10 && native.events[0].counts.output == 100, "native reasoning must take precedence over the char split (output left as reported)")

        // 非 Anthropic 家族不拆（避免把计费 token 移入定价可能为 0 的 reasoning）。
        let nonAnthropic = UsageJSONLParser.parse(
            data: Data("""
            {"type":"assistant","timestamp":"2026-02-02T00:00:00Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-other","model":"gpt-some-model","content":[{"type":"thinking","thinking":"abcdef"},{"type":"text","text":"hi"}],"usage":{"output_tokens":100,"total_tokens":100}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-non-anthropic"
        )
        try require(nonAnthropic.events[0].counts.reasoningOutput == 0 && nonAnthropic.events[0].counts.output == 100, "non-anthropic model must not be split")

        // 无 thinking 文本则不拆。
        let noThinking = UsageJSONLParser.parse(
            data: Data("""
            {"type":"assistant","timestamp":"2026-02-02T00:00:00Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-nt","model":"claude-opus","content":[{"type":"text","text":"only text"}],"usage":{"output_tokens":100,"total_tokens":100}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-no-thinking"
        )
        try require(noThinking.events[0].counts.reasoningOutput == 0 && noThinking.events[0].counts.output == 100, "no thinking text => no split")

        // Int64.max * thinkingChars 会超过 Int64；拆分必须用 full-width 算术且保持总量。
        let overflowBoundary = UsageJSONLParser.parse(
            data: Data("""
            {"type":"assistant","timestamp":"2026-02-02T00:00:00Z","sessionId":"cs","cwd":"/w/p","message":{"id":"m-overflow","model":"claude-opus","content":[{"type":"thinking","thinking":"aa"},{"type":"text","text":"b"}],"usage":{"output_tokens":9223372036854775807}}}
            """.utf8),
            source: "claude-code", fileIdentity: "claude-overflow"
        )
        let overflowCounts = overflowBoundary.events[0].counts
        try require(overflowCounts.reasoningOutput > 0 && overflowCounts.output > 0, "overflow-safe split must preserve both sides")
        try require(overflowCounts.reasoningOutput + overflowCounts.output == Int64.max, "overflow-safe split must preserve Int64.max total")
    }

    // 1c) Claude subagent transcript：token 计入，但不产生任何 session 事件，且不做 thinking 拆分。
    private static func verifyV2ClaudeSubagent() throws {
        let transcript = """
        {"type":"user","timestamp":"2026-02-03T00:00:00Z","sessionId":"sub-session","message":{"content":[{"type":"text","text":"subagent prompt"}]}}
        {"type":"assistant","timestamp":"2026-02-03T00:00:01Z","sessionId":"sub-session","cwd":"/w/p","message":{"id":"sub-msg","model":"claude-opus","content":[{"type":"thinking","thinking":"abcdef"},{"type":"text","text":"hi"}],"usage":{"output_tokens":100,"input_tokens":5,"total_tokens":105}}}
        """
        let sub = UsageJSONLParser.parse(data: Data(transcript.utf8), source: "claude-code", fileIdentity: "sub.jsonl", isSubagent: true)
        try require(sub.events.count == 1, "subagent token usage must be counted")
        try require(sub.sessionEvents.isEmpty, "subagent transcript must emit no session events")
        try require(sub.events[0].counts.output == 100 && sub.events[0].counts.reasoningOutput == 0, "subagent path must not carve thinking out of output")
        try require(sub.events[0].counts.total == 105, "subagent token total preserved")

        // 同一转录作为主会话解析时，应产生 session 事件并做拆分，验证 isSubagent 是唯一差异。
        let asMain = UsageJSONLParser.parse(data: Data(transcript.utf8), source: "claude-code", fileIdentity: "sub.jsonl")
        try require(!asMain.sessionEvents.isEmpty, "main transcript must emit session events")
        try require(asMain.events[0].counts.reasoningOutput == 75, "main transcript must apply the thinking split")
    }

    // 2) session 算法：去重/分组/排序、活跃秒数、非synthetic user 计数、UTC 直方图（按 user prompt）。
    private static func verifyV2SessionAlgorithm() throws {
        func ev(_ id: String, _ role: UsageSessionEvent.Role, _ iso: String) -> UsageSessionEvent {
            UsageSessionEvent(id: id, source: "codex", sessionHash: "sess", role: role, timestamp: UsageTimestamp.parse(iso)!)
        }
        // user(00:00) -> assistant(00:00:10) -> assistant(00:00:40) -> user(00:01:00) -> assistant(00:01:30)
        // 段1: 10..40 => 30s；段2: 由第二个 user 锚定，仅一个 assistant(90) => 0s。活跃=30s。
        let events = [
            ev("u1", .user, "2026-03-01T00:00:00Z"),
            ev("a1", .assistant, "2026-03-01T00:00:10Z"),
            ev("a2", .assistant, "2026-03-01T00:00:40Z"),
            ev("u2", .user, "2026-03-01T00:01:00Z"),
            ev("a3", .assistant, "2026-03-01T00:01:30Z"),
            ev("syn", .syntheticUser, "2026-03-01T00:02:00Z"),
            ev("a1", .assistant, "2026-03-01T00:00:10Z"), // (source,id) 去重
        ]
        let sessions = UsageSessionAggregator.aggregate(events: events, hostname: "h")
        try require(sessions.count == 1, "single session group")
        let s = sessions[0]
        try require(s.activeSeconds == 30, "active seconds segment rule: got \(s.activeSeconds)")
        try require(s.userMessageCount == 2, "non-synthetic user count (synthetic excluded): got \(s.userMessageCount)")
        try require(s.assistantEvents == 3, "assistant events count: got \(s.assistantEvents)")
        try require(s.messageCount == 6, "deduped total message count: got \(s.messageCount)")
        // 直方图按 user prompt 落 UTC 00 点，共 2 个非 synthetic user。
        try require(s.hourHistogramUTC[0] == 2, "UTC histogram must count non-synthetic user prompts at hour 0")
        try require(s.hourHistogramUTC.reduce(0,+) == 2, "histogram total equals user prompts, not assistant")

        // project 内容字段：默认解析为空串，不参与自然键。
        try require(s.project == "", "session project must default to empty when no resolver is provided")

        // 注入 project resolver：project 作为内容字段贯通，但自然键 (source, sessionHash)
        // 与分组 / 聚合结果保持不变。
        let withProject = UsageSessionAggregator.aggregate(events: events, hostname: "h") { source, sessionHash in
            source == "codex" && sessionHash == "sess" ? "acme" : ""
        }
        try require(withProject.count == 1, "project resolver must not change session grouping")
        let ps = withProject[0]
        try require(ps.project == "acme", "resolved project must flow into session content field: got \(ps.project)")
        try require(
            ps.source == s.source && ps.sessionHash == s.sessionHash
                && ps.activeSeconds == s.activeSeconds && ps.messageCount == s.messageCount,
            "project must be a content field only; natural key and aggregates must be unchanged"
        )
    }

    // 3) Claude 同一行（同 uuid / 无 uuid 回退键）重扫：文件级替换 + 同 event id 覆盖，不重复累加。
    private static func verifyV2ClaudeGrowth() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        let ledger = try UsageLedgerStore(path: db.path)
        let ts = "2026-04-01T00:00:00Z"
        func line(_ output: Int) -> String {
            "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"sessionId\":\"cs\",\"cwd\":\"/w/p\",\"message\":{\"id\":\"m1\",\"model\":\"claude-x\",\"usage\":{\"output_tokens\":\(output),\"total_tokens\":\(output)}}}"
        }
        // 首次上报 output=40
        let p1 = UsageJSONLParser.parse(data: Data(line(40).utf8), source: "claude-code", fileIdentity: "claude-grow")
        try ledger.record(events: p1.events, sessionEvents: p1.sessionEvents, checkpoint: p1.checkpoint, hostname: "h")
        try ledger.finalizeDerived(hostname: "h")
        let claudeInitial = try ledger.buckets(hostname: "h")
        try require(claudeInitial.first?.counts.total == 40, "claude initial usage")
        // 同 msg.id 增长到 120（同文件重扫），应升到 120，而不是 40+120。
        let p2 = UsageJSONLParser.parse(data: Data(line(120).utf8), source: "claude-code", fileIdentity: "claude-grow")
        try ledger.record(events: p2.events, sessionEvents: p2.sessionEvents, checkpoint: p2.checkpoint, hostname: "h")
        try ledger.finalizeDerived(hostname: "h")
        let claudeRows = try ledger.eventCount()
        let claudeGrown = try ledger.buckets(hostname: "h")
        try require(claudeRows == 1, "claude same line must stay one row")
        try require(claudeGrown.first?.counts.total == 120, "claude re-scan must overwrite to latest, not drop or double: got \(claudeGrown.first?.counts.total ?? -1)")
    }


    // 4) Codex 继承回放去重（血缘证明）+ 无法证明时 reporting blocked 失效保护。
    private static func verifyV2InheritedReplayDedup() throws {
        // 4a) 父与子（subagent）各自文件都含相同 total 快照 -> 血缘指纹一致 -> 折叠为一，可上报。
        let dbA = tempUsageDB(); defer { cleanupDB(dbA) }
        let ledgerA = try UsageLedgerStore(path: dbA.path)
        let ts = "2026-05-01T00:00:00Z"
        func totalLine(_ ts: String, out: Int, total: Int) -> String {
            "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"output_tokens\":\(out),\"input_tokens\":0,\"total_tokens\":\(total)}}}}"
        }
        let parent = """
        {"type":"session_meta","payload":{"id":"parent-1","session_id":"parent-session-1","cwd":"/w/p"}}
        {"type":"turn_context","payload":{"model":"m"}}
        \(totalLine(ts, out: 100, total: 100))
        """
        // child subagent replays the parent's total snapshot (parent_id points to parent-1).
        let child = """
        {"type":"session_meta","payload":{"id":"child-1","session_id":"child-session-1","parent_thread_id":"parent-1","cwd":"/w/p"}}
        \(totalLine(ts, out: 100, total: 100))
        """
        let pp = UsageJSONLParser.parse(data: Data(parent.utf8), source: "codex", fileIdentity: "parent.jsonl")
        let cp = UsageJSONLParser.parse(data: Data(child.utf8), source: "codex", fileIdentity: "child.jsonl")
        // 血缘指纹须一致（child 锚父 rollout；parent 锚自身 rollout；两者 root 都是 parent-1）。
        try require(!pp.events[0].lineageFingerprint.isEmpty, "parent must have lineage fingerprint (has total snapshot)")
        try require(pp.events[0].lineageFingerprint == cp.events[0].lineageFingerprint, "parent/child replay must share lineage fingerprint")
        try ledgerA.record(events: pp.events, sessionEvents: pp.sessionEvents, checkpoint: pp.checkpoint, hostname: "h")
        try ledgerA.record(events: cp.events, sessionEvents: cp.sessionEvents, checkpoint: cp.checkpoint, hostname: "h")
        let resultA = try ledgerA.finalizeDerived(hostname: "h")
        let rawRetained = try ledgerA.eventCount()
        let collapsedBuckets = try ledgerA.buckets(hostname: "h")
        try require(rawRetained == 2, "both raw events retained (append-only)")
        try require(collapsedBuckets.first?.counts.total == 100, "inherited replay must collapse to a single 100, not 200")
        try require(resultA.collapsedInheritedEvents == 1, "one inherited event collapsed")
        try require(resultA.reportingEligible, "provable dedup keeps reporting eligible")

        // 4b) 继承回放但只有 last_token_usage（无完整 total 快照）-> 无法证明 -> reporting blocked。
        let dbB = tempUsageDB(); defer { cleanupDB(dbB) }
        let ledgerB = try UsageLedgerStore(path: dbB.path)
        func lastLine(_ ts: String, out: Int) -> String {
            "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"output_tokens\":\(out),\"total_tokens\":\(out)}}}}"
        }
        let childNoSnapshot = """
        {"type":"session_meta","payload":{"id":"child-2","session_id":"child-session-2","parent_thread_id":"parent-2","cwd":"/w/p"}}
        \(lastLine(ts, out: 70))
        """
        let cnp = UsageJSONLParser.parse(data: Data(childNoSnapshot.utf8), source: "codex", fileIdentity: "child2.jsonl")
        try require(cnp.events[0].inherited, "child must be flagged inherited")
        try require(cnp.events[0].lineageFingerprint.isEmpty, "no total snapshot => no lineage fingerprint")
        try ledgerB.record(events: cnp.events, sessionEvents: cnp.sessionEvents, checkpoint: cnp.checkpoint, hostname: "h")
        let resultB = try ledgerB.finalizeDerived(hostname: "h")
        try require(!resultB.reportingEligible, "unprovable inherited replay must block reporting")
        try require(!resultB.blockedReasons.isEmpty, "blocked reasons must be reported")
        let eligibleFlag = try ledgerB.reportingEligible(hostname: "h")
        try require(!eligibleFlag, "reportingEligible(hostname:) reflects blocked state")
    }


    // 4b) 归档去重：同一 rollout 内容先后以 sessions/ 与 archived_sessions/ 两条路径扫描，
    // 只聚合一个 session，token 与会话消息均不重复。
    private static func verifyV2ArchivedSessionIdentity() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        let ledger = try UsageLedgerStore(path: db.path)
        let rollout = """
        {"timestamp":"2026-05-01T00:00:00Z","type":"session_meta","payload":{"id":"rollout-archive","session_id":"session-archive","cwd":"/w/p"}}
        {"timestamp":"2026-05-01T00:00:01Z","type":"turn_context","payload":{"model":"m"}}
        {"timestamp":"2026-05-01T00:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":3,"output_tokens":7,"total_tokens":10}}}}
        """
        let data = Data(rollout.utf8)
        // 模拟文件从 sessions/ 移动到 archived_sessions/：内容相同，路径不同。
        let live = UsageJSONLParser.parse(data: data, source: "codex", fileIdentity: "/workspace/.codex/sessions/2026/05/01/rollout-archive.jsonl")
        try ledger.record(events: live.events, sessionEvents: live.sessionEvents, checkpoint: live.checkpoint, hostname: "h")
        try ledger.finalizeDerived(hostname: "h")
        let archived = UsageJSONLParser.parse(data: data, source: "codex", fileIdentity: "/workspace/.codex/archived_sessions/rollout-archive.jsonl")
        try ledger.record(events: archived.events, sessionEvents: archived.sessionEvents, checkpoint: archived.checkpoint, hostname: "h")
        try ledger.finalizeDerived(hostname: "h")

        let sessions = try ledger.sessions(hostname: "h")
        try require(sessions.count == 1, "archival move must not duplicate the session: got \(sessions.count)")
        let buckets = try ledger.buckets(hostname: "h")
        try require(buckets.count == 1 && buckets[0].counts.total == 10, "tokens must not double after archival re-scan")
        let rawEventCount = try ledger.eventCount()
        let rawSessionEventCount = try ledger.sessionEventCount()
        // v8：raw 层 PK 含 source_file_hash，跨文件同 logical event_id 共存（归档移动=两个文件身份）；
        // 去重发生在聚合层（sessions/buckets 已断言不重复），raw 行数=每文件事件数之和。
        try require(rawEventCount == 2, "token raw rows coexist across files (v8): got \(rawEventCount)")
        try require(rawSessionEventCount == 6, "session raw rows coexist across files (v8): got \(rawSessionEventCount)")
        let s = sessions[0]
        try require(s.messageCount == 3 && s.userMessageCount == 1, "session timeline preserved exactly once")
    }

    // 5) 逐行 dirty/ack race + 精确 ack + 重启恢复。
    private static func verifyV2DirtyAckRaceAndRestart() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        func codexFile(_ session: String, ts: String, out: Int) -> String {
            """
            {"type":"session_meta","payload":{"session_id":"\(session)","thread_source":"user","cwd":"/w/p"}}
            {"type":"turn_context","payload":{"model":"m"}}
            {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":\(out),"total_tokens":\(out)}}}}
            """
        }
        var ledger: UsageLedgerStore? = try UsageLedgerStore(path: db.path)
        // 两个不同 bucket（不同小时）来制造两行。
        let f1 = UsageJSONLParser.parse(data: Data(codexFile("s1", ts: "2026-06-01T00:00:00Z", out: 100).utf8), source: "codex", fileIdentity: "f1.jsonl")
        let f2 = UsageJSONLParser.parse(data: Data(codexFile("s2", ts: "2026-06-01T01:00:00Z", out: 200).utf8), source: "codex", fileIdentity: "f2.jsonl")
        try ledger!.record(events: f1.events, sessionEvents: f1.sessionEvents, checkpoint: f1.checkpoint, hostname: "h")
        try ledger!.record(events: f2.events, sessionEvents: f2.sessionEvents, checkpoint: f2.checkpoint, hostname: "h")
        try ledger!.finalizeDerived(hostname: "h")

        // pending 全量（2 桶）。逐行 ack。
        let batch = try ledger!.pendingBatch(hostname: "h")
        try require(batch.buckets.count == 2, "two dirty buckets pending: got \(batch.buckets.count)")
        try require(batch.buckets.allSatisfy { $0.revision > 0 }, "pending rows carry revision snapshot")

        // 模拟上传期间：ack 之前，其中一个 bucket 因新数据被 finalize 重算（revision 抬升）。
        let f1b = UsageJSONLParser.parse(data: Data(codexFile("s1", ts: "2026-06-01T00:10:00Z", out: 101).utf8), source: "codex", fileIdentity: "f1b.jsonl")
        try ledger!.record(events: f1b.events, sessionEvents: f1b.sessionEvents, checkpoint: f1b.checkpoint, hostname: "h")
        try ledger!.finalizeDerived(hostname: "h") // 00:00 桶变为 200，revision 抬升

        // 用旧 batch 的 revision 快照 ack：只有未变化的 01:00 桶匹配并被标记 synced；00:00 桶保持 dirty。
        try ledger!.acknowledge(batch)
        let afterAck = try ledger!.pendingBatch(hostname: "h")
        try require(afterAck.buckets.count == 1, "row changed during upload must remain dirty (exact revision ack): got \(afterAck.buckets.count)")
        try require(afterAck.buckets[0].bucket.counts.total == 201, "the still-dirty bucket is the recomputed 00:00 one")

        // 重启：重开数据库，dirty 状态与派生数据须保留。
        ledger = nil
        let reopened = try UsageLedgerStore(path: db.path)
        let afterRestart = try reopened.pendingBatch(hostname: "h")
        try require(afterRestart.buckets.count == 1, "dirty state must survive restart")
        let restartBuckets = try reopened.buckets(hostname: "h")
        try require(restartBuckets.count == 2, "derived buckets must survive restart")
        // 硬上限：maxBuckets=1 时只返回一行且 hasMore。
        // 先制造两条 dirty：ack 掉当前 dirty，再改两个桶。
        try reopened.acknowledge(afterRestart)
        let g1 = UsageJSONLParser.parse(data: Data(codexFile("s1", ts: "2026-06-01T00:20:00Z", out: 102).utf8), source: "codex", fileIdentity: "g1.jsonl")
        let g2 = UsageJSONLParser.parse(data: Data(codexFile("s2", ts: "2026-06-01T01:20:00Z", out: 201).utf8), source: "codex", fileIdentity: "g2.jsonl")
        try reopened.record(events: g1.events, sessionEvents: g1.sessionEvents, checkpoint: g1.checkpoint, hostname: "h")
        try reopened.record(events: g2.events, sessionEvents: g2.sessionEvents, checkpoint: g2.checkpoint, hostname: "h")
        try reopened.finalizeDerived(hostname: "h")
        let limited = try reopened.pendingBatch(hostname: "h", maxBuckets: 1, maxSessions: nil)
        try require(limited.buckets.count == 1 && limited.hasMore, "hard bucket limit must cap batch and set hasMore")
    }

    // 5b) last_synced_at 只表示实际 ACK 进展：空批次、全 stale、重复 ACK 均不得推进；
    // partial ACK 只要至少一行仍精确匹配，就应落账并推进时间。
    private static func verifyV2AcknowledgeProgressTimestamp() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        let ledger = try UsageLedgerStore(path: db.path)
        func codexFile(_ session: String, ts: String, out: Int, file: String) -> ParsedUsageFile {
            UsageJSONLParser.parse(
                data: Data("""
                {"type":"session_meta","payload":{"session_id":"\(session)","thread_source":"user","cwd":"/workspace/p"}}
                {"type":"turn_context","payload":{"model":"m"}}
                {"timestamp":"\(ts)","type":"response_item","payload":{"type":"message","role":"assistant"}}
                {"timestamp":"\(ts)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":\(out),"total_tokens":\(out)}}}}
                """.utf8),
                source: "codex",
                fileIdentity: file
            )
        }

        let empty = UsagePendingBatch(hostname: "h", buckets: [], sessions: [], hasMore: false)
        try ledger.acknowledge(empty)
        let emptyTimestamp = try ledger.lastSyncedAt(hostname: "h")
        try require(emptyTimestamp == nil, "empty ACK must not create a sync timestamp")

        let firstA = codexFile("a", ts: "2026-06-01T00:00:00Z", out: 100, file: "ack-a1.jsonl")
        let firstB = codexFile("b", ts: "2026-06-01T01:00:00Z", out: 200, file: "ack-b1.jsonl")
        try ledger.record(events: firstA.events, sessionEvents: firstA.sessionEvents, checkpoint: firstA.checkpoint, hostname: "h")
        try ledger.record(events: firstB.events, sessionEvents: firstB.sessionEvents, checkpoint: firstB.checkpoint, hostname: "h")
        try ledger.finalizeDerived(hostname: "h")
        let fullyStale = try ledger.pendingBatch(hostname: "h")
        try require(fullyStale.buckets.count == 2 && fullyStale.sessions.count == 2, "stale ACK fixture must cover bucket and session rows")

        let secondA = codexFile("a", ts: "2026-06-01T00:10:00Z", out: 101, file: "ack-a1.jsonl")
        let secondB = codexFile("b", ts: "2026-06-01T01:10:00Z", out: 201, file: "ack-b1.jsonl")
        try ledger.record(
            events: secondA.events, sessionEvents: secondA.sessionEvents,
            checkpoint: UsageFileCheckpoint(
                fileID: secondA.checkpoint.fileID, source: secondA.checkpoint.source,
                pathHash: secondA.checkpoint.pathHash, offset: 2, size: 2,
                modifiedAt: secondA.checkpoint.modifiedAt.addingTimeInterval(1),
                parserVersion: secondA.checkpoint.parserVersion, status: secondA.checkpoint.status
            ),
            hostname: "h"
        )
        try ledger.record(
            events: secondB.events, sessionEvents: secondB.sessionEvents,
            checkpoint: UsageFileCheckpoint(
                fileID: secondB.checkpoint.fileID, source: secondB.checkpoint.source,
                pathHash: secondB.checkpoint.pathHash, offset: 2, size: 2,
                modifiedAt: secondB.checkpoint.modifiedAt.addingTimeInterval(1),
                parserVersion: secondB.checkpoint.parserVersion, status: secondB.checkpoint.status
            ),
            hostname: "h"
        )
        try ledger.finalizeDerived(hostname: "h")

        try ledger.acknowledge(fullyStale)
        let staleTimestamp = try ledger.lastSyncedAt(hostname: "h")
        try require(staleTimestamp == nil, "fully stale ACK must not advance last_synced_at")
        let beforePartial = try ledger.pendingCounts(hostname: "h")
        try require(beforePartial.buckets == 2 && beforePartial.sessions == 2, "fully stale ACK must leave every row pending")

        let partial = try ledger.pendingBatch(hostname: "h")
        let thirdA = codexFile("a", ts: "2026-06-01T00:20:00Z", out: 102, file: "ack-a1.jsonl")
        try ledger.record(
            events: thirdA.events, sessionEvents: thirdA.sessionEvents,
            checkpoint: UsageFileCheckpoint(
                fileID: thirdA.checkpoint.fileID, source: thirdA.checkpoint.source,
                pathHash: thirdA.checkpoint.pathHash, offset: 3, size: 3,
                modifiedAt: thirdA.checkpoint.modifiedAt.addingTimeInterval(2),
                parserVersion: thirdA.checkpoint.parserVersion, status: thirdA.checkpoint.status
            ),
            hostname: "h"
        )
        try ledger.finalizeDerived(hostname: "h")

        try ledger.acknowledge(partial)
        let partialTimestamp = try ledger.lastSyncedAt(hostname: "h")
        try require(partialTimestamp != nil, "partial ACK with matching rows must advance last_synced_at")
        let afterPartial = try ledger.pendingCounts(hostname: "h")
        try require(afterPartial.buckets == 1 && afterPartial.sessions == 1, "partial ACK must sync only the still-matching bucket and session")

        Thread.sleep(forTimeInterval: 0.01)
        try ledger.acknowledge(partial)
        let repeatedTimestamp = try ledger.lastSyncedAt(hostname: "h")
        try require(repeatedTimestamp == partialTimestamp, "repeating an already-applied/stale ACK must not advance last_synced_at")
        let afterRepeat = try ledger.pendingCounts(hostname: "h")
        try require(afterRepeat.buckets == 1 && afterRepeat.sessions == 1, "repeated ACK must not change pending rows")
    }


    // 6) hostname 改名：确认改名走原地 UPDATE，把本地历史全部旧名改成新名（单机口径，不保留多机）。
    // 「否」路径仅让新名生效、历史保留旧名（adoptHostname）。
    private static func verifyV2HostnameRebuild() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        let ledger = try UsageLedgerStore(path: db.path)
        let file = """
        {"type":"session_meta","payload":{"session_id":"s","thread_source":"user","cwd":"/w/p"}}
        {"type":"turn_context","payload":{"model":"m"}}
        {"timestamp":"2026-07-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":100,"total_tokens":100}}}}
        """
        let p = UsageJSONLParser.parse(data: Data(file.utf8), source: "codex", fileIdentity: "host.jsonl")
        try ledger.record(events: p.events, sessionEvents: p.sessionEvents, checkpoint: p.checkpoint, hostname: "old-host")
        try ledger.finalizeDerived(hostname: "old-host")
        let oldHostInitial = try ledger.buckets(hostname: "old-host")
        try require(oldHostInitial.count == 1, "old host derived present")
        let matchState = try ledger.hostnameState(current: "old-host")
        try require(matchState == .match, "hostname should match after first ingest")
        if case .mismatch = try ledger.hostnameState(current: "new-host") {} else { try require(false, "changed hostname must be detected as mismatch") }

        // 确认改名：历史全部原地改成 new-host，old-host 不再有派生行。
        try ledger.rebuildForHostname("new-host")
        let oldHostBuckets = try ledger.buckets(hostname: "old-host")
        let newHostBuckets = try ledger.buckets(hostname: "new-host")
        try require(oldHostBuckets.isEmpty, "in-place rename: old-host derived rows must be moved to new-host")
        try require(newHostBuckets.count == 1, "in-place rename: derived rows now attributed to new-host")
        try require(newHostBuckets.first?.counts.total == 100, "in-place rename preserves totals under new-host")
        // canonical hostname（本机身份）已更新为 new-host。
        let stateAfterRebuild = try ledger.hostnameState(current: "new-host")
        try require(stateAfterRebuild == .match, "canonical hostname updated to new host after rename")
        // 改名后 new-host 派生行为 dirty（自然键变化，需重新上报）。
        let pendingNew = try ledger.pendingBatch(hostname: "new-host")
        try require(!pendingNew.isEmpty, "renamed rows must be pending for re-upload under new-host")

        // 「否」路径（adoptHostname）：新名生效、历史保留旧名。
        let adoptDB = tempUsageDB(); defer { cleanupDB(adoptDB) }
        let adoptLedger = try UsageLedgerStore(path: adoptDB.path)
        try adoptLedger.record(events: p.events, sessionEvents: p.sessionEvents, checkpoint: p.checkpoint, hostname: "old-host")
        try adoptLedger.finalizeDerived(hostname: "old-host")
        try adoptLedger.adoptHostname("new-host")
        let adoptOldCount = try adoptLedger.buckets(hostname: "old-host").count
        let adoptNewEmpty = try adoptLedger.buckets(hostname: "new-host").isEmpty
        let adoptState = try adoptLedger.hostnameState(current: "new-host")
        try require(adoptOldCount == 1, "adopt: history stays under old name")
        try require(adoptNewEmpty, "adopt: no rows fabricated under new name")
        // 关键：adopt 后当前配置(new)==canonical(new) 即为 .match，绝不再触发弹窗循环。
        try require(adoptState == .match, "adopt: new name is now canonical, no re-prompt loop")
    }

    private static func verifyUniqueLegacyHostnameCandidate() throws {
        let emptyDB = tempUsageDB(); defer { cleanupDB(emptyDB) }
        let emptyLedger = try UsageLedgerStore(path: emptyDB.path)
        let emptyCandidate = try emptyLedger.uniqueLegacyHostnameCandidate()
        try require(
            emptyCandidate == nil,
            "empty ledger must not invent a legacy hostname"
        )

        let uniqueDB = tempUsageDB(); defer { cleanupDB(uniqueDB) }
        let uniqueLedger = try UsageLedgerStore(path: uniqueDB.path)
        let first = UsageJSONLParser.parse(
            data: Data("""
            {"type":"session_meta","payload":{"session_id":"legacy-one","cwd":"/w/p"}}
            {"type":"turn_context","payload":{"model":"m"}}
            {"timestamp":"2026-07-01T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":1,"total_tokens":1}}}}
            """.utf8),
            source: "codex",
            fileIdentity: "legacy-one.jsonl"
        )
        try uniqueLedger.record(
            events: first.events,
            sessionEvents: first.sessionEvents,
            checkpoint: first.checkpoint,
            hostname: "legacy-host"
        )
        try uniqueLedger.finalizeDerived(hostname: "legacy-host")
        let uniqueCandidate = try uniqueLedger.uniqueLegacyHostnameCandidate()
        try require(
            uniqueCandidate == "legacy-host",
            "a single durable hostname must be recoverable for legacy upgrade"
        )

        // 确认改名（原地 UPDATE）：legacy-host 派生行整体改到 second-host，
        // 因此唯一候选变为 second-host（legacy-host 已无派生行）。
        try uniqueLedger.rebuildForHostname("second-host")
        let rebuiltCandidate = try uniqueLedger.uniqueLegacyHostnameCandidate()
        try require(
            rebuiltCandidate == "second-host",
            "in-place rename moves the only host's rows, so second-host becomes the unique candidate"
        )

        let ambiguousDB = tempUsageDB(); defer { cleanupDB(ambiguousDB) }
        do {
            let seededLedger = try UsageLedgerStore(path: ambiguousDB.path)
            try seededLedger.record(
                events: first.events,
                sessionEvents: first.sessionEvents,
                checkpoint: first.checkpoint,
                hostname: "host-a"
            )
            try seededLedger.finalizeDerived(hostname: "host-a")
        }
        var handle: OpaquePointer?
        try require(sqlite3_open(ambiguousDB.path, &handle) == SQLITE_OK, "open ambiguous legacy db")
        let secondHostname = """
        INSERT INTO usage_buckets
          SELECT 'host-b',source,model,project,bucket_start_ms,input_tokens,output_tokens,
                 cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,
                 updated_at_ms,revision,synced_revision,skills_json,skill_counts_json,mcp_counts_json,
                 lines_added,lines_deleted,lines_net,code_metric_version
            FROM usage_buckets WHERE hostname='host-a';
        """
        try require(sqlite3_exec(handle, secondHostname, nil, nil, nil) == SQLITE_OK, "seed ambiguous legacy hosts")
        sqlite3_close(handle)
        handle = nil
        // Open only after seeding; migration adds the remaining tables and columns.
        let ambiguousLedger = try UsageLedgerStore(path: ambiguousDB.path)
        let ambiguousCandidate = try ambiguousLedger.uniqueLegacyHostnameCandidate()
        try require(
            ambiguousCandidate == nil,
            "multiple durable hostnames must remain fail-closed"
        )
    }

    // 7) v1 -> v2 迁移：老库补齐血缘列与新表，仍可读写。
    private static func verifyV2Migration() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        // 用原始 SQLite 建一个 user_version=1 的老库（v1 schema 子集 + 一行 event）。
        var handle: OpaquePointer?
        try require(sqlite3_open(db.path, &handle) == SQLITE_OK, "open raw db")
        let v1 = """
        CREATE TABLE usage_events(event_id TEXT PRIMARY KEY,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,session_hash TEXT NOT NULL,source_file_hash TEXT NOT NULL,created_at_ms INTEGER NOT NULL);
        CREATE TABLE usage_buckets(hostname TEXT NOT NULL,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,bucket_start_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL,PRIMARY KEY(hostname,source,model,project,bucket_start_ms));
        CREATE TABLE usage_files(file_id TEXT PRIMARY KEY,source TEXT NOT NULL,path_hash TEXT NOT NULL,read_offset INTEGER NOT NULL,file_size INTEGER NOT NULL,mtime_ms INTEGER NOT NULL,parser_version INTEGER NOT NULL,scan_status TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
        CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
        INSERT INTO usage_events VALUES('e1','codex','m','p',1000,0,50,0,0,0,50,'sh','fh',1000);
        PRAGMA user_version=1;
        """
        try require(sqlite3_exec(handle, v1, nil, nil, nil) == SQLITE_OK, "seed v1 schema")
        sqlite3_close(handle)

        // 打开走迁移到 v2。
        let ledger = try UsageLedgerStore(path: db.path)
        let migratedCount = try ledger.eventCount()
        try require(migratedCount == 1, "v1 event survives migration")
        // finalize 应能基于迁移后带默认血缘列的老事件重建派生。
        try ledger.finalizeDerived(hostname: "h")
        let migratedBuckets = try ledger.buckets(hostname: "h")
        try require(migratedBuckets.first?.counts.total == 50, "migrated event rebuilds into v2 derived bucket")
        // 新写入 + 会话事件在 v2 表可用。
        let file = """
        {"type":"session_meta","timestamp":"2026-08-01T00:00:00Z","payload":{"id":"migration-rollout","session_id":"s","cwd":"/w/p"}}
        {"type":"response_item","timestamp":"2026-08-01T00:00:00Z","payload":{"type":"message","role":"user"}}
        """
        let p = UsageJSONLParser.parse(data: Data(file.utf8), source: "codex", fileIdentity: "mig.jsonl")
        try ledger.record(events: p.events, sessionEvents: p.sessionEvents, checkpoint: p.checkpoint, hostname: "h")
        let migratedSessionEvents = try ledger.sessionEventCount()
        try require(migratedSessionEvents >= 1, "session events table usable after migration")
    }

    // v4->v5 迁移与 legacy 派生行对账：证明既有 revision=0/synced=0 派生行不会永远非 pending 也不会被静默删除，
    // 未绑定 host 的全局对账债务不被丢弃，且 DB 文件权限收紧到 0600。全部走公开 API + 原始 SQLite 播种。
    private static func verifyV5CleanUpgradeAndPermissions() throws {
        // 1) 干净升级：全新库无历史包袱时 reportingEligible 为真，常规写入/finalize/pending/ack/session 正常。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            let eligible = try ledger.reportingEligible(hostname: "fresh-host")
            try require(eligible, "fresh database must remain reporting eligible")
            let jsonl = """
            {"type":"session_meta","timestamp":"2026-08-01T00:00:00Z","payload":{"id":"r","session_id":"s","cwd":"/w/proj"}}
            {"type":"response_item","timestamp":"2026-08-01T00:00:00Z","payload":{"type":"message","role":"user"}}
            {"timestamp":"2026-08-01T00:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":5,"cached_input_tokens":0,"cache_creation_input_tokens":0,"reasoning_output_tokens":0,"total_tokens":15}}}}
            """
            let parsed = UsageJSONLParser.parse(data: Data(jsonl.utf8), source: "codex", fileIdentity: "fresh.jsonl")
            try ledger.record(events: parsed.events, sessionEvents: parsed.sessionEvents, checkpoint: parsed.checkpoint, hostname: "fresh-host")
            let result = try ledger.finalizeDerived(hostname: "fresh-host")
            try require(result.reportingEligible, "fresh finalize must be eligible")
            let batch = try ledger.pendingBatch(hostname: "fresh-host")
            try require(!batch.buckets.isEmpty, "freshly finalized buckets must be pending (revision>synced)")
            let sessions = try ledger.sessions(hostname: "fresh-host")
            try require(sessions.count == 1 && sessions[0].messageCount == 3, "session aggregation must produce one session from the recorded activity events")
            try ledger.acknowledge(batch)
            let afterAck = try ledger.pendingBatch(hostname: "fresh-host")
            try require(afterAck.isEmpty, "ack must clear pending for matching revision snapshot")
        }

        // 2) DB 文件权限：db / -wal / -shm 均收紧到 0600（无 group/other 位）。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            for suffix in ["", "-wal", "-shm"] {
                let target = db.path + suffix
                guard FileManager.default.fileExists(atPath: target) else { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: target)
                let perm = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
                try require(perm & 0o077 == 0, "usage DB file must not grant group/other access")
            }
        }
    }



    // 8) parser rebuild 检测、revision 单调性与无 tombstone 时的全局上报门禁。

    // 7b) v8 legacy/owned 去重：聚合前按归属优先级选行
    //     (ownedActive > ownedHistory > legacy)，有更高优先级时完全忽略低级旧行；
    //     删除/mark missing active 后历史仍保留；token/session/edit 同口径；
    //     overwrite 同 tier 计数冲突 fail-closed。
    private static func verifyV8LegacyOwnedDedup() throws {
        func open(_ path: String) throws -> OpaquePointer? {
            var handle: OpaquePointer?
            try require(sqlite3_open(path, &handle) == SQLITE_OK, "open v8 db for direct seed")
            return handle
        }
        func run(_ handle: OpaquePointer?, _ sql: String, _ label: String) throws {
            try require(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK,
                        "\(label): \(String(cString: sqlite3_errmsg(handle)))")
        }
        // 直接写一条 owned/legacy token 行（跳过 record 的按 fileID 归属，模拟迁移后的真实混合库）。
        func insertEvent(_ handle: OpaquePointer?, eventID: String, source: String = "codex",
                         model: String = "m", project: String = "p", ts: Int64 = 0, output: Int64,
                         session: String = "s", fileHash: String, strategy: String = "overwrite") throws {
            try run(handle, """
            INSERT INTO usage_events
            (event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,source_file_hash,rollout_key,parent_rollout_key,inherited,has_total_snapshot,lineage_fingerprint,merge_strategy,skill_counts_json,mcp_counts_json,created_at_ms)
            VALUES ('\(eventID)','\(source)','\(model)','\(project)',\(ts),0,\(output),0,0,0,\(output),'\(session)','\(fileHash)','','',0,0,'','\(strategy)','{}','{}',1);
            """, "insert usage_events \(eventID)/\(fileHash)")
        }
        func insertSessionEvent(_ handle: OpaquePointer?, eventID: String, source: String = "codex",
                                session: String = "s", role: String, ts: Int64, fileHash: String) throws {
            try run(handle, """
            INSERT INTO usage_session_events
            (event_id,source,session_hash,role,timestamp_ms,source_file_hash,created_at_ms)
            VALUES ('\(eventID)','\(source)','\(session)','\(role)',\(ts),'\(fileHash)',1);
            """, "insert usage_session_events \(eventID)/\(fileHash)")
        }
        func insertEdit(_ handle: OpaquePointer?, toolUseID: String, source: String = "codex",
                        model: String = "m", project: String = "p", ts: Int64 = 0,
                        added: Int64, deleted: Int64, fileHash: String) throws {
            try run(handle, """
            INSERT INTO usage_edit_entries
            (source,tool_use_id,model,project,timestamp_ms,lines_added,lines_deleted,source_file_hash,created_at_ms)
            VALUES ('\(source)','\(toolUseID)','\(model)','\(project)',\(ts),\(added),\(deleted),'\(fileHash)',1);
            """, "insert usage_edit_entries \(toolUseID)/\(fileHash)")
        }
        // 登记一个 owned 文件（scan_status 决定 active/missing）。
        func insertFile(_ handle: OpaquePointer?, fileID: String, source: String = "codex", status: String) throws {
            try run(handle, """
            INSERT INTO usage_files
            (file_id,source,path_hash,read_offset,file_size,mtime_ms,parser_version,scan_status,updated_at_ms)
            VALUES ('\(fileID)','\(source)','\(fileID)',1,1,1,\(UsageJSONLParser.parserVersion),'\(status)',1);
            """, "insert usage_files \(fileID)")
        }
        func outputTotal(_ ledger: UsageLedgerStore, hostname: String) throws -> Int64 {
            try ledger.buckets(hostname: hostname).reduce(0) { $0 + $1.counts.output }
        }

        // 1) legacy 空归属 + owned 副本：同 (source,event_id) 只算 owned，一次。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path) // 建 v8 schema
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertFile(handle, fileID: "fileA", status: "complete")
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "fileA")  // ownedActive
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "")        // legacy 副本
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            _ = try ledger.finalizeDerived(hostname: "h")
            let outputSum = try outputTotal(ledger, hostname: "h"); try require(outputSum == 100,
                        "owned copy must supersede legacy empty-attribution duplicate (count once)")
        }

        // 2) 删除/mark missing active 后历史仍保留：owned 变 ownedHistory，仍算一次，不因 missing 丢历史。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertFile(handle, fileID: "fileA", status: "complete")
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "fileA")
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "")
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.markFilesMissing(fileIDs: ["fileA"]) // active -> missing
            _ = try ledger.finalizeDerived(hostname: "h")
            let outputSum = try outputTotal(ledger, hostname: "h"); try require(outputSum == 100,
                        "ownedHistory (missing file) still supersedes legacy and is retained once")
        }

        // 3) ownedActive > ownedHistory：active 副本存在时忽略 missing 文件的旧副本（取 active 计数）。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertFile(handle, fileID: "active", status: "complete")
            try insertFile(handle, fileID: "gone", status: "missing")
            // overwrite 计数一致，避免误触发 fail-closed（此处只验优先级取胜）。
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "active")
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "gone")
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "")
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            _ = try ledger.finalizeDerived(hostname: "h")
            let outputSum = try outputTotal(ledger, hostname: "h"); try require(outputSum == 100,
                        "ownedActive supersedes ownedHistory and legacy for the same logical id")
        }

        // 4) 无任何 owned 时才保留 legacy。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertEvent(handle, eventID: "e1", output: 42, fileHash: "")
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            _ = try ledger.finalizeDerived(hostname: "h")
            let outputSum = try outputTotal(ledger, hostname: "h"); try require(outputSum == 42,
                        "legacy row must be retained when no owned row exists")
        }

        // 5) session：legacy 空归属 + owned 副本只算 owned；mark missing 后历史仍保留一条。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertFile(handle, fileID: "fileA", status: "complete")
            // 同 session 两条活动事件（一个 user、一个 assistant），各有 owned+legacy 副本。
            try insertSessionEvent(handle, eventID: "u1", role: "user", ts: 0, fileHash: "fileA")
            try insertSessionEvent(handle, eventID: "u1", role: "user", ts: 0, fileHash: "")
            try insertSessionEvent(handle, eventID: "a1", role: "assistant", ts: 60000, fileHash: "fileA")
            try insertSessionEvent(handle, eventID: "a1", role: "assistant", ts: 60000, fileHash: "")
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            _ = try ledger.finalizeDerived(hostname: "h")
            let sessions = try ledger.sessions(hostname: "h")
            try require(sessions.count == 1 && sessions[0].messageCount == 2,
                        "session events must dedup owned over legacy (2 unique events, not 4)")
            try ledger.markFilesMissing(fileIDs: ["fileA"])
            _ = try ledger.finalizeDerived(hostname: "h")
            let afterMissing = try ledger.sessions(hostname: "h")
            try require(afterMissing.count == 1 && afterMissing[0].messageCount == 2,
                        "session history retained after file marked missing")
        }

        // 6) edit：legacy 空归属 + owned 副本只算 owned；mark missing 后历史仍保留一次。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertFile(handle, fileID: "fileA", status: "complete")
            try run(handle, "INSERT INTO usage_edit_metric_sources(source,created_at_ms) VALUES('codex',1);", "mark edit metric source")
            try insertEvent(handle, eventID: "e1", output: 1, fileHash: "fileA")
            try insertEdit(handle, toolUseID: "t1", added: 10, deleted: 2, fileHash: "fileA")
            try insertEdit(handle, toolUseID: "t1", added: 10, deleted: 2, fileHash: "")
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            _ = try ledger.finalizeDerived(hostname: "h")
            func editTotals(_ l: UsageLedgerStore) throws -> (Int64, Int64) {
                try l.buckets(hostname: "h").reduce((0, 0)) { ($0.0 + $1.linesAdded, $0.1 + $1.linesDeleted) }
            }
            let (added1, deleted1) = try editTotals(ledger)
            try require(added1 == 10 && deleted1 == 2,
                        "edit entries must dedup owned over legacy (count lines once)")
            try ledger.markFilesMissing(fileIDs: ["fileA"])
            _ = try ledger.finalizeDerived(hostname: "h")
            let (added2, deleted2) = try editTotals(ledger)
            try require(added2 == 10 && deleted2 == 2,
                        "edit history retained after file marked missing")
        }

        // 7) overwrite 同 tier 计数冲突 fail-closed：两个 active 文件对同一 event 观测到不同计数。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            _ = try UsageLedgerStore(path: db.path)
            let handle = try open(db.path); defer { sqlite3_close(handle) }
            try insertFile(handle, fileID: "fileA", status: "complete")
            try insertFile(handle, fileID: "fileB", status: "complete")
            try insertEvent(handle, eventID: "e1", output: 100, fileHash: "fileA")
            try insertEvent(handle, eventID: "e1", output: 250, fileHash: "fileB")
            sqlite3_close(handle)
            let ledger = try UsageLedgerStore(path: db.path)
            let result = try ledger.finalizeDerived(hostname: "h")
            try require(!result.reportingEligible && !result.blockedReasons.isEmpty,
                        "conflicting overwrite counts across same-tier files must fail-closed")
            // 确定性不制造混合事件：保留稳定排序首行计数（source_file_hash 'fileA' < 'fileB'）。
            let outputSum = try outputTotal(ledger, hostname: "h"); try require(outputSum == 100,
                        "conflicting overwrite must keep deterministic first row, never a blended count")
        }
    }


    private static func verifyV2ParserRebuildSafety() throws {
        // 跟随解析器当前版本，并断言上一版本会触发重建，覆盖 parserVersion 提升。
        let currentVersion = UsageJSONLParser.parserVersion
        let previousVersion = currentVersion - 1
        try require(currentVersion >= 3, "parser version must be bumped for subagent + reasoning-split parity")
        func checkpoint(version: Int, fileID: String = "file") -> UsageFileCheckpoint {
            UsageFileCheckpoint(
                fileID: fileID, source: "codex", pathHash: fileID,
                offset: 1, size: 1, modifiedAt: Date(), parserVersion: version, status: "complete"
            )
        }

        func event(
            id: String = "event",
            project: String = "project",
            timestamp: Date = Date(timeIntervalSince1970: 1_700_000_000)
        ) -> UsageEvent {
            UsageEvent(
                id: id, source: "codex", model: "model", project: project,
                timestamp: timestamp, counts: UsageTokenCounts(output: 10),
                sessionHash: "session", sourceFileHash: "file"
            )
        }

        // 空库不误触发；旧 checkpoint 必须触发。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            let emptyRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: currentVersion)
            try require(!emptyRequiresRebuild, "empty usage ledger must not require parser rebuild")
            try ledger.record(events: [event()], checkpoint: checkpoint(version: currentVersion), hostname: "h")
            let currentParserRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: currentVersion)
            try require(!currentParserRequiresRebuild, "healthy current parser ledger must not require rebuild")
            try ledger.record(events: [event()], checkpoint: checkpoint(version: previousVersion), hostname: "h")
            let oldParserRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: currentVersion)
            try require(oldParserRequiresRebuild, "older parser checkpoint (v\(previousVersion)) must require rebuild under v\(currentVersion)")
        }

        // 有历史数据却没有 checkpoint，无法证明 parser 版本，必须 fail-safe rebuild。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            var ledger: UsageLedgerStore? = try UsageLedgerStore(path: db.path)
            try ledger!.record(events: [event()], checkpoint: checkpoint(version: currentVersion), hostname: "h")
            ledger = nil

            var handle: OpaquePointer?
            try require(sqlite3_open(db.path, &handle) == SQLITE_OK, "open checkpoint-less history db")
            defer { sqlite3_close(handle) }
            try require(sqlite3_exec(handle, "DELETE FROM usage_files;", nil, nil, nil) == SQLITE_OK, "remove checkpoints for rebuild verification")

            let reopened = try UsageLedgerStore(path: db.path)
            let historyRequiresRebuild = try reopened.requiresParserRebuild(currentParserVersion: currentVersion)
            try require(historyRequiresRebuild, "history without checkpoints must require rebuild")
        }

        // 活跃文件的当前 checkpoint 携带 epoch 前错误时间戳仍需 rebuild；
        // 但 begin+完成目标版本且该 checkpoint 标 missing 后，历史坏时间不再无限触发。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            let invalid = event(timestamp: Date(timeIntervalSince1970: -62_135_769_600))
            let invalidCheckpoint = checkpoint(version: currentVersion)
            try ledger.record(events: [invalid], checkpoint: invalidCheckpoint, hostname: "h")
            let timestampRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: currentVersion)
            try require(timestampRequiresRebuild, "active checkpoint with pre-epoch timestamp must require rebuild")

            // 完成目标版本 rebuild 并把该文件标 missing：历史坏时间不再触发。
            try ledger.beginParserRebuild(targetParserVersion: currentVersion)
            try ledger.markFilesMissing(fileIDs: [invalidCheckpoint.fileID])
            try ledger.markRebuildCompleted()
            let missingRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: currentVersion)
            try require(!missingRequiresRebuild, "missing file's historical bad timestamp must not require rebuild after completed rebuild")
        }

        // reset 后 revision 不复用；reset 前的旧 batch 不能 ack 新生成的同自然键行。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event()], checkpoint: checkpoint(version: previousVersion), hostname: "h")
            try ledger.finalizeDerived(hostname: "h")
            let staleBatch = try ledger.pendingBatch(hostname: "h")
            try require(staleBatch.buckets.first?.revision == 1, "initial rebuild verification revision")

			try ledger.resetForRebuild()
			try ledger.record(events: [event()], checkpoint: checkpoint(version: currentVersion), hostname: "h")
			try ledger.finalizeDerived(hostname: "h")
			// v8 rebuild 状态机：reset 置 rebuild_pending，成功重扫+finalize 后须显式完成才能解除上报门。
			try ledger.markRebuildCompleted()
			let rebuiltBatch = try ledger.pendingBatch(hostname: "h")
            try require(rebuiltBatch.buckets.first?.revision == 2, "reset must preserve monotonic revision high watermark")

            try ledger.acknowledge(staleBatch)
            let afterStaleAck = try ledger.pendingBatch(hostname: "h")
            try require(afterStaleAck.buckets.count == 1, "stale pre-reset batch must not ack rebuilt row")
        }

        // parser 修正导致未同步自然键被删除时，无远端残留，不应误 block。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event(project: "old")], checkpoint: checkpoint(version: 2), hostname: "h")
            try ledger.finalizeDerived(hostname: "h")
            try ledger.record(events: [event(project: "new")], checkpoint: checkpoint(version: 2), hostname: "h")
            let result = try ledger.finalizeDerived(hostname: "h")
            try require(result.reportingEligible, "deleting an unsynced derived key must remain reporting eligible")
            let remainsEligible = try ledger.reportingEligible(hostname: "h")
            let correctedBuckets = try ledger.buckets(hostname: "h")
            try require(remainsEligible, "删除派生行不阻断上报：未同步自然键被删仍可上报")
            try require(correctedBuckets.count == 1 && correctedBuckets[0].project == "new", "unsynced metadata correction must replace the old derived key")
        }

        // 对账门禁已移除：finalize 删除已同步自然键不再阻断上报。
        // 服务端以幂等累计 upsert 修复漏报/乱序，无 tombstone 协议，客户端不再置全局 fail-closed。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event(project: "old")], checkpoint: checkpoint(version: 2), hostname: "old-host")
            try ledger.finalizeDerived(hostname: "old-host")
            try ledger.acknowledge(ledger.pendingBatch(hostname: "old-host"))
            try ledger.record(events: [event(project: "new")], checkpoint: checkpoint(version: 2), hostname: "old-host")
            let result = try ledger.finalizeDerived(hostname: "old-host")
            try require(result.reportingEligible && result.blockedReasons.isEmpty, "对账门禁已移除：finalize 删除已同步派生行不再阻断上报")
            let oldHostEligible = try ledger.reportingEligible(hostname: "old-host")
            let otherHostEligible = try ledger.reportingEligible(hostname: "other-host")
            let laterFinalize = try ledger.finalizeDerived(hostname: "old-host")
            try require(oldHostEligible, "finalize 删除已同步行后原 hostname 仍可上报")
            try require(otherHostEligible, "对账门禁已移除：其他 hostname 不受影响")
            try require(laterFinalize.reportingEligible, "后续 finalize 保持可上报")
        }

        // 对账门禁已移除：reset 删除已同步派生行不再置位对账门禁。reset 期间的不可上报只来自
        // rebuild pending（raw 派生未完成），完成重扫 + finalize + markRebuildCompleted 后即恢复可上报。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 1), hostname: "reset-host")
            try ledger.finalizeDerived(hostname: "reset-host")
            try ledger.acknowledge(ledger.pendingBatch(hostname: "reset-host"))
            try ledger.resetForRebuild()
            // reset 后为 rebuild pending（并非对账门禁），故暂不可上报。
            let resetPendingEligible = try ledger.reportingEligible(hostname: "reset-host")
            try require(!resetPendingEligible, "reset 后处于 rebuild pending，暂不可上报")
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "reset-host")
            let postResetFinalize = try ledger.finalizeDerived(hostname: "reset-host")
            try ledger.markRebuildCompleted()
            // 完成重扫后：无对账门禁重新置位，恢复可上报。
            let resetHostEligible = try ledger.reportingEligible(hostname: "reset-host")
            let otherHostEligible = try ledger.reportingEligible(hostname: "other-host")
            try require(postResetFinalize.reportingEligible, "reset 后 finalize 无对账门禁阻断")
            try require(resetHostEligible, "对账门禁已移除：完成重扫后恢复可上报")
            try require(otherHostEligible, "对账门禁已移除：不影响其他 hostname")
        }

        // hostname 确认改名：原地把历史改到 new-host，old-host 无派生行；改名后行重新 dirty。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "old-host")
            try ledger.finalizeDerived(hostname: "old-host")
            try ledger.acknowledge(ledger.pendingBatch(hostname: "old-host"))
            try ledger.rebuildForHostname("new-host")
            let oldHostEligible = try ledger.reportingEligible(hostname: "old-host")
            let newHostEligible = try ledger.reportingEligible(hostname: "new-host")
            let postRebuildFinalize = try ledger.finalizeDerived(hostname: "new-host")
            try require(oldHostEligible, "改名后旧 host 无待同步行，仍可上报（不被对账门禁阻断）")
            try require(newHostEligible, "hostname 改名后新 host 可上报")
            try require(postRebuildFinalize.reportingEligible && postRebuildFinalize.blockedReasons.isEmpty, "对账门禁已移除：hostname 改名后 finalize 不再阻断")
            let renamedOldEmpty = try ledger.buckets(hostname: "old-host").isEmpty
            let renamedNewEmpty = try ledger.buckets(hostname: "new-host").isEmpty
            let renamedNewPending = try ledger.pendingBatch(hostname: "new-host").isEmpty
            try require(renamedOldEmpty, "原地改名：旧 host 派生行已移出")
            try require(!renamedNewEmpty, "原地改名：新 host 承接派生行")
            // 改名把已 ack 的行移到新自然键，重新 dirty，须重新上报。
            try require(!renamedNewPending, "改名后 new-host 行重新 dirty")
        }
    }

    // reset 后的 rebuild completion 是独立、持久的状态机：只有协调层显式确认所有来源成功后才能清除。
    private static func verifyV2RebuildCompletionPersistence() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        var ledger: UsageLedgerStore? = try UsageLedgerStore(path: db.path)
        let freshRequiresCompletion = try ledger!.requiresRebuildCompletion()
        try require(!freshRequiresCompletion, "fresh ledger must not require rebuild completion")

        try ledger!.resetForRebuild()
        let resetRequiresCompletion = try ledger!.requiresRebuildCompletion()
        try require(resetRequiresCompletion, "reset must atomically persist rebuild pending")

        ledger = nil
        var reopened: UsageLedgerStore? = try UsageLedgerStore(path: db.path)
        let reopenedRequiresCompletion = try reopened!.requiresRebuildCompletion()
        try require(reopenedRequiresCompletion, "rebuild pending must survive process restart")

        let emptyCheckpoint = UsageFileCheckpoint(
            fileID: "empty-file", source: "codex", pathHash: "empty-path",
            offset: 0, size: 0, modifiedAt: Date(),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try reopened!.record(events: [], checkpoint: emptyCheckpoint, hostname: "host")
        try reopened!.finalizeDerived(hostname: "host")
        let emptyScanRequiresCompletion = try reopened!.requiresRebuildCompletion()
        try require(emptyScanRequiresCompletion, "empty scan and finalize must not complete rebuild")

        let invalidCheckpoint = UsageFileCheckpoint(
            fileID: "invalid-file", source: "claude-code", pathHash: "invalid-path",
            offset: 2, size: 1, modifiedAt: Date(),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        do {
            try reopened!.record(events: [], checkpoint: invalidCheckpoint, hostname: "host")
            try require(false, "invalid checkpoint must fail")
        } catch UsageLedgerError.invalidCheckpoint {
            // Expected: a failed source scan cannot reach explicit rebuild completion.
        }
        let failedScanRequiresCompletion = try reopened!.requiresRebuildCompletion()
        try require(failedScanRequiresCompletion, "failed scan must leave rebuild pending")

        let event = UsageEvent(
            id: "rebuilt-event", source: "codex", model: "model", project: "project",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            counts: UsageTokenCounts(output: 10),
            sessionHash: "session", sourceFileHash: "rebuilt-file"
        )
        let completeCheckpoint = UsageFileCheckpoint(
            fileID: "rebuilt-file", source: "codex", pathHash: "rebuilt-path",
            offset: 1, size: 1, modifiedAt: Date(),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try reopened!.record(events: [event], checkpoint: completeCheckpoint, hostname: "host")
        try reopened!.finalizeDerived(hostname: "host")
        let finalizedRequiresCompletion = try reopened!.requiresRebuildCompletion()
        try require(finalizedRequiresCompletion, "record and finalize must not implicitly complete rebuild")

        try reopened!.markRebuildCompleted()
        let markedRequiresCompletion = try reopened!.requiresRebuildCompletion()
        try require(!markedRequiresCompletion, "explicit completion must clear rebuild pending")

        reopened = nil
        let completed = try UsageLedgerStore(path: db.path)
        let completedRequiresCompletion = try completed.requiresRebuildCompletion()
        try require(!completedRequiresCompletion, "explicit rebuild completion must persist across restart")
    }



    private static func verifyLegacyRuntimeSnapshotIgnored() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-v1-cache-verification-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let claudeSessions = root.appendingPathComponent("claude-sessions", isDirectory: true)
        let database = root.appendingPathComponent("agent-pulse.sqlite")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("v1 cache verification cleanup failed: \(error)\n", stderr) }
        }
        let store = try SQLiteSnapshotStore(path: database.path)
        try store.upsert(LegacyRuntimeSnapshotFixture(
            timestamp: Date(),
            desktopActive: 99,
            terminalActive: 99
        ))
        let collector = try CodexRuntimeMetricsCollector(
            configuration: .init(
                sessionsDirectories: [sessions],
                automationRoots: [],
                databaseURL: database,
                claudeSessionsDirectory: claudeSessions,
                claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
            ),
            processScanner: FakeScanner()
        )
        let restored = await collector.restoredDisplayState()
        try require(restored.snapshot == nil, "legacy runtime-display-v1 cache flashed under v2 task semantics")
    }

    private static func reconcileFrozenSnapshotIfConfigured() async throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let snapshotRoot = environment["AGENT_PULSE_RECONCILE_SNAPSHOT"],
              let nowValue = environment["AGENT_PULSE_RECONCILE_NOW"],
              let now = ISO8601DateFormatter().date(from: nowValue) else {
            return false
        }
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-pulse-reconcile-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: database.path + suffix)
                do {
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                } catch {
                    fputs("reconcile_cleanup_failed=1\n", stderr)
                }
            }
        }
        let root = URL(fileURLWithPath: snapshotRoot, isDirectory: true)
        var incrementURL: URL?
        if environment["AGENT_PULSE_RECONCILE_INCREMENT"] == "1" {
            let url = root
                .appendingPathComponent("root-0", isDirectory: true)
                .appendingPathComponent("rollout-reconcile-increment.jsonl")
            try writeRollout(
                to: url,
                cwd: "/tmp/project",
                events: [tokenEvent(at: now, totalOutput: 100)],
                sessionID: "reconcile-increment"
            )
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
            incrementURL = url
        }
        let collector = try CodexRuntimeMetricsCollector(configuration: .init(
            sessionsDirectories: [
                root.appendingPathComponent("root-0", isDirectory: true),
                root.appendingPathComponent("root-1", isDirectory: true),
            ],
            automationRoots: [],
            databaseURL: database,
            claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
        ))
        let metrics = try await collector.scan(at: now)
        let diagnostics = metrics.diagnostics
        print("swift_roots_input=\(diagnostics.configuredRoots)")
        print("swift_roots_canonical=\(diagnostics.canonicalRoots)")
        print("swift_jsonl_files=\(diagnostics.discoveredJSONLFiles)")
        print("swift_excluded_aggregate=\(diagnostics.excludedAggregateFiles)")
        print("swift_empty_files=\(diagnostics.excludedEmptyFiles)")
        print("swift_old_files=\(diagnostics.excludedStaleFiles)")
        print("swift_duplicate_files=\(diagnostics.duplicateFiles)")
        print("swift_selected_files=\(diagnostics.trackedLiveFiles)")
        print("swift_provider_cli_files=\(diagnostics.cliFiles)")
        print("swift_provider_desktop_files=\(diagnostics.desktopFiles)")
        print("swift_provider_subagent_files=\(diagnostics.subagentFiles)")
        print("swift_provider_unknown_files=\(diagnostics.unknownProviderFiles)")
        print("swift_output_observations=\(diagnostics.parsedOutputObservations)")
        print("swift_cumulative_observations=\(diagnostics.cumulativeObservations)")
        print("swift_incremental_observations=\(diagnostics.incrementalObservations)")
        print("swift_baseline_observations=\(diagnostics.baselineObservations)")
        print("swift_counter_resets=\(diagnostics.counterResetObservations)")
        print("swift_duplicate_messages=\(diagnostics.duplicateMessageObservations)")
        print("swift_emitted_events=\(diagnostics.emittedTokenEvents)")
        print("swift_tokens_before_dedup=\(diagnostics.tokensBeforeDeduplication)")
        print("swift_tokens_after_dedup=\(diagnostics.tokensAfterDeduplication)")
        print("swift_cold_files=\(metrics.filesScanned)")
        print("swift_cold_unreadable_files=\(metrics.unreadableFiles)")
        print("swift_cold_desktop_active=\(metrics.desktopActive ?? 0)")
        print("swift_cold_terminal_active=\(metrics.terminalActive ?? 0)")
        print("swift_cold_overlap_tokens_180s=\(metrics.liveRate.tokensInWindow ?? 0)")
        print("swift_cold_active_sessions=\(diagnostics.activeSessions)")
        print("swift_cold_tps=\(metrics.liveRate.tps ?? 0)")
        if let incrementURL {
            try appendLine(tokenEvent(at: now.addingTimeInterval(1), totalOutput: 280), to: incrementURL)
            let increment = try await collector.scan(at: now.addingTimeInterval(1))
            print("swift_increment_tokens_180s=\(Int(increment.liveRate.tokensInWindow ?? 0))")
            print("swift_increment_active_sessions=\(increment.diagnostics.activeSessions)")
            print("swift_increment_tps=\(String(format: "%.6f", increment.liveRate.tps ?? 0))")
        }
        return true
    }

    private static func verifyTPSBoundaries() throws {
        let base = Date(timeIntervalSince1970: 10_000)
        let window = TPSWindow(now: { base })

        try require(window.currentTPS() == nil, "empty TPS window must be unavailable")
        try require(window.record(tokenCount: 180, durationSeconds: 0, source: .cli, timestamp: base), "valid sample rejected")
        try requireApproximatelyEqual(window.currentTPS(referenceDate: base), 1, "fixed 180-second denominator")
        try requireApproximatelyEqual(
            window.currentTPS(referenceDate: base.addingTimeInterval(180)),
            1,
            "exact 180-second boundary"
        )
        try require(
            window.currentTPS(referenceDate: base.addingTimeInterval(180.001)) == nil,
            "event beyond 180 seconds remained in the window"
        )

        let interval = TPSWindow(now: { base })
        try require(
            interval.record(tokenCount: 6_000, durationSeconds: 600, source: .cli, timestamp: base),
            "interval sample rejected"
        )
        try requireApproximatelyEqual(interval.currentTPS(referenceDate: base), 10, "linear overlap allocation")
        try requireApproximatelyEqual(interval.tokensInWindow(referenceDate: base), 1_800, "overlap token count")

        let futureBoundary = TPSWindow(now: { base })
        try require(
            futureBoundary.record(tokenCount: 180, durationSeconds: 0, source: .cli, timestamp: base.addingTimeInterval(5)),
            "future-boundary sample rejected"
        )
        try requireApproximatelyEqual(
            futureBoundary.currentTPS(referenceDate: base),
            1,
            "five-second oracle future tolerance"
        )
        let beyondFutureBoundary = TPSWindow(now: { base })
        try require(
            beyondFutureBoundary.record(
                tokenCount: 180,
                durationSeconds: 0,
                source: .cli,
                timestamp: base.addingTimeInterval(5.001)
            ),
            "future sample was rejected before window filtering"
        )
        try require(
            beyondFutureBoundary.currentTPS(referenceDate: base) == nil,
            "event beyond oracle future tolerance entered the window"
        )

        try require(!window.record(tokenCount: -1, durationSeconds: 1, source: .cli, timestamp: base), "negative token sample accepted")
        try require(!window.record(tokenCount: 1, durationSeconds: .nan, source: .cli, timestamp: base), "NaN duration sample accepted")

        let concurrent = TPSWindow(now: { base })
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "agentpulse.verification.concurrent", attributes: .concurrent)
        for offset in 0..<100 {
            group.enter()
            queue.async {
                _ = concurrent.record(tokenCount: 1, durationSeconds: 1, source: .desktop, timestamp: base.addingTimeInterval(Double(offset) / 100))
                group.leave()
            }
        }
        group.wait()
        try require(concurrent.sampleCount(referenceDate: base.addingTimeInterval(1)) == 100, "concurrent TPS writes lost samples")
        try requireApproximatelyEqual(
            concurrent.currentTPS(referenceDate: base.addingTimeInterval(1)),
            100.0 / 180.0,
            "concurrent TPS fixed-window aggregate"
        )

        let live = LiveRateSample(timestamp: base, state: .live, tokensInWindow: 360, latestSignalAt: base)
        try requireApproximatelyEqual(live.tps, 2, "live sample must derive TPS from fixed denominator")
        let byModel = TPSWindow(now: { base })
        _ = byModel.record(TPSSample(timestamp: base, tokenCount: 180, durationSeconds: 0, source: .cli, model: "codex-test-model"))
        _ = byModel.record(TPSSample(timestamp: base, tokenCount: 90, durationSeconds: 0, source: .cli, model: "claude-opus"))
        _ = byModel.record(TPSSample(timestamp: base, tokenCount: 45, durationSeconds: 0, source: .cli, model: nil))
        let modelTokens = byModel.tokensInWindowByModel(referenceDate: base)
        try requireApproximatelyEqual(modelTokens["codex-test-model"], 180, "model TPS grouping lost Codex tokens")
        try requireApproximatelyEqual(modelTokens["claude-opus"], 90, "model TPS grouping lost Claude tokens")
        try requireApproximatelyEqual(modelTokens["unknown"], 45, "unattributed TPS must remain visible")
        try requireApproximatelyEqual(
            modelTokens.values.reduce(0, +),
            byModel.tokensInWindow(referenceDate: base),
            "model TPS sum must equal total TPS"
        )
        let persistedModels = LiveRateSample(
            timestamp: base,
            state: .live,
            tokensInWindow: 315,
            latestSignalAt: base,
            modelTokensInWindow: modelTokens
        )
        let roundTripModels = try JSONDecoder().decode(
            LiveRateSample.self,
            from: JSONEncoder().encode(persistedModels)
        )
        try require(roundTripModels.modelTokensInWindow == modelTokens, "model TPS payload did not round-trip")
        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": persistedModels.id.uuidString,
            "timestamp": persistedModels.timestamp.timeIntervalSinceReferenceDate,
            "state": "live",
            "tps": 1.5,
            "tokensInWindow": 270.0,
            "latestSignalAt": persistedModels.latestSignalAt!.timeIntervalSinceReferenceDate,
        ])
        let legacySample = try JSONDecoder().decode(LiveRateSample.self, from: legacyJSON)
        try require(legacySample.modelTokensInWindow.isEmpty, "legacy live-rate payload must decode without model data")
        try require(LiveRateSample(timestamp: base, state: .zero, tokensInWindow: nil, latestSignalAt: base).tps == 0, "zero state must persist numeric zero")
        for state in [LiveRateState.noData, .stale, .unavailable] {
            let sample = LiveRateSample(timestamp: base, state: state, tokensInWindow: 42, latestSignalAt: nil)
            try require(sample.tps == nil && sample.tokensInWindow == nil, "missing TPS state stored a numeric value")
        }
    }

    private static func verifySparklineAnalysis() throws {
        let base = Date(timeIntervalSince1970: 50_000)
        let end = base.addingTimeInterval(SparklineAnalysis.defaultWindowSeconds)

        func liveSample(minute: Int, tps: Double) -> LiveRateSample {
            let timestamp = base.addingTimeInterval(Double(minute * 60))
            return LiveRateSample(
                timestamp: timestamp,
                state: tps == 0 ? .zero : .live,
                tokensInWindow: tps * Double(LiveRateSample.windowSeconds),
                latestSignalAt: timestamp
            )
        }

        func series(_ values: [Double]) -> (points: [SparklinePoint], regression: SparklineRegression) {
            SparklineAnalysis.makeSparkline(
                from: values.enumerated().map { liveSample(minute: $0.offset, tps: $0.element) },
                end: end,
                stepSeconds: 60,
                kernel: .gaussian(radius: 2)
            )
        }

        try require(SparklineAnalysis.defaultWindowSeconds == 15 * 60, "sparkline window must be fifteen minutes")

        let rising = series((1...16).map(Double.init))
        try require(rising.points.count == 16, "fifteen-minute minute-step resampling count mismatch")
        try require(rising.regression.trend == .rising, "rising series was not classified as rising")
        try require((rising.regression.slopePerSecond ?? 0) > 0, "rising regression slope was not positive")

        let falling = series((1...16).reversed().map(Double.init))
        try require(falling.regression.trend == .falling, "falling series was not classified as falling")
        try require((falling.regression.slopePerSecond ?? 0) < 0, "falling regression slope was not negative")

        let flat = series([10, 10.02, 9.99, 10.01, 10, 10.02, 10, 9.98, 10, 10.01, 10, 10, 9.99, 10.01, 10, 10])
        try require(flat.regression.trend == .flat, "dead-zone series was not classified as flat")

        let moderateDecline = series((0..<16).map { 10 - Double($0) * (2.0 / 15.0) })
        try require(
            moderateDecline.regression.trend == .flat,
            "decline within thirty percent must remain flat"
        )
        try require(
            (moderateDecline.regression.normalizedSlope ?? -1) >= SparklineAnalysis.significantDeclineThreshold,
            "moderate decline fixture did not exercise the thirty-percent threshold"
        )

        var gapSamples = [
            liveSample(minute: 0, tps: 0),
            liveSample(minute: 1, tps: 0),
            LiveRateSample(
                timestamp: base.addingTimeInterval(2 * 60),
                state: .stale,
                tokensInWindow: 1_800,
                latestSignalAt: base
            ),
            liveSample(minute: 3, tps: 10),
            liveSample(minute: 4, tps: 10),
        ]
        let gapEnd = base.addingTimeInterval(4 * 60)
        let gap = SparklineAnalysis.makeSparkline(
            from: gapSamples,
            end: gapEnd,
            windowSeconds: 4 * 60,
            stepSeconds: 60,
            kernel: .gaussian(radius: 2)
        )
        // 双通道语义：value 保留原始真实值（缺口 nil，看板如实绘制、断开不连线）；
        // normalized 经插值补缺 + 平滑 + 归一化（菜单栏小图/悬浮球连续看趋势）。
        try require(
            gap.points.allSatisfy { $0.normalized != nil },
            "display pipeline did not interpolate the smoothed (normalized) channel"
        )
        try require(
            gap.points[2].value == nil,
            "raw value channel must preserve the real gap for the dashboard (no cross-gap interpolation)"
        )
        try require(
            (gap.points[2].normalized ?? -1) >= 0 && (gap.points[2].normalized ?? 2) <= 1,
            "internal gap was not smoothly interpolated in the normalized channel"
        )

        let edgeGaps = SparklineAnalysis.interpolateGaps([
            SparklinePoint(time: base, value: nil, normalized: nil),
            SparklinePoint(time: base.addingTimeInterval(1), value: 4, normalized: nil),
            SparklinePoint(time: base.addingTimeInterval(2), value: nil, normalized: nil),
        ])
        try requireApproximatelyEqual(edgeGaps[0].value, 4, "leading gap was not extended from nearest value")
        try requireApproximatelyEqual(edgeGaps[2].value, 4, "trailing gap was not extended from nearest value")

        let single = SparklineAnalysis.makeSparkline(
            from: [liveSample(minute: 15, tps: 7)],
            end: end,
            windowSeconds: 60,
            stepSeconds: 60
        )
        try require(single.regression.trend == .insufficient, "single point must not invent a trend")
        try require(single.regression.sampleCount == 1, "single-point regression count mismatch")

        let invalid = LiveRateSample(
            timestamp: end,
            state: .live,
            tokensInWindow: .infinity,
            latestSignalAt: end
        )
        try require(SparklineAnalysis.numericSeries(from: [invalid]).first?.value == nil, "non-finite TPS was accepted")

        var outlierPoints = (1...20).map { value in
            SparklinePoint(time: base.addingTimeInterval(Double(value)), value: Double(value), normalized: nil)
        }
        outlierPoints.append(SparklinePoint(time: end, value: 1_000_000_000, normalized: nil))
        let normalizedOutliers = SparklineAnalysis.normalize(outlierPoints)
        try require(normalizedOutliers.allSatisfy { $0.normalized?.isFinite ?? true }, "outlier normalization produced a non-finite value")
        try require(normalizedOutliers[19].normalized == 1, "display normalization was not robust to a single outlier")

        // 看板 5s 滑窗曲线：有 short 值时取 tokensInShortWindow/5（而非 180s 口径）。
        let shortSample = LiveRateSample(
            timestamp: end,
            state: .live,
            tokensInWindow: 540,                 // 180s 口径 tps = 3
            latestSignalAt: end,
            modelTokensInWindow: ["m": 540],
            tokensInShortWindow: 50,             // 5s 口径 tps = 10
            modelTokensInShortWindow: ["m": 50]
        )
        let dash = SparklineAnalysis.makeDashboardSparkline(
            from: [shortSample], end: end, windowSeconds: 10, stepSeconds: 10
        )
        try requireApproximatelyEqual(dash.last?.value, 10, "dashboard curve must use 5s short-window rate (short/5), not 180s")
        let dashModel = SparklineAnalysis.makeDashboardModelSparkline(
            from: [shortSample], model: "m", end: end, windowSeconds: 10, stepSeconds: 10
        )
        try requireApproximatelyEqual(dashModel.last?.value, 10, "dashboard per-model curve must use 5s short-window rate")
        // Codable 往返保留 short 字段。
        let roundTrip = try JSONDecoder().decode(
            LiveRateSample.self, from: JSONEncoder().encode(shortSample)
        )
        try requireApproximatelyEqual(roundTrip.tokensInShortWindow, 50, "tokensInShortWindow must survive JSON round-trip")
        // 旧库无 short 字段：回退 180s 口径，历史点仍有值。
        let legacySample = liveSample(minute: 0, tps: 4)   // tokensInShortWindow == nil
        try require(legacySample.tokensInShortWindow == nil, "legacy sample must have no short window value")
        let legacySeries = SparklineAnalysis.shortWindowSeries(from: [legacySample])
        try requireApproximatelyEqual(legacySeries.first?.value ?? nil, 4, "legacy sample must fall back to 180s rate in dashboard series")
        gapSamples.removeAll()
    }

    private static func verifySQLiteRoundTripAndRetention() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-core-verification-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { fputs("cleanup failed: \(error)\n", stderr) }
                }
            }
        }

        let store = try SQLiteSnapshotStore(path: databaseURL.path)
        let base = Date(timeIntervalSince1970: 20_000)
        let first = PulseSnapshot(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            timestamp: base,
            source: .cli,
            status: .idle,
            tps: 4.5,
            tokenCount: 90,
            completedTaskCount: 7,
            completedCountQuality: .partial,
            completedScope: .allLocal
        )
        let second = PulseSnapshot(
            id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            timestamp: base.addingTimeInterval(10),
            source: .desktop,
            status: .generating
        )
        try store.upsert(contentsOf: [first, second])

        let roundTrip = try store.query(PulseSnapshot.self, source: PulseSource.cli.rawValue)
        try require(roundTrip == [first], "SQLite PulseSnapshot roundtrip/source filter failed")
        let ranged = try store.query(
            PulseSnapshot.self,
            in: SnapshotTimeRange(start: base.addingTimeInterval(9), end: base.addingTimeInterval(11))
        )
        try require(ranged == [second], "SQLite time-range query failed")
        let deletedCount = try store.enforceRetention(maxCount: 1)
        try require(deletedCount == 1, "SQLite retention deletion count failed")
        let remainingCount = try store.count()
        try require(remainingCount == 1, "SQLite retention remaining count failed")
        let remaining = try store.query(PulseSnapshot.self)
        try require(remaining == [second], "SQLite retention kept the wrong row")
    }

    private static func verifyParserFixturesAndCollector() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        func fixture(_ name: String) throws -> String {
            try String(contentsOf: fixtures.appendingPathComponent(name), encoding: .utf8)
        }

        let distinct = CodexSessionParser.completedTasks(
            inSessionContents: try fixture("cli_user_two_complete.jsonl"),
            automationRoots: []
        )
        try require(distinct.identities.count == 2, "fixture distinct completed turns were not counted")
        let duplicate = CodexSessionParser.completedTasks(
            inSessionContents: try fixture("cli_user_duplicate_turn.jsonl"),
            automationRoots: []
        )
        try require(duplicate.identities.count == 1, "fixture duplicate turn was not deduplicated")
        let subagent = CodexSessionParser.completedTasks(
            inSessionContents: try fixture("subagent_excluded.jsonl"),
            automationRoots: []
        )
        try require(subagent.identities.isEmpty, "subagent completion was included")
        let automation = CodexSessionParser.completedTasks(
            inSessionContents: try fixture("automation_excluded.jsonl"),
            automationRoots: []
        )
        try require(automation.identities.isEmpty, "automation completion was included")
        try require(
            !CodexSessionParser.isUnderAutomation(cwd: "/tmp/my-automations-demo/project", automationRoots: []),
            "automation path matching was too broad"
        )
        let modernMeta = CodexSessionParser.parseSessionMeta(
            line: "{\"type\":\"session_meta\",\"payload\":{\"id\":\"modern-session\",\"thread_source\":\"user\"}}"
        )
        try require(modernMeta?.sessionID == "modern-session", "session_meta payload.id was not accepted")

        // 新版 session_meta 格式漂移：顶层判定不能只看 thread_source，需结合结构化 source 字段。
        func topLevel(_ json: String) throws -> Bool {
            guard let meta = CodexSessionParser.parseSessionMeta(
                line: "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"s\"\(json)}}"
            ) else { throw VerificationFailure.assertion("session_meta did not parse: \(json)") }
            return meta.isTopLevel
        }
        // 漂移的顶层会话：source 是标量入口字符串，即便 thread_source 被标为 subagent 也是顶层。
        let driftedTopLevel = try topLevel(",\"source\":\"vscode\",\"thread_source\":\"subagent\"")
        try require(driftedTopLevel, "drifted top-level (source=vscode, thread_source=subagent) must be top-level")
        // 真正的派生子 agent：source 是对象（含 subagent.thread_spawn），必须排除。
        let spawnedSubagent = try topLevel(",\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"p\",\"depth\":2}}},\"thread_source\":\"subagent\"")
        try require(!spawnedSubagent, "genuine spawned sub-agent (object source) must not be top-level")
        // 新版顶层 exec/user 入口。
        let execTopLevel = try topLevel(",\"source\":\"exec\",\"thread_source\":\"user\"")
        try require(execTopLevel, "exec top-level must be top-level")
        // 旧格式兼容：无 source 字段时仅靠 thread_source。
        let legacyUser = try topLevel(",\"thread_source\":\"user\"")
        try require(legacyUser, "legacy top-level (thread_source=user, no source) must remain top-level")
        let legacySubagent = try topLevel(",\"thread_source\":\"subagent\"")
        try require(!legacySubagent, "legacy sub-agent (thread_source=subagent, no source) must remain excluded")
        try require(
            CodexProcessClassifier.isIndependentCLI(executablePath: "/private/tmp/codex"),
            "standalone native codex executable was not classified as terminal"
        )
        try require(
            CodexProcessClassifier.isIndependentCLI(executablePath: "claude"),
            "standalone Claude CLI executable was not classified as terminal"
        )
        try require(
            !CodexProcessClassifier.isIndependentCLI(
                executablePath: "/Applications/Codex.app/Contents/Resources/codex"
            ),
            "Desktop app's native codex helper was classified as terminal"
        )
        try require(
            !CodexProcessClassifier.isIndependentCLI(executablePath: "/opt/homebrew/bin/node"),
            "CLI wrapper process was classified as a native codex task"
        )
        try require(
            !CodexProcessClassifier.isIndependentCLI(
                executablePath: "/Applications/Claude.app/Contents/MacOS/claude"
            ),
            "Claude Desktop executable was classified as a terminal task"
        )
        try require(
            CodexProcessClassifier.isClaudeDesktopApp(
                executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
            "Claude Desktop main process was not recognized"
        )
        try require(
            !CodexProcessClassifier.isClaudeDesktopApp(
                executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
            ),
            "Claude Desktop helper was mistaken for the main process"
        )

        let stagedSessions = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-session-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagedSessions, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: stagedSessions) }
            catch { fputs("fixture cleanup failed: \(error)\n", stderr) }
        }
        let fixtureNames = [
            "aborted_last.jsonl",
            "automation_excluded.jsonl",
            "cli_user_active.jsonl",
            "cli_user_duplicate_turn.jsonl",
            "cli_user_missing_turn.jsonl",
            "cli_user_two_complete.jsonl",
            "desktop_user_one_complete.jsonl",
            "subagent_excluded.jsonl",
        ]
        for (index, name) in fixtureNames.enumerated() {
            let contents = try fixture(name)
            let destination = stagedSessions.appendingPathComponent("rollout-\(index).jsonl")
            try contents.write(to: destination, atomically: true, encoding: .utf8)
        }

        let collector = CodexStatusCollector(
            processScanner: FakeScanner(processes: [
                RunningProcess(
                    pid: 42,
                    executablePath: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/bin/codex",
                    residentMemoryBytes: 2048,
                    cpuUsagePercent: 1.5
                )
            ]),
            sessionsDirectories: [stagedSessions],
            automationRoots: [],
            clock: FixedClock(date: Date(timeIntervalSince1970: 30_000))
        )
        let snapshot = collector.collect(source: .cli)
        try require(snapshot.status == .generating, "collector failed live+active lifecycle mapping")
        try require(snapshot.completedTaskCount == 4, "collector completed count used the wrong scope or deduplication")
        try require(snapshot.completedCountQuality == .partial, "local rollout count must be marked partial")
        try require(snapshot.completedScope == .allLocal, "local rollout count scope must be allLocal")
        try require(snapshot.completedIsLowerBound, "partial completed count must be marked lower bound")
    }

    private static func verifyToolMetricsAndEditLines() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
        func parse(_ name: String, source: String, isSubagent: Bool = false) throws -> ParsedUsageFile {
            let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
            return UsageJSONLParser.parse(data: data, source: source, fileIdentity: name, isSubagent: isSubagent)
        }

        // 解析器版本已提升到 6（稳定 count-only 身份、MCP output gate 与边界修复）。
        try require(UsageJSONLParser.parserVersion == 9, "parserVersion must advance to 9 for Claude message.id fold (upstream billing parity)")

        // 1) 技能计数：同名累加，键并入排序去重列表。
        let skill = try parse("claude_skill_tool_use.jsonl", source: "claude-code")
        try require(skill.events.count == 1, "skill fixture should yield one event")
        let skillEvent = skill.events[0]
        try require(skillEvent.skillCounts == ["frontend-design": 2, "brainstorming": 1], "skill counts mismatch: \(skillEvent.skillCounts)")
        try require(UsageToolMetrics.mergeSkillCountKeys(skills: [], counts: skillEvent.skillCounts) == ["brainstorming", "frontend-design"], "skill presence union/order mismatch")
        try require(skillEvent.mcpCounts.isEmpty, "skill fixture must not report mcp")

        // 2) MCP 计数：mcp__server__tool 取 server 累加；Bash 与不完整 mcp__ 名排除。
        let mcp = try parse("claude_mcp_tool_use.jsonl", source: "claude-code")
        try require(mcp.events.count == 1, "mcp fixture should yield one event")
        try require(mcp.events[0].mcpCounts == ["filesystem": 2, "github": 1], "mcp counts mismatch: \(mcp.events[0].mcpCounts)")
        try require(mcp.events[0].skillCounts.isEmpty, "mcp fixture must not report skills")
        try require(UsageToolMetrics.mcpServerFromToolUseName("mcp__bad") == nil, "incomplete mcp name must be rejected")
        try require(UsageToolMetrics.mcpServerFromToolUseName("Bash") == nil, "non-mcp name must be rejected")

        // 3) 编辑 applied gate + LCS 行差分：成功编辑计入，is_error 编辑排除。
        let edit = try parse("claude_edit_applied.jsonl", source: "claude-code")
        try require(edit.editEntries.count == 1, "only the applied edit should survive the result gate: \(edit.editEntries.count)")
        try require(edit.sessionEvents.allSatisfy { $0.sourceFileHash == edit.checkpoint.fileID }, "all parsed Claude session events must belong to their checkpoint file")
        try require(edit.editEntries.allSatisfy { $0.sourceFileHash == edit.checkpoint.fileID }, "all parsed Claude edit entries must belong to their checkpoint file")
        let okEntry = edit.editEntries[0]
        try require(okEntry.toolUseID == "tu-ok", "wrong edit survived gate: \(okEntry.toolUseID)")
        try require(okEntry.added == 2 && okEntry.deleted == 1, "LCS line diff mismatch: +\(okEntry.added)/-\(okEntry.deleted)")

        // 4) MultiEdit 求和 + 单笔 >2000 行整笔清零。
        let cap = try parse("claude_edit_multiedit_cap.jsonl", source: "claude-code")
        let capAgg = UsageEditLines.aggregate(cap.editEntries, bucketMilliseconds: UsageLedgerStore.bucketMilliseconds)
        try require(capAgg.count == 1, "capped edits should collapse to one bucket delta")
        try require(capAgg[0].added == 3 && capAgg[0].deleted == 1, "multiedit sum/cap mismatch: +\(capAgg[0].added)/-\(capAgg[0].deleted)")
        try require(capAgg[0].net == 2, "net mismatch: \(capAgg[0].net)")

        // 5) 生成 / 锁文件路径排除，仅业务文件计入。
        let gen = try parse("claude_edit_generated_path.jsonl", source: "claude-code")
        try require(gen.editEntries.count == 1, "generated/lock paths must be excluded: \(gen.editEntries.count)")
        try require(gen.editEntries[0].toolUseID == "tu-real" && gen.editEntries[0].added == 2, "only the business-file write should count")
        try require(UsageEditLines.isGeneratedEditPath("/x/node_modules/y.js"), "node_modules must be generated")
        try require(!UsageEditLines.isGeneratedEditPath("/x/vendorized/y.go"), "vendorized must not match vendor component")

        // 6) Codex apply_patch：+/- 计数、Move to 生成路径整段跳过、成功 gate、call_id 去重。
        let codex = try parse("codex_apply_patch.jsonl", source: "codex")
        try require(codex.editEntries.count == 1, "codex applied patch should yield one entry: \(codex.editEntries.count)")
        try require(codex.sessionEvents.allSatisfy { $0.sourceFileHash == codex.checkpoint.fileID }, "all parsed Codex session events must belong to their checkpoint file")
        try require(codex.editEntries.allSatisfy { $0.sourceFileHash == codex.checkpoint.fileID }, "all parsed Codex edit entries must belong to their checkpoint file")
        let cxEntry = codex.editEntries[0]
        try require(cxEntry.toolUseID == "cx-call-1", "codex dedup id mismatch: \(cxEntry.toolUseID)")
        try require(cxEntry.added == 2 && cxEntry.deleted == 1, "codex +/- count (post move-to skip) mismatch: +\(cxEntry.added)/-\(cxEntry.deleted)")
        try require(cxEntry.model == "codex-test-model", "codex edit should carry turn model")
        try require(codex.events.contains { $0.counts.total == 150 }, "codex token event should still parse alongside edits")
        try require(UsageEditLines.codexExecIsApplied("Script failed\nExit code: 0") == false, "programmatic wrapper failure must override quoted success marker")

        // 7) Claude usage-less（零 token）Skill/MCP turn 物化 count-only 事件；同一 turn 的
        //    fork 重刷按内容指纹去重折叠为一条；带 usage 的 turn 不受影响。
        let countOnly = try parse("claude_count_only.jsonl", source: "claude-code")
        let coEvents = countOnly.events.filter { !$0.skillCounts.isEmpty || !$0.mcpCounts.isEmpty }
        try require(coEvents.count == 1, "usage-less skill/mcp turn must yield exactly one deduped count-only event: \(coEvents.count)")
        let co = coEvents[0]
        try require(co.counts.total == 0 && co.counts.output == 0 && co.counts.input == 0, "count-only event must carry zero tokens: \(co.counts)")
        try require(co.skillCounts == ["distill": 1], "count-only skill counts mismatch: \(co.skillCounts)")
        try require(co.mcpCounts == ["github": 1], "count-only mcp counts mismatch: \(co.mcpCounts)")
        try require(co.mergeStrategy == .cumulativeMax, "count-only event must merge cumulativeMax")
        try require(co.model == "claude-sonnet", "count-only event must carry the record model")
        try require(!co.hasTotalSnapshot, "count-only event must not claim a total token snapshot")
        try require(countOnly.events.contains { $0.counts.total == 15 }, "usage-bearing turn must still emit its token event alongside count-only")
        // count-only 与真实 usage 事件 id 不相撞（不同 id 空间）。
        try require(Set(countOnly.events.map { $0.id }).count == countOnly.events.count, "count-only id must not collide with usage event ids")

        // 稳定 ID 必须绑定 source/session/message(turn)：跨 session 不碰撞；同 turn 内容/时间重写
        // 仍保持同一 id 并逐维取最大；若同 turn 后续出现 usage，则不再额外物化 count-only。
        let rewrittenA = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-08-11T00:00:00Z","type":"assistant","sessionId":"sess-stable","message":{"id":"msg-stable","model":"claude-sonnet","content":[{"type":"tool_use","name":"Skill","input":{"skill":"distill"}}]}}
            """.utf8), source: "claude-code", fileIdentity: "count-stable-a"
        )
        let rewrittenB = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-08-11T00:10:00Z","type":"assistant","sessionId":"sess-stable","message":{"id":"msg-stable","model":"claude-sonnet","content":[{"type":"tool_use","name":"Skill","input":{"skill":"distill"}},{"type":"tool_use","name":"mcp__github__one","input":{}},{"type":"tool_use","name":"mcp__github__two","input":{}}]}}
            """.utf8), source: "claude-code", fileIdentity: "count-stable-b"
        )
        try require(rewrittenA.events[0].id == rewrittenB.events[0].id, "same source/session/turn rewrite must preserve count-only id")
        try require(rewrittenB.events[0].mcpCounts == ["github": 2], "same turn rewrite must carry the rewritten maximum counts")

        let crossSession = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-08-11T00:00:00Z","type":"assistant","sessionId":"sess-a","message":{"id":"msg-shared","model":"claude-sonnet","content":[{"type":"tool_use","name":"Skill","input":{"skill":"distill"}}]}}
            {"timestamp":"2026-08-11T00:00:00Z","type":"assistant","sessionId":"sess-b","message":{"id":"msg-shared","model":"claude-sonnet","content":[{"type":"tool_use","name":"Skill","input":{"skill":"distill"}}]}}
            """.utf8), source: "claude-code", fileIdentity: "count-cross-session"
        )
        try require(crossSession.events.count == 2 && Set(crossSession.events.map(\.id)).count == 2, "equal turn ids in different sessions must not collide")

        let usageRewrite = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-08-11T00:00:00Z","type":"assistant","sessionId":"sess-usage","message":{"id":"msg-usage","model":"claude-sonnet","content":[{"type":"tool_use","name":"Skill","input":{"skill":"distill"}}]}}
            {"timestamp":"2026-08-11T00:00:01Z","type":"assistant","sessionId":"sess-usage","message":{"id":"msg-usage","model":"claude-sonnet","content":[{"type":"text","text":"done"}],"usage":{"output_tokens":5,"total_tokens":5}}}
            """.utf8), source: "claude-code", fileIdentity: "count-usage-rewrite"
        )
        try require(usageRewrite.events.count == 1 && usageRewrite.events[0].skillCounts == ["distill": 1], "usage rewrite must absorb tool counts without a duplicate count-only event")

        // 8) usage-less 且无 Skill/MCP：不产生任何事件（不虚构零 token 行）。
        let noTool = try parse("claude_usageless_no_tool.jsonl", source: "claude-code")
        try require(noTool.events.isEmpty, "usage-less record without skill/mcp must emit no event: \(noTool.events.count)")

        // 9) usage-less Skill turn 但缺 timestamp：跳过（无法归桶），不物化。
        let noTs = try parse("claude_count_only_no_ts.jsonl", source: "claude-code")
        try require(noTs.events.isEmpty, "usage-less skill turn without timestamp must be skipped: \(noTs.events.count)")

        // 10) Codex programmatic apply_patch（custom_tool_call name=exec，JS tools.apply_patch）：
        //     programmatic 成功 gate 仅认「Script completed」；failed/running 排除；token 事件仍解析。
        let prog = try parse("codex_apply_patch_programmatic.jsonl", source: "codex")
        try require(prog.editEntries.count == 1, "only the confirmed programmatic success should survive: \(prog.editEntries.map { $0.toolUseID })")
        let progEntry = prog.editEntries[0]
        try require(progEntry.toolUseID == "pg-ok", "wrong programmatic call survived gate: \(progEntry.toolUseID)")
        try require(progEntry.added == 2 && progEntry.deleted == 1, "programmatic +/- mismatch: +\(progEntry.added)/-\(progEntry.deleted)")
        try require(progEntry.model == "codex-test-model", "programmatic edit must carry turn model")
        try require(prog.events.contains { $0.counts.total == 150 }, "programmatic rollout token event must still parse")
        // 纯函数直测：JS 提取与 gate。
        let jsBody = UsageEditLines.codexProgrammaticPatchBody("const p = \"*** Begin Patch\\n*** Update File: a\\n@@\\n-x\\n+y\\n*** End Patch\"; await tools.apply_patch(p);")
        try require(jsBody != nil && jsBody!.contains("*** Begin Patch") && jsBody!.contains("+y"), "programmatic JS body extraction failed: \(String(describing: jsBody))")
        try require(UsageEditLines.codexProgrammaticPatchBody("const p = \"noop\"; text(p);") == nil, "non-apply_patch JS must not yield a body")
        try require(UsageEditLines.codexProgrammaticExecIsApplied("Script completed\nOutput:\n"), "programmatic Script completed must be applied")
        try require(!UsageEditLines.codexProgrammaticExecIsApplied("Script running with cell ID 7\n"), "programmatic running must not be applied")
        try require(!UsageEditLines.codexProgrammaticExecIsApplied("Exit code: 0\nSuccess. Updated the following files"), "programmatic gate must not fall back to legacy markers")

        // 11) Codex exec_command JSON args（decode-first 内层 cmd，还原被转义的换行）成功 gate。
        let execJson = try parse("codex_apply_patch_exec_json.jsonl", source: "codex")
        try require(execJson.editEntries.count == 1, "exec_command JSON apply_patch should yield one entry: \(execJson.editEntries.count)")
        try require(execJson.editEntries[0].added == 2 && execJson.editEntries[0].deleted == 0, "exec_command JSON +/- mismatch: +\(execJson.editEntries[0].added)/-\(execJson.editEntries[0].deleted)")

        // 12) Codex 直接 function_call 形态的 mcp__server__tool：必须有匹配成功 output；
        //     error / unsupported / 无 output 排除；成功调用物化零-token count-only 事件。
        let cxMCP = try parse("codex_mcp_function_call.jsonl", source: "codex")
        let cxMCPCounts = cxMCP.events.filter { !$0.mcpCounts.isEmpty }
        try require(cxMCPCounts.count == 2, "codex direct mcp should yield two count-only events (filesystem, github): \(cxMCPCounts.count)")
        var mergedMCP: [String: Int] = [:]
        for e in cxMCPCounts {
            try require(e.counts.total == 0, "codex mcp count-only event must carry zero tokens: \(e.counts)")
            try require(e.mergeStrategy == .cumulativeMax, "codex mcp count-only must merge cumulativeMax")
            try require(e.model == "codex-test-model", "codex mcp count-only must carry turn model: \(e.model)")
            try require(!e.hasTotalSnapshot, "codex mcp count-only must not claim a total token snapshot")
            for (k, v) in e.mcpCounts { mergedMCP[k, default: 0] += v }
        }
        try require(mergedMCP == ["filesystem": 1, "github": 1], "codex direct mcp counts mismatch: \(mergedMCP)")
        try require(cxMCPCounts.allSatisfy { $0.mcpCounts["notion"] == nil && $0.mcpCounts["slack"] == nil && $0.mcpCounts["linear"] == nil }, "failed/unsupported/unmatched direct mcp calls must be excluded")
        try require(cxMCP.events.contains { $0.counts.total == 150 }, "codex mcp rollout token event must still parse")

        // 13) Codex 技能读取：cat .../<name>/SKILL.md 计数；rg 对同路径不计（仅当模式匹配，不读内容）。
        let cxSkillRead = try parse("codex_skill_read.jsonl", source: "codex")
        let cxSkillReadCounts = cxSkillRead.events.filter { !$0.skillCounts.isEmpty }
        try require(cxSkillReadCounts.count == 1, "codex skill read should yield exactly one count-only event (cat, not rg): \(cxSkillReadCounts.count)")
        try require(cxSkillReadCounts[0].skillCounts == ["distill": 1], "codex skill read counts mismatch: \(cxSkillReadCounts[0].skillCounts)")
        try require(cxSkillReadCounts[0].counts.total == 0, "codex skill read count-only must be zero tokens")

        func codexSkillCommand(_ command: String) throws -> [String: Any] {
            let data = try JSONSerialization.data(withJSONObject: ["cmd": command])
            guard let arguments = String(data: data, encoding: .utf8) else {
                throw VerificationFailure.assertion("failed to encode codex skill command")
            }
            return ["type": "response_item", "payload": ["type": "function_call", "name": "exec_command", "arguments": arguments]]
        }
        let sedReadCounts = UsageToolMetrics.countCodexSkillReads(try codexSkillCommand("sed -n '1,20p' /x/distill/SKILL.md"))
        let sedWriteCounts = UsageToolMetrics.countCodexSkillReads(try codexSkillCommand("sed -i '' 's/a/b/' /x/distill/SKILL.md"))
        let redirectedWriteCounts = UsageToolMetrics.countCodexSkillReads(try codexSkillCommand("cat /tmp/new-skill > /x/distill/SKILL.md"))
        let redirectedReadCounts = UsageToolMetrics.countCodexSkillReads(try codexSkillCommand("cat /x/distill/SKILL.md > /tmp/copy"))
        try require(sedReadCounts == ["distill": 1], "read-only sed must count as a skill read")
        try require(sedWriteCounts.isEmpty, "sed -i skill writes must not count as reads")
        try require(redirectedWriteCounts.isEmpty, "output redirection into SKILL.md must not count as a read")
        try require(!redirectedReadCounts.isEmpty, "SKILL.md used as the input side of redirection must still count")

        // 14) Codex 技能提及：用户消息里 [$name](…/SKILL.md) 计 1。
        let cxSkillMarker = try parse("codex_skill_marker.jsonl", source: "codex")
        let cxSkillMarkerCounts = cxSkillMarker.events.filter { !$0.skillCounts.isEmpty }
        try require(cxSkillMarkerCounts.count == 1, "codex skill marker should yield one count-only event: \(cxSkillMarkerCounts.count)")
        try require(cxSkillMarkerCounts[0].skillCounts == ["brainstorming": 1], "codex skill marker counts mismatch: \(cxSkillMarkerCounts[0].skillCounts)")

        // 15) Codex programmatic MCP（JS tools.mcp__…）：仅「Script completed」成功 gate 计入；failed 排除。
        let cxProgMCP = try parse("codex_programmatic_mcp.jsonl", source: "codex")
        let cxProgMCPCounts = cxProgMCP.events.filter { !$0.mcpCounts.isEmpty }
        try require(cxProgMCPCounts.count == 1, "codex programmatic mcp should yield one confirmed-success count-only event: \(cxProgMCPCounts.count)")
        try require(cxProgMCPCounts[0].mcpCounts == ["slack": 1], "codex programmatic mcp counts mismatch (notion failed, excluded): \(cxProgMCPCounts[0].mcpCounts)")
        try require(cxProgMCPCounts[0].counts.total == 0, "codex programmatic mcp count-only must be zero tokens")

        // 15b) 直测 programmatic MCP 控制流可达性分析：只统计真正会被执行到的 tools.mcp__… 调用，
        //      排除字符串 / 正则 / 注释 / 未调用函数体 / 未执行嵌套回调；重复调用按次计重。
        let jsControlFlow = """
        const quoted = "await tools.mcp__quoted__tool({})";
        const regex = /await tools.mcp__regex__tool\\(\\{\\}\\)/;
        // await tools.mcp__line_comment__tool({})
        /* await tools.mcp__block_comment__tool({}) */
        const config = {
          text: "await tools.mcp__object_text__tool({})",
          callback: async () => {
            await tools.mcp__callback__tool({});
            (async () => {
              await tools.mcp__nested_iife__tool({});
            })();
          },
          callbackExpression: async () => await tools.mcp__callback_expression__tool({}),
          method: async function () {
            await tools.mcp__function_value__tool({});
          },
          async shorthand() {
            await tools.mcp__object_method__tool({});
          },
        };
        await Promise.all(items.map(async item => await tools.mcp__map_callback__tool({ item })));
        if (enabled) {
          await tools.mcp__filesystem__read_file({ path: "/tmp/a" });
        }
        for (const issue of issues) {
          await tools.mcp__github__create_issue(issue);
        }
        for await (const event of events) {
          await tools.mcp__teams__send_message(event);
        }
        try {
          await tools.mcp__memory__search({ query: "x" });
        } catch (err) {
          await tools.mcp__slack__search({ query: String(err) });
        } finally {
          await tools.mcp__notion__fetch({ id: "n" });
        }
        async function runLinear() {
          await tools.mcp__linear__get_issue({ id: "L-1" });
        }
        await runLinear();
        async function neverCalled() {
          await tools.mcp__never_called__tool({});
        }
        async function neverMaps() {
          return items.map(async item => await tools.mcp__nested_unexecuted_map__tool({ item }));
        }
        const runArrow = async () => await tools.mcp__azure__get_work_item({ id: "A-1" });
        await runArrow();
        const neverCalledArrow = async () => await tools.mcp__never_called_arrow__tool({});
        const invoked = {
          run: async () => { await tools.mcp__airtable__get_record({ id: "AT-1" }); },
          expression: async () => await tools.mcp__monday__get_item({ id: "MO-1" }),
          method: async function () { await tools.mcp__confluence__get_page({ id: "CF-1" }); },
          async shorthand() { await tools.mcp__figma__get_file({ id: "FG-1" }); },
        };
        await invoked.run();
        await invoked.expression();
        await invoked.method();
        await invoked.shorthand();
        async function runRepeated() {
          await tools.mcp__clickup__get_task({ id: "CU-1" });
        }
        await runRepeated();
        await runRepeated();
        if (enabled) await tools.mcp__calendar__list_events({});
        const pendingPromise = tools.mcp__drive__get_file({ id: "D-1" });
        await pendingPromise;
        await Promise.all([
          tools.mcp__asana__get_task({ id: "AS-1" }),
          tools.mcp__dropbox__get_file({ id: "DB-1" }),
        ]);
        (async () => {
          await tools.mcp__jira__get_issue({ id: "J-1" });
        })();
        """
        let got = CodexProgrammaticMCP.toolUses(jsControlFlow)
        let want: [String: Int] = [
            "filesystem": 1, "github": 1, "teams": 1, "memory": 1, "slack": 1, "notion": 1,
            "linear": 1, "azure": 1, "calendar": 1, "map_callback": 1, "drive": 1, "asana": 1,
            "dropbox": 1, "clickup": 2, "airtable": 1, "monday": 1, "confluence": 1, "figma": 1, "jira": 1,
        ]
        try require(got == want, "programmatic MCP control-flow counts mismatch: \(got)")
        for server in ["quoted", "regex", "line_comment", "block_comment", "object_text", "callback", "nested_iife", "callback_expression", "function_value", "object_method", "nested_unexecuted_map", "never_called", "never_called_arrow"] {
            try require(got[server] == nil, "non-executed \(server) text must not count: \(got)")
        }

        // 16) Codex 编辑缺时间戳：无时间戳的 apply_patch 调用不生成可归桶 edit（无法归桶），
        //     且不落入 epoch-0 桶；但乱序（output 先于 call）且 output 自身缺时间戳时，
        //     仍能结算成功 gate，令带时间戳的调用正常计入。
        let cxEditTS = try parse("codex_edit_missing_ts.jsonl", source: "codex")
        try require(cxEditTS.editEntries.count == 1, "missing-ts codex edit call must not bucket; only the timestamped one survives: \(cxEditTS.editEntries.map { $0.toolUseID })")
        let cxKept = cxEditTS.editEntries[0]
        try require(cxKept.toolUseID == "cx-keep", "wrong codex edit survived: \(cxKept.toolUseID)")
        try require(cxKept.added == 2 && cxKept.deleted == 1, "codex kept +/- mismatch: +\(cxKept.added)/-\(cxKept.deleted)")
        try require(cxKept.timestamp.timeIntervalSince1970 > 0, "surviving codex edit must not fall into the epoch-0 bucket: \(cxKept.timestamp)")
        try require(!cxEditTS.editEntries.contains { $0.timestamp.timeIntervalSince1970 == 0 }, "no codex edit may land in the epoch-0 bucket")
        try require(cxEditTS.diagnostics.contains { $0.contains("edit call skipped (missing timestamp)") }, "missing-ts codex edit must emit a redacted diagnostic: \(cxEditTS.diagnostics)")
        try require(!cxEditTS.diagnostics.contains { $0.contains("app.go") || $0.contains("Begin Patch") }, "diagnostic must not leak edit content")

        // 17) Codex programmatic MCP 缺时间戳：无时间戳的调用不计数；带时间戳的调用即便其
        //     output 自身缺时间戳，仍以「Script completed」结算并计入。
        let cxProgTS = try parse("codex_programmatic_mcp_missing_ts.jsonl", source: "codex")
        let cxProgTSCounts = cxProgTS.events.filter { !$0.mcpCounts.isEmpty }
        try require(cxProgTSCounts.count == 1, "missing-ts programmatic mcp call must not count; only the timestamped one survives: \(cxProgTSCounts.count)")
        try require(cxProgTSCounts[0].mcpCounts == ["github": 1], "programmatic mcp kept counts mismatch (slack call had no ts): \(cxProgTSCounts[0].mcpCounts)")
        try require(cxProgTSCounts[0].timestamp.timeIntervalSince1970 > 0, "surviving programmatic mcp count-only must not be epoch-0: \(cxProgTSCounts[0].timestamp)")
        try require(cxProgTS.diagnostics.contains { $0.contains("mcp call skipped (missing timestamp)") }, "missing-ts programmatic mcp must emit a redacted diagnostic: \(cxProgTS.diagnostics)")

        // 18) Claude 编辑缺时间戳：无时间戳的 tool_use 不生成可归桶 edit；带时间戳的 tool_use
        //     即便其 tool_result 自身缺时间戳，仍能结算 applied gate 并计入。
        let clEditTS = try parse("claude_edit_missing_ts.jsonl", source: "claude-code")
        try require(clEditTS.editEntries.count == 1, "missing-ts claude edit must not bucket; only the timestamped one survives: \(clEditTS.editEntries.map { $0.toolUseID })")
        let clKept = clEditTS.editEntries[0]
        try require(clKept.toolUseID == "tu-keep", "wrong claude edit survived: \(clKept.toolUseID)")
        try require(clKept.added == 2 && clKept.deleted == 1, "claude kept +/- mismatch: +\(clKept.added)/-\(clKept.deleted)")
        try require(clKept.timestamp.timeIntervalSince1970 > 0, "surviving claude edit must not fall into the epoch-0 bucket: \(clKept.timestamp)")
        try require(clEditTS.diagnostics.contains { $0.contains("edit call skipped (missing timestamp)") }, "missing-ts claude edit must emit a redacted diagnostic: \(clEditTS.diagnostics)")

        // 19) 整文件重解析确定性：同一字节流解析两次，edit / count-only / MCP 结果稳定
        //     （id、+/-、计数、时间戳、diagnostics 一致），保证无隐藏顺序 / 进程内状态依赖。
        for name in ["codex_edit_missing_ts.jsonl", "codex_programmatic_mcp_missing_ts.jsonl", "codex_mcp_function_call.jsonl", "codex_programmatic_mcp.jsonl", "claude_edit_missing_ts.jsonl"] {
            let source = name.hasPrefix("claude") ? "claude-code" : "codex"
            let a = try parse(name, source: source)
            let b = try parse(name, source: source)
            let aEdits = a.editEntries.map { "\($0.toolUseID)|\($0.added)|\($0.deleted)|\(Int64($0.timestamp.timeIntervalSince1970))" }.sorted()
            let bEdits = b.editEntries.map { "\($0.toolUseID)|\($0.added)|\($0.deleted)|\(Int64($0.timestamp.timeIntervalSince1970))" }.sorted()
            try require(aEdits == bEdits, "whole-file reparse edit determinism broken for \(name): \(aEdits) vs \(bEdits)")
            let aTools = a.events.map { "\($0.id)|\(UsageToolMetrics.countMapFingerprint($0.skillCounts))|\(UsageToolMetrics.countMapFingerprint($0.mcpCounts))" }.sorted()
            let bTools = b.events.map { "\($0.id)|\(UsageToolMetrics.countMapFingerprint($0.skillCounts))|\(UsageToolMetrics.countMapFingerprint($0.mcpCounts))" }.sorted()
            try require(aTools == bTools, "whole-file reparse event/tool determinism broken for \(name): \(aTools) vs \(bTools)")
            try require(a.diagnostics.sorted() == b.diagnostics.sorted(), "whole-file reparse diagnostics determinism broken for \(name)")
        }
    }

    private static func verifyActiveCountingRules() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-active-verification-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archivedSessions = root.appendingPathComponent("archived_sessions", isDirectory: true)
        let claudeSessions = root.appendingPathComponent("claude-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archivedSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("active verification cleanup failed: \(error)\n", stderr) }
        }

        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        func makeRollout(
            _ name: String,
            originator: String = "Codex Desktop",
            threadSource: String = "user",
            cwd: String = "/tmp/project",
            events: [String],
            modifiedAt: Date,
            directory: URL? = nil,
            sessionID: String? = nil
        ) throws {
            let url = (directory ?? sessions).appendingPathComponent("rollout-\(name).jsonl")
            try writeRollout(
                to: url,
                cwd: cwd,
                events: events,
                sessionID: sessionID ?? name,
                threadSource: threadSource,
                originator: originator
            )
            try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        }

        try makeRollout("recent", events: [startedEvent()], modifiedAt: base)
        try makeRollout(
            "recent-duplicate",
            events: [startedEvent()],
            modifiedAt: base,
            sessionID: "recent"
        )
        try makeRollout(
            "stale",
            events: [startedEvent()],
            modifiedAt: base.addingTimeInterval(-(CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds + 1))
        )
        try makeRollout("complete", events: [startedEvent(), completeEvent(turnID: "done")], modifiedAt: base)
        try makeRollout("aborted", events: [startedEvent(), abortedEvent()], modifiedAt: base)
        try makeRollout(
            "subagent",
            threadSource: "subagent",
            events: [startedEvent()],
            modifiedAt: base
        )
        try makeRollout(
            "automation",
            cwd: "/tmp/automations/nightly",
            events: [startedEvent(), completeEvent(turnID: "automation")],
            modifiedAt: base
        )
        try makeRollout(
            "cli-recent",
            originator: "codex_exec",
            events: [startedEvent()],
            modifiedAt: base
        )
        try makeRollout(
            "cli-stale",
            originator: "codex_exec",
            events: [startedEvent()],
            modifiedAt: base.addingTimeInterval(-(CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds + 1))
        )
        try makeRollout(
            "archived",
            events: [startedEvent(), completeEvent(turnID: "archived")],
            modifiedAt: base,
            directory: archivedSessions
        )

        func writeClaudeRegistry(pid: Int32, sessionID: String, status: String) throws {
            let json = "{\"pid\":\(pid),\"sessionId\":\"\(sessionID)\",\"kind\":\"interactive\",\"entrypoint\":\"cli\",\"status\":\"\(status)\"}"
            try json.write(
                to: claudeSessions.appendingPathComponent("\(pid).json"),
                atomically: true,
                encoding: .utf8
            )
        }
        for pid: Int32 in 201...204 {
            try writeClaudeRegistry(
                pid: pid,
                sessionID: "claude-\(pid)",
                status: pid == 201 ? "busy" : "idle"
            )
        }
        try writeClaudeRegistry(pid: 999, sessionID: "stale-registry", status: "busy")

        let codexProcesses = [
            RunningProcess(pid: 101, executablePath: "/private/tmp/codex"),
            RunningProcess(pid: 105, executablePath: "codex"),
        ]
        let claudeProcesses = (201...204).map {
            RunningProcess(pid: Int32($0), executablePath: "/opt/homebrew/bin/claude")
        }
        let desktopHelper = RunningProcess(
            pid: 102,
            executablePath: "/Applications/Codex.app/Contents/Resources/codex"
        )
        let wrapper = RunningProcess(pid: 103, executablePath: "/opt/homebrew/bin/node")
        let scanner = SequencedScanner(snapshots: [
            codexProcesses + claudeProcesses + [desktopHelper, wrapper],
            [],
            [],
        ])
        let configuration = CodexRuntimeMetricsConfiguration(
            sessionsDirectories: [sessions, archivedSessions],
            automationRoots: [],
            databaseURL: root.appendingPathComponent("active.sqlite"),
            claudeSessionsDirectory: claudeSessions,
            claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
        )
        let collector = try CodexRuntimeMetricsCollector(
            configuration: configuration,
            processScanner: scanner
        )

        let active = try await collector.scan(at: base)
        // active 口径：会话最近 5 分钟内有活动即算 active，不再要求尾部生命周期为 task_started。
        // recent / complete / aborted 三者 mtime 均在窗口内 → 全部 active；stale 超时 → 不计。
        try require(active.desktopActive == 3, "recent Desktop sessions with activity in-window were not all active")
        try require(active.taskBreakdown.codexDesktop.totalTasks == 4, "Desktop total did not deduplicate current non-automation sessions")
        try require(active.taskBreakdown.codexDesktop.activeTasks == 3, "Desktop active window mismatch")
        try require(active.taskBreakdown.codexCLI.totalTasks == 2, "Codex CLI total must equal current independent processes")
        try require(active.taskBreakdown.codexCLI.activeTasks == 1, "Codex CLI active must be process-capped")
        try require(active.taskBreakdown.claudeCLI.totalTasks == 4, "Claude stale registry was counted or opened registries were missed")
        try require(active.taskBreakdown.claudeCLI.activeTasks == 1, "Claude busy registry count mismatch")
        try require(active.terminalActive == 2, "Terminal active did not sum Codex and Claude lifecycle activity")
        try require(active.totalTasks == 10 && active.activeTasks == 5, "aggregate total/active breakdown mismatch")
        try require(active.completed.value == 1, "archive or automation completion leaked into current completed count")
        try require(!active.activeCountsArePartial, "healthy active sources were marked partial")

        let exited = try await collector.scan(at: base.addingTimeInterval(1))
        try require(exited.terminalActive == 0, "exited terminal process did not disappear on the next scan")
        try require(exited.taskBreakdown.codexCLI.totalTasks == 0, "closed Codex CLI remained in total")
        try require(exited.taskBreakdown.claudeCLI.totalTasks == 0, "closed Claude CLI remained in total")
        try require(exited.desktopActive == 3, "unchanged recent Desktop tasks did not survive cache reuse")

        let timedOut = try await collector.scan(
            at: base.addingTimeInterval(CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds + 1)
        )
        try require(timedOut.desktopActive == 0, "stale started Desktop task did not time out after five minutes")

        // 回归：正在生成下一轮的 Desktop 会话,尾部生命周期是上一轮的 task_complete,之后仍有 output token 流。
        // 旧实现要求 lifecycleStarted 才计 active,会漏判这种“回合间仍在产出”的活跃会话(即用户上报的 bug)。
        try await verifyDesktopActiveAfterCompleteWithTrailingOutput()

        let failingCollector = try CodexRuntimeMetricsCollector(
            configuration: .init(
                sessionsDirectories: [sessions],
                automationRoots: [],
                databaseURL: root.appendingPathComponent("process-unavailable.sqlite"),
                claudeSessionsDirectory: claudeSessions,
                claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
            ),
            processScanner: FakeScanner(error: .launchFailed("fixture"))
        )
        let processUnavailable = try await failingCollector.scan(at: base)
        try require(processUnavailable.desktopActive == 3, "process failure erased independently known Desktop active")
        try require(processUnavailable.terminalActive == nil, "failed process scan fabricated a terminal count")
        try require(processUnavailable.taskBreakdown.codexCLI.quality == .unavailable, "process failure fabricated Codex CLI quality")
        try require(processUnavailable.taskBreakdown.claudeCLI.quality == .unavailable, "process failure fabricated Claude CLI quality")
        try require(processUnavailable.activeCountsArePartial, "failed process scan was not marked partial")
    }

    // 回归用例:Desktop 会话回合间正在生成——尾部生命周期是上一轮 task_complete,之后仍有 output token 流。
    // 旧实现以 lifecycleStarted 为硬前提,会把这种活跃会话判为非 active(desktopActive=0),即用户上报的 bug。
    private static func verifyDesktopActiveAfterCompleteWithTrailingOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-desktop-trailing-output-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let claudeSessions = root.appendingPathComponent("claude-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("desktop trailing-output cleanup failed: \(error)\n", stderr) }
        }

        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let url = sessions.appendingPathComponent("rollout-generating.jsonl")
        try writeRollout(
            to: url,
            cwd: "/tmp/project",
            events: [
                startedEvent(),
                completeEvent(turnID: "t1"),
                tokenEvent(at: base.addingTimeInterval(-2), totalOutput: 100),
                tokenEvent(at: base.addingTimeInterval(-1), totalOutput: 260),
            ],
            sessionID: "generating",
            threadSource: "user",
            originator: "Codex Desktop"
        )
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: url.path)

        // 新版 Codex Desktop 顶层会话:source 是标量入口("vscode"),但 thread_source 被标为 "subagent"。
        // 旧口径(thread_source=="user")会漏判 → Desktop active 恒 0(即用户上报的现象)。
        let driftURL = sessions.appendingPathComponent("rollout-drifted.jsonl")
        try writeRollout(
            to: driftURL,
            cwd: "/tmp/project-drift",
            events: [startedEvent()],
            sessionID: "drifted-top-level",
            threadSource: "subagent",
            originator: "Codex Desktop",
            sourceJSON: "\"vscode\""
        )
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: driftURL.path)

        // 真正的派生子 agent:source 是对象(含 thread_spawn)。不得计入 Desktop task。
        let subagentURL = sessions.appendingPathComponent("rollout-subagent.jsonl")
        try writeRollout(
            to: subagentURL,
            cwd: "/tmp/project-sub",
            events: [startedEvent()],
            sessionID: "spawned-subagent",
            threadSource: "subagent",
            originator: "Codex Desktop",
            sourceJSON: "{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"p\",\"depth\":2}}}"
        )
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: subagentURL.path)

        let configuration = CodexRuntimeMetricsConfiguration(
            sessionsDirectories: [sessions],
            automationRoots: [],
            databaseURL: root.appendingPathComponent("trailing.sqlite"),
            claudeSessionsDirectory: claudeSessions,
            claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
        )
        let collector = try CodexRuntimeMetricsCollector(
            configuration: configuration,
            processScanner: FakeScanner(processes: [])
        )

        let active = try await collector.scan(at: base)
        // generating + drifted 两个顶层 Desktop 会话计入;spawned-subagent 排除。
        try require(
            active.taskBreakdown.codexDesktop.totalTasks == 2,
            "top-level Desktop sessions (incl. drifted source=string) were not counted; sub-agent must be excluded"
        )
        try require(
            active.desktopActive == 2,
            "both the generating and drifted-top-level Desktop sessions must count as active"
        )

        // 同一会话在 5 分钟窗口外(无新活动)必须回落为非 active,验证放宽 guard 未破坏超时下界。
        let afterTimeout = try await collector.scan(
            at: base.addingTimeInterval(CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds + 1)
        )
        try require(
            afterTimeout.desktopActive == 0,
            "sessions with no activity for over five minutes must fall out of active"
        )
    }

    private static func verifyClaudeDesktopCounting() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-claude-desktop-verification-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let claudeSessions = root.appendingPathComponent("claude-sessions", isDirectory: true)
        let claudeProjects = root
            .appendingPathComponent("claude-projects", isDirectory: true)
            .appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Claude Desktop verification cleanup failed: \(error)\n", stderr) }
        }

        let base = Date(timeIntervalSince1970: 90_000)
        let timestamp = ISO8601DateFormatter().string(from: base.addingTimeInterval(-1))
        let activeSession = "{\"type\":\"user\",\"sessionId\":\"desktop-active\",\"entrypoint\":\"claude-desktop-3p\",\"timestamp\":\"\(timestamp)\",\"message\":{\"role\":\"user\"}}\n"
        let completedSession = "{\"type\":\"assistant\",\"sessionId\":\"desktop-complete\",\"entrypoint\":\"claude-desktop-3p\",\"timestamp\":\"\(timestamp)\",\"message\":{\"role\":\"assistant\",\"stop_reason\":\"end_turn\"}}\n"
        try activeSession.write(
            to: claudeProjects.appendingPathComponent("desktop-active.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try completedSession.write(
            to: claudeProjects.appendingPathComponent("desktop-complete.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let scanner = SequencedScanner(snapshots: [[
            RunningProcess(
                pid: 501,
                executablePath: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
            RunningProcess(
                pid: 502,
                executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
            ),
        ], []])
        let collector = try CodexRuntimeMetricsCollector(
            configuration: .init(
                sessionsDirectories: [sessions],
                automationRoots: [],
                databaseURL: root.appendingPathComponent("claude-desktop.sqlite"),
                claudeSessionsDirectory: claudeSessions,
                claudeProjectsDirectory: root.appendingPathComponent("claude-projects")
            ),
            processScanner: scanner
        )

        let running = try await collector.scan(at: base)
        try require(running.taskBreakdown.claudeDesktop.present, "running Claude Desktop was reported closed")
        try require(running.taskBreakdown.claudeDesktop.totalTasks == 2, "Claude Desktop total task count mismatch")
        try require(running.taskBreakdown.claudeDesktop.activeTasks == 1, "Claude Desktop active tail detection mismatch")

        let closed = try await collector.scan(at: base.addingTimeInterval(1))
        try require(!closed.taskBreakdown.claudeDesktop.present, "closed Claude Desktop remained present")
        try require(closed.taskBreakdown.claudeDesktop.totalTasks == 0, "closed Claude Desktop retained historical tasks")
        try require(closed.taskBreakdown.claudeDesktop.activeTasks == 0, "closed Claude Desktop retained active tasks")
    }

    private static func verifyClaudeTPSIntegration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-claude-tps-verification-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let claudeSessions = root.appendingPathComponent("claude-sessions", isDirectory: true)
        let claudeProjects = root
            .appendingPathComponent("claude-projects", isDirectory: true)
            .appendingPathComponent("project-a", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("Claude TPS verification cleanup failed: \(error)\n", stderr) }
        }

        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let codexRollout = sessions.appendingPathComponent("rollout-codex-tps.jsonl")
        try writeRollout(
            to: codexRollout,
            cwd: "/tmp/project",
            events: [tokenEvent(at: base, totalOutput: 100)],
            sessionID: "codex-tps"
        )
        let claudeLog = claudeProjects.appendingPathComponent("claude-session.jsonl")
        try writeRollout(
            to: claudeLog,
            cwd: "/tmp/claude-project",
            events: [
                completeEvent(turnID: "must-not-count"),
                messageEvent(at: base, messageID: "same-message", output: 100),
                messageEvent(at: base, messageID: "historical-message", output: 50),
            ],
            sessionID: "must-not-be-a-task",
            originator: "Codex Desktop"
        )
        for file in [codexRollout, claudeLog] {
            try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: file.path)
        }

        let collector = try CodexRuntimeMetricsCollector(
            configuration: .init(
                sessionsDirectories: [sessions],
                automationRoots: [],
                databaseURL: root.appendingPathComponent("claude-tps.sqlite"),
                claudeSessionsDirectory: claudeSessions,
                claudeProjectsDirectory: root.appendingPathComponent("claude-projects", isDirectory: true)
            ),
            processScanner: FakeScanner()
        )

        let cold = try await collector.scan(at: base)
        try require(cold.liveRate.tps == 0, "Claude historical output replayed during cold discovery")
        try require(cold.totalTasks == 0, "Claude project JSONL leaked into task totals")
        try require(cold.completed.value == 0, "Claude project JSONL leaked into completed totals")

        try appendLine(
            messageEvent(at: base.addingTimeInterval(1), messageID: "same-message", output: 100),
            to: claudeLog
        )
        let duplicate = try await collector.scan(at: base.addingTimeInterval(1))
        try require(duplicate.liveRate.tps == 0, "repeated Claude message usage was double-counted")

        try appendLine(
            messageEvent(at: base.addingTimeInterval(2), messageID: "same-message", output: 140),
            to: claudeLog
        )
        try appendLine(
            messageEvent(at: base.addingTimeInterval(2), messageID: "new-message", output: 60),
            to: claudeLog
        )
        let claudeDelta = try await collector.scan(at: base.addingTimeInterval(2))
        try requireApproximatelyEqual(
            claudeDelta.liveRate.tps,
            100.0 / Double(LiveRateSample.windowSeconds),
            "Claude same-message delta and new-message increment mismatch"
        )

        try appendLine(tokenEvent(at: base.addingTimeInterval(3), totalOutput: 190), to: codexRollout)
        let combined = try await collector.scan(at: base.addingTimeInterval(3))
        try requireApproximatelyEqual(
            combined.liveRate.tps,
            190.0 / Double(LiveRateSample.windowSeconds),
            "Codex and Claude output TPS did not aggregate"
        )
        try require(combined.diagnostics.tokensAfterDeduplication == 190, "combined token delta diagnostics mismatch")
        try require(combined.diagnostics.activeSessions == 2, "Codex and Claude active token sessions mismatch")
    }

    private static func verifyOracleColdStartAndCandidateRules() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-oracle-regression-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let alias = root.appendingPathComponent("sessions-alias", isDirectory: true)
        let database = root.appendingPathComponent("agent-pulse.sqlite")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: sessions)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("oracle regression cleanup failed: \(error)\n", stderr) }
        }

        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var trackedFiles: [URL] = []
        for index in 0..<100 {
            let file = sessions.appendingPathComponent(String(format: "rollout-%03d.jsonl", index))
            var events = [
                tokenEvent(at: base.addingTimeInterval(-10), totalOutput: 0),
                tokenEvent(at: base, totalOutput: 2_048),
            ]
            if index == 1 {
                events.append(messageEvent(at: base, messageID: "message-1", output: 100))
            }
            try writeRollout(
                to: file,
                cwd: "/tmp/project",
                events: events,
                sessionID: "oracle-\(index)",
                threadSource: index == 1 ? "subagent" : "user"
            )
            try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: file.path)
            trackedFiles.append(file)
        }
        let aggregate = sessions.appendingPathComponent("rollout-summary.jsonl")
        try writeRollout(to: aggregate, cwd: "/tmp/project", events: [])
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: aggregate.path)
        let empty = sessions.appendingPathComponent("rollout-empty.jsonl")
        try Data().write(to: empty)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: empty.path)
        let old = sessions.appendingPathComponent("rollout-old.jsonl")
        try writeRollout(to: old, cwd: "/tmp/project", events: [
            tokenEvent(at: base, totalOutput: 999_999)
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(-(15 * 60 + 1))],
            ofItemAtPath: old.path
        )

        let collector = try CodexRuntimeMetricsCollector(configuration: .init(
            sessionsDirectories: [sessions, alias, sessions],
            automationRoots: [],
            databaseURL: database,
            claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
        ))
        let cold = try await collector.scan(at: base)
        let historicalReplayTPS = Double(100 * 2_048) / Double(LiveRateSample.windowSeconds)
        try require(historicalReplayTPS > 1_100, "regression fixture no longer reproduces the old thousand-TPS replay")
        try require(cold.liveRate.tps == 0, "cold discovery replayed pre-start history into TPS")
        try require(cold.diagnostics.configuredRoots == 3, "configured root count mismatch")
        try require(cold.diagnostics.canonicalRoots == 1, "duplicate/symlink roots were not canonicalized")
        try require(cold.diagnostics.trackedLiveFiles == 96, "oracle max-96 candidate cap mismatch")
        try require(cold.diagnostics.excludedAggregateFiles == 1, "aggregate JSONL was not excluded")
        try require(cold.diagnostics.excludedEmptyFiles == 1, "empty JSONL was not excluded")
        try require(cold.diagnostics.excludedStaleFiles == 1, "15-minute mtime filter mismatch")
        try require(cold.diagnostics.emittedTokenEvents == 0, "cold baseline emitted token events")
        try require(cold.diagnostics.baselineObservations == 193, "tail baseline observation count mismatch")
        try require(cold.diagnostics.subagentFiles == 1, "subagent provider classification mismatch")

        try appendLine(messageEvent(at: base.addingTimeInterval(1), messageID: "message-1", output: 100), to: trackedFiles[1])
        let repeatedMessage = try await collector.scan(at: base.addingTimeInterval(1))
        try require(repeatedMessage.liveRate.tps == 0, "repeated message usage was double-counted")
        try appendLine(messageEvent(at: base.addingTimeInterval(2), messageID: "message-1", output: 140), to: trackedFiles[1])
        let messageDelta = try await collector.scan(at: base.addingTimeInterval(2))
        try requireApproximatelyEqual(
            messageDelta.liveRate.tps,
            40.0 / Double(LiveRateSample.windowSeconds),
            "message identity delta mismatch"
        )
        try appendLine(tokenEvent(at: base.addingTimeInterval(3), totalOutput: 2_228), to: trackedFiles[0])
        let warm = try await collector.scan(at: base.addingTimeInterval(3))
        try requireApproximatelyEqual(
            warm.liveRate.tps,
            220.0 / Double(LiveRateSample.windowSeconds),
            "post-baseline cumulative/message aggregate mismatch"
        )
        try require(warm.diagnostics.tokensAfterDeduplication == 220, "deduplicated token total mismatch")
        try require(warm.diagnostics.tokensBeforeDeduplication == 420, "pre-dedup token total mismatch")
        try require(warm.diagnostics.activeSessions == 2, "active session count mismatch")
        try appendLine(
            combinedTokenEvent(
                at: base.addingTimeInterval(4),
                lastOutput: 999,
                totalOutput: 2_067
            ),
            to: trackedFiles[2]
        )
        let combinedUsage = try await collector.scan(at: base.addingTimeInterval(4))
        try requireApproximatelyEqual(
            combinedUsage.liveRate.tps,
            239.0 / Double(LiveRateSample.windowSeconds),
            "last_token_usage and total_token_usage were both counted"
        )
        if ProcessInfo.processInfo.environment["AGENT_PULSE_PRINT_RECONCILE"] == "1" {
            print("swift_regression_historical_replay_tps=\(String(format: "%.6f", historicalReplayTPS))")
            print("swift_regression_cold_files=\(cold.diagnostics.trackedLiveFiles)")
            print("swift_regression_cold_tps=\(String(format: "%.6f", cold.liveRate.tps ?? 0))")
            print("swift_regression_warm_tokens=\(Int(warm.liveRate.tokensInWindow ?? 0))")
            print("swift_regression_warm_active_sessions=\(warm.diagnostics.activeSessions)")
            print("swift_regression_warm_tps=\(String(format: "%.6f", warm.liveRate.tps ?? 0))")
        }
    }

    private static func verifyRuntimeCollectorAndPersistence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-runtime-verification-\(UUID().uuidString)", isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let database = root.appendingPathComponent("Application Support/AgentPulse/agent-pulse.sqlite")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { fputs("runtime verification cleanup failed: \(error)\n", stderr) }
        }

        let rollout = sessions.appendingPathComponent("rollout-verification.jsonl")
        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let configuration = CodexRuntimeMetricsConfiguration(
            sessionsDirectories: [sessions],
            automationRoots: [root.appendingPathComponent("automations").path],
            databaseURL: database,
            claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
        )

        try writeRollout(to: rollout, cwd: "/tmp/project", events: [])
        let collector = try CodexRuntimeMetricsCollector(configuration: configuration)
        let noData = try await collector.scan(at: base)
        try require(noData.liveRate.state == .noData, "missing output signal must be no_data")
        try require(noData.completed.quality == .partial, "local completed metric must always be partial")
        try require(noData.completed.scope == .allLocal, "local completed metric must be allLocal")
        try require(noData.completed.isLowerBound, "local completed metric must be a lower bound")

        try writeRollout(to: rollout, cwd: "/tmp/project", events: [
            threadSettingsEvent(model: "custom-code-model"),
            modelFreePaddingEvent(byteCount: 600_000),
            tokenEvent(at: base, totalOutput: 100)
        ])
        let zero = try await collector.scan(at: base.addingTimeInterval(1))
        try require(
            zero.liveRate.state == .zero && zero.liveRate.tps == 0,
            "healthy baseline without delta must be zero; got \(zero.liveRate.state.rawValue), reused=\(zero.filesReusedFromCache), incremental=\(zero.filesReadIncrementally), full=\(zero.filesFullyParsed)"
        )

        try appendLine(tokenEvent(at: base.addingTimeInterval(2), totalOutput: 280), to: rollout)
        let appended = try await collector.scan(at: base.addingTimeInterval(2))
        try requireApproximatelyEqual(appended.liveRate.tps, 1, "append-only cumulative delta was not tailed incrementally")
        try requireApproximatelyEqual(
            appended.liveRate.modelTokensInWindow["custom-code-model"],
            180,
            "thread_settings_applied model was not inherited by token_count delta"
        )
        try require(appended.liveRate.modelTokensInWindow["unknown"] == nil, "known custom-code-model delta fell into unknown")

        try writeRollout(to: rollout, cwd: "/tmp/project", events: [
            tokenEvent(at: base.addingTimeInterval(-598), totalOutput: 0)
        ])
        let intervalBaseline = try await collector.scan(at: base.addingTimeInterval(2))
        try require(
            intervalBaseline.diagnostics.emittedTokenEvents == 0,
            "replacement must rebuild baseline without history replay"
        )
        try appendLine(tokenEvent(at: base.addingTimeInterval(2), totalOutput: 6_000), to: rollout)
        let interval = try await collector.scan(at: base.addingTimeInterval(2))
        try require(interval.liveRate.state == .live, "interval output must be live")
        try requireApproximatelyEqual(interval.liveRate.tps, 10, accuracy: 0.000_001, "600-second interval overlap")
        let warmClock = ContinuousClock()
        let warmStarted = warmClock.now
        let warmInterval = try await collector.scan(at: base.addingTimeInterval(2))
        let warmElapsed = warmClock.now - warmStarted
        try require(warmElapsed < .seconds(2), "unchanged warm scan exceeded the 2-second hard limit")
        try require(warmInterval.desktopActive == interval.desktopActive, "warm scan changed desktop count")
        try require(warmInterval.terminalActive == interval.terminalActive, "warm scan changed terminal count")
        try require(warmInterval.completed == interval.completed, "warm scan changed completed count metadata")
        try require(warmInterval.liveRate == interval.liveRate, "warm scan changed TPS for the same timestamp")

        try writeRollout(to: rollout, cwd: "/tmp/project", events: [
            tokenEvent(at: base.addingTimeInterval(-180), totalOutput: 1_000)
        ])
        _ = try await collector.scan(at: base.addingTimeInterval(3))
        try appendLine(tokenEvent(at: base.addingTimeInterval(-170), totalOutput: 100), to: rollout)
        let resetBaseline = try await collector.scan(at: base.addingTimeInterval(3))
        try require(resetBaseline.liveRate.tps == 0, "counter decrease must not emit tokens")
        try appendLine(tokenEvent(at: base, totalOutput: 280), to: rollout)
        try appendLine(completeEvent(turnID: "turn-1"), to: rollout)
        let reset = try await collector.scan(at: base.addingTimeInterval(3))
        try requireApproximatelyEqual(reset.liveRate.tps, 1, accuracy: 0.000_001, "counter reset created a spike")
        try require(reset.completed.value == 1, "interactive completion was not counted")

        let restoredCollector = try CodexRuntimeMetricsCollector(configuration: configuration)
        let cachedState = await restoredCollector.restoredDisplayState()
        try require(cachedState.snapshot?.desktopActive == reset.desktopActive, "cached desktop count mismatch")
        try require(cachedState.snapshot?.terminalActive == reset.terminalActive, "cached terminal count mismatch")
        try require(cachedState.snapshot?.completed == reset.completed, "cached completed metric mismatch")
        try require(cachedState.snapshot?.liveRate == reset.liveRate, "cached TPS sample mismatch")
        try require(!cachedState.history.isEmpty, "cached TPS history was not restored without scanning")
        let restored = try await restoredCollector.scan(at: base.addingTimeInterval(4))
        try require(restored.history.contains(where: { $0.timestamp == base }), "SQLite history did not restore the first sample")
        try require(
            restored.history.count >= 5,
            "SQLite and in-memory history were not merged (count=\(restored.history.count))"
        )

        try writeRollout(to: rollout, cwd: "/tmp/a/automations/nested/project", events: [
            completeEvent(turnID: "automation-turn")
        ])
        let automation = try await restoredCollector.scan(at: base.addingTimeInterval(5))
        try require(automation.completed.value == 0, "an automations path segment was included")

        try writeRollout(to: rollout, cwd: "/tmp/project", events: [
            tokenEvent(at: base.addingTimeInterval(-400), totalOutput: 100)
        ])
        let stale = try await restoredCollector.scan(at: base.addingTimeInterval(6))
        try require(stale.liveRate.state == .stale, "old output signal must be stale")

        let promotedSessions = root.appendingPathComponent("promoted-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: promotedSessions, withIntermediateDirectories: true)
        let promotedRollout = promotedSessions.appendingPathComponent("rollout-promoted.jsonl")
        try writeRollout(to: promotedRollout, cwd: "/tmp/project", events: [
            threadSettingsEvent(model: "codex-test-model"),
            tokenEvent(at: base.addingTimeInterval(-3_600), totalOutput: 100)
        ], sessionID: "promoted-verification")
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(-3_600)],
            ofItemAtPath: promotedRollout.path
        )
        let promotedConfiguration = CodexRuntimeMetricsConfiguration(
            sessionsDirectories: [promotedSessions],
            automationRoots: [],
            databaseURL: root.appendingPathComponent("promoted.sqlite"),
            claudeProjectsDirectory: root.appendingPathComponent("missing-promoted-claude")
        )
        let promotedCollector = try CodexRuntimeMetricsCollector(configuration: promotedConfiguration)
        _ = try await promotedCollector.scan(at: base)
        try appendLine(tokenEvent(at: base.addingTimeInterval(11), totalOutput: 200), to: promotedRollout)
        let promotedBaseline = try await promotedCollector.scan(at: base.addingTimeInterval(11))
        try require(
            promotedBaseline.liveRate.modelTokensInWindow["unknown"] == nil,
            "promoting a completed-only file must rebuild its live baseline"
        )
        try appendLine(tokenEvent(at: base.addingTimeInterval(12), totalOutput: 380), to: promotedRollout)
        let promotedDelta = try await promotedCollector.scan(at: base.addingTimeInterval(12))
        try requireApproximatelyEqual(
            promotedDelta.liveRate.modelTokensInWindow["codex-test-model"],
            180,
            "promoted file lost its model context"
        )
        try require(
            promotedDelta.liveRate.modelTokensInWindow["unknown"] == nil,
            "promoted file delta fell into unknown"
        )

        let unavailableConfiguration = CodexRuntimeMetricsConfiguration(
            sessionsDirectories: [root.appendingPathComponent("missing-sessions")],
            automationRoots: [],
            databaseURL: root.appendingPathComponent("unavailable.sqlite"),
            claudeProjectsDirectory: root.appendingPathComponent("missing-claude-projects")
        )
        let unavailableCollector = try CodexRuntimeMetricsCollector(configuration: unavailableConfiguration)
        let unavailable = try await unavailableCollector.scan(at: base)
        try require(unavailable.liveRate.state == .unavailable, "missing source must be unavailable")
    }

    private static func writeRollout(
        to url: URL,
        cwd: String,
        events: [String],
        sessionID: String = "runtime-verification",
        threadSource: String = "user",
        originator: String = "codex_exec",
        sourceJSON: String? = nil
    ) throws {
        // sourceJSON 为已编码的 JSON 片段（字符串如 "\"vscode\"" 或对象如 {"subagent":{...}}），
        // 用于覆盖新版 session_meta 的 payload.source 字段；nil 时不写 source（旧格式）。
        let sourceField = sourceJSON.map { ",\"source\":\($0)" } ?? ""
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(sessionID)\",\"thread_source\":\"\(threadSource)\",\"originator\":\"\(originator)\",\"cwd\":\"\(cwd)\"\(sourceField)}}"
        try ([meta] + events).joined(separator: "\n").appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    private static func appendLine(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    private static func tokenEvent(at date: Date, totalOutput: Int) -> String {
        let formatter = ISO8601DateFormatter()
        return "{\"timestamp\":\"\(formatter.string(from: date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"output_tokens\":\(totalOutput),\"input_tokens\":999999,\"cached_input_tokens\":999999,\"reasoning_output_tokens\":999999}}}}"
    }

    private static func threadSettingsEvent(model: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_settings\":{\"model\":\"\(model)\"}}}"
    }

    private static func modelFreePaddingEvent(byteCount: Int) -> String {
        let padding = String(repeating: "x", count: byteCount)
        return "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"content\":\"\(padding)\"}}"
    }

    private static func messageEvent(at date: Date, messageID: String, output: Int) -> String {
        let formatter = ISO8601DateFormatter()
        return "{\"timestamp\":\"\(formatter.string(from: date))\",\"type\":\"assistant\",\"sessionId\":\"message-session\",\"message\":{\"id\":\"\(messageID)\",\"usage\":{\"output_tokens\":\(output)}}}"
    }

    private static func combinedTokenEvent(at date: Date, lastOutput: Int, totalOutput: Int) -> String {
        let formatter = ISO8601DateFormatter()
        return "{\"timestamp\":\"\(formatter.string(from: date))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"output_tokens\":\(lastOutput)},\"total_token_usage\":{\"output_tokens\":\(totalOutput)}}}}"
    }

    private static func completeEvent(turnID: String) -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"\(turnID)\"}}"
    }

    private static func startedEvent() -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}"
    }

    private static func abortedEvent() -> String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_aborted\"}}"
    }

    // FS-PROJ) 回归：血缘去重会丢弃携带 project 的原始行，session project 必须从**全量 raw**取，
    // 而非 deduped —— 证明去重后仍能解析出正确 project。
    private static func verifyV2ProjectFromRawNotDeduped() throws {
        let db = tempUsageDB(); defer { cleanupDB(db) }
        let ledger = try UsageLedgerStore(path: db.path)
        let ts = "2026-12-15T00:00:00Z"
        func totalLine(out: Int, total: Int) -> String {
            "{\"timestamp\":\"\(ts)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"output_tokens\":\(out),\"input_tokens\":0,\"total_tokens\":\(total)}}}}"
        }
        // parent 与 child(subagent) 共享同一完整 total 快照 -> 血缘指纹一致 -> 折叠为一。
        // 让**被折叠掉**的那条携带 project（cwd），验证 project 仍能从全量 raw 解析。
        let parent = """
        {"type":"session_meta","payload":{"id":"parent-proj","session_id":"parent-session-proj","cwd":"/w/parent-proj"}}
        {"type":"turn_context","payload":{"model":"m"}}
        {"timestamp":"\(ts)","type":"response_item","payload":{"type":"message","role":"assistant"}}
        \(totalLine(out: 100, total: 100))
        """
        let child = """
        {"type":"session_meta","payload":{"id":"child-proj","session_id":"child-session-proj","parent_thread_id":"parent-proj","cwd":"/w/child-proj"}}
        {"timestamp":"\(ts)","type":"response_item","payload":{"type":"message","role":"assistant"}}
        \(totalLine(out: 100, total: 100))
        """
        let pp = UsageJSONLParser.parse(data: Data(parent.utf8), source: "codex", fileIdentity: "parent-proj.jsonl")
        let cp = UsageJSONLParser.parse(data: Data(child.utf8), source: "codex", fileIdentity: "child-proj.jsonl")
        try require(pp.events.first?.lineageFingerprint == cp.events.first?.lineageFingerprint, "parent/child replay share lineage fingerprint")
        try require(pp.events.first?.project.isEmpty == false && cp.events.first?.project.isEmpty == false, "both raw events carry a project")
        let parentProject = pp.events[0].project
        let childProject = cp.events[0].project
        try require(parentProject != childProject, "parent/child must resolve to distinct projects for this regression")
        try ledger.record(events: pp.events, sessionEvents: pp.sessionEvents, checkpoint: pp.checkpoint, hostname: "h")
        try ledger.record(events: cp.events, sessionEvents: cp.sessionEvents, checkpoint: cp.checkpoint, hostname: "h")
        try ledger.finalizeDerived(hostname: "h")

        // 两条 raw 各属不同 session，血缘去重只把其一从聚合中折叠，但 project map 从全量 raw 计算，
        // 两个 session 仍各自解析出各自 project（不因去重而丢失）。
        let sessions = try ledger.sessions(hostname: "h")
        let projects = Set(sessions.map { $0.project })
        try require(sessions.count == 2, "two sessions aggregated (parent + child): got \(sessions.count)")
        try require(projects.contains(parentProject) && projects.contains(childProject),
                    "session project must resolve from full raw events despite lineage dedup: got \(projects), want [\(parentProject), \(childProject)]")
    }


    private static func verifyV2SessionProjectWireAndMigration() throws {
        // 3a) project 内容字段贯通：insert -> finalize -> read/pending/fullSync 均带 project。
        let db = tempUsageDB(); defer { cleanupDB(db) }
        var ledger: UsageLedgerStore? = try UsageLedgerStore(path: db.path)
        // codex：token 事件带 cwd=/w/projectX -> project 落在 UsageEvent.project；同 session 的会话事件。
        let file = """
        {"type":"session_meta","payload":{"session_id":"sp","thread_source":"user","cwd":"/w/projectX"}}
        {"type":"turn_context","payload":{"model":"m"}}
        {"timestamp":"2026-11-01T00:00:00Z","type":"response_item","payload":{"type":"message","role":"assistant"}}
        {"timestamp":"2026-11-01T00:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"output_tokens":50,"total_tokens":50}}}}
        """
        let p = UsageJSONLParser.parse(data: Data(file.utf8), source: "codex", fileIdentity: "proj.jsonl")
        try require(p.events.first?.project.isEmpty == false, "token event should carry a non-empty project from cwd")
        let expectedProject = p.events[0].project
        try ledger!.record(events: p.events, sessionEvents: p.sessionEvents, checkpoint: p.checkpoint, hostname: "h")
        try ledger!.finalizeDerived(hostname: "h")

        let sessions = try ledger!.sessions(hostname: "h")
        try require(sessions.count == 1, "one session aggregated")
        try require(sessions[0].project == expectedProject, "session project must derive from latest valid UsageEvent.project: got '\(sessions[0].project)' want '\(expectedProject)'")

        let pending = try ledger!.pendingBatch(hostname: "h")
        try require(pending.sessions.first?.session.project == expectedProject, "pending session carries project")

        // reopen：project 持久化。
        ledger = nil
        let reopened = try UsageLedgerStore(path: db.path)
        let reopenedSessions = try reopened.sessions(hostname: "h")
        try require(reopenedSessions.first?.project == expectedProject, "session project survives reopen")

        // 3b) v2 旧库迁移到 v3：建一个 user_version=2 的老库（无 project 列），迁移后补列且数据保留。
        let db2 = tempUsageDB(); defer { cleanupDB(db2) }
        var handle: OpaquePointer?
        try require(sqlite3_open(db2.path, &handle) == SQLITE_OK, "open raw v2 db")
        let v2 = """
        CREATE TABLE usage_events(event_id TEXT PRIMARY KEY,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,session_hash TEXT NOT NULL,source_file_hash TEXT NOT NULL,rollout_key TEXT NOT NULL DEFAULT '',parent_rollout_key TEXT NOT NULL DEFAULT '',inherited INTEGER NOT NULL DEFAULT 0,has_total_snapshot INTEGER NOT NULL DEFAULT 0,lineage_fingerprint TEXT NOT NULL DEFAULT '',created_at_ms INTEGER NOT NULL);
        CREATE TABLE usage_buckets(hostname TEXT NOT NULL,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,bucket_start_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 0,synced_revision INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(hostname,source,model,project,bucket_start_ms));
        CREATE TABLE usage_files(file_id TEXT PRIMARY KEY,source TEXT NOT NULL,path_hash TEXT NOT NULL,read_offset INTEGER NOT NULL,file_size INTEGER NOT NULL,mtime_ms INTEGER NOT NULL,parser_version INTEGER NOT NULL,scan_status TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
        CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
        CREATE TABLE usage_session_events(event_id TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,role TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,created_at_ms INTEGER NOT NULL,PRIMARY KEY(source,event_id));
        CREATE TABLE usage_sessions(hostname TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,first_activity_ms INTEGER NOT NULL,last_activity_ms INTEGER NOT NULL,active_seconds INTEGER NOT NULL,message_count INTEGER NOT NULL,user_message_count INTEGER NOT NULL,assistant_events INTEGER NOT NULL,hour_histogram TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,synced_revision INTEGER NOT NULL DEFAULT 0,updated_at_ms INTEGER NOT NULL,PRIMARY KEY(hostname,source,session_hash));
        INSERT INTO usage_events VALUES('e1','codex','m','/w/legacy',1000,0,50,0,0,0,50,'sh','fh','','',0,0,'',1000);
        PRAGMA user_version=2;
        """
        try require(sqlite3_exec(handle, v2, nil, nil, nil) == SQLITE_OK, "seed v2 schema")
        sqlite3_close(handle)

        // 打开触发 v2 -> v3 迁移。老事件保留；finalize 后派生 project 落到 session。
        let migrated = try UsageLedgerStore(path: db2.path)
        let migratedEventCount = try migrated.eventCount()
        try require(migratedEventCount == 1, "v2 event survives migration to v3")
        try migrated.finalizeDerived(hostname: "h")
        let migratedBuckets = try migrated.buckets(hostname: "h")
        try require(migratedBuckets.first?.counts.total == 50, "migrated event rebuilds derived bucket after v3 migration")

        // 幂等：再次打开（已是 v3）不应报错、事件不丢。
        let reopenedV3 = try UsageLedgerStore(path: db2.path)
        let reopenedV3Count = try reopenedV3.eventCount()
        try require(reopenedV3Count == 1, "reopening v3 db is idempotent and lossless")
    }

    // MARK: - cliproxyapi usage parser

    private static func verifyCliProxyUsageParser() throws {
        let targetKey = "sk-target-example"
        let otherKey = "sk-other-example"
        let targetHash = CliProxyUsageParser.apiKeyHash(for: targetKey)
        let otherHash = CliProxyUsageParser.apiKeyHash(for: otherKey)
        try require(targetHash.count == 64, "SHA256 hex must be 64 chars")
        try require(targetHash != otherHash, "distinct keys must hash differently")

        // 构造两条目标 key 明细（不同 model / 时间）、一条他 key 明细（须被过滤）、
        // 一条零用量明细（须跳过）、一条无时间戳明细（须跳过）。
        let payload: [String: Any] = [
            "total_requests": 4,
            "apis": [
                "POST /v1/chat/completions": [
                    "models": [
                        "model-a": [
                            "details": [
                                [
                                    "timestamp": "2026-08-09T16:24:58.500000000Z",
                                    "api_key_hash": targetHash,
                                    "resolved_model": "model-a",
                                    "tokens": [
                                        "input_tokens": 100, "output_tokens": 40,
                                        "reasoning_tokens": 10, "cache_read_tokens": 30,
                                        "cache_creation_tokens": 5, "cached_tokens": 0,
                                        "cache_tokens": 0, "total_tokens": 140,
                                    ],
                                ],
                                [
                                    "timestamp": "2026-08-09T17:00:00Z",
                                    "api_key_hash": otherHash,
                                    "resolved_model": "model-a",
                                    "tokens": ["input_tokens": 999, "output_tokens": 999, "total_tokens": 1998],
                                ],
                                [
                                    // 零用量：跳过。
                                    "timestamp": "2026-08-09T17:10:00Z",
                                    "api_key_hash": targetHash,
                                    "resolved_model": "model-a",
                                    "tokens": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0],
                                ],
                                [
                                    // 无时间戳：跳过。
                                    "api_key_hash": targetHash,
                                    "resolved_model": "model-a",
                                    "tokens": ["input_tokens": 5, "output_tokens": 5, "total_tokens": 10],
                                ],
                            ],
                        ],
                    ],
                ],
                "POST /v1/messages": [
                    "models": [
                        "model-b": [
                            "details": [
                                [
                                    "timestamp": "2026-08-10T09:00:00Z",
                                    "api_key_hash": targetHash,
                                    "resolved_model": "model-b",
                                    "tokens": ["input_tokens": 50, "output_tokens": 20, "total_tokens": 70],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)

        let events = CliProxyUsageParser.parse(data: data, targetAPIKey: targetKey)
        try require(events.count == 2, "must extract exactly the two valid target-key details, got \(events.count)")
        try require(events.allSatisfy { $0.source == CliProxyUsageParser.source }, "source must be cliproxy")
        let identity = CliProxyUsageParser.apiKeyIdentity(for: targetKey)
        try require(events.allSatisfy { $0.project == identity && $0.sessionHash == identity }, "identity must be hashed key, never plaintext")
        try require(!events.contains { $0.model == "model-a" && $0.counts.total == 1998 }, "other key must be filtered out")

        // token 映射：model-a 明细 input=100(含 cache_read 30 + creation 5)、output=40(含 reasoning 10)。
        guard let modelA = events.first(where: { $0.model == "model-a" }) else {
            throw VerificationFailure.assertion("missing model-a event")
        }
        try require(modelA.counts.cachedInput == 30, "cachedInput mapping failed: \(modelA.counts.cachedInput)")
        try require(modelA.counts.cacheCreationInput == 5, "cacheCreation mapping failed: \(modelA.counts.cacheCreationInput)")
        try require(modelA.counts.input == 65, "net input mapping failed: \(modelA.counts.input)")
        try require(modelA.counts.reasoningOutput == 10, "reasoning mapping failed")
        try require(modelA.counts.output == 30, "net output mapping failed: \(modelA.counts.output)")
        try require(modelA.counts.total == 140, "total mapping failed: \(modelA.counts.total)")

        // 幂等：同一份数据再解析，event id 必须完全一致。
        let again = CliProxyUsageParser.parse(data: data, targetAPIKey: targetKey)
        try require(Set(events.map(\.id)) == Set(again.map(\.id)), "event ids must be stable across parses")

        // 空 / 非法输入稳健返回空。
        try require(CliProxyUsageParser.parse(data: Data("not json".utf8), targetAPIKey: targetKey).isEmpty, "invalid json must yield empty")
        try require(CliProxyUsageParser.parse(data: data, targetAPIKey: "").isEmpty, "empty target key must yield empty")

        // 账本闭环：recordNetworkEvents（无 checkpoint）+ finalizeDerived → cliproxy bucket。
        let databaseURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let ledger = try UsageLedgerStore(path: databaseURL.path)
        let hostname = "device"
        try ledger.recordNetworkEvents(events, source: CliProxyUsageParser.source, hostname: hostname)
        // 重复 record 不应重复计数（幂等）。
        try ledger.recordNetworkEvents(again, source: CliProxyUsageParser.source, hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)
        let buckets = try ledger.buckets(hostname: hostname)
        let cliProxyBuckets = buckets.filter { $0.source == CliProxyUsageParser.source }
        try require(!cliProxyBuckets.isEmpty, "cliproxy buckets must be produced")
        let cliProxyTotal = cliProxyBuckets.reduce(Int64(0)) { $0 + $1.counts.total }
        try require(cliProxyTotal == 210, "cliproxy bucket total must equal 140+70=210, got \(cliProxyTotal)")
        let ledgerEventCount = try ledger.eventCount()
        try require(ledgerEventCount == 2, "duplicate recordNetworkEvents must remain idempotent")

        // recordNetworkEvents 不得写入 usage_files checkpoint（网络来源无 parser 版本轴）。
        let needsRebuild = try ledger.requiresParserRebuild(currentParserVersion: UsageJSONLParser.parserVersion)
        try require(!needsRebuild, "cliproxy events must not trigger parser rebuild")
    }
}
