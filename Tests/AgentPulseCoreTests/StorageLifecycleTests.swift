import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class StorageLifecycleTests: XCTestCase {
    private let hostname = "fixture-host"
    private let fileID = "fixture-file-hash"
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, output: Int64, file: String? = nil, source: String = "claude", model: String = "claude-opus") -> UsageEvent {
        UsageEvent(id: id, source: source, model: model, project: "project-hash",
                   timestamp: time, counts: UsageTokenCounts(output: output), sessionHash: "session-hash",
                   sourceFileHash: file ?? fileID, mergeStrategy: .cumulativeMax)
    }

    private func batch(_ events: [UsageEvent], offset: Int64, replace: Bool = false, final: Bool = true,
                       values: [String: Data] = [:], removedKeys: [String] = [], removedEvents: [String] = [],
                       file: String? = nil, codexModel: String? = nil) -> UsageIncrementalBatch {
        let checkpoint = UsageFileCheckpoint(fileID: file ?? fileID, source: "claude", pathHash: file ?? fileID,
                                            offset: offset, size: offset, modifiedAt: time,
                                            parserVersion: UsageJSONLParser.parserVersion, status: final ? "complete" : "reading")
        return UsageIncrementalBatch(parsed: ParsedUsageFile(events: events, sessionEvents: [], checkpoint: checkpoint, diagnostics: []),
                                     stateChanges: UsageParserStateChanges(values: values, removedKeys: removedKeys),
                                     removedEventIDs: removedEvents, removedEditIDs: [], replacesFile: replace, isFinalBatch: final,
                                     codexUnknownModel: codexModel)
    }

    private func count(_ store: UsageLedgerStore, sql: String) throws -> Int64 {
        let statement = try store.prepare(sql)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(try store.step(statement), SQLITE_ROW)
        return sqlite3_column_int64(statement, 0)
    }

    func testAbortedReplacementPreservesCommittedHistoryAndDiscardsStage() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("old", output: 20)], offset: 100, replace: true,
                                                 values: ["state": Data("old".utf8)]), hostname: hostname)
        try store.recordIncremental(batch: batch([event("new", output: 8)], offset: 50, replace: true, final: false,
                                                 values: ["state": Data("new".utf8)]), hostname: hostname)
        XCTAssertEqual(try store.eventCount(), 1)
        XCTAssertEqual(try store.checkpoint(fileID: fileID)?.offset, 100)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data("new".utf8))
        try store.abortParserReplacement(fileID: fileID)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data("old".utf8))
        XCTAssertEqual(try count(store, sql: "SELECT output_tokens FROM usage_events WHERE event_id='old';"), 20)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_parser_stage;"), 0)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_parser_replacements;"), 0)
    }

    func testSuccessfulReplacementPublishesOnlyFinalGenerationAndKeepsOtherFiles() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("old", output: 20)], offset: 100, replace: true,
                                                 values: ["obsolete": Data([1])]), hostname: hostname)
        try store.recordIncremental(batch: batch([event("other", output: 5, file: "other-file")], offset: 10,
                                                 replace: true, file: "other-file"), hostname: hostname)
        try store.recordIncremental(batch: batch([event("new", output: 8)], offset: 30, replace: true, final: false,
                                                 values: ["current": Data([2])]), hostname: hostname)
        try store.recordIncremental(batch: batch([event("new", output: 6)], offset: 50,
                                                 values: ["current": Data([3])]), hostname: hostname)
        XCTAssertEqual(try store.eventCount(), 2)
        XCTAssertEqual(try count(store, sql: "SELECT SUM(output_tokens) FROM usage_events;"), 11)
        XCTAssertNil(try store.parserState(fileID: fileID, key: "obsolete"))
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "current"), Data([3]))
        XCTAssertEqual(try store.checkpoint(fileID: fileID)?.offset, 50)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_parser_stage;"), 0)
    }

    func testAppendCorrectionsAreAuthoritativeAndIdentityStateDoesNotAccumulateVersions() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("keep", output: 20), event("remove", output: 5)],
                                                 offset: 100, replace: true, values: ["identity": Data([1]), "discard": Data()]), hostname: hostname)
        try store.recordIncremental(batch: batch([event("keep", output: 7)], offset: 150,
                                                 values: ["identity": Data([2])], removedKeys: ["discard"],
                                                 removedEvents: ["remove"]), hostname: hostname)
        XCTAssertEqual(try store.eventCount(), 1)
        XCTAssertEqual(try count(store, sql: "SELECT output_tokens FROM usage_events;"), 7)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_parser_state;"), 1)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "identity"), Data([2]))
        XCTAssertNil(try store.parserState(fileID: fileID, key: "discard"))
    }

    func testCheckpointFailureRollsBackRawStateAndReplacementPublication() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("old", output: 20)], offset: 100, replace: true,
                                                 values: ["state": Data([1])]), hostname: hostname)
        try store.recordIncremental(batch: batch([event("new", output: 8)], offset: 30, replace: true, final: false,
                                                 values: ["state": Data([2])]), hostname: hostname)
        try store.exec("CREATE TRIGGER fail_checkpoint BEFORE INSERT ON usage_files BEGIN SELECT RAISE(ABORT,'fixture failure'); END;")
        XCTAssertThrowsError(try store.recordIncremental(batch: batch([], offset: 50), hostname: hostname))
        XCTAssertEqual(try store.checkpoint(fileID: fileID)?.offset, 100)
        XCTAssertEqual(try count(store, sql: "SELECT output_tokens FROM usage_events WHERE event_id='old';"), 20)
        try store.abortParserReplacement(fileID: fileID)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data([1]))
    }

    func testReopeningDiscardsInterruptedStageAndRetainsSavedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fixture.sqlite").path
        do {
            let store = try UsageLedgerStore(path: path)
            try store.recordIncremental(batch: batch([event("old", output: 20)], offset: 100, replace: true,
                                                     values: ["state": Data([1])]), hostname: hostname)
            try store.recordIncremental(batch: batch([event("new", output: 8)], offset: 30, replace: true, final: false,
                                                     values: ["state": Data([2])]), hostname: hostname)
        }
        let reopened = try UsageLedgerStore(path: path)
        XCTAssertEqual(try reopened.checkpoint(fileID: fileID)?.offset, 100)
        XCTAssertEqual(try reopened.parserState(fileID: fileID, key: "state"), Data([1]))
        XCTAssertEqual(try count(reopened, sql: "SELECT output_tokens FROM usage_events WHERE event_id='old';"), 20)
        XCTAssertEqual(try count(reopened, sql: "SELECT COUNT(*) FROM usage_parser_stage;"), 0)
    }

    func testIdentityMigrationInvalidatesEmbeddedOldFileReferencesWithoutDeletingHistory() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("old", output: 20)], offset: 100, replace: true,
                                                 values: ["state": Data([1])]), hostname: hostname)
        let migrated = try store.migrateFileIdentityIfCheckpointMatches(
            from: fileID, to: "new-file-hash", expectedSource: "claude", expectedSize: 100,
            expectedModifiedAt: time, expectedParserVersion: UsageJSONLParser.parserVersion)
        XCTAssertEqual(migrated?.fileID, "new-file-hash")
        XCTAssertNil(try store.parserState(fileID: fileID, key: "state"))
        XCTAssertNil(try store.parserState(fileID: "new-file-hash", key: "state"))
        XCTAssertEqual(try count(store, sql: "SELECT output_tokens FROM usage_events WHERE source_file_hash='new-file-hash';"), 20)
    }

    func testMissingFileReturningWithoutNewRowsRecomputesOwnershipTier() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("shared", output: 20)], offset: 100, replace: true), hostname: hostname)
        try store.recordIncremental(batch: batch([event("shared", output: 7, file: "other-file")], offset: 10,
                                                 replace: true, file: "other-file"), hostname: hostname)
        try store.markFilesMissing(fileIDs: [fileID], hostname: hostname)
        try store.finalizeDerived(hostname: hostname)
        XCTAssertEqual(try store.buckets(hostname: hostname).reduce(0) { $0 + $1.counts.output }, 7)
        try store.recordIncremental(batch: batch([], offset: 100), hostname: hostname)
        try store.finalizeDerived(hostname: hostname)
        XCTAssertEqual(try store.buckets(hostname: hostname).reduce(0) { $0 + $1.counts.output }, 20)
    }

    func testUnknownModelBackfillUsesKeyedStateForStagedAndCommittedRows() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        let marker = try JSONEncoder().encode("unknown-event")
        try store.recordIncremental(batch: batch([event("unknown-event", output: 20, source: "codex", model: "unknown")],
                                                 offset: 50, replace: true, final: false,
                                                 values: ["codex-unknown:identity-hash": marker]), hostname: hostname)
        try store.recordIncremental(batch: batch([], offset: 100, codexModel: "first-model"), hostname: hostname)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_events WHERE model='first-model';"), 1)
        try store.recordIncremental(batch: batch([], offset: 150, codexModel: "second-model"), hostname: hostname)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_events WHERE model='second-model';"), 1)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_parser_state;"), 1)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_parser_stage;"), 0)
    }

    func testStreamingDirtyCapturePreservesOptionalHostnameIsolation() throws {
        let store = try UsageLedgerStore(path: ":memory:")
        try store.recordIncremental(batch: batch([event("local", output: 20), event("remote", output: 5)],
                                                 offset: 100, replace: true), hostname: hostname)
        try store.exec("UPDATE usage_events SET hostname='other-host' WHERE event_id='remote'; DELETE FROM usage_dirty_keys;")
        try store.markParserRowsDirtyUnlocked(fileID: fileID, allRows: true, hostname: hostname)
        XCTAssertGreaterThan(try count(store, sql: "SELECT COUNT(*) FROM usage_dirty_keys WHERE hostname='fixture-host';"), 0)
        XCTAssertEqual(try count(store, sql: "SELECT COUNT(*) FROM usage_dirty_keys WHERE hostname='other-host';"), 0)
        try store.exec("DELETE FROM usage_dirty_keys;")
        try store.markParserRowsDirtyUnlocked(fileID: fileID, allRows: true)
        XCTAssertGreaterThan(try count(store, sql: "SELECT COUNT(*) FROM usage_dirty_keys WHERE hostname='other-host';"), 0)
    }
}
