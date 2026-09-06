import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

/// Opt-in storage benchmark; never opens the user's ledger or session files.
final class ParserPublicationScaleTests: XCTestCase {
    func testScanWorkerRequestsUtilityQoSForLedgerWork() throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        let finished = expectation(description: "scan worker completes ledger call")
        UsageFileScanner.workerQueue.async {
            let workerQoS = qos_class_self()
            let ledgerQoS = ledger.queue.sync { qos_class_self() }
            print("publication-qos worker=\(workerQoS.rawValue) ledger=\(ledgerQoS.rawValue) utility=\(QOS_CLASS_UTILITY.rawValue)")
            XCTAssertEqual(workerQoS, QOS_CLASS_UTILITY)
            XCTAssertEqual(ledgerQoS, QOS_CLASS_UTILITY)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
    }

    private static let fileCount = 32
    private static let rowsPerFile = 1_024
    private static let cacheBytes: Int64 = 32 * 1_024 * 1_024
    private let hostname = "publication-scale"
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    private func events(file: Int, changed: Bool = false) -> [UsageEvent] {
        (0..<Self.rowsPerFile).map { index in
            let key = "\(file)-\(index)"
            return UsageEvent(
                id: ContentDigest.sha256("event-\(key)"), source: "codex", model: "model",
                project: "project", timestamp: timestamp.addingTimeInterval(Double(index)),
                counts: UsageTokenCounts(input: 10, output: changed && index % 100 == 0 ? 6 : 5),
                sessionHash: ContentDigest.sha256("session-\(file)"), sourceFileHash: "file-\(file)",
                rolloutKey: ContentDigest.sha256("rollout-\(file)"),
                lineageFingerprint: ContentDigest.sha256("lineage-\(key)"),
                codexDedupKey: ContentDigest.sha256("content-\(key)"))
        }
    }

    private func checkpoint(file: Int) -> UsageFileCheckpoint {
        UsageFileCheckpoint(fileID: "file-\(file)", source: "codex", pathHash: "file-\(file)",
            offset: 100, size: 100, modifiedAt: timestamp,
            parserVersion: UsageJSONLParser.parserVersion, status: "complete")
    }

    private func batch(file: Int, events: [UsageEvent], first: Bool, final: Bool) -> UsageIncrementalBatch {
        UsageIncrementalBatch(parsed: ParsedUsageFile(events: events, sessionEvents: [],
            checkpoint: checkpoint(file: file), diagnostics: []),
            stateChanges: UsageParserStateChanges(values: [:], removedKeys: []),
            removedEventIDs: [], removedEditIDs: [], replacesFile: first, isFinalBatch: final)
    }

    private func scalar(_ ledger: UsageLedgerStore, _ sql: String) throws -> Int64 {
        let statement = try ledger.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try ledger.step(statement) == SQLITE_ROW else { throw UsageLedgerError.sqlite("benchmark scalar missing") }
        return sqlite3_column_int64(statement, 0)
    }

    private func cacheCounter(_ ledger: UsageLedgerStore, _ code: Int32, reset: Bool = false) throws -> Int32 {
        var current: Int32 = 0
        var high: Int32 = 0
        guard sqlite3_db_status(ledger.db, code, &current, &high, reset ? 1 : 0) == SQLITE_OK else {
            throw UsageLedgerError.sqlite("benchmark counter failed")
        }
        return current
    }

    private func measure(_ label: String, ledger: UsageLedgerStore, operation: () throws -> Void) throws {
        _ = try cacheCounter(ledger, SQLITE_DBSTATUS_CACHE_MISS, reset: true)
        _ = try cacheCounter(ledger, SQLITE_DBSTATUS_CACHE_WRITE, reset: true)
        let start = ProcessInfo.processInfo.systemUptime
        try operation()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let misses = try cacheCounter(ledger, SQLITE_DBSTATUS_CACHE_MISS)
        let writes = try cacheCounter(ledger, SQLITE_DBSTATUS_CACHE_WRITE)
        print("publication-scale phase=\(label) seconds=\(elapsed) cacheMisses=\(misses) cacheWrites=\(writes)")
    }

