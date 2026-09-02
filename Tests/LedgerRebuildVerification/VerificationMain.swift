import AgentPulseCore
import Foundation
import SQLite3

/// Deterministic verification of the ledger rebuild chain: schema migration,
/// resetForRebuild, full rescan from transcripts, and derived aggregation.
///
/// Everything runs against a purpose-built transcript tree and a throwaway
/// database under the system temporary directory. The production ledger is
/// never opened, copied, or read - it is only referenced by path so the
/// live-database guard itself can be exercised.
///
/// UsageLedgerStore.resetForRebuild carries the note "生产不调用此路径", so this
/// target is its only guard. Run with:
/// swift run LedgerRebuildVerification
@main
struct LedgerRebuildVerification {
    static func main() throws {
        try verifyLiveDatabaseGuard()
        try verifyLegacySchemaMigrationPreservesWatermark()
        try verifyRebuildChain()
        print("LedgerRebuildVerification: PASS")
    }
}

// MARK: - Live database guard

/// The rebuild chain is destructive: it clears every rebuildable table before
/// rescanning. Pointing it at the live ledger would wipe history that no longer
/// exists on disk, so the guard must reject both the live path itself and any
/// hard link to it. Verified by assertion rather than by a startup check that
/// nobody observes - and without ever opening the live database.
private func verifyLiveDatabaseGuard() throws {
    let fixture = try Fixture(label: "live-guard")
    defer { fixture.cleanUp() }

    let live = try liveDatabaseURL()
    try require(!isRebuildTarget(live, live: live), "the live ledger path must be rejected")

    let ledgerPath = fixture.root.appendingPathComponent("usage.sqlite3", isDirectory: false)
    try Data().write(to: ledgerPath)
    try require(isRebuildTarget(ledgerPath, live: live), "an independent copy must be accepted")

    let link = fixture.root.appendingPathComponent("hardlink.sqlite3", isDirectory: false)
    try FileManager.default.linkItem(at: ledgerPath, to: link)
    try require(!isRebuildTarget(link, live: ledgerPath), "a hard link to the ledger must be rejected")

    let absent = fixture.root.appendingPathComponent("missing.sqlite3", isDirectory: false)
    try require(!isRebuildTarget(absent, live: live), "a non-existent path must be rejected")
}

/// Accepts a path only when it exists, is not the live ledger, and does not
/// share an inode with it. Neither database is opened.
private func isRebuildTarget(_ candidate: URL, live: URL) -> Bool {
    let target = candidate.resolvingSymlinksInPath().standardizedFileURL
    let liveTarget = live.resolvingSymlinksInPath().standardizedFileURL
    guard FileManager.default.fileExists(atPath: target.path) else { return false }
    guard target != liveTarget else { return false }
    return !sameFile(target, liveTarget)
}

private func liveDatabaseURL() throws -> URL {
    try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    ).appending(path: "AgentPulse/usage.sqlite3")
}

private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
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

// MARK: - Legacy schema migration

