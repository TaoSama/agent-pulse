import Darwin
import Foundation
import SQLite3

public struct AntigravityUsageScanResult: Sendable {
    public fileprivate(set) var discoveredDatabases = 0
    public fileprivate(set) var scannedDatabases = 0
    public fileprivate(set) var failedDatabases = 0
    public fileprivate(set) var failedDirectories = 0
    public fileprivate(set) var observedEvents = 0
}

/// Reads native generation statistics for Desktop, CLI and IDE sessions.
public enum AntigravityUsageCollector {
    public static let source = "antigravity"
    private static let profiles = ["antigravity", "antigravity-cli", "antigravity-ide"]
    private static let conversationDirectory = "conversations"
    private static let maximumMetadataBytes = 16 * 1_024 * 1_024
    private static let maximumStepMetadataBytes = 256 * 1_024
    private static let maximumGenerationsPerDatabase = 100_000

    private enum ReadError: Error {
        case invalidFile, unreadyWAL, modifiedWhileReading, sqlite, invalidMetadata, tooManyGenerations
    }

    public static func defaultRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        profiles.map { profile in
            home.appendingPathComponent(".gemini", isDirectory: true)
                .appendingPathComponent(profile, isDirectory: true)
        }
    }

    public static func scanAndRecord(
        roots: [URL], ledger: UsageLedgerStore, hostname: String,
        checkCancellation: () throws -> Void = {}
    ) throws -> AntigravityUsageScanResult {
        var result = AntigravityUsageScanResult()
        var seen = Set<URL>()
        for root in roots {
            try checkCancellation()
            let directory = root.appendingPathComponent(conversationDirectory, isDirectory: true)
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                )
            } catch {
                let fileError = error as NSError
                if fileError.domain == NSCocoaErrorDomain
                    && fileError.code == CocoaError.Code.fileReadNoSuchFile.rawValue { continue }
                result.failedDirectories += 1
                continue
            }
            for file in files.sorted(by: { $0.path < $1.path }) where file.pathExtension == "db" {
                try checkCancellation()
                guard let url = AntigravitySQLitePath.resolvingParent(of: file) else {
                    result.discoveredDatabases += 1
                    result.failedDatabases += 1
                    continue
                }
                guard seen.insert(url).inserted else { continue }
                result.discoveredDatabases += 1
                let databaseID = ContentDigest.sha256(url.path)
                let start: Revision
                do {
                    start = try Revision(url)
                } catch {
                    result.failedDatabases += 1
                    continue
                }
                let state = start.stateDigest
                if try ledger.antigravityRevision(for: databaseID) == state { continue }
                let events: [UsageEvent]
                do {
                    events = try read(url, revision: start, checkCancellation: checkCancellation)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result.failedDatabases += 1
                    continue
                }
                try checkCancellation()
                try ledger.commitAntigravityEvents(
                    events, databaseID: databaseID, revision: state, hostname: hostname
                )
                result.scannedDatabases += 1
                result.observedEvents += events.count
            }
        }
        return result
    }

    private static func read(
        _ file: URL, revision: Revision, checkCancellation: () throws -> Void
    ) throws -> [UsageEvent] {
        let events = try readSnapshot(file, immutable: revision.wal == nil, checkCancellation: checkCancellation)
        let current = try Revision(file)
        if revision.wal == nil {
            // SQLite does not take a read lock in immutable mode. Discard the
            // entire read if the main file or sidecars changed in the meantime.
            guard current == revision else { throw ReadError.modifiedWhileReading }
        } else {
            guard current.database.identity == revision.database.identity else { throw ReadError.modifiedWhileReading }
        }
        // A normal SQLite WAL read is a coherent snapshot even when the
        // writer appends. Retaining the prior stamp causes a read next round.
        return events
    }

    private static func readSnapshot(
        _ file: URL, immutable: Bool, checkCancellation: () throws -> Void
    ) throws -> [UsageEvent] {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI
        var database: OpaquePointer?
        let uri = file.absoluteString + (immutable ? "?immutable=1" : "?mode=ro")
        let openStatus = sqlite3_open_v2(uri, &database, flags, nil)
        defer { sqlite3_close(database) }
        guard openStatus == SQLITE_OK, let database else { throw ReadError.sqlite }
        guard sqlite3_exec(database, "PRAGMA trusted_schema=OFF; BEGIN;", nil, nil, nil) == SQLITE_OK
        else { throw ReadError.sqlite }
        var generations: OpaquePointer?
        var steps: OpaquePointer?
        defer {
            sqlite3_finalize(generations)
            sqlite3_finalize(steps)
        }
        let generationSQL = "SELECT data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx;"
        guard sqlite3_prepare_v2(database, generationSQL, -1, &generations, nil) == SQLITE_OK,
              sqlite3_prepare_v2(database, "SELECT metadata FROM steps WHERE idx=?;", -1, &steps, nil) == SQLITE_OK
        else { throw ReadError.sqlite }

        let session = ContentDigest.sha256(source + "\u{1}" + file.deletingPathExtension().lastPathComponent)
        var events: [String: UsageEvent] = [:]
        var rows = 0
        while true {
            try checkCancellation()
            let status = sqlite3_step(generations)
            if status == SQLITE_DONE { return events.values.sorted { $0.id < $1.id } }
            guard status == SQLITE_ROW else { throw ReadError.sqlite }
            rows += 1
            guard rows <= maximumGenerationsPerDatabase else { throw ReadError.tooManyGenerations }
            let bytes = try blob(generations, maximumBytes: maximumMetadataBytes)
            guard let generation = try AntigravityUsageMetadata.generation(bytes) else { continue }
            guard sqlite3_reset(steps) == SQLITE_OK,
                  sqlite3_bind_int64(steps, 1, generation.firstStep) == SQLITE_OK,
                  sqlite3_step(steps) == SQLITE_ROW
            else { throw ReadError.sqlite }
            let metadata = try blob(steps, maximumBytes: maximumStepMetadataBytes)
            let timestamp = try AntigravityUsageMetadata.createdAt(metadata)
            let id = ContentDigest.sha256(source + "\u{1}" + generation.responseID)
            let event = UsageEvent(
                id: id, source: source, model: generation.model, project: source,
                timestamp: timestamp, counts: generation.counts, sessionHash: session, sourceFileHash: ""
            )
            if let existing = events[id], !prefers(event, over: existing) { continue }
            events[id] = event
        }
    }

    private static func blob(_ statement: OpaquePointer?, maximumBytes: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, 0))
        guard count <= maximumBytes, sqlite3_column_type(statement, 0) == SQLITE_BLOB
        else { throw ReadError.invalidMetadata }
        if count == 0 { return Data() }
        guard let buffer = sqlite3_column_blob(statement, 0) else { throw ReadError.invalidMetadata }
        return Data(bytes: buffer, count: count)
    }

    // A repeated response can be a less complete mirror. Pick one complete
    // snapshot, never add counters from multiple representations of a call.
    private static func prefers(_ event: UsageEvent, over previous: UsageEvent) -> Bool {
        if event.counts.total != previous.counts.total { return event.counts.total > previous.counts.total }
        if event.timestamp != previous.timestamp { return event.timestamp < previous.timestamp }
        if event.model == "unknown" { return false }
        if previous.model == "unknown" { return true }
        return event.model < previous.model
    }

    private struct Revision: Equatable {
        let database: Stamp
        let wal: Stamp?
        let sharedMemory: Stamp?

        init(_ url: URL) throws {
            guard let main = try Stamp.read(url.path) else { throw ReadError.invalidFile }
            database = main
            wal = try Stamp.read(url.path + "-wal")
            sharedMemory = try Stamp.read(url.path + "-shm")
            guard (wal == nil) == (sharedMemory == nil) else { throw ReadError.unreadyWAL }
        }

        var stateDigest: String {
            ContentDigest.sha256(database.signature + "|" + (wal?.signature ?? "none"))
        }
    }

    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        var identity: String { "\(device):\(inode)" }
        var signature: String {
            "\(identity):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)"
        }

        static func read(_ path: String) throws -> Self? {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return nil }
                throw ReadError.invalidFile
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else { throw ReadError.invalidFile }
            return Self(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                        modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                        changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
        }
    }
}
