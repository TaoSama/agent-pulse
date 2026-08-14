import XCTest
@testable import AgentPulseCore

/// 测试内部使用的持久化模型，仅在测试目标内可见(private)，不进入正式模块。
private struct SampleSnapshot: SnapshotPersistable, Equatable {
    let id: UUID
    let timestamp: Date
    let storageSource: String
    let tps: Double?
    let completedTaskCount: Int?
    let quality: String
    var sourceIdentifier: String? { storageSource }
}

final class SQLiteSnapshotStoreTests: XCTestCase {
    private static let ownerOnlyPermissions = 0o600

    private func makeStore() throws -> SQLiteSnapshotStore {
        try SQLiteSnapshotStore(path: ":memory:")
    }

    private func snap(_ id: UUID = UUID(), at seconds: TimeInterval, source: String = "codex-cli",
                      tps: Double? = nil, completed: Int? = nil, quality: String = "complete") -> SampleSnapshot {
        SampleSnapshot(id: id, timestamp: Date(timeIntervalSince1970: seconds), storageSource: source,
                       tps: tps, completedTaskCount: completed, quality: quality)
    }

    func testRoundtripPreservesAllFields() throws {
        let store = try makeStore()
        let original = snap(at: 1000, source: "codex-desktop", tps: 42.5, completed: 7, quality: "partial")
        try store.upsert(original)
        let loaded = try store.query(SampleSnapshot.self)
        XCTAssertEqual(loaded, [original])
    }

