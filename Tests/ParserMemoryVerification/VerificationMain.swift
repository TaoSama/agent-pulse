import AgentPulseCore
import Darwin
import Foundation
import SQLite3

private enum Failure: Error { case assertion(String) }
private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw Failure.assertion(message) }
}

private struct Options: Sendable {
    let scale: Int
    let observe: Bool
    static let mebibyte: UInt64 = 1_024 * 1_024
    static let hardLimit = 512 * mebibyte
    static let growthLimit = 128 * mebibyte

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let rawScale = environment["PARSER_MEMORY_SCALE"] ?? "1"
        guard let scale = Int(rawScale), (1...3).contains(scale) else {
            throw Failure.assertion("PARSER_MEMORY_SCALE must be 1, 2 or 3")
        }
        let rawObserve = environment["PARSER_MEMORY_OBSERVE"] ?? "0"
        try require(rawObserve == "0" || rawObserve == "1", "PARSER_MEMORY_OBSERVE must be 0 or 1")
        self.scale = scale
        observe = rawObserve == "1"
    }
}

@main
private enum ParserMemoryVerification {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("ParserMemoryVerification: FAIL \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let options = try Options()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("parser-memory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let fixture = try Fixture.create(root: root, scale: options.scale)
            // One dispatch work item deliberately spans every file and batch.
            // Per-file work items would drain autoreleases and hide the original failure.
            let queue = DispatchQueue(label: "parser-memory-verification", autoreleaseFrequency: .workItem)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try verify(fixture, options: options)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            do { try FileManager.default.removeItem(at: root) }
            catch { FileHandle.standardError.write(Data("fixture cleanup failed: \(error)\n".utf8)) }
            throw error
        }
    }

    private static func verify(_ fixture: Fixture, options: Options) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let ledger = try UsageLedgerStore(path: fixture.root.appendingPathComponent("usage.sqlite3").path)
        let observer = try DatabaseObserver(path: fixture.root.appendingPathComponent("usage.sqlite3").path)
        let probe = try Probe(options: options)
        var saved: [String: [String: UsageFileCheckpoint]] = [:]
        var manifests: [UsageScanManifest] = []
        for source in fixture.sources {
            let sourceStarted = ProcessInfo.processInfo.systemUptime
            let manifest = try UsageScanManifest.discover(source: source)
            try require(manifest.files.count == fixture.filesPerSource, "fixture discovery lost files")
            manifests.append(manifest)
            var checkpoints: [String: UsageFileCheckpoint] = [:]
            try scan(manifest, ledger: ledger, checkpoints: &checkpoints, probe: probe)
            let elapsed = ProcessInfo.processInfo.systemUptime - sourceStarted
            FileHandle.standardOutput.write(Data(("source=\(source.source) peakFootprint=\(probe.peak) "
                + "growth=\(probe.growth) elapsedSeconds=\(String(format: "%.3f", elapsed))\n").utf8))
            try verifyCheckpoints(manifest, checkpoints: checkpoints, ledger: ledger)
            saved[source.source] = checkpoints
        }
        try require(try ledger.eventCount() == fixture.expectedEvents, "token event count differs from generated fixture")
        try require(try ledger.sessionEventCount() == fixture.expectedSessionEvents, "session activity count differs from generated fixture")
        try require(try observer.scalar("SELECT SUM(input_tokens) FROM usage_events;") == Int64(fixture.expectedEvents * 10), "input tokens were lost or duplicated")
        try require(try observer.scalar("SELECT SUM(output_tokens) FROM usage_events;") == Int64(fixture.expectedEvents * 5), "output tokens were lost or duplicated")
        for manifest in manifests {
            let source = manifest.source.source
            let name = source == "codex" ? "rollout-long.jsonl" : "long.jsonl"
            guard let longFile = manifest.files.first(where: { $0.url.lastPathComponent == name }) else {
                throw Failure.assertion("long fixture file was not discovered")
            }
            // Use the discovered URL, including the system's temporary-path aliases.
            let fileID = UsageJSONLParser.fileID(for: UsageFileScanner.fileIdentity(for: longFile.url, source: source))
            try require(probe.advances[fileID, default: 0] >= 4, "long \(source) file did not exercise multiple committed batches")
        }

        let beforeVersion = try observer.scalar("PRAGMA data_version;")
        let beforeAdvances = probe.totalAdvances
        for manifest in manifests {
            var checkpoints = try ledger.checkpoints(source: manifest.source.source)
            guard let scanned = saved[manifest.source.source] else { throw Failure.assertion("missing scanner checkpoints") }
            try require(Set(checkpoints.keys) == Set(scanned.keys), "persisted checkpoint set differs from scanner checkpoint set")
            for (fileID, checkpoint) in scanned {
                guard let persisted = checkpoints[fileID] else { throw Failure.assertion("missing persisted checkpoint") }
                try require(checkpointsEqualAtStoragePrecision(persisted, checkpoint), "persisted checkpoint differs from scanner checkpoint")
            }
            let beforeUnchanged = checkpoints
            try scan(manifest, ledger: ledger, checkpoints: &checkpoints, probe: probe)
            try require(checkpoints == beforeUnchanged, "unchanged scan altered checkpoints")
        }
        try require(try observer.scalar("PRAGMA data_version;") == beforeVersion, "unchanged scan committed SQLite writes")
        try require(probe.totalAdvances == beforeAdvances, "unchanged scan parsed more batches")
        try require(try ledger.eventCount() == fixture.expectedEvents, "unchanged scan altered event count")
        try probe.sample(label: "unchanged-complete")
        print("ParserMemoryVerification: \(options.observe ? "OBSERVED (growth gate disabled)" : "PASS") "
              + "files=\(fixture.filesPerSource * 2) bytes=\(fixture.bytes) events=\(fixture.expectedEvents) "
              + "batchesObserved=\(probe.totalAdvances) peakFootprint=\(probe.peak) growth=\(probe.growth) "
              + "wallSeconds=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))")
    }

    private static func scan(_ manifest: UsageScanManifest, ledger: UsageLedgerStore,
                             checkpoints: inout [String: UsageFileCheckpoint], probe: Probe) throws {
        var index = 0
        var currentFileID: String?
        let present = try UsageFileScanner.scan(
            manifest: manifest, ledger: ledger, hostname: "parser-memory-fixture", checkpoints: &checkpoints,
            onFile: {
                let file = manifest.files[index]
                currentFileID = UsageJSONLParser.fileID(for: UsageFileScanner.fileIdentity(for: file.url, source: manifest.source.source))
                index += 1
            },
            checkCancellation: {
                // Only the observer's allocations are pooled here, never parsing.
                // A primary-key cursor lookup observes staged batch commits without loading the table.
                try autoreleasepool {
                    try probe.sample(label: "\(manifest.source.source)-file-\(index)")
                    if let currentFileID { try probe.observeCheckpoint(currentFileID, ledger: ledger) }
                }
            }
        )
        try require(present.count == manifest.files.count, "scanner did not visit every file")
        for fileID in present { try probe.observeCheckpoint(fileID, ledger: ledger) }
        try probe.sample(label: "\(manifest.source.source)-files-complete")
    }

    private static func verifyCheckpoints(_ manifest: UsageScanManifest,
                                          checkpoints: [String: UsageFileCheckpoint], ledger: UsageLedgerStore) throws {
        for file in manifest.files {
            let fileID = UsageJSONLParser.fileID(for: UsageFileScanner.fileIdentity(for: file.url, source: manifest.source.source))
            guard let checkpoint = checkpoints[fileID] else { throw Failure.assertion("missing checkpoint") }
            try require(checkpoint.status == "complete" && checkpoint.offset == file.size && checkpoint.size == file.size,
                        "checkpoint did not reach the complete file boundary")
            try require(checkpoint.parserVersion == UsageJSONLParser.parserVersion, "checkpoint parser version mismatch")
            guard let persisted = try ledger.checkpoint(fileID: fileID) else { throw Failure.assertion("missing persisted checkpoint") }
            try require(checkpointsEqualAtStoragePrecision(persisted, checkpoint), "checkpoint was not durably persisted")
        }
    }

    private static func checkpointsEqualAtStoragePrecision(_ lhs: UsageFileCheckpoint, _ rhs: UsageFileCheckpoint) -> Bool {
        // SQLite stores modification time as rounded epoch milliseconds.
        lhs.fileID == rhs.fileID && lhs.source == rhs.source && lhs.pathHash == rhs.pathHash
            && lhs.offset == rhs.offset && lhs.size == rhs.size && lhs.parserVersion == rhs.parserVersion
            && lhs.status == rhs.status
            && (lhs.modifiedAt.timeIntervalSince1970 * 1_000).rounded()
                == (rhs.modifiedAt.timeIntervalSince1970 * 1_000).rounded()
    }
}

