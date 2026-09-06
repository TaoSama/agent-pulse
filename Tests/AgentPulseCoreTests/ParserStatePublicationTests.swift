import Foundation
import SQLite3
import XCTest
@testable import AgentPulseCore

final class ParserStatePublicationTests: XCTestCase {
    func testParserStateEncodingIsStableAndReadsLegacyJSON() throws {
        let legacy = Data(#"{"z":1,"a":2}"#.utf8)
        let first = UsageParserState(lookup: { _ in legacy })
        XCTAssertEqual(first.read("map", as: [String: Int].self), ["a": 2, "z": 1])
        first.write(["z": 1, "a": 2], key: "map")
        let second = UsageParserState()
        second.write(["a": 2, "z": 1], key: "map")
        XCTAssertEqual(try first.changes().values["map"], try second.changes().values["map"])
        XCTAssertEqual(try first.changes().values["map"], Data(#"{"a":2,"z":1}"#.utf8))
    }

    func testRepeatedAppendStateDoesNotRewriteDurableValue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("append-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let ledger = try UsageLedgerStore(path: root.appendingPathComponent("usage.sqlite3").path)
        let checkpoint = UsageFileCheckpoint(fileID: "file", source: "codex", pathHash: "file",
            offset: 1, size: 1, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete")
        func write(_ value: UInt8) throws {
            let batch = UsageIncrementalBatch(parsed: ParsedUsageFile(events: [], sessionEvents: [],
                checkpoint: checkpoint, diagnostics: []),
                stateChanges: UsageParserStateChanges(values: ["key": Data([value])], removedKeys: []),
                removedEventIDs: [], removedEditIDs: [], replacesFile: false, isFinalBatch: true)
            try ledger.recordIncremental(batch: batch, hostname: "host")
        }
        try write(1)
        try ledger.exec("""
            CREATE TEMP TABLE state_writes(value INTEGER);
            CREATE TEMP TRIGGER state_insert AFTER INSERT ON main.usage_parser_state
              BEGIN INSERT INTO state_writes VALUES(1); END;
            CREATE TEMP TRIGGER state_update AFTER UPDATE ON main.usage_parser_state
              BEGIN INSERT INTO state_writes VALUES(1); END;
            """)
        try write(1)
        let count = try ledger.prepare("SELECT COUNT(*) FROM state_writes;")
        defer { sqlite3_finalize(count) }
        XCTAssertEqual(try ledger.step(count), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(count, 0), 0)
        sqlite3_reset(count)
        try write(2)
        XCTAssertEqual(try ledger.step(count), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(count, 0), 1)
        XCTAssertEqual(try ledger.parserState(fileID: "file", key: "key"), Data([2]))
    }

    func testStatePublicationSkipsIdenticalValuesAndKeepsOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("state-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let ledger = try UsageLedgerStore(path: root.appendingPathComponent("usage.sqlite3").path)
        try ledger.exec("""
            INSERT INTO usage_parser_state VALUES
              ('a','same',X'01'),('a','changed',X'02'),('a','removed',X'03'),('b','other',X'04');
            INSERT INTO temp.usage_parser_stage VALUES
              ('a','state','same',X'01'),('a','state','changed',X'05'),('a','state','new',X'06'),
              ('a','event','ignored',X'07');
            """)
        let before = sqlite3_total_changes64(ledger.db)
        try ledger.transaction { try ledger.publishParserStateDifferentialUnlocked(fileID: "a") }
        XCTAssertEqual(sqlite3_total_changes64(ledger.db) - before, 3)
        XCTAssertEqual(try ledger.parserState(fileID: "a", key: "same"), Data([1]))
        XCTAssertEqual(try ledger.parserState(fileID: "a", key: "changed"), Data([5]))
        XCTAssertEqual(try ledger.parserState(fileID: "a", key: "new"), Data([6]))
        XCTAssertNil(try ledger.parserState(fileID: "a", key: "removed"))
        XCTAssertNil(try ledger.parserState(fileID: "a", key: "ignored"))
        XCTAssertEqual(try ledger.parserState(fileID: "b", key: "other"), Data([4]))
        let after = sqlite3_total_changes64(ledger.db)
        try ledger.transaction { try ledger.publishParserStateDifferentialUnlocked(fileID: "a") }
        XCTAssertEqual(sqlite3_total_changes64(ledger.db), after)
    }
}