/// A v4 database is the oldest baseline this app still migrates. What matters
/// beyond reaching the current schema is that the per-host revision
/// high-watermark survives: acknowledgements are matched by revision, so losing
/// or regressing it risks acking a batch the server never received.
///
/// MetricsLedgerPipelineVerification already covers the v6 shape and the
/// column-level migration results. This case covers the watermark contract, on
/// a different baseline, across all three points where it could be dropped.
private func verifyLegacySchemaMigrationPreservesWatermark() throws {
    let fixture = try Fixture(label: "legacy-migration")
    defer { fixture.cleanUp() }

    let host = "fixture-host"
    let watermarkKey = "revision\u{1}\(host)"
    let expectedWatermark: Int64 = 4711
    let path = fixture.root.appendingPathComponent("legacy.sqlite3", isDirectory: false).path

    // Minimal v4 shape: enough tables for the migration chain to run, plus the
    // protected watermark and a frozen marker that reset must clear.
    try withDatabase(URL(fileURLWithPath: path), readOnly: false) { db in
        try execute(db, "CREATE TABLE usage_events(event_id TEXT PRIMARY KEY,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,session_hash TEXT NOT NULL,source_file_hash TEXT NOT NULL,created_at_ms INTEGER NOT NULL,rollout_key TEXT NOT NULL DEFAULT '',parent_rollout_key TEXT NOT NULL DEFAULT '',inherited INTEGER NOT NULL DEFAULT 0,has_total_snapshot INTEGER NOT NULL DEFAULT 0,lineage_fingerprint TEXT NOT NULL DEFAULT '');")
        try execute(db, "CREATE TABLE usage_buckets(hostname TEXT NOT NULL,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,bucket_start_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL,revision INTEGER NOT NULL DEFAULT 0,synced_revision INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(hostname,source,model,project,bucket_start_ms));")
        try execute(db, "CREATE TABLE usage_session_events(event_id TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,role TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,created_at_ms INTEGER NOT NULL,PRIMARY KEY(source,event_id));")
        try execute(db, "CREATE TABLE usage_sessions(hostname TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,first_activity_ms INTEGER NOT NULL,last_activity_ms INTEGER NOT NULL,active_seconds INTEGER NOT NULL,message_count INTEGER NOT NULL,user_message_count INTEGER NOT NULL,assistant_events INTEGER NOT NULL,hour_histogram TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,synced_revision INTEGER NOT NULL DEFAULT 0,updated_at_ms INTEGER NOT NULL,PRIMARY KEY(hostname,source,session_hash));")
        try execute(db, "CREATE TABLE usage_files(file_id TEXT PRIMARY KEY,source TEXT NOT NULL,path_hash TEXT NOT NULL,read_offset INTEGER NOT NULL,file_size INTEGER NOT NULL,mtime_ms INTEGER NOT NULL,parser_version INTEGER NOT NULL,scan_status TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);")
        try execute(db, "CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);")
        try execute(db, "INSERT INTO usage_events(event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,source_file_hash,created_at_ms) VALUES('legacy-v4','codex','model-a','project-a',1755000000000,10,5,0,0,0,15,'sess-legacy','',0);")
        try execute(db, "INSERT INTO sync_state(key,value,updated_at_ms) VALUES('\(watermarkKey)','\(expectedWatermark)',0);")
        try execute(db, "INSERT INTO sync_state(key,value,updated_at_ms) VALUES('frozen_before_ms\u{1}\(host)','123456',0);")
        try execute(db, "PRAGMA user_version=4;")
    }

    let before = try readSnapshot(URL(fileURLWithPath: path))
    try require(
        before.schemaVersion >= 1 && before.schemaVersion <= Int64(UsageLedgerStore.schemaVersion),
        "fixture baseline must sit between v1 and current v\(UsageLedgerStore.schemaVersion), got v\(before.schemaVersion)"
    )

    let ledger = try UsageLedgerStore(path: path)
    let migrated = try readSnapshot(URL(fileURLWithPath: path))
    try require(
        migrated.schemaVersion == Int64(UsageLedgerStore.schemaVersion),
        "migration must reach current schema v\(UsageLedgerStore.schemaVersion), got v\(migrated.schemaVersion)"
    )
    try require(
        watermark(watermarkKey, in: migrated.syncState) == expectedWatermark,
        "migration must preserve the revision high-watermark exactly"
    )
    try require(try ledger.eventCount() == 1, "migration must retain the legacy event")

    // resetForRebuild clears every rebuildable table. The watermark must survive
    // so post-reset rows keep counting up from it; the frozen marker must not,
    // because a stale frozen水位 would block rescanned data from being derived.
    try ledger.resetForRebuild()
    let afterReset = try readSnapshot(URL(fileURLWithPath: path))
    try require(
        afterReset.events == 0 && afterReset.buckets == 0
            && afterReset.sessions == 0 && afterReset.files == 0,
        "reset must clear every rebuildable table"
    )
    try require(
        watermark(watermarkKey, in: afterReset.syncState) == expectedWatermark,
        "reset must preserve the revision high-watermark"
    )
    try require(
        afterReset.syncState["frozen_before_ms\u{1}\(host)"] == nil,
        "reset must clear the frozen watermark so rescanned rows can derive"
    )
    try require(
        afterReset.syncState["rebuild_pending"] == "1",
        "reset must record the rebuild-pending marker in the same transaction"
    )
}

