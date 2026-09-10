import Foundation
import AgentPulseCore
import SQLite3

func verifyDerivationWarningsDoNotBlockReporting() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reporting-warnings-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do { try FileManager.default.removeItem(at: directory) }
        catch { preconditionFailure("Reporting warning fixture cleanup failed: \(error)") }
    }
    let hostname = "warning-host"
    let start = Date(timeIntervalSince1970: 1_700_001_000)
    let backgroundCount = 12
    let initialOutput: Int64 = 10
    let updatedOutput: Int64 = 30
    let automaticPath = directory.appendingPathComponent("automatic.sqlite").path
    let automatic = try UsageLedgerStore(path: automaticPath)
    let full = try UsageLedgerStore(path: directory.appendingPathComponent("full.sqlite").path)

    func record(_ ledger: UsageLedgerStore, events: [UsageEvent], file: String) throws {
        let checkpoint = UsageFileCheckpoint(
            fileID: file, source: "codex", pathHash: file, offset: 0, size: 1,
            modifiedAt: start, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try ledger.record(events: events, checkpoint: checkpoint, hostname: hostname)
    }
    func conflict(file: String, session: String, output: Int64) -> UsageEvent {
        UsageEvent(
            id: "conflicting-event", source: "codex", model: "warning-model", project: "warning-project",
            timestamp: start, counts: UsageTokenCounts(output: output), sessionHash: session,
            sourceFileHash: file, inherited: true
        )
    }
    func verifyWarnings(_ result: UsageFinalizeResult) throws {
        try warningRequire(result.reportingEligible && result.blockedReasons.isEmpty,
                           "local deduplication warnings must not block reporting")
        try warningRequire(result.warnings.count == 2,
                           "inherited replay and identity conflict must be separate warnings")
        try warningRequire(result.warnings.contains { $0.contains("inherited replay") }, "missing inherited warning")
        try warningRequire(result.warnings.contains { $0.contains("conflicting identity") }, "missing identity warning")
    }
    func verifyPendingGate(_ ledger: UsageLedgerStore) throws {
        try warningRequire(try !ledger.reportingEligible(hostname: hostname), "incomplete derivation must block reporting")
        do {
            _ = try ledger.pendingBatch(hostname: hostname)
        } catch UsageLedgerError.localDerivationPending {
            return
        }
        throw UsageLedgerError.sqlite("incomplete derivation exposed a pending upload batch")
    }

    let background = (0..<backgroundCount).map { index in
        UsageEvent(
            id: "background-\(index)", source: "codex", model: "background", project: "background",
            timestamp: start, counts: UsageTokenCounts(output: 1), sessionHash: "background",
            sourceFileHash: "background-file"
        )
    }
    for ledger in [automatic, full] {
        try record(ledger, events: background, file: "background-file")
        _ = try ledger.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
        try record(ledger, events: [conflict(file: "file-a", session: "session-a", output: initialOutput)], file: "file-a")
        try record(ledger, events: [conflict(file: "file-b", session: "session-b", output: initialOutput)], file: "file-b")
        try verifyPendingGate(ledger)
    }
    let automaticResult = try automatic.finalizeDerived(hostname: hostname)
    let fullResult = try full.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
    try warningRequire(automatic.lastFinalizeDiagnostics.strategy == "incremental", "fixture must exercise incremental finalize")
    try verifyWarnings(automaticResult)
    try verifyWarnings(fullResult)
    try compare(automatic, full, automaticResult, fullResult, hostname, -2)
    let total = try automatic.buckets(hostname: hostname).reduce(Int64(0)) { $0 + $1.counts.output }
    try warningRequire(total == Int64(backgroundCount) + initialOutput,
                       "warning policy must preserve logical-event max aggregation")

    // Simulate the old conflict-only eligibility flag without scanning or rewriting usage data.
    try warningExecute(automaticPath, """
        INSERT OR REPLACE INTO sync_state(key,value,updated_at_ms)
        VALUES('reporting_eligible' || char(1) || 'warning-host','0',0);
        """)
    let reopened = try UsageLedgerStore(path: automaticPath)
    try warningRequire(try reopened.reportingEligible(hostname: hostname), "legacy conflict flag must not block after reopening")
    let restoredWarnings = try reopened.reportingWarnings(hostname: hostname)
    try warningRequire(restoredWarnings.count == 1 && restoredWarnings[0].contains("conflicting identity"),
                       "reopening must restore persisted identity warning without scanning raw events")
    let staleBatch = try reopened.pendingBatch(hostname: hostname)
    try warningRequire(!staleBatch.isEmpty, "legacy conflict must retain pending upload rows")
    let noChange = try reopened.finalizeDerived(hostname: hostname)
    try warningRequire(reopened.lastFinalizeDiagnostics.strategy == "noChange", "legacy recovery must not require a full rescan")
    try warningRequire(noChange.reportingEligible && noChange.blockedReasons.isEmpty, "no-change path must ignore legacy conflict flag")
    try warningRequire(noChange.warnings.contains { $0.contains("conflicting identity") }, "no-change path must retain persisted identity warning")

    for ledger in [reopened, full] {
        try record(ledger, events: [conflict(file: "file-b", session: "session-b", output: updatedOutput)], file: "file-b")
        try verifyPendingGate(ledger)
    }
    let updatedAutomatic = try reopened.finalizeDerived(hostname: hostname)
    let updatedFull = try full.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
    try verifyWarnings(updatedAutomatic)
    try verifyWarnings(updatedFull)
    try compare(reopened, full, updatedAutomatic, updatedFull, hostname, -3)
    try reopened.acknowledge(staleBatch)
    let pending = try reopened.pendingBatch(hostname: hostname)
    try warningRequire(pending.buckets.count == 1 && pending.buckets[0].bucket.counts.output == updatedOutput,
                       "stale ACK must leave the changed warning bucket pending")

    for ledger in [reopened, full] { try ledger.markFilesMissing(fileIDs: ["file-b"], hostname: hostname) }
    let resolvedAutomatic = try reopened.finalizeDerived(hostname: hostname)
    let resolvedFull = try full.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
    try warningRequire(!resolvedAutomatic.warnings.contains { $0.contains("conflicting identity") }, "resolved identity conflict must clear its warning")
    try compare(reopened, full, resolvedAutomatic, resolvedFull, hostname, -4)

    try warningExecute(automaticPath, "INSERT OR REPLACE INTO sync_state(key,value,updated_at_ms) VALUES('rebuild_pending','1',0);")
    try verifyPendingGate(reopened)
    try warningExecute(automaticPath, "DELETE FROM sync_state WHERE key='rebuild_pending';")
    try warningRequire(try reopened.reportingEligible(hostname: hostname), "completed rebuild must restore reporting")
    print("Reporting warnings: PASS (full/incremental/no-change, legacy recovery, pending guards, exact ACK)")
}

private func warningRequire(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw UsageLedgerError.sqlite(message) }
}

private func warningExecute(_ path: String, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw UsageLedgerError.sqlite("reporting warning fixture open failed") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw UsageLedgerError.sqlite("reporting warning fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
    }
}
