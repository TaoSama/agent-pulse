import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage
import Foundation

// Redacted end-to-end usage-reporting smoke. Drives the *production* reporting
// pipeline — real config load, real bytedcli token command, real
// UsageIngestClient over HTTP — against an isolated ledger copy and an operator-
// supplied ingest base URL (point it at a local capture server, never at the
// production backend from here). Prints only aggregate counts and the server's
// acknowledgement; never session ids, project paths, tokens, or bodies.
//
// Required environment:
//   AGENT_PULSE_SMOKE_LEDGER    absolute path to a *copy* of usage.sqlite3
//   AGENT_PULSE_SMOKE_CONFIG    absolute path to a 0600 reporting.json
//   AGENT_PULSE_SMOKE_BASE_URL  ingest base URL (e.g. http://127.0.0.1:8899)
//   AGENT_PULSE_SMOKE_HOSTNAME  canonical hostname to align the ledger to
//
// With any variable missing the smoke prints usage and exits 0, so the target
// builds and stays inert in CI.

@main
struct UsageReportingSmoke {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard let ledgerPath = env["AGENT_PULSE_SMOKE_LEDGER"],
              let configPath = env["AGENT_PULSE_SMOKE_CONFIG"],
              let baseURLString = env["AGENT_PULSE_SMOKE_BASE_URL"],
              let hostname = env["AGENT_PULSE_SMOKE_HOSTNAME"],
              let baseURL = URL(string: baseURLString)
        else {
            FileHandle.standardError.write(Data("""
            usage-reporting-smoke: set AGENT_PULSE_SMOKE_LEDGER, AGENT_PULSE_SMOKE_CONFIG,
            AGENT_PULSE_SMOKE_BASE_URL, AGENT_PULSE_SMOKE_HOSTNAME to run. Inert without them.

            """.utf8))
            return
        }

        do {
            let ledger = try UsageLedgerStore(path: ledgerPath)

            // Optional seed mode: populate a *fresh* ledger with synthetic
            // revision-tracked events so the pipeline can exercise a real POST
            // without tripping the legacy-row reconciliation gate. Used only for
            // the end-to-end transport check against a local capture server.
            if env["AGENT_PULSE_SMOKE_SEED"] == "1" {
                try seedSyntheticEvents(into: ledger, hostname: hostname)
                print("[smoke] seeded synthetic revision-tracked events")
            }

            // 1) Align the ledger identity to the canonical hostname (the same
            //    operation the app performs on a mismatch), then recompute the
            //    derived buckets/sessions from raw events under that identity.
            switch try ledger.hostnameState(current: hostname) {
            case .match:
                print("[smoke] ledger hostname already aligned: \(hostname)")
            case .unset:
                print("[smoke] ledger hostname unset → aligning to \(hostname)")
                try ledger.rebuildForHostname(hostname)
            case let .mismatch(stored):
                print("[smoke] ledger hostname '\(stored)' ≠ '\(hostname)' → rebuilding")
                try ledger.rebuildForHostname(hostname)
            }
            let finalize = try ledger.finalizeDerived(hostname: hostname)
            print("[smoke] finalize eligible=\(finalize.reportingEligible) blocked=\(finalize.blockedReasons)")

            let pending = try ledger.pendingBatch(hostname: hostname, maxBuckets: nil, maxSessions: nil)
            print("[smoke] pending buckets=\(pending.buckets.count) sessions=\(pending.sessions.count)")

            // 2) Run the real reporter (real token command, real HTTP client).
            let reporter = TokenUsageReporter()
            let report = try await reporter.report(
                ledger: ledger,
                hostname: hostname,
                baseURL: baseURL,
                configurationURL: URL(fileURLWithPath: configPath)
            )
            print("[smoke] REPORT attempted buckets=\(report.bucketsAttempted) sessions=\(report.sessionsAttempted)")
            print("[smoke] REPORT acknowledged buckets=\(report.bucketsAcknowledged) sessions=\(report.sessionsAcknowledged)")
            if report.partialFailures.isEmpty {
                print("[smoke] no partial failures — all attempted batches acknowledged exactly")
            } else {
                print("[smoke] partial failures: \(report.partialFailures.count)")
                for f in report.partialFailures.prefix(3) {
                    print("[smoke]   buckets=\(f.bucketCount) sessions=\(f.sessionCount) error=\(f.error)")
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[smoke] ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Record a few synthetic token events (revision-tracked, non-legacy) into a
    /// fresh ledger. Deterministic timestamps keep buckets stable across runs.
    /// Set AGENT_PULSE_SMOKE_SEED_EVENTS to raise the count and grow the payload
    /// past the gzip threshold, exercising the compressed transport branch.
    static func seedSyntheticEvents(into ledger: UsageLedgerStore, hostname: String) throws {
        // Each event's sourceFileHash must equal the checkpoint fileID, or the
        // ledger rejects the batch as an invalid attribution.
        let sourceFileID = "smoke-file"
        let count = ProcessInfo.processInfo.environment["AGENT_PULSE_SMOKE_SEED_EVENTS"]
            .flatMap(Int.init) ?? 3
        let base = Date(timeIntervalSince1970: 1_786_680_000) // fixed instant
        var events: [UsageEvent] = []
        for i in 0..<count {
            let n = Int64(i + 1)
            let counts = UsageTokenCounts(
                input: 1000 * n, output: 200 * n, cachedInput: 500 * n,
                cacheCreationInput: 300 * n, reasoningOutput: 50 * n
            )
            // Distinct model per event yields a distinct bucket, so a higher
            // count grows the request body rather than merging into one bucket.
            let event = UsageEvent(
                id: "smoke-event-\(i)",
                source: i % 2 == 0 ? "codex" : "claude-cli",
                model: "smoke-model-\(i)",
                project: "agent-pulse-smoke",
                timestamp: base.addingTimeInterval(Double(i) * 60),
                counts: counts,
                sessionHash: "smokehash\(i)ABCDEF",
                sourceFileHash: sourceFileID
            )
            events.append(event)
        }
        let checkpoint = UsageFileCheckpoint(
            fileID: sourceFileID, source: "codex", pathHash: "smokepath",
            offset: 0, size: 1, modifiedAt: base, parserVersion: 2, status: "complete"
        )
        try ledger.record(events: events, checkpoint: checkpoint, hostname: hostname)
    }
}
