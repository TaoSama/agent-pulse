import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class FullLogicalScanTests: XCTestCase {

    private func makeLedger() throws -> UsageLedgerStore {
        let ledger = try UsageLedgerStore(path: ":memory:")
        try ledger.prepareForUsageScan()
        return ledger
    }

    private func insertFile(
        _ ledger: UsageLedgerStore,
        fileID: String,
        source: String = "codex",
        status: String = "ok"
    ) throws {
        let stmt = try ledger.prepare("""
            INSERT INTO usage_files(file_id, source, path_hash, read_offset, file_size, mtime_ms, parser_version, scan_status, updated_at_ms)
            VALUES (?, ?, 'ph', 0, 100, 1000, 7, ?, 1000);
            """)
        defer { sqlite3_finalize(stmt) }
        try ledger.bind(stmt, 1, fileID)
        try ledger.bind(stmt, 2, source)
        try ledger.bind(stmt, 3, status)
        try ledger.done(stmt)
    }

    private func insertEvent(
        _ ledger: UsageLedgerStore,
        eventID: String,
        source: String = "codex",
        model: String = "gpt-5",
        project: String = "project-a",
        timestampMs: Int64 = 1000,
        inputTokens: Int64 = 10,
        outputTokens: Int64 = 20,
        cachedInputTokens: Int64 = 0,
        cacheCreationInputTokens: Int64 = 0,
        reasoningOutputTokens: Int64 = 0,
        totalTokens: Int64 = 30,
        sessionHash: String = "sess-1",
        sourceFileHash: String = "fh-1",
        inherited: Int = 0,
        lineageFingerprint: String = "",
        codexDedupKey: String = "",
        mergeStrategy: String = "overwrite",
        hostname: String = "host-a"
    ) throws {
        let stmt = try ledger.prepare("""
            INSERT INTO usage_events(
                event_id, source, model, project, timestamp_ms,
                input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                reasoning_output_tokens, total_tokens, session_hash, source_file_hash,
                rollout_key, parent_rollout_key, inherited, has_total_snapshot,
                lineage_fingerprint, codex_dedup_key, merge_strategy, skill_counts_json,
                mcp_counts_json, hostname, created_at_ms
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '', '', ?, 0, ?, ?, ?, '{}', '{}', ?, 1);
            """)
        defer { sqlite3_finalize(stmt) }
        try ledger.bind(stmt, 1, eventID)
        try ledger.bind(stmt, 2, source)
        try ledger.bind(stmt, 3, model)
        try ledger.bind(stmt, 4, project)
        try ledger.bind(stmt, 5, timestampMs)
        try ledger.bind(stmt, 6, inputTokens)
        try ledger.bind(stmt, 7, outputTokens)
        try ledger.bind(stmt, 8, cachedInputTokens)
        try ledger.bind(stmt, 9, cacheCreationInputTokens)
        try ledger.bind(stmt, 10, reasoningOutputTokens)
        try ledger.bind(stmt, 11, totalTokens)
        try ledger.bind(stmt, 12, sessionHash)
        try ledger.bind(stmt, 13, sourceFileHash)
        try ledger.bind(stmt, 14, Int64(inherited))
        try ledger.bind(stmt, 15, lineageFingerprint)
        try ledger.bind(stmt, 16, codexDedupKey)
        try ledger.bind(stmt, 17, mergeStrategy)
        try ledger.bind(stmt, 18, hostname)
        try ledger.done(stmt)
    }

    private func queryPlan(
        _ ledger: UsageLedgerStore,
        sql: String,
        hostname: String
    ) throws -> [String] {
        let stmt = try ledger.prepare("EXPLAIN QUERY PLAN " + sql)
        defer { sqlite3_finalize(stmt) }
        try ledger.bind(stmt, 1, hostname)
        var plan: [String] = []
        while try ledger.step(stmt) == SQLITE_ROW {
            plan.append(ledger.text(stmt, 3))
        }
        return plan
    }

    private func rowCount(_ ledger: UsageLedgerStore, table: String) throws -> Int64 {
        let stmt = try ledger.prepare("SELECT COUNT(*) FROM \(table);")
        defer { sqlite3_finalize(stmt) }
        guard try ledger.step(stmt) == SQLITE_ROW else {
            throw UsageLedgerError.sqlite("Missing count result in full logical scan test")
        }
        return sqlite3_column_int64(stmt, 0)
    }

    // MARK: - Tests

    func testEmptyTableSelectsSequentialScanAndYieldsEmptyResult() throws {
        let ledger = try makeLedger()
        let sql = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-a")
        XCTAssertTrue(sql.contains("NOT INDEXED"), "Expected NOT INDEXED on empty table: \(sql)")

        let plan = try queryPlan(ledger, sql: sql, hostname: "host-a")
        XCTAssertTrue(plan.contains { $0.contains("SCAN usage_events") }, "Plan should scan table: \(plan)")
        XCTAssertFalse(plan.contains { $0.contains("idx_usage_events_host_time") }, "Plan should not use index: \(plan)")

        try ledger.exec("DROP TABLE IF EXISTS temp_logical_events;")
        let stmt = try ledger.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try ledger.bind(stmt, 1, "host-a")
        try ledger.done(stmt)

        let count = try rowCount(ledger, table: "temp_logical_events")
        XCTAssertEqual(count, 0)
    }

    func testSingleHostSelectsSequentialScan() throws {
        let ledger = try makeLedger()
        try insertFile(ledger, fileID: "fh-1")
        try insertEvent(ledger, eventID: "e1", hostname: "host-a")
        try insertEvent(ledger, eventID: "e2", hostname: "host-a")

        let sql = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-a")
        XCTAssertTrue(sql.contains("NOT INDEXED"), "Expected NOT INDEXED when all rows match target host")

        let plan = try queryPlan(ledger, sql: sql, hostname: "host-a")
        XCTAssertTrue(plan.contains { $0.contains("SCAN usage_events") }, "Plan should scan table: \(plan)")
        XCTAssertFalse(plan.contains { $0.contains("idx_usage_events_host_time") }, "Plan should not use index: \(plan)")
    }

    func testMultipleHostsRegressToIndexedPath() throws {
        let ledger = try makeLedger()
        try insertFile(ledger, fileID: "fh-1")
        try insertEvent(ledger, eventID: "e-a", hostname: "host-a")
        try insertEvent(ledger, eventID: "e-b", hostname: "host-b")
        try insertEvent(ledger, eventID: "e-c", hostname: "host-c")

        // 1) host-b has both smaller (host-a) and larger (host-c) hosts
        let sqlB = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-b")
        XCTAssertFalse(sqlB.contains("NOT INDEXED"), "Expected indexed path for host-b when other hosts exist")
        let planB = try queryPlan(ledger, sql: sqlB, hostname: "host-b")
        XCTAssertTrue(planB.contains { $0.contains("SEARCH usage_events USING INDEX idx_usage_events_host_time") }, "Plan should search index: \(planB)")
        XCTAssertFalse(planB.contains { $0.contains("SCAN usage_events") }, "Plan should not full-scan: \(planB)")

        // 2) host-a only has larger host (host-b, host-c)
        let sqlA = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-a")
        XCTAssertFalse(sqlA.contains("NOT INDEXED"), "Expected indexed path for host-a when larger host exists")

        // 3) host-c only has smaller host (host-a, host-b)
        let sqlC = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-c")
        XCTAssertFalse(sqlC.contains("NOT INDEXED"), "Expected indexed path for host-c when smaller host exists")
        for (host, sql, expectedID) in [("host-a", sqlA, "e-a"), ("host-b", sqlB, "e-b"), ("host-c", sqlC, "e-c")] {
            try ledger.exec("DROP TABLE IF EXISTS temp_logical_events;")
            let statement = try ledger.prepare(sql)
            defer { sqlite3_finalize(statement) }
            try ledger.bind(statement, 1, host)
            try ledger.done(statement)
            XCTAssertEqual(try rowCount(ledger, table: "temp_logical_events"), 1)
            let result = try ledger.prepare("SELECT event_id FROM temp_logical_events;")
            defer { sqlite3_finalize(result) }
            XCTAssertEqual(try ledger.step(result), SQLITE_ROW)
            XCTAssertEqual(ledger.text(result, 0), expectedID)
        }
    }

    func testNonExistentHostReturnsEmptyResult() throws {
        let ledger = try makeLedger()
        try insertFile(ledger, fileID: "fh-1")
        try insertEvent(ledger, eventID: "e1", hostname: "host-a")

        let sql = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-nonexistent")
        try ledger.exec("DROP TABLE IF EXISTS temp_logical_events;")
        let stmt = try ledger.prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try ledger.bind(stmt, 1, "host-nonexistent")
        try ledger.done(stmt)

        let count = try rowCount(ledger, table: "temp_logical_events")
        XCTAssertEqual(count, 0)
    }

    func testBidirectionalExceptEquivalenceAcrossTiersAndDuplicates() throws {
        let ledger = try makeLedger()
        try insertFile(ledger, fileID: "file-active", status: "ok")
        try insertFile(ledger, fileID: "file-active-2", status: "ok")
        try insertFile(ledger, fileID: "file-missing", status: "missing")

        // Construct various tiers and duplicate cases on host-a:
        // Case 1: Same (source, event_id) appearing in both tier 2 (active) and tier 1 (missing).
        // Tier 2 should win.
        try insertEvent(ledger, eventID: "dup-1", model: "winner-model", project: "proj-1",
                        inputTokens: 100, outputTokens: 200, sessionHash: "s-win",
                        sourceFileHash: "file-active", hostname: "host-a")
        try insertEvent(ledger, eventID: "dup-1", model: "loser-model", project: "proj-1",
                        inputTokens: 10, outputTokens: 20, sessionHash: "s-lose",
                        sourceFileHash: "file-missing", hostname: "host-a")

        // Case 2: Tier 0 (empty source_file_hash) vs Tier 1 (missing)
        try insertEvent(ledger, eventID: "dup-2", model: "tier1-model", project: "proj-2",
                        sourceFileHash: "file-missing", hostname: "host-a")
        try insertEvent(ledger, eventID: "dup-2", model: "tier0-model", project: "proj-2",
                        sourceFileHash: "", hostname: "host-a")

        // Case 3: Identity conflict within top tier (multiple models in same top tier)
        try insertEvent(ledger, eventID: "conflict-1", model: "model-x", project: "proj-3",
                        sessionHash: "sess-x", sourceFileHash: "file-active", hostname: "host-a")
        try insertEvent(ledger, eventID: "conflict-1", model: "model-y", project: "proj-3",
                        sessionHash: "sess-y", sourceFileHash: "file-active-2", hostname: "host-a")

        // Case 4: Normal single event
        try insertEvent(ledger, eventID: "solo-1", model: "model-single", project: "proj-single",
                        sourceFileHash: "file-active", hostname: "host-a")

        // Run new path
        let newSQL = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-a")
        XCTAssertTrue(newSQL.contains("NOT INDEXED"))
        try ledger.exec("DROP TABLE IF EXISTS temp_logical_events;")
        try ledger.exec("DROP TABLE IF EXISTS temp_logical_new;")
        try ledger.exec("DROP TABLE IF EXISTS temp_logical_old;")

        let newStmt = try ledger.prepare(newSQL)
        defer { sqlite3_finalize(newStmt) }
        try ledger.bind(newStmt, 1, "host-a")
        try ledger.done(newStmt)
        try ledger.exec("CREATE TEMP TABLE temp_logical_new AS SELECT * FROM temp_logical_events;")
        try ledger.exec("DROP TABLE temp_logical_events;")

        // Run forced old index path
        let oldSQL = newSQL
            .replacingOccurrences(of: "usage_events NOT INDEXED", with: "usage_events INDEXED BY idx_usage_events_host_time")
        let oldStmt = try ledger.prepare(oldSQL)
        defer { sqlite3_finalize(oldStmt) }
        try ledger.bind(oldStmt, 1, "host-a")
        try ledger.done(oldStmt)
        try ledger.exec("CREATE TEMP TABLE temp_logical_old AS SELECT * FROM temp_logical_events;")
        try ledger.exec("DROP TABLE temp_logical_events;")

        // Verify row counts match and > 0
        let countNew = try rowCount(ledger, table: "temp_logical_new")
        let countOld = try rowCount(ledger, table: "temp_logical_old")
        XCTAssertGreaterThan(countNew, 0, "Should have processed events")
        XCTAssertEqual(countNew, countOld, "New and old row counts must match")

        // Bidirectional EXCEPT test: (new EXCEPT old) UNION ALL (old EXCEPT new) must be 0
        let diffStmt = try ledger.prepare("""
            SELECT COUNT(*) FROM (
                SELECT * FROM (SELECT * FROM temp_logical_new EXCEPT SELECT * FROM temp_logical_old)
                UNION ALL
                SELECT * FROM (SELECT * FROM temp_logical_old EXCEPT SELECT * FROM temp_logical_new)
            );
            """)
        defer { sqlite3_finalize(diffStmt) }
        guard try ledger.step(diffStmt) == SQLITE_ROW else {
            XCTFail("Failed to step diff statement")
            return
        }
        let diffCount = sqlite3_column_int64(diffStmt, 0)
        XCTAssertEqual(diffCount, 0, "Bidirectional EXCEPT found \(diffCount) mismatched rows between sequential and indexed paths")
    }

    func testIndexInitializationCallingOrderSafety() throws {
        // Fresh database without prepareForUsageScan()
        let ledger = try UsageLedgerStore(path: ":memory:")

        // The public full-finalize entry point must initialize its required indexes.
        try ledger.finalizeDerived(hostname: "host-a", strategy: .fullRecompute)

        // After prepareForUsageScan(), the helper succeeds safely
        let sql = try ledger.fullLogicalEventsSQLUnlocked(hostname: "host-a")
        XCTAssertTrue(sql.contains("NOT INDEXED"))
    }
}
