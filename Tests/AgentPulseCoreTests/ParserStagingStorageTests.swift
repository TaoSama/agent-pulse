import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class ParserStagingStorageTests: XCTestCase {
    private let hostname = "staging-host"
    private let fileID = "staging-file"
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private func databasePath() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("staging.sqlite").path
    }

    private func batch(_ id: String?, output: Int64 = 0, offset: Int64,
                       replace: Bool = false, final: Bool = true, state: UInt8) -> UsageIncrementalBatch {
        let events = id.map {
            [UsageEvent(id: $0, source: "claude", model: "model", project: "project",
                        timestamp: time, counts: UsageTokenCounts(output: output),
                        sessionHash: "session", sourceFileHash: fileID)]
        } ?? []
        let checkpoint = UsageFileCheckpoint(fileID: fileID, source: "claude", pathHash: fileID,
            offset: offset, size: offset, modifiedAt: time, parserVersion: UsageJSONLParser.parserVersion,
            status: final ? "complete" : "reading")
        return UsageIncrementalBatch(
            parsed: ParsedUsageFile(events: events, sessionEvents: [], checkpoint: checkpoint, diagnostics: []),
            stateChanges: UsageParserStateChanges(values: ["state": Data([state])], removedKeys: []),
            removedEventIDs: [], removedEditIDs: [], replacesFile: replace, isFinalBatch: final)
    }

    private func observer(_ path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw UsageLedgerError.sqlite("unable to open fixture observer")
        }
        return db
    }

    private func execute(_ db: OpaquePointer?, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw UsageLedgerError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalar(_ db: OpaquePointer?, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw UsageLedgerError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw UsageLedgerError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func walFrames(_ db: OpaquePointer) throws -> Int32 {
        var frames: Int32 = -1
        var checkpointed: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(db, "main", SQLITE_CHECKPOINT_PASSIVE, &frames, &checkpointed)
        guard result == SQLITE_OK else {
            throw UsageLedgerError.sqlite("fixture WAL inspection failed: \(result)")
        }
        return frames
    }

    private func assertHistory(_ db: OpaquePointer?, output: Int64, offset: Int64, state: UInt8,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try scalar(db, "SELECT SUM(output_tokens) FROM main.usage_events;"), output, file: file, line: line)
        XCTAssertEqual(try scalar(db, "SELECT read_offset FROM main.usage_files;"), offset, file: file, line: line)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM main.usage_parser_state WHERE hex(value)='\(String(format: "%02X", state))';"), 1, file: file, line: line)
    }

    func testNonfinalBatchesDoNotCommitMainWALAndFinalPublicationIsAtomic() throws {
        let path = try databasePath()
        let store = try UsageLedgerStore(path: path)
        try store.recordIncremental(batch: batch("old", output: 20, offset: 100, replace: true, state: 1), hostname: hostname)
        let db = try observer(path)
        defer { XCTAssertEqual(sqlite3_close(db), SQLITE_OK) }
        let version = try scalar(db, "PRAGMA main.data_version;")
        let frames = try walFrames(db)
        XCTAssertGreaterThanOrEqual(frames, 0)
        XCTAssertEqual(try scalar(store.db, "PRAGMA temp_store;"), 1)
        XCTAssertEqual(try scalar(store.db, "PRAGMA main.synchronous;"), 1)
        let autoCheckpoint = try scalar(store.db, "PRAGMA wal_autocheckpoint;")
        let fullSync = try scalar(store.db, "PRAGMA checkpoint_fullfsync;")

        try store.recordIncremental(batch: batch("new-a", output: 3, offset: 30, replace: true, final: false, state: 2), hostname: hostname)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data([2]))
        try store.recordIncremental(batch: batch("new-b", output: 7, offset: 60, final: false, state: 3), hostname: hostname)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data([3]))
        XCTAssertEqual(try scalar(store.db, "SELECT COUNT(*) FROM temp.usage_parser_stage WHERE kind='event';"), 2)
        XCTAssertEqual(try scalar(db, "PRAGMA main.data_version;"), version)
        XCTAssertEqual(try walFrames(db), frames)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM main.sqlite_schema WHERE name IN ('usage_parser_stage','usage_parser_replacements');"), 0)
        XCTAssertEqual(try scalar(db, "SELECT COUNT(*) FROM temp.sqlite_schema;"), 0)
        try assertHistory(db, output: 20, offset: 100, state: 1)

        // A concurrent reader sees a complete old snapshot until it starts a new read.
        try execute(db, "BEGIN DEFERRED;")
        try assertHistory(db, output: 20, offset: 100, state: 1)
        try store.recordIncremental(batch: batch(nil, offset: 90, state: 4), hostname: hostname)
        try assertHistory(db, output: 20, offset: 100, state: 1)
        try execute(db, "COMMIT;")
        try assertHistory(db, output: 10, offset: 90, state: 4)
        XCTAssertGreaterThan(try scalar(db, "PRAGMA main.data_version;"), version)
        XCTAssertEqual(try scalar(store.db, "SELECT COUNT(*) FROM temp.usage_parser_stage;"), 0)
        XCTAssertEqual(try scalar(store.db, "PRAGMA wal_autocheckpoint;"), autoCheckpoint)
        XCTAssertEqual(try scalar(store.db, "PRAGMA checkpoint_fullfsync;"), fullSync)
    }

    func testFailedFinalPublicationRollsBackMainAndRetainsStageForRetry() throws {
        let path = try databasePath()
        let store = try UsageLedgerStore(path: path)
        try store.recordIncremental(batch: batch("old", output: 20, offset: 100, replace: true, state: 1), hostname: hostname)
        try store.recordIncremental(batch: batch("new", output: 8, offset: 30, replace: true, final: false, state: 2), hostname: hostname)
        try store.exec("CREATE TRIGGER fail_staging_checkpoint BEFORE INSERT ON usage_files BEGIN SELECT RAISE(ABORT,'fixture checkpoint failure'); END;")
        XCTAssertThrowsError(try store.recordIncremental(batch: batch(nil, offset: 60, state: 3), hostname: hostname))
        try assertHistory(store.db, output: 20, offset: 100, state: 1)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data([2]))
        XCTAssertEqual(try scalar(store.db, "SELECT COUNT(*) FROM temp.usage_parser_stage WHERE kind='event';"), 1)
        try store.exec("DROP TRIGGER fail_staging_checkpoint;")
        try store.recordIncremental(batch: batch(nil, offset: 60, state: 3), hostname: hostname)
        try assertHistory(store.db, output: 8, offset: 60, state: 3)
    }

    func testReopeningDiscardsOnlyUnpublishedTemporaryGeneration() throws {
        let path = try databasePath()
        do {
            let store = try UsageLedgerStore(path: path)
            try store.recordIncremental(batch: batch("old", output: 20, offset: 100, replace: true, state: 1), hostname: hostname)
            try store.recordIncremental(batch: batch("new", output: 8, offset: 30, replace: true, final: false, state: 2), hostname: hostname)
        }
        let reopened = try UsageLedgerStore(path: path)
        try assertHistory(reopened.db, output: 20, offset: 100, state: 1)
        XCTAssertEqual(try reopened.parserState(fileID: fileID, key: "state"), Data([1]))
        XCTAssertEqual(try scalar(reopened.db, "SELECT COUNT(*) FROM temp.usage_parser_stage;"), 0)
        XCTAssertEqual(try scalar(reopened.db, "SELECT COUNT(*) FROM temp.usage_parser_replacements;"), 0)
    }

    func testLegacyPersistentScratchTablesAreRemovedWithoutDeletingHistory() throws {
        let path = try databasePath()
        do {
            let store = try UsageLedgerStore(path: path)
            try store.recordIncremental(batch: batch("old", output: 20, offset: 100, replace: true, state: 1), hostname: hostname)
            // The qualified schema recreates an older release's interrupted scratch storage.
            try store.exec("""
                CREATE TABLE main.usage_parser_replacements(file_id TEXT PRIMARY KEY,hostname TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE main.usage_parser_stage(file_id TEXT NOT NULL,kind TEXT NOT NULL,key TEXT NOT NULL,value BLOB NOT NULL,PRIMARY KEY(file_id,kind,key)) WITHOUT ROWID;
                INSERT INTO main.usage_parser_replacements VALUES('interrupted','staging-host');
                INSERT INTO main.usage_parser_stage VALUES('interrupted','state','unfinished',zeroblob(131072));
                CREATE TABLE main.fixture_unrelated(value INTEGER NOT NULL);
                INSERT INTO main.fixture_unrelated VALUES(7);
                """)
            XCTAssertEqual(try scalar(store.db, "SELECT COUNT(*) FROM main.usage_parser_stage;"), 1)
        }
        let reopened = try UsageLedgerStore(path: path)
        XCTAssertEqual(try scalar(reopened.db, "SELECT COUNT(*) FROM main.sqlite_schema WHERE name IN ('usage_parser_stage','usage_parser_replacements');"), 0)
        XCTAssertEqual(try scalar(reopened.db, "SELECT COUNT(*) FROM temp.sqlite_schema WHERE name IN ('usage_parser_stage','usage_parser_replacements');"), 2)
        XCTAssertEqual(try scalar(reopened.db, "SELECT value FROM main.fixture_unrelated;"), 7)
        try assertHistory(reopened.db, output: 20, offset: 100, state: 1)
    }
}
