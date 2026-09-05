import Foundation
import AgentPulseCore
import SQLite3

func verifyClosureIterationFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("closure-guard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let automatic = try UsageLedgerStore(path: directory.appendingPathComponent("automatic.sqlite").path)
    let full = try UsageLedgerStore(path: directory.appendingPathComponent("full.sqlite").path)
    let hostname = "closure-host"
    let source = "codex"
    let chainCount = 40
    let backgroundCount = 200
    let start = Date(timeIntervalSince1970: 1_700_001_000)

    func event(_ index: Int, output: Int64 = 1) -> UsageEvent {
        UsageEvent(id: "chain-\(index)", source: source, model: "model", project: "project",
                   timestamp: start.addingTimeInterval(Double(index / 2) * 1800),
                   counts: UsageTokenCounts(output: output), sessionHash: "session-\((index + 1) / 2)",
                   sourceFileHash: "file-\(index)")
    }
    func record(_ ledger: UsageLedgerStore, events: [UsageEvent], fileID: String) throws {
        let checkpoint = UsageFileCheckpoint(fileID: fileID, source: source, pathHash: fileID,
            offset: 0, size: 1, modifiedAt: start, parserVersion: UsageJSONLParser.parserVersion, status: "complete")
        try ledger.record(events: events, sessionEvents: [], checkpoint: checkpoint, hostname: hostname)
    }

    // Bucket links (0,1), (2,3), ... alternate with session links (1,2), (3,4), ... .
    // The full connected component is below the fraction threshold but needs over 16 rounds.
    let background = (0..<backgroundCount).map { index in
        UsageEvent(id: "background-\(index)", source: source, model: "model", project: "background",
                   timestamp: start.addingTimeInterval(1_000_000), counts: UsageTokenCounts(output: 1),
                   sessionHash: "", sourceFileHash: "background")
    }
    for ledger in [automatic, full] {
        try record(ledger, events: background, fileID: "background")
        for index in 0..<chainCount { try record(ledger, events: [event(index)], fileID: "file-\(index)") }
        _ = try ledger.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
        try record(ledger, events: [event(0, output: 7)], fileID: "file-0")
    }
    let a = try automatic.finalizeDerived(hostname: hostname)
    let b = try full.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
    guard automatic.lastFinalizeDiagnostics.strategy == "full" else {
        throw NSError(domain: "ClosureGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: "nonconverged closure must fall back to full recompute"])
    }
    try compare(automatic, full, a, b, hostname, -1)
    print("Closure iteration guard: PASS (40-node component, full fallback and exact parity)")
}

func verifySQLiteReadFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-read-error-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("usage.sqlite").path
    let ledger = try UsageLedgerStore(path: path)
    let event = UsageEvent(id: "event", source: "network", model: "model", project: "project",
                           timestamp: Date(timeIntervalSince1970: 1_700_000_000), counts: UsageTokenCounts(output: 1),
                           sessionHash: "", sourceFileHash: "")
    try ledger.recordNetworkEvents([event], source: "network", hostname: "host")
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw UsageLedgerError.sqlite("fixture database open failed") }
    defer { sqlite3_close(db) }
    // This view prepares successfully and fails only when stepping a stored row.
    let sql = "ALTER TABLE usage_buckets RENAME TO saved_buckets; CREATE VIEW usage_buckets AS SELECT * FROM saved_buckets WHERE abs(-9223372036854775808)=0;"
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw UsageLedgerError.sqlite("fixture view creation failed") }
    do {
        _ = try ledger.buckets(hostname: "host")
    } catch UsageLedgerError.sqlite {
        print("SQLite read failure: PASS (step error propagated)")
        return
    }
    throw NSError(domain: "SQLiteReadFailure", code: 1, userInfo: [NSLocalizedDescriptionKey: "step failure returned an empty result"])
}

func verifyNetworkBucketRelocation() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("network-relocation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try UsageLedgerStore(path: directory.appendingPathComponent("usage.sqlite").path)
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    func event(_ id: String, model: String, output: Int64) -> UsageEvent {
        UsageEvent(id: id, source: "network", model: model, project: "project",
                   timestamp: start, counts: UsageTokenCounts(output: output), sessionHash: "", sourceFileHash: "")
    }
    try ledger.recordNetworkEvents([event("a", model: "old", output: 1), event("b", model: "old", output: 3)], source: "network", hostname: "host")
    try ledger.recordNetworkEvents([event("a", model: "new", output: 2)], source: "network", hostname: "host")
    let partial = try ledger.buckets(hostname: "host")
    guard partial.count == 2, partial.first(where: { $0.model == "old" })?.counts.output == 3,
          partial.first(where: { $0.model == "new" })?.counts.output == 2 else {
        throw UsageLedgerError.sqlite("network correction did not remove the old contribution")
    }
    try ledger.recordNetworkEvents([event("b", model: "new", output: 3)], source: "network", hostname: "host")
    let final = try ledger.buckets(hostname: "host")
    guard final.count == 1, final[0].model == "new", final[0].counts.output == 5 else {
        throw UsageLedgerError.sqlite("empty old network bucket was retained")
    }
    print("Network bucket relocation: PASS (old contribution removed, empty old bucket deleted)")
}

func verifySummarySnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("summary-snapshot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ledger = try UsageLedgerStore(path: directory.appendingPathComponent("usage.sqlite").path)
    let start = Date(timeIntervalSince1970: 1_700_001_000)
    let now = start.addingTimeInterval(60)
    let range = DateInterval(start: start.addingTimeInterval(-1800), end: now)
    let event = UsageEvent(id: "first", source: "network", model: "model", project: "project",
                           timestamp: start, counts: UsageTokenCounts(output: 5), sessionHash: "", sourceFileHash: "")
    try ledger.recordNetworkEvents([event], source: "network", hostname: "host")
    let first = try ledger.summarySnapshot(containing: now, hostname: "host", outputRange: range)
    guard first.windows.count == 4, first.outputBuckets.map(\.outputTokens).reduce(0, +) == 5 else {
        throw UsageLedgerError.sqlite("summary snapshot omitted windows or series")
    }
    for item in first.windows {
        guard item.summary == (try ledger.summary(window: item.window, containing: now, hostname: "host")),
              item.models == (try ledger.modelSummary(window: item.window, containing: now, hostname: "host")) else {
            throw UsageLedgerError.sqlite("snapshot differs from public aggregate semantics")
        }
    }
    let second = try ledger.summarySnapshot(containing: now, hostname: "host", outputRange: range)
    guard second.revision > first.revision, second.windows.last?.summary == first.windows.last?.summary else {
        throw UsageLedgerError.sqlite("snapshot sequence did not advance independently of data changes")
    }

    var db: OpaquePointer?
    guard sqlite3_open(directory.appendingPathComponent("usage.sqlite").path, &db) == SQLITE_OK else {
        throw UsageLedgerError.sqlite("summary fixture database open failed")
    }
    defer { sqlite3_close(db) }
    // A summary-only column fails at sqlite3_step, while both series projections remain valid.
    // Executing a window query instead of skipping it therefore makes the series-only call fail.
    let sql = """
        ALTER TABLE usage_buckets RENAME TO saved_buckets;
        CREATE VIEW usage_buckets AS
        SELECT hostname, source, model, project, bucket_start_ms,
               abs(-9223372036854775808) AS input_tokens, output_tokens,
               cached_input_tokens, cache_creation_input_tokens, reasoning_output_tokens,
               total_tokens, updated_at_ms
        FROM saved_buckets;
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw UsageLedgerError.sqlite("summary fixture view creation failed")
    }
    let seriesOnly = try ledger.summarySnapshot(containing: now, hostname: "host", includeWindowSummaries: false, outputRange: range)
    guard seriesOnly.windows.isEmpty, seriesOnly.revision == second.revision + 1,
          seriesOnly.outputBuckets.elementsEqual(first.outputBuckets, by: {
              $0.bucketStart == $1.bucketStart && $0.outputTokens == $1.outputTokens
          }),
          seriesOnly.outputBucketsByModel.elementsEqual(first.outputBucketsByModel, by: {
              $0.bucketStart == $1.bucketStart && $0.model == $1.model && $0.outputTokens == $1.outputTokens
          }) else {
        throw UsageLedgerError.sqlite("series-only snapshot changed series, retained windows, or used a separate revision sequence")
    }
    var rejectedWindowRead = false
    do {
        _ = try ledger.summarySnapshot(containing: now, hostname: "host", outputRange: range)
    } catch UsageLedgerError.sqlite(let message) {
        guard message.contains("integer overflow") else { throw UsageLedgerError.sqlite(message) }
        rejectedWindowRead = true
    }
    guard rejectedWindowRead else { throw UsageLedgerError.sqlite("fixture did not reject a window query") }
    let afterFailure = try ledger.summarySnapshot(containing: now, hostname: "host", includeWindowSummaries: false, outputRange: range)
    guard afterFailure.revision == seriesOnly.revision + 1 else {
        throw UsageLedgerError.sqlite("failed snapshot advanced the completed-read revision")
    }
    print("Summary snapshot: PASS (window parity, series-only isolation, shared revision, failed-read rollback)")
}
