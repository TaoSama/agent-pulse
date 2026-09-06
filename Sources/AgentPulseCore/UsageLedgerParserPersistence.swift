import Foundation
import SQLite3

/// Parser state stores statistics and hashed identities only. Completed identities
/// remain addressable for out-of-order records; each identity has a single value.
/// Replacement staging holds one generation per file and is discarded on abort,
/// successful publication, or closing the connection. Disk-backed TEMP storage
/// avoids writing these non-recoverable intermediate values through the main WAL.
extension UsageLedgerStore {
    func initializeParserPersistenceUnlocked() throws {
        try transaction {
            try exec("""
            CREATE TABLE IF NOT EXISTS usage_parser_state(
              file_id TEXT NOT NULL, key TEXT NOT NULL, value BLOB NOT NULL,
              PRIMARY KEY(file_id,key)
            ) WITHOUT ROWID;
            DROP TABLE IF EXISTS main.usage_parser_stage;
            DROP TABLE IF EXISTS main.usage_parser_replacements;
            CREATE TEMP TABLE IF NOT EXISTS usage_parser_replacements(
              file_id TEXT PRIMARY KEY, hostname TEXT NOT NULL
            ) WITHOUT ROWID;
            CREATE TEMP TABLE IF NOT EXISTS usage_parser_ready(
              file_id TEXT PRIMARY KEY, checkpoint BLOB NOT NULL
            ) WITHOUT ROWID;
            CREATE TEMP TABLE IF NOT EXISTS usage_parser_stage(
              file_id TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL,
              value BLOB NOT NULL, PRIMARY KEY(file_id,kind,key)
            ) WITHOUT ROWID;
            """)
            try initializeTypedStageTablesUnlocked()
        }
        // Only obsolete scratch tables are dropped. Their pages can be reused;
        // this does not promise a smaller database file or run VACUUM. Durable
        // raw rows, parser state and checkpoints retain their publication transaction.
    }

    func resetParserPersistenceUnlocked() throws {
        try exec("DELETE FROM usage_parser_state; DELETE FROM temp.usage_parser_stage; DELETE FROM temp.usage_parser_replacements; DELETE FROM temp.usage_parser_ready;"); try resetTypedParserStageUnlocked()
    }

    func migrateParserFileIdentityUnlocked(from oldID: String, to newID: String) throws {
        // A caller may migrate only the committed checkpoint. In-flight replacement
        // data belongs to the old attempt and is never published under another file.
        try abortParserReplacementUnlocked(fileID: oldID)
        try abortParserReplacementUnlocked(fileID: newID)
        // Encoded statistics may themselves contain the old sourceFileHash. A
        // cursor cannot be relabelled independently of those values. Invalidate
        // it so the next read stages a complete replacement under the new identity;
        // the existing raw/checkpoint history remains available throughout.
        try deleteParserStateUnlocked(fileID: oldID)
        try deleteParserStateUnlocked(fileID: newID)
    }