private final class Probe {
    let options: Options
    let baseline: UInt64
    var peak: UInt64
    var offsets: [String: Int64] = [:]
    var advances: [String: Int] = [:]
    var totalAdvances: Int { advances.values.reduce(0, +) }
    var growth: UInt64 { peak > baseline ? peak - baseline : 0 }

    init(options: Options) throws {
        self.options = options
        baseline = try Self.footprint()
        peak = baseline
        try sample(label: "baseline")
    }

    func sample(label: String) throws {
        peak = max(peak, try Self.footprint())
        try require(peak <= Options.hardLimit, "physical footprint safety limit exceeded at \(label): \(peak) > \(Options.hardLimit)")
        if !options.observe {
            try require(growth <= Options.growthLimit, "physical footprint growth exceeded at \(label): \(growth) > \(Options.growthLimit)")
        }
    }

    func observeCheckpoint(_ fileID: String, ledger: UsageLedgerStore) throws {
        // Initial scans keep the public checkpoint untouched until publication.
        // parserState reads the committed replacement stage while it is active.
        struct CursorOffset: Decodable { let offset: Int64 }
        guard let data = try ledger.parserState(fileID: fileID, key: "stream-cursor") else { return }
        let cursor = try JSONDecoder().decode(CursorOffset.self, from: data)
        if cursor.offset > offsets[fileID, default: 0] {
            offsets[fileID] = cursor.offset
            advances[fileID, default: 0] += 1
        }
    }