/// The watermark is protected monotonically: advancing is legitimate (re-derived
/// rows bump their revision), regressing is not.
private func watermark(_ key: String, in state: [String: String]) -> Int64? {
    state[key].flatMap(Int64.init)
}

// MARK: - Rebuild chain

/// Fixture shape. Every count below is asserted exactly, so a regression that
/// drops or duplicates a dimension fails instead of merely shrinking a total.
private enum Expected {
    static let host = "fixture-host"
    /// 2 codex transcripts + 2 claude transcripts.
    static let files = 4
    /// codex: 2 files x 2 token events. claude: 2 files x 2 assistant turns.
    static let events = 8
    /// One session per transcript.
    static let sessions = 4
    /// Skill tool_use blocks across the claude transcripts.
    static let skillCalls = 3
    /// MCP tool_use blocks across the claude transcripts.
    static let mcpCalls = 2
    static let linesAdded: Int64 = 12
    static let linesDeleted: Int64 = 4
}

/// Full chain on a self-built transcript tree: populate, reset, rescan, derive,
/// then check the structural invariants that only hold after a clean rebuild.
private func verifyRebuildChain() throws {
    let fixture = try Fixture(label: "rebuild-chain")
    defer { fixture.cleanUp() }

    let transcripts = try fixture.writeTranscriptTree()
    try require(
        transcripts.count == Expected.files,
        "fixture must provide \(Expected.files) transcripts, got \(transcripts.count)"
    )

    let databaseURL = fixture.root.appendingPathComponent("usage.sqlite3", isDirectory: false)
    let ledger = try UsageLedgerStore(path: databaseURL.path)

    // Populate once so reset has something to clear, then verify it cleared.
    var seed = ScanTotals()
    try scan(transcripts, hostname: Expected.host, ledger: ledger, totals: &seed)
    _ = try ledger.finalizeDerived(hostname: Expected.host)
    let seeded = try readSnapshot(databaseURL)
    try require(
        seeded.events > 0 && seeded.buckets > 0 && seeded.files > 0,
        "seed pass must populate raw and derived rows"
    )

    try ledger.resetForRebuild()
    let cleared = try readSnapshot(databaseURL)
    try require(
        cleared.events == 0 && cleared.buckets == 0
            && cleared.sessions == 0 && cleared.files == 0,
        "reset must clear every rebuildable table before the rescan"
    )

    // Full rescan from disk - the path a parser upgrade takes in production.
    var totals = ScanTotals()
    try scan(transcripts, hostname: Expected.host, ledger: ledger, totals: &totals)
    _ = try ledger.finalizeDerived(hostname: Expected.host)

    try require(
        totals.files == Expected.files,
        "rescan must read \(Expected.files) transcripts, got \(totals.files)"
    )
    try require(totals.bytes > 0, "rescan must read a non-zero number of bytes")
    try require(
        totals.diagnostics == 0,
        "fixture transcripts must parse without diagnostics, got \(totals.diagnostics)"
    )

    try require(
        !(try ledger.requiresParserRebuild(currentParserVersion: UsageJSONLParser.parserVersion)),
        "a full rescan at the current parser version must clear the rebuild flag"
    )

    let eventCount = try ledger.eventCount()
    try require(
        eventCount == Expected.events,
        "rescan must produce exactly \(Expected.events) events, got \(eventCount)"
    )

    let buckets = try ledger.buckets(hostname: Expected.host)
    let sessions = try ledger.sessions(hostname: Expected.host)
    try require(
        sessions.count == Expected.sessions,
        "rescan must derive \(Expected.sessions) sessions, got \(sessions.count)"
    )
    try require(!buckets.isEmpty, "rescan must derive at least one bucket")

    let skillCalls = buckets.reduce(0) { $0 + $1.skillCounts.values.reduce(0, +) }
    let mcpCalls = buckets.reduce(0) { $0 + $1.mcpCounts.values.reduce(0, +) }
    let linesAdded = buckets.reduce(Int64(0)) { saturatedAdd($0, $1.linesAdded) }
    let linesDeleted = buckets.reduce(Int64(0)) { saturatedAdd($0, $1.linesDeleted) }
    try require(
        skillCalls == Expected.skillCalls,
        "rescan must derive \(Expected.skillCalls) skill calls, got \(skillCalls)"
    )
    try require(
        mcpCalls == Expected.mcpCalls,
        "rescan must derive \(Expected.mcpCalls) MCP calls, got \(mcpCalls)"
    )
    try require(
        linesAdded == Expected.linesAdded && linesDeleted == Expected.linesDeleted,
        "rescan must derive \(Expected.linesAdded)/\(Expected.linesDeleted) edit lines, "
            + "got \(linesAdded)/\(linesDeleted)"
    )

    try checkpointWriteAheadLog(databaseURL)
    try verifyStructuralInvariants(databaseURL, expectedHostname: Expected.host)
    try verifyOwnerOnlyFiles(databaseURL)

    print("files=\(totals.files) bytes=\(totals.bytes) events=\(eventCount)")
    print("buckets=\(buckets.count) sessions=\(sessions.count)")
    print("skills=\(skillCalls) mcp=\(mcpCalls) linesAdded=\(linesAdded) linesDeleted=\(linesDeleted)")
}