    public func parserState(fileID: String, key: String) throws -> Data? {
        try queue.sync {
            let staging = try hasParserReplacementUnlocked(fileID: fileID)
            let sql = staging
                ? "SELECT value FROM temp.usage_parser_stage WHERE file_id=? AND kind='state' AND key=?;"
                : "SELECT value FROM usage_parser_state WHERE file_id=? AND key=?;"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, fileID); try bind(statement, 2, key)
            guard try step(statement) == SQLITE_ROW else { return nil }
            return parserBlob(statement, column: 0)
        }
    }

    public func abortParserReplacement(fileID: String) throws {
        try queue.sync { try transaction { try abortParserReplacementUnlocked(fileID: fileID) } }
    }

    public func recordIncremental(batch: UsageIncrementalBatch, hostname: String) throws {
        _ = try recordIncremental(batch: batch, hostname: hostname, deferPublication: false)
    }

    func recordIncrementalForScan(batch: UsageIncrementalBatch, hostname: String) throws -> Bool {
        try recordIncremental(batch: batch, hostname: hostname, deferPublication: true)
    }

    private func recordIncremental(batch: UsageIncrementalBatch, hostname: String, deferPublication: Bool) throws -> Bool {
        let parsed = batch.parsed
        let checkpoint = parsed.checkpoint
        guard checkpoint.offset >= 0, checkpoint.offset <= checkpoint.size else {
            throw UsageLedgerError.invalidCheckpoint
        }
        try validateAttribution(events: parsed.events, sessionEvents: parsed.sessionEvents,
                                editEntries: parsed.editEntries, fileID: checkpoint.fileID)
        var committed = false
        try queue.sync {
            try transaction {
                let fileID = checkpoint.fileID
                if batch.replacesFile {
                    try abortParserReplacementUnlocked(fileID: fileID)
                    let statement = try prepare("INSERT INTO temp.usage_parser_replacements(file_id,hostname) VALUES(?,?);")
                    defer { sqlite3_finalize(statement) }
                    try bind(statement, 1, fileID); try bind(statement, 2, hostname); try done(statement)
                }
                if try hasParserReplacementUnlocked(fileID: fileID) {
                    guard try !parserReplacementIsReadyUnlocked(fileID: fileID) else {
                        throw UsageLedgerError.invalidCheckpoint
                    }
                    try stageParserBatchUnlocked(batch, hostname: hostname)
                    if batch.isFinalBatch {
                        if deferPublication {
                            try markParserReplacementReadyUnlocked(checkpoint)
                        } else {
                            try publishParserReplacementUnlocked(checkpoint, hostname: hostname)
                            committed = true
                        }
                    }
                } else {
                    try writeParserRawBatchUnlocked(events: parsed.events, sessions: parsed.sessionEvents,
                                                    edits: parsed.editEntries, removedEvents: batch.removedEventIDs,
                                                    removedEdits: batch.removedEditIDs, fileID: fileID, hostname: hostname)
                    try writeParserStateUnlocked(batch.stateChanges, fileID: fileID, staging: false)
                    if let model = batch.codexUnknownModel {
                        try backfillParserUnknownModelUnlocked(fileID: fileID, model: model, staging: false)
                    }
                    try finishParserBatchUnlocked(checkpoint, hostname: hostname)
                    committed = true
                }
            }
        }
        return committed
    }

    func finishParserBatchUnlocked(_ checkpoint: UsageFileCheckpoint, hostname: String, rawChanged: Bool = true) throws {
        let previous = try prepare("SELECT scan_status FROM usage_files WHERE file_id=?;")
        defer { sqlite3_finalize(previous) }
        try bind(previous, 1, checkpoint.fileID)
        let hadCheckpoint = try step(previous) == SQLITE_ROW
        let wasActive = hadCheckpoint && text(previous, 0) != "missing"
        let tierChanged = wasActive != (checkpoint.status != "missing")
        if tierChanged && (!rawChanged || (hadCheckpoint && !wasActive)) {
            // Returning files change ownership tier even when their bytes have not
            // changed. Every identity in the file can now displace another winner.
            try markParserRowsDirtyUnlocked(fileID: checkpoint.fileID, allRows: true)
        }
        if checkpoint.status == "complete" {
            try markEditMetricSourceUnlocked(checkpoint.source, hostname: hostname)
        }
        try writeCheckpoint(checkpoint)
        let dirty = try prepare("SELECT 1 FROM usage_dirty_keys LIMIT 1;")
        defer { sqlite3_finalize(dirty) }
        let hasDirtyKeys = try step(dirty) == SQLITE_ROW
        if rawChanged || tierChanged || hasDirtyKeys {
            try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
        }
        if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
            try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
        }
    }

    private func hasParserReplacementUnlocked(fileID: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM temp.usage_parser_replacements WHERE file_id=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, fileID)
        return try step(statement) == SQLITE_ROW
    }

    func abortParserReplacementUnlocked(fileID: String) throws {
        for table in ["temp.usage_parser_stage", "temp.usage_parser_replacements", "temp.usage_parser_ready"] {
            let statement = try prepare("DELETE FROM \(table) WHERE file_id=?;")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, fileID); try done(statement)
        }
        try abortTypedParserStageUnlocked(fileID: fileID)
    }

    func deleteParserStateUnlocked(fileID: String) throws {
        let statement = try prepare("DELETE FROM usage_parser_state WHERE file_id=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, fileID); try done(statement)
    }

    private func stageParserBatchUnlocked(_ batch: UsageIncrementalBatch, hostname: String) throws {
        let fileID = batch.parsed.checkpoint.fileID
        let owner = try prepare("SELECT hostname FROM temp.usage_parser_replacements WHERE file_id=?;")
        defer { sqlite3_finalize(owner) }
        try bind(owner, 1, fileID)
        guard try step(owner) == SQLITE_ROW, text(owner, 0) == hostname else {
            throw UsageLedgerError.invalidCheckpoint
        }
        try stageTypedEventsUnlocked(batch.parsed.events, fileID: fileID, hostname: hostname)
        try stageTypedSessionsUnlocked(batch.parsed.sessionEvents, fileID: fileID, hostname: hostname)
        try stageTypedEditsUnlocked(batch.parsed.editEntries, fileID: fileID, hostname: hostname)
        // An emitted authoritative event wins over a deletion marker in the same batch.
        let emitted = Set(batch.parsed.events.map(\.id))
        let emittedEdits = Set(batch.parsed.editEntries.map(\.toolUseID))
        try deleteTypedStageRemovedEventsUnlocked(batch.removedEventIDs.filter { !emitted.contains($0) }, fileID: fileID)
        try deleteTypedStageRemovedEditsUnlocked(batch.removedEditIDs.filter { !emittedEdits.contains($0) }, fileID: fileID)
        try writeParserStateUnlocked(batch.stateChanges, fileID: fileID, staging: true)
        if let model = batch.codexUnknownModel {
            try backfillParserUnknownModelUnlocked(fileID: fileID, model: model, staging: true)
        }
    }

    /// Unknown-model identity markers are individually keyed, so model discovery
    /// updates their historical rows in SQLite without constructing a file-sized
    /// list of events or identifiers in the parser's resident memory.
    private func backfillParserUnknownModelUnlocked(fileID: String, model: String, staging: Bool) throws {
        if staging {
            try backfillTypedStageUnknownModelUnlocked(fileID: fileID, model: model)
            return
        }
        try prepareParserKeysUnlocked()
        let identities = try prepare("""
            INSERT OR IGNORE INTO temp_parser_keys(kind,id)
            SELECT 'event',json_extract(CAST(value AS TEXT),'$') FROM usage_parser_state
            WHERE file_id=? AND key>='codex-unknown:' AND key<'codex-unknown;';
            """)
        defer { sqlite3_finalize(identities) }
        try bind(identities, 1, fileID); try done(identities)
        try markParserRowsDirtyUnlocked(fileID: fileID, allRows: false)
        let update = try prepare("""
            UPDATE usage_events SET model=?
            WHERE source_file_hash=? AND event_id IN (SELECT id FROM temp_parser_keys WHERE kind='event');
            """)
        defer { sqlite3_finalize(update) }
        try bind(update, 1, model); try bind(update, 2, fileID); try done(update)
        try markParserRowsDirtyUnlocked(fileID: fileID, allRows: false)
        try exec("DELETE FROM temp_parser_keys;")
    }

    private func writeParserStateUnlocked(_ changes: UsageParserStateChanges, fileID: String, staging: Bool) throws {
        let table = staging ? "temp.usage_parser_stage" : "usage_parser_state"
        let remove = try prepare("DELETE FROM \(table) WHERE file_id=? AND key=?" + (staging ? " AND kind='state';" : ";"))
        defer { sqlite3_finalize(remove) }
        for key in changes.removedKeys {
            sqlite3_reset(remove); sqlite3_clear_bindings(remove)
            try bind(remove, 1, fileID); try bind(remove, 2, key); try done(remove)
        }
        let sql = staging
            ? """
                INSERT INTO temp.usage_parser_stage(file_id,key,value,kind) VALUES(?,?,?,'state')
                ON CONFLICT(file_id,kind,key) DO UPDATE SET value=excluded.value
                WHERE usage_parser_stage.value IS NOT excluded.value;
                """
            : """
                INSERT INTO usage_parser_state(file_id,key,value) VALUES(?,?,?)
                ON CONFLICT(file_id,key) DO UPDATE SET value=excluded.value
                WHERE usage_parser_state.value IS NOT excluded.value;
                """
        let insert = try prepare(sql)
        defer { sqlite3_finalize(insert) }
        for (key, data) in changes.values {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, fileID); try bind(insert, 2, key)
            try bindParserBlob(insert, index: 3, value: data); try done(insert)
        }
    }

    private func unfrozenParserRowsUnlocked(events: [UsageEvent], sessions: [UsageSessionEvent], hostname: String) throws -> (events: [UsageEvent], sessions: [UsageSessionEvent]) {
        let frozen = try frozenBeforeMsUnlocked(hostname)
        let keptEvents = events.filter { frozen <= 0 || millis($0.timestamp) >= frozen }
        let keptSessions = sessions.filter { frozen <= 0 || millis($0.timestamp) >= frozen }
        let dropped = events.count - keptEvents.count + sessions.count - keptSessions.count
        if dropped > 0 {
            let key = frozenDroppedEventsKey(hostname)
            try setIntUnlocked(key: key, value: (try readIntUnlocked(key: key) ?? 0) + Int64(dropped))
        }
        return (keptEvents, keptSessions)
    }

    private func writeParserRawBatchUnlocked(events: [UsageEvent], sessions: [UsageSessionEvent], edits: [UsageEditEntry], removedEvents: [String], removedEdits: [String], fileID: String, hostname: String) throws {
        let (keptEvents, keptSessions) = try unfrozenParserRowsUnlocked(events: events, sessions: sessions, hostname: hostname)
        try prepareParserKeysUnlocked()
        let keys = try prepare("INSERT OR IGNORE INTO temp_parser_keys(kind,id,source) VALUES(?,?,?);")
        defer { sqlite3_finalize(keys) }
        let sessionSources = Dictionary(keptSessions.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        for (kind, ids) in [("event", keptEvents.map(\.id) + removedEvents), ("session", keptSessions.map(\.id)), ("edit", edits.map(\.toolUseID) + removedEdits)] {
            for id in ids {
                sqlite3_reset(keys); sqlite3_clear_bindings(keys)
                try bind(keys, 1, kind); try bind(keys, 2, id)
                try bind(keys, 3, kind == "session" ? sessionSources[id] ?? "" : ""); try done(keys)
            }
        }
        try markParserRowsDirtyUnlocked(fileID: fileID, allRows: false)
        // Delete only touched identities before inserting authoritative parser output;
        // cumulativeMax is a parser concern and must not prevent count corrections.
        for (table, column, kind) in [("usage_events", "event_id", "event"), ("usage_session_events", "event_id", "session"), ("usage_edit_entries", "tool_use_id", "edit")] {
            let statement = try prepare("DELETE FROM \(table) WHERE source_file_hash=?\(parserBatchScope(column: column, kind: kind));")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, fileID); try done(statement)
        }
        try insertRawEvents(keptEvents, fileID: fileID, hostname: hostname)
        try insertRawSessionEvents(keptSessions, fileID: fileID, hostname: hostname)
        try insertRawEditEntries(edits, fileID: fileID, hostname: hostname)
        try markParserRowsDirtyUnlocked(fileID: fileID, allRows: false)
        try exec("DELETE FROM temp_parser_keys;")
    }

    private func prepareParserKeysUnlocked() throws {
        try exec("CREATE TEMP TABLE IF NOT EXISTS temp_parser_keys(kind TEXT NOT NULL,id TEXT NOT NULL,source TEXT NOT NULL DEFAULT '',PRIMARY KEY(kind,id)) WITHOUT ROWID; DELETE FROM temp_parser_keys;")
    }

    private func parserBatchScope(column: String, kind: String) -> String {
        if kind == "session" {
            // The session primary key starts with source; include it to avoid
            // scanning all previously published sessions on each small batch.
            return " AND (source,\(column)) IN (SELECT source,id FROM temp_parser_keys WHERE kind='session')"
        }
        return " AND \(column) IN (SELECT id FROM temp_parser_keys WHERE kind='\(kind)')"
    }

    /// SQL streams dirty keys directly into their durable set, including the old
    /// owner when attribution changes. No whole-file Swift collection is created.
    func markParserRowsDirtyUnlocked(fileID: String, allRows: Bool, hostname: String? = nil) throws {
        let separator = "char(1)"
        let bucket = "CAST((timestamp_ms / \(Self.bucketMilliseconds)) * \(Self.bucketMilliseconds) AS TEXT)"
        let bucketKey = "source||\(separator)||model||\(separator)||project||\(separator)||\(bucket)"
        let definitions: [(String, String, String, [(String, String)])] = [
            ("usage_events", "event_id", "event", [
                ("logical", "source||\(separator)||event_id"), ("lineage", "lineage_fingerprint"),
                ("content", "codex_dedup_key"), ("session", "source||\(separator)||session_hash"), ("bucket", bucketKey)
            ]),
            ("usage_session_events", "event_id", "session", [("session", "source||\(separator)||session_hash")]),
            ("usage_edit_entries", "tool_use_id", "edit", [("editTool", "tool_use_id"), ("bucket", bucketKey)])
        ]
        for (table, column, rowKind, definitions) in definitions {
            let scope = allRows ? "" : parserBatchScope(column: column, kind: rowKind)
            let owner = hostname == nil ? "" : " AND hostname=?"
            for (kind, expression) in definitions {
                let statement = try prepare("""
                    INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                    SELECT hostname,'\(kind)',\(expression),? FROM \(table)
                    WHERE source_file_hash=?\(scope)\(owner) AND (\(expression))<>'';
                    """)
                defer { sqlite3_finalize(statement) }
                try bind(statement, 1, millis(Date())); try bind(statement, 2, fileID)
                if let hostname { try bind(statement, 3, hostname) }
                try done(statement)
            }
        }
    }

    func parserBlob(_ statement: OpaquePointer?, column: Int32) -> Data {
        let size = Int(sqlite3_column_bytes(statement, column))
        guard size > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: size)
    }

    func bindParserBlob(_ statement: OpaquePointer?, index: Int32, value: Data) throws {
        guard value.count <= Int(Int32.max) else {
            throw UsageLedgerError.sqlite("parser statistics exceed SQLite value limit")
        }
        if value.isEmpty {
            guard sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK else {
                throw UsageLedgerError.sqlite("unable to bind empty parser statistics")
            }
            return
        }
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK else { throw UsageLedgerError.sqlite("unable to bind parser statistics") }
    }
}
