import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage

enum ReportingWarningsVerification {
    private static let hostname = "warning-device"
    private static let timestamp = Date(timeIntervalSince1970: 1_700_001_000)
    private static let baseURL = URL(string: "https://example.invalid")!
    private static let configurationURL = URL(fileURLWithPath: "/unused")

    static func run() async throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        let initialOutput: Int64 = 10
        let winningOutput: Int64 = 20
        let updatedOutput: Int64 = 30
        try recordConflict(ledger, fileID: "file-a", sessionHash: "session-a", output: initialOutput)
        try recordConflict(ledger, fileID: "file-b", sessionHash: "session-b", output: winningOutput)
        try await verifyDerivationBlocksSender(ledger)

        let finalized = try ledger.finalizeDerived(hostname: hostname)
        try require(finalized.reportingEligible && finalized.blockedReasons.isEmpty,
                    "finalized data-quality warnings must not block reporting")
        try require(finalized.warnings.contains { $0.contains("conflicting identity") }
                    && finalized.warnings.contains { $0.contains("inherited replay") },
                    "fixture must retain identity-conflict and inherited-replay warnings")
        let pending = try ledger.pendingCounts(hostname: hostname)
        try require(pending.buckets == 1 && pending.sessions > 0,
                    "warning fixture must retain a real bucket and sessions to upload")

        // Warning-only eligibility must still preserve exact ACK requirements.
        let malformedClient = ScriptedBatchClient(fixedResponse: UsageIngestResponse())
        let rejected = try await report(ledger, client: malformedClient)
        let remaining = try ledger.pendingCounts(hostname: hostname)
        try require(!malformedClient.requests.isEmpty
                    && rejected.bucketsAcknowledged == 0 && rejected.sessionsAcknowledged == 0
                    && rejected.partialFailures.first?.error == .malformedResponse
                    && remaining.buckets == pending.buckets && remaining.sessions == pending.sessions,
                    "warnings must neither block transmission nor bypass exact ACK validation")

        let client = ScriptedBatchClient()
        let accepted = try await report(ledger, client: client)
        try require(accepted.bucketsAcknowledged == pending.buckets
                    && accepted.sessionsAcknowledged == pending.sessions
                    && accepted.bucketsPending == 0 && accepted.sessionsPending == 0
                    && accepted.partialFailures.isEmpty,
                    "warning-only ledger did not send and acknowledge every pending row")
        let sentBuckets = client.requests.flatMap { $0.request.buckets }
        try require(sentBuckets.count == 1 && sentBuckets[0].outputTokens == winningOutput,
                    "warning policy changed the logical-event max aggregation in the wire payload")
        try require(try ledger.pendingBatch(hostname: hostname).isEmpty,
                    "successful warning-only report left acknowledged revisions pending")
        try require(try ledger.reportingWarnings(hostname: hostname).contains { $0.contains("conflicting identity") },
                    "acknowledging usage must not erase a still-present identity warning")

        try recordConflict(ledger, fileID: "file-b", sessionHash: "session-b", output: updatedOutput)
        try await verifyDerivationBlocksSender(ledger)
        let updated = try ledger.finalizeDerived(hostname: hostname)
        try require(updated.reportingEligible && !updated.warnings.isEmpty,
                    "a warning-only revision must become eligible after its derivation completes")
        let updateClient = ScriptedBatchClient()
        let updateReport = try await report(ledger, client: updateClient)
        let updatedBuckets = updateClient.requests.flatMap { $0.request.buckets }
        try require(updatedBuckets.count == 1 && updatedBuckets[0].outputTokens == updatedOutput
                    && updateReport.bucketsAcknowledged == 1
                    && updateReport.bucketsPending == 0 && updateReport.sessionsPending == 0,
                    "warning-only changes must upload the complete updated cumulative value")
        print("Reporting warning policy verification passed (sender gate, cumulative payload, exact ACK)")
    }

    private static func verifyDerivationBlocksSender(_ ledger: UsageLedgerStore) async throws {
        try require(try ledger.requiresDerivationCompletion(), "fixture must have unfinished derivation")
        let client = ScriptedBatchClient()
        do {
            _ = try await report(ledger, client: client)
            throw Failure.failed("unfinished derivation reached reporting")
        } catch TokenUsageReporterError.reportingIneligible {
            try require(client.requests.isEmpty, "unfinished derivation called the sender")
        }
    }

    private static func report(_ ledger: UsageLedgerStore, client: ScriptedBatchClient) async throws -> TokenUsageReport {
        try await AgentPulseUsageVerification.makeReporter(client: client, hostname: hostname).report(
            ledger: ledger, hostname: hostname, baseURL: baseURL, configurationURL: configurationURL
        )
    }

    private static func recordConflict(
        _ ledger: UsageLedgerStore, fileID: String, sessionHash: String, output: Int64
    ) throws {
        let event = UsageEvent(
            id: "conflicting-event", source: "codex", model: "warning-model", project: "warning-project",
            timestamp: timestamp, counts: UsageTokenCounts(output: output), sessionHash: sessionHash,
            sourceFileHash: fileID, inherited: true
        )
        let session = UsageSessionEvent(
            id: "user-\(sessionHash)", source: "codex", sessionHash: sessionHash,
            sourceFileHash: fileID, role: .user, timestamp: timestamp
        )
        let checkpoint = UsageFileCheckpoint(
            fileID: fileID, source: "codex", pathHash: fileID, offset: 1, size: 1,
            modifiedAt: timestamp, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try ledger.record(events: [event], sessionEvents: [session], checkpoint: checkpoint, hostname: hostname)
    }

    private enum Failure: Error { case failed(String) }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure.failed(message) }
    }
}