    private static func footprint() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try require(status == KERN_SUCCESS, "TASK_VM_INFO failed: \(status)")
        guard let peakOffset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak) else {
            throw Failure.assertion("TASK_VM_INFO peak field layout is unavailable")
        }
        let requiredBytes = peakOffset + MemoryLayout.size(ofValue: info.ledger_phys_footprint_peak)
        try require(Int(count) * MemoryLayout<integer_t>.size >= requiredBytes,
                    "TASK_VM_INFO does not expose the physical footprint peak")
        return max(info.phys_footprint, UInt64(max(0, info.ledger_phys_footprint_peak)))
    }
}

private struct Fixture: Sendable {
    let root: URL
    let sources: [UsageScanRoot]
    let filesPerSource: Int
    let expectedEvents: Int
    let expectedSessionEvents: Int
    let bytes: Int64

    static func create(root: URL, scale: Int) throws -> Fixture {
        let smallFiles = 32
        let longGroups = 4_000 * scale
        let smallGroups = 100 * scale
        let sources = [UsageScanRoot(root: root.appendingPathComponent("codex"), source: "codex"),
                       UsageScanRoot(root: root.appendingPathComponent("claude"), source: "claude-code")]
        var bytes: Int64 = 0
        for source in sources {
            try FileManager.default.createDirectory(at: source.root, withIntermediateDirectories: false)
            for index in 0...smallFiles {
                try autoreleasepool {
                    let name = index == 0 ? "long" : "small-\(index)"
                    let file = source.root.appendingPathComponent(source.source == "codex" ? "rollout-\(name).jsonl" : "\(name).jsonl")
                    bytes += try write(file: file, codex: source.source == "codex", groups: index == 0 ? longGroups : smallGroups)
                }
            }
        }
        let groupsPerSource = longGroups + smallFiles * smallGroups
        return Fixture(root: root, sources: sources, filesPerSource: smallFiles + 1,
                       expectedEvents: groupsPerSource * 2,
                       expectedSessionEvents: groupsPerSource * 5 + smallFiles + 1, bytes: bytes)
    }

    private static func write(file: URL, codex: Bool, groups: Int) throws -> Int64 {
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { do { try handle.close() } catch { FileHandle.standardError.write(Data("fixture close failed: \(error)\n".utf8)) } }
        let session = file.deletingPathExtension().lastPathComponent
        let timestamp = "2026-09-01T12:00:00.123Z"
        let body = String(repeating: "x", count: 4_096)
        var bytes: Int64 = 0
        if codex {
            let data = Data("{\"type\":\"session_meta\",\"timestamp\":\"\(timestamp)\",\"payload\":{\"id\":\"\(session)\",\"cwd\":\"/fixture/project\"}}\n".utf8)
            try handle.write(contentsOf: data); bytes += Int64(data.count)
        }
        for index in 0..<groups {
            try autoreleasepool {
                let id = "\(session)-\(index)"
                let rows: String
                if codex {
                    rows = """
                    {"type":"turn_context","timestamp":"\(timestamp)","payload":{"turn_id":"\(id)","model":"gpt-5"}}
                    {"type":"response_item","timestamp":"\(timestamp)","payload":{"type":"message","id":"\(id)","role":"assistant","content":[{"type":"output_text","text":"\(body)"}]}}
                    {"type":"event_msg","timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"model":"gpt-5","last_token_usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}}}
                    """
                } else {
                    rows = """
                    {"type":"user","uuid":"user-\(id)","sessionId":"\(session)","timestamp":"\(timestamp)","message":{"role":"user","content":"question"}}
                    {"type":"assistant","uuid":"assistant-\(id)","sessionId":"\(session)","timestamp":"\(timestamp)","message":{"id":"\(id)","model":"claude-opus-4","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"text","text":"\(body)"}]}}
                    """
                }
                let data = Data((rows + "\n").utf8)
                try handle.write(contentsOf: data); bytes += Int64(data.count)
            }
        }
        return bytes
    }
}

private final class DatabaseObserver {
    private let db: OpaquePointer
    init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw Failure.assertion("unable to open fixture observer")
        }
        db = handle
    }
    deinit { sqlite3_close(db) }

    func scalar(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw Failure.assertion("unable to prepare fixture observation")
        }
        defer { sqlite3_finalize(statement) }
        try require(sqlite3_step(statement) == SQLITE_ROW, "unable to read fixture observation")
        return sqlite3_column_int64(statement, 0)
    }
}
