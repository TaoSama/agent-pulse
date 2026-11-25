import AgentPulseCore
import Foundation
import SQLite3

enum AntigravityTaskVerification {
    private enum Failure: Error {
        case assertion(String)
        case sqlite(Int32)
    }

    private final class Scanner: ProcessScanning, @unchecked Sendable {
        private let lock = NSLock()
        private var processes: [RunningProcess] = []

        func replace(with next: [RunningProcess]) {
            lock.withLock { processes = next }
        }

        func scan() throws -> [RunningProcess] {
            lock.withLock { processes }
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-tasks-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { NSLog("Antigravity task fixture cleanup failed") }
        }
        let stores = try ["antigravity", "antigravity-cli", "antigravity-ide"].map { name in
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            return directory.appendingPathComponent("conversation_summaries.db")
        }
        let desktop = try open(stores[0])
        defer { sqlite3_close(desktop) }
        let cli = try open(stores[1])
        defer { sqlite3_close(cli) }
        let schema = """
                PRAGMA journal_mode = WAL;
                CREATE TABLE conversation_summaries (
                    conversation_id TEXT PRIMARY KEY, last_modified_time TEXT, killed INTEGER,
                    not_fully_idle INTEGER, status TEXT, source TEXT,
                    nesting_depth INTEGER, parent_conversation_id TEXT, step_count INTEGER
                );
                """
        for db in [desktop, cli] { try exec(db, schema) }
        try seedClosedProfile(at: stores[2], schema: schema)
        try exec(desktop, """
            INSERT INTO conversation_summaries VALUES
              ('mirror', '2026-11-25 12:00:00.001+00:00', 0, 1, 'CASCADE_RUN_STATUS_RUNNING', 'CORTEX_TRAJECTORY_SOURCE_CLI', 0, '', 2),
              ('desktop', '2026-11-25 12:00:00.001+00:00', 0, 0, 'CASCADE_RUN_STATUS_BUSY', '', 0, '', 2),
              ('stale', '2026-11-25 11:00:00+00:00', 0, 1, 'CASCADE_RUN_STATUS_RUNNING', '', 0, '', 2),
              ('killed', '2026-11-25 12:00:00.001+00:00', 1, 1, 'CASCADE_RUN_STATUS_RUNNING', '', 0, '', 2),
              ('child', '2026-11-25 12:00:00.001+00:00', 0, 1, 'CASCADE_RUN_STATUS_RUNNING', '', 1, 'desktop', 2);
            """)
        try exec(cli, """
            INSERT INTO conversation_summaries VALUES
              ('mirror', '2026-11-25 12:00:00.001+00:00', 0, 0, 'CASCADE_RUN_STATUS_IDLE', '', 0, '', 2),
              ('cli', '2026-11-25 12:00:00.001+00:00', 0, 1, '', '', 0, '', 0),
              ('placeholder', '0001-01-01 00:00:00+00:00', 0, 0, '', '', 0, '', 0);
            """)
        let scanner = Scanner()
        let desktopProcess = RunningProcess(pid: 101, executablePath: "/Applications/Renamed.app/Contents/MacOS/Antigravity")
        let cliProcess = RunningProcess(pid: 102, executablePath: "agy")
        scanner.replace(with: [desktopProcess, cliProcess])
        let codexSessions = root.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: false)
        let configuration = CodexRuntimeMetricsConfiguration(
            sessionsDirectories: [codexSessions], automationRoots: [], databaseURL: root.appendingPathComponent("pulse.sqlite"),
            claudeSessionsDirectory: root.appendingPathComponent("claude-sessions"),
            claudeProjectsDirectory: root.appendingPathComponent("claude-projects"),
            antigravitySummaryDatabases: stores
        )
        guard let now = ISO8601DateFormatter().date(from: "2026-11-25T12:00:01Z") else {
            throw Failure.assertion("invalid fixture timestamp")
        }
        let collector = try CodexRuntimeMetricsCollector(configuration: configuration, processScanner: scanner)
        let first = try await collector.scan(at: now)
        let metric = first.taskBreakdown.antigravity
        try require(metric.totalTasks == 5 && metric.activeTasks == 2,
                    "top-level task count mismatch: \(metric)")
        try require(first.taskBreakdown.antigravity.quality == .complete, "closed WAL profile should remain readable")
        try require(!FileManager.default.fileExists(atPath: stores[2].path + "-shm"),
                    "read-only scan created a sidecar for the closed profile")
        try require(first.totalTasks == 5 && first.activeTasks == 2, "combined task counters omit Antigravity")
        try verifyLegacySnapshot(first.taskBreakdown)

        try exec(desktop, "UPDATE conversation_summaries SET status='CASCADE_RUN_STATUS_IDLE' WHERE conversation_id='desktop'")
        let changed = try await collector.scan(at: now.addingTimeInterval(1))
        try require(changed.taskBreakdown.antigravity.activeTasks == 1, "WAL-only idle update did not invalidate the cache")
        scanner.replace(with: [desktopProcess])
        let cliExited = try await collector.scan(at: now.addingTimeInterval(2))
        try require(cliExited.taskBreakdown.antigravity.activeTasks == 0, "exited CLI still contributes active tasks")

        try Data("not SQLite".utf8).write(to: stores[2])
        let partial = try await collector.scan(at: now.addingTimeInterval(3))
        try require(partial.taskBreakdown.antigravity.totalTasks == 5 && partial.taskBreakdown.antigravity.quality == .partial,
                    "an unreadable Antigravity store must preserve the other stores and degrade quality")
        scanner.replace(with: [])
        let closed = try await collector.scan(at: now.addingTimeInterval(4))
        try require(!closed.taskBreakdown.antigravity.present && closed.taskBreakdown.antigravity.totalTasks == 0,
                    "closed Antigravity still contributes historical tasks")
    }

    private static func verifyLegacySnapshot(_ breakdown: RuntimeTaskBreakdown) throws {
        let encoded = try JSONEncoder().encode(breakdown)
        guard var fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw Failure.assertion("invalid encoded runtime counters")
        }
        fields.removeValue(forKey: "antigravity")
        let legacy = try JSONSerialization.data(withJSONObject: fields)
        let restored = try JSONDecoder().decode(RuntimeTaskBreakdown.self, from: legacy)
        try require(restored.antigravity == .unavailable && restored.codexDesktop == breakdown.codexDesktop,
                    "legacy cached snapshot must decode without Antigravity data")
    }

    private static func seedClosedProfile(at url: URL, schema: String) throws {
        do {
            let db = try open(url)
            defer { sqlite3_close(db) }
            try exec(db, schema)
            try exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        // The system SQLite can persist empty sidecars even when the final
        // connection closes. Ensure this fixture exercises immutable mode.
        let files = FileManager.default
        let wal = url.path + "-wal"
        if files.fileExists(atPath: wal) {
            let attributes = try files.attributesOfItem(atPath: wal)
            try require((attributes[.size] as? NSNumber)?.int64Value == 0, "closed fixture has uncheckpointed WAL")
            try files.removeItem(atPath: wal)
        }
        let sharedMemory = url.path + "-shm"
        if files.fileExists(atPath: sharedMemory) { try files.removeItem(atPath: sharedMemory) }
    }

    private static func open(_ url: URL) throws -> OpaquePointer {
        var db: OpaquePointer?
        let status = sqlite3_open(url.path, &db)
        guard status == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw Failure.sqlite(status)
        }
        return db
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw Failure.sqlite(status) }
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else { throw Failure.assertion(reason) }
    }
}
