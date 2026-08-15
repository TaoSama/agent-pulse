import AgentPulseCore
import Foundation
import SQLite3

private enum PreflightFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        if case let .failed(message) = self { return message }
        return "preflight failed"
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw PreflightFailure.failed(message) }
}

private struct DatabaseSnapshot {
    let schemaVersion: Int64
    let events: Int64
    let buckets: Int64
    let sessions: Int64
    let files: Int64
    let syncState: [String: String]
}

private struct ScanTotals {
    var files = 0
    var bytes: Int64 = 0
    var diagnostics = 0
}

@main
struct ProductionDatabasePreflightVerification {
    private static let databaseEnvironmentKey = "AGENT_PULSE_PREFLIGHT_DB"
    private static let hostnameEnvironmentKey = "AGENT_PULSE_PREFLIGHT_HOSTNAME"
    private static let progressInterval = 250

    static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let databasePath = environment[databaseEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !databasePath.isEmpty else {
            throw PreflightFailure.failed("set \(databaseEnvironmentKey) to an offline database copy")
        }
        guard let hostname = environment[hostnameEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostname.isEmpty else {
            throw PreflightFailure.failed("set \(hostnameEnvironmentKey) to the existing ledger hostname")
        }

        let databaseURL = URL(fileURLWithPath: databasePath).resolvingSymlinksInPath().standardizedFileURL
        let liveURL = try liveDatabaseURL().resolvingSymlinksInPath().standardizedFileURL
        try require(FileManager.default.fileExists(atPath: databaseURL.path), "offline database copy does not exist")
        try require(databaseURL != liveURL, "refusing to open the live Agent Pulse database")
        try require(!sameFile(databaseURL, liveURL), "refusing a hard link to the live Agent Pulse database")

        let before = try readSnapshot(databaseURL)
        // 接受任意不高于当前 schema 的离线副本（历史基线 v4 起、含当前 v10 活库副本）；
        // 高于当前版本说明副本来自更新的 build，拒绝以免误判迁移路径。
        try require(
            before.schemaVersion >= 1 && before.schemaVersion <= Int64(UsageLedgerStore.schemaVersion),
            "expected production-copy schema between v1 and current v\(UsageLedgerStore.schemaVersion), got v\(before.schemaVersion)"
        )
        try require(before.events > 0 && before.buckets > 0 && before.files > 0, "production copy is unexpectedly empty")
        let protectedState = before.syncState.filter { key, _ in
            key.hasPrefix("revision\u{1}")
        }

        var scanTotals = ScanTotals()
        var finalBucketCount = 0
        var finalSessionCount = 0
        var skillCalls = 0
        var mcpCalls = 0
        var linesAdded: Int64 = 0
        var linesDeleted: Int64 = 0

        do {
            let ledger = try UsageLedgerStore(path: databaseURL.path)
            let migrated = try readSnapshot(databaseURL)
            try require(migrated.schemaVersion == Int64(UsageLedgerStore.schemaVersion), "migration did not reach current schema v\(UsageLedgerStore.schemaVersion)")
            try require(state(protectedState, isPreservedBy: migrated.syncState), "migration lost revision high-watermark state")
            let rebuildRequired = try ledger.requiresParserRebuild(
                currentParserVersion: UsageJSONLParser.parserVersion
            )
            // 陈旧 parser 的副本会报告需要重建；已是当前 parser 的副本无需重建。
            // 无论哪种情况，预检都强制走一遍 reset → 全量重扫 → 派生，以证明重建链路端到端正确。
            _ = rebuildRequired

            try ledger.resetForRebuild()
            let afterReset = try readSnapshot(databaseURL)
            try require(state(protectedState, isPreservedBy: afterReset.syncState), "parser reset lost protected sync state")
            try require(afterReset.events == 0 && afterReset.buckets == 0 && afterReset.sessions == 0 && afterReset.files == 0, "parser reset did not clear rebuildable rows")

            let home = FileManager.default.homeDirectoryForCurrentUser
            try scan(
                root: home.appending(path: ".codex/sessions"),
                source: UsageJSONLParser.codexSource,
                includeSubagents: false,
                hostname: hostname,
                ledger: ledger,
                totals: &scanTotals
            )
            try scan(
                root: home.appending(path: ".codex/archived_sessions"),
                source: UsageJSONLParser.codexSource,
                includeSubagents: false,
                hostname: hostname,
                ledger: ledger,
                totals: &scanTotals
            )
            try scan(
                root: home.appending(path: ".claude/projects"),
                source: "claude-code",
                includeSubagents: true,
                hostname: hostname,
                ledger: ledger,
                totals: &scanTotals
            )

            _ = try ledger.finalizeDerived(hostname: hostname)
            let rebuildStillRequired = try ledger.requiresParserRebuild(
                currentParserVersion: UsageJSONLParser.parserVersion
            )
            try require(
                !rebuildStillRequired,
                "rebuild still required after full parser v\(UsageJSONLParser.parserVersion) scan"
            )

            let buckets = try ledger.buckets(hostname: hostname)
            let sessions = try ledger.sessions(hostname: hostname)
            finalBucketCount = buckets.count
            finalSessionCount = sessions.count
            skillCalls = buckets.reduce(0) { partial, bucket in
                partial + bucket.skillCounts.values.reduce(0, +)
            }
            mcpCalls = buckets.reduce(0) { partial, bucket in
                partial + bucket.mcpCounts.values.reduce(0, +)
            }
            linesAdded = buckets.reduce(0) { saturatedAdd($0, $1.linesAdded) }
            linesDeleted = buckets.reduce(0) { saturatedAdd($0, $1.linesDeleted) }

            try require(scanTotals.files > 0 && scanTotals.bytes > 0, "no transcript files were scanned")
            let eventCount = try ledger.eventCount()
            try require(eventCount > 0, "full scan produced no usage events")
            try require(finalBucketCount > 0, "full scan produced no derived buckets")
            try require(finalSessionCount > 0, "full scan produced no derived sessions")
            try require(skillCalls > 0, "full scan produced no skill metrics")
            try require(mcpCalls > 0, "full scan produced no MCP metrics")
            try require(linesAdded > 0 || linesDeleted > 0, "full scan produced no edit metrics")
        }

        try checkpointWriteAheadLog(databaseURL)
        try verifyDatabase(databaseURL, expectedHostname: hostname)
        let final = try readSnapshot(databaseURL)
        try require(final.schemaVersion == Int64(UsageLedgerStore.schemaVersion), "final database schema is not current v\(UsageLedgerStore.schemaVersion)")
        try require(final.events > 0 && final.buckets > 0 && final.sessions > 0 && final.files > 0, "final database is missing rebuilt data")
        try require(state(protectedState, isPreservedBy: final.syncState), "final database lost protected sync state")
        try verifyOwnerOnlyFiles(databaseURL)

        print("ProductionDatabasePreflightVerification: PASS")
        print("schema_before=\(before.schemaVersion) schema_after=\(final.schemaVersion)")
        print("raw_events_before=\(before.events) raw_events_after=\(final.events)")
        print("files_scanned=\(scanTotals.files) bytes_scanned=\(scanTotals.bytes) diagnostics=\(scanTotals.diagnostics)")
        print("buckets=\(finalBucketCount) sessions=\(finalSessionCount)")
        print("skill_calls=\(skillCalls) mcp_calls=\(mcpCalls) lines_added=\(linesAdded) lines_deleted=\(linesDeleted)")
        print("full_scan buckets=\(finalBucketCount) sessions=\(finalSessionCount) skills=\(skillCalls) mcp=\(mcpCalls) linesAdded=\(linesAdded) linesDeleted=\(linesDeleted)")
    }

    private static func scan(
        root: URL,
        source: String,
        includeSubagents: Bool,
        hostname: String,
        ledger: UsageLedgerStore,
        totals: inout ScanTotals
    ) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw PreflightFailure.failed("required transcript source is unreadable: \(source)")
        }
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let modifiedAt = values.contentModificationDate ?? Date()
            let parsed = UsageJSONLParser.parse(
                data: data,
                source: source,
                fileIdentity: url.path,
                modifiedAt: modifiedAt,
                isSubagent: includeSubagents && isSubagentTranscript(url)
            )
            try ledger.record(
                events: parsed.events,
                sessionEvents: parsed.sessionEvents,
                editEntries: parsed.editEntries,
                editMetricsSupported: true,
                checkpoint: parsed.checkpoint,
                hostname: hostname
            )
            totals.files += 1
            totals.bytes = saturatedAdd(totals.bytes, Int64(values.fileSize ?? data.count))
            totals.diagnostics += parsed.diagnostics.count
            if totals.files.isMultiple(of: progressInterval) {
                print("scan_progress_files=\(totals.files)")
            }
        }
    }

    private static func isSubagentTranscript(_ url: URL) -> Bool {
        url.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
            && url.deletingLastPathComponent().lastPathComponent == "subagents"
    }

    private static func liveDatabaseURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appending(path: "AgentPulse/usage.sqlite3")
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? FileManager.default.attributesOfItem(atPath: lhs.path),
              let right = try? FileManager.default.attributesOfItem(atPath: rhs.path),
              let leftDevice = left[.systemNumber] as? NSNumber,
              let rightDevice = right[.systemNumber] as? NSNumber,
              let leftInode = left[.systemFileNumber] as? NSNumber,
              let rightInode = right[.systemFileNumber] as? NSNumber else {
            return false
        }
        return leftDevice == rightDevice && leftInode == rightInode
    }

    private static func state(_ expected: [String: String], isPreservedBy actual: [String: String]) -> Bool {
        expected.allSatisfy { actual[$0.key] == $0.value }
    }

    private static func verifyDatabase(_ url: URL, expectedHostname: String) throws {
        try withDatabase(url, readOnly: true) { db in
            let quickCheck = try scalarText(db, "PRAGMA quick_check;")
            let integrityCheck = try scalarText(db, "PRAGMA integrity_check;")
            let foreignKeyFailures = try scalarInt(db, "SELECT COUNT(*) FROM pragma_foreign_key_check;")
            let staleParsers = try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_files WHERE parser_version != \(UsageJSONLParser.parserVersion);"
            )
            let invalidStatuses = try scalarInt(db, "SELECT COUNT(*) FROM usage_files WHERE scan_status NOT IN ('complete','degraded');")
            let wrongBucketHosts = try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_buckets WHERE hostname != \(quoted(expectedHostname));"
            )
            let wrongSessionHosts = try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_sessions WHERE hostname != \(quoted(expectedHostname));"
            )
            try require(quickCheck == "ok", "quick_check failed")
            try require(integrityCheck == "ok", "integrity_check failed")
            try require(foreignKeyFailures == 0, "foreign_key_check failed")
            try require(
                staleParsers == 0,
                "not every checkpoint is parser v\(UsageJSONLParser.parserVersion)"
            )
            try require(invalidStatuses == 0, "invalid scan status")
            try require(wrongBucketHosts == 0, "derived bucket hostname mismatch")
            try require(wrongSessionHosts == 0, "derived session hostname mismatch")
            let invalidTimestamps = """
                SELECT COUNT(*) FROM (
                  SELECT timestamp_ms AS value FROM usage_events WHERE timestamp_ms<0
                  UNION ALL SELECT timestamp_ms FROM usage_session_events WHERE timestamp_ms<0
                  UNION ALL SELECT timestamp_ms FROM usage_edit_entries WHERE timestamp_ms<0
                  UNION ALL SELECT bucket_start_ms FROM usage_buckets WHERE bucket_start_ms<0
                  UNION ALL SELECT first_activity_ms FROM usage_sessions WHERE first_activity_ms<0
                  UNION ALL SELECT last_activity_ms FROM usage_sessions WHERE last_activity_ms<0
                  UNION ALL SELECT mtime_ms FROM usage_files WHERE mtime_ms<0
                );
                """
            let negativeTimestamps = try scalarInt(db, invalidTimestamps)
            try require(negativeTimestamps == 0, "negative timestamps remain after rebuild")
        }
    }

    private static func checkpointWriteAheadLog(_ url: URL) throws {
        try withDatabase(url, readOnly: false) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &statement, nil) == SQLITE_OK else {
                throw sqliteError(db)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
            let busy = sqlite3_column_int(statement, 0)
            try require(busy == 0, "unable to checkpoint the offline database copy")
        }
    }

    private static func verifyOwnerOnlyFiles(_ databaseURL: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber else {
                throw PreflightFailure.failed("unable to read database permissions")
            }
            try require(permissions.intValue & 0o077 == 0, "database file is accessible by group or other users")
        }
    }

    private static func readSnapshot(_ url: URL) throws -> DatabaseSnapshot {
        try withDatabase(url, readOnly: true) { db in
            let version = try scalarInt(db, "PRAGMA user_version;")
            let events = try tableExists(db, "usage_events") ? scalarInt(db, "SELECT COUNT(*) FROM usage_events;") : 0
            let buckets = try tableExists(db, "usage_buckets") ? scalarInt(db, "SELECT COUNT(*) FROM usage_buckets;") : 0
            let sessions = try tableExists(db, "usage_sessions") ? scalarInt(db, "SELECT COUNT(*) FROM usage_sessions;") : 0
            let files = try tableExists(db, "usage_files") ? scalarInt(db, "SELECT COUNT(*) FROM usage_files;") : 0
            let syncState = try tableExists(db, "sync_state") ? readSyncState(db) : [:]
            return DatabaseSnapshot(
                schemaVersion: version,
                events: events,
                buckets: buckets,
                sessions: sessions,
                files: files,
                syncState: syncState
            )
        }
    }

    private static func withDatabase<T>(_ url: URL, readOnly: Bool, _ body: (OpaquePointer?) throws -> T) throws -> T {
        var database: OpaquePointer?
        // A cold copy of a WAL-mode database can legitimately contain only the checkpointed main
        // file. SQLite's regular read-only open then tries to create a new shared-memory sidecar and
        // can fail on the first statement even though sqlite3_open_v2 itself succeeded. Use immutable
        // mode only when no non-empty WAL exists and no SHM sidecar exists; a non-empty orphan WAL is
        // never ignored because it may contain uncheckpointed data.
        let manager = FileManager.default
        let walPath = url.path + "-wal"
        let shmPath = url.path + "-shm"
        let walSize = ((try? manager.attributesOfItem(atPath: walPath)[.size]) as? NSNumber)?.int64Value ?? 0
        let useImmutable = readOnly && walSize == 0 && !manager.fileExists(atPath: shmPath)
        let path = useImmutable ? url.absoluteString + "?mode=ro&immutable=1" : url.path
        let flags = useImmutable
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            : (readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
        let result = sqlite3_open_v2(path, &database, flags, nil)
        guard result == SQLITE_OK else {
            sqlite3_close_v2(database)
            throw PreflightFailure.failed("unable to inspect offline database copy")
        }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }

    private static func tableExists(_ db: OpaquePointer?, _ table: String) throws -> Bool {
        try scalarInt(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=\(quoted(table));") == 1
    }

    private static func readSyncState(_ db: OpaquePointer?) throws -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key,value FROM sync_state ORDER BY key;", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let value = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            result[key] = value
        }
        try require(sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE, "unable to read sync state")
        return result
    }

    private static func scalarInt(_ db: OpaquePointer?, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        return sqlite3_column_int64(statement, 0)
    }

    private static func scalarText(_ db: OpaquePointer?, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw sqliteError(db) }
        return String(cString: text)
    }

    private static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func sqliteError(_ db: OpaquePointer?) -> PreflightFailure {
        .failed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable")
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
