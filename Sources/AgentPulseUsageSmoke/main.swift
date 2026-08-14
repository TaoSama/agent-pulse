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

        // Diagnostic mode: parse one real JSONL file with the current parser and
        // print timestamp coverage, without touching any ledger. Confirms the
        // parser resolves real timestamps (no distantPast fallback) before a
        // production rebuild. Prints only counts and derived bucket starts.
        if let parsePath = env["AGENT_PULSE_SMOKE_PARSE_FILE"] {
            parseFileDiagnostic(path: parsePath, source: env["AGENT_PULSE_SMOKE_PARSE_SOURCE"] ?? "codex")
            return
        }

        // Rebuild-verify mode: run a parser rebuild against a *copy* of a ledger,
        // re-scanning the real local JSONL roots with the current parser, then
        // report bucketStart health. Never touches the production ledger; point
        // AGENT_PULSE_SMOKE_REBUILD_LEDGER at a backup copy only. Read-only over
        // the JSONL sources.
        if let rebuildLedger = env["AGENT_PULSE_SMOKE_REBUILD_LEDGER"],
           let hostname = env["AGENT_PULSE_SMOKE_HOSTNAME"] {
            await rebuildVerify(ledgerPath: rebuildLedger, hostname: hostname)
            return
        }

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

    /// Parse a single real JSONL file with the current parser and report
    /// timestamp coverage plus a sample derived 30-minute bucket start. Read-only.
    static func parseFileDiagnostic(path: String, source: String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            FileHandle.standardError.write(Data("[parse] cannot read \(path)\n".utf8))
            return
        }
        let parsed = UsageJSONLParser.parse(data: data, source: source, fileIdentity: "diagnostic", modifiedAt: Date())
        let negative = parsed.events.filter { $0.timestamp.timeIntervalSince1970 < 0 }
        print("[parse] parserVersion=\(UsageJSONLParser.parserVersion) source=\(source)")
        print("[parse] events=\(parsed.events.count) diagnostics=\(parsed.diagnostics.count)")
        print("[parse] negative(distantPast) timestamps=\(negative.count)")
        if let first = parsed.events.min(by: { $0.timestamp < $1.timestamp }) {
            let ms = Int64(first.timestamp.timeIntervalSince1970 * 1000)
            let bucketMs = (ms / UsageLedgerStore.bucketMilliseconds) * UsageLedgerStore.bucketMilliseconds
            print("[parse] earliest event ts=\(first.timestamp) → bucketStart=\(Date(timeIntervalSince1970: Double(bucketMs) / 1000))")
        }
        if let last = parsed.events.max(by: { $0.timestamp < $1.timestamp }) {
            print("[parse] latest event ts=\(last.timestamp)")
        }
        // Aggregate the five components exactly as the ledger would, so a
        // reference re-aggregation of the same file can be diffed field by field.
        var input: Int64 = 0, output: Int64 = 0, cached: Int64 = 0, creation: Int64 = 0, reasoning: Int64 = 0
        for e in parsed.events {
            input += e.counts.input; output += e.counts.output
            cached += e.counts.cachedInput; creation += e.counts.cacheCreationInput
            reasoning += e.counts.reasoningOutput
        }
        print("[parse] AGG input=\(input) output=\(output) cached=\(cached) creation=\(creation) reasoning=\(reasoning)")
        print("[parse] AGG fourSum=\(input + output + cached + reasoning) fiveSum=\(input + output + cached + creation + reasoning)")
    }

    /// The real local scan roots, matched to the app's production configuration.
    private static var scanRoots: [(root: URL, source: String, subagents: Bool)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            (home.appending(path: ".codex/sessions"), "codex", false),
            (home.appending(path: ".codex/archived_sessions"), "codex", false),
            (home.appending(path: ".claude/projects"), "claude-code", true),
        ]
    }

    /// Run a parser rebuild against a ledger *copy*: reset the parser high-water
    /// mark, re-scan the real JSONL roots with the current parser (the same
    /// parse+record calls the app uses), finalize, then report bucketStart
    /// health. Read-only over the JSONL sources; only the copied ledger is
    /// written.
    static func rebuildVerify(ledgerPath: String, hostname: String) async {
        do {
            let ledger = try UsageLedgerStore(path: ledgerPath)
            let version = UsageJSONLParser.parserVersion
            print("[rebuild] ledger=\(ledgerPath)")
            print("[rebuild] requiresParserRebuild(v\(version))=\(try ledger.requiresParserRebuild(currentParserVersion: version))")

            switch try ledger.hostnameState(current: hostname) {
            case .match: print("[rebuild] hostname already \(hostname)")
            case .unset, .mismatch:
                print("[rebuild] aligning hostname → \(hostname)")
                try ledger.rebuildForHostname(hostname)
            }

            try ledger.beginParserRebuild(targetParserVersion: version)
            var scannedFiles = 0
            var presentBySource: [String: [String]] = [:]
            for entry in scanRoots {
                let (present, files) = try rescanRoot(entry.root, source: entry.source,
                                                      subagents: entry.subagents, ledger: ledger, hostname: hostname)
                presentBySource[entry.source, default: []] += present
                scannedFiles += files
            }
            for (source, present) in presentBySource {
                try ledger.markFilesMissing(source: source, presentFileIDs: present)
            }
            let finalize = try ledger.finalizeDerived(hostname: hostname)
            if try ledger.requiresRebuildCompletion() { try ledger.markRebuildCompleted() }
            print("[rebuild] rescanned files=\(scannedFiles) eligible=\(finalize.reportingEligible) blocked=\(finalize.blockedReasons)")

            let pending = try ledger.pendingBatch(hostname: hostname, maxBuckets: nil, maxSessions: nil)
            print("[rebuild] pending buckets=\(pending.buckets.count) sessions=\(pending.sessions.count)")
            let badStart = pending.buckets.filter { $0.bucket.bucketStart.timeIntervalSince1970 < 0 }
            print("[rebuild] buckets with negative(distantPast) bucketStart=\(badStart.count)")
            func fiveSum(_ c: UsageTokenCounts) -> Int64 {
                c.input + c.output + c.cachedInput + c.cacheCreationInput + c.reasoningOutput
            }
            let distinctStarts = Set(pending.buckets.map { $0.bucket.bucketStart })
            print("[rebuild] distinct bucketStart values=\(distinctStarts.count)")
            if let sample = pending.buckets.max(by: { fiveSum($0.bucket.counts) < fiveSum($1.bucket.counts) }) {
                let b = sample.bucket
                print("[rebuild] top bucket: source=\(b.source) model=\(b.model) bucketStart=\(b.bucketStart) fiveSum=\(fiveSum(b.counts))")
            }
        } catch {
            FileHandle.standardError.write(Data("[rebuild] ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Re-scan one root with the current parser, mirroring the app's per-file
    /// parse+record sequence. Returns the present fileIDs and the count of files
    /// actually re-parsed.
    private static func rescanRoot(_ root: URL, source: String, subagents: Bool,
                                   ledger: UsageLedgerStore, hostname: String) throws -> (present: [String], reparsed: Int) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ([], 0)
        }
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return ([], 0) }
        var present: [String] = []
        var reparsed = 0
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let modifiedAt = values.contentModificationDate ?? Date.distantPast
            let fileID = UsageJSONLParser.fileID(for: url.path)
            present.append(fileID)
            let isSubagent = subagents
                && url.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
                && url.deletingLastPathComponent().lastPathComponent == "subagents"
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let parsed = UsageJSONLParser.parse(data: data, source: source, fileIdentity: url.path,
                                                modifiedAt: modifiedAt, isSubagent: isSubagent)
            try ledger.record(events: parsed.events, sessionEvents: parsed.sessionEvents,
                              editEntries: parsed.editEntries, editMetricsSupported: true,
                              checkpoint: parsed.checkpoint, hostname: hostname)
            reparsed += 1
        }
        return (present, reparsed)
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