    func testPublicationAgainstLedgerLargerThanPageCache() throws {
        guard ProcessInfo.processInfo.environment["LEDGER_PUBLICATION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with LEDGER_PUBLICATION_BENCHMARK=1; synthetic storage only")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("publication-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let ledger = try UsageLedgerStore(path: directory.appendingPathComponent("usage.sqlite3").path)
        try ledger.prepareForUsageScan()
        try measure("seed", ledger: ledger) {
            for file in 0..<Self.fileCount {
                try autoreleasepool {
                    try ledger.record(events: events(file: file), checkpoint: checkpoint(file: file), hostname: hostname)
                }
            }
        }
        let databaseBytes = try scalar(ledger, "PRAGMA page_count;") * scalar(ledger, "PRAGMA page_size;")
        XCTAssertGreaterThan(databaseBytes, Self.cacheBytes, "fixture must exceed the production page-cache budget")
        print("publication-scale databaseBytes=\(databaseBytes) cacheBudget=\(Self.cacheBytes) rows=\(Self.fileCount * Self.rowsPerFile)")
        // A prior successful finalize consumes dirty keys. Keeping all seed keys
        // would hide the cost of re-enqueuing unchanged identities on replacement.
        try ledger.exec("DELETE FROM usage_dirty_keys;")
        try measure("legacy-replace", ledger: ledger) {
            try ledger.record(events: events(file: 0), checkpoint: checkpoint(file: 0), hostname: hostname)
        }
        for (label, file, changed) in [("same", 0, false), ("changed", 1, true), ("fresh", Self.fileCount, false)] {
            try measure("\(label)-stage", ledger: ledger) {
                try ledger.recordIncremental(batch: batch(file: file, events: events(file: file, changed: changed),
                    first: true, final: false), hostname: hostname)
            }
            try ledger.exec("DELETE FROM usage_dirty_keys;")
            try measure("\(label)-EOF", ledger: ledger) {
                try ledger.recordIncremental(batch: batch(file: file, events: [], first: false, final: true), hostname: hostname)
            }
            print("publication-scale phase=\(label) dirtyKeys=\(try scalar(ledger, "SELECT COUNT(*) FROM usage_dirty_keys;"))")
        }
        let totalRows = Int64((Self.fileCount + 1) * Self.rowsPerFile)
        XCTAssertEqual(try scalar(ledger, "SELECT COUNT(*) FROM usage_events;"), totalRows)
        let changedRows = Int64((Self.rowsPerFile - 1) / 100 + 1)
        XCTAssertEqual(try scalar(ledger, "SELECT SUM(output_tokens) FROM usage_events;"), totalRows * 5 + changedRows)
    }

    func testFreshImportDirectRecordVersusTypedStageBenchmark() throws {
        guard ProcessInfo.processInfo.environment["LEDGER_PUBLICATION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with LEDGER_PUBLICATION_BENCHMARK=1; synthetic storage only")
        }
        let baseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-import-scale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: baseDirectory) }

        let freshFileIndex = Self.fileCount
        let freshEvents = events(file: freshFileIndex)
        let freshCheckpoint = checkpoint(file: freshFileIndex)
        let stageBatch = batch(file: freshFileIndex, events: freshEvents, first: true, final: false)
        let eofBatch = batch(file: freshFileIndex, events: [], first: false, final: true)

        func createSeededLedger(name: String) throws -> UsageLedgerStore {
            let targetDir = baseDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
            let path = targetDir.appendingPathComponent("usage.sqlite3").path
            try autoreleasepool {
                let seed = try UsageLedgerStore(path: path)
                try seed.prepareForUsageScan()
                for file in 0..<Self.fileCount {
                    try seed.record(events: events(file: file), checkpoint: checkpoint(file: file), hostname: hostname)
                }
                try seed.exec("DELETE FROM usage_dirty_keys;")
                let bytes = try scalar(seed, "PRAGMA page_count;") * scalar(seed, "PRAGMA page_size;")
                XCTAssertGreaterThan(bytes, Self.cacheBytes)
            }
            // Reopen only after the seed connection closes. This resets SQLite's
            // page cache, not the operating system's filesystem cache.
            return try UsageLedgerStore(path: path)
        }

        // Direct record is a lower-overhead reference, not the old incremental
        // parser: it already has the complete file in memory and needs no staging.
        let directLedger = try createSeededLedger(name: "direct")
        try measure("fresh-direct-record", ledger: directLedger) {
            try directLedger.record(events: freshEvents, checkpoint: freshCheckpoint, hostname: hostname)
        }

        let typedLedger = try createSeededLedger(name: "typed")
        try measure("fresh-typed-complete", ledger: typedLedger) {
            try typedLedger.recordIncremental(batch: stageBatch, hostname: hostname)
            try typedLedger.recordIncremental(batch: eofBatch, hostname: hostname)
        }

        let expectedRows = Int64((Self.fileCount + 1) * Self.rowsPerFile)
        let expectedTokens = expectedRows * 5

        let directRows = try scalar(directLedger, "SELECT COUNT(*) FROM usage_events;")
        let typedRows = try scalar(typedLedger, "SELECT COUNT(*) FROM usage_events;")
        XCTAssertEqual(directRows, expectedRows)
        XCTAssertEqual(typedRows, expectedRows)

        let directTokens = try scalar(directLedger, "SELECT SUM(output_tokens) FROM usage_events;")
        let typedTokens = try scalar(typedLedger, "SELECT SUM(output_tokens) FROM usage_events;")
        XCTAssertEqual(directTokens, expectedTokens)
        XCTAssertEqual(typedTokens, expectedTokens)

        let directStatus = try scalar(directLedger, "SELECT COUNT(*) FROM usage_files WHERE file_id='file-\(freshFileIndex)' AND scan_status='complete';")
        let typedStatus = try scalar(typedLedger, "SELECT COUNT(*) FROM usage_files WHERE file_id='file-\(freshFileIndex)' AND scan_status='complete';")
        XCTAssertEqual(directStatus, 1)
        XCTAssertEqual(typedStatus, 1)
    }

    /// Isolates transaction grouping with identical publication SQL on each side.
    /// This is not a scanner implementation or a production throughput claim.
    func testGroupedPublicationWriteAmplificationBenchmark() throws {
        guard ProcessInfo.processInfo.environment["LEDGER_GROUP_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with LEDGER_GROUP_BENCHMARK=1; synthetic storage only")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("publication-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let importedFiles = 16
        for groupSize in [1, 8] {
            try autoreleasepool {
                let ledger = try UsageLedgerStore(path: directory.appendingPathComponent("group-\(groupSize).sqlite3").path)
                try ledger.prepareForUsageScan()
                for file in 0..<Self.fileCount {
                    try ledger.record(events: events(file: file), checkpoint: checkpoint(file: file), hostname: hostname)
                }
                try ledger.exec("DELETE FROM usage_dirty_keys;")
                for file in Self.fileCount..<(Self.fileCount + importedFiles) {
                    let rows = events(file: file)
                    let sessions = rows.map {
                        UsageSessionEvent(id: $0.id, source: $0.source, sessionHash: $0.sessionHash,
                            sourceFileHash: $0.sourceFileHash, role: .assistant, timestamp: $0.timestamp)
                    }
                    let staged = UsageIncrementalBatch(parsed: ParsedUsageFile(events: rows, sessionEvents: sessions,
                        checkpoint: checkpoint(file: file), diagnostics: []),
                        stateChanges: UsageParserStateChanges(values: [:], removedKeys: []),
                        removedEventIDs: [], removedEditIDs: [], replacesFile: true, isFinalBatch: true)
                    XCTAssertFalse(try ledger.recordIncrementalForScan(batch: staged, hostname: hostname))
                }
                try measure("group-size-\(groupSize)", ledger: ledger) {
                    for start in stride(from: Self.fileCount, to: Self.fileCount + importedFiles, by: groupSize) {
                        let fileIDs = (start..<min(start + groupSize, Self.fileCount + importedFiles)).map { "file-\($0)" }
                        let committed = try ledger.publishReadyParserReplacements(fileIDs: fileIDs, hostname: hostname)
                        XCTAssertEqual(committed.map(\.fileID), fileIDs)
                    }
                }
                XCTAssertEqual(try scalar(ledger, "SELECT COUNT(*) FROM usage_events;"), Int64((Self.fileCount + importedFiles) * Self.rowsPerFile))
                XCTAssertEqual(try scalar(ledger, "SELECT COUNT(*) FROM usage_session_events;"), Int64(importedFiles * Self.rowsPerFile))
                XCTAssertEqual(try scalar(ledger, "SELECT COUNT(*) FROM usage_files;"), Int64(Self.fileCount + importedFiles))
            }
        }
    }
}
