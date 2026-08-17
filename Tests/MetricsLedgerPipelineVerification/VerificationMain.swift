import Foundation
import SQLite3
import AgentPulseCore

private enum VerificationFailure: Error, CustomStringConvertible {
    case assertion(String)
    case sqlite(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        case let .sqlite(message): message
        }
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationFailure.assertion(message) }
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw VerificationFailure.assertion(message) }
    return value
}

@main
struct MetricsLedgerPipelineVerification {
    static func main() throws {
        let verifier = MetricsLedgerPipelineVerifier()
        try verifier.verifyV7MigrationIsAdditive()
        try verifier.verifyMetricsPersistAggregateAndMapToDerivedRows()
        try verifier.verifyContentDedupKeyCollapsesForkCopies()
        try verifier.verifyCalendarWindowSummariesUseDerivedBucketsAndHostname()
        try verifier.verifyFinalizeIsScopedToHostname()
        try verifier.verifyLegacyRawRowsAreClaimedOnlyByCanonicalHostname()
        print("MetricsLedgerPipelineVerification: PASS")
    }
}

private struct MetricsLedgerPipelineVerifier {
    func verifyV7MigrationIsAdditive() throws {
        let database = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: database) }

        try withDatabase(database) { db in
            try execute(db, "CREATE TABLE usage_events(event_id TEXT PRIMARY KEY);")
            try execute(db, "CREATE TABLE usage_buckets(hostname TEXT,source TEXT,model TEXT,project TEXT,bucket_start_ms INTEGER);")
            try execute(db, "CREATE TABLE usage_sessions(hostname TEXT,source TEXT,session_hash TEXT);")
            // 合法真实 v6 库必然带 usage_session_events（v1->v2 建表）；fixture 补齐它并塞一行 legacy 事件，
            // 才能真实检验 v7->v8 对该表的「新增 source_file_hash 并入 PK」重建是加法且不丢行。
            try execute(db, "CREATE TABLE usage_session_events(event_id TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,role TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,created_at_ms INTEGER NOT NULL,PRIMARY KEY(source,event_id));")
            // 合法真实旧库自 v1 起即带 usage_files / sync_state 基线表；v7->v8 迁移会向 sync_state 写 raw-dirty 门禁键，
            // fixture 必须补齐，才是真实可迁移的旧 schema。
            try execute(db, "CREATE TABLE usage_files(file_id TEXT PRIMARY KEY,source TEXT NOT NULL,path_hash TEXT NOT NULL,read_offset INTEGER NOT NULL,file_size INTEGER NOT NULL,mtime_ms INTEGER NOT NULL,parser_version INTEGER NOT NULL,scan_status TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);")
            try execute(db, "CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);")
            try execute(db, "INSERT INTO usage_events(event_id) VALUES('legacy');")
            try execute(db, "INSERT INTO usage_session_events(event_id,source,session_hash,role,timestamp_ms,created_at_ms) VALUES('legacy-se','codex','sess','user',0,0);")
            try execute(db, "PRAGMA user_version=6;")
        }

        do {
            let ledger = try UsageLedgerStore(path: database.path)
            try require(try ledger.eventCount() == 1, "migrated ledger must retain the legacy event")
        }

        try withDatabase(database) { db in
            try require(try scalarInt(db, "PRAGMA user_version;") == Int64(UsageLedgerStore.schemaVersion), "legacy v6 database must migrate to the current schema version")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM usage_events WHERE event_id='legacy';") == 1, "migration must retain legacy rows")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM pragma_table_info('usage_events') WHERE name='skill_counts_json';") == 1, "usage event skill column must exist")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM pragma_table_info('usage_buckets') WHERE name='code_metric_version';") == 1, "bucket code metric version column must exist")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM pragma_table_info('usage_sessions') WHERE name='skills_json';") == 1, "session skills column must exist")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='usage_edit_entries';") == 1, "raw edit table must exist")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM pragma_table_info('usage_session_events') WHERE name='source_file_hash';") == 1, "session event file-attribution column must exist")
            try require(try scalarInt(db, "SELECT COUNT(*) FROM usage_session_events WHERE event_id='legacy-se';") == 1, "v8 rebuild must retain legacy session events")
        }
    }

    func verifyMetricsPersistAggregateAndMapToDerivedRows() throws {
        let database = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: database) }
        let ledger = try UsageLedgerStore(path: database.path)
        let timestamp = try date("2026-08-14T01:05:00Z")
        let later = try date("2026-08-14T01:10:00Z")
        let editOnly = try date("2026-08-14T01:45:00Z")
        let source = "codex"
        let session = "session-a"

        let original = UsageEvent(
            id: "event-original", source: source, model: "model-a", project: "project-a",
            timestamp: timestamp, counts: UsageTokenCounts(input: 10, reportedTotal: 10),
            sessionHash: session, sourceFileHash: "file-a", hasTotalSnapshot: true,
            lineageFingerprint: "shared-snapshot", skillCounts: ["review": 2], mcpCounts: ["filesystem": 1]
        )
        let inherited = UsageEvent(
            id: "event-inherited", source: source, model: "model-a", project: "project-a",
            timestamp: timestamp, counts: UsageTokenCounts(input: 10, reportedTotal: 10),
            sessionHash: "child-session", sourceFileHash: "file-b", inherited: true,
            hasTotalSnapshot: true, lineageFingerprint: "shared-snapshot",
            skillCounts: ["review": 3, "child-only": 1], mcpCounts: ["filesystem": 2]
        )
        let independent = UsageEvent(
            id: "event-independent", source: source, model: "model-a", project: "project-a",
            timestamp: later, counts: UsageTokenCounts(input: 5, reportedTotal: 5),
            sessionHash: session, sourceFileHash: "file-a", skillCounts: ["build": 1],
            mcpCounts: ["filesystem": 1]
        )
        let sessionEvents = [
            UsageSessionEvent(id: "user", source: source, sessionHash: session, role: .user, timestamp: timestamp),
            UsageSessionEvent(id: "assistant", source: source, sessionHash: session, role: .assistant, timestamp: later),
        ]
        let edits = [
            UsageEditEntry(source: source, model: "model-a", project: "project-a", timestamp: timestamp, added: 3, deleted: 1, toolUseID: "global-edit"),
            UsageEditEntry(source: "other", model: "other", project: "other", timestamp: timestamp, added: 99, deleted: 99, toolUseID: "global-edit"),
            UsageEditEntry(source: source, model: "model-a", project: "project-a", timestamp: editOnly, added: 7, deleted: 2, toolUseID: "edit-only"),
        ]
        // v8 record 语义为「按 checkpoint.fileID 的文件级原子替换」，本批所有行的 sourceFileHash 必须为空或等于该 fileID。
        // original/independent 属 file-a、inherited 属 file-b（跨会话共享同一 lineage 指纹）：因此分两次 record，
        // 各自携带对应文件的 checkpoint，绝不在单批里混入他文件归属。session 事件与 edit 归属 file-a。
        let checkpointA = UsageFileCheckpoint(
            fileID: "file-a", source: source, pathHash: "path-a", offset: 10, size: 10,
            modifiedAt: later, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        let checkpointB = UsageFileCheckpoint(
            fileID: "file-b", source: source, pathHash: "path-b", offset: 10, size: 10,
            modifiedAt: later, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )

        try ledger.record(
            events: [original, independent], sessionEvents: sessionEvents,
            editEntries: edits, editMetricsSupported: true, checkpoint: checkpointA, hostname: "host-a"
        )
        try ledger.record(
            events: [inherited], sessionEvents: [], editEntries: [],
            editMetricsSupported: true, checkpoint: checkpointB, hostname: "host-a"
        )
        let finalized = try ledger.finalizeDerived(hostname: "host-a")
        try require(finalized.collapsedInheritedEvents == 1, "lineage duplicate must collapse once")

        let buckets = try ledger.buckets(hostname: "host-a")
        try require(buckets.count == 2, "token and edit-only buckets must both materialize")
        let tokenBucket = try unwrap(buckets.first { $0.counts.total > 0 }, "token bucket must exist")
        try require(tokenBucket.counts.input == 15, "lineage token counts must not double count")
        try require(tokenBucket.skillCounts == ["build": 1, "child-only": 1, "review": 3], "skill counts must merge by lineage max then bucket sum")
        try require(tokenBucket.skills == ["build", "child-only", "review"], "skills must contain sorted skill-count keys")
        try require(tokenBucket.mcpCounts == ["filesystem": 3], "MCP counts must merge by lineage max then bucket sum")
        try require(tokenBucket.linesAdded == 3 && tokenBucket.linesDeleted == 1 && tokenBucket.linesNet == 2, "token bucket edit lines must aggregate")
        try require(tokenBucket.codeMetricVersion == 2, "supported token bucket must advertise code metric v2")

        let editBucket = try unwrap(buckets.first { $0.counts.total == 0 }, "edit-only bucket must exist")
        try require(editBucket.source == source, "global tool-use dedupe must preserve the first edit source")
        try require(editBucket.linesAdded == 7 && editBucket.linesDeleted == 2 && editBucket.linesNet == 5, "edit-only bucket lines must aggregate")
        try require(editBucket.codeMetricVersion == 2, "edit-only bucket must advertise code metric v2")
        try require(!buckets.contains { $0.source == "other" }, "tool-use IDs must dedupe globally across sources")

        let sessions = try ledger.sessions(hostname: "host-a")
        try require(sessions.count == 1, "session aggregation must retain one session")
        try require(sessions[0].skills == ["build", "review"], "session skills must come from non-inherited token events")

        let pending = try ledger.pendingBatch(hostname: "host-a")
        try require(pending.buckets.map(\.bucket) == buckets, "pending bucket payload must retain metrics")
        try require(pending.sessions.map(\.session) == sessions, "pending session payload must retain skills")
        try ledger.acknowledge(pending)
        try require(try ledger.pendingBatch(hostname: "host-a").isEmpty, "acknowledged metrics must no longer be pending")
    }

    /// 内容型去重键：fork/subagent 复制出的、内容逐字节相同的 codex 事件（不同
    /// event_id、不同文件、无血缘指纹）必须在 finalize 折叠为单份，桶总量等于一份，
    /// 而非两份。这直接对齐参考实现的跨文件 DedupKey 折叠。
    func verifyContentDedupKeyCollapsesForkCopies() throws {
        let database = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: database) }
        let ledger = try UsageLedgerStore(path: database.path)
        let timestamp = try date("2026-08-14T02:05:00Z")
        let source = "codex"
        let sharedKey = "codex:deadbeefcafef00d1234567890abcdef"

        // 两份 fork 副本：内容相同（同 counts），共享同一 codexDedupKey，但 event_id、
        // 文件归属、时间戳不同，且 lineageFingerprint 为空 —— 血缘层不会折叠它们，
        // 只有新增的内容折叠能把它们并成一份。
        func forkCopy(id: String, file: String, ts: Date) -> UsageEvent {
            UsageEvent(
                id: id, source: source, model: "model-a", project: "project-a",
                timestamp: ts, counts: UsageTokenCounts(input: 100, output: 20, cachedInput: 500, reportedTotal: 620),
                sessionHash: "session-fork", sourceFileHash: file, hasTotalSnapshot: true,
                lineageFingerprint: "", codexDedupKey: sharedKey
            )
        }
        let copyA = forkCopy(id: "event-fork-a", file: "file-a", ts: timestamp)
        let copyB = forkCopy(id: "event-fork-b", file: "file-b", ts: timestamp.addingTimeInterval(120))
        let checkpointA = UsageFileCheckpoint(
            fileID: "file-a", source: source, pathHash: "path-a", offset: 1, size: 1,
            modifiedAt: timestamp, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        let checkpointB = UsageFileCheckpoint(
            fileID: "file-b", source: source, pathHash: "path-b", offset: 1, size: 1,
            modifiedAt: timestamp, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        try ledger.record(events: [copyA], checkpoint: checkpointA, hostname: "host-a")
        try ledger.record(events: [copyB], checkpoint: checkpointB, hostname: "host-a")

        let finalized = try ledger.finalizeDerived(hostname: "host-a")
        try require(finalized.collapsedContentDuplicates == 1, "one fork copy must collapse by content dedup key")
        try require(finalized.collapsedInheritedEvents == 0, "lineage layer must not touch empty-fingerprint fork copies")

        let buckets = try ledger.buckets(hostname: "host-a")
        let fiveSum = buckets.reduce(Int64(0)) { $0 + $1.counts.billableTotal }
        try require(fiveSum == 620, "fork copies must contribute a single copy's tokens (620), not double (1240)")

        // 反向：不同内容 → 不同 key → 不折叠。
        let db2 = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: db2) }
        let ledger2 = try UsageLedgerStore(path: db2.path)
        let distinct = UsageEvent(
            id: "event-distinct", source: source, model: "model-a", project: "project-a",
            timestamp: timestamp, counts: UsageTokenCounts(input: 7, reportedTotal: 7),
            sessionHash: "session-fork", sourceFileHash: "file-a", hasTotalSnapshot: true,
            lineageFingerprint: "", codexDedupKey: "codex:0000000000000000ffffffffffffffff"
        )
        try ledger2.record(events: [copyA, distinct], checkpoint: checkpointA, hostname: "host-a")
        let finalized2 = try ledger2.finalizeDerived(hostname: "host-a")
        try require(finalized2.collapsedContentDuplicates == 0, "different content keys must not fold")

        // largest-billable-wins：同键但后一份 counts 更大，必须换成更大的一份（不能被
        // 快速路径误留小份）。同时后一份带 skill，折叠后桶必须保留该 skill（skill/mcp
        // 并集不为空时快速路径不能跳过重建）。
        let db3 = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: db3) }
        let ledger3 = try UsageLedgerStore(path: db3.path)
        let smallFirst = UsageEvent(
            id: "event-small", source: source, model: "model-a", project: "project-a",
            timestamp: timestamp, counts: UsageTokenCounts(input: 10, output: 2, reportedTotal: 12),
            sessionHash: "session-fork", sourceFileHash: "file-a", hasTotalSnapshot: true,
            lineageFingerprint: "", codexDedupKey: sharedKey
        )
        let bigSecond = UsageEvent(
            id: "event-big", source: source, model: "model-a", project: "project-a",
            timestamp: timestamp.addingTimeInterval(120),
            counts: UsageTokenCounts(input: 1000, output: 200, reportedTotal: 1200),
            sessionHash: "session-fork", sourceFileHash: "file-b", hasTotalSnapshot: true,
            lineageFingerprint: "", codexDedupKey: sharedKey, skillCounts: ["big-skill": 1]
        )
        try ledger3.record(events: [smallFirst], checkpoint: checkpointA, hostname: "host-a")
        try ledger3.record(events: [bigSecond], checkpoint: checkpointB, hostname: "host-a")
        let finalized3 = try ledger3.finalizeDerived(hostname: "host-a")
        try require(finalized3.collapsedContentDuplicates == 1, "larger fork copy must still collapse the smaller one")
        let buckets3 = try ledger3.buckets(hostname: "host-a")
        let fiveSum3 = buckets3.reduce(Int64(0)) { $0 + $1.counts.billableTotal }
        try require(fiveSum3 == 1200, "largest-billable-wins must keep the bigger copy (1200), not the smaller (12)")
        try require(buckets3.contains { $0.skills.contains("big-skill") },
                    "skill from the kept copy must survive the content fold (fast-path must not drop non-empty skill union)")
    }

    func verifyCalendarWindowSummariesUseDerivedBucketsAndHostname() throws {
        let database = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: database) }
        let ledger = try UsageLedgerStore(path: database.path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try unwrap(TimeZone(identifier: "Asia/Shanghai"), "Asia/Shanghai time zone must exist")
        let reference = try localDate(2026, 8, 14, 12, calendar: calendar)

        let inside = UsageTokenCounts(input: 10, output: 3, cachedInput: 5, cacheCreationInput: 2, reportedTotal: 20)
        // 参考时刻 2026-08-14 12:00：day=[08-14 00:00,08-15 00:00)，week=[08-07 12:00,ref)，month=[07-15 12:00,ref)。
        try insertBucket(database, hostname: "host-a", model: "unknown", at: localDate(2026, 8, 14, 0, calendar: calendar), counts: inside) // day + week + month
        try insertBucket(database, hostname: "host-a", model: "model-a", at: localDate(2026, 8, 10, 0, calendar: calendar), counts: UsageTokenCounts(input: 20, reportedTotal: 20)) // week + month，非 day
        try insertBucket(database, hostname: "host-a", model: "model-a", at: localDate(2026, 8, 1, 0, calendar: calendar), counts: UsageTokenCounts(input: 30, reportedTotal: 30)) // month，非 week
        try insertBucket(database, hostname: "host-a", model: "model-a", at: localDate(2026, 7, 1, 0, calendar: calendar), counts: UsageTokenCounts(input: 40, reportedTotal: 40)) // 早于 month 起点
        try insertBucket(database, hostname: "host-a", model: "model-a", at: localDate(2026, 8, 15, 0, calendar: calendar), counts: UsageTokenCounts(input: 50, reportedTotal: 50)) // 晚于 day/week/month 右界，仍计入 all-time
        try insertBucket(database, hostname: "host-b", model: "model-a", at: localDate(2026, 8, 14, 0, calendar: calendar), counts: UsageTokenCounts(input: 99, reportedTotal: 99)) // 其它 hostname

        let day = try unwrap(ledger.summary(window: .day, containing: reference, hostname: "host-a", calendar: calendar), "day summary must exist")
        try require(day.counts == inside, "day window must be left-closed and right-open")
        try require(day.cachedTokens == 5 && day.newTokens == 10, "summary cache/new-token semantics: cached=cache-read, new=pure input (excludes cache creation)")
        let expectedCost = UsageCostEstimator.cost(model: "unknown", counts: inside)
        try require(abs(day.estimatedCostUSD - expectedCost) <= 0.000_000_001, "unknown model cost must use estimator fallback")

        try require(try ledger.summary(window: .week, containing: reference, hostname: "host-a", calendar: calendar)?.counts.input == 30, "week window is the rolling 7-day range ending at the reference instant")
        try require(try ledger.summary(window: .month, containing: reference, hostname: "host-a", calendar: calendar)?.counts.input == 60, "month window is the rolling 30-day range ending at the reference instant")
        try require(try ledger.summary(window: nil, containing: reference, hostname: "host-a", calendar: calendar)?.counts.input == 150, "hostname all-time summary")
        try require(try ledger.summary(window: .day, containing: reference, calendar: calendar)?.counts.input == 109, "display day summary must include every hostname")
        try require(try ledger.summary(window: .week, containing: reference, calendar: calendar)?.counts.input == 129, "display week summary must include every hostname")
        try require(try ledger.summary(window: .month, containing: reference, calendar: calendar)?.counts.input == 159, "display month summary must include every hostname")
        try require(try ledger.summary(window: nil, containing: reference, calendar: calendar)?.counts.input == 249, "display all-time summary must include every hostname")
        let displayModels = try ledger.modelSummary(window: .day, containing: reference, calendar: calendar)
        try require(displayModels.first(where: { $0.model == "model-a" })?.counts.input == 99, "display model summary must preserve cross-host model totals")
        try require(displayModels.first(where: { $0.model == "unknown" })?.counts.input == 10, "display model summary must preserve other models")
        let displayWeekModels = try ledger.modelSummary(window: .week, containing: reference, calendar: calendar)
        try require(displayWeekModels.first(where: { $0.model == "model-a" })?.counts.input == 119, "display model summary must sum the same model across hostnames")
        let dayInterval = try unwrap(UsageSummaryWindow.day.interval(containing: reference, calendar: calendar), "day interval must exist")
        let displayOutput = try ledger.outputTokenBuckets(start: dayInterval.start, end: reference)
        try require(displayOutput.count == 1, "display output buckets must group the same bucket across hostnames")
        try require(displayOutput.reduce(Int64(0)) { $0 + $1.outputTokens } == 3, "display output buckets must include all hostnames")
        let displayOutputByModel = try ledger.outputTokenBucketsByModel(start: dayInterval.start, end: reference)
        try require(displayOutputByModel.count == 2, "display model output buckets must group by bucket and model")
        try require(displayOutputByModel.first(where: { $0.model == "unknown" })?.outputTokens == 3, "display model output buckets must aggregate across hostnames")
        try require(try ledger.summary()?.counts.input == 249, "legacy summary must remain cross-host all-time")
        try require(try ledger.summary(window: .day, containing: localDate(2024, 1, 1, 12, calendar: calendar), hostname: "host-a", calendar: calendar) == nil, "empty summary window must return nil")
        try require(try ledger.summary(window: .day, containing: localDate(2024, 1, 1, 12, calendar: calendar), calendar: calendar) == nil, "empty display summary window must return nil")
    }

    func verifyFinalizeIsScopedToHostname() throws {
        let database = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: database) }
        let ledger = try UsageLedgerStore(path: database.path)
        let timestamp = try date("2026-08-18T01:00:00Z")

        func checkpoint(_ fileID: String) -> UsageFileCheckpoint {
            UsageFileCheckpoint(
                fileID: fileID, source: "verification", pathHash: fileID,
                offset: 1, size: 1, modifiedAt: timestamp,
                parserVersion: UsageJSONLParser.parserVersion, status: "complete"
            )
        }
        func event(_ id: String, fileID: String, input: Int64) -> UsageEvent {
            UsageEvent(
                id: id, source: "verification", model: "model", project: "project",
                timestamp: timestamp, counts: UsageTokenCounts(input: input, reportedTotal: input),
                sessionHash: "session-(id)", sourceFileHash: fileID
            )
        }

        try ledger.record(events: [event("a1", fileID: "file-a", input: 10)], checkpoint: checkpoint("file-a"), hostname: "host-a")
        try ledger.record(events: [event("b1", fileID: "file-b", input: 20)], checkpoint: checkpoint("file-b"), hostname: "host-b")
        _ = try ledger.finalizeDerived(hostname: "host-a")
        _ = try ledger.finalizeDerived(hostname: "host-b")
        try require(try ledger.summary(window: nil, containing: timestamp, hostname: "host-a")?.counts.input == 10, "host-a finalize must not consume host-b raw events")
        try require(try ledger.summary(window: nil, containing: timestamp, hostname: "host-b")?.counts.input == 20, "host-b finalize must retain its own derived rows")

        try ledger.record(events: [event("a2", fileID: "file-a", input: 30)], checkpoint: checkpoint("file-a"), hostname: "host-a")
        _ = try ledger.finalizeDerived(hostname: "host-a")
        try require(try ledger.summary(window: nil, containing: timestamp, hostname: "host-a")?.counts.input == 30, "host-a refinalize must only replace host-a derived rows")
        try require(try ledger.summary(window: nil, containing: timestamp, hostname: "host-b")?.counts.input == 20, "host-a refinalize must not mutate host-b derived rows")
        try require(try ledger.summary(window: nil, containing: timestamp)?.counts.input == 50, "display summary must add independently derived hostnames")
    }

    func verifyLegacyRawRowsAreClaimedOnlyByCanonicalHostname() throws {
        let database = try temporaryDatabaseURL()
        defer { cleanupDatabase(at: database) }
        let ledger = try UsageLedgerStore(path: database.path)
        let timestamp = try date("2026-08-18T02:00:00Z")
        func checkpoint(_ fileID: String) -> UsageFileCheckpoint {
            UsageFileCheckpoint(
                fileID: fileID, source: "verification", pathHash: fileID,
                offset: 1, size: 1, modifiedAt: timestamp,
                parserVersion: UsageJSONLParser.parserVersion, status: "complete"
            )
        }
        func event(_ id: String, fileID: String, input: Int64) -> UsageEvent {
            UsageEvent(
                id: id, source: "verification", model: "model", project: "project",
                timestamp: timestamp, counts: UsageTokenCounts(input: input, reportedTotal: input),
                sessionHash: "session-\(id)", sourceFileHash: fileID
            )
        }

        // 首次 record 建立 canonical=host-a；模拟 v10 迁移后仍残留的一条空 hostname 原始行。
        try ledger.record(events: [event("legacy", fileID: "file-a", input: 10)], checkpoint: checkpoint("file-a"), hostname: "host-a")
        try ledger.record(events: [event("owned-b", fileID: "file-b", input: 20)], checkpoint: checkpoint("file-b"), hostname: "host-b")
        try withDatabase(database) { db in
            try execute(db, "UPDATE usage_events SET hostname='' WHERE event_id='legacy';")
            try execute(db, "INSERT INTO sync_state(key,value,updated_at_ms) VALUES('unresolved_legacy_raw_hostname','1',0);")
        }

        _ = try ledger.finalizeDerived(hostname: "host-b")
        try require(try ledger.summary(window: nil, containing: timestamp, hostname: "host-b")?.counts.input == 20, "non-canonical finalize must ignore legacy raw rows")
        try withDatabase(database) { db in
            try require(try scalarInt(db, "SELECT COUNT(*) FROM usage_events WHERE event_id='legacy' AND hostname='';") == 1, "non-canonical finalize must not claim legacy raw rows")
        }

        _ = try ledger.finalizeDerived(hostname: "host-a")
        try require(try ledger.summary(window: nil, containing: timestamp, hostname: "host-a")?.counts.input == 10, "canonical finalize must claim legacy raw rows exactly once")
        try require(try ledger.summary(window: nil, containing: timestamp)?.counts.input == 30, "cross-host display must not double count legacy raw rows")
        try withDatabase(database) { db in
            try require(try scalarInt(db, "SELECT COUNT(*) FROM usage_events WHERE event_id='legacy' AND hostname='host-a';") == 1, "canonical finalize must persist legacy ownership")
        }
    }

    private func temporaryDatabaseURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("usage.sqlite")
    }

    private func cleanupDatabase(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        } catch {
            let message = "MetricsLedgerPipelineVerification cleanup failed: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
        }
    }

    private func date(_ value: String) throws -> Date {
        try unwrap(ISO8601DateFormatter().date(from: value), "invalid fixture date: \(value)")
    }

    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, minute: Int = 0, calendar: Calendar) throws -> Date {
        try unwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)), "invalid local fixture date")
    }

    private func withDatabase(_ url: URL, _ body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        let result = url.path.withCString { sqlite3_open_v2($0, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) }
        guard result == SQLITE_OK, let handle else { throw VerificationFailure.sqlite("unable to open fixture database") }
        defer { sqlite3_close_v2(handle) }
        try body(handle)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func scalarInt(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
        return sqlite3_column_int64(statement, 0)
    }

    private func insertBucket(_ url: URL, hostname: String, model: String, at date: Date, counts: UsageTokenCounts) throws {
        try withDatabase(url) { db in
            let sql = """
                INSERT INTO usage_buckets(
                  hostname,source,model,project,bucket_start_ms,input_tokens,output_tokens,
                  cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,
                  revision,synced_revision,updated_at_ms
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
            defer { sqlite3_finalize(statement) }
            try bindText(statement, index: 1, value: hostname, db: db)
            try bindText(statement, index: 2, value: "codex", db: db)
            try bindText(statement, index: 3, value: model, db: db)
            try bindText(statement, index: 4, value: "project", db: db)
            try bindInt64(statement, index: 5, value: Int64((date.timeIntervalSince1970 * 1_000).rounded()), db: db)
            try bindInt64(statement, index: 6, value: counts.input, db: db)
            try bindInt64(statement, index: 7, value: counts.output, db: db)
            try bindInt64(statement, index: 8, value: counts.cachedInput, db: db)
            try bindInt64(statement, index: 9, value: counts.cacheCreationInput, db: db)
            try bindInt64(statement, index: 10, value: counts.reasoningOutput, db: db)
            try bindInt64(statement, index: 11, value: counts.total, db: db)
            try bindInt64(statement, index: 12, value: 1, db: db)
            try bindInt64(statement, index: 13, value: 0, db: db)
            try bindInt64(statement, index: 14, value: Int64((date.timeIntervalSince1970 * 1_000).rounded()), db: db)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
        }
    }

    private func bindText(_ statement: OpaquePointer?, index: Int32, value: String, db: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard result == SQLITE_OK else { throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db))) }
    }

    private func bindInt64(_ statement: OpaquePointer?, index: Int32, value: Int64, db: OpaquePointer) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else {
            throw VerificationFailure.sqlite(String(cString: sqlite3_errmsg(db)))
        }
    }
}
