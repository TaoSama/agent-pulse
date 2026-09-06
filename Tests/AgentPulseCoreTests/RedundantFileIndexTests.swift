import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class RedundantFileIndexTests: XCTestCase {
    func testFilePrimaryKeyKeepsHostScopedMissingLookupsSelective() throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        try ledger.prepareForUsageScan()
        try ledger.exec("""
            CREATE TEMP TABLE temp_usage_dirty_files(file_id TEXT PRIMARY KEY) WITHOUT ROWID;
            DROP INDEX IF EXISTS idx_usage_events_host_file;
            """)
        for projection in ["e.source,e.event_id", "e.source,e.session_hash", "e.source,e.model,e.project,e.timestamp_ms"] {
            let statement = try ledger.prepare("""
                EXPLAIN QUERY PLAN SELECT DISTINCT \(projection)
                FROM temp_usage_dirty_files f
                CROSS JOIN usage_events e INDEXED BY sqlite_autoindex_usage_events_1
                ON e.hostname=? AND e.source_file_hash=f.file_id;
                """)
            defer { sqlite3_finalize(statement) }
            try ledger.bind(statement, 1, "host")
            var plan: [String] = []
            while try ledger.step(statement) == SQLITE_ROW { plan.append(ledger.text(statement, 3)) }
            XCTAssertTrue(plan.contains { $0.contains("SEARCH e USING INDEX sqlite_autoindex_usage_events_1 (source_file_hash=?)") }, "\(plan)")
            XCTAssertFalse(plan.contains { $0.contains("SCAN e") }, "\(plan)")
        }
    }

    func testHostDedupQueryPlansSurviveLegacyIndexRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dedup-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("usage.sqlite3").path
        func plans(_ ledger: UsageLedgerStore) throws -> [[String]] {
            try ["lineage_fingerprint", "codex_dedup_key"].map { column in
                let statement = try ledger.prepare("""
                    EXPLAIN QUERY PLAN SELECT source,event_id FROM usage_events
                    WHERE hostname=? AND \(column)=? AND \(column)<>'';
                    """)
                defer { sqlite3_finalize(statement) }
                try ledger.bind(statement, 1, "host"); try ledger.bind(statement, 2, "identity")
                var result: [String] = []
                while try ledger.step(statement) == SQLITE_ROW { result.append(ledger.text(statement, 3)) }
                return result
            }
        }
        let before: [[String]] = try autoreleasepool {
            let ledger = try UsageLedgerStore(path: path)
            try ledger.prepareForUsageScan()
            try ledger.exec("""
                CREATE INDEX idx_usage_events_lineage ON usage_events(lineage_fingerprint);
                CREATE INDEX idx_usage_events_dedup ON usage_events(codex_dedup_key);
                """)
            return try plans(ledger)
        }
        let ledger = try UsageLedgerStore(path: path)
        try ledger.prepareForUsageScan()
        let after = try plans(ledger)
        XCTAssertEqual(before, after)
        for (plan, index) in zip(after, ["idx_usage_events_host_lineage", "idx_usage_events_host_content"]) {
            XCTAssertTrue(plan.contains { $0.contains("USING COVERING INDEX \(index)") }, "\(plan)")
            XCTAssertFalse(plan.contains { $0.contains("SCAN usage_events") }, "\(plan)")
        }
    }

    func testBackgroundPreparationReclaimsOnlyRedundantFileIndexes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("file-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let ledger = try UsageLedgerStore(path: root.appendingPathComponent("usage.sqlite3").path)
        try ledger.exec("CREATE INDEX IF NOT EXISTS idx_usage_events_file ON usage_events(source_file_hash);")
        try ledger.exec("CREATE INDEX IF NOT EXISTS idx_usage_events_host_file ON usage_events(hostname,source_file_hash);")
        try ledger.exec("CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_file ON usage_edit_entries(source_file_hash);")
        try ledger.prepareForUsageScan()
        for table in ["usage_events", "usage_edit_entries"] {
            let statement = try ledger.prepare("EXPLAIN QUERY PLAN DELETE FROM \(table) WHERE source_file_hash=?;")
            defer { sqlite3_finalize(statement) }
            try ledger.bind(statement, 1, "fixture")
            var plan: [String] = []
            while try ledger.step(statement) == SQLITE_ROW { plan.append(ledger.text(statement, 3)) }
            XCTAssertTrue(plan.contains { $0.contains("SEARCH \(table)") && $0.contains("sqlite_autoindex_\(table)_1") }, "\(table): \(plan)")
            XCTAssertFalse(plan.contains { $0.contains("SCAN \(table)") })
        }
        let indexes = try ledger.prepare("SELECT name FROM sqlite_master WHERE type='index';")
        defer { sqlite3_finalize(indexes) }
        var names = Set<String>()
        while try ledger.step(indexes) == SQLITE_ROW { names.insert(ledger.text(indexes, 0)) }
        XCTAssertFalse(names.contains("idx_usage_events_file"))
        XCTAssertFalse(names.contains("idx_usage_edit_entries_file"))
        XCTAssertFalse(names.contains("idx_usage_events_lineage"))
        XCTAssertFalse(names.contains("idx_usage_events_dedup"))
        // Session's file column is not a leading primary-key column.
        XCTAssertTrue(names.contains("idx_session_events_file"))
        XCTAssertFalse(names.contains("idx_usage_events_host_file"))
        XCTAssertTrue(names.contains("idx_usage_events_time"))
    }
}
