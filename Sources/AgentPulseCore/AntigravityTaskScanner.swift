import Foundation
import Darwin
import SQLite3

/// Reads only summary metadata. Conversation IDs are used in memory to fold
/// mirrors and never enter the published or persisted runtime snapshot.
struct AntigravityTaskScanner {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        static func read(path: String) throws -> Self? {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw ReadFailure.metadata
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReadFailure.metadata }
            return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                        modifiedSeconds: info.st_mtimespec.tv_sec,
                        modifiedNanoseconds: info.st_mtimespec.tv_nsec)
        }

        func identifiesSameFile(as previous: Self) -> Bool {
            device == previous.device && inode == previous.inode
        }
    }

    private struct Revision: Equatable {
        let database: Stamp
        let wal: Stamp?
    }

    private struct Conversation {
        let id: String
        let lastActivity: Date?
        let busy: Bool
        let cli: Bool
        let native: Bool

        func supersedes(_ previous: Self) -> Bool {
            let time = lastActivity ?? .distantPast
            let previousTime = previous.lastActivity ?? .distantPast
            if time == previousTime { return native && !previous.native }
            return time > previousTime
        }
    }

    private struct CachedRows {
        let revision: Revision
        let rows: [Conversation]
    }

    private enum ReadFailure: Error { case metadata, incompleteWAL, replaced, sqlite }

    private static let cliDirectory = "antigravity-cli"
    private static let cliSource = "CORTEX_TRAJECTORY_SOURCE_CLI"
    private static let busySQL = "not_fully_idle != 0 OR status IN ('CASCADE_RUN_STATUS_RUNNING', 'CASCADE_RUN_STATUS_BUSY')"
    private static let unixEpochJulianDay = 2_440_587.5
    private static let secondsPerDay = 86_400.0
    private var cache: [URL: CachedRows] = [:]

    static func databaseURLs(home: URL) -> [URL] {
        AntigravityUsageCollector.defaultRoots(home: home).map {
            $0.appendingPathComponent("conversation_summaries.db")
        }
    }

    mutating func scan(databases: [URL], processes: [RunningProcess], now: Date) -> RuntimeTaskCategoryMetric {
        let desktopRunning = processes.contains {
            $0.executablePath.hasSuffix(".app/Contents/MacOS/Antigravity")
                || $0.executablePath.hasSuffix(".app/Contents/MacOS/Antigravity IDE")
        }
        let cliRunning = processes.contains {
            $0.executablePath.split(separator: "/").last == "agy"
                && !$0.executablePath.contains(".app/Contents/")
        }
        guard !databases.isEmpty, desktopRunning || cliRunning else {
            return RuntimeTaskCategoryMetric(totalTasks: 0, activeTasks: 0, present: false, quality: .complete)
        }

        var unique: [String: Conversation] = [:]
        var readable = false
        var partial = false
        for url in databases {
            do {
                guard let rows = try readRows(at: url) else { continue }
                readable = true
                for row in rows {
                    if let existing = unique[row.id], !row.supersedes(existing) { continue }
                    unique[row.id] = row
                }
            } catch {
                cache.removeValue(forKey: url)
                partial = true
            }
        }
        guard readable else {
            return RuntimeTaskCategoryMetric(totalTasks: nil, activeTasks: nil, present: true, quality: .unavailable)
        }

        var active = 0
        for row in unique.values where row.busy && (row.cli ? cliRunning : desktopRunning) {
            guard let date = row.lastActivity else {
                partial = true
                continue
            }
            let age = now.timeIntervalSince(date)
            if age >= -CodexRuntimeMetricsConfiguration.futureTimestampToleranceSeconds
                && age <= CodexRuntimeMetricsConfiguration.activeTaskTimeoutSeconds {
                active += 1
            }
        }
        return RuntimeTaskCategoryMetric(totalTasks: unique.count, activeTasks: active, present: true,
                                         quality: partial ? .partial : .complete)
    }

    private mutating func readRows(at url: URL) throws -> [Conversation]? {
        guard let revision = try Self.revision(at: url) else {
            cache.removeValue(forKey: url)
            return nil
        }
        if let cached = cache[url], cached.revision == revision { return cached.rows }

        let immutable = revision.wal == nil
        let rows = try Self.query(url: url, immutable: immutable)
        guard let current = try Self.revision(at: url),
              immutable ? current == revision : current.database.identifiesSameFile(as: revision.database) else {
            throw ReadFailure.replaced
        }
        cache[url] = CachedRows(revision: revision, rows: rows)
        return rows
    }

    private static func revision(at url: URL) throws -> Revision? {
        guard let database = try Stamp.read(path: url.path) else { return nil }
        let wal = try Stamp.read(path: url.path + "-wal")
        let sharedMemory = try Stamp.read(path: url.path + "-shm")
        guard (wal == nil) == (sharedMemory == nil) else { throw ReadFailure.incompleteWAL }
        return Revision(database: database, wal: wal)
    }

    private static func query(url: URL, immutable: Bool) throws -> [Conversation] {
        var database: OpaquePointer?
        // A closed WAL-mode database may have no sidecars. Immutable mode
        // permits reading it without creating them, guarded by the revision check.
        guard let file = AntigravitySQLitePath.resolvingParent(of: url) else { throw ReadFailure.metadata }
        let uri = file.absoluteString + (immutable ? "?immutable=1" : "?mode=ro")
        let options = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI
        let status = sqlite3_open_v2(uri, &database, options, nil)
        defer { sqlite3_close(database) }
        guard status == SQLITE_OK,
              sqlite3_exec(database, "PRAGMA trusted_schema = OFF", nil, nil, nil) == SQLITE_OK else {
            throw ReadFailure.sqlite
        }
        let sql = """
            SELECT conversation_id, julianday(last_modified_time),
                   killed = 0 AND (\(busySQL)),
                   source = '\(cliSource)'
            FROM conversation_summaries
            WHERE conversation_id <> '' AND nesting_depth = 0 AND coalesce(parent_conversation_id, '') = ''
              AND (step_count > 0 OR \(busySQL))
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadFailure.sqlite
        }
        let cliStore = url.deletingLastPathComponent().lastPathComponent == cliDirectory
        var rows: [Conversation] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return rows
            case SQLITE_ROW:
                guard let id = sqlite3_column_text(statement, 0) else { throw ReadFailure.sqlite }
                let julianDay = sqlite3_column_double(statement, 1)
                let seconds = (julianDay - unixEpochJulianDay) * secondsPerDay
                let date = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil
                    : Date(timeIntervalSince1970: (seconds * 1_000).rounded() / 1_000)
                let cli = cliStore || sqlite3_column_int(statement, 3) != 0
                rows.append(Conversation(id: String(cString: id), lastActivity: date,
                                         busy: sqlite3_column_int(statement, 2) != 0,
                                         cli: cli, native: cliStore == cli))
            default: throw ReadFailure.sqlite
            }
        }
    }
}
