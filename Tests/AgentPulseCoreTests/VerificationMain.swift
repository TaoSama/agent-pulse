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
        try verifyTPSBoundaries()
        try verifySQLiteRoundTripAndRetention()
        try verifyUsageLedgerAndParsers()
        try verifyUsageV2()
        try await verifyLegacyRuntimeSnapshotIgnored()
        try verifyParserFixturesAndCollector()
        try await verifyOracleColdStartAndCandidateRules()
        try await verifyClaudeTPSIntegration()
        try await verifyActiveCountingRules()
        try await verifyClaudeDesktopCounting()
        try await verifyRuntimeCollectorAndPersistence()
        try verifySparklineAnalysis()
        print("AgentPulseCoreVerification: PASS")
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
        try require(parsedClaude.events.count == 1, "claude message-id dedup")
        try require(parsedClaude.sessionEvents.count == 1, "claude message-id session event dedup")
        try require(parsedClaude.events[0].counts.output == 25 && parsedClaude.events[0].counts.cacheCreationInput == 40, "claude max usage and cache creation")

        let database = FileManager.default.temporaryDirectory.appending(path: "usage-ledger-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) } }
        let ledger = try UsageLedgerStore(path: database.path)
        try ledger.record(events: parsedCodex.events + parsedClaude.events, checkpoint: parsedClaude.checkpoint, hostname: "test-host")
        try ledger.record(events: parsedCodex.events + parsedClaude.events, checkpoint: parsedClaude.checkpoint, hostname: "test-host")
        try ledger.finalizeDerived(hostname: "test-host")
        let eventCount = try ledger.eventCount()
        let buckets = try ledger.buckets(hostname: "test-host")
        let summary = try ledger.summary()
        try require(eventCount == 2, "ledger idempotent event insert")
        try require(buckets.count == 2, "half-hour bucket dimensions")
        try require(summary?.counts.total == codexCounts.total + parsedClaude.events[0].counts.total, "ledger summary total")
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
        try verifyV2SessionAlgorithm()
        try verifyV2ClaudeGrowth()
        try verifyV2InheritedReplayDedup()
        try verifyV2DirtyAckRaceAndRestart()
        try verifyV2HostnameRebuild()
        try verifyV2Migration()
        try verifyV2ParserRebuildSafety()
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

        let parent = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:00:00Z","type":"session_meta","payload":{"id":"rollout-parent","session_id":"session-parent","cwd":"/workspace/protocol-fixture"}}
            {"timestamp":"2026-02-01T00:00:01Z","type":"turn_context","payload":{"model":"model-context"}}
            \(tokenLine("2026-02-01T00:00:02Z", model: "model-info", lastInput: 6, lastOutput: 4, totalInput: 16, totalOutput: 9, total: 25))
            {"timestamp":"2026-02-01T00:00:03Z","type":"response_item","payload":{"type":"message","role":"assistant"}}
            """.utf8),
            source: "codex",
            fileIdentity: "protocol-parent-a"
        )
        try require(parent.events.count == 1, "protocol parent token count")
        try require(parent.events[0].model == "model-info", "info.model must override turn_context model")
        try require(parent.events[0].project == "protocol-fixture", "session_meta cwd must determine project")
        try require(parent.sessionEvents.map(\.role) == [.syntheticUser, .user, .assistant], "Codex session event roles")

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
            parent.sessionEvents.map(\.id) == relocatedParent.sessionEvents.map(\.id),
            "Codex session event ids must survive path changes, compaction, and line relocation"
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
            missingSessionEventA.sessionEvents[0].id == missingSessionEventB.sessionEvents[0].id,
            "missing session identity must not leak path into session event id"
        )

        let sameRolloutDifferentSession = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:01:00Z","type":"session_meta","payload":{"id":"rollout-parent","session_id":"session-other"}}
            \(tokenLine("2026-02-01T00:01:01Z", lastInput: 1, lastOutput: 1, totalInput: 1, totalOutput: 1, total: 2))
            """.utf8),
            source: "codex", fileIdentity: "protocol-parent-b"
        )
        try require(parent.events[0].rolloutKey == sameRolloutDifferentSession.events[0].rolloutKey, "payload.id must determine rollout identity")
        try require(parent.events[0].sessionHash != sameRolloutDifferentSession.events[0].sessionHash, "payload.session_id must independently determine session identity")

        let sameSessionDifferentRollout = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T00:02:00Z","type":"session_meta","payload":{"id":"rollout-other","session_id":"session-parent"}}
            \(tokenLine("2026-02-01T00:02:01Z", lastInput: 1, lastOutput: 1, totalInput: 1, totalOutput: 1, total: 2))
            """.utf8),
            source: "codex", fileIdentity: "protocol-parent-c"
        )
        try require(parent.events[0].sessionHash == sameSessionDifferentRollout.events[0].sessionHash, "equal session_id must produce equal session identity")
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
        try require(stableA.events.count == 1, "identical snapshots in one rollout must deduplicate")
        try require(stableA.events[0].id == stableB.events[0].id, "Codex event id must ignore path, timestamp, and line index")

        let incompleteTotal = UsageJSONLParser.parse(
            data: Data("""
            {"timestamp":"2026-02-01T06:00:00Z","type":"session_meta","payload":{"id":"rollout-incomplete","session_id":"session-incomplete"}}
            {"timestamp":"2026-02-01T06:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":2,"output_tokens":1,"total_tokens":3},"total_token_usage":{"output_tokens":1,"total_tokens":3}}}}
            """.utf8),
            source: "codex", fileIdentity: "protocol-incomplete"
        )
        try require(!incompleteTotal.events[0].hasTotalSnapshot && incompleteTotal.events[0].lineageFingerprint.isEmpty, "complete total snapshot requires numeric input/output/total fields")

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
    }

    // 3) Claude 同 msg.id 累计增长：账本按 UPSERT 取最大，不能丢更新。
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
        try require(claudeRows == 1, "claude same msg.id must stay one row")
        try require(claudeGrown.first?.counts.total == 120, "claude growth must upsert-max, not drop or double: got \(claudeGrown.first?.counts.total ?? -1)")
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


    // 6) hostname rebuild：canonical hostname 变化时从原始事件重建，清除旧 hostname 派生。
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

        try ledger.rebuildForHostname("new-host")
        let oldHostBuckets = try ledger.buckets(hostname: "old-host")
        let newHostBuckets = try ledger.buckets(hostname: "new-host")
        try require(oldHostBuckets.isEmpty, "old (wrong) hostname derived must be cleared")
        try require(newHostBuckets.count == 1, "derived rebuilt under new hostname from append-only events")
        try require(newHostBuckets.first?.counts.total == 100, "rebuilt totals preserved")
        let stateAfterRebuild = try ledger.hostnameState(current: "new-host")
        try require(stateAfterRebuild == .match, "canonical hostname updated after rebuild")
        // 重建后应为 dirty（synced_revision=0），可重新上报。
        let pendingNew = try ledger.pendingBatch(hostname: "new-host")
        try require(!pendingNew.isEmpty, "rebuilt rows must be pending for re-upload")
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

    // 8) parser rebuild 检测、revision 单调性与无 tombstone 时的全局上报门禁。
    private static func verifyV2ParserRebuildSafety() throws {
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
            let emptyRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: 2)
            try require(!emptyRequiresRebuild, "empty usage ledger must not require parser rebuild")
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "h")
            let currentParserRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: 2)
            try require(!currentParserRequiresRebuild, "healthy current parser ledger must not require rebuild")
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 1), hostname: "h")
            let oldParserRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: 2)
            try require(oldParserRequiresRebuild, "older parser checkpoint must require rebuild")
        }

        // 有历史数据却没有 checkpoint，无法证明 parser 版本，必须 fail-safe rebuild。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            var ledger: UsageLedgerStore? = try UsageLedgerStore(path: db.path)
            try ledger!.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "h")
            ledger = nil

            var handle: OpaquePointer?
            try require(sqlite3_open(db.path, &handle) == SQLITE_OK, "open checkpoint-less history db")
            defer { sqlite3_close(handle) }
            try require(sqlite3_exec(handle, "DELETE FROM usage_files;", nil, nil, nil) == SQLITE_OK, "remove checkpoints for rebuild verification")

            let reopened = try UsageLedgerStore(path: db.path)
            let historyRequiresRebuild = try reopened.requiresParserRebuild(currentParserVersion: 2)
            try require(historyRequiresRebuild, "history without checkpoints must require rebuild")
        }

        // 当前版本 checkpoint 也不能掩盖 v1 distantPast / 任意 epoch 前错误时间。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            let invalid = event(timestamp: Date(timeIntervalSince1970: -62_135_769_600))
            try ledger.record(events: [invalid], checkpoint: checkpoint(version: 2), hostname: "h")
            let timestampRequiresRebuild = try ledger.requiresParserRebuild(currentParserVersion: 2)
            try require(timestampRequiresRebuild, "negative historical timestamp must require rebuild")
        }

        // reset 后 revision 不复用；reset 前的旧 batch 不能 ack 新生成的同自然键行。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 1), hostname: "h")
            try ledger.finalizeDerived(hostname: "h")
            let staleBatch = try ledger.pendingBatch(hostname: "h")
            try require(staleBatch.buckets.first?.revision == 1, "initial rebuild verification revision")

            try ledger.resetForRebuild()
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "h")
            try ledger.finalizeDerived(hostname: "h")
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
            try require(remainsEligible, "unsynced deletion must not persist a reconciliation block")
            try require(correctedBuckets.count == 1 && correctedBuckets[0].project == "new", "unsynced metadata correction must replace the old derived key")
        }

        // finalize 删除已同步自然键：全局、持久 fail-closed，后续 finalize 不得自动解封。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event(project: "old")], checkpoint: checkpoint(version: 2), hostname: "old-host")
            try ledger.finalizeDerived(hostname: "old-host")
            try ledger.acknowledge(ledger.pendingBatch(hostname: "old-host"))
            try ledger.record(events: [event(project: "new")], checkpoint: checkpoint(version: 2), hostname: "old-host")
            let blocked = try ledger.finalizeDerived(hostname: "old-host")
            try require(!blocked.reportingEligible && !blocked.blockedReasons.isEmpty, "synced key deletion in finalize must block reporting")
            let oldHostEligible = try ledger.reportingEligible(hostname: "old-host")
            let otherHostEligible = try ledger.reportingEligible(hostname: "other-host")
            let laterFinalize = try ledger.finalizeDerived(hostname: "old-host")
            try require(!oldHostEligible, "finalize deletion block must cover original hostname")
            try require(!otherHostEligible, "finalize deletion block must be global")
            try require(!laterFinalize.reportingEligible, "later finalize must not clear reconciliation block")
        }

        // reset 删除已同步派生行：全局 block 必须跨 reset 保留，并被后续 finalize 返回。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 1), hostname: "reset-host")
            try ledger.finalizeDerived(hostname: "reset-host")
            try ledger.acknowledge(ledger.pendingBatch(hostname: "reset-host"))
            try ledger.resetForRebuild()
            let resetHostEligible = try ledger.reportingEligible(hostname: "reset-host")
            let otherHostEligible = try ledger.reportingEligible(hostname: "other-host")
            try require(!resetHostEligible, "parser reset block must survive reset")
            try require(!otherHostEligible, "parser reset block must cover every hostname")
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "reset-host")
            let postResetFinalize = try ledger.finalizeDerived(hostname: "reset-host")
            try require(!postResetFinalize.reportingEligible, "post-reset finalize must expose reconciliation block")
        }

        // hostname rebuild 删除已同步派生行：切换 hostname 不能绕过全局 block。
        do {
            let db = tempUsageDB(); defer { cleanupDB(db) }
            let ledger = try UsageLedgerStore(path: db.path)
            try ledger.record(events: [event()], checkpoint: checkpoint(version: 2), hostname: "old-host")
            try ledger.finalizeDerived(hostname: "old-host")
            try ledger.acknowledge(ledger.pendingBatch(hostname: "old-host"))
            try ledger.rebuildForHostname("new-host")
            let oldHostEligible = try ledger.reportingEligible(hostname: "old-host")
            let newHostEligible = try ledger.reportingEligible(hostname: "new-host")
            let thirdHostEligible = try ledger.reportingEligible(hostname: "third-host")
            let postRebuildFinalize = try ledger.finalizeDerived(hostname: "new-host")
            try require(!oldHostEligible, "hostname rebuild block must cover old hostname")
            try require(!newHostEligible, "hostname rebuild block must cover new hostname")
            try require(!thirdHostEligible, "hostname rebuild block must be global")
            try require(!postRebuildFinalize.reportingEligible, "post-hostname-rebuild finalize must remain blocked")
        }
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
        _ = byModel.record(TPSSample(timestamp: base, tokenCount: 180, durationSeconds: 0, source: .cli, model: "gpt-5.6-sol"))
        _ = byModel.record(TPSSample(timestamp: base, tokenCount: 90, durationSeconds: 0, source: .cli, model: "claude-opus"))
        _ = byModel.record(TPSSample(timestamp: base, tokenCount: 45, durationSeconds: 0, source: .cli, model: nil))
        let modelTokens = byModel.tokensInWindowByModel(referenceDate: base)
        try requireApproximatelyEqual(modelTokens["gpt-5.6-sol"], 180, "model TPS grouping lost Codex tokens")
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
        try require(gap.points.allSatisfy { !$0.isGap }, "display pipeline did not interpolate missing TPS points")
        try require(
            (gap.points[2].value ?? -1) > 0 && (gap.points[2].value ?? 11) < 10,
            "internal gap was not smoothly interpolated between neighbors"
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
        try require(active.desktopActive == 1, "recent top-level Desktop started task was not the sole Desktop active")
        try require(active.taskBreakdown.codexDesktop.totalTasks == 4, "Desktop total did not deduplicate current non-automation sessions")
        try require(active.taskBreakdown.codexDesktop.activeTasks == 1, "Desktop active lifecycle/timeout mismatch")
        try require(active.taskBreakdown.codexCLI.totalTasks == 2, "Codex CLI total must equal current independent processes")
        try require(active.taskBreakdown.codexCLI.activeTasks == 1, "Codex CLI active must be rollout-gated")
        try require(active.taskBreakdown.claudeCLI.totalTasks == 4, "Claude stale registry was counted or opened registries were missed")
        try require(active.taskBreakdown.claudeCLI.activeTasks == 1, "Claude busy registry count mismatch")
        try require(active.terminalActive == 2, "Terminal active did not sum Codex and Claude lifecycle activity")
        try require(active.totalTasks == 10 && active.activeTasks == 3, "aggregate total/active breakdown mismatch")
        try require(active.completed.value == 1, "archive or automation completion leaked into current completed count")
        try require(!active.activeCountsArePartial, "healthy active sources were marked partial")

        let exited = try await collector.scan(at: base.addingTimeInterval(1))
        try require(exited.terminalActive == 0, "exited terminal process did not disappear on the next scan")
        try require(exited.taskBreakdown.codexCLI.totalTasks == 0, "closed Codex CLI remained in total")
        try require(exited.taskBreakdown.claudeCLI.totalTasks == 0, "closed Claude CLI remained in total")
        try require(exited.desktopActive == 1, "unchanged recent Desktop task did not survive cache reuse")

        let timedOut = try await collector.scan(
            at: base.addingTimeInterval(CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds + 1)
        )
        try require(timedOut.desktopActive == 0, "stale started Desktop task did not time out after five minutes")

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
        try require(processUnavailable.desktopActive == 1, "process failure erased independently known Desktop active")
        try require(processUnavailable.terminalActive == nil, "failed process scan fabricated a terminal count")
        try require(processUnavailable.taskBreakdown.codexCLI.quality == .unavailable, "process failure fabricated Codex CLI quality")
        try require(processUnavailable.taskBreakdown.claudeCLI.quality == .unavailable, "process failure fabricated Claude CLI quality")
        try require(processUnavailable.activeCountsArePartial, "failed process scan was not marked partial")
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
            threadSettingsEvent(model: "seed-code"),
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
            appended.liveRate.modelTokensInWindow["seed-code"],
            180,
            "thread_settings_applied model was not inherited by token_count delta"
        )
        try require(appended.liveRate.modelTokensInWindow["unknown"] == nil, "known seed-code delta fell into unknown")

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
            threadSettingsEvent(model: "gpt-5.6-sol"),
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
            promotedDelta.liveRate.modelTokensInWindow["gpt-5.6-sol"],
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
        originator: String = "codex_exec"
    ) throws {
        let meta = "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(sessionID)\",\"thread_source\":\"\(threadSource)\",\"originator\":\"\(originator)\",\"cwd\":\"\(cwd)\"}}"
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
}
