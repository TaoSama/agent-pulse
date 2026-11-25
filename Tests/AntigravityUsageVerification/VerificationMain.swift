import AgentPulseCore
import Foundation
import SQLite3

private enum CheckFailure: Error {
    case failed(String)
    case sqlite
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw CheckFailure.failed(message) }
}

@main
struct AntigravityUsageVerification {
    private static let hostname = "antigravity-fixture-host"
    private static let fixtureModel = "fixture-model"
    private static let fixtureTime: UInt64 = 1_795_550_401

    static func main() throws {
        try verifyNativeDatabases()
        if ProcessInfo.processInfo.environment["AGENT_PULSE_VERIFY_LIVE_ANTIGRAVITY"] == "1" {
            try verifyLocalDatabases()
        }
        print("AntigravityUsageVerification passed")
    }

    private static func verifyNativeDatabases() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-pulse-antigravity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { NSLog("Could not remove Antigravity verification fixture") }
        }
        let desktop = scratch.appendingPathComponent("antigravity", isDirectory: true)
        let cli = scratch.appendingPathComponent("antigravity-cli", isDirectory: true)
        let missing = scratch.appendingPathComponent("antigravity-ide", isDirectory: true)
        let desktopDB = try fixtureDatabase(in: desktop, name: "test desktop?#")
        try insertGeneration(desktopDB, index: 1, response: "test mirror", input: 100)
        try require(sqlite3_close(desktopDB) == SQLITE_OK, "close desktop fixture")
        let cliDB = try fixtureDatabase(in: cli, name: "test cli")
        defer { sqlite3_close(cliDB) }
        try insertGeneration(cliDB, index: 1, response: "test mirror", input: 60)
        try insertGeneration(cliDB, index: 2, response: "test CLI call", input: 150)
        let malformedDB = try fixtureDatabase(in: cli, name: "malformed")
        defer { sqlite3_close(malformedDB) }
        try insertGeneration(malformedDB, index: 1, response: "test valid call in corrupt db", input: 80)
        try exec(malformedDB, "INSERT INTO gen_metadata VALUES (2, X'ff');")

        let ledgerPath = scratch.appendingPathComponent("usage.sqlite").path
        let ledger = try UsageLedgerStore(path: ledgerPath)
        let roots = [desktop, cli, missing]
        let first = try scan(roots, ledger)
        try require(first.discoveredDatabases == 3 && first.scannedDatabases == 2
                    && first.failedDatabases == 1 && first.failedDirectories == 0,
                    "live WAL, closed WAL and malformed databases must be distinguished")
        try require(first.observedEvents == 3, "collect native generations from both origins")
        let totals = try counts(ledger)
        try require(totals == UsageTokenCounts(input: 250, output: 24, cachedInput: 400,
                     cacheCreationInput: 10, reasoningOutput: 14, reportedTotal: 698),
                    "fold mirrored calls, preserve disjoint input/cache/response/reasoning")

        let reloadedLedger = try UsageLedgerStore(path: ledgerPath)
        let repeatRead = try scan(roots, reloadedLedger)
        try require(repeatRead.scannedDatabases == 0 && repeatRead.failedDatabases == 1,
                    "file stamps survive reopening and a corrupt source remains retryable")
        try require(try counts(reloadedLedger) == totals, "unchanged databases do not inflate usage")

        try insertGeneration(cliDB, index: 3, response: "test next CLI call", input: 200)
        try exec(malformedDB, "DELETE FROM gen_metadata WHERE idx=2;")
        let refreshed = try scan(roots, reloadedLedger)
        try require(refreshed.scannedDatabases == 2 && refreshed.failedDatabases == 0,
                    "detect append to live WAL and retry repaired source")
        try require(try counts(reloadedLedger).total == 1_426, "WAL append and repaired source each record once")

        try insertGeneration(cliDB, index: 4, response: "test mirror", input: 120,
                             model: "different-mirror-model", createdAt: fixtureTime + 3_600)
        _ = try scan(roots, reloadedLedger)
        try require(try counts(reloadedLedger).total == 1_446,
                    "improved mirror keeps the first persisted bucket key")

        let secondHost = "antigravity-new-host"
        try reloadedLedger.adoptHostname(secondHost)
        let unchangedAfterAdopt = try AntigravityUsageCollector.scanAndRecord(
            roots: roots, ledger: reloadedLedger, hostname: secondHost
        )
        try require(unchangedAfterAdopt.scannedDatabases == 0, "adopting a hostname should retain file stamps")
        try insertGeneration(cliDB, index: 5, response: "test new host", input: 40)
        _ = try AntigravityUsageCollector.scanAndRecord(roots: roots, ledger: reloadedLedger, hostname: secondHost)
        try require(try reloadedLedger.buckets(hostname: secondHost).first?.counts.total == 264,
                    "only new responses count under the adopted hostname")
        try require(try counts(reloadedLedger).total == 1_446, "prior host history remains")

        try freezeOldHost(in: ledgerPath)
        try insertGeneration(cliDB, index: 6, response: "test new host after freeze", input: 50,
                             createdAt: fixtureTime + 10_800)
        _ = try AntigravityUsageCollector.scanAndRecord(roots: roots, ledger: reloadedLedger, hostname: secondHost)
        let newBuckets = try reloadedLedger.buckets(hostname: secondHost)
        try require(newBuckets.reduce(0) { $0 + $1.counts.total } == 538,
                    "compacted raw events must not replay once their hostname changes")
        try require(try counts(reloadedLedger).total == 1_446, "prior host frozen bucket remains")

        let cancelledLedger = try UsageLedgerStore(path: ":memory:")
        var checks = 0
        do {
            _ = try AntigravityUsageCollector.scanAndRecord(roots: [desktop], ledger: cancelledLedger, hostname: hostname) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
            throw CheckFailure.failed("cancellation should propagate")
        } catch is CancellationError {
            try require(try cancelledLedger.buckets(hostname: hostname).isEmpty, "cancelled database must not commit")
        }
        try require(try scan([desktop], cancelledLedger).scannedDatabases == 1, "cancelled database remains retryable")
    }

    private static func verifyLocalDatabases() throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        let result = try scan(AntigravityUsageCollector.defaultRoots(), ledger)
        try require(result.failedDatabases == 0 && result.failedDirectories == 0 && result.observedEvents > 0,
                    "local Antigravity stores should yield valid measured usage")
        let totals = try ledger.summary()?.counts ?? UsageTokenCounts()
        print("Live Antigravity: \(result.scannedDatabases) DBs, \(result.observedEvents) observations, "
              + "input \(totals.input), cached \(totals.cachedInput), output \(totals.output), "
              + "reasoning \(totals.reasoningOutput), total \(totals.total)")
    }

    private static func scan(_ roots: [URL], _ ledger: UsageLedgerStore) throws -> AntigravityUsageScanResult {
        try AntigravityUsageCollector.scanAndRecord(roots: roots, ledger: ledger, hostname: hostname)
    }

    private static func counts(_ ledger: UsageLedgerStore) throws -> UsageTokenCounts {
        let buckets = try ledger.buckets(hostname: hostname)
        guard buckets.count == 1, let bucket = buckets.first,
              bucket.model == fixtureModel, bucket.source == AntigravityUsageCollector.source
        else { throw CheckFailure.failed("expected a single normalized Antigravity bucket") }
        return bucket.counts
    }

    private static func fixtureDatabase(in root: URL, name: String) throws -> OpaquePointer {
        let directory = root.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name + ".db")
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw CheckFailure.sqlite
        }
        do {
            try exec(database, """
                PRAGMA journal_mode=WAL;
                CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB);
                CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB, step_payload BLOB);
                """)
        } catch {
            sqlite3_close(database)
            throw error
        }
        return database
    }

    private static func freezeOldHost(in path: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(path, &database) == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw CheckFailure.sqlite
        }
        defer { sqlite3_close(database) }
        let cutoff = (fixtureTime / 1_800 + 3) * 1_800 * 1_000
        try exec(database, """
            DELETE FROM usage_events WHERE hostname='\(hostname)' AND source='antigravity';
            INSERT INTO sync_state VALUES ('frozen_before_ms' || char(1) || '\(hostname)', '\(cutoff)', 0);
            """)
    }

    private static func insertGeneration(
        _ database: OpaquePointer, index: UInt64, response: String, input: UInt64,
        model: String = fixtureModel, createdAt: UInt64? = nil
    ) throws {
        let usage = wire(2, input) + wire(3, 19) + wire(4, 5) + wire(5, 200)
            + wire(9, 7) + wire(10, 12) + wire(11, Array(response.utf8))
        let chat = wire(4, usage) + wire(22, Array(model.utf8)) + wire(28, [0xff, 0xff])
        let generation = wire(1, chat) + wire(2, varint(index))
        let timestamp = wire(1, wire(1, createdAt ?? fixtureTime + index) + wire(2, 123_456_789))
        try exec(database, """
            BEGIN;
            INSERT INTO steps VALUES (\(index), X'\(hex(timestamp))', X'ff');
            INSERT INTO gen_metadata VALUES (\(index), X'\(hex(generation))');
            COMMIT;
            """)
    }

    private static func hex(_ data: [UInt8]) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func wire(_ field: UInt64, _ value: UInt64) -> [UInt8] {
        varint(field << 3) + varint(value)
    }

    private static func wire(_ field: UInt64, _ bytes: [UInt8]) -> [UInt8] {
        varint((field << 3) | 2) + varint(UInt64(bytes.count)) + bytes
    }

    private static func varint(_ number: UInt64) -> [UInt8] {
        var value = number
        var bytes: [UInt8] = []
        while value >= 0x80 {
            bytes.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        bytes.append(UInt8(value))
        return bytes
    }

    private static func exec(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CheckFailure.sqlite }
    }
}
