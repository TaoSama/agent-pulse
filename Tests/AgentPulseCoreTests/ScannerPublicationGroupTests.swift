import Foundation
import XCTest
@testable import AgentPulseCore

final class ScannerPublicationGroupTests: XCTestCase {
    private func fixture(count: Int) throws -> UsageScanManifest {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scanner-groups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        for file in 0..<count {
            let rows: [[String: Any]] = [
                ["type": "session_meta", "timestamp": "2026-08-01T00:00:00Z", "payload": ["id": "session-\(file)"]],
                ["type": "event_msg", "timestamp": "2026-08-01T00:00:01Z", "payload": [
                    "type": "token_count", "info": ["last_token_usage": ["input_tokens": 10, "output_tokens": 2, "total_tokens": 12]],
                ]],
            ]
            var data = Data()
            for row in rows {
                data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
                data.append(0x0A)
            }
            let url = root.appendingPathComponent("rollout-group-\(file).jsonl")
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: url.path)
        }
        return try UsageScanManifest.discover(source: UsageScanRoot(root: root, source: "codex"))
    }

    func testCancellationDiscardsReadyFilesWithoutAdvancingCheckpoints() throws {
        let manifest = try fixture(count: 3)
        let ledger = try UsageLedgerStore(path: ":memory:")
        var checkpoints: [String: UsageFileCheckpoint] = [:]
        var visited = 0
        XCTAssertThrowsError(try UsageFileScanner.scan(manifest: manifest, ledger: ledger, hostname: "host",
            checkpoints: &checkpoints, onFile: { visited += 1 }, checkCancellation: {
                if visited == 2 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertTrue(checkpoints.isEmpty)
        XCTAssertTrue(try ledger.checkpoints(source: "codex").isEmpty)
        XCTAssertEqual(try ledger.eventCount(), 0)
        try UsageFileScanner.scan(manifest: manifest, ledger: ledger, hostname: "host", checkpoints: &checkpoints)
        XCTAssertEqual(checkpoints.count, 3)
        XCTAssertEqual(try ledger.eventCount(), 3)
    }

    func testRepeatedFileFlushesBeforeRevisitingItsIdentity() throws {
        let original = try fixture(count: 1)
        let file = try XCTUnwrap(original.files.first)
        let manifest = UsageScanManifest(source: original.source, files: [file, file])
        let ledger = try UsageLedgerStore(path: ":memory:")
        var checkpoints: [String: UsageFileCheckpoint] = [:]
        try UsageFileScanner.scan(manifest: manifest, ledger: ledger, hostname: "host", checkpoints: &checkpoints)
        XCTAssertEqual(checkpoints.count, 1)
        XCTAssertEqual(try ledger.eventCount(), 1)
        XCTAssertEqual(checkpoints, try ledger.checkpoints(source: "codex"))
    }

    func testCapacityFlushAndRemainderMatchImmediatePublication() throws {
        let manifest = try fixture(count: 9)
        let grouped = try UsageLedgerStore(path: ":memory:")
        let immediate = try UsageLedgerStore(path: ":memory:")
        var checkpoints: [String: UsageFileCheckpoint] = [:]
        try UsageFileScanner.scan(manifest: manifest, ledger: grouped, hostname: "host", checkpoints: &checkpoints)
        for file in manifest.files {
            let identity = UsageFileScanner.fileIdentity(for: file.url, source: "codex")
            let fileID = UsageJSONLParser.fileID(for: identity)
            _ = try UsageJSONLParser.readIncrementally(fileURL: file.url, source: "codex", fileIdentity: identity,
                previousCheckpoint: nil, stateLookup: { try immediate.parserState(fileID: fileID, key: $0) },
                onBatch: { try immediate.recordIncremental(batch: $0, hostname: "host") })
        }
        XCTAssertEqual(checkpoints.count, 9)
        XCTAssertEqual(checkpoints, try grouped.checkpoints(source: "codex"))
        XCTAssertEqual(checkpoints, try immediate.checkpoints(source: "codex"))
        XCTAssertEqual(try grouped.eventCount(), try immediate.eventCount())
        XCTAssertEqual(try grouped.sessionEventCount(), try immediate.sessionEventCount())
        XCTAssertEqual(try grouped.eventCount(), 9)
    }

    func testReadyReplacementAndDurableAppendCanInterleave() throws {
        let manifest = try fixture(count: 2)
        let first = manifest.files[0]
        let ledger = try UsageLedgerStore(path: ":memory:")
        var checkpoints: [String: UsageFileCheckpoint] = [:]
        try UsageFileScanner.scan(manifest: UsageScanManifest(source: manifest.source, files: [first]),
            ledger: ledger, hostname: "host", checkpoints: &checkpoints)
        let line = #"{"type":"event_msg","timestamp":"2026-08-01T00:00:02Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":3,"total_tokens":23}}}}"# + "\n"
        let handle = try FileHandle(forWritingTo: first.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_001)], ofItemAtPath: first.url.path)
        let updated = try UsageScanManifest.discover(source: manifest.source)
        let appended = try XCTUnwrap(updated.files.first { $0.url == first.url })
        let replacement = try XCTUnwrap(updated.files.first { $0.url != first.url })
        try UsageFileScanner.scan(manifest: UsageScanManifest(source: manifest.source, files: [replacement, appended]),
            ledger: ledger, hostname: "host", checkpoints: &checkpoints)
        XCTAssertEqual(checkpoints.count, 2)
        XCTAssertEqual(checkpoints, try ledger.checkpoints(source: "codex"))
        XCTAssertEqual(try ledger.eventCount(), 3)
    }
}