    func testUpsertReplacesSamePrimaryKey() throws {
        let store = try makeStore()
        let id = UUID()
        try store.upsert(snap(id, at: 1000, tps: 1))
        try store.upsert(snap(id, at: 2000, tps: 2))
        let loaded = try store.query(SampleSnapshot.self)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.tps, 2)
        XCTAssertEqual(loaded.first?.timestamp, Date(timeIntervalSince1970: 2000))
    }

    func testRangeQueryIsInclusiveAndOrdered() throws {
        let store = try makeStore()
        try store.upsert(contentsOf: [snap(at: 300), snap(at: 100), snap(at: 200)])
        let range = SnapshotTimeRange(start: Date(timeIntervalSince1970: 100),
                                      end: Date(timeIntervalSince1970: 200))
        let loaded = try store.query(SampleSnapshot.self, in: range)
        XCTAssertEqual(loaded.map { $0.timestamp.timeIntervalSince1970 }, [100, 200])
    }

    func testRangeQueryReversedBoundsNormalized() throws {
        let store = try makeStore()
        try store.upsert(snap(at: 150))
        let range = SnapshotTimeRange(start: Date(timeIntervalSince1970: 300),
                                      end: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try store.query(SampleSnapshot.self, in: range).count, 1)
    }

    func testSourceFilter() throws {
        let store = try makeStore()
        try store.upsert(snap(at: 100, source: "codex-cli"))
        try store.upsert(snap(at: 200, source: "codex-desktop"))
        let loaded = try store.query(SampleSnapshot.self, source: "codex-desktop")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.sourceIdentifier, "codex-desktop")
    }

    func testDeleteOlderThanRetention() throws {
        let store = try makeStore()
        try store.upsert(contentsOf: [snap(at: 100), snap(at: 200), snap(at: 300)])
        let deleted = try store.deleteSnapshots(olderThan: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(deleted, 1)
        XCTAssertEqual(try store.count(), 2)
        let remaining = try store.query(SampleSnapshot.self).map { $0.timestamp.timeIntervalSince1970 }
        XCTAssertEqual(remaining, [200, 300])
    }

    func testEnforceRetentionKeepsMostRecent() throws {
        let store = try makeStore()
        for t in stride(from: 100.0, through: 500.0, by: 100.0) {
            try store.upsert(snap(at: t))
        }
        let deleted = try store.enforceRetention(maxCount: 2)
        XCTAssertEqual(deleted, 3)
        let remaining = try store.query(SampleSnapshot.self).map { $0.timestamp.timeIntervalSince1970 }
        XCTAssertEqual(remaining, [400, 500])
    }

    func testEnforceRetentionZeroClearsAll() throws {
        let store = try makeStore()
        try store.upsert(snap(at: 100))
        XCTAssertEqual(try store.enforceRetention(maxCount: 0), 1)
        XCTAssertEqual(try store.count(), 0)
    }

    func testEnforceRetentionNegativeThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.enforceRetention(maxCount: -1))
    }

    func testEmptyQueryReturnsEmpty() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.query(SampleSnapshot.self).count, 0)
        XCTAssertEqual(try store.count(), 0)
    }

    func testConcurrentWritesAreThreadSafe() throws {
        let store = try makeStore()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "test.concurrent", attributes: .concurrent)
        for i in 0..<50 {
            group.enter()
            queue.async {
                do { try store.upsert(self.snap(at: Double(i))) } catch { XCTFail("upsert failed: \(error)") }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try store.count(), 50)
    }

    func testFilePersistenceRoundtrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("snapshots.sqlite").path
        let expected = snap(at: 4242, tps: 3.14, completed: 9, quality: "unavailable")
        do {
            let store = try SQLiteSnapshotStore(path: dbPath)
            try store.upsert(expected)
        }
        let reopened = try SQLiteSnapshotStore(path: dbPath)
        XCTAssertEqual(try reopened.query(SampleSnapshot.self), [expected])
    }

    func testDiskDatabaseAndSidecarsUseOwnerOnlyPermissionsOnCreateAndReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentpulse-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databasePath = directory.appendingPathComponent("snapshots.sqlite").path
        let paths = [databasePath, databasePath + "-wal", databasePath + "-shm"]
        let original = try SQLiteSnapshotStore(path: databasePath)
        try original.upsert(snap(at: 1234))
        try assertOwnerOnlyPermissions(paths: paths)

        for path in paths {
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)],
                ofItemAtPath: path
            )
        }
        let reopened = try SQLiteSnapshotStore(path: databasePath)
        XCTAssertEqual(try reopened.count(), 1)
        try assertOwnerOnlyPermissions(paths: paths)
    }

    func testOpenInvalidPathThrows() {
        XCTAssertThrowsError(try SQLiteSnapshotStore(path: "/nonexistent-\(UUID().uuidString)/x/db.sqlite")) { error in
            guard case SQLiteSnapshotStoreError.openFailed = error else {
                return XCTFail("expected openFailed, got \(error)")
            }
        }
    }

    private func assertOwnerOnlyPermissions(paths: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for path in paths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), "missing SQLite file: \(path)", file: file, line: line)
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber, file: file, line: line)
            XCTAssertEqual(
                permissions.intValue & 0o777,
                Self.ownerOnlyPermissions,
                "unexpected permissions for \(path)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - 真实 PulseSnapshot 模型集成

    func testRealPulseSnapshotRoundtrip() throws {
        let store = try makeStore()
        let snapshot = PulseSnapshot(
            timestamp: Date(timeIntervalSince1970: 12345),
            source: .cli,
            status: .generating,
            tps: 88.25,
            tokenCount: 4096,
            completedTaskCount: 37,
            completedCountQuality: .partial,
            note: "collected"
        )
        try store.upsert(snapshot)
        let loaded = try store.query(PulseSnapshot.self)
        XCTAssertEqual(loaded, [snapshot])
        XCTAssertEqual(loaded.first?.completedTaskCount, 37)
        XCTAssertEqual(loaded.first?.completedCountQuality, .partial)
        XCTAssertEqual(loaded.first?.completedIsLowerBound, true)
    }

    func testRealPulseSnapshotSourceFilterAndRange() throws {
        let store = try makeStore()
        let desktop = PulseSnapshot(timestamp: Date(timeIntervalSince1970: 100), source: .desktop, status: .idle)
        let cli = PulseSnapshot(timestamp: Date(timeIntervalSince1970: 200), source: .cli, status: .idle)
        try store.upsert(contentsOf: [desktop, cli])
        let onlyCli = try store.query(PulseSnapshot.self, source: PulseSource.cli.rawValue)
        XCTAssertEqual(onlyCli, [cli])
        let range = SnapshotTimeRange(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(try store.query(PulseSnapshot.self, in: range), [desktop])
    }

    func testRealDegradedSnapshotPreservesReason() throws {
        let store = try makeStore()
        let degraded = PulseSnapshot.degraded(
            source: .desktop,
            timestamp: Date(timeIntervalSince1970: 999),
            reason: .permissionDenied(path: "/redacted")
        )
        try store.upsert(degraded)
        let loaded = try store.query(PulseSnapshot.self)
        XCTAssertEqual(loaded, [degraded])
        XCTAssertEqual(loaded.first?.status, .degraded)
        XCTAssertEqual(loaded.first?.degradedReason, .permissionDenied(path: "/redacted"))
        XCTAssertNotNil(loaded.first?.note)
    }
}
