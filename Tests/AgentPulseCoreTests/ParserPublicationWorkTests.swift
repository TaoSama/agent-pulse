import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class ParserPublicationWorkTests: XCTestCase {
    private let hostname = "publication-host"
    private let fileID = "publication-file"
    private let time = Date(timeIntervalSince1970: 1_800_000_000)

    private final class StatementTrace {
        var dirtyCaptures = 0
        var rawDeletes = 0
        var scopedStatements = 0
        var stageStreams = 0
        var eventInserts = 0
        var typedStageCleanups = 0
        var vmSteps = 0

        func record(_ statement: OpaquePointer, event: UInt32) {
            if event == UInt32(SQLITE_TRACE_PROFILE) {
                vmSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 1))
                return
            }
            guard let rawSQL = sqlite3_sql(statement) else { return }
            let sql = String(cString: rawSQL).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if sql.hasPrefix("INSERT OR IGNORE INTO usage_dirty_keys"), sql.contains("WHERE source_file_hash=?") {
                dirtyCaptures += 1
            }
            for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
                if sql.hasPrefix("DELETE FROM \(table) WHERE source_file_hash") { rawDeletes += 1 }
            }
            if sql.contains("temp_parser_keys") { scopedStatements += 1 }
            if sql.hasPrefix("SELECT value FROM temp.usage_parser_stage") { stageStreams += 1 }
            if sql.hasPrefix("INSERT INTO usage_events(") || sql.hasPrefix("INSERT INTO usage_events ") { eventInserts += 1 }
            if sql.hasPrefix("DELETE FROM temp.usage_stage_"), sql.hasSuffix("WHERE source_file_hash=?;") {
                typedStageCleanups += 1
            }
        }
    }

    private func makeStore() throws -> UsageLedgerStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return try UsageLedgerStore(path: directory.appendingPathComponent("publication.sqlite").path)
    }

    private func event(_ id: String, output: Int64 = 1, source: String = "codex", at: Date? = nil,
                       strategy: UsageEvent.MergeStrategy = .overwrite, skills: [String: Int] = [:]) -> UsageEvent {
        UsageEvent(id: id, source: source, model: "model", project: "project", timestamp: at ?? time,
                   counts: UsageTokenCounts(output: output), sessionHash: "session", sourceFileHash: fileID,
                   mergeStrategy: strategy, skillCounts: skills)
    }

    private func session(_ id: String, at: Date? = nil) -> UsageSessionEvent {
        UsageSessionEvent(id: id, source: "codex", sessionHash: "session", sourceFileHash: fileID,
                          role: .user, timestamp: at ?? time)
    }

    private func edit(_ id: String, at: Date? = nil) -> UsageEditEntry {
        UsageEditEntry(source: "codex", model: "model", project: "project", sourceFileHash: fileID,
                       timestamp: at ?? time, added: 2, deleted: 1, toolUseID: id)
    }

    private func batch(_ events: [UsageEvent] = [], sessions: [UsageSessionEvent] = [], edits: [UsageEditEntry] = [],
                       replace: Bool = false, final: Bool = true, source: String = "codex",
                       offset: Int64 = 100, state: UInt8 = 1) -> UsageIncrementalBatch {
        let checkpoint = UsageFileCheckpoint(fileID: fileID, source: source, pathHash: fileID, offset: offset,
            size: offset, modifiedAt: time, parserVersion: UsageJSONLParser.parserVersion, status: final ? "complete" : "reading")
        return UsageIncrementalBatch(
            parsed: ParsedUsageFile(events: events, sessionEvents: sessions, checkpoint: checkpoint,
                                   diagnostics: [], editEntries: edits),
            stateChanges: UsageParserStateChanges(values: ["state": Data([state])], removedKeys: []),
            removedEventIDs: [], removedEditIDs: [], replacesFile: replace, isFinalBatch: final)
    }

    private func scalar(_ store: UsageLedgerStore, _ sql: String) throws -> Int64 {
        let statement = try store.prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard try store.step(statement) == SQLITE_ROW else { throw UsageLedgerError.sqlite("fixture scalar missing") }
        return sqlite3_column_int64(statement, 0)
    }

    private func cacheCounter(_ store: UsageLedgerStore, _ operation: Int32, reset: Bool = false) throws -> Int32 {
        var current: Int32 = 0
        var highest: Int32 = 0
        guard sqlite3_db_status(store.db, operation, &current, &highest, reset ? 1 : 0) == SQLITE_OK else {
            throw UsageLedgerError.sqlite("fixture cache counter unavailable")
        }
        return current
    }

    private func trace(_ store: UsageLedgerStore, body: () throws -> Void) throws -> StatementTrace {
        let trace = StatementTrace()
        let mask = UInt32(SQLITE_TRACE_STMT | SQLITE_TRACE_PROFILE)
        let result = sqlite3_trace_v2(store.db, mask, { event, context, statement, _ in
            guard let context, let statement else { return 0 }
            Unmanaged<StatementTrace>.fromOpaque(context).takeUnretainedValue().record(OpaquePointer(statement), event: event)
            return 0
        }, Unmanaged.passUnretained(trace).toOpaque())
        guard result == SQLITE_OK else { throw UsageLedgerError.sqlite("fixture trace installation failed") }
        defer { XCTAssertEqual(sqlite3_trace_v2(store.db, 0, nil, nil), SQLITE_OK) }
        try body()
        return trace
    }

    func testEOFBookkeepingIsPerFileRatherThanPerDecodedBatch() throws {
        let rowCounts = [1, 129, 1025]
        let expectedDirtyCapturesPerFile = 16 // Eight key queries for each of old and new generations.
        // Only the event table has an old generation in this fixture.
        // Fresh session/edit tables must bypass diff DELETE/UPDATE entirely.
        let expectedRawDeletesPerFile = 1
        for count in rowCounts {
            let store = try makeStore()
            try store.recordIncremental(batch: batch([event("old")], replace: true), hostname: hostname)
            try store.recordIncremental(batch: batch((0..<count).map { event("event-\($0)") },
                sessions: (0..<count).map { session("session-\($0)") }, edits: (0..<count).map { edit("edit-\($0)") },
                replace: true, final: false), hostname: hostname)
            _ = try cacheCounter(store, SQLITE_DBSTATUS_CACHE_MISS, reset: true)
            _ = try cacheCounter(store, SQLITE_DBSTATUS_CACHE_WRITE, reset: true)
            let observed = try trace(store) {
                try store.recordIncremental(batch: batch(offset: 200, state: 2), hostname: hostname)
            }
            let cacheMisses = try cacheCounter(store, SQLITE_DBSTATUS_CACHE_MISS)
            let cacheWrites = try cacheCounter(store, SQLITE_DBSTATUS_CACHE_WRITE)
            XCTAssertEqual(observed.dirtyCaptures, expectedDirtyCapturesPerFile, "rows=\(count)")
            XCTAssertEqual(observed.rawDeletes, expectedRawDeletesPerFile, "rows=\(count)")
            XCTAssertEqual(observed.scopedStatements, 0, "EOF must not rebuild per-batch correction keys")
            XCTAssertEqual(observed.stageStreams, 0, "typed publication must not decode a generic JSON event stream")
            XCTAssertEqual(observed.eventInserts, 1, "event publication must be one set operation regardless of row count")
            XCTAssertEqual(observed.typedStageCleanups, 3, "each typed stage must be cleared once at EOF")
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events;"), Int64(count))
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events;"), Int64(count))
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries;"), Int64(count))
            print("EOF rows=\(count): dirty=\(observed.dirtyCaptures), deletes=\(observed.rawDeletes), VM=\(observed.vmSteps), cacheMiss=\(cacheMisses), cacheWrite=\(cacheWrites)")
        }
    }

    private func observeRawMutations(_ store: UsageLedgerStore) throws {
        try store.exec("CREATE TEMP TABLE raw_mutations(table_name TEXT, operation TEXT);")
        for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                try store.exec("""
                    CREATE TEMP TRIGGER observe_\(table)_\(operation) AFTER \(operation) ON main.\(table)
                    BEGIN INSERT INTO raw_mutations VALUES('\(table)','\(operation)'); END;
                    """)
            }
        }
    }

    func testIdenticalReplacementDoesNotMutateRawRows() throws {
        let store = try makeStore()
        let unchanged = batch([event("same", skills: ["b": 2, "a": 1])],
            sessions: [session("same")], edits: [edit("same")], replace: true)
        try store.recordIncremental(batch: unchanged, hostname: hostname)
        try store.finalizeDerived(hostname: hostname)
        try store.exec("UPDATE usage_events SET created_at_ms=123;")
        try observeRawMutations(store)
        try store.recordIncremental(batch: unchanged, hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM raw_mutations;"), 0)
        XCTAssertEqual(try scalar(store, "SELECT created_at_ms FROM usage_events;"), 123)
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events;"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys;"), 0)
        XCTAssertFalse(try store.requiresDerivationCompletion())
    }

    func testUnchangedReplacementPreservesCheckpointTierAndSourceGateInvalidation() throws {
        let store = try makeStore()
        let unchanged = batch([event("same")], replace: true)
        try store.recordIncremental(batch: unchanged, hostname: hostname)
        try store.finalizeDerived(hostname: hostname)
        // Isolate checkpoint attribution from raw mutations: returning or newly
        // registered files become active-tier candidates even with identical rows.
        for checkpointChange in [
            "UPDATE usage_files SET scan_status='missing';",
            "DELETE FROM usage_files;"
        ] {
            try store.exec(checkpointChange)
            try store.recordIncremental(batch: unchanged, hostname: hostname)
            XCTAssertGreaterThan(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys;"), 0)
            XCTAssertTrue(try store.requiresDerivationCompletion())
            try store.finalizeDerived(hostname: hostname)
        }
        // A new measurable source must invalidate derived code metrics even when
        // it produces no raw rows. A second identical empty scan must be a no-op.
        try store.recordIncremental(batch: batch(replace: true), hostname: hostname)
        try store.finalizeDerived(hostname: hostname)
        let empty = batch(replace: true, source: "new-empty-source")
        try store.recordIncremental(batch: empty, hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_metric_sources WHERE source='new-empty-source';"), 1)
        XCTAssertTrue(try store.requiresDerivationCompletion())
        try store.finalizeDerived(hostname: hostname)
        try store.recordIncremental(batch: empty, hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys;"), 0)
        XCTAssertFalse(try store.requiresDerivationCompletion())
    }

    func testReplacementMutatesOnlyChangedMissingAndNewRowsForEachKind() throws {
        let store = try makeStore()
        let ids = ["same", "changed", "removed"]
        try store.recordIncremental(batch: batch(ids.map { event($0) }, sessions: ids.map { session($0) },
            edits: ids.map { edit($0) }, replace: true), hostname: hostname)
        try observeRawMutations(store)
        try store.recordIncremental(batch: batch([event("same"), event("changed", output: 7), event("new")],
            sessions: [session("same"), session("changed", at: time.addingTimeInterval(1)), session("new")],
            edits: [edit("same"), edit("changed", at: time.addingTimeInterval(1)), edit("new")],
            replace: true), hostname: hostname)
        for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
            for operation in ["INSERT", "UPDATE", "DELETE"] {
                XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM raw_mutations WHERE table_name='\(table)' AND operation='\(operation)';"), 1)
            }
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM \(table);"), 3)
        }
        XCTAssertEqual(try scalar(store, "SELECT SUM(output_tokens) FROM usage_events;"), 9)
    }

    func testParsedCorrectionsRemainAuthoritativeForAppendAndReplacement() throws {
        let store = try makeStore()
        try store.recordIncremental(batch: batch([event("shared", output: 80, strategy: .cumulativeMax)], replace: true), hostname: hostname)
        try store.recordIncremental(batch: batch([event("shared", output: 7, strategy: .cumulativeMax)]), hostname: hostname)
        // Incremental parser batches already contain the reconciled value;
        // writeParserRawBatchUnlocked replaces the touched event identities.
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events;"), 7)
        try store.recordIncremental(batch: batch([event("shared", output: 7, strategy: .cumulativeMax)], replace: true), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events;"), 7)
    }

    func testFrozenBoundaryAndDroppedCountersMatchAppendForAllKinds() throws {
        let before = time.addingTimeInterval(-1)
        let after = time.addingTimeInterval(1)
        for replacement in [false, true] {
            let store = try makeStore()
            try store.setIntUnlocked(key: "frozen_before_ms\u{1}\(hostname)", value: store.millis(time))
            try store.recordIncremental(batch: batch([
                event("before", output: 9, at: before), event("boundary", output: 2), event("after", output: 3, at: after)
            ], sessions: [session("before", at: before), session("boundary"), session("after", at: after)],
               edits: [edit("historical-edit", at: before)], replace: replacement), hostname: hostname)
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events;"), 2)
            XCTAssertEqual(try scalar(store, "SELECT SUM(output_tokens) FROM usage_events;"), 5)
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events;"), 2)
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries;"), 1)
            XCTAssertEqual(try store.frozenDroppedEventCount(hostname: hostname), 2)
        }
    }

    func testReplacementCapturesOldOwnersAndSourceAndKeepsLatestStagedDuplicates() throws {
        let store = try makeStore()
        let oldSource = "previous-source"
        try store.recordIncremental(batch: batch([
            event("shared", output: 80, source: oldSource), event("removed", output: 20, source: oldSource)
        ], replace: true, source: oldSource), hostname: "previous-host")
        try store.exec("UPDATE usage_events SET hostname='second-previous-host' WHERE event_id='removed'; DELETE FROM usage_dirty_keys;")
        try store.recordIncremental(batch: batch([
            event("shared", output: 30, strategy: .cumulativeMax, skills: ["skill": 5]),
            event("shared", output: 12, strategy: .cumulativeMax, skills: ["skill": 3])
        ], replace: true, final: false), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM temp.usage_stage_events_candidate;"), 1)
        try store.recordIncremental(batch: batch([
            event("shared", output: 7, strategy: .cumulativeMax, skills: ["skill": 1])
        ], state: 2), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT SUM(output_tokens) FROM usage_events;"), 7)
        XCTAssertEqual(try scalar(store, "SELECT json_extract(skill_counts_json,'$.skill') FROM usage_events;"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE hostname='publication-host' AND source='codex';"), 1)
        for (owner, source, id) in [("previous-host", oldSource, "shared"), ("second-previous-host", oldSource, "removed"), (hostname, "codex", "shared")] {
            XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys WHERE hostname='\(owner)' AND kind='logical' AND key='\(source)\u{1}\(id)';"), 1)
        }
    }

    func testEmptyReplacementStillPublishesCheckpointStateAndSourceGate() throws {
        let store = try makeStore()
        try store.recordIncremental(batch: batch([event("old")], replace: true), hostname: hostname)
        let emptySource = "empty-supported-source"
        try store.recordIncremental(batch: batch(replace: true, source: emptySource, offset: 0, state: 2), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events;"), 0)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_metric_sources WHERE source='\(emptySource)';"), 1)
        XCTAssertEqual(try store.checkpoint(fileID: fileID)?.offset, 0)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data([2]))
        XCTAssertEqual(try store.readTextUnlocked(key: UsageLedgerStore.rawDerivationPendingKey), "1")
    }

    func testTypedSessionStageKeepsLatestSourceForTheSameIdentity() throws {
        let store = try makeStore()
        let old = UsageSessionEvent(id: "shared", source: "old", sessionHash: "session",
            sourceFileHash: fileID, role: .user, timestamp: time)
        let new = UsageSessionEvent(id: "shared", source: "new", sessionHash: "session",
            sourceFileHash: fileID, role: .assistant, timestamp: time)
        try store.recordIncremental(batch: batch(sessions: [old], replace: true, final: false), hostname: hostname)
        try store.recordIncremental(batch: batch(sessions: [new]), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events;"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_session_events WHERE source='new' AND role='assistant';"), 1)
    }

    func testTypedStageRemovalsAndUnknownModelBackfill() throws {
        let store = try makeStore()
        let first = batch([event("removed"), event("kept")], edits: [edit("removed"), edit("kept")], replace: true, final: false)
        let staged = UsageIncrementalBatch(parsed: first.parsed,
            stateChanges: UsageParserStateChanges(values: ["codex-unknown:fixture": try JSONEncoder().encode("kept")], removedKeys: []),
            removedEventIDs: [], removedEditIDs: [], replacesFile: true, isFinalBatch: false)
        try store.recordIncremental(batch: staged, hostname: hostname)
        let last = batch([event("kept")], edits: [edit("kept")])
        try store.recordIncremental(batch: UsageIncrementalBatch(parsed: last.parsed,
            stateChanges: last.stateChanges, removedEventIDs: ["removed", "kept"],
            removedEditIDs: ["removed", "kept"], replacesFile: false, isFinalBatch: true,
            codexUnknownModel: "resolved-model"), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events;"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_events WHERE event_id='kept' AND model='resolved-model';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries WHERE tool_use_id='kept';"), 1)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_edit_entries;"), 1)
    }

    func testCheckpointFailureRollsBackNewRowsDirtyKeysAndFrozenCounter() throws {
        let store = try makeStore()
        try store.recordIncremental(batch: batch([event("old", output: 20)], replace: true), hostname: hostname)
        try store.setIntUnlocked(key: "frozen_before_ms\u{1}\(hostname)", value: store.millis(time))
        try store.exec("DELETE FROM usage_dirty_keys;")
        try store.recordIncremental(batch: batch([
            event("frozen", at: time.addingTimeInterval(-1)), event("new", output: 7)
        ], replace: true, final: false, state: 2), hostname: hostname)
        try store.exec("CREATE TRIGGER fail_publication BEFORE INSERT ON usage_files BEGIN SELECT RAISE(ABORT,'publication fixture'); END;")
        XCTAssertThrowsError(try store.recordIncremental(batch: batch(offset: 200, state: 3), hostname: hostname))
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events WHERE event_id='old';"), 20)
        XCTAssertEqual(try scalar(store, "SELECT COUNT(*) FROM usage_dirty_keys;"), 0)
        XCTAssertEqual(try store.frozenDroppedEventCount(hostname: hostname), 0)
        XCTAssertEqual(try store.checkpoint(fileID: fileID)?.offset, 100)
        XCTAssertEqual(try store.parserState(fileID: fileID, key: "state"), Data([2]))
        try store.exec("DROP TRIGGER fail_publication;")
        try store.recordIncremental(batch: batch(offset: 200, state: 3), hostname: hostname)
        XCTAssertEqual(try scalar(store, "SELECT output_tokens FROM usage_events;"), 7)
        XCTAssertEqual(try store.frozenDroppedEventCount(hostname: hostname), 1)
    }
}