// MARK: - Structural invariants

/// Invariants that must hold on any database produced by a clean rebuild.
/// These are cheap SQL checks; none of them needs production-scale data.
private func verifyStructuralInvariants(_ url: URL, expectedHostname: String) throws {
    try withDatabase(url, readOnly: true) { db in
        try require(try scalarText(db, "PRAGMA quick_check;") == "ok", "quick_check failed")
        try require(try scalarText(db, "PRAGMA integrity_check;") == "ok", "integrity_check failed")
        try require(
            try scalarInt(db, "SELECT COUNT(*) FROM pragma_foreign_key_check;") == 0,
            "foreign_key_check failed"
        )

        // A rebuild that stopped short would leave checkpoints on the old parser.
        try require(
            try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_files WHERE parser_version != \(UsageJSONLParser.parserVersion);"
            ) == 0,
            "every checkpoint must be parser v\(UsageJSONLParser.parserVersion) after a full rescan"
        )
        // 'missing' is legitimate during steady-state collection but never right
        // after a rescan that just read every file from disk.
        try require(
            try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_files WHERE scan_status NOT IN ('complete','degraded');"
            ) == 0,
            "a full rescan must leave every checkpoint complete or degraded"
        )

        // Single-host rebuild: no derived row may be attributed elsewhere.
        try require(
            try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_buckets WHERE hostname != \(quoted(expectedHostname));"
            ) == 0,
            "derived bucket hostname mismatch"
        )
        try require(
            try scalarInt(
                db,
                "SELECT COUNT(*) FROM usage_sessions WHERE hostname != \(quoted(expectedHostname));"
            ) == 0,
            "derived session hostname mismatch"
        )

        // A negative timestamp means a parse fell back to distantPast and got
        // persisted; it corrupts bucketing and every window query downstream.
        let negativeTimestamps = """
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
        try require(
            try scalarInt(db, negativeTimestamps) == 0,
            "negative timestamps remain after rebuild"
        )
    }
}

/// A WAL that cannot be truncated means a connection outlived the rebuild.
private func checkpointWriteAheadLog(_ url: URL) throws {
    try withDatabase(url, readOnly: false) { db in
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA wal_checkpoint(TRUNCATE);", -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError(db)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
        try require(sqlite3_column_int(statement, 0) == 0, "unable to checkpoint the rebuilt database")
    }
}

/// UsageLedgerStore tightens db/-wal/-shm to 0600 on open; the ledger holds
/// per-project activity, so a group- or world-readable sidecar leaks it.
private func verifyOwnerOnlyFiles(_ databaseURL: URL) throws {
    for suffix in ["", "-wal", "-shm"] {
        let path = databaseURL.path + suffix
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw VerificationError.failed("unable to read database permissions")
        }
        try require(
            permissions.intValue & 0o077 == 0,
            "database file is accessible by group or other users: \(path)"
        )
    }
}

// MARK: - Fixture

private struct Transcript {
    let url: URL
    let source: String
}

private struct ScanTotals {
    var files = 0
    var bytes: Int64 = 0
    var diagnostics = 0
}

/// Reads the fixture transcripts exactly the way the collector does, so the
/// rebuild exercises the real parse-and-record path rather than a shortcut that
/// hands pre-built model objects to the store.
private func scan(
    _ transcripts: [Transcript],
    hostname: String,
    ledger: UsageLedgerStore,
    totals: inout ScanTotals
) throws {
    for transcript in transcripts.sorted(by: { $0.url.path < $1.url.path }) {
        let values = try transcript.url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let data = try Data(contentsOf: transcript.url)
        let parsed = UsageJSONLParser.parse(
            data: data,
            source: transcript.source,
            fileIdentity: transcript.url.path,
            modifiedAt: values.contentModificationDate ?? Date(),
            isSubagent: false
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
    }
}

/// Isolated transcript tree plus database directory, both under a unique
/// temporary root. Nothing here reads or writes user data.
private struct Fixture {
    let root: URL
    private let fileManager = FileManager.default

    init(label: String) throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "agent-pulse-ledger-rebuild-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanUp() {
        try? fileManager.removeItem(at: root)
    }

    /// Two codex transcripts and two claude transcripts. The claude side carries
    /// the Skill/MCP tool_use blocks and the edits, so skill, MCP and edit-line
    /// aggregation all have real data to derive from.
    func writeTranscriptTree() throws -> [Transcript] {
        let codexDirectory = root.appendingPathComponent("codex-sessions", isDirectory: true)
        let claudeDirectory = root.appendingPathComponent("claude-projects", isDirectory: true)
        try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        var transcripts: [Transcript] = []
        transcripts.append(Transcript(
            url: try write(codexDirectory, "rollout-alpha.jsonl", CodexFixture.alpha),
            source: UsageJSONLParser.codexSource
        ))
        transcripts.append(Transcript(
            url: try write(codexDirectory, "rollout-beta.jsonl", CodexFixture.beta),
            source: UsageJSONLParser.codexSource
        ))
        transcripts.append(Transcript(
            url: try write(claudeDirectory, "session-gamma.jsonl", ClaudeFixture.gamma),
            source: "claude-code"
        ))
        transcripts.append(Transcript(
            url: try write(claudeDirectory, "session-delta.jsonl", ClaudeFixture.delta),
            source: "claude-code"
        ))
        return transcripts
    }

    private func write(_ directory: URL, _ name: String, _ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let body = lines.joined(separator: "\n") + "\n"
        guard let data = body.data(using: .utf8) else {
            throw VerificationError.failed("fixture \(name) is not valid UTF-8")
        }
        try data.write(to: url, options: .atomic)
        return url
    }
}

// MARK: - Transcript content

/// Fixed timestamps keep bucketing deterministic; all of them land in the same
/// UTC day but different 30-minute buckets.
private enum FixtureClock {
    static let t0 = "2026-08-14T01:10:00Z"
    static let t1 = "2026-08-14T01:20:00Z"
    static let t2 = "2026-08-14T02:10:00Z"
    static let t3 = "2026-08-14T02:20:00Z"
}

/// Codex rollout transcripts. Each token_count carries a complete
/// last_token_usage so the parser never takes the cumulative-fallback path,
/// which would emit a diagnostic and break the zero-diagnostic assertion.
private enum CodexFixture {
    static let alpha: [String] = [
        sessionMeta(id: "11111111-1111-4111-8111-111111111111", cwd: "/tmp/fixture/project-alpha"),
        tokenCount(timestamp: FixtureClock.t0, input: 120, output: 45, cumulative: 165),
        tokenCount(timestamp: FixtureClock.t1, input: 200, output: 60, cumulative: 425)
    ]

    static let beta: [String] = [
        sessionMeta(id: "22222222-2222-4222-8222-222222222222", cwd: "/tmp/fixture/project-beta"),
        tokenCount(timestamp: FixtureClock.t2, input: 90, output: 30, cumulative: 120),
        tokenCount(timestamp: FixtureClock.t3, input: 150, output: 40, cumulative: 310)
    ]

    private static func sessionMeta(id: String, cwd: String) -> String {
        let payload = "{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\",\"originator\":\"fixture\"}"
        return "{\"timestamp\":\"\(FixtureClock.t0)\",\"type\":\"session_meta\",\"payload\":\(payload)}"
    }

    /// `cumulative` is the running total after this turn.
    private static func tokenCount(timestamp: String, input: Int, output: Int, cumulative: Int) -> String {
        let last = usage(input: input, output: output, total: input + output)
        let total = usage(input: cumulative, output: cumulative, total: cumulative * 2)
        let info = "{\"model\":\"gpt-5-codex\",\"model_context_window\":200000,"
            + "\"last_token_usage\":\(last),\"total_token_usage\":\(total)}"
        let payload = "{\"type\":\"token_count\",\"info\":\(info)}"
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":\(payload)}"
    }

    private static func usage(input: Int, output: Int, total: Int) -> String {
        "{\"input_tokens\":\(input),\"cached_input_tokens\":0,\"output_tokens\":\(output),"
            + "\"reasoning_output_tokens\":0,\"total_tokens\":\(total)}"
    }
}

/// Claude transcripts. These carry the Skill and MCP tool_use blocks plus the
/// Edit blocks, so skill counts, MCP counts and edit lines all derive from real
/// parsed content rather than hand-built model objects.
private enum ClaudeFixture {
    private static let gammaSession = "33333333-3333-4333-8333-333333333333"
    private static let deltaSession = "44444444-4444-4444-8444-444444444444"

    /// 2 skill calls, 1 MCP call, edits adding 7 and deleting 3.
    static let gamma: [String] = [
        assistant(
            id: "msg-gamma-1", timestamp: FixtureClock.t0, cwd: "/tmp/fixture/project-gamma",
            session: gammaSession, input: 300, output: 80,
            blocks: [
                skillBlock("go", id: "tu-gamma-skill-1"),
                mcpBlock("github", tool: "search", id: "tu-gamma-mcp-1")
            ]
        ),
        assistant(
            id: "msg-gamma-2", timestamp: FixtureClock.t1, cwd: "/tmp/fixture/project-gamma",
            session: gammaSession, input: 220, output: 55,
            blocks: [
                skillBlock("ship", id: "tu-gamma-skill-2"),
                editBlock(
                    id: "tu-gamma-edit-1", path: "/tmp/fixture/project-gamma/main.swift",
                    oldLines: 3, newLines: 7
                )
            ]
        ),
        editResult(
            id: "tu-gamma-edit-1", timestamp: FixtureClock.t1,
            session: gammaSession, cwd: "/tmp/fixture/project-gamma"
        )
    ]

    /// 1 skill call, 1 MCP call, edits adding 5 and deleting 1.
    static let delta: [String] = [
        assistant(
            id: "msg-delta-1", timestamp: FixtureClock.t2, cwd: "/tmp/fixture/project-delta",
            session: deltaSession, input: 180, output: 40,
            blocks: [mcpBlock("postgres", tool: "query", id: "tu-delta-mcp-1")]
        ),
        assistant(
            id: "msg-delta-2", timestamp: FixtureClock.t3, cwd: "/tmp/fixture/project-delta",
            session: deltaSession, input: 140, output: 35,
            blocks: [
                skillBlock("verify", id: "tu-delta-skill-1"),
                editBlock(
                    id: "tu-delta-edit-1", path: "/tmp/fixture/project-delta/app.swift",
                    oldLines: 1, newLines: 5
                )
            ]
        ),
        editResult(
            id: "tu-delta-edit-1", timestamp: FixtureClock.t3,
            session: deltaSession, cwd: "/tmp/fixture/project-delta"
        )
    ]

    private static func assistant(
        id: String, timestamp: String, cwd: String, session: String,
        input: Int, output: Int, blocks: [String]
    ) -> String {
        let usage = "{\"input_tokens\":\(input),\"output_tokens\":\(output),"
            + "\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}"
        let message = "{\"id\":\"\(id)\",\"model\":\"claude-sonnet-4-5\","
            + "\"content\":[\(blocks.joined(separator: ","))],\"usage\":\(usage)}"
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"assistant\",\"uuid\":\"\(id)-uuid\","
            + "\"sessionId\":\"\(session)\",\"cwd\":\"\(cwd)\",\"message\":\(message)}"
    }


    /// Edits only count once a non-error tool_result confirms they applied;
    /// proposed or failed edits must never inflate the metric. The fixture
    /// therefore has to close each edit with its result record.
    private static func editResult(id: String, timestamp: String, session: String, cwd: String) -> String {
        let block = "{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\",\"is_error\":false}"
        let message = "{\"role\":\"user\",\"content\":[\(block)]}"
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"user\",\"uuid\":\"\(id)-result\","
            + "\"sessionId\":\"\(session)\",\"cwd\":\"\(cwd)\",\"message\":\(message)}"
    }

    private static func skillBlock(_ name: String, id: String) -> String {
        "{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"Skill\",\"input\":{\"skill\":\"\(name)\"}}"
    }

    private static func mcpBlock(_ server: String, tool: String, id: String) -> String {
        "{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"mcp__\(server)__\(tool)\",\"input\":{}}"
    }

    /// Edit block whose old_string and new_string differ by whole lines, so the
    /// line diff produces a predictable added/deleted delta.
    private static func editBlock(id: String, path: String, oldLines: Int, newLines: Int) -> String {
        let oldText = (0..<oldLines).map { "old line \($0)" }.joined(separator: "\\n")
        let newText = (0..<newLines).map { "new line \($0)" }.joined(separator: "\\n")
        let input = "{\"file_path\":\"\(path)\",\"old_string\":\"\(oldText)\","
            + "\"new_string\":\"\(newText)\"}"
        return "{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"Edit\",\"input\":\(input)}"
    }
}

// MARK: - Support

enum VerificationError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case let .failed(message) = self { return message }
        return "verification failed"
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationError.failed(message) }
}

private func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
    let (sum, overflow) = lhs.addingReportingOverflow(rhs)
    return overflow ? Int64.max : sum
}

private struct DatabaseSnapshot {
    let schemaVersion: Int64
    let events: Int64
    let buckets: Int64
    let sessions: Int64
    let files: Int64
    let syncState: [String: String]
}

private func readSnapshot(_ url: URL) throws -> DatabaseSnapshot {
    try withDatabase(url, readOnly: true) { db in
        let version = try scalarInt(db, "PRAGMA user_version;")
        let events = try tableExists(db, "usage_events")
            ? scalarInt(db, "SELECT COUNT(*) FROM usage_events;") : 0
        let buckets = try tableExists(db, "usage_buckets")
            ? scalarInt(db, "SELECT COUNT(*) FROM usage_buckets;") : 0
        let sessions = try tableExists(db, "usage_sessions")
            ? scalarInt(db, "SELECT COUNT(*) FROM usage_sessions;") : 0
        let files = try tableExists(db, "usage_files")
            ? scalarInt(db, "SELECT COUNT(*) FROM usage_files;") : 0
        let syncState = try tableExists(db, "sync_state") ? readSyncState(db) : [:]
        return DatabaseSnapshot(
            schemaVersion: version, events: events, buckets: buckets,
            sessions: sessions, files: files, syncState: syncState
        )
    }
}

private func withDatabase<T>(_ url: URL, readOnly: Bool, _ body: (OpaquePointer?) throws -> T) throws -> T {
    var database: OpaquePointer?
    let flags = readOnly
        ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
        sqlite3_close_v2(database)
        throw VerificationError.failed("unable to open fixture database")
    }
    defer { sqlite3_close_v2(database) }
    return try body(database)
}

private func tableExists(_ db: OpaquePointer?, _ table: String) throws -> Bool {
    try scalarInt(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type=\"table\" AND name=\(quoted(table));"
    ) == 1
}

private func readSyncState(_ db: OpaquePointer?) throws -> [String: String] {
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
    try require(
        sqlite3_errcode(db) == SQLITE_OK || sqlite3_errcode(db) == SQLITE_DONE,
        "unable to read sync state"
    )
    return result
}

private func execute(_ db: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw sqliteError(db) }
}

private func scalarInt(_ db: OpaquePointer?, _ sql: String) throws -> Int64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw sqliteError(db) }
    return sqlite3_column_int64(statement, 0)
}

private func scalarText(_ db: OpaquePointer?, _ sql: String) throws -> String {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw sqliteError(db) }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
        throw sqliteError(db)
    }
    return String(cString: text)
}

private func quoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
}

private func sqliteError(_ db: OpaquePointer?) -> VerificationError {
    .failed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable")
}
