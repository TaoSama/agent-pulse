import Darwin
import Foundation
import SQLite3

public struct AntigravityUsageScanResult: Sendable {
    public fileprivate(set) var discoveredDatabases = 0
    public fileprivate(set) var scannedDatabases = 0
    public fileprivate(set) var failedDatabases = 0
    public fileprivate(set) var failedDirectories = 0
    public fileprivate(set) var observedEvents = 0
    public fileprivate(set) var rejectedRows = 0
    public fileprivate(set) var pendingDatabases = 0
}

/// Reads native generation statistics for Desktop, CLI and IDE sessions.
public enum AntigravityUsageCollector {
    public static let source = "antigravity"
    private static let profiles = ["antigravity", "antigravity-cli", "antigravity-ide"]
    private static let conversationDirectory = "conversations"
    private static let maximumMetadataBytes = 16 * 1_024 * 1_024
    private static let maximumStepMetadataBytes = 256 * 1_024
    private static let maximumGenerationsPerBatch = 100_000

    private enum ReadError: Error {
        case invalidFile, unreadyWAL, modifiedWhileReading, sqlite, invalidMetadata
    }

    private struct BatchCursor {
        let beforeIndex: Int64
        let state: String
        let hasRejections: Bool
        let needsRevalidation: Bool

        init(beforeIndex: Int64, state: String, hasRejections: Bool, needsRevalidation: Bool) {
            self.beforeIndex = beforeIndex
            self.state = state
            self.hasRejections = hasRejections
            self.needsRevalidation = needsRevalidation
        }

        init?(checkpoint: String?, databaseStamp: Stamp) {
            let fields = checkpoint?.split(separator: ":") ?? []
            guard fields.count == 6, fields[0] == "batch-v1", fields[1] == databaseStamp.identityDigest,
                  let index = Int64(fields[3]), ["0", "1"].contains(fields[4]), ["0", "1"].contains(fields[5])
            else { return nil }
            self.init(beforeIndex: index, state: String(fields[2]), hasRejections: fields[4] == "1",
                      needsRevalidation: fields[5] == "1")
        }

        func checkpoint(databaseStamp: Stamp) -> String {
            "batch-v1:\(databaseStamp.identityDigest):\(state):\(beforeIndex):\(hasRejections ? 1 : 0):\(needsRevalidation ? 1 : 0)"
        }
    }

