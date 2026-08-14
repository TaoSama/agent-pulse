import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage

private enum VerificationError: Error { case failed(String) }

private final class ScriptedBatchClient: UsageBatchReporting, @unchecked Sendable {
    private let lock = NSLock()
    private let failOnCall: Int?
    private let fixedResponse: UsageIngestResponse?
    private let cancelBeforeReturning: Bool
    private var callCount = 0
    private(set) var requests: [UsageBatch] = []

    init(
        failOnCall: Int? = nil,
        fixedResponse: UsageIngestResponse? = nil,
        cancelBeforeReturning: Bool = false
    ) {
        self.failOnCall = failOnCall
        self.fixedResponse = fixedResponse
        self.cancelBeforeReturning = cancelBeforeReturning
    }

    func ingest(batches: [UsageBatch]) async throws -> UsageBatchOutcome {
        lock.withLock { requests.append(contentsOf: batches) }
        guard let batch = batches.first else { return UsageBatchOutcome(acks: [], failures: []) }
        let shouldFail = lock.withLock { () -> Bool in
            callCount += 1
            return callCount == failOnCall
        }
        if shouldFail {
            return UsageBatchOutcome(
                acks: [],
                failures: [UsageBatchFailure(
                    batchIndex: 0,
                    batchID: batch.batchID,
                    revision: batch.revision,
                    bucketCount: batch.request.buckets.count,
                    sessionCount: batch.request.sessions.count,
                    error: .transportFailure
                )]
            )
        }
        let outcome = UsageBatchOutcome(
            acks: [UsageBatchAck(
                batchIndex: 0,
                batchID: batch.batchID,
                revision: batch.revision,
                bucketCount: batch.request.buckets.count,
                sessionCount: batch.request.sessions.count,
                autonomySessionCount: 0,
                response: fixedResponse ?? UsageIngestResponse(
                    bucketsUpserted: batch.request.buckets.count,
                    sessionsUpserted: batch.request.sessions.count,
                    autonomySessionsUpserted: batch.request.autonomySessions.count
                )
            )],
            failures: []
        )
        if cancelBeforeReturning {
            withUnsafeCurrentTask { task in task?.cancel() }
        }
        return outcome
    }
}

@main
enum AgentPulseUsageVerification {
    static func main() async throws {
        do {
            try verifyConfigurationSafety()
            try verifyGeneralizedSourceDispatch()
            try verifyLocalCollectionConfigValidation()
            try verifyPayloadMapping()
            try await verifyPartialAckAndRecovery()
            try await verifyMalformedAcknowledgementsRemainPending()
            try await verifyCancellationKeepsBatchPending()
            try await CoordinatorVerification.run()
        } catch {
            fputs("TEMP DIAG step failed: \(error)\n", stderr)
            for symbol in Thread.callStackSymbols { fputs("  \(symbol)\n", stderr) }
            throw error
        }
        print("AgentPulseUsage verification passed")
    }

