import AgentPulseCore
import Foundation
import SQLite3

extension AntigravityUsageVerification {
    static func verifyCompactedReplays() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-pulse-antigravity-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: scratch) }
            catch { NSLog("Could not remove the Antigravity replay fixture") }
        }
        let root = scratch.appendingPathComponent("antigravity", isDirectory: true)
        let database = try fixtureDatabase(in: root, name: "replay")
        defer { sqlite3_close(database) }
        let now = UInt64(Date().timeIntervalSince1970)
        let historical = now - 45 * 24 * 60 * 60
        try insertGeneration(database, index: 1, response: "compacted", input: 10, createdAt: historical)
        try insertGeneration(database, index: 2, response: "retained", input: 20, createdAt: now)

        let path = scratch.appendingPathComponent("usage.sqlite").path
        let original = try UsageLedgerStore(path: path)
        let oldHost = "original-antigravity-host"
        let newHost = "adopted-antigravity-host"
        _ = try AntigravityUsageCollector.scanAndRecord(roots: [root], ledger: original, hostname: oldHost)
        try requireReplay(try !original.hasAntigravityTranscriptHistory(),
                          "a native checkpoint does not claim transcript history")
        let before = try original.buckets(hostname: oldHost)
        let compacted = try original.compactFrozenRaw(hostname: oldHost)
        try requireReplay(compacted.deletedRows == 1 && (try original.eventCount()) == 1,
                          "compaction must delete the historical raw generation")
        try original.adoptHostname(newHost)

        try insertGeneration(database, index: 3, response: "compacted", input: 100, createdAt: now + 3_600)
        try insertGeneration(database, index: 4, response: "retained", input: 200, createdAt: now + 7_200)
        try insertGeneration(database, index: 5, response: "new history", input: 30, createdAt: historical - 3_600)
        let reopened = try UsageLedgerStore(path: path)
        _ = try AntigravityUsageCollector.scanAndRecord(roots: [root], ledger: reopened, hostname: newHost)
        let newBuckets = try reopened.buckets(hostname: newHost)
        let oldBuckets = try reopened.buckets(hostname: oldHost)
        try requireReplay(newBuckets.count == 1 && newBuckets.first?.counts.input == 30
                          && oldBuckets == before && (try reopened.eventCount()) == 2,
                          "only the unseen historical response should move totals after the hostname changes")
        try reopened.record(events: [], checkpoint: UsageFileCheckpoint(
            fileID: "legacy-transcript", source: AntigravityUsageCollector.source, pathHash: "fixture",
            offset: 10, size: 10, modifiedAt: Date(), parserVersion: UsageJSONLParser.parserVersion,
            status: "missing"
        ), hostname: newHost)
        try requireReplay(try reopened.hasAntigravityTranscriptHistory(),
                          "a legacy transcript checkpoint claims history even when its file is missing")
    }

    private static func requireReplay(_ assertion: Bool, _ message: String) throws {
        guard assertion else { throw NSError(domain: message, code: 1) }
    }
}