    private struct SnapshotBatch {
        let events: [UsageEvent]
        let rejectedRows: Int
        let nextIndex: Int64?
        let coversCurrentSnapshot: Bool
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
                let checkpoint = try ledger.antigravityRevision(for: databaseID)
                if checkpoint == state { continue }
                let cursor = BatchCursor(checkpoint: checkpoint, databaseStamp: start.database)
                let changed = cursor.map { $0.state != state } ?? false
                let batch: SnapshotBatch
                do {
                    batch = try read(url, revision: start, beforeIndex: cursor?.beforeIndex,
                                     refreshNewest: changed, checkCancellation: checkCancellation)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result.failedDatabases += 1
                    continue
                }
                try checkCancellation()
                let hasRejections = batch.rejectedRows > 0
                    || (!batch.coversCurrentSnapshot && cursor?.hasRejections == true)
                let needsRevalidation = !batch.coversCurrentSnapshot
                    && (changed || cursor?.needsRevalidation == true)
                let nextCheckpoint: String? = if let index = batch.nextIndex {
                    BatchCursor(beforeIndex: index, state: state, hasRejections: hasRejections,
                                needsRevalidation: needsRevalidation).checkpoint(databaseStamp: start.database)
                } else {
                    hasRejections || needsRevalidation ? nil : state
                }
                try ledger.commitAntigravityEvents(
                    batch.events, databaseID: databaseID, revision: nextCheckpoint, hostname: hostname
                )
                result.scannedDatabases += 1
                result.observedEvents += batch.events.count
                result.rejectedRows += batch.rejectedRows
                if batch.nextIndex != nil || needsRevalidation { result.pendingDatabases += 1 }
            }
        }
        return result
    }

    private static func read(
        _ file: URL, revision: Revision, beforeIndex: Int64?, refreshNewest: Bool,
        checkCancellation: () throws -> Void
    ) throws -> SnapshotBatch {
        let batch = try readSnapshot(file, immutable: revision.wal == nil, beforeIndex: beforeIndex,
                                     refreshNewest: refreshNewest, checkCancellation: checkCancellation)
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
        return batch
    }

    private static func readSnapshot(
        _ file: URL, immutable: Bool, beforeIndex: Int64?, refreshNewest: Bool,
        checkCancellation: () throws -> Void
    ) throws -> SnapshotBatch {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_URI
        var database: OpaquePointer?
        let uri = file.absoluteString + (immutable ? "?immutable=1" : "?mode=ro")
        let openStatus = sqlite3_open_v2(uri, &database, flags, nil)
        defer { sqlite3_close(database) }
        guard openStatus == SQLITE_OK, let database else { throw ReadError.sqlite }
        guard sqlite3_exec(database, "PRAGMA trusted_schema=OFF; BEGIN;", nil, nil, nil) == SQLITE_OK
        else { throw ReadError.sqlite }
        var steps: OpaquePointer?
        defer { sqlite3_finalize(steps) }
        guard sqlite3_prepare_v2(database, "SELECT metadata FROM steps WHERE idx=?;", -1, &steps, nil) == SQLITE_OK
        else { throw ReadError.sqlite }
        let session = ContentDigest.sha256(source + "\u{1}" + file.deletingPathExtension().lastPathComponent)
        var events: [String: UsageEvent] = [:]
        var rejects = 0
        var before = beforeIndex
        if refreshNewest {
            // Refresh the changed recent page while continuing the older sweep.
            // All pages come from this single SQLite transaction.
            guard let recentBoundary = try readGenerations(
                database, steps: steps, session: session, beforeIndex: nil, events: &events,
                rejectedRows: &rejects, checkCancellation: checkCancellation
            ) else {
                return SnapshotBatch(events: events.values.sorted { $0.id < $1.id }, rejectedRows: rejects,
                                     nextIndex: nil, coversCurrentSnapshot: true)
            }
            before = min(before ?? recentBoundary, recentBoundary)
        }
        let next = try readGenerations(database, steps: steps, session: session, beforeIndex: before,
                                      events: &events, rejectedRows: &rejects, checkCancellation: checkCancellation)
        return SnapshotBatch(events: events.values.sorted { $0.id < $1.id }, rejectedRows: rejects,
                             nextIndex: next, coversCurrentSnapshot: before == nil && next == nil)
    }

    private static func readGenerations(
        _ database: OpaquePointer, steps: OpaquePointer?, session: String, beforeIndex: Int64?,
        events: inout [String: UsageEvent], rejectedRows: inout Int, checkCancellation: () throws -> Void
    ) throws -> Int64? {
        var generations: OpaquePointer?
        defer { sqlite3_finalize(generations) }
        let condition = beforeIndex == nil ? "" : "WHERE idx < ? "
        let generationSQL = "SELECT idx, data FROM gen_metadata \(condition)ORDER BY idx DESC LIMIT \(maximumGenerationsPerBatch + 1);"
        guard sqlite3_prepare_v2(database, generationSQL, -1, &generations, nil) == SQLITE_OK else { throw ReadError.sqlite }
        if let beforeIndex, sqlite3_bind_int64(generations, 1, beforeIndex) != SQLITE_OK { throw ReadError.sqlite }

        var rows = 0
        var lastIndex: Int64?
        while true {
            try checkCancellation()
            let status = sqlite3_step(generations)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, sqlite3_column_type(generations, 0) == SQLITE_INTEGER
            else { throw ReadError.sqlite }
            if rows == maximumGenerationsPerBatch {
                return lastIndex
            }
            rows += 1
            lastIndex = sqlite3_column_int64(generations, 0)
            guard sqlite3_column_type(generations, 1) != SQLITE_NULL else { continue }
            do {
                guard let event = try readGeneration(generations, steps: steps, session: session) else { continue }
                if let existing = events[event.id], !prefers(event, over: existing) { continue }
                events[event.id] = event
            } catch is AntigravityUsageMetadata.DecodeError {
                rejectedRows += 1
            } catch ReadError.invalidMetadata {
                rejectedRows += 1
            }
        }
    }

    private static func readGeneration(
        _ generations: OpaquePointer?, steps: OpaquePointer?, session: String
    ) throws -> UsageEvent? {
        let bytes = try blob(generations, column: 1, maximumBytes: maximumMetadataBytes)
        guard let generation = try AntigravityUsageMetadata.generation(bytes) else { return nil }
        guard sqlite3_reset(steps) == SQLITE_OK,
              sqlite3_bind_int64(steps, 1, generation.firstStep) == SQLITE_OK else { throw ReadError.sqlite }
        let status = sqlite3_step(steps)
        if status == SQLITE_DONE { throw ReadError.invalidMetadata }
        guard status == SQLITE_ROW else { throw ReadError.sqlite }
        let metadata = try blob(steps, column: 0, maximumBytes: maximumStepMetadataBytes)
        let timestamp = try AntigravityUsageMetadata.createdAt(metadata)
        let id = ContentDigest.sha256(source + "\u{1}" + generation.responseID)
        return UsageEvent(id: id, source: source, model: generation.model, project: source,
                          timestamp: timestamp, counts: generation.counts, sessionHash: session, sourceFileHash: "")
    }

    private static func blob(_ statement: OpaquePointer?, column: Int32, maximumBytes: Int) throws -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= maximumBytes, sqlite3_column_type(statement, column) == SQLITE_BLOB
        else { throw ReadError.invalidMetadata }
        guard sqlite3_errcode(sqlite3_db_handle(statement)) != SQLITE_NOMEM else { throw ReadError.sqlite }
        if count == 0 { return Data() }
        guard let buffer = sqlite3_column_blob(statement, column) else { throw ReadError.sqlite }
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
        var identityDigest: String { ContentDigest.sha256(identity) }
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