    private static func verifyConfigurationSafety() throws {
        let emptyReporter = TokenUsageReporter(configurationLoader: { _ in TokenReportingConfiguration() })
        let unusedURL = URL(fileURLWithPath: "/unused")
        try require(emptyReporter.configurationStatus(for: unusedURL) == .hostnameMissing, "empty configuration must fail closed")
        try require(
            !TokenUsageReporter.isValidBaseURL(URL(string: "file:///tmp/report")!),
            "non-HTTP URL accepted"
        )
        try require(
            !TokenUsageReporter.isValidBaseURL(URL(string: "https://user:secret@example.invalid")!),
            "credential-bearing URL accepted"
        )
        try require(
            TokenUsageReporter.isValidBaseURL(URL(string: "https://example.invalid")!),
            "HTTPS base URL rejected"
        )
        for value in ["http://localhost:8080", "http://127.0.0.1", "http://[::1]"] {
            try require(TokenUsageReporter.isValidBaseURL(URL(string: value)!), "loopback HTTP URL rejected: \(value)")
        }
        for value in [
            "http://example.invalid", "http://0.0.0.0", "http://127.0.0.2",
            "http://localhost.example.invalid", "http://[::2]"
        ] {
            try require(!TokenUsageReporter.isValidBaseURL(URL(string: value)!), "non-loopback HTTP URL accepted: \(value)")
        }
        try require(!TokenUsageReporter.isValidPath("https://example.invalid/usage"), "absolute request path accepted")

        let configuration = readyConfiguration()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configurationURL = directory.appending(path: "reporting.json")
        let data = try JSONEncoder().encode(configuration)
        try data.write(to: configurationURL, options: .atomic)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: configurationURL.path)
        try require(
            TokenUsageReporter().configurationStatus(for: configurationURL) == .invalid,
            "world-readable configuration was accepted"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationURL.path)
        try require(
            TokenUsageReporter().configurationStatus(for: configurationURL) == .ready,
            "owner-only configuration was rejected"
        )
    }

    private static func verifyPayloadMapping() throws {
        let counts = UsageTokenCounts(input: 10, output: 4, cachedInput: 3, cacheCreationInput: 2, reasoningOutput: 1)
        let bucket = UsageBucket(
            hostname: "device", source: "source", model: "model", project: "project",
            bucketStart: Date(timeIntervalSince1970: 1_800), counts: counts
        )
        let payload = UsageBucketPayloadMapper.payloads(from: [bucket])[0]
        try require(
            payload.totalTokens == counts.total
                && payload.hostname == "device"
                && payload.bucketStart == "1970-01-01T00:30:00Z",
            "bucket mapping failed"
        )

        let session = UsageSession(
            hostname: "device", source: "source", sessionHash: "session",
            project: "demo",
            firstActivity: Date(timeIntervalSince1970: 1_800),
            lastActivity: Date(timeIntervalSince1970: 1_860),
            activeSeconds: 45, messageCount: 5, userMessageCount: 2, assistantEvents: 3,
            hourHistogramUTC: [1, 2]
        )
        let sessionPayload = UsageSessionPayloadMapper.payloads(from: [session])[0]
        try require(
            sessionPayload.durationSeconds == 60
                && sessionPayload.activeSeconds == 45
                && sessionPayload.messageCount == 5
                && sessionPayload.project == "demo"
                && sessionPayload.userPromptHours.count == 24,
            "session mapping failed"
        )
    }

    private static func verifyPartialAckAndRecovery() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let ledger = try UsageLedgerStore(path: databaseURL.path)
        let hostname = "device"
        try recordRevision(1, ledger: ledger, hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)
        try recordRevision(2, ledger: ledger, hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)

        let initial = try ledger.pendingBatch(hostname: hostname, maxBuckets: 1, maxSessions: 1)
        let initialRevision = max(initial.buckets.map(\.revision).max() ?? 0, initial.sessions.map(\.revision).max() ?? 0)
        let scripted = ScriptedBatchClient(failOnCall: 2)
        let reporter = makeReporter(client: scripted, hostname: hostname)
        let first = try await reporter.report(
            ledger: ledger,
            hostname: hostname,
            baseURL: URL(string: "https://example.invalid")!,
            configurationURL: URL(fileURLWithPath: "/unused")
        )
        try require(
            first.bucketsAcknowledged == 1
                && first.bucketsAttempted == 2
                && first.bucketsPending == 1
                && first.partialFailures.count == 1,
            "partial acknowledgement accounting failed"
        )
        let afterFailure = try ledger.pendingBatch(hostname: hostname, maxBuckets: 1, maxSessions: 1)
        let afterFailureRevision = max(afterFailure.buckets.map(\.revision).max() ?? 0, afterFailure.sessions.map(\.revision).max() ?? 0)
        try require(afterFailureRevision > initialRevision, "failed revision was acknowledged")
        try require(scripted.requests.allSatisfy { !$0.request.fullSync && !$0.request.fullSyncReset }, "ordinary report triggered full sync")

        let recovered = try await reporter.report(
            ledger: ledger,
            hostname: hostname,
            baseURL: URL(string: "https://example.invalid")!,
            configurationURL: URL(fileURLWithPath: "/unused")
        )
        try require(
            recovered.bucketsAcknowledged == 1
                && recovered.bucketsPending == 0
                && recovered.partialFailures.isEmpty,
            "failed batch did not recover"
        )

        let missingHostname = makeReporter(client: ScriptedBatchClient(), hostname: "")
        do {
            _ = try await missingHostname.report(
                ledger: ledger, hostname: "",
                baseURL: URL(string: "https://example.invalid")!,
                configurationURL: URL(fileURLWithPath: "/unused")
            )
            throw VerificationError.failed("missing hostname was accepted")
        } catch TokenUsageReporterError.canonicalHostnameMissing {}

        do {
            _ = try await reporter.report(
                ledger: ledger, hostname: "changed-device",
                baseURL: URL(string: "https://example.invalid")!,
                configurationURL: URL(fileURLWithPath: "/unused")
            )
            throw VerificationError.failed("hostname mismatch was accepted")
        } catch TokenUsageReporterError.hostnameRebuildRequired {}
    }

    private static func verifyMalformedAcknowledgementsRemainPending() async throws {
        let cases: [(String, UsageIngestResponse)] = [
            ("zero counts", UsageIngestResponse()),
            ("bucket undercount", UsageIngestResponse(bucketsUpserted: 0, sessionsUpserted: 1)),
            ("bucket overcount", UsageIngestResponse(bucketsUpserted: 2, sessionsUpserted: 1)),
            ("session undercount", UsageIngestResponse(bucketsUpserted: 1, sessionsUpserted: 0)),
            ("session overcount", UsageIngestResponse(bucketsUpserted: 1, sessionsUpserted: 2)),
            ("unexpected autonomy count", UsageIngestResponse(
                bucketsUpserted: 1,
                sessionsUpserted: 1,
                autonomySessionsUpserted: 1
            ))
        ]
        for (label, response) in cases {
            try await verifyMalformedAcknowledgementRemainsPending(response, label: label)
        }
    }

    private static func verifyMalformedAcknowledgementRemainsPending(
        _ response: UsageIngestResponse,
        label: String
    ) async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let ledger = try UsageLedgerStore(path: databaseURL.path)
        let hostname = "device"
        try recordRevision(1, ledger: ledger, hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)

        let rejected = try await makeReporter(
            client: ScriptedBatchClient(fixedResponse: response),
            hostname: hostname
        ).report(
            ledger: ledger,
            hostname: hostname,
            baseURL: URL(string: "https://example.invalid")!,
            configurationURL: URL(fileURLWithPath: "/unused")
        )
        try require(
            rejected.bucketsAttempted == 1
                && rejected.sessionsAttempted == 1
                && rejected.bucketsAcknowledged == 0
                && rejected.sessionsAcknowledged == 0
                && rejected.bucketsPending == 1
                && rejected.sessionsPending == 1
                && rejected.partialFailures.count == 1
                && rejected.partialFailures[0].error == .malformedResponse,
            "malformed acknowledgement was accepted: \(label)"
        )

        let recovered = try await makeReporter(
            client: ScriptedBatchClient(),
            hostname: hostname
        ).report(
            ledger: ledger,
            hostname: hostname,
            baseURL: URL(string: "https://example.invalid")!,
            configurationURL: URL(fileURLWithPath: "/unused")
        )
        try require(
            recovered.bucketsAcknowledged == 1
                && recovered.sessionsAcknowledged == 1
                && recovered.bucketsPending == 0
                && recovered.sessionsPending == 0,
            "pending batch did not recover after malformed acknowledgement: \(label)"
        )
    }

    private static func verifyCancellationKeepsBatchPending() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let ledger = try UsageLedgerStore(path: databaseURL.path)
        let hostname = "device"
        try recordRevision(1, ledger: ledger, hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)

        let reporter = makeReporter(
            client: ScriptedBatchClient(cancelBeforeReturning: true),
            hostname: hostname
        )
        let reportTask = Task {
            try await reporter.report(
                ledger: ledger,
                hostname: hostname,
                baseURL: URL(string: "https://example.invalid")!,
                configurationURL: URL(fileURLWithPath: "/unused")
            )
        }
        do {
            _ = try await reportTask.value
            throw VerificationError.failed("cancelled report acknowledged its batch")
        } catch is CancellationError {}

        let remaining = try ledger.pendingCounts(hostname: hostname)
        try require(
            remaining.buckets == 1 && remaining.sessions == 1,
            "cancelled report did not preserve pending rows"
        )
    }

    private static func makeReporter(client: ScriptedBatchClient, hostname: String) -> TokenUsageReporter {
        let configuration = readyConfiguration(hostname: hostname)
        return TokenUsageReporter(
            configurationLoader: { _ in configuration },
            clientFactory: { _, _ in client }
        )
    }

    private static func readyConfiguration(hostname: String = "device") -> TokenReportingConfiguration {
        TokenReportingConfiguration(
            canonicalHostname: hostname,
            path: "/usage",
            headers: .init(authToken: "Auth", contentEncoding: "Encoding", contentType: "Type"),
            tokenCommand: .init(executable: "/usr/bin/false", tokenKeyPath: ["value"]),
            batch: .init(maxBucketsPerBatch: 1, maxSessionsPerBatch: 1, maxConcurrentBatches: 1),
            retry: .init(maxRetries: 0, retryableStatusCodes: [], backoffSeconds: [])
        )
    }

    private static func recordRevision(_ index: Int, ledger: UsageLedgerStore, hostname: String) throws {
        let timestamp = Date(timeIntervalSince1970: Double(index * 1_800))
        let counts = UsageTokenCounts(input: Int64(index), output: 1)
        let event = UsageEvent(
            id: "event-\(index)", source: "source", model: "model", project: "project",
            timestamp: timestamp, counts: counts, sessionHash: "session-\(index)",
            sourceFileHash: "file-\(index)"
        )
        let sessionEvents = [
            UsageSessionEvent(id: "user-\(index)", source: "source", sessionHash: "session-\(index)", role: .user, timestamp: timestamp),
            UsageSessionEvent(id: "assistant-\(index)", source: "source", sessionHash: "session-\(index)", role: .assistant, timestamp: timestamp.addingTimeInterval(1))
        ]
        let checkpoint = UsageFileCheckpoint(
            fileID: "file-\(index)", source: "source", pathHash: "path-\(index)",
            offset: 1, size: 1, modifiedAt: timestamp, parserVersion: 1, status: "complete"
        )
        try ledger.record(events: [event], sessionEvents: sessionEvents, checkpoint: checkpoint, hostname: hostname)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw VerificationError.failed(message) }
    }

    /// 泛化来源分派：任意非 codex 来源都走 Claude-compatible 解析并携带 cumulativeMax 合并策略；
    /// 自定义非 Anthropic 模型不做 thinking 拆分；codex 保持 rollout 语义 + overwrite。
    private static func verifyGeneralizedSourceDispatch() throws {
        // 自定义 transcript：Claude 结构，model=custom-code-model（非 anthropic）。
        let seedTranscript = """
        {"type":"user","timestamp":"2026-03-01T00:00:00Z","sessionId":"seed-sess","message":{"content":[{"type":"text","text":"hi"}]}}
        {"type":"assistant","timestamp":"2026-03-01T00:00:01Z","sessionId":"seed-sess","cwd":"/w/p","message":{"id":"seed-msg","model":"custom-code-model","content":[{"type":"thinking","thinking":"abcdef"},{"type":"text","text":"hi"}],"usage":{"output_tokens":100,"input_tokens":5,"total_tokens":105}}}
        """
        let seed = UsageJSONLParser.parse(data: Data(seedTranscript.utf8), source: "seed", fileIdentity: "seed.jsonl")
        try require(!seed.sessionEvents.isEmpty, "non-codex source must emit session events (Claude-compatible path)")
        try require(seed.events.count == 1, "seed transcript token usage counted")
        try require(seed.events[0].mergeStrategy == .cumulativeMax, "non-codex event must carry cumulativeMax merge strategy")
        try require(seed.events[0].counts.reasoningOutput == 0 && seed.events[0].counts.output == 100, "seed (non-anthropic) model must NOT split thinking into reasoning")

        // 同结构但 anthropic 模型：仍走同一路径，但应用 thinking 拆分。验证 model 门控是唯一差异。
        let claudeLike = seedTranscript.replacingOccurrences(of: "custom-code-model", with: "claude-opus")
        let anth = UsageJSONLParser.parse(data: Data(claudeLike.utf8), source: "my-local", fileIdentity: "a.jsonl")
        try require(anth.events[0].mergeStrategy == .cumulativeMax, "arbitrary non-codex source still cumulativeMax")
        try require(anth.events[0].counts.reasoningOutput == 75, "anthropic-family model on non-codex source applies thinking split")

        // codex 仍走 rollout 语义 + overwrite。
        let codexRollout = """
        {"type":"session_meta","timestamp":"2026-03-01T00:00:00Z","payload":{"id":"roll-1","cwd":"/w/p"}}
        {"type":"turn_context","timestamp":"2026-03-01T00:00:01Z","payload":{"model":"codex-test-model"}}
        {"type":"event_msg","timestamp":"2026-03-01T00:00:02Z","payload":{"type":"token_count","info":{"model":"codex-test-model","last_token_usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30},"total_token_usage":{"input_tokens":10,"output_tokens":20,"total_tokens":30}}}}
        """
        let codex = UsageJSONLParser.parse(data: Data(codexRollout.utf8), source: "codex", fileIdentity: "c.jsonl")
        try require(codex.events.count == 1, "codex rollout produces a token event")
        try require(codex.events[0].mergeStrategy == .overwrite, "codex event must carry overwrite merge strategy")
        try require(codex.events[0].model == "codex-test-model", "codex model resolved from turn_context")
    }

    /// 本地采集来源配置：format 白名单、内建来源保护、source 归一化、绝对路径要求、
    /// 重复/别名 root 去重、0600 权限、非法 JSON。
    private static func verifyLocalCollectionConfigValidation() throws {
        func raw(_ s: String?, _ r: String?, _ f: String? = "claude", _ sub: Bool? = nil) -> LocalCollectionConfigurationLoader.RawLocalSource {
            LocalCollectionConfigurationLoader.RawLocalSource(source: s, root: r, format: f, includeSubagents: sub)
        }

        // 内建来源不可被覆盖。
        try require(LocalCollectionConfigurationLoader.sanitize([raw("codex", "/a")]).isEmpty, "reserved source 'codex' must be rejected")
        try require(LocalCollectionConfigurationLoader.sanitize([raw("Claude-Code", "/a")]).isEmpty, "reserved source 'claude-code' must be rejected (case-insensitive)")

        // format 非 claude 跳过。
        try require(LocalCollectionConfigurationLoader.sanitize([raw("x", "/a", "jsonl")]).isEmpty, "non-claude format must be skipped")

        // 非绝对路径跳过。
        try require(LocalCollectionConfigurationLoader.sanitize([raw("x", "relative/dir")]).isEmpty, "non-absolute root must be skipped")

        // source 归一化：大写/非法字符被清洗、长度受限、去重。
        let normalized = LocalCollectionConfigurationLoader.sanitize([raw(" My Src! ", "/roots/a")])
        try require(normalized.count == 1, "valid entry accepted")
        try require(normalized[0].source == "mysrc", "source normalized to lowercase [a-z0-9._-]: got \(normalized[0].source)")
        try require(normalized[0].includeSubagents == true, "includeSubagents defaults to true")

        // 同一 source 去重（保留首个）。
        try require(LocalCollectionConfigurationLoader.sanitize([raw("dup", "/roots/a"), raw("dup", "/roots/b")]).count == 1, "duplicate source collapsed")

        // 别名/嵌套 root 去重：/roots/a 与其子孙 /roots/a/child 只接受首个。
        let overlap = LocalCollectionConfigurationLoader.sanitize([raw("s1", "/roots/a"), raw("s2", "/roots/a/child")])
        try require(overlap.count == 1, "overlapping (ancestor/descendant) roots must not both scan")

        // includeSubagents=false 被尊重。
        let noSub = LocalCollectionConfigurationLoader.sanitize([raw("s3", "/roots/x", "claude", false)])
        try require(noSub.first?.includeSubagents == false, "includeSubagents=false respected")

        // 空数据 -> empty；非法 JSON -> malformed。
        try require(try LocalCollectionConfigurationLoader.decode(Data()).sources.isEmpty, "empty data decodes to empty config")
        var threwMalformed = false
        do { _ = try LocalCollectionConfigurationLoader.decode(Data("{not json".utf8)) } catch { threwMalformed = true }
        try require(threwMalformed, "malformed JSON must throw")
    }
}
