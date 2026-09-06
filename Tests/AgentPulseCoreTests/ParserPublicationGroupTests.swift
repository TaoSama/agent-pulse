import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class ParserPublicationGroupTests: XCTestCase {
    private let hostname = "group-host"
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeStore(at path: String? = nil) throws -> (UsageLedgerStore, URL?) {
        if let path {
            return (try UsageLedgerStore(path: path), nil)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("group-test.sqlite")
        return (try UsageLedgerStore(path: fileURL.path), fileURL)
    }

    private func event(_ id: String, fileID: String, output: Int64 = 1, source: String = "codex") -> UsageEvent {
        UsageEvent(id: id, source: source, model: "model", project: "project", timestamp: time,
                   counts: UsageTokenCounts(output: output), sessionHash: "session-\(fileID)", sourceFileHash: fileID,
                   mergeStrategy: .overwrite, skillCounts: [:])
    }

    private func session(_ id: String, fileID: String) -> UsageSessionEvent {
        UsageSessionEvent(id: id, source: "codex", sessionHash: "session-\(fileID)", sourceFileHash: fileID,
                          role: .user, timestamp: time)
    }

    private func edit(_ id: String, fileID: String) -> UsageEditEntry {
        UsageEditEntry(source: "codex", model: "model", project: "project", sourceFileHash: fileID,
                       timestamp: time, added: 2, deleted: 1, toolUseID: id)
    }

    private func batch(fileID: String, events: [UsageEvent] = [], sessions: [UsageSessionEvent] = [],
                       edits: [UsageEditEntry] = [], replace: Bool = true, final: Bool = true,
                       offset: Int64 = 100, state: UInt8 = 1) -> UsageIncrementalBatch {
        let checkpoint = UsageFileCheckpoint(
            fileID: fileID, source: "codex", pathHash: fileID, offset: offset,
            size: offset, modifiedAt: time, parserVersion: UsageJSONLParser.parserVersion,
            status: final ? "complete" : "reading"
        )
        return UsageIncrementalBatch(
            parsed: ParsedUsageFile(events: events, sessionEvents: sessions, checkpoint: checkpoint,
                                   diagnostics: [], editEntries: edits),
            stateChanges: UsageParserStateChanges(values: ["state": Data([state])], removedKeys: []),
            removedEventIDs: [], removedEditIDs: [], replacesFile: replace, isFinalBatch: final
        )
    }

    private func scalar(_ store: UsageLedgerStore, _ sql: String) throws -> Int64 {
        let statement = try store.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try store.step(statement) == SQLITE_ROW else { throw UsageLedgerError.sqlite("fixture scalar missing") }
        return sqlite3_column_int64(statement, 0)
    }

    func testDeferredReplacementDoesNotExposeRawStateOrDurableCheckpoint() throws {
        let (store, _) = try makeStore()
        let file = "file-deferred"
        let b = batch(fileID: file, events: [event("e1", fileID: file)],
                      sessions: [session("s1", fileID: file)],
                      edits: [edit("ed1", fileID: file)], replace: true, final: true)
        let committed = try store.recordIncrementalForScan(batch: b, hostname: hostname)
        XCTAssertFalse(committed)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(file)';"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events WHERE source_file_hash='\(file)';"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries WHERE source_file_hash='\(file)';"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_parser_state WHERE file_id='\(file)';"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_files WHERE file_id='\(file)';"), 0)
        XCTAssertNil(try store.checkpoints(source: "codex")[file])
    }

    func testPublishReadyReplacementsPublishesAllFilesDurably() throws {
        let (store, _) = try makeStore()
        let fileA = "file-a", fileB = "file-b"
        let bA = batch(fileID: fileA, events: [event("ea1", fileID: fileA)],
                       sessions: [session("sa1", fileID: fileA)],
                       edits: [edit("eda1", fileID: fileA)], replace: true, final: true, state: 10)
        let bB = batch(fileID: fileB, events: [event("eb1", fileID: fileB)],
                       sessions: [session("sb1", fileID: fileB)],
                       edits: [edit("edb1", fileID: fileB)], replace: true, final: true, state: 20)
        XCTAssertFalse(try store.recordIncrementalForScan(batch: bA, hostname: hostname))
        XCTAssertFalse(try store.recordIncrementalForScan(batch: bB, hostname: hostname))

        let committed = try store.publishReadyParserReplacements(fileIDs: [fileA, fileB], hostname: hostname)
        XCTAssertEqual(committed.count, 2)
        let checkpoints = try store.checkpoints(source: "codex")
        XCTAssertNotNil(checkpoints[fileA])
        XCTAssertNotNil(checkpoints[fileB])

        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(fileA)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(fileB)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events WHERE source_file_hash='\(fileA)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events WHERE source_file_hash='\(fileB)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries WHERE source_file_hash='\(fileA)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries WHERE source_file_hash='\(fileB)';"), 1)
        XCTAssertEqual(try store.parserState(fileID: fileA, key: "state"), Data([10]))
        XCTAssertEqual(try store.parserState(fileID: fileB, key: "state"), Data([20]))
    }

    func testPublishReadyReplacementsRollsBackOnMissingFileOrHostMismatch() throws {
        let (store, _) = try makeStore()
        let fileA = "file-rollback-a"
        let bA = batch(fileID: fileA, events: [event("e1", fileID: fileA)], replace: true, final: true)
        XCTAssertFalse(try store.recordIncrementalForScan(batch: bA, hostname: hostname))

        XCTAssertThrowsError(try store.publishReadyParserReplacements(fileIDs: [fileA, "missing-file"], hostname: hostname))
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events;"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_files;"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys;"), 0)

        XCTAssertThrowsError(try store.publishReadyParserReplacements(fileIDs: [fileA], hostname: "wrong-host"))
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events;"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_files;"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys;"), 0)
    }

    func testFileIsolationAllowsSelectiveAbortAndPublication() throws {
        let (store, _) = try makeStore()
        let fileA = "file-iso-a", fileB = "file-iso-b"
        let bA = batch(fileID: fileA, events: [event("ea1", fileID: fileA)], replace: true, final: true)
        let bB = batch(fileID: fileB, events: [event("eb1", fileID: fileB)], replace: true, final: true)
        _ = try store.recordIncrementalForScan(batch: bA, hostname: hostname)
        _ = try store.recordIncrementalForScan(batch: bB, hostname: hostname)

        try store.abortParserReplacements(fileIDs: [fileA])

        let committed = try store.publishReadyParserReplacements(fileIDs: [fileB], hostname: hostname)
        XCTAssertEqual(committed.map(\.fileID), [fileB])
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(fileB)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(fileA)';"), 0)
        XCTAssertThrowsError(try store.publishReadyParserReplacements(fileIDs: [fileA], hostname: hostname))
    }

    func testAbortReadyReplacementPreservesExistingRawAndCheckpoint() throws {
        let (store, _) = try makeStore()
        let file = "file-preserve"
        let initial = batch(fileID: file, events: [event("orig", fileID: file, output: 5)],
                            sessions: [session("orig-s", fileID: file)],
                            edits: [edit("orig-ed", fileID: file)], replace: true, final: true, offset: 100, state: 1)
        try store.recordIncremental(batch: initial, hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events WHERE source_file_hash='\(file)';"), 5)

        let replacement = batch(fileID: file, events: [event("new", fileID: file, output: 99)],
                                replace: true, final: true, offset: 200, state: 2)
        _ = try store.recordIncrementalForScan(batch: replacement, hostname: hostname)

        try store.abortParserReplacements(fileIDs: [file])

        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(file)';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events WHERE source_file_hash='\(file)';"), 5)
        XCTAssertEqual(try scalar(store, "SELECT read_offset FROM usage_files WHERE file_id='\(file)';"), 100)
        XCTAssertEqual(try store.parserState(fileID: file, key: "state"), Data([1]))
    }

    func testReopeningStoreDropsTempReadyWithoutAffectingDurableRaw() throws {
        let file = "file-reopen"
        let fileURL: URL = try autoreleasepool {
            let (initialStore, url) = try makeStore()
            let committedBatch = batch(fileID: file, events: [event("durable", fileID: file, output: 10)])
            try initialStore.recordIncremental(batch: committedBatch, hostname: hostname)
            let readyBatch = batch(fileID: file, events: [event("staged", fileID: file, output: 99)])
            _ = try initialStore.recordIncrementalForScan(batch: readyBatch, hostname: hostname)
            return try XCTUnwrap(url)
        }
        let reopenedStore = try UsageLedgerStore(path: fileURL.path)
        XCTAssertEqual(try scalar(reopenedStore, "SELECT output_tokens FROM usage_events WHERE source_file_hash='\(file)';"), 10)
        XCTAssertThrowsError(try reopenedStore.publishReadyParserReplacements(fileIDs: [file], hostname: hostname))
    }

    func testDefaultIncrementalAPIRemainsImmediate() throws {
        let (store, _) = try makeStore()
        let file = "file-default"
        let immediateBatch = batch(fileID: file, events: [event("imm", fileID: file)], replace: true, final: true)
        try store.recordIncremental(batch: immediateBatch, hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(file)';"), 1)
        XCTAssertNotNil(try store.checkpoints(source: "codex")[file])

        let appendBatch = batch(fileID: file, events: [event("app", fileID: file)], replace: false, final: true, offset: 200)
        let appendCommitted = try store.recordIncrementalForScan(batch: appendBatch, hostname: hostname)
        XCTAssertTrue(appendCommitted)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE source_file_hash='\(file)';"), 2)
        XCTAssertEqual(try scalar(store, "SELECT read_offset FROM usage_files WHERE file_id='\(file)';"), 200)
    }

    func testPartialReplacementCannotPublishAndRollbackPreservesReadyFile() throws {
        let (store, _) = try makeStore()
        _ = try store.recordIncrementalForScan(batch: batch(fileID: "ready", events: [event("r", fileID: "ready")]), hostname: hostname)
        _ = try store.recordIncrementalForScan(batch: batch(fileID: "partial", events: [event("p", fileID: "partial")], final: false), hostname: hostname)
        XCTAssertThrowsError(try store.publishReadyParserReplacements(fileIDs: ["ready", "partial"], hostname: hostname))
        XCTAssertEqual(try store.eventCount(), 0)
        XCTAssertTrue(try store.checkpoints(source: "codex").isEmpty)
        XCTAssertEqual(try store.publishReadyParserReplacements(fileIDs: ["ready"], hostname: hostname).count, 1)
    }
}
