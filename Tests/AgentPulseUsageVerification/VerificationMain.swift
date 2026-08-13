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
        try verifyConfigurationSafety()
        try verifyPayloadMapping()
        try await verifyPartialAckAndRecovery()
        try await verifyMalformedAcknowledgementsRemainPending()
        try await verifyCancellationKeepsBatchPending()
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
}
