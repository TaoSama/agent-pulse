import Foundation
import SQLite3
import Darwin

private let usageSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum UsageLedgerError: Error, CustomStringConvertible {
    case sqlite(String)
    case invalidCheckpoint
    case localDerivationPending

    public var description: String {
        switch self {
        case let .sqlite(message): message
        case .invalidCheckpoint: "invalid checkpoint"
        case .localDerivationPending: "local usage derivation is pending"
        }
    }
}

/// 待上传的单个 bucket 快照：自然键 + 内容 + 该行当前 revision 快照。
/// ack 时按 (自然键, revision 快照) 精确匹配，避免误 ack 上传期间变化的行。
public struct UsagePendingBucket: Sendable, Equatable {
    public let bucket: UsageBucket
    public let revision: Int64
    public init(bucket: UsageBucket, revision: Int64) { self.bucket = bucket; self.revision = revision }
}

/// 待上传的单个 session 快照：自然键 + 内容 + 该行当前 revision 快照。
public struct UsagePendingSession: Sendable, Equatable {
    public let session: UsageSession
    public let revision: Int64
    public init(session: UsageSession, revision: Int64) { self.session = session; self.revision = revision }
}

/// 待上传批次。
///
/// buckets / sessions 各自带 revision 快照；hasMore 指示是否还有未纳入本批的 dirty 行。
/// 逐 batch 上传成功后调用 acknowledge(batch:)，仅把「自然键 + revision 快照」仍匹配的行
/// 标记为已同步；上传期间被重算（revision 提升）的行不匹配，保持 dirty。
public struct UsagePendingBatch: Sendable, Equatable {
    public let hostname: String
    public let buckets: [UsagePendingBucket]
    public let sessions: [UsagePendingSession]
    public let hasMore: Bool

    public init(hostname: String, buckets: [UsagePendingBucket], sessions: [UsagePendingSession], hasMore: Bool) {
        self.hostname = hostname
        self.buckets = buckets
        self.sessions = sessions
        self.hasMore = hasMore
    }

    public var isEmpty: Bool { buckets.isEmpty && sessions.isEmpty }
}

/// canonical hostname 门禁状态。
public enum UsageHostnameState: Sendable, Equatable {
    case unset
    case match
    case mismatch(stored: String)
}

/// finalizeDerived 结果，含上报资格门禁。
public struct UsageFinalizeResult: Sendable, Equatable {
    /// 是否可安全上报。false 时存在无法证明的潜在重复（例如继承回放但无完整 total 快照）。
    public let reportingEligible: Bool
    /// 门禁被 blocked 的原因（reportingEligible == false 时给出）。
    public let blockedReasons: [String]
    /// 本次因血缘证明被折叠（去重）的事件数。
    public let collapsedInheritedEvents: Int
    /// 本次因内容型去重键（codexDedupKey）被折叠的事件数（fork/subagent 回放重复）。
    public let collapsedContentDuplicates: Int

    public init(reportingEligible: Bool, blockedReasons: [String], collapsedInheritedEvents: Int, collapsedContentDuplicates: Int = 0) {
        self.reportingEligible = reportingEligible
        self.blockedReasons = blockedReasons
        self.collapsedInheritedEvents = collapsedInheritedEvents
        self.collapsedContentDuplicates = collapsedContentDuplicates
    }
}

public enum UsageIncrementalBaselineRecovery: Sendable, Equatable {
    case notNeeded
    case recovered
    case deferred
}


/// 持久化 append-only 用量账本。
///
/// 设计要点：
/// - record 只写原始层（usage_events 原始 token 事件、usage_session_events 原始会话事件、
///   usage_files checkpoint）。Codex token 事件按稳定 event_id 幂等；Claude 同 msg.id 的
///   累计增长按 UPSERT 取最大（不能 INSERT OR IGNORE 丢更新）。删除源文件永不删除历史。
/// - 一次扫描结束后调用 finalizeDerived(hostname:) 做「全局」去重 + 聚合，避免每文件重建：
///   Codex fork/subagent 继承回放按血缘证明（完整 total 快照指纹）折叠；无法证明重复的
///   继承行保留但把上报资格置为 blocked，绝不上传可能重复数据。
/// - 派生表 usage_buckets / usage_sessions 逐行携带 revision 与 synced_revision：
///   revision > synced_revision 即 dirty。pending 返回自然键 + revision 快照，ack 按
///   (自然键, revision 快照) 精确 UPDATE，上传期间被重算的行不匹配、保持 dirty。
/// - canonical hostname 变化时，从原始事件事务重建目标 hostname 派生聚合并清除旧 hostname。
/// - 显式 rebuild 时事务性清空派生 + 原始 + checkpoint（仅显式 rebuild）。
public final class UsageLedgerStore: @unchecked Sendable {
    public static let schemaVersion: Int32 = 10
    public static let bucketMilliseconds: Int64 = 30 * 60 * 1_000
    public static let defaultMaxBucketsPerBatch = 500
    public static let defaultMaxSessionsPerBatch = 1_000
    public static let defaultMaxEventsForBaselineRecovery: Int64 = 200_000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.agentpulse.usage-ledger")
    /// 数据库主文件路径；用于对 db 及其 WAL/SHM 边车文件收紧 POSIX 权限（0600）。
    private let path: String
    /// 用量库仅当前用户可读写：库中含项目路径、hostname 等可识别信息，禁止同机其它用户读取。
    private static let filePermissions: Int16 = 0o600

    public init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw UsageLedgerError.sqlite("unable to open usage database")
        }
        db = handle
        do {
            try exec("PRAGMA journal_mode=WAL;")
            try exec("PRAGMA busy_timeout=5000;")
            try exec("PRAGMA foreign_keys=ON;")
            // 批量写入 / 全表重读调优：WAL 下 synchronous=NORMAL 崩溃至多丢最后一个未 checkpoint
            // 事务（本账本可重扫恢复，可接受）；32MiB 页缓存吃下全库 raw 重读；派生重算的
            // 临时表/排序走磁盘：大库（4.4M+ 事件）下 MEMORY 会把 temp_deduped_events 全放内存触发 jetsam。
            try exec("PRAGMA synchronous=NORMAL;")
            try exec("PRAGMA cache_size=-32768;")
            try exec("PRAGMA temp_store=FILE;")
            try migrate()
            // WAL 模式与迁移都会创建/触碰 db、-wal、-shm；统一在此收紧到 0600，
            // 不放宽已更严格的权限（best-effort：文件不存在则跳过）。
            tightenFilePermissions()
        } catch { sqlite3_close_v2(handle); db = nil; throw error }
    }

    /// 将 db 及其 WAL/SHM 边车文件权限收紧到 0600（best-effort，不抛出）。
    /// 仅当当前权限比目标更宽时才 chmod，避免放宽用户已手动收紧的权限。
    private func tightenFilePermissions() {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = path + suffix
            guard manager.fileExists(atPath: target) else { continue }
            let attributes = try? manager.attributesOfItem(atPath: target)
            let current = (attributes?[.posixPermissions] as? NSNumber)?.intValue
            // 只关心 group/other 位：任何 group/other 位被置位（如 0644、0404、0755）都必须收紧。
            // 数值大小比较不安全（0404 < 0600 却仍含 other-read）。当且仅当 group/other 全为 0
            // （如用户手动设为 0600 / 0400）时保持不动，避免放宽用户已收紧的权限。
            if let current, current & 0o077 == 0 { continue }
            try? manager.setAttributes([.posixPermissions: NSNumber(value: Self.filePermissions)], ofItemAtPath: target)
        }
    }

    deinit { if let db { sqlite3_close_v2(db) } }


    // MARK: - Ingest (raw only)

    public func record(events: [UsageEvent], checkpoint: UsageFileCheckpoint, hostname: String) throws {
        try record(events: events, sessionEvents: [], checkpoint: checkpoint, hostname: hostname)
    }

    /// 只写原始层：token 事件 + 会话活动事件 + checkpoint（单事务）。不触碰派生表。
    /// Codex token 事件按 event_id 幂等；Claude 同 msg.id 的累计增长按 UPSERT 取最大。
    /// 会话事件按 (source,event_id) 幂等。扫描结束后须调用 finalizeDerived(hostname:)。
    public func record(events: [UsageEvent], sessionEvents: [UsageSessionEvent], checkpoint: UsageFileCheckpoint, hostname: String) throws {
        try record(
            events: events,
            sessionEvents: sessionEvents,
            editEntries: [],
            editMetricsSupported: false,
            checkpoint: checkpoint,
            hostname: hostname
        )
    }

    /// 只写原始层：token、session、已应用编辑和 checkpoint 同事务持久化。
    /// 调用此入口也会把 checkpoint.source 标记为支持 codeMetricVersion=2 的可测来源，
    /// 因而该来源即使本批没有 edit entry，其 token bucket 仍明确上报 0 行编辑。
    public func record(
        events: [UsageEvent],
        sessionEvents: [UsageSessionEvent],
        editEntries: [UsageEditEntry],
        editMetricsSupported: Bool = false,
        checkpoint: UsageFileCheckpoint,
        hostname: String
    ) throws {
       guard checkpoint.offset <= checkpoint.size else { throw UsageLedgerError.invalidCheckpoint }
       try queue.sync {
           try transaction {
                // 文件级原子 replace：以 checkpoint.fileID 作为唯一权威归属键。
                // 绝不信任外部空值——传入行 sourceFileHash 为空（legacy 默认）时归属到 checkpoint.fileID；
                // 非空则必须与 checkpoint.fileID 相符，否则拒绝（防止把 A 文件的行混入 B 文件的替换事务）。
                let fileID = checkpoint.fileID
                try validateAttribution(events: events, sessionEvents: sessionEvents, editEntries: editEntries, fileID: fileID)
                // 冻结水位护栏：早于 frozen 的迟到原始事件（rsync 老文件 / local-sources 新目录 /
                // degraded 重解析补出）一律丢弃、不入库，绝不回退 frozen、绝不触发重算——冻结区原始行
                // 可能已被 compact 物理删除，重算无源可算只会把正确的历史派生覆盖成残值。代价是这条
                // 晚到事件不计入总数（已接受的"稍不准"）。丢弃计数累计到 sync_state 供观测/验证。
                let frozen = try frozenBeforeMsUnlocked(hostname)
                let keptEvents: [UsageEvent]
                let keptSessionEvents: [UsageSessionEvent]
                if frozen > 0 {
                    keptEvents = events.filter { millis($0.timestamp) >= frozen }
                    keptSessionEvents = sessionEvents.filter { millis($0.timestamp) >= frozen }
                    let dropped = (events.count - keptEvents.count) + (sessionEvents.count - keptSessionEvents.count)
                    if dropped > 0 {
                        let key = frozenDroppedEventsKey(hostname)
                        let prior = try readIntUnlocked(key: key) ?? 0
                        try setIntUnlocked(key: key, value: prior + Int64(dropped))
                    }
                } else {
                    keptEvents = events
                    keptSessionEvents = sessionEvents
                }
                // 先删除该 fileID 的旧归属原始行，再插入本批新行：同事务实现「对该文件的原子替换」。
                // 增量 finalize 的前提：旧行马上要被删掉，其 logical/lineage/content 键必须先记下来。
                // 否则一旦某个被删的行原本是某个去重组的胜者，我们就再也无法知道该组还有谁需要重算。
                try recordDirtyKeysForFileUnlocked(fileID: fileID, hostname: hostname)
                try deleteRawForFileUnlocked(fileID: fileID)
                try insertRawEvents(keptEvents, fileID: fileID, hostname: hostname)
                try insertRawSessionEvents(keptSessionEvents, fileID: fileID, hostname: hostname)
                try insertRawEditEntries(editEntries, fileID: fileID, hostname: hostname)
                // 新行落库后再记一次：本批带来的键（可能是全新的 lineage/content 组）同样要重算。
                try recordDirtyKeysForFileUnlocked(fileID: fileID, hostname: hostname)
                if editMetricsSupported && checkpoint.status == "complete" {
                    try markEditMetricSourceUnlocked(checkpoint.source, hostname: hostname)
                }
                try writeCheckpoint(checkpoint)
                // 每次 raw replace 都令派生 dirty：直到一次成功 finalizeDerived 才清除。
                try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
                if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                    try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                }
            }
        }
    }

    /// 只写原始 token 事件（网络主动拉取的来源，如 cliproxy），并写一条合成 checkpoint。
    ///
    /// 网络来源不是「文件」：同一 source 的事件统一归属到一个合成 fileID，
    /// 不走 record() 的文件级 replace 路径，只做基于 (source_file_hash, event_id) 的幂等 upsert。
    /// 仍写一条合成 checkpoint，原因有二：
    /// 1) requiresParserRebuild 把「有数据却无任何 checkpoint」判为需重建；纯网络来源账本
    ///    若不写 checkpoint 会每轮被 resetForRebuild 清空。
    /// 2) checkpoint 的 parser_version 取一个足够大的稳定值，保证不小于任何本地 JSONL 解析器
    ///    版本，从而永不触发 parser 升级重建。
    /// 网络事件为 append-only，因此在同一事务内只精确重算受影响的
    /// 30 分钟 bucket，不置位全库 raw_derivation_pending。本地文件扫描若已
    /// 置位 pending，该标志保持不变，仍由常规 finalize 收口。
    public func recordNetworkEvents(_ events: [UsageEvent], source: String, hostname: String) throws {
        guard !events.isEmpty else { return }
        guard events.allSatisfy({ $0.source == source }) else { throw UsageLedgerError.invalidCheckpoint }
        let fileID = "network\u{1}\(source)"
        let checkpoint = UsageFileCheckpoint(
            fileID: fileID,
            source: source,
            pathHash: fileID,
            offset: 0,
            size: 0,
            modifiedAt: Date(timeIntervalSince1970: 0),
            parserVersion: Int(Self.networkParserVersion),
            status: "complete"
        )
        try queue.sync {
            try transaction {
                let frozen = try frozenBeforeMsUnlocked(hostname)
                let keptEvents = frozen > 0 ? events.filter { millis($0.timestamp) >= frozen } : events
                try insertRawEvents(keptEvents, fileID: fileID, hostname: hostname)
                try writeCheckpoint(checkpoint)
                try recomputeNetworkBucketsUnlocked(events: keptEvents, source: source, hostname: hostname)
                if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                    try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                }
            }
        }
    }

    /// Network events have no lineage/content replay semantics and all share one authoritative
    /// synthetic file attribution. Re-aggregate only their affected natural keys; comparing the
    /// complete bucket value keeps retries idempotent and preserves the revision/ACK contract.
    private func recomputeNetworkBucketsUnlocked(events: [UsageEvent], source: String, hostname: String) throws {
        struct BucketMeta {
            let source: String
            let model: String
            let project: String
            let start: Int64
        }

        var affected: [String: BucketMeta] = [:]
        for event in events where event.source == source {
            let start = (millis(event.timestamp) / Self.bucketMilliseconds) * Self.bucketMilliseconds
            let key = "\(event.source)\u{1}\(event.model)\u{1}\(event.project)\u{1}\(start)"
            affected[key] = BucketMeta(source: event.source, model: event.model, project: event.project, start: start)
        }
        guard !affected.isEmpty else { return }

        let existing = try readBucketRowsUnlocked(hostname: hostname)
        var changed: [UsageBucket] = []
        for (key, meta) in affected {
            let statement = try prepare("""
                SELECT input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,
                       reasoning_output_tokens,total_tokens,skill_counts_json,mcp_counts_json
                FROM usage_events
                WHERE hostname=? AND source=? AND model=? AND project=?
                  AND timestamp_ms>=? AND timestamp_ms<?;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            try bind(statement, 2, meta.source)
            try bind(statement, 3, meta.model)
            try bind(statement, 4, meta.project)
            try bind(statement, 5, meta.start)
            try bind(statement, 6, meta.start + Self.bucketMilliseconds)

            var counts = UsageTokenCounts()
            var skillCounts: [String: Int] = [:]
            var mcpCounts: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let row = UsageTokenCounts(
                    input: sqlite3_column_int64(statement, 0),
                    output: sqlite3_column_int64(statement, 1),
                    cachedInput: sqlite3_column_int64(statement, 2),
                    cacheCreationInput: sqlite3_column_int64(statement, 3),
                    reasoningOutput: sqlite3_column_int64(statement, 4),
                    reportedTotal: sqlite3_column_int64(statement, 5)
                )
                counts = UsageTokenCounts(
                    input: saturatedAdd(counts.input, row.input),
                    output: saturatedAdd(counts.output, row.output),
                    cachedInput: saturatedAdd(counts.cachedInput, row.cachedInput),
                    cacheCreationInput: saturatedAdd(counts.cacheCreationInput, row.cacheCreationInput),
                    reasoningOutput: saturatedAdd(counts.reasoningOutput, row.reasoningOutput),
                    reportedTotal: saturatedAdd(counts.reportedTotal, row.total)
                )
                skillCounts = UsageToolMetrics.mergeCounts(skillCounts, decodeStringIntMap(text(statement, 6)))
                mcpCounts = UsageToolMetrics.mergeCounts(mcpCounts, decodeStringIntMap(text(statement, 7)))
            }

            let bucket = UsageBucket(
                hostname: hostname,
                source: meta.source,
                model: meta.model,
                project: meta.project,
                bucketStart: date(meta.start),
                counts: counts,
                skillCounts: skillCounts,
                mcpCounts: mcpCounts
            )
            if existing[key]?.bucket != bucket { changed.append(bucket) }
        }

        guard !changed.isEmpty else { return }
        let revision = try nextRevisionUnlocked(hostname: hostname)
        for bucket in changed { try upsertBucketUnlocked(bucket, revision: revision) }
    }

    /// 返回指定网络来源身份已入库事件的最新毫秒时间戳。先从小型派生表定位
    /// 最后一个 bucket，再通过 timestamp 索引只扫描该 bucket，避免遍历大型原始表。
    public func latestNetworkEventTimestampMS(project: String, source: String, hostname: String) throws -> Int64? {
        try queue.sync {
            let bucket = try prepare("SELECT MAX(bucket_start_ms) FROM usage_buckets WHERE hostname=? AND source=? AND project=?;")
            defer { sqlite3_finalize(bucket) }
            try bind(bucket, 1, hostname)
            try bind(bucket, 2, source)
            try bind(bucket, 3, project)
            guard sqlite3_step(bucket) == SQLITE_ROW, sqlite3_column_type(bucket, 0) != SQLITE_NULL else { return nil }
            let bucketStart = sqlite3_column_int64(bucket, 0)

            let statement = try prepare("SELECT MAX(timestamp_ms) FROM usage_events WHERE hostname=? AND timestamp_ms>=? AND source=? AND project=?;")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            try bind(statement, 2, bucketStart)
            try bind(statement, 3, source)
            try bind(statement, 4, project)
            guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return sqlite3_column_int64(statement, 0)
        }
    }

    /// 网络来源 checkpoint 的 parser 版本基线：取一个足够大的稳定值，保证不小于任何本地
    /// JSONL 解析器版本，从而永不触发 parser 升级重建。
    private static let networkParserVersion: Int32 = 1_000_000

    /// 校验本批所有行的 sourceFileHash 与 checkpoint.fileID 相符（空值视为归属该 fileID，合法）。
    /// 非空且不等 -> invalidCheckpoint：绝不把外部错误归属写入本文件的替换事务。
    private func validateAttribution(events: [UsageEvent], sessionEvents: [UsageSessionEvent], editEntries: [UsageEditEntry], fileID: String) throws {
        for event in events where !event.sourceFileHash.isEmpty && event.sourceFileHash != fileID {
            throw UsageLedgerError.invalidCheckpoint
        }
        for event in sessionEvents where !event.sourceFileHash.isEmpty && event.sourceFileHash != fileID {
            throw UsageLedgerError.invalidCheckpoint
        }
        for entry in editEntries where !entry.sourceFileHash.isEmpty && entry.sourceFileHash != fileID {
            throw UsageLedgerError.invalidCheckpoint
        }
    }

    // MARK: - 增量 finalize 脏键（record 事务内记录，finalizeDerived 消费后清空）

    /// 脏键种类。增量重算靠这三类键把「受影响的去重组」还原成「需要重算的 bucket/session」。
    enum DirtyKeyKind: String {
        /// (source, event_id)：logical ID 去重组。
        case logical
        /// lineage_fingerprint：血缘去重组。
        case lineage
        /// codex_dedup_key：内容去重组。
        case content
        /// (source, session_hash)：session 聚合单元。
        case session
        /// source：该来源刚被标记支持 edit 指标，其全部 bucket 的 codeMetricVersion 都要更新。
        case editMetricSource
        /// tool_use_id：edit 条目按此跨文件去重。胜者易主会把行数归属挪到另一个 bucket，
        /// 所以变更文件里出现过的每个 tool_use_id 当前在册的全部 bucket 都要重算。
        case editTool
        /// bucket 自然键 (source, model, project, bucketStart)。
        ///
        /// 前四类都是「去重组」的键，闭包展开时要靠原始行还原出 bucket。但当一个 bucket 的
        /// 全部贡献行都被删光时（文件被替换成更少的行），原始层已经查不到它们，闭包再也
        /// 还原不出这个 bucket —— 它既不会被重算，也不会被删除，陈旧值会永久残留。
        /// 所以删行之前必须把行当时所在的 bucket 键直接记下来。
        case bucket
    }

    /// 记录一批脏键。同键重复写入由主键吸收。
    private func insertDirtyKeysUnlocked(
        _ keys: some Sequence<String>,
        kind: DirtyKeyKind,
        hostname: String
    ) throws {
        let statement = try prepare(
            "INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms) VALUES(?,?,?,?);"
        )
        defer { sqlite3_finalize(statement) }
        let nowMs = millis(Date())
        for key in keys where !key.isEmpty {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(statement, 1, hostname)
            try bind(statement, 2, kind.rawValue)
            try bind(statement, 3, key)
            try bind(statement, 4, nowMs)
            try done(statement)
        }
    }

    /// 批量捕获一组转为 missing 的文件当前在册原始行对应的脏键。
    ///
    /// `markFilesMissing(source:presentFileIDs:)` 可能一次性让成千上万个历史 checkpoint 从
    /// active 转为 missing；逐文件调用 `recordDirtyKeysForFileUnlocked` 会对三张 raw 表重复做
    /// indexed lookup。这里先把 transitioned fileID 放进临时表，再用少数几条 set-based SQL
    /// 一次性登记相同的 logical / session / edit / bucket 键。
    ///
    /// 注意这里故意不直接登记 lineage/content 键：mark missing 只改变文件 tier，raw 行仍在，
    /// logical 键足以在闭包传播阶段重新推导出这些行所属的 lineage/content 组。把每一行的
    /// lineage/content 也提前塞进 dirty 表，会在大规模历史文件转 missing 时制造数十万冗余种子，
    /// 让增量 finalize 在闭包传播前就退化成长时间全表级索引遍历。
    private func recordMissingFileDirtyKeysUnlocked(fileIDs: [String], hostname: String) throws {
        guard !fileIDs.isEmpty else { return }
        try exec("CREATE TEMP TABLE IF NOT EXISTS temp_usage_dirty_files(file_id TEXT PRIMARY KEY) WITHOUT ROWID;")
        try exec("DELETE FROM temp_usage_dirty_files;")
        let insertFile = try prepare("INSERT OR IGNORE INTO temp_usage_dirty_files(file_id) VALUES(?);")
        defer { sqlite3_finalize(insertFile) }
        for fileID in fileIDs where !fileID.isEmpty {
            sqlite3_reset(insertFile); sqlite3_clear_bindings(insertFile)
            try bind(insertFile, 1, fileID)
            try done(insertFile)
        }

        let nowMs = millis(Date())
        let separator = "\u{1}"
        let bucketMs = Self.bucketMilliseconds

        if try tableExistsUnlocked("usage_events") {
            let logical = try prepare("""
                INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                SELECT DISTINCT ?, ?, e.source || ? || e.event_id, ?
                FROM temp_usage_dirty_files f
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_host_file
                  ON e.hostname=? AND e.source_file_hash = f.file_id;
                """)
            defer { sqlite3_finalize(logical) }
            try bind(logical, 1, hostname)
            try bind(logical, 2, DirtyKeyKind.logical.rawValue)
            try bind(logical, 3, separator)
            try bind(logical, 4, nowMs)
            try bind(logical, 5, hostname)
            try done(logical)

            let eventSessions = try prepare("""
                INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                SELECT DISTINCT ?, ?, e.source || ? || e.session_hash, ?
                FROM temp_usage_dirty_files f
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_host_file
                  ON e.hostname=? AND e.source_file_hash = f.file_id;
                """)
            defer { sqlite3_finalize(eventSessions) }
            try bind(eventSessions, 1, hostname)
            try bind(eventSessions, 2, DirtyKeyKind.session.rawValue)
            try bind(eventSessions, 3, separator)
            try bind(eventSessions, 4, nowMs)
            try bind(eventSessions, 5, hostname)
            try done(eventSessions)

            let eventBuckets = try prepare("""
                INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                SELECT DISTINCT ?, ?, e.source || ? || e.model || ? || e.project || ? || CAST((e.timestamp_ms / ?) * ? AS TEXT), ?
                FROM temp_usage_dirty_files f
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_host_file
                  ON e.hostname=? AND e.source_file_hash = f.file_id;
                """)
            defer { sqlite3_finalize(eventBuckets) }
            try bind(eventBuckets, 1, hostname)
            try bind(eventBuckets, 2, DirtyKeyKind.bucket.rawValue)
            try bind(eventBuckets, 3, separator)
            try bind(eventBuckets, 4, separator)
            try bind(eventBuckets, 5, separator)
            try bind(eventBuckets, 6, bucketMs)
            try bind(eventBuckets, 7, bucketMs)
            try bind(eventBuckets, 8, nowMs)
            try bind(eventBuckets, 9, hostname)
            try done(eventBuckets)
        }

        if try tableExistsUnlocked("usage_session_events") {
            let sessions = try prepare("""
                INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                SELECT DISTINCT ?, ?, s.source || ? || s.session_hash, ?
                FROM usage_session_events s
                JOIN temp_usage_dirty_files f ON f.file_id = s.source_file_hash
                WHERE s.hostname=?;
                """)
            defer { sqlite3_finalize(sessions) }
            try bind(sessions, 1, hostname)
            try bind(sessions, 2, DirtyKeyKind.session.rawValue)
            try bind(sessions, 3, separator)
            try bind(sessions, 4, nowMs)
            try bind(sessions, 5, hostname)
            try done(sessions)
        }

        if try tableExistsUnlocked("usage_edit_entries") {
            let editTools = try prepare("""
                INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                SELECT DISTINCT ?, ?, e.tool_use_id, ?
                FROM usage_edit_entries e
                JOIN temp_usage_dirty_files f ON f.file_id = e.source_file_hash
                WHERE e.hostname=? AND e.tool_use_id <> '';
                """)
            defer { sqlite3_finalize(editTools) }
            try bind(editTools, 1, hostname)
            try bind(editTools, 2, DirtyKeyKind.editTool.rawValue)
            try bind(editTools, 3, nowMs)
            try bind(editTools, 4, hostname)
            try done(editTools)

            let editBuckets = try prepare("""
                INSERT OR IGNORE INTO usage_dirty_keys(hostname,kind,key,created_at_ms)
                SELECT DISTINCT ?, ?, e.source || ? || e.model || ? || e.project || ? || CAST((e.timestamp_ms / ?) * ? AS TEXT), ?
                FROM usage_edit_entries e
                JOIN temp_usage_dirty_files f ON f.file_id = e.source_file_hash
                WHERE e.hostname=?;
                """)
            defer { sqlite3_finalize(editBuckets) }
            try bind(editBuckets, 1, hostname)
            try bind(editBuckets, 2, DirtyKeyKind.bucket.rawValue)
            try bind(editBuckets, 3, separator)
            try bind(editBuckets, 4, separator)
            try bind(editBuckets, 5, separator)
            try bind(editBuckets, 6, bucketMs)
            try bind(editBuckets, 7, bucketMs)
            try bind(editBuckets, 8, nowMs)
            try bind(editBuckets, 9, hostname)
            try done(editBuckets)
        }

        try exec("DELETE FROM temp_usage_dirty_files;")
    }

    /// 把某 fileID 当前在册的原始行的去重键与 session 键全部登记为脏。
    ///
    /// 必须在 deleteRawForFileUnlocked 之前调用一次（捕获即将消失的旧行），插入新行之后再调用一次
    /// （捕获本批带来的新键）。只登记「这些行参与了哪些去重组」，组内其余成员由 finalize 时的闭包
    /// 展开负责补齐——这里不做展开，因为 record 在扫描热路径上，每个文件都要跑。
    private func recordDirtyKeysForFileUnlocked(fileID: String, hostname: String) throws {
        guard try tableExistsUnlocked("usage_events") else { return }
        var logical: Set<String> = []
        var lineage: Set<String> = []
        var content: Set<String> = []
        var sessions: Set<String> = []
        var buckets: Set<String> = []
        let bucketMs = Self.bucketMilliseconds
        do {
            let statement = try prepare("""
                SELECT source, event_id, lineage_fingerprint, codex_dedup_key, session_hash,
                       model, project, timestamp_ms
                FROM usage_events WHERE hostname=? AND source_file_hash=?;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try bind(statement, 2, fileID)
            while sqlite3_step(statement) == SQLITE_ROW {
                let source = text(statement, 0)
                logical.insert(compositeKey(source, text(statement, 1)))
                lineage.insert(text(statement, 2))
                content.insert(text(statement, 3))
                sessions.insert(compositeKey(source, text(statement, 4)))
                // 行当前所在的 bucket：删行后就再也算不出来了，必须此刻记下。
                let start = (sqlite3_column_int64(statement, 7) / bucketMs) * bucketMs
                buckets.insert(compositeKey(source, text(statement, 5), text(statement, 6), String(start)))
            }
        }
        // session 活动事件独立于 token 事件：同一文件可能只贡献 session 行。
        if try tableExistsUnlocked("usage_session_events") {
            let statement = try prepare(
                "SELECT DISTINCT source, session_hash FROM usage_session_events WHERE hostname=? AND source_file_hash=?;"
            )
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try bind(statement, 2, fileID)
            while sqlite3_step(statement) == SQLITE_ROW {
                sessions.insert(compositeKey(text(statement, 0), text(statement, 1)))
            }
        }
        // edit 条目可能是该文件的唯一产物（纯 edit 文件没有任何 token 事件），此时上面两个
        // 循环一个键都收集不到，所以这里独立收集。
        //
        // 记录 edit 条目当前所在的 bucket 自然键：若这些行随文件替换被删，之后就再也查不到
        // 它们曾落在哪个 bucket，那个 bucket 既不会被重算也不会被删，陈旧值永久残留。
        // 与 token 侧的 DirtyKeyKind.bucket 同理。
        //
        // 同时记录 tool_use_id：edit 按它跨文件去重，胜者易主会把行数归属挪到另一个文件的
        // bucket，那个 bucket 无法从本文件的行还原，只能靠 tool_use_id 反查。登记 tool_use_id
        // 而不是整个 source —— 后者会把该来源的每一个 edit bucket 都拖进闭包（实测追加
        // 10 个事件就拉进 80 个 bucket，再经 session / bucket_map 两条边雪崩到两万多行）。
        var editTools: Set<String> = []
        if try tableExistsUnlocked("usage_edit_entries") {
            let statement = try prepare("""
                SELECT DISTINCT source, model, project, timestamp_ms, tool_use_id
                FROM usage_edit_entries WHERE hostname=? AND source_file_hash=?;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try bind(statement, 2, fileID)
            while sqlite3_step(statement) == SQLITE_ROW {
                let source = text(statement, 0)
                editTools.insert(text(statement, 4))
                let start = (sqlite3_column_int64(statement, 3) / bucketMs) * bucketMs
                buckets.insert(compositeKey(source, text(statement, 1), text(statement, 2), String(start)))
            }
        }
        try insertDirtyKeysUnlocked(logical, kind: .logical, hostname: hostname)
        try insertDirtyKeysUnlocked(lineage, kind: .lineage, hostname: hostname)
        try insertDirtyKeysUnlocked(content, kind: .content, hostname: hostname)
        try insertDirtyKeysUnlocked(sessions, kind: .session, hostname: hostname)
        try insertDirtyKeysUnlocked(editTools, kind: .editTool, hostname: hostname)
        try insertDirtyKeysUnlocked(buckets, kind: .bucket, hostname: hostname)
    }

    /// 复合键分隔符统一用 U+0001，与派生表的 bucket/session key 口径一致。
    private func compositeKey(_ parts: String...) -> String {
        parts.joined(separator: "\u{1}")
    }

    /// 删除某 fileID 归属的全部原始行（token/session/edit）。文件级替换的第一步。
    /// 仅删该 fileID：跨文件相同 event/tool ID 的其它文件行不受影响。
    private func deleteRawForFileUnlocked(fileID: String) throws {
        for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
            guard try tableExistsUnlocked(table) else { continue }
            let statement = try prepare("DELETE FROM \(table) WHERE source_file_hash=?;")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, fileID); try done(statement)
        }
    }

    private func insertRawEvents(_ events: [UsageEvent], fileID: String, hostname: String) throws {
        // 合并策略随事件持久化（merge_strategy），不再按来源名硬编码：
        // - cumulativeMax（Claude-compatible）：同 msg.id 流式累计增长，逐列取最大保证不丢更新，
        //   且 model=unknown 时保留既有 model（流式早行不冲掉已知 model）。
        // - overwrite（Codex rollout）：event_id 稳定且携带修正后的独立计数，重解析直接覆盖。
        // hostname 为采集机标识：文件级 replace 时按本机 hostname 写入，冲突更新也覆盖为最新采集机。
        let sql = """
            INSERT INTO usage_events
            (event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,source_file_hash,rollout_key,parent_rollout_key,inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,merge_strategy,skill_counts_json,mcp_counts_json,hostname,created_at_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(source_file_hash,event_id) DO UPDATE SET
              source=excluded.source,
              input_tokens=CASE WHEN excluded.merge_strategy='cumulativeMax' THEN MAX(input_tokens,excluded.input_tokens) ELSE excluded.input_tokens END,
              output_tokens=CASE WHEN excluded.merge_strategy='cumulativeMax' THEN MAX(output_tokens,excluded.output_tokens) ELSE excluded.output_tokens END,
              cached_input_tokens=CASE WHEN excluded.merge_strategy='cumulativeMax' THEN MAX(cached_input_tokens,excluded.cached_input_tokens) ELSE excluded.cached_input_tokens END,
              cache_creation_input_tokens=CASE WHEN excluded.merge_strategy='cumulativeMax' THEN MAX(cache_creation_input_tokens,excluded.cache_creation_input_tokens) ELSE excluded.cache_creation_input_tokens END,
              reasoning_output_tokens=CASE WHEN excluded.merge_strategy='cumulativeMax' THEN MAX(reasoning_output_tokens,excluded.reasoning_output_tokens) ELSE excluded.reasoning_output_tokens END,
              total_tokens=CASE WHEN excluded.merge_strategy='cumulativeMax' THEN MAX(total_tokens,excluded.total_tokens) ELSE excluded.total_tokens END,
              model=CASE WHEN excluded.merge_strategy='cumulativeMax' AND excluded.model='unknown' THEN model ELSE excluded.model END,
              project=excluded.project,
              timestamp_ms=excluded.timestamp_ms,
              session_hash=excluded.session_hash,
              source_file_hash=excluded.source_file_hash,
              rollout_key=excluded.rollout_key,
              parent_rollout_key=excluded.parent_rollout_key,
              inherited=excluded.inherited,
              has_total_snapshot=excluded.has_total_snapshot,
              lineage_fingerprint=excluded.lineage_fingerprint,
              codex_dedup_key=excluded.codex_dedup_key,
              merge_strategy=excluded.merge_strategy,
              skill_counts_json=excluded.skill_counts_json,
              mcp_counts_json=excluded.mcp_counts_json,
              hostname=excluded.hostname;
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        let existingCounts = try prepare("SELECT skill_counts_json,mcp_counts_json FROM usage_events WHERE source_file_hash=? AND event_id=?;")
        defer { sqlite3_finalize(existingCounts) }
        for event in events {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            let c = event.counts
            var skillCounts = UsageToolMetrics.normalizeCounts(event.skillCounts)
            var mcpCounts = UsageToolMetrics.normalizeCounts(event.mcpCounts)
            if event.mergeStrategy == .cumulativeMax {
                sqlite3_reset(existingCounts); sqlite3_clear_bindings(existingCounts)
                try bind(existingCounts, 1, fileID); try bind(existingCounts, 2, event.id)
                if sqlite3_step(existingCounts) == SQLITE_ROW {
                    skillCounts = maximumCounts(decodeStringIntMap(text(existingCounts, 0)), skillCounts)
                    mcpCounts = maximumCounts(decodeStringIntMap(text(existingCounts, 1)), mcpCounts)
                }
            }
            try bind(insert, 1, event.id); try bind(insert, 2, event.source)
            try bind(insert, 3, event.model); try bind(insert, 4, event.project)
            try bind(insert, 5, millis(event.timestamp)); try bind(insert, 6, c.input)
            try bind(insert, 7, c.output); try bind(insert, 8, c.cachedInput)
            try bind(insert, 9, c.cacheCreationInput); try bind(insert, 10, c.reasoningOutput)
            try bind(insert, 11, c.total); try bind(insert, 12, event.sessionHash)
            try bind(insert, 13, fileID); try bind(insert, 14, event.rolloutKey)
            try bind(insert, 15, event.parentRolloutKey); try bind(insert, 16, event.inherited ? 1 : 0)
            try bind(insert, 17, event.hasTotalSnapshot ? 1 : 0); try bind(insert, 18, event.lineageFingerprint)
            try bind(insert, 19, event.codexDedupKey)
            try bind(insert, 20, event.mergeStrategy.rawValue)
            try bind(insert, 21, encodeStringIntMap(skillCounts))
            try bind(insert, 22, encodeStringIntMap(mcpCounts))
            try bind(insert, 23, hostname)
            try bind(insert, 24, millis(Date()))
            try done(insert)
        }
    }

    private func insertRawSessionEvents(_ events: [UsageSessionEvent], fileID: String, hostname: String) throws {
        let sql = """
            INSERT OR IGNORE INTO usage_session_events
            (event_id,source,session_hash,role,timestamp_ms,source_file_hash,hostname,created_at_ms)
            VALUES (?,?,?,?,?,?,?,?);
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        for event in events {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, event.id); try bind(insert, 2, event.source)
            try bind(insert, 3, event.sessionHash); try bind(insert, 4, event.role.rawValue)
            try bind(insert, 5, millis(event.timestamp)); try bind(insert, 6, fileID)
            try bind(insert, 7, hostname); try bind(insert, 8, millis(Date()))
            try done(insert)
        }
    }

    private func insertRawEditEntries(_ entries: [UsageEditEntry], fileID: String, hostname: String) throws {
        let sql = """
            INSERT OR IGNORE INTO usage_edit_entries
            (tool_use_id,source,model,project,timestamp_ms,lines_added,lines_deleted,source_file_hash,hostname,created_at_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?);
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        for entry in entries where !entry.toolUseID.isEmpty {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, entry.toolUseID); try bind(insert, 2, entry.source)
            try bind(insert, 3, entry.model); try bind(insert, 4, entry.project)
            try bind(insert, 5, millis(entry.timestamp)); try bind(insert, 6, entry.added)
            try bind(insert, 7, entry.deleted); try bind(insert, 8, fileID)
            try bind(insert, 9, hostname); try bind(insert, 10, millis(Date()))
            try done(insert)
        }
    }

    private func markEditMetricSourceUnlocked(_ source: String, hostname: String) throws {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let statement = try prepare("INSERT OR IGNORE INTO usage_edit_metric_sources(source,created_at_ms) VALUES(?,?);")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, normalized); try bind(statement, 2, millis(Date()))
        try done(statement)
        // 该来源首次被标记为可测：它已有的每个 bucket 都要补写 codeMetricVersion，
        // 即使那些 bucket 本轮没有任何 edit 条目。登记为脏让增量路径覆盖到它们。
        guard sqlite3_changes(db) > 0 else { return }
        try insertDirtyKeysUnlocked([normalized], kind: .editMetricSource, hostname: hostname)
    }


    // MARK: - 增量 finalize：脏键闭包展开

    /// 不动点迭代上限。正常 2-3 轮收敛；设上限是防御异常数据把 finalize 拖成长循环。
    private static let dirtyClosureIterationLimit = 16

    /// 增量重算的作用域：需要重算的 bucket 键与 session 键。
    private struct DirtyScope {
        /// bucket 自然键 (source, model, project, bucketStart)。
        var buckets: Set<String> = []
        /// session 自然键 (source, sessionHash)。
        var sessions: Set<String> = []
    }

    /// 把脏键展开成「必须重算的 bucket / session」闭包。
    ///
    /// 三级去重是串联的：logical 组的胜者决定它参与哪个 lineage 组，lineage 组的胜者决定它参与哪个
    /// content 组。任何一级胜者易主，原胜者所在 bucket 就会失去它的贡献。所以不能只看新事件自己的
    /// bucket——必须沿 logical → lineage → content 双向传播直到不再产生新键（不动点），再收集闭包内
    /// 所有成员行的 bucket。
    ///
    /// 传播只做这三个键的等值查找，走 idx_usage_events_host_time / _lineage / _dedup 索引，
    /// 代价与受影响的组规模成正比，与账本总行数无关。
    private func expandDirtyScopeUnlocked(hostname: String) throws -> DirtyScope {
        try dropDirtyClosureTablesUnlocked()
        try exec("CREATE TEMP TABLE temp_dirty_logical(source TEXT NOT NULL, event_id TEXT NOT NULL, PRIMARY KEY(source,event_id));")
        try exec("CREATE TEMP TABLE temp_dirty_lineage(fingerprint TEXT PRIMARY KEY);")
        try exec("CREATE TEMP TABLE temp_dirty_content(dedup_key TEXT PRIMARY KEY);")
        defer { try? dropDirtyClosureTablesUnlocked() }
        try seedDirtyKeysUnlocked(hostname: hostname)
        try propagateDirtyClosureUnlocked(hostname: hostname)
        return try collectDirtyScopeUnlocked(hostname: hostname)
    }

    /// 不动点传播：三级去重键互相传播直到不再产生新键。要求 temp_dirty_* 三张表已建好并灌过种子。
    private func propagateDirtyClosureUnlocked(hostname: String) throws {
        // 四条传播语句都加 hostname 过滤，避免多机场景下把其它 hostname 的事件拉进作用域。
        let logicalToLineage = try prepare("""
            INSERT OR IGNORE INTO temp_dirty_lineage(fingerprint)
            SELECT DISTINCT e.lineage_fingerprint FROM temp_dirty_logical d
            CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_lineage
              ON e.source = d.source AND e.event_id = d.event_id
            WHERE e.hostname = ? AND e.lineage_fingerprint <> '';
            """)
        let logicalToContent = try prepare("""
            INSERT OR IGNORE INTO temp_dirty_content(dedup_key)
            SELECT DISTINCT e.codex_dedup_key FROM temp_dirty_logical d
            CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_content
              ON e.source = d.source AND e.event_id = d.event_id
            WHERE e.hostname = ? AND e.codex_dedup_key <> '';
            """)
        let lineageToLogical = try prepare("""
            INSERT OR IGNORE INTO temp_dirty_logical(source, event_id)
            SELECT DISTINCT e.source, e.event_id FROM temp_dirty_lineage d
            CROSS JOIN usage_events e ON e.lineage_fingerprint = d.fingerprint
            WHERE e.hostname = ? AND e.hostname <> '' AND e.lineage_fingerprint <> '';
            """)
        let contentToLogical = try prepare("""
            INSERT OR IGNORE INTO temp_dirty_logical(source, event_id)
            SELECT DISTINCT e.source, e.event_id FROM temp_dirty_content d
            CROSS JOIN usage_events e ON e.codex_dedup_key = d.dedup_key
            WHERE e.hostname = ? AND e.hostname <> '' AND e.codex_dedup_key <> '';
            """)
        defer {
            sqlite3_finalize(logicalToLineage)
            sqlite3_finalize(logicalToContent)
            sqlite3_finalize(lineageToLogical)
            sqlite3_finalize(contentToLogical)
        }
        for _ in 0 ..< Self.dirtyClosureIterationLimit {
            var added: Int32 = 0
            sqlite3_reset(logicalToLineage); sqlite3_clear_bindings(logicalToLineage)
            try bind(logicalToLineage, 1, hostname); try done(logicalToLineage)
            added += sqlite3_changes(db)
            sqlite3_reset(logicalToContent); sqlite3_clear_bindings(logicalToContent)
            try bind(logicalToContent, 1, hostname); try done(logicalToContent)
            added += sqlite3_changes(db)
            sqlite3_reset(lineageToLogical); sqlite3_clear_bindings(lineageToLogical)
            try bind(lineageToLogical, 1, hostname); try done(lineageToLogical)
            added += sqlite3_changes(db)
            sqlite3_reset(contentToLogical); sqlite3_clear_bindings(contentToLogical)
            try bind(contentToLogical, 1, hostname); try done(contentToLogical)
            added += sqlite3_changes(db)
            if added == 0 { break }
        }
    }

    /// 收集闭包覆盖的 bucket / session 自然键。要求传播已完成。
    private func collectDirtyScopeUnlocked(hostname: String) throws -> DirtyScope {
        var scope = DirtyScope()
        let bucketMs = Self.bucketMilliseconds
        // 闭包内每一行的 bucket 都要重算：model / project 是 bucket 自然键的一部分，
        // 同一 logical 组的不同行可能落在不同 bucket，所以逐行收集而不是只看胜者。
        do {
            let statement = try prepare("""
                SELECT DISTINCT e.source, e.model, e.project,
                       (e.timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start
                FROM temp_dirty_logical d
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_logical
                  ON e.source = d.source AND e.event_id = d.event_id
                WHERE e.hostname = ? AND e.hostname <> '';
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            while sqlite3_step(statement) == SQLITE_ROW {
                scope.buckets.insert(compositeKey(
                    text(statement, 0), text(statement, 1), text(statement, 2),
                    String(sqlite3_column_int64(statement, 3))
                ))
            }
        }
        // 闭包内成员行所属的 session：project / skills 取自 logical 去重结果，胜者易主即可能变化。
        do {
            let statement = try prepare("""
                SELECT DISTINCT e.source, e.session_hash FROM temp_dirty_logical d
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_logical
                  ON e.source = d.source AND e.event_id = d.event_id
                WHERE e.hostname = ? AND e.session_hash <> '' AND e.hostname <> '';
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            while sqlite3_step(statement) == SQLITE_ROW {
                scope.sessions.insert(compositeKey(text(statement, 0), text(statement, 1)))
            }
        }
        // 直接登记的 session 脏键：只贡献 session 活动行的文件不会出现在上面的 token 事件闭包里。
        for key in try dirtyKeysUnlocked(kind: .session, hostname: hostname) {
            scope.sessions.insert(key)
        }
        // edit 条目自带 bucket 自然键，且可能创建 token 侧不存在的 bucket。
        for key in try dirtyEditBucketsUnlocked(hostname: hostname) {
            scope.buckets.insert(key)
        }
        // 直接登记的 bucket 键：贡献行可能已被删光，闭包无从还原，只能靠 record 当时记下的键。
        for key in try dirtyKeysUnlocked(kind: .bucket, hostname: hostname) {
            scope.buckets.insert(key)
        }
        return scope
    }

    private func dropDirtyClosureTablesUnlocked() throws {
        try exec("DROP TABLE IF EXISTS temp_dirty_logical;")
        try exec("DROP TABLE IF EXISTS temp_dirty_lineage;")
        try exec("DROP TABLE IF EXISTS temp_dirty_content;")
    }

    /// 把登记的脏键灌进闭包种子表。logical 键是 source+U+0001+event_id 的复合串，在 SQL 里按分隔符切开。
    private func seedDirtyKeysUnlocked(hostname: String) throws {
        do {
            let statement = try prepare("""
                INSERT OR IGNORE INTO temp_dirty_logical(source, event_id)
                SELECT substr(key, 1, instr(key, char(1)) - 1),
                       substr(key, instr(key, char(1)) + 1)
                FROM usage_dirty_keys
                WHERE hostname = ? AND kind = 'logical' AND instr(key, char(1)) > 1;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try done(statement)
        }
        for (kind, table, column) in [
            (DirtyKeyKind.lineage, "temp_dirty_lineage", "fingerprint"),
            (DirtyKeyKind.content, "temp_dirty_content", "dedup_key"),
        ] {
            let statement = try prepare("""
                INSERT OR IGNORE INTO \(table)(\(column))
                SELECT key FROM usage_dirty_keys
                WHERE hostname = ? AND kind = ? AND key <> '';
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try bind(statement, 2, kind.rawValue)
            try done(statement)
        }
    }

    /// 读取某类脏键的全部键值。
    private func dirtyKeysUnlocked(kind: DirtyKeyKind, hostname: String) throws -> [String] {
        let statement = try prepare("SELECT key FROM usage_dirty_keys WHERE hostname=? AND kind=? AND key <> '';")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try bind(statement, 2, kind.rawValue)
        var keys: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW { keys.append(text(statement, 0)) }
        return keys
    }

    /// 受影响的 edit bucket。
    ///
    /// 两个来源，对应两种影响面：
    ///
    /// 1. 脏 tool_use_id：edit 按它跨文件去重。某个文件的条目被删或新增后，同 ID 在其它文件里的
    ///    条目可能晋升为胜者，其 bucket 的行数随之变化。所以该 ID 当前在册的每一行所在的 bucket
    ///    都要重算。行数由 idx_usage_edit_entries_dedup(tool_use_id) 索引点查界定，与表规模无关。
    ///
    /// 2. 脏 editMetricSource：某来源首次被标记支持 edit 指标时，它已有的每个 bucket 都要补写
    ///    codeMetricVersion，即使那些 bucket 本轮没有任何 edit 条目变化。这才是需要全 source
    ///    展开的唯一场景，且只在该来源首次标记那一次发生（markEditMetricSourceUnlocked 用
    ///    sqlite3_changes 守住了重复登记）。
    private func dirtyEditBucketsUnlocked(hostname: String) throws -> [String] {
        guard try tableExistsUnlocked("usage_edit_entries") else { return [] }
        let bucketMs = Self.bucketMilliseconds
        var keys: [String] = []
        let tools = try dirtyKeysUnlocked(kind: .editTool, hostname: hostname)
        if !tools.isEmpty {
            let statement = try prepare("""
                SELECT DISTINCT source, model, project,
                       (timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start
                FROM usage_edit_entries WHERE hostname = ? AND tool_use_id = ?;
                """)
            defer { sqlite3_finalize(statement) }
            for toolUseID in tools {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(statement, 1, hostname); try bind(statement, 2, toolUseID)
                while sqlite3_step(statement) == SQLITE_ROW {
                    keys.append(compositeKey(
                        text(statement, 0), text(statement, 1), text(statement, 2),
                        String(sqlite3_column_int64(statement, 3))
                    ))
                }
            }
        }
        let sources = try dirtyKeysUnlocked(kind: .editMetricSource, hostname: hostname)
        if !sources.isEmpty {
            let statement = try prepare("""
                SELECT DISTINCT source, model, project,
                       (timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start
                FROM usage_edit_entries WHERE hostname = ? AND source = ?;
                """)
            defer { sqlite3_finalize(statement) }
            for source in sources {
                sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                try bind(statement, 1, hostname); try bind(statement, 2, source)
                while sqlite3_step(statement) == SQLITE_ROW {
                    keys.append(compositeKey(
                        text(statement, 0), text(statement, 1), text(statement, 2),
                        String(sqlite3_column_int64(statement, 3))
                    ))
                }
            }
        }
        return keys
    }


    // MARK: - 派生去重 SQL（全量与增量共用同一份，避免两套实现漂移）

    /// logical 去重（tier 优先级 -> 按 (source, event_id) 分组）。
    ///
    /// scoped 版仅比全量版多一个 JOIN temp_scope_events，把参与去重的原始行限定在脏闭包
    /// 覆盖的 logical 组内。分组维度与全量逐字相同，所以增量结果等于全量结果在该作用域上的
    /// 投影——等价性来自共用同一份 SQL，而不是两套实现凑出来的巧合。
    private static func logicalEventsSQL(scoped: Bool) -> String {
        scoped ? logicalEventsScopedSQL : logicalEventsFullSQL
    }

    private static let logicalEventsFullSQL = """
            CREATE TEMP TABLE temp_logical_events AS
            WITH active_files AS (
                SELECT file_id FROM usage_files WHERE scan_status <> 'missing'
            ),
            tiered AS (
                SELECT
                    event_id, source, model, project, timestamp_ms,
                    input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                    reasoning_output_tokens, total_tokens, session_hash,
                    inherited, has_total_snapshot, lineage_fingerprint, codex_dedup_key,
                    skill_counts_json, mcp_counts_json, merge_strategy,
                    CASE
                        WHEN source_file_hash = '' THEN 0
                        WHEN source_file_hash IN (SELECT file_id FROM active_files) THEN 2
                        ELSE 1
                    END AS tier
                FROM usage_events
                WHERE hostname = ?
            ),
            max_tier AS (
                SELECT source, event_id, MAX(tier) AS max_tier
                FROM tiered GROUP BY source, event_id
            ),
            top_tier AS (
                SELECT t.* FROM tiered t
                JOIN max_tier m ON t.source = m.source AND t.event_id = m.event_id AND t.tier = m.max_tier
            ),
            logical_dedup AS (
                SELECT
                    source, event_id,
                    COALESCE(MAX(CASE WHEN model <> 'unknown' THEN model END), MAX(model)) AS model,
                    COALESCE(MAX(CASE WHEN project <> 'unknown' THEN project END), MAX(project)) AS project,
                    MIN(timestamp_ms) AS timestamp_ms,
                    MAX(input_tokens) AS input_tokens,
                    MAX(output_tokens) AS output_tokens,
                    MAX(cached_input_tokens) AS cached_input_tokens,
                    MAX(cache_creation_input_tokens) AS cache_creation_input_tokens,
                    MAX(reasoning_output_tokens) AS reasoning_output_tokens,
                    MAX(total_tokens) AS total_tokens,
                    MAX(session_hash) AS session_hash,
                    MIN(inherited) AS inherited,
                    MAX(has_total_snapshot) AS has_total_snapshot,
                    MAX(lineage_fingerprint) AS lineage_fingerprint,
                    MAX(codex_dedup_key) AS codex_dedup_key,
                    COALESCE(MAX(CASE WHEN merge_strategy = 'cumulativeMax' THEN 'cumulativeMax' END), MAX(merge_strategy)) AS merge_strategy,
                    MAX(skill_counts_json) AS skill_counts_json,
                    MAX(mcp_counts_json) AS mcp_counts_json,
                    CASE
                        WHEN MAX(CASE WHEN merge_strategy = 'cumulativeMax' THEN 1 ELSE 0 END) = 1 THEN 0
                        WHEN COUNT(DISTINCT session_hash) > 1 THEN 1
                        WHEN COUNT(DISTINCT CASE WHEN model <> 'unknown' THEN model END) > 1 THEN 1
                        WHEN COUNT(DISTINCT CASE WHEN project <> 'unknown' THEN project END) > 1 THEN 1
                        ELSE 0
                    END AS has_identity_conflict
                FROM top_tier
                GROUP BY source, event_id
            )
            SELECT * FROM logical_dedup;
        """

    private static let logicalEventsScopedSQL = """
            CREATE TEMP TABLE temp_logical_events AS
            WITH active_files AS (
                SELECT file_id FROM usage_files WHERE scan_status <> 'missing'
            ),
            tiered AS (
                SELECT
                    usage_events.event_id, usage_events.source, usage_events.model, usage_events.project, usage_events.timestamp_ms,
                    usage_events.input_tokens, usage_events.output_tokens, usage_events.cached_input_tokens, usage_events.cache_creation_input_tokens,
                    usage_events.reasoning_output_tokens, usage_events.total_tokens, usage_events.session_hash,
                    usage_events.inherited, usage_events.has_total_snapshot, usage_events.lineage_fingerprint, usage_events.codex_dedup_key,
                    usage_events.skill_counts_json, usage_events.mcp_counts_json, usage_events.merge_strategy,
                    CASE
                        WHEN usage_events.source_file_hash = '' THEN 0
                        WHEN usage_events.source_file_hash IN (SELECT file_id FROM active_files) THEN 2
                        ELSE 1
                    END AS tier
                FROM temp_scope_events s
                CROSS JOIN usage_events INDEXED BY idx_usage_events_dirty_logical
                  ON usage_events.source = s.source AND usage_events.event_id = s.event_id
                WHERE usage_events.hostname = ? AND usage_events.hostname <> ''
            ),
            max_tier AS (
                SELECT source, event_id, MAX(tier) AS max_tier
                FROM tiered GROUP BY source, event_id
            ),
            top_tier AS (
                SELECT t.* FROM tiered t
                JOIN max_tier m ON t.source = m.source AND t.event_id = m.event_id AND t.tier = m.max_tier
            ),
            logical_dedup AS (
                SELECT
                    source, event_id,
                    COALESCE(MAX(CASE WHEN model <> 'unknown' THEN model END), MAX(model)) AS model,
                    COALESCE(MAX(CASE WHEN project <> 'unknown' THEN project END), MAX(project)) AS project,
                    MIN(timestamp_ms) AS timestamp_ms,
                    MAX(input_tokens) AS input_tokens,
                    MAX(output_tokens) AS output_tokens,
                    MAX(cached_input_tokens) AS cached_input_tokens,
                    MAX(cache_creation_input_tokens) AS cache_creation_input_tokens,
                    MAX(reasoning_output_tokens) AS reasoning_output_tokens,
                    MAX(total_tokens) AS total_tokens,
                    MAX(session_hash) AS session_hash,
                    MIN(inherited) AS inherited,
                    MAX(has_total_snapshot) AS has_total_snapshot,
                    MAX(lineage_fingerprint) AS lineage_fingerprint,
                    MAX(codex_dedup_key) AS codex_dedup_key,
                    COALESCE(MAX(CASE WHEN merge_strategy = 'cumulativeMax' THEN 'cumulativeMax' END), MAX(merge_strategy)) AS merge_strategy,
                    MAX(skill_counts_json) AS skill_counts_json,
                    MAX(mcp_counts_json) AS mcp_counts_json,
                    CASE
                        WHEN MAX(CASE WHEN merge_strategy = 'cumulativeMax' THEN 1 ELSE 0 END) = 1 THEN 0
                        WHEN COUNT(DISTINCT session_hash) > 1 THEN 1
                        WHEN COUNT(DISTINCT CASE WHEN model <> 'unknown' THEN model END) > 1 THEN 1
                        WHEN COUNT(DISTINCT CASE WHEN project <> 'unknown' THEN project END) > 1 THEN 1
                        ELSE 0
                    END AS has_identity_conflict
                FROM top_tier
                GROUP BY source, event_id
            )
            SELECT * FROM logical_dedup;
        """

    /// lineage 去重：输入是 temp_logical_events，全量与增量逐字共用。
    private static let lineageEventsSQL = """
            CREATE TEMP TABLE temp_lineage_events AS
            WITH
            lineage_ranked AS (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY lineage_fingerprint ORDER BY inherited ASC, timestamp_ms ASC) AS rn
                FROM temp_logical_events
                WHERE lineage_fingerprint <> ''
            )
                SELECT source, event_id, model, project, timestamp_ms,
                       input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                       reasoning_output_tokens, total_tokens, session_hash,
                       inherited, has_total_snapshot, lineage_fingerprint, codex_dedup_key,
                       skill_counts_json, mcp_counts_json, merge_strategy
                FROM lineage_ranked WHERE rn = 1
                UNION ALL
                SELECT source, event_id, model, project, timestamp_ms,
                       input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                       reasoning_output_tokens, total_tokens, session_hash,
                       inherited, has_total_snapshot, lineage_fingerprint, codex_dedup_key,
                       skill_counts_json, mcp_counts_json, merge_strategy
                FROM temp_logical_events WHERE lineage_fingerprint = '';
        """

    /// content 去重：输入是 temp_lineage_events，全量与增量逐字共用。
    private static let dedupedEventsSQL = """
            CREATE TEMP TABLE temp_deduped_events AS
            WITH
            content_ranked AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY codex_dedup_key
                    ORDER BY (input_tokens + output_tokens + cached_input_tokens
                              + cache_creation_input_tokens + reasoning_output_tokens) DESC
                ) AS rn
                FROM temp_lineage_events
                WHERE codex_dedup_key <> ''
            ),
            content_dedup AS (
                SELECT source, event_id, model, project, timestamp_ms,
                       input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                       reasoning_output_tokens, total_tokens, session_hash,
                       inherited, has_total_snapshot, lineage_fingerprint, codex_dedup_key,
                       skill_counts_json, mcp_counts_json, merge_strategy
                FROM content_ranked WHERE rn = 1
                UNION ALL
                SELECT source, event_id, model, project, timestamp_ms,
                       input_tokens, output_tokens, cached_input_tokens, cache_creation_input_tokens,
                       reasoning_output_tokens, total_tokens, session_hash,
                       inherited, has_total_snapshot, lineage_fingerprint, codex_dedup_key,
                       skill_counts_json, mcp_counts_json, merge_strategy
                FROM temp_lineage_events WHERE codex_dedup_key = ''
            )
            SELECT * FROM content_dedup;
        """

    /// 原始行 -> 最终去重胜者的归属映射（全量与增量逐字共用）。
    ///
    /// skill/mcp 计数必须按 key 取 max，SQL 的 MAX(JSON) 做不到，所以计数合并只能在 Swift
    /// 端做。但「谁是胜者」不该在 Swift 端重算：三级去重的胜者已由 temp_logical_events /
    /// temp_lineage_events / temp_deduped_events 物化，SQL 用 ROW_NUMBER() OVER (... ORDER BY)
    /// 定序；Swift 端再跑一遍就要复刻同一套 tie-break，而 Dictionary 遍历顺序不确定，
    /// 两边必然漂移到不同的 bucket 自然键。全量路径下算错的键会被 bucket 查找静默丢弃。
    ///
    /// 这张表把归属关系交给 SQL：每个 logical 行落到它最终所属胜者的 bucket 自然键上。
    /// Swift 只按 winner 分组累计计数，不再选胜者。
    private static func skillAttributionSQL(bucketMs: Int64) -> String {
        """
            CREATE TEMP TABLE temp_skill_attribution AS
            WITH lineage_winner AS (
                SELECT l.source AS member_source, l.event_id AS member_event_id,
                       w.source AS win_source, w.event_id AS win_event_id
                FROM temp_logical_events l
                JOIN temp_lineage_events w ON w.lineage_fingerprint = l.lineage_fingerprint
                WHERE l.lineage_fingerprint <> ''
                UNION ALL
                SELECT l.source, l.event_id, l.source, l.event_id
                FROM temp_logical_events l
                WHERE l.lineage_fingerprint = ''
            ),
            content_winner AS (
                SELECT n.source AS member_source, n.event_id AS member_event_id,
                       d.source AS win_source, d.event_id AS win_event_id
                FROM temp_lineage_events n
                JOIN temp_deduped_events d ON d.codex_dedup_key = n.codex_dedup_key
                WHERE n.codex_dedup_key <> ''
                UNION ALL
                SELECT n.source, n.event_id, n.source, n.event_id
                FROM temp_lineage_events n
                WHERE n.codex_dedup_key = ''
            )
            SELECT lw.member_source AS source, lw.member_event_id AS event_id,
                   d.source AS winner_source, d.event_id AS winner_event_id,
                   d.model AS winner_model, d.project AS winner_project,
                   (d.timestamp_ms / \(bucketMs)) * \(bucketMs) AS winner_bucket_start
            FROM lineage_winner lw
            JOIN content_winner cw ON cw.member_source = lw.win_source
                AND cw.member_event_id = lw.win_event_id
            JOIN temp_deduped_events d ON d.source = cw.win_source
                AND d.event_id = cw.win_event_id;
        """
    }
    // MARK: - Finalize derived (global dedup + aggregate)

    @discardableResult
    public func finalizeDerived(
        hostname: String,
        compactFrozen: Bool = false,
        strategy: UsageFinalizeStrategy = .automatic,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> UsageFinalizeResult {
        try queue.sync {
            try ensurePerformanceIndexesUnlocked()
            var result = UsageFinalizeResult(reportingEligible: true, blockedReasons: [], collapsedInheritedEvents: 0)
            var didCompact = false
            try transaction {
                try claimLegacyRawRowsIfUnambiguousUnlocked(hostname: hostname)
                try discardLegacyNetworkDirtyKeysUnlocked(hostname: hostname)
                try discardRedundantGroupDirtyKeysUnlocked(hostname: hostname)
                result = try withBackgroundResourcePriority {
                    try recomputeDispatchUnlocked(hostname: hostname, strategy: strategy, progress: progress)
                }
                // 只有显式 finalize 表示调用方已经成功完成整轮来源扫描。其它内部重算
                // （例如 hostname 对齐）不能清除此门禁，否则部分扫描失败后会 fail-open。
                try deleteKeyUnlocked(Self.rawDerivationPendingKey)
                // 冻结压实是显式开启的省磁盘行为（默认关闭）：删原始行不可逆，只在调用方（应用采集链路）
                // 明确要求时才做，绝不对任意导入的历史数据默认自动删。本轮派生已算好并落库后，在同一
                // 事务内顺序推进冻结水位并压实：先推进 frozen（单调、满足前置才推），再删被新冻结区间的
                // 原始行。二者同事务原子提交——绝不允许「删了行但 frozen 没推进」的中间态。
                // 这两个方法均为 *Unlocked，不自带 queue.sync/transaction，也不再触发 recompute。
                if compactFrozen {
                    let advancedTo = try advanceFrozenWatermarkUnlocked(hostname: hostname)
                    if advancedTo > 0 {
                        try compactFrozenRawUnlocked(hostname: hostname, frozen: advancedTo)
                        didCompact = true
                    }
                }
            }
            // VACUUM 必须在事务外执行（SQLite 限制）；失败无害，下一轮压实后重试即可回收。
            if didCompact { try? exec("VACUUM;") }
            return result
        }
    }

    /// 全量派生会顺序读写数 GB SQLite 临时数据并持续占用一个核心。把当前 ledger worker
    /// 线程的 CPU 降为后台优先级，让前台应用和用户交互优先；重算结束（含抛错）后恢复。
    /// 磁盘 I/O 保持正常吞吐，绝不使用 IOPOL_THROTTLE 人为将读写压到 2MB/s 导致数小时卡顿。
    private func withBackgroundResourcePriority<T>(_ operation: () throws -> T) rethrows -> T {
        let previousCPU = getpriority(PRIO_DARWIN_THREAD, 0)
        let cpuChanged = setpriority(PRIO_DARWIN_THREAD, 0, PRIO_DARWIN_BG) == 0
        defer {
            if cpuChanged {
                _ = setpriority(PRIO_DARWIN_THREAD, 0, previousCPU >= 0 ? previousCPU : 0)
            }
        }
        return try operation()
    }

    private struct RawEvent {
        let id: String; let source: String; let model: String; let project: String
        let timestampMs: Int64; let counts: UsageTokenCounts
        let sessionHash: String; let inherited: Bool; let hasTotalSnapshot: Bool; let lineageFingerprint: String
        let codexDedupKey: String
        let skillCounts: [String: Int]; let mcpCounts: [String: Int]
        let mergeStrategy: String
        /// 采集机标识：派生聚合按各事件自带 hostname 归属，实现本地保留多机快照。
        let hostname: String
    }

    private struct RawEditEntry {
        let source: String; let model: String; let project: String
        let timestampMs: Int64; let added: Int64; let deleted: Int64
        /// 采集机标识：edit bucket 聚合按各条目自带 hostname 归属。
        let hostname: String
    }

    /// skill/mcp 计数合并用的中间表示（携带 tier，供四级去重）。
    private struct SkillMergeEvent {
            let source: String
            let eventID: String
            let model: String
            let project: String
            let sessionHash: String
            let timestampMs: Int64
            let inherited: Bool
            let billableTotal: Int64
            let lineageFingerprint: String
            let codexDedupKey: String
            let skillCounts: [String: Int]
            let mcpCounts: [String: Int]
            let tier: Int
    }

    /// v8 归属优先级 tier（数值越大优先级越高）。
    /// - legacy：source_file_hash 为空的历史 append/upsert 行（无文件归属）。
    /// - ownedHistory：source_file_hash 非空，但其文件已从磁盘消失（scan_status='missing'）或无 checkpoint 行。
    /// - ownedActive：source_file_hash 非空且其文件当前在册且非 missing。
    private enum AttributionTier: Int {
        case legacy = 0
        case ownedHistory = 1
        case ownedActive = 2
    }

    private struct TieredRawEvent {
        let event: RawEvent
        let tier: AttributionTier
    }

    /// 计算单行的归属 tier：空 source_file_hash 视为 legacy；非空则看其文件是否在 activeFiles 中。
    private func attributionTier(sourceFileHash: String, activeFiles: Set<String>) -> AttributionTier {
        if sourceFileHash.isEmpty { return .legacy }
        return activeFiles.contains(sourceFileHash) ? .ownedActive : .ownedHistory
    }

    /// 当前在册且非 missing 的文件归属键集合（usage_files.scan_status<>'missing'）。
    /// 不在此集合中的非空 source_file_hash 即 ownedHistory（missing 或无 checkpoint）。
    private func ownedActiveFileIDsUnlocked() throws -> Set<String> {
        let statement = try prepare("SELECT file_id FROM usage_files WHERE scan_status<>'missing';")
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { result.insert(text(statement, 0)) }
        return result
    }

    // 全局重算派生表：读取全部原始事件 -> 血缘证明去重 -> 重算 buckets/sessions -> 差异写入并递增 revision。
    private func recomputeDerivedUnlocked(
        hostname: String,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> UsageFinalizeResult {
        let progressTotalStages = 8
        var progressStage = 0
        func advanceStage() {
            progressStage += 1
            progress?(progressStage, progressTotalStages)
        }

        // 全量去重 + 聚合下推到 SQLite，避免把 4.4M 行加载到 Swift 内存（原实现峰值 11GB+ 触发 jetsam）。
        // logical ID 结果会被 lineage/content 去重、冲突统计和 session project 共同使用，只物化一次，
        // 避免每个消费者都重新扫描和排序完整 usage_events 历史。
        try exec("DROP TABLE IF EXISTS temp_logical_events;")
        try exec("DROP TABLE IF EXISTS temp_lineage_events;")
        try exec("DROP TABLE IF EXISTS temp_deduped_events;")
        let bucketMs = Self.bucketMilliseconds
        let logicalSQL = Self.logicalEventsSQL(scoped: false)
        do {
            let logicalStmt = try prepare(logicalSQL)
            defer { sqlite3_finalize(logicalStmt) }
            try bind(logicalStmt, 1, hostname)
            try done(logicalStmt)
        }

        // lineage 去重的中间结果单独物化：content 去重和折叠数统计都要用它，
        // 否则两处各自重跑一遍 PARTITION BY lineage_fingerprint 的窗口排序。
        let lineageSQL = Self.lineageEventsSQL
        try exec(lineageSQL)

        let dedupSQL = Self.dedupedEventsSQL
        try exec(dedupSQL)
        advanceStage() // 1-3) 三级去重在 SQLite 内完成

        // 计算 lineage / content 去重折叠数：从原始事件经 tier+logical 去重后，
        // 按 lineage_fingerprint / codex_dedup_key 统计被折叠的事件数。
        let collapseCountSQL = """
            SELECT
                (SELECT COUNT(*) FROM temp_logical_events WHERE lineage_fingerprint <> '')
                    - (SELECT COUNT(DISTINCT lineage_fingerprint) FROM temp_logical_events WHERE lineage_fingerprint <> '') AS collapsed_inherited,
                (SELECT COUNT(*) FROM temp_lineage_events WHERE codex_dedup_key <> '')
                    - (SELECT COUNT(DISTINCT codex_dedup_key) FROM temp_lineage_events WHERE codex_dedup_key <> '') AS collapsed_content,
                (SELECT COUNT(*) FROM temp_logical_events WHERE inherited = 1 AND lineage_fingerprint = '') AS unprovable_inherited,
                (SELECT COALESCE(SUM(has_identity_conflict), 0) FROM temp_logical_events) AS identity_conflicts
            """
        var collapsedInheritedEvents = 0
        var collapsedContentDuplicates = 0
        var unprovableInherited = 0
        var identityConflicts = 0
        do {
            let collapseStmt = try prepare(collapseCountSQL)
            defer { sqlite3_finalize(collapseStmt) }
            if sqlite3_step(collapseStmt) == SQLITE_ROW {
                collapsedInheritedEvents = Int(sqlite3_column_int64(collapseStmt, 0))
                collapsedContentDuplicates = Int(sqlite3_column_int64(collapseStmt, 1))
                unprovableInherited = Int(sqlite3_column_int64(collapseStmt, 2))
                identityConflicts = Int(sqlite3_column_int64(collapseStmt, 3))
            }
        }

        // 不可证明的继承回放：inherited 但无 total snapshot（无 lineage 指纹），无法证明是否重复。
        // 上报为累计值幂等 upsert，重复由服务端吸收自愈，因此不阻断上报；仅在 blockedReasons 留信息性说明。
        var blockedReasons: [String] = []
        if unprovableInherited > 0 {
            blockedReasons.append("\(unprovableInherited) inherited replay event(s) without total snapshot cannot be proven duplicate; reporting proceeds (idempotent upsert self-heals)")
        }
        if identityConflicts > 0 {
            blockedReasons.append("\(identityConflicts) logical event(s) have conflicting identity (session/model/project) across same-tier files; reporting blocked")
        }

        // bucket token 聚合：直接 GROUP BY，不加载事件到 Swift。
        let bucketSQL = """
            SELECT source, model, project, (timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start,
                   SUM(input_tokens), SUM(output_tokens), SUM(cached_input_tokens),
                   SUM(cache_creation_input_tokens), SUM(reasoning_output_tokens), SUM(total_tokens)
            FROM temp_deduped_events
            GROUP BY source, model, project, bucket_start;
            """
        let bucketStmt = try prepare(bucketSQL)
        defer { sqlite3_finalize(bucketStmt) }

        struct BucketAgg {
            var counts = UsageTokenCounts()
            var skillCounts: [String: Int] = [:]
            var mcpCounts: [String: Int] = [:]
            var linesAdded: Int64 = 0
            var linesDeleted: Int64 = 0
            var codeMetricVersion = 0
        }
        var buckets: [String: BucketAgg] = [:]
        var bucketMeta: [String: (source: String, model: String, project: String, start: Int64)] = [:]

        while sqlite3_step(bucketStmt) == SQLITE_ROW {
            let source = text(bucketStmt, 0)
            let model = text(bucketStmt, 1)
            let project = text(bucketStmt, 2)
            let start = sqlite3_column_int64(bucketStmt, 3)
            let key = "\(source)\u{1}\(model)\u{1}\(project)\u{1}\(start)"
            let counts = UsageTokenCounts(
                input: sqlite3_column_int64(bucketStmt, 4),
                output: sqlite3_column_int64(bucketStmt, 5),
                cachedInput: sqlite3_column_int64(bucketStmt, 6),
                cacheCreationInput: sqlite3_column_int64(bucketStmt, 7),
                reasoningOutput: sqlite3_column_int64(bucketStmt, 8),
                reportedTotal: sqlite3_column_int64(bucketStmt, 9)
            )
            buckets[key] = BucketAgg(counts: counts)
            bucketMeta[key] = (source, model, project, start)
        }

        advanceStage() // 4) bucket token 聚合完成

        // skill/mcp 计数合并：SQL MAX(JSON) 无法按 key 取 max，因此加载所有非空计数事件
        // （约 1.5 万行），在 Swift 端复现 tier→logical ID→lineage→content 四级去重的计数合并。
        let skillEventSQL = """
            SELECT e.source, e.event_id, e.model, e.project, e.session_hash, e.timestamp_ms,
                   e.inherited,
                   (e.input_tokens + e.output_tokens + e.cached_input_tokens
                    + e.cache_creation_input_tokens + e.reasoning_output_tokens) AS billable_total,
                   e.lineage_fingerprint, e.codex_dedup_key,
                   e.skill_counts_json, e.mcp_counts_json,
                   CASE
                       WHEN e.source_file_hash = '' THEN 0
                       WHEN EXISTS (SELECT 1 FROM usage_files f WHERE f.file_id = e.source_file_hash AND f.scan_status <> 'missing') THEN 2
                       ELSE 1
                   END AS tier
            FROM usage_events e
            WHERE e.hostname = ? AND (e.skill_counts_json <> '{}' OR e.mcp_counts_json <> '{}');
            """
        let skillEventStmt = try prepare(skillEventSQL)
        defer { sqlite3_finalize(skillEventStmt) }
        try bind(skillEventStmt, 1, hostname)
        var skillEvents: [SkillMergeEvent] = []
        while sqlite3_step(skillEventStmt) == SQLITE_ROW {
            skillEvents.append(SkillMergeEvent(
                source: text(skillEventStmt, 0),
                eventID: text(skillEventStmt, 1),
                model: text(skillEventStmt, 2),
                project: text(skillEventStmt, 3),
                sessionHash: text(skillEventStmt, 4),
                timestampMs: sqlite3_column_int64(skillEventStmt, 5),
                inherited: sqlite3_column_int64(skillEventStmt, 6) != 0,
                billableTotal: sqlite3_column_int64(skillEventStmt, 7),
                lineageFingerprint: text(skillEventStmt, 8),
                codexDedupKey: text(skillEventStmt, 9),
                skillCounts: decodeStringIntMap(text(skillEventStmt, 10)),
                mcpCounts: decodeStringIntMap(text(skillEventStmt, 11)),
                tier: Int(sqlite3_column_int64(skillEventStmt, 12))
            ))
        }

        // skill/mcp 计数合并：三级去重后按 bucket 汇总（实现见 mergeSkillCountsByBucketUnlocked）。
        let logicalDeduped = logicalDedupedSkillEvents(skillEvents)
        for merged in try mergeSkillCountsByBucketUnlocked(skillEvents, bucketMs: bucketMs) {
            if var agg = buckets[merged.key] {
                agg.skillCounts = UsageToolMetrics.mergeCounts(agg.skillCounts, merged.skillCounts)
                agg.mcpCounts = UsageToolMetrics.mergeCounts(agg.mcpCounts, merged.mcpCounts)
                buckets[merged.key] = agg
            }
        }

        // collapsedInheritedEvents / collapsedContentDuplicates 由 SQL 全量去重统计（覆盖所有事件），
        // 此处 Swift 仅处理 skill/mcp 计数合并，不覆盖折叠数。
        advanceStage() // 4.5) skill/mcp 合并完成


        // edit 条目聚合（edit 表行数少，沿用原 Swift 实现）。
        let editMetricSources = try readEditMetricSourcesUnlocked()
        for key in bucketMeta.keys {
            guard let meta = bucketMeta[key], editMetricSources.contains(meta.source) else { continue }
            buckets[key]?.codeMetricVersion = UsageEditLines.codeMetricVersion
        }
        for edit in try readAllRawEditEntries(hostname: hostname) {
            let start = (edit.timestampMs / bucketMs) * bucketMs
            let key = "\(edit.source)\u{1}\(edit.model)\u{1}\(edit.project)\u{1}\(start)"
            var agg = buckets[key] ?? BucketAgg()
            agg.linesAdded = saturatedAdd(agg.linesAdded, edit.added)
            agg.linesDeleted = saturatedAdd(agg.linesDeleted, edit.deleted)
            agg.codeMetricVersion = UsageEditLines.codeMetricVersion
            buckets[key] = agg
            bucketMeta[key] = (edit.source, edit.model, edit.project, start)
        }
        advanceStage() // 5) edit 聚合完成

        // session 聚合：8.1M session 事件全部下推到 SQLite，仅返回 ~2.7K 个 session 结果行。
        // 三级去重（tier 优先级）+ 分段活跃秒数 + 计数 + 小时直方图均在 SQL 内完成。
        var sessionProject: [String: (project: String, timestampMs: Int64)] = [:]
        var sessionSkillCounts: [String: [String: Int]] = [:]

        // session skills 使用 tier→logical 结果但不做 lineage/content 合并：继承回放携带的 skill
        // 属于子 session，不能通过 lineage 并入原 session。这样既避免 SQL MAX(JSON) 漏计，
        // 又保持原聚合器「仅非 inherited token 事件贡献 session skills」的口径。
        for event in logicalDeduped where !event.inherited && !event.skillCounts.isEmpty {
            let key = "\(event.source)\u{1}\(event.sessionHash)"
            sessionSkillCounts[key] = UsageToolMetrics.mergeCounts(
                sessionSkillCounts[key] ?? [:],
                event.skillCounts
            )
        }

        // session project 必须从 tier+logical 去重结果取，不能从 lineage/content 去重后的
        // temp_deduped_events 取——被血缘折叠的事件可能携带另一个 session 的 project，去重后会丢失。
        // 顺序扫描已物化的 logical 行，在 Swift 仅保留每个 session 的最新 project（约 2.7K 项），
        // 比再次对 4.4M 原始行执行 GROUP BY + window sort 更省磁盘 I/O。
        let sessionProjSQL = """
            SELECT source, session_hash, project, timestamp_ms
            FROM temp_logical_events
            WHERE project <> '';
            """
        do {
            let sessionProjStmt = try prepare(sessionProjSQL)
            defer { sqlite3_finalize(sessionProjStmt) }
            while sqlite3_step(sessionProjStmt) == SQLITE_ROW {
                let source = text(sessionProjStmt, 0)
                let sessionHash = text(sessionProjStmt, 1)
                let project = text(sessionProjStmt, 2)
                let timestampMs = sqlite3_column_int64(sessionProjStmt, 3)
                let key = "\(source)\u{1}\(sessionHash)"
                if let current = sessionProject[key], current.timestampMs >= timestampMs { continue }
                sessionProject[key] = (project, timestampMs)
            }
        }

        let sessions = try aggregateSessionsStreamingUnlocked(
            hostname: hostname,
            sessionProject: sessionProject,
            sessionSkillCounts: sessionSkillCounts
        )
        advanceStage() // 6) session 聚合完成

        // 全量收尾：把本轮的完整冲突集落盘。identityConflicts 是 reportingEligible 的唯一门禁，
        // 增量路径的 updateScopedIdentityConflictsUnlocked 只替换作用域内的键，依赖这里先
        // 建立全量基线。不写的话表永远为空，作用域外的历史冲突会丢，
        // 导致 eligible 误判为 true。仅追加持久化写入，不改全量自身的计算。
        try rebuildIdentityConflictsUnlocked(hostname: hostname)

        try exec("DROP TABLE IF EXISTS temp_logical_events;")
        try exec("DROP TABLE IF EXISTS temp_lineage_events;")


        // 差异写入：仅对内容变化的行提升 revision，未变行保持原 revision/synced。
        let newRevision = try nextRevisionUnlocked(hostname: hostname)
        var changed = false
        let frozen = try frozenBeforeMsUnlocked(hostname)

        var existingBuckets = try readBucketRowsUnlocked(hostname: hostname)
        for (key, meta) in bucketMeta {
            if frozen > 0 && meta.start < frozen { continue }
            let aggregate = buckets[key]!
            let bucket = UsageBucket(
                hostname: hostname, source: meta.source, model: meta.model, project: meta.project,
                bucketStart: date(meta.start), counts: aggregate.counts,
                skillCounts: aggregate.skillCounts, mcpCounts: aggregate.mcpCounts,
                linesAdded: aggregate.linesAdded, linesDeleted: aggregate.linesDeleted,
                codeMetricVersion: aggregate.codeMetricVersion
            )
            let existing = existingBuckets[key]
            if existing?.bucket != bucket {
                try upsertBucketUnlocked(bucket, revision: newRevision)
                changed = true
            }
            existingBuckets[key] = nil
        }
        for (key, row) in existingBuckets {
            if frozen > 0 && millis(row.bucket.bucketStart) < frozen { continue }
            try deleteBucketUnlocked(hostname: hostname, key: key)
            changed = true
        }

        var existingSessions = try readSessionRowsUnlocked(hostname: hostname)
        advanceStage() // 7) bucket 差异写完成
        for session in sessions {
            let key = "\(session.source)\u{1}\(session.sessionHash)"
            if frozen > 0 && millis(session.lastActivity) < frozen { continue }
            let existing = existingSessions[key]
            if existing?.session != session {
                try upsertSessionUnlocked(session, revision: newRevision)
                changed = true
            }
            existingSessions[key] = nil
        }
        for (key, row) in existingSessions {
            if frozen > 0 && millis(row.session.lastActivity) < frozen { continue }
            try deleteSessionUnlocked(hostname: hostname, key: key)
            changed = true
        }

        if !changed {
            try setIntUnlocked(key: revisionKey(hostname), value: newRevision - 1)
        }

        let eligible = identityConflicts == 0
        try setTextUnlocked(key: reportingEligibleKey(hostname), value: eligible ? "1" : "0")
        advanceStage() // 8) session 差异写完成

        // 持久化 logical 组 -> bucket 自然键映射，供增量 finalize 把旧 bucket 纳入作用域。
        // 必须在 temp_deduped_events 被 drop 之前执行。
        let bms = Self.bucketMilliseconds
        try exec("DELETE FROM usage_logical_bucket_map WHERE hostname='\(hostname)';")
        try exec("""
            INSERT OR REPLACE INTO usage_logical_bucket_map(
                hostname,source,event_id,bucket_model,bucket_project,bucket_start)
            SELECT '\(hostname)', source, event_id, model, project,
                   (timestamp_ms/\(bms))*\(bms)
            FROM temp_deduped_events;
            """)

        try? exec("DROP TABLE IF EXISTS temp_deduped_events;")

        return UsageFinalizeResult(
            reportingEligible: eligible,
            blockedReasons: blockedReasons,
            collapsedInheritedEvents: collapsedInheritedEvents,
            collapsedContentDuplicates: collapsedContentDuplicates
        )
    }

    public func reportingEligible(hostname: String) throws -> Bool {
        try queue.sync {
            // 任一采集/派生阶段未完成都必须 fail-closed，绝不上报陈旧或不完整派生。
            guard try !hasLocalDerivationPendingUnlocked() else { return false }
            return (try readTextUnlocked(key: reportingEligibleKey(hostname)) ?? "1") == "1"
        }
    }


    // MARK: - 增量 finalize

    /// 派生重算策略。
    public enum UsageFinalizeStrategy: Sendable {
        /// 前置条件满足时走增量，否则自动回退全量。生产默认。
        case automatic
        /// 强制全量重算。显式 rebuild 与等价性验证使用。
        case fullRecompute
    }

    /// 增量作用域的 bucket 数上限。超过说明本轮改动面已接近全量，
    /// 逐 bucket 差异写反而比一次全表 GROUP BY 慢，直接回退。
    private static let incrementalBucketLimit = 5000

    /// 作用域事件数占该 hostname 全部事件的比例上限。超过就退回全量。
    ///
    /// 增量只有在作用域远小于全表时才划算。优化闭包索引后，即使处理 50% 的事件仍只需数十秒，
    /// 远快于多 GB 库的全量重算。
    private static let incrementalScopeFraction = 0.5

    /// 增量基线标志：一次成功的全量重算会置位，表示派生表与 identity 冲突表都已重建完毕。
    /// 没有基线就不能增量——增量只修补差异，修补一个不存在或不可信的基线毫无意义。
    private static let incrementalBaselineKey = "incremental_baseline_ready"

    /// identity 冲突键的物化视图。
    ///
    /// reportingEligible 是上报门禁，必须精确。全量路径靠一次全表 GROUP BY 数冲突组；
    /// 增量路径不能这么做，那正是要消掉的 10 秒。所以把「当前处于冲突态的 logical 组」
    /// 持久化成稀疏表：全量重算整表重建，增量重算只增删作用域内的键。
    /// 表内该 hostname 无行 <=> 无冲突 <=> eligible。
    private func ensureIdentityConflictTableUnlocked() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_identity_conflicts(
              hostname TEXT NOT NULL,
              source TEXT NOT NULL,
              event_id TEXT NOT NULL,
              PRIMARY KEY(hostname,source,event_id)
            );
            """)
    }

    private func identityConflictCountUnlocked(hostname: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM usage_identity_conflicts WHERE hostname=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// 全量路径收尾：从刚物化的 temp_logical_events 整表重建该 hostname 的冲突集。
    private func rebuildIdentityConflictsUnlocked(hostname: String) throws {
        try ensureIdentityConflictTableUnlocked()
        do {
            let statement = try prepare("DELETE FROM usage_identity_conflicts WHERE hostname=?;")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try done(statement)
        }
        let statement = try prepare("""
            INSERT OR IGNORE INTO usage_identity_conflicts(hostname,source,event_id)
            SELECT ?, source, event_id FROM temp_logical_events WHERE has_identity_conflict = 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try done(statement)
    }

    /// 增量路径：只替换作用域内的冲突键，作用域外的原始行本轮没变，冲突态不会变。
    private func updateScopedIdentityConflictsUnlocked(hostname: String) throws {
        try ensureIdentityConflictTableUnlocked()
        do {
            let statement = try prepare("""
                DELETE FROM usage_identity_conflicts
                WHERE hostname = ?
                  AND EXISTS (SELECT 1 FROM temp_scope_events s
                              WHERE s.source = usage_identity_conflicts.source
                                AND s.event_id = usage_identity_conflicts.event_id);
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname); try done(statement)
        }
        let statement = try prepare("""
            INSERT OR IGNORE INTO usage_identity_conflicts(hostname,source,event_id)
            SELECT ?, source, event_id FROM temp_logical_events WHERE has_identity_conflict = 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try done(statement)
    }

    private func clearDirtyKeysUnlocked(hostname: String) throws {
        guard try tableExistsUnlocked("usage_dirty_keys") else { return }
        let statement = try prepare("DELETE FROM usage_dirty_keys WHERE hostname=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try done(statement)
    }

    /// Drop dirty keys left by older builds that treated append-only network sources as if they
    /// were replace-by-file logs. Network sources maintain affected buckets inside
    /// recordNetworkEvents, so these synthetic-file dirty keys only force a pointless full
    /// recompute on large ledgers. Local JSONL file dirty keys are preserved.
    private func discardLegacyNetworkDirtyKeysUnlocked(hostname: String) throws {
        guard try tableExistsUnlocked("usage_dirty_keys"), try tableExistsUnlocked("usage_files") else { return }
        let statement = try prepare("""
            DELETE FROM usage_dirty_keys
            WHERE hostname=?
              AND kind IN ('logical','session','bucket')
              AND instr(key, char(1)) > 1
              AND substr(key, 1, instr(key, char(1)) - 1) IN (
                  SELECT DISTINCT source FROM usage_files
                  WHERE parser_version >= ? AND source <> ''
              );
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        try bind(statement, 2, Int64(Self.networkParserVersion))
        try done(statement)
    }

    /// Older builds eagerly stored lineage/content dirty keys for every row in files that merely
    /// transitioned to missing. Those group keys are redundant whenever a logical dirty key for
    /// the same raw row is also present: dirty propagation recomputes lineage/content from the
    /// logical seed using the raw row that is still retained for missing files. Removing only the
    /// provably-covered group seeds preserves orphan lineage/content keys that may be the sole
    /// evidence after a file-level raw delete, while avoiding hundreds of thousands of redundant
    /// propagation seeds on large ledgers.
    private func discardRedundantGroupDirtyKeysUnlocked(hostname: String) throws {
        guard try tableExistsUnlocked("usage_dirty_keys"), try tableExistsUnlocked("usage_events") else { return }
        let deleteLineage = try prepare("""
            DELETE FROM usage_dirty_keys
            WHERE hostname = ? AND kind = 'lineage'
              AND EXISTS (
                  SELECT 1
                  FROM usage_events e INDEXED BY idx_usage_events_host_lineage
                  JOIN usage_dirty_keys d ON d.hostname = usage_dirty_keys.hostname
                    AND d.kind = 'logical'
                    AND d.key = e.source || char(1) || e.event_id
                  WHERE e.hostname = usage_dirty_keys.hostname
                    AND e.lineage_fingerprint = usage_dirty_keys.key
                    AND e.lineage_fingerprint <> ''
              );
            """)
        defer { sqlite3_finalize(deleteLineage) }
        try bind(deleteLineage, 1, hostname)
        try done(deleteLineage)

        let deleteContent = try prepare("""
            DELETE FROM usage_dirty_keys
            WHERE hostname = ? AND kind = 'content'
              AND EXISTS (
                  SELECT 1
                  FROM usage_events e INDEXED BY idx_usage_events_host_content
                  JOIN usage_dirty_keys d ON d.hostname = usage_dirty_keys.hostname
                    AND d.kind = 'logical'
                    AND d.key = e.source || char(1) || e.event_id
                  WHERE e.hostname = usage_dirty_keys.hostname
                    AND e.codex_dedup_key = usage_dirty_keys.key
                    AND e.codex_dedup_key <> ''
              );
            """)
        defer { sqlite3_finalize(deleteContent) }
        try bind(deleteContent, 1, hostname)
        try done(deleteContent)
    }

    private func derivedHasAnyRowUnlocked(hostname: String) throws -> Bool {
        for table in ["usage_buckets", "usage_sessions"] {
            guard try tableExistsUnlocked(table) else { continue }
            let statement = try prepare("SELECT 1 FROM \(table) WHERE hostname=? LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            if sqlite3_step(statement) == SQLITE_ROW { return true }
        }
        return false
    }

    /// 增量前置判据。任一不满足即回退全量——回退永远安全，只是慢。
    ///
    /// - 脏键表 / 冲突表不存在：老库尚未建表。
    /// - 无基线标志：上一次成功的全量重算才建立基线；首次 finalize、reset、迁移后都没有。
    /// - rebuild 挂起：协调层正在整轮重扫，基线不可信。
    /// - 派生层无行：没有可修补的基线。
    /// - 冻结水位非 0：冻结区原始行可能已被 compact 物理删除，去重组在原始层已不完整，
    ///   闭包展开会漏掉被删成员；且全量对冻结区 bucket 跳过差异写，复现这套语义不划算。
    ///
    /// 不再用 dirty-key 数量做前置早退：missing 文件和文件级 replace 会一次性登记大量
    /// lineage/content/logical 键，但真实受影响的 bucket / session 可能很小。增量路径内部
    /// 会在闭包展开过程中按事件作用域比例和 bucket 数上限回退，全量重算只应由真实作用域决定。
    private func canRecomputeIncrementallyUnlocked(hostname: String) throws -> Bool {
        guard try tableExistsUnlocked("usage_dirty_keys") else { return false }
        guard try tableExistsUnlocked("usage_identity_conflicts") else { return false }
        guard try tableExistsUnlocked("usage_logical_bucket_map") else { return false }
        guard try readTextUnlocked(key: Self.incrementalBaselineKey) != nil else { return false }
        guard try readTextUnlocked(key: Self.rebuildPendingKey) == nil else { return false }
        guard try frozenBeforeMsUnlocked(hostname) == 0 else { return false }
        return try derivedHasAnyRowUnlocked(hostname: hostname)
    }

    /// One-time recovery for ledgers migrated before the incremental finalize baseline was
    /// persisted. v10 migration marks raw derivation as pending because hostname was added to
    /// raw rows. If that migration already backfilled every raw row and existing derived rows
    /// match the current parser generation, a later scan may only have a small dirty-key set
    /// (for example files transitioning to missing). Without this baseline, automatic finalize
    /// falls back to a full recompute over very large local ledgers.
    ///
    /// This does not clear raw_derivation_pending. It only creates the metadata required for
    /// the normal incremental path to safely consume the existing dirty keys.
    @discardableResult
    public func recoverIncrementalBaselineIfSafe(
        hostname: String,
        currentParserVersion: Int,
        maxEvents: Int64 = UsageLedgerStore.defaultMaxEventsForBaselineRecovery
    ) throws -> UsageIncrementalBaselineRecovery {
        guard currentParserVersion > 0 else { return .notNeeded }
        return try queue.sync {
            var recovery: UsageIncrementalBaselineRecovery = .notNeeded
            try transaction {
                guard try readTextUnlocked(key: Self.incrementalBaselineKey) == nil else { return }
                guard try readTextUnlocked(key: Self.rawDerivationPendingKey) != nil else { return }
                guard try readTextUnlocked(key: Self.rebuildPendingKey) == nil else { return }
                guard try readTextUnlocked(key: Self.unresolvedLegacyRawHostnameKey) == nil else { return }
                guard try (readIntUnlocked(key: Self.rebuildCompletedParserVersionKey) ?? 0) >= Int64(currentParserVersion) else { return }
                guard try !hasEmptyRawHostnameUnlocked() else { return }
                guard try !hasActiveCheckpointOlderThanParserUnlocked(currentParserVersion) else { return }
                guard try derivedHasAnyRowUnlocked(hostname: hostname) else { return }
                guard try !hostEventCountExceedsUnlocked(hostname: hostname, limit: maxEvents) else {
                    recovery = .deferred
                    return
                }

                try ensureIdentityConflictTableUnlocked()
                try ensureLogicalBucketMapUnlocked()
                try rebuildIncrementalBaselineTablesUnlocked(hostname: hostname)
                try setTextUnlocked(key: Self.incrementalBaselineKey, value: "1")
                recovery = .recovered
            }
            return recovery
        }
    }

    private func hasEmptyRawHostnameUnlocked() throws -> Bool {
        for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
            guard try tableExistsUnlocked(table) else { continue }
            let statement = try prepare("SELECT 1 FROM \(table) WHERE hostname='' LIMIT 1;")
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW { return true }
        }
        return false
    }

    private func hasActiveCheckpointOlderThanParserUnlocked(_ parserVersion: Int) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM usage_files WHERE scan_status<>'missing' AND parser_version<? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Int64(parserVersion))
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func ensureLogicalBucketMapUnlocked() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_logical_bucket_map(
              hostname TEXT NOT NULL,
              source TEXT NOT NULL,
              event_id TEXT NOT NULL,
              bucket_model TEXT NOT NULL,
              bucket_project TEXT NOT NULL,
              bucket_start INTEGER NOT NULL,
              PRIMARY KEY(hostname,source,event_id)
            );
            """)
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_logical_bucket_map_bucket
            ON usage_logical_bucket_map(hostname,bucket_model,bucket_project,bucket_start,source);
            """)
    }

    private func clearIdentityConflictsUnlocked(hostname: String) throws {
        try ensureIdentityConflictTableUnlocked()
        let statement = try prepare("DELETE FROM usage_identity_conflicts WHERE hostname=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        try done(statement)
    }

    private func clearLogicalBucketMapUnlocked(hostname: String) throws {
        try ensureLogicalBucketMapUnlocked()
        let statement = try prepare("DELETE FROM usage_logical_bucket_map WHERE hostname=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        try done(statement)
    }

    private func rebuildIncrementalBaselineTablesUnlocked(hostname: String) throws {
        try clearIdentityConflictsUnlocked(hostname: hostname)
        try clearLogicalBucketMapUnlocked(hostname: hostname)
        let bucketMs = Self.bucketMilliseconds
        try exec("DROP TABLE IF EXISTS temp_logical_events;")
        try exec("DROP TABLE IF EXISTS temp_lineage_events;")
        try exec("DROP TABLE IF EXISTS temp_deduped_events;")
        defer {
            try? exec("DROP TABLE IF EXISTS temp_logical_events;")
            try? exec("DROP TABLE IF EXISTS temp_lineage_events;")
            try? exec("DROP TABLE IF EXISTS temp_deduped_events;")
        }
        do {
            let statement = try prepare(Self.logicalEventsSQL(scoped: false))
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            try done(statement)
        }
        let conflicts = try prepare("""
            INSERT OR IGNORE INTO usage_identity_conflicts(hostname,source,event_id)
            SELECT ?, source, event_id FROM temp_logical_events WHERE has_identity_conflict = 1;
            """)
        defer { sqlite3_finalize(conflicts) }
        try bind(conflicts, 1, hostname)
        try done(conflicts)
        try exec(Self.lineageEventsSQL)
        try exec(Self.dedupedEventsSQL)
        let statement = try prepare("""
            INSERT OR REPLACE INTO usage_logical_bucket_map(
                hostname,source,event_id,bucket_model,bucket_project,bucket_start
            )
            SELECT ?, source, event_id, model, project,
                   (timestamp_ms / \(bucketMs)) * \(bucketMs)
            FROM temp_deduped_events;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        try done(statement)
    }

    /// 增量重算：只重算脏闭包覆盖的 bucket / session，其余派生行原样不动。
    ///
    /// 返回 nil 表示本轮不适合增量（作用域过大），调用方回退全量。
    private func recomputeDerivedIncrementalUnlocked(
        hostname: String,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> UsageFinalizeResult? {
        let progressTotalStages = 8
        var progressStage = 0
        func advanceStage() {
            progressStage += 1
            progress?(progressStage, progressTotalStages)
        }

        // 1) 脏键 -> 不动点闭包 -> 作用域。三张 temp_dirty_* 表要活到 temp_scope_events 物化完，
        //    所以这里自己管生命周期，不复用 expandDirtyScopeUnlocked 的 defer 清理。
        try dropDirtyClosureTablesUnlocked()
        try exec("CREATE TEMP TABLE temp_dirty_logical(source TEXT NOT NULL, event_id TEXT NOT NULL, PRIMARY KEY(source,event_id));")
        try exec("CREATE TEMP TABLE temp_dirty_lineage(fingerprint TEXT PRIMARY KEY);")
        try exec("CREATE TEMP TABLE temp_dirty_content(dedup_key TEXT PRIMARY KEY);")
        defer { try? dropDirtyClosureTablesUnlocked() }
        defer { try? exec("DROP TABLE IF EXISTS temp_scope_events;") }

        try seedDirtyKeysUnlocked(hostname: hostname)
        try propagateDirtyClosureUnlocked(hostname: hostname)
        var scope = try collectDirtyScopeUnlocked(hostname: hostname)
        guard scope.buckets.count <= Self.incrementalBucketLimit else { return nil }

        // temp_scope_events 初始化为闭包内的 logical 键。
        try exec("DROP TABLE IF EXISTS temp_scope_events;")
        try exec("CREATE TEMP TABLE temp_scope_events(source TEXT NOT NULL, event_id TEXT NOT NULL, PRIMARY KEY(source,event_id));")
        try exec("INSERT OR IGNORE INTO temp_scope_events(source,event_id) SELECT source,event_id FROM temp_dirty_logical;")

        // 组补全：lineage / content 两层去重是「全组语义」——胜者由整个 partition 内的相对顺序
        // 决定。如果作用域只包含某个 lineage 组的部分成员，ROW_NUMBER 选出的胜者可能与全量不一致。
        // 这里把作用域内任何行所涉及的 lineage 指纹 / content 键下的全部 logical 组都补进
        // temp_scope_events，循环到不动点，保证闭包性质。
        let bucketMsForScope = Self.bucketMilliseconds
        let scopeLineageStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_events(source, event_id)
            SELECT DISTINCT e2.source, e2.event_id
            FROM temp_scope_events s
            CROSS JOIN usage_events e1 INDEXED BY idx_usage_events_dirty_lineage
              ON e1.source = s.source AND e1.event_id = s.event_id
            CROSS JOIN usage_events e2 INDEXED BY idx_usage_events_host_lineage
              ON e2.lineage_fingerprint = e1.lineage_fingerprint
            WHERE e1.hostname = ? AND e2.hostname = ?
              AND e1.lineage_fingerprint <> '' AND e2.lineage_fingerprint <> ''
              AND e1.hostname <> '';
            """)
        let scopeContentStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_events(source, event_id)
            SELECT DISTINCT e2.source, e2.event_id
            FROM temp_scope_events s
            CROSS JOIN usage_events e1 INDEXED BY idx_usage_events_dirty_content
              ON e1.source = s.source AND e1.event_id = s.event_id
            CROSS JOIN usage_events e2 INDEXED BY idx_usage_events_host_content
              ON e2.codex_dedup_key = e1.codex_dedup_key
            WHERE e1.hostname = ? AND e2.hostname = ?
              AND e1.codex_dedup_key <> '' AND e2.codex_dedup_key <> ''
              AND e1.hostname <> '';
            """)
        // bucket / session 共居补全。bucket 与 session 的聚合值是「落进它的全部事件」的和，
        // 而 scoped 去重只能看见 temp_scope_events 里的行。若某个已在作用域的 bucket
        // 还有其它（干净）贡献者没进来，重算会丢掉它们的 token，轻则算小、
        // 重则算成空而误删整个 bucket。不变量：bucket 进作用域 ⇒ 落进它的
        // 全部事件必须进 temp_scope_events；session 同理（project / skillCounts 取自该
        // session 全部 logical 胜者）。
        //
        // 注意：bucket 进作用域不只来自事件——edit 脏键、直接登记的 bucket 脏键、
        // 旧 logical→bucket 映射都会把 bucket 放进来，而它们对应的 token 事件可能一行都不在
        // temp_scope_events 里。所以这里把作用域的 bucket / session 集合也物化成临时表，
        // 让闭包在「事件 ↔ bucket/session」两侧双向迭代到不动点。
        try exec("DROP TABLE IF EXISTS temp_scope_buckets;")
        try exec("DROP TABLE IF EXISTS temp_scope_sessions_seed;")
        try exec("""
            CREATE TEMP TABLE temp_scope_buckets(
                source TEXT NOT NULL, model TEXT NOT NULL, project TEXT NOT NULL,
                bucket_start INTEGER NOT NULL,
                PRIMARY KEY(source, model, project, bucket_start));
            """)
        try exec("""
            CREATE TEMP TABLE temp_scope_sessions_seed(
                source TEXT NOT NULL, session_hash TEXT NOT NULL,
                PRIMARY KEY(source, session_hash));
            """)
        defer {
            try? exec("DROP TABLE IF EXISTS temp_scope_buckets;")
            try? exec("DROP TABLE IF EXISTS temp_scope_sessions_seed;")
        }
        // 种子：非事件来源的 bucket / session 键（edit 脏键、直接登记的键、旧映射）。
        for key in scope.buckets {
            let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard parts.count == 4, let start = Int64(parts[3]) else { continue }
            let stmt = try prepare("INSERT OR IGNORE INTO temp_scope_buckets(source,model,project,bucket_start) VALUES(?,?,?,?);")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, String(parts[0])); try bind(stmt, 2, String(parts[1]))
            try bind(stmt, 3, String(parts[2])); try bind(stmt, 4, start)
            try done(stmt)
        }
        for key in scope.sessions {
            let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let stmt = try prepare("INSERT OR IGNORE INTO temp_scope_sessions_seed(source,session_hash) VALUES(?,?);")
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, String(parts[0])); try bind(stmt, 2, String(parts[1]))
            try done(stmt)
        }
        // 事件 → bucket / session：作用域内事件所在的 bucket / session 全部入集。
        let scopeBucketFromEventStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_buckets(source, model, project, bucket_start)
            SELECT DISTINCT e.source, e.model, e.project,
                   (e.timestamp_ms / \(bucketMsForScope)) * \(bucketMsForScope)
            FROM temp_scope_events s
            CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_logical
              ON e.source = s.source AND e.event_id = s.event_id
            WHERE e.hostname = ? AND e.hostname <> '';
            """)
        let scopeSessionFromEventStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_sessions_seed(source, session_hash)
            SELECT DISTINCT e.source, e.session_hash
            FROM temp_scope_events s
            CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_logical
              ON e.source = s.source AND e.event_id = s.event_id
            WHERE e.hostname = ? AND e.session_hash <> '' AND e.hostname <> '';
            """)
        // bucket / session → 事件：作用域内 bucket / session 的全部贡献事件入集。
        let scopeEventFromBucketStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_events(source, event_id)
            SELECT DISTINCT e.source, e.event_id
            FROM temp_scope_buckets b
            CROSS JOIN usage_events e INDEXED BY idx_usage_events_host_time
              ON e.hostname = ?
             AND e.timestamp_ms >= b.bucket_start
             AND e.timestamp_ms < b.bucket_start + \(bucketMsForScope)
             AND e.source = b.source
             AND e.model = b.model
             AND e.project = b.project
            WHERE e.hostname <> '';
            """)
        // bucket → 事件的第二条路径：沿旧 logical→bucket 映射反查。去重胜者的 model 是
        // COALESCE(MAX(CASE WHEN model <> 'unknown' THEN model END), MAX(model)) 的产物，可能不等于组内
        // 任何一行的原始 model；lineage / content 两层去重还会把胜者改判到另一个组的 bucket。
        // 所以光按原始行的 (model, project, bucket) 匹配会漏掉这类贡献者，必须靠上一轮
        // 落盘的映射反查才能把它们拉进作用域。
        let scopeEventFromBucketMapStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_events(source, event_id)
            SELECT DISTINCT m.source, m.event_id
            FROM temp_scope_buckets b
            CROSS JOIN usage_logical_bucket_map m ON m.source = b.source AND m.bucket_model = b.model
                AND b.project = m.bucket_project AND b.bucket_start = m.bucket_start
            WHERE m.hostname = ?;
            """)
        // 事件 → 旧 bucket。上一轮落盘的映射记录了每个事件当时实际贡献到哪个 bucket。
        // 去重胜者的 model 是 COALESCE 产物，lineage / content 两层还会把胜者改判到另一个
        // 组的 bucket，所以旧 bucket 无法从原始行的 (model, project) 还原。胜者易主后旧 bucket
        // 必须进作用域，否则重算不到它，旧值永久残留。
        let scopeBucketFromMapStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_buckets(source, model, project, bucket_start)
            SELECT DISTINCT m.source, m.bucket_model, m.bucket_project, m.bucket_start
            FROM temp_scope_events s
            CROSS JOIN usage_logical_bucket_map m ON m.source = s.source AND m.event_id = s.event_id
            WHERE m.hostname = ?;
            """)
        let scopeEventFromSessionStmt = try prepare("""
            INSERT OR IGNORE INTO temp_scope_events(source, event_id)
            SELECT DISTINCT e.source, e.event_id
            FROM temp_scope_sessions_seed t
            CROSS JOIN usage_events e INDEXED BY idx_usage_events_session
              ON e.session_hash = t.session_hash
            WHERE e.source = t.source AND e.hostname = ? AND e.hostname <> '';
            """)
        defer {
            sqlite3_finalize(scopeLineageStmt); sqlite3_finalize(scopeContentStmt)
            sqlite3_finalize(scopeBucketFromEventStmt); sqlite3_finalize(scopeSessionFromEventStmt)
            sqlite3_finalize(scopeEventFromBucketStmt); sqlite3_finalize(scopeEventFromSessionStmt)
            sqlite3_finalize(scopeEventFromBucketMapStmt); sqlite3_finalize(scopeBucketFromMapStmt)
        }
        // 作用域上限先算出来，循环里每轮检查。不能等循环结束再判：雪崩式增长的代价正是在
        // 循环内花掉的，实测跑满 16 轮要 54 秒，而这轮本来就注定退回全量（全量只要 4 秒）。
        let hostEventTotal = try hostEventCountUnlocked(hostname: hostname)
        let scopeEventCeiling = hostEventTotal > 0
            ? Int(Double(hostEventTotal) * Self.incrementalScopeFraction)
            : Int.max
        var scopeOverflowed = false
        for _ in 0 ..< Self.dirtyClosureIterationLimit {
            var added: Int32 = 0
            sqlite3_reset(scopeLineageStmt); sqlite3_clear_bindings(scopeLineageStmt)
            try bind(scopeLineageStmt, 1, hostname); try bind(scopeLineageStmt, 2, hostname)
            try done(scopeLineageStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeContentStmt); sqlite3_clear_bindings(scopeContentStmt)
            try bind(scopeContentStmt, 1, hostname); try bind(scopeContentStmt, 2, hostname)
            try done(scopeContentStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeBucketFromEventStmt); sqlite3_clear_bindings(scopeBucketFromEventStmt)
            try bind(scopeBucketFromEventStmt, 1, hostname)
            try done(scopeBucketFromEventStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeSessionFromEventStmt); sqlite3_clear_bindings(scopeSessionFromEventStmt)
            try bind(scopeSessionFromEventStmt, 1, hostname)
            try done(scopeSessionFromEventStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeEventFromBucketStmt); sqlite3_clear_bindings(scopeEventFromBucketStmt)
            try bind(scopeEventFromBucketStmt, 1, hostname)
            try done(scopeEventFromBucketStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeEventFromSessionStmt); sqlite3_clear_bindings(scopeEventFromSessionStmt)
            try bind(scopeEventFromSessionStmt, 1, hostname)
            try done(scopeEventFromSessionStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeEventFromBucketMapStmt); sqlite3_clear_bindings(scopeEventFromBucketMapStmt)
            try bind(scopeEventFromBucketMapStmt, 1, hostname)
            try done(scopeEventFromBucketMapStmt)
            added += sqlite3_changes(db)
            sqlite3_reset(scopeBucketFromMapStmt); sqlite3_clear_bindings(scopeBucketFromMapStmt)
            try bind(scopeBucketFromMapStmt, 1, hostname)
            try done(scopeBucketFromMapStmt)
            added += sqlite3_changes(db)
            if added == 0 { break }
            if try Int(scalar("SELECT COUNT(*) FROM temp_scope_events;")) > scopeEventCeiling {
                scopeOverflowed = true
                break
            }
        }
        // 作用域太大就退回全量：增量的开销随作用域线性增长，而全量是固定成本。
        if scopeOverflowed { return nil }
        advanceStage() // 1) 闭包展开 + 组补全完成

        // 组补全后，scope.buckets / scope.sessions 需要按补全后的 temp_scope_events 重新收集，
        // 否则新补进的 logical 组所在的 bucket 不会被重算（也不会被删）。
        do {
            let bucketMs = Self.bucketMilliseconds
            let stmt = try prepare("""
                SELECT DISTINCT e.source, e.model, e.project,
                       (e.timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start
                FROM temp_scope_events s
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_logical
                  ON e.source = s.source AND e.event_id = s.event_id
                WHERE e.hostname = ? AND e.hostname <> '';
                """)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, hostname)
            while sqlite3_step(stmt) == SQLITE_ROW {
                scope.buckets.insert(compositeKey(
                    text(stmt, 0), text(stmt, 1), text(stmt, 2),
                    String(sqlite3_column_int64(stmt, 3))
                ))
            }
        }
        do {
            let stmt = try prepare("""
                SELECT DISTINCT e.source, e.session_hash FROM temp_scope_events s
                CROSS JOIN usage_events e INDEXED BY idx_usage_events_dirty_logical
                  ON e.source = s.source AND e.event_id = s.event_id
                WHERE e.hostname = ? AND e.session_hash <> '' AND e.hostname <> '';
                """)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, hostname)
            while sqlite3_step(stmt) == SQLITE_ROW {
                scope.sessions.insert(compositeKey(text(stmt, 0), text(stmt, 1)))
            }
        }
        // 把作用域内 logical 组上一轮贡献到的旧 bucket 键并入 scope.buckets。
        // 胜者易主后旧 bucket 的贡献行可能已不在 usage_events 里，无法从原始行还原 bucket 键，
        // 必须靠这张映射表把旧 bucket 纳入作用域，重算后若无贡献就走删除分支。
        do {
            let stmt = try prepare("""
                SELECT DISTINCT m.source, m.bucket_model, m.bucket_project, m.bucket_start
                FROM temp_scope_events s
                CROSS JOIN usage_logical_bucket_map m ON m.source = s.source AND m.event_id = s.event_id
                WHERE m.hostname = ?;
                """)
            defer { sqlite3_finalize(stmt) }
            try bind(stmt, 1, hostname)
            while sqlite3_step(stmt) == SQLITE_ROW {
                scope.buckets.insert(compositeKey(
                    text(stmt, 0), text(stmt, 1), text(stmt, 2),
                    String(sqlite3_column_int64(stmt, 3))
                ))
            }
        }
        guard scope.buckets.count <= Self.incrementalBucketLimit else { return nil }

        // 2) 作用域内三级去重。SQL 与全量共用同一份常量，只有 logical 种子多一个 JOIN。
        let bucketMs = Self.bucketMilliseconds
        try exec("DROP TABLE IF EXISTS temp_logical_events;")
        try exec("DROP TABLE IF EXISTS temp_lineage_events;")
        try exec("DROP TABLE IF EXISTS temp_deduped_events;")
        defer {
            try? exec("DROP TABLE IF EXISTS temp_logical_events;")
            try? exec("DROP TABLE IF EXISTS temp_lineage_events;")
            try? exec("DROP TABLE IF EXISTS temp_deduped_events;")
        }
        // 胜者 bucket 无法从原始行反向枚举。logical 去重逐列取 MAX / COALESCE，同一
        // (source, event_id) 的多行可能分处不同文件、不同 model / project / 时间戳，合成的胜者
        // 会落进一个「组内没有任何一行在里面」的第三个 bucket。所以不存在从 bucket 自然键
        // 反查「所有可能贡献者」的 SQL——能表达这层关系的只有上一轮落盘的
        // usage_logical_bucket_map。
        //
        // 因此作用域必须以 logical 组为单位，在「logical 组 ↔ bucket」二部图上迭代：
        // 跑完 scoped 去重拿到新胜者 bucket 后，再拿这些 bucket 反查映射表，把同样贡献到
        // 它们的其它 logical 组拉进作用域，然后重跑去重。新拉进的组又可能带出新 bucket，
        // 所以要循环到不动点。temp_scope_events 只增不减且上界是全表，循环必终止。
        for _ in 0 ..< Self.dirtyClosureIterationLimit {
            // 每轮从头重建三张去重临时表（上一轮的作用域可能已变大）。
            // 循环退出时表一定存在，后续聚合阶段直接用。
            try exec("DROP TABLE IF EXISTS temp_logical_events;")
            try exec("DROP TABLE IF EXISTS temp_lineage_events;")
            try exec("DROP TABLE IF EXISTS temp_deduped_events;")
            do {
                let statement = try prepare(Self.logicalEventsSQL(scoped: true))
                defer { sqlite3_finalize(statement) }
                try bind(statement, 1, hostname)
                try done(statement)
            }
            try exec(Self.lineageEventsSQL)
            try exec(Self.dedupedEventsSQL)
            // 拿新胜者 bucket 反查映射表。该语句引用 temp_deduped_events，必须在该表
            // 建好之后才能 prepare，所以放在循环体内。
            // 先把胜者 bucket 键物化成一张小表：直接 JOIN 时 (timestamp_ms/N)*N 是表达式，
            // 用不上 idx_logical_bucket_map_bucket，会退化成 21k x 50k 的嵌套循环。
            try exec("DROP TABLE IF EXISTS temp_winner_buckets;")
            try exec("""
                CREATE TEMP TABLE temp_winner_buckets AS
                SELECT DISTINCT source, model, project,
                       (timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start
                FROM temp_deduped_events;
                """)
            let winnerBucketStmt = try prepare("""
                INSERT OR IGNORE INTO temp_scope_events(source, event_id)
                SELECT DISTINCT m.source, m.event_id
                FROM usage_logical_bucket_map m
                JOIN temp_winner_buckets w ON w.source = m.source
                    AND w.model = m.bucket_model AND w.project = m.bucket_project
                    AND w.bucket_start = m.bucket_start
                WHERE m.hostname = ?;
                """)
            try bind(winnerBucketStmt, 1, hostname)
            try done(winnerBucketStmt)
            let grew = sqlite3_changes(db)
            sqlite3_finalize(winnerBucketStmt)
            try exec("DROP TABLE IF EXISTS temp_winner_buckets;")
            if grew == 0 { break }
        }
        advanceStage() // 2-3) 三级去重完成

        // 去重胜者的 model 可能是 COALESCE(MAX(CASE WHEN model <> 'unknown' THEN model END), MAX(model))
        // 的结果，不等于组内任何一行的原始 model。因此胜者实际落进的 bucket 自然键可能不在
        // scope.buckets（它是按原始行的 model/project 收集的）。这里把去重结果真实的 bucket 键
        // 并入作用域，避免 token 聚合阶段被 guard scope.buckets.contains 误丢。
        do {
            let statement = try prepare("""
                SELECT DISTINCT source, model, project,
                       (timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start
                FROM temp_deduped_events;
                """)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                scope.buckets.insert(compositeKey(
                    text(statement, 0), text(statement, 1), text(statement, 2),
                    String(sqlite3_column_int64(statement, 3))
                ))
            }
        }
        // 外层不动点循环可能又把新的 logical 组拉进了 temp_scope_events，而 scope.sessions
        // 是循环之前收集的。这里按最终的作用域重新补齐，否则新拉进的行所属 session
        // 不会被重算（也不会被删）。
        do {
            let statement = try prepare("""
                SELECT DISTINCT e.source, e.session_hash FROM temp_scope_events s
                CROSS JOIN usage_events e ON e.source = s.source AND e.event_id = s.event_id
                WHERE e.hostname = ? AND e.session_hash <> '' AND e.hostname <> '';
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            while sqlite3_step(statement) == SQLITE_ROW {
                scope.sessions.insert(compositeKey(text(statement, 0), text(statement, 1)))
            }
        }
        // 旧 bucket 也要按最终作用域重新并入：循环新拉进的 logical 组上一轮可能贡献到
        // 另一个 bucket，胜者易主后那个 bucket 必须进作用域才能被重算或删除。
        do {
            let statement = try prepare("""
                SELECT DISTINCT m.source, m.bucket_model, m.bucket_project, m.bucket_start
                FROM temp_scope_events s
                CROSS JOIN usage_logical_bucket_map m ON m.source = s.source AND m.event_id = s.event_id
                WHERE m.hostname = ?;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            while sqlite3_step(statement) == SQLITE_ROW {
                scope.buckets.insert(compositeKey(
                    text(statement, 0), text(statement, 1), text(statement, 2),
                    String(sqlite3_column_int64(statement, 3))
                ))
            }
        }
        // 3) identity 冲突：只替换作用域内的键，其余不动。eligible 由整表是否为空判定，仍然精确。
        try updateScopedIdentityConflictsUnlocked(hostname: hostname)

        var blockedReasons: [String] = []
        var unprovableInherited = 0
        do {
            let statement = try prepare(
                "SELECT COUNT(*) FROM temp_logical_events WHERE inherited = 1 AND lineage_fingerprint = '';"
            )
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                unprovableInherited = Int(sqlite3_column_int64(statement, 0))
            }
        }
        if unprovableInherited > 0 {
            blockedReasons.append("\(unprovableInherited) inherited replay event(s) without total snapshot cannot be proven duplicate; reporting proceeds (idempotent upsert self-heals)")
        }
        let identityConflicts = try identityConflictCountUnlocked(hostname: hostname)
        if identityConflicts > 0 {
            blockedReasons.append("\(identityConflicts) logical event(s) have conflicting identity (session/model/project) across same-tier files; reporting blocked")
        }

        // 4) 折叠统计只覆盖作用域内的组。这两个数是遥测/信息性输出（生产无消费者），
        //    语义相应收窄为「本轮重算的组里折叠了多少」，与增量口径一致。
        var collapsedInheritedEvents = 0
        var collapsedContentDuplicates = 0
        do {
            let statement = try prepare("""
                SELECT
                    (SELECT COUNT(*) FROM temp_logical_events WHERE lineage_fingerprint <> '')
                        - (SELECT COUNT(DISTINCT lineage_fingerprint) FROM temp_logical_events WHERE lineage_fingerprint <> ''),
                    (SELECT COUNT(*) FROM temp_lineage_events WHERE codex_dedup_key <> '')
                        - (SELECT COUNT(DISTINCT codex_dedup_key) FROM temp_lineage_events WHERE codex_dedup_key <> '');
                """)
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                collapsedInheritedEvents = Int(sqlite3_column_int64(statement, 0))
                collapsedContentDuplicates = Int(sqlite3_column_int64(statement, 1))
            }
        }

        // 5) bucket token 聚合：只聚合作用域覆盖的 bucket。
        struct BucketAgg {
            var counts = UsageTokenCounts()
            var skillCounts: [String: Int] = [:]
            var mcpCounts: [String: Int] = [:]
            var linesAdded: Int64 = 0
            var linesDeleted: Int64 = 0
            var codeMetricVersion = 0
        }
        var buckets: [String: BucketAgg] = [:]
        var bucketMeta: [String: (source: String, model: String, project: String, start: Int64)] = [:]
        do {
            let statement = try prepare("""
                SELECT source, model, project, (timestamp_ms / \(bucketMs)) * \(bucketMs) AS bucket_start,
                       SUM(input_tokens), SUM(output_tokens), SUM(cached_input_tokens),
                       SUM(cache_creation_input_tokens), SUM(reasoning_output_tokens), SUM(total_tokens)
                FROM temp_deduped_events
                GROUP BY source, model, project, bucket_start;
                """)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let source = text(statement, 0)
                let model = text(statement, 1)
                let project = text(statement, 2)
                let start = sqlite3_column_int64(statement, 3)
                let key = compositeKey(source, model, project, String(start))
                // 作用域外的 bucket 不能在这里写入：它的聚合只含作用域内的行，是残缺值。
                // 正常情况下不会出现——闭包已把所有成员行的 bucket 都收进 scope——
                // 这里是防御性丢弃，宁可不动也不写错。
                guard scope.buckets.contains(key) else { continue }
                buckets[key] = BucketAgg(counts: UsageTokenCounts(
                    input: sqlite3_column_int64(statement, 4),
                    output: sqlite3_column_int64(statement, 5),
                    cachedInput: sqlite3_column_int64(statement, 6),
                    cacheCreationInput: sqlite3_column_int64(statement, 7),
                    reasoningOutput: sqlite3_column_int64(statement, 8),
                    reportedTotal: sqlite3_column_int64(statement, 9)
                ))
                bucketMeta[key] = (source, model, project, start)
            }
        }
        advanceStage() // 4) bucket token 聚合完成

        // 6) skill/mcp 四级去重合并：SQL 的 MAX(JSON) 无法按 key 取 max，必须在 Swift 端重做
        //    tier -> logical -> lineage -> content 四级。只取作用域内的事件。
        let scopedSkillEvents = try readScopedSkillMergeEventsUnlocked(hostname: hostname)
        for ev in try mergeSkillCountsByBucketUnlocked(scopedSkillEvents, bucketMs: bucketMs) {
            guard var agg = buckets[ev.key] else { continue }
            agg.skillCounts = UsageToolMetrics.mergeCounts(agg.skillCounts, ev.skillCounts)
            agg.mcpCounts = UsageToolMetrics.mergeCounts(agg.mcpCounts, ev.mcpCounts)
            buckets[ev.key] = agg
        }
        advanceStage() // 4.5) skill/mcp 合并完成

        // 7) edit 聚合：edit 表按 tool_use_id 全局去重，胜者可能在作用域外的文件里，
        //    所以读全量 edit 条目（该表行数远小于 usage_events），只把落在作用域内的 bucket 计入。
        let editMetricSources = try readEditMetricSourcesUnlocked()
        for key in bucketMeta.keys {
            guard let meta = bucketMeta[key], editMetricSources.contains(meta.source) else { continue }
            buckets[key]?.codeMetricVersion = UsageEditLines.codeMetricVersion
        }
        for edit in try readAllRawEditEntries(hostname: hostname) {
            let start = (edit.timestampMs / bucketMs) * bucketMs
            let key = compositeKey(edit.source, edit.model, edit.project, String(start))
            guard scope.buckets.contains(key) else { continue }
            var agg = buckets[key] ?? BucketAgg()
            agg.linesAdded = saturatedAdd(agg.linesAdded, edit.added)
            agg.linesDeleted = saturatedAdd(agg.linesDeleted, edit.deleted)
            agg.codeMetricVersion = UsageEditLines.codeMetricVersion
            buckets[key] = agg
            bucketMeta[key] = (edit.source, edit.model, edit.project, start)
        }
        advanceStage() // 5) edit 聚合完成

        // 8) session 聚合：project / skills 取自 logical 去重结果（不做 lineage/content 合并——
        //    继承回放携带的 skill 属于子 session，不能并入原 session）。
        var sessionProject: [String: (project: String, timestampMs: Int64)] = [:]
        var sessionSkillCounts: [String: [String: Int]] = [:]
        for ev in logicalDedupedSkillEvents(scopedSkillEvents) where !ev.inherited && !ev.skillCounts.isEmpty {
            let key = compositeKey(ev.source, ev.sessionHash)
            sessionSkillCounts[key] = UsageToolMetrics.mergeCounts(sessionSkillCounts[key] ?? [:], ev.skillCounts)
        }
        do {
            let statement = try prepare("""
                SELECT source, session_hash, project, timestamp_ms
                FROM temp_logical_events WHERE project <> '';
                """)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let key = compositeKey(text(statement, 0), text(statement, 1))
                let timestampMs = sqlite3_column_int64(statement, 3)
                if let current = sessionProject[key], current.timestampMs >= timestampMs { continue }
                sessionProject[key] = (text(statement, 2), timestampMs)
            }
        }
        let sessions = try aggregateSessionsScopedUnlocked(
            hostname: hostname,
            sessionKeys: scope.sessions,
            sessionProject: sessionProject,
            sessionSkillCounts: sessionSkillCounts
        )
        advanceStage() // 6) session 聚合完成

        // 9) 差异写。作用域外的派生行完全不碰——这正是增量省下时间的地方。
        let newRevision = try nextRevisionUnlocked(hostname: hostname)
        var changed = false

        let existingBuckets = try readBucketRowsUnlocked(hostname: hostname)
        for key in scope.buckets {
            guard let meta = bucketMeta[key], let aggregate = buckets[key] else {
                // 作用域内但本轮聚合无结果：该 bucket 的全部贡献都没了（源文件被删/行被替换/
                // 去重胜者移出该 bucket）。必须删除，留着就是永远不会再更新的陈旧值。
                if existingBuckets[key] != nil {
                    try deleteBucketUnlocked(hostname: hostname, key: key)
                    changed = true
                }
                continue
            }
            // 空聚合：token 六分量全 0、lines 全 0、skill/mcp 都空。通常是 edit 循环用
            // `buckets[key] ?? BucketAgg()` 给一个无 token 贡献的 key 凭空建了全 0 agg，
            // 而该 edit 的 added/deleted 也恰好为 0。这种 bucket 不该存在，走删除分支。
            // 注意：纯 edit bucket（token 全 0 但 lines 非 0）是合法的，不会被误删。
            let c = aggregate.counts
            let isEmpty = c.input == 0 && c.output == 0 && c.cachedInput == 0
                && c.cacheCreationInput == 0 && c.reasoningOutput == 0 && c.reportedTotal == 0
                && aggregate.linesAdded == 0 && aggregate.linesDeleted == 0
                && aggregate.skillCounts.isEmpty && aggregate.mcpCounts.isEmpty
            if isEmpty {
                if existingBuckets[key] != nil {
                    try deleteBucketUnlocked(hostname: hostname, key: key)
                    changed = true
                }
                continue
            }
            let bucket = UsageBucket(
                hostname: hostname, source: meta.source, model: meta.model, project: meta.project,
                bucketStart: date(meta.start), counts: aggregate.counts,
                skillCounts: aggregate.skillCounts, mcpCounts: aggregate.mcpCounts,
                linesAdded: aggregate.linesAdded, linesDeleted: aggregate.linesDeleted,
                codeMetricVersion: aggregate.codeMetricVersion
            )
            if existingBuckets[key]?.bucket != bucket {
                try upsertBucketUnlocked(bucket, revision: newRevision)
                changed = true
            }
        }

        let existingSessions = try readSessionRowsUnlocked(hostname: hostname)
        advanceStage() // 7) bucket 差异写完成
        var producedSessionKeys: Set<String> = []
        for session in sessions {
            let key = compositeKey(session.source, session.sessionHash)
            producedSessionKeys.insert(key)
            if existingSessions[key]?.session != session {
                try upsertSessionUnlocked(session, revision: newRevision)
                changed = true
            }
        }
        // 作用域内但本轮没聚合出来的 session：其活动行已全部消失，删掉。
        for key in scope.sessions where !producedSessionKeys.contains(key) {
            if existingSessions[key] != nil {
                try deleteSessionUnlocked(hostname: hostname, key: key)
                changed = true
            }
        }

        if !changed {
            try setIntUnlocked(key: revisionKey(hostname), value: newRevision - 1)
        }

        let eligible = identityConflicts == 0
        try setTextUnlocked(key: reportingEligibleKey(hostname), value: eligible ? "1" : "0")
        advanceStage() // 8) session 差异写完成

        // 更新作用域内 logical 组的 bucket 映射：先删旧映射，再从 temp_deduped_events 写入新的。
        // 必须在 defer DROP temp_deduped_events 之前执行。
        let bms = Self.bucketMilliseconds
        try exec("""
            DELETE FROM usage_logical_bucket_map
            WHERE hostname='\(hostname)' AND EXISTS (
                SELECT 1 FROM temp_scope_events s
                WHERE s.source = usage_logical_bucket_map.source
                  AND s.event_id = usage_logical_bucket_map.event_id
            );
            """)
        try exec("""
            INSERT OR REPLACE INTO usage_logical_bucket_map(
                hostname,source,event_id,bucket_model,bucket_project,bucket_start)
            SELECT '\(hostname)', source, event_id, model, project,
                   (timestamp_ms/\(bms))*\(bms)
            FROM temp_deduped_events;
            """)

        return UsageFinalizeResult(
            reportingEligible: eligible,
            blockedReasons: blockedReasons,
            collapsedInheritedEvents: collapsedInheritedEvents,
            collapsedContentDuplicates: collapsedContentDuplicates
        )
    }

    /// 读取作用域内带 skill/mcp 计数的原始事件（含 tier）。与全量的 skillEventSQL 同构，
    /// 只多一个 JOIN temp_scope_events。
    private func readScopedSkillMergeEventsUnlocked(hostname: String) throws -> [SkillMergeEvent] {
        let statement = try prepare("""
            SELECT e.source, e.event_id, e.model, e.project, e.session_hash, e.timestamp_ms,
                   e.inherited,
                   (e.input_tokens + e.output_tokens + e.cached_input_tokens
                    + e.cache_creation_input_tokens + e.reasoning_output_tokens) AS billable_total,
                   e.lineage_fingerprint, e.codex_dedup_key,
                   e.skill_counts_json, e.mcp_counts_json,
                   CASE
                       WHEN e.source_file_hash = '' THEN 0
                       WHEN EXISTS (SELECT 1 FROM usage_files f WHERE f.file_id = e.source_file_hash AND f.scan_status <> 'missing') THEN 2
                       ELSE 1
                   END AS tier
            FROM temp_scope_events s
            CROSS JOIN usage_events e ON e.source = s.source AND e.event_id = s.event_id
            WHERE e.hostname = ? AND (e.skill_counts_json <> '{}' OR e.mcp_counts_json <> '{}') AND e.hostname <> '';
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        var events: [SkillMergeEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            events.append(SkillMergeEvent(
                source: text(statement, 0), eventID: text(statement, 1),
                model: text(statement, 2), project: text(statement, 3),
                sessionHash: text(statement, 4),
                timestampMs: sqlite3_column_int64(statement, 5),
                inherited: sqlite3_column_int64(statement, 6) != 0,
                billableTotal: sqlite3_column_int64(statement, 7),
                lineageFingerprint: text(statement, 8), codexDedupKey: text(statement, 9),
                skillCounts: decodeStringIntMap(text(statement, 10)),
                mcpCounts: decodeStringIntMap(text(statement, 11)),
                tier: Int(sqlite3_column_int64(statement, 12))
            ))
        }
        return events
    }

    /// session 聚合的作用域版：只重算 sessionKeys 里的 session。
    ///
    /// 与全量版共用同一个流式聚合器，只是把驱动 SQL 的 WHERE 收窄到目标 session。
    /// 单个 session 的聚合只依赖它自己的活动行，所以按 session 切分是无损的。
    private func aggregateSessionsScopedUnlocked(
        hostname: String,
        sessionKeys: Set<String>,
        sessionProject: [String: (project: String, timestampMs: Int64)],
        sessionSkillCounts: [String: [String: Int]]
    ) throws -> [UsageSession] {
        guard !sessionKeys.isEmpty else { return [] }
        try exec("DROP TABLE IF EXISTS temp_scope_sessions;")
        try exec("CREATE TEMP TABLE temp_scope_sessions(source TEXT NOT NULL, session_hash TEXT NOT NULL, PRIMARY KEY(source,session_hash));")
        defer { try? exec("DROP TABLE IF EXISTS temp_scope_sessions;") }
        do {
            let insert = try prepare("INSERT OR IGNORE INTO temp_scope_sessions(source,session_hash) VALUES(?,?);")
            defer { sqlite3_finalize(insert) }
            for key in sessionKeys {
                let parts = key.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { continue }
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                try bind(insert, 1, parts[0]); try bind(insert, 2, parts[1])
                try done(insert)
            }
        }
        return try aggregateSessionsStreamingUnlocked(
            hostname: hostname,
            sessionProject: sessionProject,
            sessionSkillCounts: sessionSkillCounts,
            scopedToTempSessions: true
        )
    }

    /// finalizeDerived 的重算调度：先试增量，不满足前置或作用域过大就回退全量。
    ///
    /// 两条路径都在同一个事务里，脏键的清除与派生写入原子提交——绝不允许「清了脏键但派生没写」。
    private func recomputeDispatchUnlocked(
        hostname: String,
        strategy: UsageFinalizeStrategy,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> UsageFinalizeResult {
        try ensureIdentityConflictTableUnlocked()
        if strategy == .automatic, try canRecomputeIncrementallyUnlocked(hostname: hostname) {
            if let result = try recomputeDerivedIncrementalUnlocked(hostname: hostname, progress: progress) {
                try clearDirtyKeysUnlocked(hostname: hostname)
                return result
            }
        }
        let result = try recomputeDerivedUnlocked(hostname: hostname, progress: progress)
        // 全量重算刚刚重建了完整基线（含 identity 冲突表），下一轮起可以走增量。
        try setTextUnlocked(key: Self.incrementalBaselineKey, value: "1")
        try clearDirtyKeysUnlocked(hostname: hostname)
        return result
    }
    // MARK: - Frozen watermark (compaction, unlocked; called inside finalizeDerived transaction)

    /// 冻结静默期：只固化「早于 now - 此值」且已对齐 30 分钟 bucket 边界的历史。取 30 天，远大于
    /// codex fork / claude resume 的常见回放窗口，把跨区去重折叠的偏差压到可忽略（已接受的"稍不准"）。
    static let frozenSilenceMs: Int64 = 30 * 24 * 60 * 60 * 1_000

    /// 推进冻结水位线（单调不减、永不回退），返回推进后的 frozen（未推进返回 0，表示本轮不 compact）。
    /// 目标 = floor((now - 静默期) / bucketMs) * bucketMs，与当前 frozen 取 max。
    /// 前置门禁（任一不满足则本轮不推进，保守放弃省空间而非冒错删风险）：
    /// - 全库不存在 scan_status='degraded' 的文件（degraded=解析未收敛，其区间可能后续补出 <frozen
    ///   事件；一票否决，避免固化未收敛区间）。
    /// - 无 raw_derivation_pending（finalize 事务内此刻已清除，天然满足；此处再校验一次是防御性冗余）。
    /// 注意：调用方保证已在 finalizeDerived 事务内、recompute 之后执行——本轮派生已反映最新活跃区。
    func advanceFrozenWatermarkUnlocked(hostname: String) throws -> Int64 {
        // degraded 一票否决：只要存在未收敛文件就不推进（保守）。
        if try scalar("SELECT EXISTS(SELECT 1 FROM usage_files WHERE scan_status='degraded');") != 0 {
            return 0
        }
        if try readTextUnlocked(key: Self.rawDerivationPendingKey) != nil { return 0 }

        let bucketMs = Self.bucketMilliseconds
        let nowMs = millis(Date())
        // 对齐到 30 分钟 bucket 边界，保证冻结边界永不劈开任何 bucket。
        let target = ((nowMs - Self.frozenSilenceMs) / bucketMs) * bucketMs
        let current = try frozenBeforeMsUnlocked(hostname)
        // 单调不减：目标不高于当前则不推进（含 now 回拨的情形——回拨使 target 变小，被 max 挡住）。
        guard target > current else { return 0 }
        try setIntUnlocked(key: frozenBeforeKey(hostname), value: target)
        return target
    }

    /// 压实：删除已冻结区间（timestamp < frozen）的原始行以回收磁盘。仅 usage_events 与
    /// usage_session_events 两张大表；usage_edit_entries 不动（体积可忽略）。
    /// - usage_events：按 timestamp_ms < frozen 逐行删（bucket 对齐后等价于 bucket_start < frozen）。
    /// - usage_session_events：仅删「完全冻结」的 session——该 (source,session_hash) 的所有事件都 < frozen
    ///   （MAX(timestamp) < frozen）。跨界 session（尚有 >=frozen 的事件）整体保留，避免截断其派生指标。
    /// **跨所有 hostname 删除**：hostname 下沉在原始事件层只是「采集机痕迹」，派生已由 rebuildForHostname +
    /// recompute 统一归属到当前 canonical hostname（包含所有采集机的贡献）。冻结边界是全局时间概念，
    /// 若只删 canonical hostname 的行，旧机器名（改名前/多机同步）的历史原始行会成为永不可回收的死数据。
    /// 必须在 finalizeDerived 事务内、frozen 推进之后同事务调用；VACUUM 由调用方在事务外执行。
    func compactFrozenRawUnlocked(hostname: String, frozen: Int64) throws {
        guard frozen > 0 else { return }
        let delEvents = try prepare("DELETE FROM usage_events WHERE timestamp_ms < ?;")
        defer { sqlite3_finalize(delEvents) }
        try bind(delEvents, 1, frozen); try done(delEvents)

        // 只删完全冻结 session 的 session_events：排除任何仍有 timestamp>=frozen 事件的 (source,session_hash)。
        // 按 (source,session_hash) 复合匹配（与聚合器 session 自然键一致），且跨 hostname 判定——
        // 同一逻辑 session 可能被不同采集机记录，只要任一机器仍有活跃事件就整体保留。
        let delSessions = try prepare("""
            DELETE FROM usage_session_events
            WHERE timestamp_ms < ?
              AND (source, session_hash) NOT IN (
                SELECT source, session_hash FROM usage_session_events
                WHERE timestamp_ms >= ?
              );
            """)
        defer { sqlite3_finalize(delSessions) }
        try bind(delSessions, 1, frozen); try bind(delSessions, 2, frozen)
        try done(delSessions)
    }

    // MARK: - Reads

    public func checkpoint(fileID: String) throws -> UsageFileCheckpoint? {
        try queue.sync {
            let statement = try prepare("SELECT source,path_hash,read_offset,file_size,mtime_ms,parser_version,scan_status FROM usage_files WHERE file_id=?;")
            defer { sqlite3_finalize(statement) }; try bind(statement, 1, fileID)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return UsageFileCheckpoint(fileID: fileID, source: text(statement, 0), pathHash: text(statement, 1), offset: sqlite3_column_int64(statement, 2), size: sqlite3_column_int64(statement, 3), modifiedAt: date(sqlite3_column_int64(statement, 4)), parserVersion: Int(sqlite3_column_int64(statement, 5)), status: text(statement, 6))
        }
    }

    /// Rename a checkpoint/raw attribution key when a source file's stable identity changes but
    /// its contents have not. This is used for Codex rollout files moved from sessions/ into
    /// archived_sessions/: the old path hash is a storage location, not a semantic file identity.
    public func migrateFileIdentityIfCheckpointMatches(
        from oldFileID: String,
        to newFileID: String,
        expectedSource: String,
        expectedSize: Int64,
        expectedModifiedAt: Date,
        expectedParserVersion: Int
    ) throws -> UsageFileCheckpoint? {
        guard oldFileID != newFileID else { return try checkpoint(fileID: newFileID) }
        return try queue.sync {
            guard try checkpointUnlocked(fileID: newFileID) == nil,
                  let old = try checkpointUnlocked(fileID: oldFileID),
                  old.source == expectedSource,
                  old.status == "complete",
                  old.size == expectedSize,
                  old.parserVersion == expectedParserVersion,
                  abs(old.modifiedAt.timeIntervalSince(expectedModifiedAt)) < 0.001
            else { return nil }

            try transaction {
                for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
                    guard try tableExistsUnlocked(table) else { continue }
                    let statement = try prepare("UPDATE \(table) SET source_file_hash=? WHERE source_file_hash=?;")
                    defer { sqlite3_finalize(statement) }
                    try bind(statement, 1, newFileID)
                    try bind(statement, 2, oldFileID)
                    try done(statement)
                }
                try deleteCheckpointUnlocked(fileID: oldFileID)
                try writeCheckpoint(UsageFileCheckpoint(
                    fileID: newFileID,
                    source: old.source,
                    pathHash: newFileID,
                    offset: old.offset,
                    size: old.size,
                    modifiedAt: old.modifiedAt,
                    parserVersion: old.parserVersion,
                    status: old.status
                ))
            }
            return try checkpointUnlocked(fileID: newFileID)
        }
    }

    private func checkpointUnlocked(fileID: String) throws -> UsageFileCheckpoint? {
        let statement = try prepare("SELECT source,path_hash,read_offset,file_size,mtime_ms,parser_version,scan_status FROM usage_files WHERE file_id=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, fileID)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return UsageFileCheckpoint(fileID: fileID, source: text(statement, 0), pathHash: text(statement, 1), offset: sqlite3_column_int64(statement, 2), size: sqlite3_column_int64(statement, 3), modifiedAt: date(sqlite3_column_int64(statement, 4)), parserVersion: Int(sqlite3_column_int64(statement, 5)), status: text(statement, 6))
    }

    private func deleteCheckpointUnlocked(fileID: String) throws {
        let statement = try prepare("DELETE FROM usage_files WHERE file_id=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, fileID)
        try done(statement)
    }

    /// 当前解析器是否必须执行一次显式全量 rebuild。
    ///
    /// 空库或仅含当前/更新 parser checkpoint 的合法库返回 false；以下任一情况返回 true：
    /// - 至少一个已记录文件的 parser_version 旧于当前版本；
    /// - 迁移库仍有原始/派生数据但没有任何 checkpoint，无法证明已由当前 parser 生成；
    /// - 原始或派生表中存在 epoch 之前的明显非法时间戳（涵盖 v1 的
    ///   Date.distantPast 错值 -62135769600000）。
    public func requiresParserRebuild(currentParserVersion: Int) throws -> Bool {
        guard currentParserVersion > 0 else { return true }
        return try queue.sync {
            // missing checkpoint 是不可重新解析的历史，不得让它永久触发 rebuild。
            // 一次成功完成的目标 parser 版本也作为持久高水位，避免 legacy 空归属历史反复触发。
            let completedVersion = try readIntUnlocked(key: Self.rebuildCompletedParserVersionKey) ?? 0
            if completedVersion >= Int64(currentParserVersion) { return false }
            let checkpoint = try prepare("SELECT 1 FROM usage_files WHERE scan_status<>'missing' AND parser_version<? LIMIT 1;")
            defer { sqlite3_finalize(checkpoint) }
            try bind(checkpoint, 1, Int64(currentParserVersion))
            if sqlite3_step(checkpoint) == SQLITE_ROW { return true }

            let missingCheckpoint = try prepare("""
                SELECT 1
                WHERE NOT EXISTS (SELECT 1 FROM usage_files)
                  AND (
                    EXISTS (SELECT 1 FROM usage_events)
                    OR EXISTS (SELECT 1 FROM usage_session_events)
                    OR EXISTS (SELECT 1 FROM usage_buckets)
                    OR EXISTS (SELECT 1 FROM usage_sessions)
                  );
                """)
           defer { sqlite3_finalize(missingCheckpoint) }
           if sqlite3_step(missingCheckpoint) == SQLITE_ROW { return true }

            // 安全网：活跃（非 missing）文件的原始事件携带 epoch 前非法时间戳（含 v1 distantPast 错值）
            // 必须触发 rebuild。已标 missing 的已删文件历史不再触发，避免无限 rebuild；
            // 派生表（buckets/sessions）由 raw 重算，不单独检查以免陈旧派生误报。
            let invalidTimestampSQL = """
                SELECT 1 FROM (
                  SELECT e.timestamp_ms AS value FROM usage_events e
                  WHERE e.timestamp_ms<0
                    AND EXISTS (SELECT 1 FROM usage_files f WHERE f.file_id=e.source_file_hash AND f.scan_status<>'missing')
                  UNION ALL
                  SELECT s.timestamp_ms FROM usage_session_events s
                  WHERE s.timestamp_ms<0
                    AND EXISTS (SELECT 1 FROM usage_files f WHERE f.file_id=s.source_file_hash AND f.scan_status<>'missing')
                ) LIMIT 1;
                """
            let invalidTimestamp = try prepare(invalidTimestampSQL)
            defer { sqlite3_finalize(invalidTimestamp) }
            return sqlite3_step(invalidTimestamp) == SQLITE_ROW
        }
    }

    public func buckets(hostname: String) throws -> [UsageBucket] {
        try queue.sync { try readBucketsUnlocked(hostname: hostname) }
    }

    public func sessions(hostname: String) throws -> [UsageSession] {
        try queue.sync { try readSessionsUnlocked(hostname: hostname) }
    }

    /// Returns the only non-empty hostname already present in the durable ledger, or nil when the
    /// ledger is empty or contains more than one hostname. This is a legacy-upgrade recovery aid,
    /// not a general hostname detector: callers must prefer explicit configuration and persisted
    /// user choice, and must never guess when the ledger is ambiguous.
    public func uniqueLegacyHostnameCandidate() throws -> String? {
        try queue.sync { try uniqueLegacyHostnameCandidateUnlocked() }
    }

    /// unlocked 版：供迁移事务内复用（不能再进 queue.sync）。
    private func uniqueLegacyHostnameCandidateUnlocked() throws -> String? {
        let statement = try prepare("""
            SELECT hostname FROM (
              SELECT hostname FROM usage_buckets WHERE TRIM(hostname)<>''
              UNION
              SELECT hostname FROM usage_sessions WHERE TRIM(hostname)<>''
            ) ORDER BY hostname LIMIT 2;
            """)
        defer { sqlite3_finalize(statement) }
        var hostnames: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            hostnames.append(text(statement, 0))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        guard hostnames.count == 1 else { return nil }
        return hostnames[0]
    }

    /// v10 以前的原始行没有 hostname。只有账本尚无派生设备，或唯一派生设备就是本次目标时，
    /// 才能证明这些行属于目标设备并一次性认领；多设备或 adopt 新名场景保持为空，避免被重复派生。
    private func claimLegacyRawRowsIfUnambiguousUnlocked(hostname: String) throws {
        let canonical = try readTextUnlocked(key: Self.canonicalHostnameKey).flatMap { $0.isEmpty ? nil : $0 }
        let unresolvedMigration = try readTextUnlocked(key: Self.unresolvedLegacyRawHostnameKey) == "1"
        // 正常 v10 库已有 canonical 且无迁移债务，直接 O(1) 返回；仅旧库迁移或尚未建立
        // canonical 的兼容场景才检查/更新原始大表。
        guard unresolvedMigration || canonical == nil else { return }
        let candidate = try uniqueLegacyHostnameCandidateUnlocked()
        let hasDerivedHostname = try hasAnyNonEmptyDerivedHostnameUnlocked()
        let mayClaim = canonical == hostname || (canonical == nil && (!hasDerivedHostname || candidate == hostname))
        guard mayClaim else { return }
        for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
            guard try tableExistsUnlocked(table) else { continue }
            let statement = try prepare("UPDATE \(table) SET hostname=? WHERE hostname='';")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            try done(statement)
        }
        try deleteKeyUnlocked(Self.unresolvedLegacyRawHostnameKey)
    }

    private func hasAnyNonEmptyDerivedHostnameUnlocked() throws -> Bool {
        let statement = try prepare("""
            SELECT 1 FROM (
              SELECT hostname FROM usage_buckets WHERE TRIM(hostname)<>''
              UNION SELECT hostname FROM usage_sessions WHERE TRIM(hostname)<>''
            ) LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    /// 兼容入口：汇总 usage_buckets 中所有 hostname 的全时段派生数据。
    public func summary(prices: [UsageModelPrice] = []) throws -> UsageSummary? {
        try summary(window: nil, containing: Date(), hostname: nil, prices: prices)
    }

    /// 派生桶汇总。hostname=nil 时跨所有设备展示；非 nil 时仅查询指定设备。
    /// window=nil 表示全时段；非 nil 使用调用方 calendar 的窗口，边界为 [start,end)。
    public func summary(
        window: UsageSummaryWindow?,
        containing date: Date,
        hostname: String? = nil,
        calendar: Calendar = .current,
        prices: [UsageModelPrice] = []
    ) throws -> UsageSummary? {
        try queue.sync { () throws -> UsageSummary? in
            guard let filter = bucketSummaryFilter(window: window, containing: date, hostname: hostname, calendar: calendar) else {
                return nil
            }
            let sql = """
                SELECT model,
                       SUM(input_tokens),
                       SUM(output_tokens),
                       SUM(cached_input_tokens),
                       SUM(cache_creation_input_tokens),
                       SUM(reasoning_output_tokens),
                       SUM(MAX(total_tokens, input_tokens + output_tokens + cached_input_tokens + cache_creation_input_tokens + reasoning_output_tokens)),
                       MAX(updated_at_ms)
                FROM usage_buckets
                \(filter.whereClause)
                GROUP BY model;
                """
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            try bindBucketSummaryFilter(filter, to: statement)
            var total = UsageTokenCounts(); var cost = 0.0; var newest: Int64?
            var found = false
            while sqlite3_step(statement) == SQLITE_ROW {
                found = true
                let counts = bucketSummaryCounts(statement)
                total = sumCounts(total, counts)
                cost += UsageCostEstimator.cost(model: text(statement, 0), counts: counts, prices: prices)
                newest = max(newest ?? 0, sqlite3_column_int64(statement, 7))
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return found ? UsageSummary(updatedAt: newest.map { self.date($0) }, counts: total, estimatedCostUSD: cost) : nil
        }
    }

    /// 按模型 token 汇总。hostname=nil 时跨所有设备；window=nil 表示全时段；
    /// 非 nil 使用调用方 calendar 的窗口区间，边界为 [start,end)。
    /// 仅聚合 token 计数（不含费用），按 total 降序返回；无数据返回空数组。
    public func modelSummary(
        window: UsageSummaryWindow?,
        containing date: Date,
        hostname: String? = nil,
        calendar: Calendar = .current
    ) throws -> [UsageModelTokenSummary] {
        try queue.sync { () throws -> [UsageModelTokenSummary] in
            guard let filter = bucketSummaryFilter(window: window, containing: date, hostname: hostname, calendar: calendar) else {
                return []
            }
            let sql = """
                SELECT model,
                       SUM(input_tokens),
                       SUM(output_tokens),
                       SUM(cached_input_tokens),
                       SUM(cache_creation_input_tokens),
                       SUM(reasoning_output_tokens),
                       SUM(MAX(total_tokens, input_tokens + output_tokens + cached_input_tokens + cache_creation_input_tokens + reasoning_output_tokens))
                FROM usage_buckets
                \(filter.whereClause)
                GROUP BY model;
                """
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            try bindBucketSummaryFilter(filter, to: statement)
            var rows: [UsageModelTokenSummary] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(UsageModelTokenSummary(model: text(statement, 0), counts: bucketSummaryCounts(statement)))
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return rows.sorted {
                if $0.counts.total == $1.counts.total { return $0.model < $1.model }
                return $0.counts.total > $1.counts.total
            }
        }
    }

    /// 指定 hostname 在 [start,end) 内、按 30min bucket_start 聚合的 output_tokens 时间序列。
    /// 用于看板 1 天 TPS 曲线（每个 30min bucket 的 output 之和 → /1800 = 平均 TPS）。
    /// 按 bucketStart 升序返回；无数据返回空数组。queue.sync 阻塞，勿在主线程调用。
    public func outputTokenBuckets(
        hostname: String? = nil,
        start: Date,
        end: Date
    ) throws -> [(bucketStart: Date, outputTokens: Int64)] {
        try queue.sync {
            var sql = "SELECT bucket_start_ms,SUM(output_tokens) FROM usage_buckets WHERE "
            if hostname != nil { sql += "hostname=? AND " }
            sql += "bucket_start_ms>=? AND bucket_start_ms<? "
                + "GROUP BY bucket_start_ms ORDER BY bucket_start_ms;"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if let hostname { try bind(statement, bindIndex, hostname); bindIndex += 1 }
            try bind(statement, bindIndex, millis(start))
            try bind(statement, bindIndex + 1, millis(end))
            var rows: [(bucketStart: Date, outputTokens: Int64)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((date(sqlite3_column_int64(statement, 0)), sqlite3_column_int64(statement, 1)))
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return rows
        }
    }

    /// 同上，但按 (bucket_start, model) 分组，供看板 1 天分模型曲线。
    public func outputTokenBucketsByModel(
        hostname: String? = nil,
        start: Date,
        end: Date
    ) throws -> [(bucketStart: Date, model: String, outputTokens: Int64)] {
        try queue.sync {
            var sql = "SELECT bucket_start_ms,model,SUM(output_tokens) FROM usage_buckets WHERE "
            if hostname != nil { sql += "hostname=? AND " }
            sql += "bucket_start_ms>=? AND bucket_start_ms<? "
                + "GROUP BY bucket_start_ms,model ORDER BY bucket_start_ms;"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            var bindIndex: Int32 = 1
            if let hostname { try bind(statement, bindIndex, hostname); bindIndex += 1 }
            try bind(statement, bindIndex, millis(start))
            try bind(statement, bindIndex + 1, millis(end))
            var rows: [(bucketStart: Date, model: String, outputTokens: Int64)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((date(sqlite3_column_int64(statement, 0)), text(statement, 1), sqlite3_column_int64(statement, 2)))
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return rows
        }
    }

    private struct BucketSummaryFilter {
        var whereClause: String
        var hostname: String?
        var interval: DateInterval?
    }

    private func bucketSummaryFilter(
        window: UsageSummaryWindow?,
        containing date: Date,
        hostname: String?,
        calendar: Calendar
    ) -> BucketSummaryFilter? {
        var predicates: [String] = []
        if hostname != nil { predicates.append("hostname=?") }
        var interval: DateInterval?
        if let window {
            guard let resolved = window.interval(containing: date, calendar: calendar) else { return nil }
            interval = resolved
            predicates.append("bucket_start_ms>=? AND bucket_start_ms<?")
        }
        return BucketSummaryFilter(
            whereClause: predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND "),
            hostname: hostname,
            interval: interval
        )
    }

    private func bindBucketSummaryFilter(_ filter: BucketSummaryFilter, to statement: OpaquePointer?) throws {
        var bindIndex: Int32 = 1
        if let hostname = filter.hostname {
            try bind(statement, bindIndex, hostname)
            bindIndex += 1
        }
        if let interval = filter.interval {
            try bind(statement, bindIndex, millis(interval.start))
            try bind(statement, bindIndex + 1, millis(interval.end))
        }
    }

    private func bucketSummaryCounts(_ statement: OpaquePointer?) -> UsageTokenCounts {
        UsageTokenCounts(
            input: sqlite3_column_int64(statement, 1),
            output: sqlite3_column_int64(statement, 2),
            cachedInput: sqlite3_column_int64(statement, 3),
            cacheCreationInput: sqlite3_column_int64(statement, 4),
            reasoningOutput: sqlite3_column_int64(statement, 5),
            reportedTotal: sqlite3_column_int64(statement, 6)
        )
    }

    private func sumCounts(_ left: UsageTokenCounts, _ right: UsageTokenCounts) -> UsageTokenCounts {
        UsageTokenCounts(
            input: saturatedAdd(left.input, right.input),
            output: saturatedAdd(left.output, right.output),
            cachedInput: saturatedAdd(left.cachedInput, right.cachedInput),
            cacheCreationInput: saturatedAdd(left.cacheCreationInput, right.cacheCreationInput),
            reasoningOutput: saturatedAdd(left.reasoningOutput, right.reasoningOutput),
            reportedTotal: saturatedAdd(left.reportedTotal, right.total)
        )
    }

    /// 单 hostname 的原始事件行数。增量作用域的相对大小判据。
    /// 调用方已持有队列，所以这里不再 queue.sync（会死锁）。
    private func hostEventCountUnlocked(hostname: String) throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM usage_events WHERE hostname=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func hostEventCountExceedsUnlocked(hostname: String, limit: Int64) throws -> Bool {
        guard limit >= 0 else { return true }
        let statement = try prepare("""
            SELECT COUNT(*) FROM (
              SELECT 1 FROM usage_events WHERE hostname=? LIMIT ?
            );
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)
        try bind(statement, 2, limit + 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return sqlite3_column_int64(statement, 0) > limit
    }

    public func eventCount() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM usage_events;"); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func sessionEventCount() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM usage_session_events;"); defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func readBucketsUnlocked(hostname: String) throws -> [UsageBucket] {
        let sql = """
            SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,skills_json,skill_counts_json,mcp_counts_json,lines_added,lines_deleted,code_metric_version
            FROM usage_buckets WHERE hostname=? ORDER BY bucket_start_ms,source,model,project;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsageBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5), cachedInput: sqlite3_column_int64(statement, 6), cacheCreationInput: sqlite3_column_int64(statement, 7), reasoningOutput: sqlite3_column_int64(statement, 8), reportedTotal: sqlite3_column_int64(statement, 9))
            result.append(UsageBucket(
                hostname: hostname, source: text(statement, 0), model: text(statement, 1), project: text(statement, 2),
                bucketStart: date(sqlite3_column_int64(statement, 3)), counts: counts,
                skills: decodeStringArray(text(statement, 10)), skillCounts: decodeStringIntMap(text(statement, 11)),
                mcpCounts: decodeStringIntMap(text(statement, 12)), linesAdded: sqlite3_column_int64(statement, 13),
                linesDeleted: sqlite3_column_int64(statement, 14), codeMetricVersion: Int(sqlite3_column_int64(statement, 15))
            ))
        }
        return result
    }

    private func readSessionsUnlocked(hostname: String) throws -> [UsageSession] {
        let sql = """
            SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,project,skills_json
            FROM usage_sessions WHERE hostname=? ORDER BY source,session_hash;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsageSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(UsageSession(
                hostname: hostname, source: text(statement, 0), sessionHash: text(statement, 1),
                project: text(statement, 9), skills: decodeStringArray(text(statement, 10)),
                firstActivity: date(sqlite3_column_int64(statement, 2)), lastActivity: date(sqlite3_column_int64(statement, 3)),
                activeSeconds: sqlite3_column_int64(statement, 4), messageCount: sqlite3_column_int64(statement, 5),
                userMessageCount: sqlite3_column_int64(statement, 6), assistantEvents: sqlite3_column_int64(statement, 7),
                hourHistogramUTC: decodeHistogram(text(statement, 8))
            ))
        }
        return result
    }

    /// 只物化重复 logical id 的赢家；唯一事件不进入字典。随后沿现有 session 时间索引
    /// 顺序扫描，Swift 端始终只保留当前 session 的累计状态。
    private func aggregateSessionsStreamingUnlocked(
        hostname: String,
        sessionProject: [String: (project: String, timestampMs: Int64)],
        sessionSkillCounts: [String: [String: Int]],
        scopedToTempSessions: Bool = false
    ) throws -> [UsageSession] {
        let duplicateWinners = try duplicateSessionEventWinnersUnlocked(hostname: hostname)
        // scoped 模式只聚合 temp_scope_sessions 里的 session。单个 session 的聚合只依赖它
        // 自己的活动行，所以按 session 切分是无损的。scoped 分支不强制 INDEXED BY：加了
        // EXISTS 子查询后让查询规划器自己选，避免与强制索引冲突。
        let sessionScanSQL = scopedToTempSessions ? """
            SELECT event_id,source,session_hash,role,timestamp_ms,source_file_hash
            FROM usage_session_events
            WHERE hostname=?
              AND EXISTS (SELECT 1 FROM temp_scope_sessions t
                          WHERE t.source = usage_session_events.source
                            AND t.session_hash = usage_session_events.session_hash)
            ORDER BY source,session_hash,timestamp_ms,
                     CASE role WHEN 'user' THEN 0 WHEN 'synthetic_user' THEN 1 ELSE 2 END,
                     event_id,source_file_hash;
            """ : """
            SELECT event_id,source,session_hash,role,timestamp_ms,source_file_hash
            FROM usage_session_events INDEXED BY idx_session_events_host_group
            WHERE hostname=?
            ORDER BY source,session_hash,timestamp_ms,
                     CASE role WHEN 'user' THEN 0 WHEN 'synthetic_user' THEN 1 ELSE 2 END,
                     event_id,source_file_hash;
            """
        let statement = try prepare(sessionScanSQL)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname)

        var sessions: [UsageSession] = []
        var currentSource = ""
        var currentSessionHash = ""
        var firstActivityMs: Int64 = 0
        var lastActivityMs: Int64 = 0
        var activeSeconds: Double = 0
        var messageCount: Int64 = 0
        var userMessageCount: Int64 = 0
        var assistantEvents: Int64 = 0
        var histogram = [Int64](repeating: 0, count: 24)
        var anchoredByUser = false
        var segmentStartMs: Int64?
        var segmentEndMs: Int64?
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        func closeSegment() {
            if let start = segmentStartMs, let end = segmentEndMs, end > start {
                activeSeconds += Double(end - start) / 1_000
            }
            segmentStartMs = nil
            segmentEndMs = nil
        }

        func appendCurrentSession() {
            guard !currentSource.isEmpty else { return }
            closeSegment()
            let key = "\(currentSource)\u{1}\(currentSessionHash)"
            sessions.append(UsageSession(
                hostname: hostname,
                source: currentSource,
                sessionHash: currentSessionHash,
                project: sessionProject[key]?.project ?? "",
                skills: UsageToolMetrics.skillNames(sessionSkillCounts[key] ?? [:]),
                firstActivity: date(firstActivityMs),
                lastActivity: date(lastActivityMs),
                activeSeconds: Int64(activeSeconds.rounded()),
                messageCount: messageCount,
                userMessageCount: userMessageCount,
                assistantEvents: assistantEvents,
                hourHistogramUTC: histogram
            ))
        }

        func reset(source: String, sessionHash: String, timestampMs: Int64) {
            currentSource = source
            currentSessionHash = sessionHash
            firstActivityMs = timestampMs
            lastActivityMs = timestampMs
            activeSeconds = 0
            messageCount = 0
            userMessageCount = 0
            assistantEvents = 0
            histogram = [Int64](repeating: 0, count: 24)
            anchoredByUser = false
            segmentStartMs = nil
            segmentEndMs = nil
        }

        while sqlite3_step(statement) == SQLITE_ROW {
            let eventID = text(statement, 0)
            let source = text(statement, 1)
            let sessionHash = text(statement, 2)
            let logicalKey = "\(source)\u{1}\(eventID)"
            if let winner = duplicateWinners[logicalKey], winner != text(statement, 5) { continue }
            guard let role = UsageSessionEvent.Role(rawValue: text(statement, 3)) else { continue }
            let timestampMs = sqlite3_column_int64(statement, 4)

            if source != currentSource || sessionHash != currentSessionHash {
                appendCurrentSession()
                reset(source: source, sessionHash: sessionHash, timestampMs: timestampMs)
            }
            messageCount += 1
            lastActivityMs = max(lastActivityMs, timestampMs)
            switch role {
            case .user:
                userMessageCount += 1
                let hour = utcCalendar.component(.hour, from: date(timestampMs))
                if (0..<24).contains(hour) { histogram[hour] += 1 }
                closeSegment()
                anchoredByUser = true
            case .syntheticUser:
                closeSegment()
                anchoredByUser = true
            case .assistant:
                assistantEvents += 1
                if anchoredByUser {
                    if segmentStartMs == nil { segmentStartMs = timestampMs }
                    segmentEndMs = timestampMs
                }
            }
        }
        appendCurrentSession()
        return sessions
    }

    private func duplicateSessionEventWinnersUnlocked(hostname: String) throws -> [String: String] {
        let duplicateStatement = try prepare("""
            SELECT source,event_id
            FROM usage_session_events INDEXED BY idx_session_events_host
            WHERE hostname=?
            GROUP BY source,event_id
            HAVING COUNT(*)>1;
            """)
        defer { sqlite3_finalize(duplicateStatement) }
        try bind(duplicateStatement, 1, hostname)

        let candidateStatement = try prepare("""
            SELECT source_file_hash
            FROM usage_session_events
            WHERE hostname=? AND source=? AND event_id=?
            ORDER BY source_file_hash;
            """)
        defer { sqlite3_finalize(candidateStatement) }
        let activeFiles = try ownedActiveFileIDsUnlocked()
        var winners: [String: String] = [:]

        while sqlite3_step(duplicateStatement) == SQLITE_ROW {
            let source = text(duplicateStatement, 0)
            let eventID = text(duplicateStatement, 1)
            sqlite3_reset(candidateStatement)
            sqlite3_clear_bindings(candidateStatement)
            try bind(candidateStatement, 1, hostname)
            try bind(candidateStatement, 2, source)
            try bind(candidateStatement, 3, eventID)

            var winner = ""
            var winnerTier = AttributionTier.legacy
            var hasWinner = false
            while sqlite3_step(candidateStatement) == SQLITE_ROW {
                let fileID = text(candidateStatement, 0)
                let tier = attributionTier(sourceFileHash: fileID, activeFiles: activeFiles)
                if !hasWinner || tier.rawValue > winnerTier.rawValue {
                    winner = fileID
                    winnerTier = tier
                    hasWinner = true
                }
            }
            if hasWinner { winners["\(source)\u{1}\(eventID)"] = winner }
        }
        return winners
    }

    private func readAllRawEvents(hostname: String, overwriteConflicts: inout [String]) throws -> [RawEvent] {
        // 读取目标设备的全部（跨文件）原始 token 行，稳定排序。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let sql = "SELECT event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,skill_counts_json,mcp_counts_json,merge_strategy,source_file_hash,hostname FROM usage_events WHERE hostname=? ORDER BY timestamp_ms,event_id,source_file_hash;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [TieredRawEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 5), output: sqlite3_column_int64(statement, 6), cachedInput: sqlite3_column_int64(statement, 7), cacheCreationInput: sqlite3_column_int64(statement, 8), reasoningOutput: sqlite3_column_int64(statement, 9), reportedTotal: sqlite3_column_int64(statement, 10))
            let sourceFileHash = text(statement, 19)
            result.append(TieredRawEvent(
                event: RawEvent(
                    id: text(statement, 0), source: text(statement, 1), model: text(statement, 2), project: text(statement, 3),
                    timestampMs: sqlite3_column_int64(statement, 4), counts: counts, sessionHash: text(statement, 11),
                    inherited: sqlite3_column_int64(statement, 12) != 0, hasTotalSnapshot: sqlite3_column_int64(statement, 13) != 0,
                    lineageFingerprint: text(statement, 14),
                    codexDedupKey: text(statement, 15),
                    skillCounts: decodeStringIntMap(text(statement, 16)),
                    mcpCounts: decodeStringIntMap(text(statement, 17)),
                    mergeStrategy: text(statement, 18),
                    hostname: text(statement, 20)
                ),
                tier: attributionTier(sourceFileHash: sourceFileHash, activeFiles: activeFiles)
            ))
        }
        return dedupRawEventsByLogicalID(result, overwriteConflicts: &overwriteConflicts)
    }

    /// 聚合前按 logical id（source + event_id）合并跨文件重复的 token 行，使「跨文件相同 event 只算一次」。
    ///
    /// v8 归属优先级（先按 tier 取胜，彻底忽略更低 tier 的旧行，避免 legacy 空归属与 owned 副本双算）：
    ///   ownedActive（source_file_hash 非空且其文件当前在册且非 missing）
    ///   > ownedHistory（source_file_hash 非空但文件 missing / 无 checkpoint）
    ///   > legacy（source_file_hash 为空的历史 append/upsert 行）。
    /// 有更高 tier 时，同 logical id 的低 tier 行被完全丢弃（不并入计数）；仅当无任何 owned 行时保留 legacy。
    /// 相同 tier 内跨文件仍按既有稳定规则合并：
    /// - cumulativeMax：逐维取 max（含 total）；skill/mcp 取 max；model=unknown 时保留已知 model。
    /// - overwrite：确定性选择一行（按 source_file_hash 已在 SQL 端稳定排序，取首个出现者），
    ///   但 skill/mcp 仍取 max，避免不同文件观测到的工具计数彼此抹除。
    /// inherited/hasTotalSnapshot/lineageFingerprint 取「更能证明」的值（hasTotalSnapshot 优先真），
    /// 以免跨文件合并把可证明去重的血缘信息丢失。
    private func dedupRawEventsByLogicalID(_ tiered: [TieredRawEvent], overwriteConflicts: inout [String]) -> [RawEvent] {
        var order: [String] = []
        var byKey: [String: (event: RawEvent, tier: AttributionTier)] = [:]
        for entry in tiered {
            let event = entry.event
            let key = "\(event.source)\u{1}\(event.id)"
            guard let existing = byKey[key] else {
                byKey[key] = (event, entry.tier); order.append(key); continue
            }
            // 跨 tier：更高优先级完全取代低优先级旧行（不合并计数，杜绝 legacy/owned 双算）。
            if entry.tier.rawValue > existing.tier.rawValue {
                byKey[key] = (event, entry.tier); continue
            }
            if entry.tier.rawValue < existing.tier.rawValue { continue }
            // 同 tier overwrite 重复：若不可变维度或计数冲突，fail-closed（记录冲突，阻断 reporting），
            // 但仍确定性保留稳定排序首行，绝不制造把 A 计数拼 B 维度的「混合事件」。
            if existing.event.mergeStrategy != "cumulativeMax" && event.mergeStrategy != "cumulativeMax" {
                if let conflict = overwriteConflictReason(existing: existing.event, incoming: event) {
                    overwriteConflicts.append(conflict)
                }
            }
            // 同 tier：沿用既有稳定合并规则。
            let merged = mergeSameTierRawEvents(existing: existing.event, incoming: event)
            byKey[key] = (merged, existing.tier)
        }
        return order.compactMap { byKey[$0]?.event }
    }

    /// overwrite 同 tier 重复行的确定性冲突检测：event_id 稳定且应携带一致的独立计数与不可变维度，
    /// 若不一致说明两份文件对同一 logical event 观测矛盾，需 fail-closed 而非静默取其一。
    ///
    /// timestamp 不参与冲突判定：它只是展示字段、不入计费口径，且 claude-code 同一 message.id
    /// 跨文件（主转录 / subagent / resume 续写）折叠时按各文件行集合取 min，min 结果天然可能不同，
    /// 把它当不可变维度会对无计费影响的差异 fail-closed。合并时统一保留确定性首行的 timestamp。
    private func overwriteConflictReason(existing: RawEvent, incoming event: RawEvent) -> String? {
        var mismatched: [String] = []
        // counts-only 差异不再 fail-closed：同一 logical event id 在自然键已锁定
        //（source/model/project/session + 派生层 hostname/bucket）下的计数矛盾，
        // 本质是同一次生成的截断中途快照 vs 完成态。与服务端 incremental GREATEST
        // upsert 一致地逐列取 max（见 mergeSameTierRawEvents），不再阻断上报。
        // 仅 session/model/project 这类身份维度不一致才视为真冲突、保持 fail-closed。
        if existing.sessionHash != event.sessionHash { mismatched.append("session") }
        // model=unknown 允许被已知 model 补齐，不算冲突；两个都非空且不同才算。
        if existing.model != event.model, existing.model != "unknown", event.model != "unknown" {
            mismatched.append("model")
        }
        if existing.project != event.project, existing.project != "unknown", event.project != "unknown" {
            mismatched.append("project")
        }
        guard !mismatched.isEmpty else { return nil }
        return "overwrite duplicate event \(existing.source)/\(existing.id) has conflicting identity \(mismatched.joined(separator: ",")) across files; kept deterministic first row and blocked reporting"
    }

    /// 同 tier 内跨文件相同 logical id 的稳定合并（既有语义，不改）。
    private func mergeSameTierRawEvents(existing: RawEvent, incoming event: RawEvent) -> RawEvent {
            let cumulative = existing.mergeStrategy == "cumulativeMax" || event.mergeStrategy == "cumulativeMax"
            let mergedCounts: UsageTokenCounts
            if cumulative {
                mergedCounts = UsageTokenCounts(
                    input: max(existing.counts.input, event.counts.input),
                    output: max(existing.counts.output, event.counts.output),
                    cachedInput: max(existing.counts.cachedInput, event.counts.cachedInput),
                    cacheCreationInput: max(existing.counts.cacheCreationInput, event.counts.cacheCreationInput),
                    reasoningOutput: max(existing.counts.reasoningOutput, event.counts.reasoningOutput),
                    reportedTotal: max(existing.counts.reportedTotal, event.counts.reportedTotal)
                )
            } else {
                // overwrite 同 tier 计数差异 = 同一 event 的截断中途快照 vs 完成态；
                // 逐列取 max，与服务端 incremental GREATEST upsert 收敛到同一累计值，
                // 重复上报（客户端 max vs 服务端 GREATEST）天然幂等自愈。
                mergedCounts = UsageTokenCounts(
                    input: max(existing.counts.input, event.counts.input),
                    output: max(existing.counts.output, event.counts.output),
                    cachedInput: max(existing.counts.cachedInput, event.counts.cachedInput),
                    cacheCreationInput: max(existing.counts.cacheCreationInput, event.counts.cacheCreationInput),
                    reasoningOutput: max(existing.counts.reasoningOutput, event.counts.reasoningOutput),
                    reportedTotal: max(existing.counts.reportedTotal, event.counts.reportedTotal)
                )
            }
            let preferKnownModel: String = {
                if existing.model != "unknown" { return existing.model }
                if event.model != "unknown" { return event.model }
                return existing.model
            }()
            return RawEvent(
                id: existing.id, source: existing.source, model: preferKnownModel, project: existing.project,
                timestampMs: existing.timestampMs, counts: mergedCounts, sessionHash: existing.sessionHash,
                inherited: existing.inherited && event.inherited,
                hasTotalSnapshot: existing.hasTotalSnapshot || event.hasTotalSnapshot,
                lineageFingerprint: existing.lineageFingerprint.isEmpty ? event.lineageFingerprint : existing.lineageFingerprint,
                codexDedupKey: existing.codexDedupKey.isEmpty ? event.codexDedupKey : existing.codexDedupKey,
                skillCounts: maximumCounts(existing.skillCounts, event.skillCounts),
                mcpCounts: maximumCounts(existing.mcpCounts, event.mcpCounts),
                mergeStrategy: cumulative ? "cumulativeMax" : existing.mergeStrategy,
                hostname: existing.hostname.isEmpty ? event.hostname : existing.hostname
            )
    }

    private func readAllRawEditEntries(hostname: String) throws -> [RawEditEntry] {
        // 跨文件相同 tool_use_id 只保留确定性一条，避免同一编辑被两份文件重复计入行数指标。
        // v8 归属优先级：ownedActive > ownedHistory > legacy；有更高 tier 时完全忽略低 tier 旧行，
        // 仅当无任何 owned 行时保留 legacy。同 tier 内维持既有「按 timestamp,tool_use_id,source_file_hash
        // 稳定排序取首个」的确定性口径。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let statement = try prepare("SELECT source,model,project,timestamp_ms,lines_added,lines_deleted,tool_use_id,source_file_hash,hostname FROM usage_edit_entries WHERE hostname=? ORDER BY timestamp_ms,tool_use_id,source_file_hash;")
        defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var order: [String] = []
        var byKey: [String: (entry: RawEditEntry, tier: AttributionTier)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let toolUseID = text(statement, 6)
            let tier = attributionTier(sourceFileHash: text(statement, 7), activeFiles: activeFiles)
            let entry = RawEditEntry(
                source: text(statement, 0), model: text(statement, 1), project: text(statement, 2),
                timestampMs: sqlite3_column_int64(statement, 3),
                added: max(0, sqlite3_column_int64(statement, 4)),
                deleted: max(0, sqlite3_column_int64(statement, 5)),
                hostname: text(statement, 8)
            )
            guard let existing = byKey[toolUseID] else {
                byKey[toolUseID] = (entry, tier); order.append(toolUseID); continue
            }
            // 更高 tier 完全取代低 tier；同 tier 保留稳定排序首个；低 tier 忽略。
            if tier.rawValue > existing.tier.rawValue { byKey[toolUseID] = (entry, tier) }
        }
        return order.compactMap { byKey[$0]?.entry }
    }

    private func readEditMetricSourcesUnlocked() throws -> Set<String> {
        let statement = try prepare("SELECT source FROM usage_edit_metric_sources;")
        defer { sqlite3_finalize(statement) }
        var result = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { result.insert(text(statement, 0)) }
        return result
    }

    private func readAllSessionEvents(hostname: String) throws -> [UsageSessionEvent] {
        // 跨文件相同 (source,event_id) 的会话事件只保留一条。
        // v8 归属优先级：ownedActive > ownedHistory > legacy；有更高 tier 时完全忽略低 tier 旧行，
        // 仅当无任何 owned 行时保留 legacy。同 tier 内维持既有「按 source,event_id,source_file_hash
        // 稳定排序取首个」的确定性口径。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let statement = try prepare("SELECT event_id,source,session_hash,role,timestamp_ms,source_file_hash,hostname FROM usage_session_events WHERE hostname=? ORDER BY source,event_id,source_file_hash;")
        defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var order: [String] = []
        var byKey: [String: (event: UsageSessionEvent, tier: AttributionTier)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let role = UsageSessionEvent.Role(rawValue: text(statement, 3)) else { continue }
            let key = "\(text(statement, 1))\u{1}\(text(statement, 0))"
            let tier = attributionTier(sourceFileHash: text(statement, 5), activeFiles: activeFiles)
            let event = UsageSessionEvent(id: text(statement, 0), source: text(statement, 1), sessionHash: text(statement, 2), role: role, timestamp: date(sqlite3_column_int64(statement, 4)), hostname: text(statement, 6))
            guard let existing = byKey[key] else {
                byKey[key] = (event, tier); order.append(key); continue
            }
            if tier.rawValue > existing.tier.rawValue { byKey[key] = (event, tier) }
        }
        return order.compactMap { byKey[$0]?.event }
    }



    // MARK: - skill/mcp 计数的四级去重（全量与增量共用）

    /// 第 1 级：logical ID 去重。同 (source, event_id) 取最高 tier，同 tier 内计数按 key 取 max。
    ///
    /// session skills 只用到这一级 —— 继承回放携带的 skill 属于子 session，
    /// 不能通过 lineage 并入原 session，所以不能用后面几级的结果。
    /// 与 logicalEventsSQL 的 COALESCE(MAX(CASE WHEN x <> 'unknown' THEN x END), MAX(x)) 同语义：
    /// 优先取非 unknown 中的最大值，全是 unknown 时取最大值。
    private static func coalescedDedupField(_ lhs: String, _ rhs: String) -> String {
        let unknown = "unknown"
        switch (lhs == unknown, rhs == unknown) {
        case (false, false): return max(lhs, rhs)
        case (false, true): return lhs
        case (true, false): return rhs
        case (true, true): return lhs
        }
    }
    private func logicalDedupedSkillEvents(_ events: [SkillMergeEvent]) -> [SkillMergeEvent] {
            // 1) logical ID 去重：同 (source, event_id) 取最高 tier，计数按 key 取 max。
            var logicalByKey: [String: SkillMergeEvent] = [:]
            for ev in events {
                let key = "\(ev.source)\u{1}\(ev.eventID)"
                if let existing = logicalByKey[key] {
                    if ev.tier > existing.tier {
                        logicalByKey[key] = ev
                    } else if ev.tier == existing.tier {
                        // 同 tier 合并必须与 logicalEventsSQL 逐列对齐，不能取「遍历到的第一行」。
                        // 两条喂数据的 SQL 都没有 ORDER BY，全量读全表、增量读子集，返回顺序不同；
                        // 若取首行字段，胜者的 model / project / timestamp 会随顺序漂移，算出不同的
                        // bucket 自然键。全量路径下算错的键被 bucket 查找静默丢弃，所以一直没暴露。
                        // 对齐口径：model / project 用 COALESCE(MAX(非 unknown), MAX(全部))，
                        // timestamp / inherited 取 MIN。
                        let mergedModel = Self.coalescedDedupField(existing.model, ev.model)
                        let mergedProject = Self.coalescedDedupField(existing.project, ev.project)
                        logicalByKey[key] = SkillMergeEvent(
                            source: existing.source, eventID: existing.eventID,
                            model: mergedModel, project: mergedProject,
                            sessionHash: max(existing.sessionHash, ev.sessionHash),
                            timestampMs: min(existing.timestampMs, ev.timestampMs),
                            inherited: existing.inherited && ev.inherited,
                            billableTotal: max(existing.billableTotal, ev.billableTotal),
                            lineageFingerprint: max(existing.lineageFingerprint, ev.lineageFingerprint),
                            codexDedupKey: max(existing.codexDedupKey, ev.codexDedupKey),
                            skillCounts: maximumCounts(existing.skillCounts, ev.skillCounts),
                            mcpCounts: maximumCounts(existing.mcpCounts, ev.mcpCounts),
                            tier: existing.tier
                        )
                    }
                } else {
                    logicalByKey[key] = ev
                }
            }
            let logicalDeduped = Array(logicalByKey.values)
        return logicalDeduped
    }

    /// 三级去重后按 bucket 自然键合并 skill/mcp 计数。
    ///
    /// 分工：胜者选择全部交给 SQL（temp_skill_attribution），Swift 只做 SQL 做不到的两件事——
    /// logical 组内按 key 取 max，以及同一胜者下多个 logical 组按 key 取 max。
    /// 落到同一 bucket 的不同胜者之间是求和，与 token 侧的 GROUP BY 语义一致。
    ///
    /// 前置条件：temp_logical_events / temp_lineage_events / temp_deduped_events 均已物化。
    private func mergeSkillCountsByBucketUnlocked(
        _ events: [SkillMergeEvent],
        bucketMs: Int64
    ) throws -> [(key: String, skillCounts: [String: Int], mcpCounts: [String: Int])] {
        let logicalDeduped = logicalDedupedSkillEvents(events)
        guard !logicalDeduped.isEmpty else { return [] }

        let attribution = try readSkillAttributionUnlocked(bucketMs: bucketMs)

        // 每个胜者先把归属到它的 logical 组按 key 取 max —— 这一步复现 lineage / content
        // 两级「计数按 key 取 max」的语义，但不再由 Swift 决定谁是胜者。
        var byWinner: [String: (bucketKey: String, skillCounts: [String: Int], mcpCounts: [String: Int])] = [:]
        for ev in logicalDeduped {
            guard let target = attribution[compositeKey(ev.source, ev.eventID)] else { continue }
            if let existing = byWinner[target.winnerKey] {
                byWinner[target.winnerKey] = (
                    target.bucketKey,
                    maximumCounts(existing.skillCounts, ev.skillCounts),
                    maximumCounts(existing.mcpCounts, ev.mcpCounts)
                )
            } else {
                byWinner[target.winnerKey] = (target.bucketKey, ev.skillCounts, ev.mcpCounts)
            }
        }

        // 再按 bucket 求和。遍历顺序不影响结果：mergeCounts 逐 key 相加，可交换可结合。
        var merged: [String: (skillCounts: [String: Int], mcpCounts: [String: Int])] = [:]
        for (_, entry) in byWinner {
            if let existing = merged[entry.bucketKey] {
                merged[entry.bucketKey] = (
                    UsageToolMetrics.mergeCounts(existing.skillCounts, entry.skillCounts),
                    UsageToolMetrics.mergeCounts(existing.mcpCounts, entry.mcpCounts)
                )
            } else {
                merged[entry.bucketKey] = (entry.skillCounts, entry.mcpCounts)
            }
        }
        // 键升序返回，保证调用方看到的顺序稳定。
        return merged.keys.sorted().compactMap { key in
            merged[key].map { (key: key, skillCounts: $0.skillCounts, mcpCounts: $0.mcpCounts) }
        }
    }

    /// 物化并读取「logical 行 -> 最终胜者 + 胜者 bucket 自然键」的归属映射。
    private func readSkillAttributionUnlocked(
        bucketMs: Int64
    ) throws -> [String: (winnerKey: String, bucketKey: String)] {
        try exec("DROP TABLE IF EXISTS temp_skill_attribution;")
        defer { try? exec("DROP TABLE IF EXISTS temp_skill_attribution;") }
        try exec(Self.skillAttributionSQL(bucketMs: bucketMs))

        let statement = try prepare("""
            SELECT source, event_id, winner_source, winner_event_id,
                   winner_model, winner_project, winner_bucket_start
            FROM temp_skill_attribution;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [String: (winnerKey: String, bucketKey: String)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let memberKey = compositeKey(text(statement, 0), text(statement, 1))
            let winnerKey = compositeKey(text(statement, 2), text(statement, 3))
            let bucketKey = compositeKey(
                text(statement, 2), text(statement, 4), text(statement, 5),
                String(sqlite3_column_int64(statement, 6))
            )
            result[memberKey] = (winnerKey, bucketKey)
        }
        return result
    }
    // MARK: - Derived row helpers (unlocked; inside transaction)

    private struct BucketRow: Equatable { let bucket: UsageBucket; let revision: Int64; let synced: Int64 }

    private func readBucketRowsUnlocked(hostname: String) throws -> [String: BucketRow] {
        let sql = "SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,skills_json,skill_counts_json,mcp_counts_json,lines_added,lines_deleted,code_metric_version,revision,synced_revision FROM usage_buckets WHERE hostname=?;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [String: BucketRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let start = sqlite3_column_int64(statement, 3)
            let key = "\(text(statement,0))\u{1}\(text(statement,1))\u{1}\(text(statement,2))\u{1}\(start)"
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5), cachedInput: sqlite3_column_int64(statement, 6), cacheCreationInput: sqlite3_column_int64(statement, 7), reasoningOutput: sqlite3_column_int64(statement, 8), reportedTotal: sqlite3_column_int64(statement, 9))
            let bucket = UsageBucket(
                hostname: hostname, source: text(statement, 0), model: text(statement, 1), project: text(statement, 2),
                bucketStart: date(start), counts: counts, skills: decodeStringArray(text(statement, 10)),
                skillCounts: decodeStringIntMap(text(statement, 11)), mcpCounts: decodeStringIntMap(text(statement, 12)),
                linesAdded: sqlite3_column_int64(statement, 13), linesDeleted: sqlite3_column_int64(statement, 14),
                codeMetricVersion: Int(sqlite3_column_int64(statement, 15))
            )
            result[key] = BucketRow(bucket: bucket, revision: sqlite3_column_int64(statement, 16), synced: sqlite3_column_int64(statement, 17))
        }
        return result
    }

    private func upsertBucketUnlocked(_ bucket: UsageBucket, revision: Int64) throws {
        let c = bucket.counts
        let sql = """
            INSERT INTO usage_buckets(hostname,source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,skills_json,skill_counts_json,mcp_counts_json,lines_added,lines_deleted,lines_net,code_metric_version,revision,synced_revision,updated_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)
            ON CONFLICT(hostname,source,model,project,bucket_start_ms) DO UPDATE SET
              input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens,cached_input_tokens=excluded.cached_input_tokens,
              cache_creation_input_tokens=excluded.cache_creation_input_tokens,reasoning_output_tokens=excluded.reasoning_output_tokens,
              total_tokens=excluded.total_tokens,skills_json=excluded.skills_json,skill_counts_json=excluded.skill_counts_json,
              mcp_counts_json=excluded.mcp_counts_json,lines_added=excluded.lines_added,lines_deleted=excluded.lines_deleted,
              lines_net=excluded.lines_net,code_metric_version=excluded.code_metric_version,
              revision=excluded.revision,updated_at_ms=excluded.updated_at_ms;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, bucket.hostname); try bind(statement, 2, bucket.source); try bind(statement, 3, bucket.model); try bind(statement, 4, bucket.project); try bind(statement, 5, millis(bucket.bucketStart))
        try bind(statement, 6, c.input); try bind(statement, 7, c.output); try bind(statement, 8, c.cachedInput); try bind(statement, 9, c.cacheCreationInput); try bind(statement, 10, c.reasoningOutput); try bind(statement, 11, c.total)
        try bind(statement, 12, encodeStringArray(bucket.skills)); try bind(statement, 13, encodeStringIntMap(bucket.skillCounts)); try bind(statement, 14, encodeStringIntMap(bucket.mcpCounts))
        try bind(statement, 15, bucket.linesAdded); try bind(statement, 16, bucket.linesDeleted); try bind(statement, 17, bucket.linesNet)
        try bind(statement, 18, Int64(bucket.codeMetricVersion)); try bind(statement, 19, revision); try bind(statement, 20, millis(Date()))
        try done(statement)
    }

    private func deleteBucketUnlocked(hostname: String, key: String) throws {
        let parts = key.components(separatedBy: "\u{1}")
        guard parts.count == 4, let start = Int64(parts[3]) else { return }
        let statement = try prepare("DELETE FROM usage_buckets WHERE hostname=? AND source=? AND model=? AND project=? AND bucket_start_ms=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try bind(statement, 2, parts[0]); try bind(statement, 3, parts[1]); try bind(statement, 4, parts[2]); try bind(statement, 5, start)
        try done(statement)
    }

    private struct SessionRow {
        let session: UsageSession
        let revision: Int64
        let synced: Int64
    }

    private func readSessionRowsUnlocked(hostname: String) throws -> [String: SessionRow] {
        let sql = """
            SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,revision,synced_revision,project,skills_json
            FROM usage_sessions WHERE hostname=?;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var map: [String: SessionRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let session = UsageSession(
                hostname: hostname, source: text(statement, 0), sessionHash: text(statement, 1),
                project: text(statement, 11), skills: decodeStringArray(text(statement, 12)),
                firstActivity: date(sqlite3_column_int64(statement, 2)), lastActivity: date(sqlite3_column_int64(statement, 3)),
                activeSeconds: sqlite3_column_int64(statement, 4), messageCount: sqlite3_column_int64(statement, 5),
                userMessageCount: sqlite3_column_int64(statement, 6), assistantEvents: sqlite3_column_int64(statement, 7),
                hourHistogramUTC: decodeHistogram(text(statement, 8))
            )
            map["\(session.source)\u{1}\(session.sessionHash)"] = SessionRow(
                session: session,
                revision: sqlite3_column_int64(statement, 9),
                synced: sqlite3_column_int64(statement, 10)
            )
        }
        return map
    }

    private func upsertSessionUnlocked(_ session: UsageSession, revision: Int64) throws {
        let sql = """
            INSERT INTO usage_sessions(hostname,source,session_hash,project,skills_json,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,revision,synced_revision,updated_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0,?)
            ON CONFLICT(hostname,source,session_hash) DO UPDATE SET
              project=excluded.project,skills_json=excluded.skills_json,first_activity_ms=excluded.first_activity_ms,last_activity_ms=excluded.last_activity_ms,active_seconds=excluded.active_seconds,
              message_count=excluded.message_count,user_message_count=excluded.user_message_count,assistant_events=excluded.assistant_events,
              hour_histogram=excluded.hour_histogram,revision=excluded.revision,updated_at_ms=excluded.updated_at_ms;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, session.hostname); try bind(statement, 2, session.source); try bind(statement, 3, session.sessionHash)
        try bind(statement, 4, session.project); try bind(statement, 5, encodeStringArray(session.skills))
        try bind(statement, 6, millis(session.firstActivity)); try bind(statement, 7, millis(session.lastActivity))
        try bind(statement, 8, session.activeSeconds); try bind(statement, 9, session.messageCount); try bind(statement, 10, session.userMessageCount); try bind(statement, 11, session.assistantEvents)
        try bind(statement, 12, encodeHistogram(session.hourHistogramUTC)); try bind(statement, 13, revision); try bind(statement, 14, millis(Date()))
        try done(statement)
    }

    private func deleteSessionUnlocked(hostname: String, key: String) throws {
        let parts = key.components(separatedBy: "\u{1}")
        guard parts.count == 2 else { return }
        let statement = try prepare("DELETE FROM usage_sessions WHERE hostname=? AND source=? AND session_hash=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try bind(statement, 2, parts[0]); try bind(statement, 3, parts[1])
        try done(statement)
    }


    // MARK: - Sync (per-row revision snapshot + exact ack)

    public func pendingBatch(hostname: String) throws -> UsagePendingBatch {
        try pendingBatch(hostname: hostname, maxBuckets: Self.defaultMaxBucketsPerBatch, maxSessions: Self.defaultMaxSessionsPerBatch)
    }

    /// 拉取 dirty（revision > synced_revision）派生行，硬上限 maxBuckets / maxSessions（nil=不限）。
    /// 每行携带其 revision 快照；ack 时按 (自然键, revision 快照) 精确匹配。
    public func pendingBatch(hostname: String, maxBuckets: Int?, maxSessions: Int?) throws -> UsagePendingBatch {
        try queue.sync {
            // 不可用不能伪装成权威空批次；调用方必须先恢复完整扫描/派生。
            if try hasLocalDerivationPendingUnlocked() {
                throw UsageLedgerError.localDerivationPending
            }
            let bucketLimit = maxBuckets.map { max(0, $0) }
            let sessionLimit = maxSessions.map { max(0, $0) }

            var bucketSQL = "SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,skills_json,skill_counts_json,mcp_counts_json,lines_added,lines_deleted,code_metric_version,revision FROM usage_buckets WHERE hostname=? AND bucket_start_ms>=0 AND revision>synced_revision ORDER BY revision,bucket_start_ms,source,model,project"
            if let bucketLimit { bucketSQL += " LIMIT \(bucketLimit + 1)" }
            bucketSQL += ";"
            let bucketStmt = try prepare(bucketSQL); defer { sqlite3_finalize(bucketStmt) }; try bind(bucketStmt, 1, hostname)
            var pendingBuckets: [UsagePendingBucket] = []
            var moreBuckets = false
            while sqlite3_step(bucketStmt) == SQLITE_ROW {
                if let bucketLimit, pendingBuckets.count >= bucketLimit { moreBuckets = true; break }
                let counts = UsageTokenCounts(input: sqlite3_column_int64(bucketStmt, 4), output: sqlite3_column_int64(bucketStmt, 5), cachedInput: sqlite3_column_int64(bucketStmt, 6), cacheCreationInput: sqlite3_column_int64(bucketStmt, 7), reasoningOutput: sqlite3_column_int64(bucketStmt, 8), reportedTotal: sqlite3_column_int64(bucketStmt, 9))
                let bucket = UsageBucket(
                    hostname: hostname, source: text(bucketStmt, 0), model: text(bucketStmt, 1), project: text(bucketStmt, 2),
                    bucketStart: date(sqlite3_column_int64(bucketStmt, 3)), counts: counts,
                    skills: decodeStringArray(text(bucketStmt, 10)), skillCounts: decodeStringIntMap(text(bucketStmt, 11)),
                    mcpCounts: decodeStringIntMap(text(bucketStmt, 12)), linesAdded: sqlite3_column_int64(bucketStmt, 13),
                    linesDeleted: sqlite3_column_int64(bucketStmt, 14), codeMetricVersion: Int(sqlite3_column_int64(bucketStmt, 15))
                )
                pendingBuckets.append(UsagePendingBucket(bucket: bucket, revision: sqlite3_column_int64(bucketStmt, 16)))
            }

            var sessionSQL = "SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,project,skills_json,revision FROM usage_sessions WHERE hostname=? AND revision>synced_revision ORDER BY revision,source,session_hash"
            if let sessionLimit { sessionSQL += " LIMIT \(sessionLimit + 1)" }
            sessionSQL += ";"
            let sessionStmt = try prepare(sessionSQL); defer { sqlite3_finalize(sessionStmt) }; try bind(sessionStmt, 1, hostname)
            var pendingSessions: [UsagePendingSession] = []
            var moreSessions = false
            while sqlite3_step(sessionStmt) == SQLITE_ROW {
                if let sessionLimit, pendingSessions.count >= sessionLimit { moreSessions = true; break }
                let session = UsageSession(
                    hostname: hostname, source: text(sessionStmt, 0), sessionHash: text(sessionStmt, 1),
                    project: text(sessionStmt, 9), skills: decodeStringArray(text(sessionStmt, 10)),
                    firstActivity: date(sqlite3_column_int64(sessionStmt, 2)), lastActivity: date(sqlite3_column_int64(sessionStmt, 3)),
                    activeSeconds: sqlite3_column_int64(sessionStmt, 4), messageCount: sqlite3_column_int64(sessionStmt, 5),
                    userMessageCount: sqlite3_column_int64(sessionStmt, 6), assistantEvents: sqlite3_column_int64(sessionStmt, 7),
                    hourHistogramUTC: decodeHistogram(text(sessionStmt, 8))
                )
                pendingSessions.append(UsagePendingSession(session: session, revision: sqlite3_column_int64(sessionStmt, 11)))
            }

            return UsagePendingBatch(hostname: hostname, buckets: pendingBuckets, sessions: pendingSessions, hasMore: moreBuckets || moreSessions)
        }
    }

    /// 精确 ack：仅把「自然键 + revision 快照」仍匹配的行标记为已同步。
    /// 上传期间被 finalizeDerived 重算（revision 提升）的行不匹配，保持 dirty；失败则不应调用本方法。
    public func acknowledge(_ batch: UsagePendingBatch) throws {
        try queue.sync {
            try transaction {
                let nowMs = millis(Date())
                var acknowledgedRows = 0
                let bucketSQL = "UPDATE usage_buckets SET synced_revision=?, updated_at_ms=? WHERE hostname=? AND source=? AND model=? AND project=? AND bucket_start_ms=? AND revision=? AND revision>synced_revision;"
                let bucketStmt = try prepare(bucketSQL); defer { sqlite3_finalize(bucketStmt) }
                for pending in batch.buckets {
                    let b = pending.bucket
                    guard b.hostname == batch.hostname else { continue }
                    sqlite3_reset(bucketStmt); sqlite3_clear_bindings(bucketStmt)
                    try bind(bucketStmt, 1, pending.revision); try bind(bucketStmt, 2, nowMs); try bind(bucketStmt, 3, b.hostname)
                    try bind(bucketStmt, 4, b.source); try bind(bucketStmt, 5, b.model); try bind(bucketStmt, 6, b.project); try bind(bucketStmt, 7, millis(b.bucketStart)); try bind(bucketStmt, 8, pending.revision)
                    try done(bucketStmt)
                    acknowledgedRows += Int(sqlite3_changes(db))
                }
                let sessionSQL = "UPDATE usage_sessions SET synced_revision=?, updated_at_ms=? WHERE hostname=? AND source=? AND session_hash=? AND revision=? AND revision>synced_revision;"
                let sessionStmt = try prepare(sessionSQL); defer { sqlite3_finalize(sessionStmt) }
                for pending in batch.sessions {
                    let s = pending.session
                    guard s.hostname == batch.hostname else { continue }
                    sqlite3_reset(sessionStmt); sqlite3_clear_bindings(sessionStmt)
                    try bind(sessionStmt, 1, pending.revision); try bind(sessionStmt, 2, nowMs); try bind(sessionStmt, 3, s.hostname)
                    try bind(sessionStmt, 4, s.source); try bind(sessionStmt, 5, s.sessionHash); try bind(sessionStmt, 6, pending.revision)
                    try done(sessionStmt)
                    acknowledgedRows += Int(sqlite3_changes(db))
                }
                guard acknowledgedRows > 0 else { return }
                try setTextUnlocked(key: lastSyncedKey(batch.hostname), value: String(nowMs))
            }
        }
    }

    public func lastSyncedAt(hostname: String) throws -> Date? {
        try queue.sync { try readTextUnlocked(key: lastSyncedKey(hostname)).flatMap { Int64($0) }.map(date) }
    }

    /// dirty 行计数（用于观测 / 判断是否有待上传）。
    public func pendingCounts(hostname: String) throws -> (buckets: Int, sessions: Int) {
        try queue.sync {
            if try hasLocalDerivationPendingUnlocked() { throw UsageLedgerError.localDerivationPending }
            let b = try countUnlocked("SELECT COUNT(*) FROM usage_buckets WHERE hostname=? AND bucket_start_ms>=0 AND revision>synced_revision;", hostname)
            let s = try countUnlocked("SELECT COUNT(*) FROM usage_sessions WHERE hostname=? AND first_activity_ms>=0 AND last_activity_ms>=0 AND revision>synced_revision;", hostname)
            return (b, s)
        }
    }

    private func countUnlocked(_ sql: String, _ hostname: String) throws -> Int {
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }



    // MARK: - Hostname gate + rebuild

    public func hostnameState(current hostname: String) throws -> UsageHostnameState {
        try queue.sync {
            guard let stored = try readTextUnlocked(key: Self.canonicalHostnameKey), !stored.isEmpty else { return .unset }
            return stored == hostname ? .match : .mismatch(stored: stored)
        }
    }

    /// 本机身份从旧 canonical hostname 改名为新值时，把本地历史全部原地统一成新名字。
    ///
    /// 单机口径：不做 DELETE + 全库重算，只在一个事务里把所有旧 hostname 直接 UPDATE 成新
    /// hostname —— 原始层三张表（hostname 为普通列，改名不撞主键）与派生两张表（hostname 属
    /// 主键，改名可能撞已存在的新名行），并更新 sync_state.canonical_hostname。
    ///
    /// 派生行的 revision/synced_revision 原样保留：改名后其自然键中的 hostname 变了，等价于新
    /// hostname 下的新自然键，revision 仍 > synced_revision（原本已 synced 的行也因键变化需在新
    /// 名下重新上报），从而以增量方式重新对齐远端。服务端 upsert-only、无 tombstone，旧名残留
    /// 由服务端自行处理，客户端不代管。
    public func rebuildForHostname(_ hostname: String) throws {
        try queue.sync {
            let old = try readTextUnlocked(key: Self.canonicalHostnameKey) ?? ""
            // 目标名与旧名相同（或旧名为空未设置过）时无需搬迁历史，仅落定 canonical。
            guard old != hostname, !old.isEmpty else {
                try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                return
            }
            try transaction {
                let nowMs = millis(Date())
                // 原始层：hostname 为普通列，直接原地改名，绝不撞主键。
                try renameRawHostnameUnlocked(table: "usage_events", from: old, to: hostname)
                try renameRawHostnameUnlocked(table: "usage_session_events", from: old, to: hostname)
                if try tableExistsUnlocked("usage_edit_entries") {
                    try renameRawHostnameUnlocked(table: "usage_edit_entries", from: old, to: hostname)
                }
                // 派生层：hostname 属主键。单机场景新名下本不该有行；为稳妥先清理新名下的既有行，
                // 再把旧名行整体改到新名。改名后自然键（含 hostname）变了，等价于新名下的新行，
                // 因此把 revision 提升到新名的新高水位、保持 synced_revision 不变，使其 dirty 重新上报。
                let newRevision = try nextRevisionUnlocked(hostname: hostname)
                try renameDerivedHostnameUnlocked(table: "usage_buckets", from: old, to: hostname, revision: newRevision, nowMs: nowMs)
                try renameDerivedHostnameUnlocked(table: "usage_sessions", from: old, to: hostname, revision: newRevision, nowMs: nowMs)
                try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
            }
        }
    }

    /// 原始表 hostname 原地改名：hostname 为普通列，无主键冲突风险。
    private func renameRawHostnameUnlocked(table: String, from old: String, to new: String) throws {
        let statement = try prepare("UPDATE \(table) SET hostname=? WHERE hostname=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, new); try bind(statement, 2, old)
        try done(statement)
    }

    /// 派生表 hostname 原地改名：hostname 属主键，先删新名残留行再整体改名。改名后自然键（含 hostname）
    /// 变化，等价于新名下从未同步过的新行，故把 revision 提升到新名新高水位、synced_revision 归零，
    /// 保证 revision>synced_revision 而 dirty，须在新名下重新上报（避免旧名下的已 ack 高水位误判为已同步）。
    private func renameDerivedHostnameUnlocked(table: String, from old: String, to new: String, revision: Int64, nowMs: Int64) throws {
        let purge = try prepare("DELETE FROM \(table) WHERE hostname=?;")
        do { defer { sqlite3_finalize(purge) }; try bind(purge, 1, new); try done(purge) }
        let update = try prepare("UPDATE \(table) SET hostname=?, revision=?, synced_revision=0, updated_at_ms=? WHERE hostname=?;")
        defer { sqlite3_finalize(update) }
        try bind(update, 1, new); try bind(update, 2, revision); try bind(update, 3, nowMs); try bind(update, 4, old)
        try done(update)
    }

    /// 采纳新的本机身份，但**不改动**任何历史行：仅把 canonical_hostname 更新为新名。
    ///
    /// 对应用户在改名确认弹窗中选择「否」——新名从此生效并承接后续新数据，历史保留旧名。
    /// 结果是同一台机器上「旧名历史 + 新名新数据」共存（预期行为，非 bug），各自按其
    /// hostname 上报。更新后 hostnameState(current: 新名) 即为 .match，不会再触发弹窗循环。
    public func adoptHostname(_ hostname: String) throws {
        try queue.sync {
            try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
        }
    }

    // MARK: - Explicit rebuild reset

    /// 是否存在一次已 reset、但尚未由协调层确认全部来源重扫成功的 rebuild。
    ///
    /// 标记只能由 markRebuildCompleted() 显式清除；record/finalize 不会推断重扫已完成。
    public func requiresRebuildCompletion() throws -> Bool {
        try queue.sync {
            try readTextUnlocked(key: Self.rebuildPendingKey) != nil
        }
    }

    /// 开始一次不清库的 parser rebuild。现存文件由协调层逐文件原子 replace；
    /// 已从磁盘消失的 checkpoint/raw 永久保留，直到整轮扫描和 finalize 成功。
    public func beginParserRebuild(targetParserVersion: Int) throws {
        guard targetParserVersion > 0 else { throw UsageLedgerError.invalidCheckpoint }
        try queue.sync {
            try transaction {
                try setTextUnlocked(key: Self.rebuildPendingKey, value: "1")
                try setIntUnlocked(key: Self.rebuildTargetParserVersionKey, value: Int64(targetParserVersion))
            }
        }
    }

    /// 协调层确认所有来源的全量扫描均成功后，显式完成当前 rebuild。
    /// 空扫描、部分扫描或任一来源失败时不得调用。
    public func markRebuildCompleted() throws {
        try queue.sync {
            try transaction {
                if let target = try readIntUnlocked(key: Self.rebuildTargetParserVersionKey) {
                    let completed = try readIntUnlocked(key: Self.rebuildCompletedParserVersionKey) ?? 0
                    if target > completed {
                        try setIntUnlocked(key: Self.rebuildCompletedParserVersionKey, value: target)
                    }
                }
                try deleteKeyUnlocked(Self.rebuildPendingKey)
                try deleteKeyUnlocked(Self.rebuildTargetParserVersionKey)
            }
        }
    }

    /// 是否存在「文件已 replace 但派生尚未成功重算」的挂起状态（raw 派生 dirty）。
    /// 由每次 record 置位、finalizeDerived 成功后清除。协调层可据此在 finalize 之前一律不上报。
    public func requiresDerivationCompletion() throws -> Bool {
        try queue.sync {
            try readTextUnlocked(key: Self.rawDerivationPendingKey) != nil
        }
    }

    /// 准备后台扫描所需的大表性能索引。调用方应在后台队列执行，避免阻塞 App 初始化。
    public func prepareForUsageScan() throws {
        try queue.sync { try ensurePerformanceIndexesUnlocked() }
    }

    /// 标记一批磁盘上已消失的文件为 checkpoint missing，但绝不删除其原始行或派生历史。
    /// 删除源文件不应由 record 自动删历史；本 API 仅把这些 fileID 的 scan_status 置 "missing"，
    /// 保留 raw 以维持历史与去重口径。未登记的 fileID 忽略。
    public func markFilesMissing(fileIDs: [String], hostname: String) throws {
        guard !fileIDs.isEmpty else { return }
        try queue.sync {
            try ensurePerformanceIndexesUnlocked()
            try transaction {
                // 只更新真正还不是 missing 的行：未登记的 fileID 与已经 missing 的行都不存在 tier 变化，
                // 若也置脏位就会让下一轮扫描白跑一次全库重算。
                let statement = try prepare("UPDATE usage_files SET scan_status=?, updated_at_ms=? WHERE file_id=? AND scan_status<>'missing';")
                defer { sqlite3_finalize(statement) }
                let nowMs = millis(Date())
                var transitioned: [String] = []
                for fileID in fileIDs {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try bind(statement, 1, "missing"); try bind(statement, 2, nowMs); try bind(statement, 3, fileID)
                    try done(statement)
                    if sqlite3_changes(db) > 0 { transitioned.append(fileID) }
                }
                // scan_status 参与派生：tier 由文件是否 active 决定，转 missing 会把其事件
                // 从 ownedActive 降为 ownedHistory，可能改变 logical dedup 选中的行。
                // 不置脏位则派生表会一直沿用旧 tier 的结果。
                guard !transitioned.isEmpty else { return }
                // raw 行仍在（本方法只改 checkpoint 状态），所以此刻还能批量读出它们的去重键。
                try recordMissingFileDirtyKeysUnlocked(fileIDs: transitioned, hostname: hostname)
                try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
            }
        }
    }

    /// 以 source 为原子作用域，把本轮未出现的 checkpoint 标为 missing；只改 checkpoint，
    /// 不删除任何 raw。调用方必须先合并同 source 的全部 root（例如 Codex sessions + archive）。
    public func markFilesMissing(source: String, presentFileIDs: [String], hostname: String) throws {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else { throw UsageLedgerError.invalidCheckpoint }
        let present = Set(presentFileIDs)
        try queue.sync {
            try ensurePerformanceIndexesUnlocked()
            try transaction {
                let read = try prepare("SELECT file_id FROM usage_files WHERE source=? AND scan_status<>'missing';")
                defer { sqlite3_finalize(read) }
                try bind(read, 1, normalizedSource)
                var missing: [String] = []
                var result = sqlite3_step(read)
                while result == SQLITE_ROW {
                    let fileID = text(read, 0)
                    if !present.contains(fileID) { missing.append(fileID) }
                    result = sqlite3_step(read)
                }
                guard result == SQLITE_DONE else { throw error() }
                guard !missing.isEmpty else { return }
                let update = try prepare("UPDATE usage_files SET scan_status='missing',updated_at_ms=? WHERE source=? AND file_id=?;")
                defer { sqlite3_finalize(update) }
                let nowMs = millis(Date())
                for fileID in missing {
                    sqlite3_reset(update); sqlite3_clear_bindings(update)
                    try bind(update, 1, nowMs); try bind(update, 2, normalizedSource); try bind(update, 3, fileID)
                    try done(update)
                }
                // raw 行仍在（本方法只改 checkpoint 状态），此刻还能批量读出这些文件的去重键，
                // 供增量 finalize 还原受 tier 变化影响的 bucket/session。
                try recordMissingFileDirtyKeysUnlocked(fileIDs: missing, hostname: hostname)
                // 只有真的有文件转 missing 时才置脏位（上面已 guard 空集提前返回），
                // 否则每轮扫描都会退化成全库重算。
                try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
            }
        }
    }

    /// 显式 rebuild：事务性清空派生 + 原始 + checkpoint（仅显式 rebuild 时调用）。
    /// 随后由协调层清空重扫全部源文件重建，用于修正历史错误时间数据（parserVersion 提升）。
    /// 注意：v8 起自动 parser 升级路径不再依赖本方法；它仍作为显式全量 rebuild 的兜底可用（协调层仍会调用）。
    /// targetParserVersion 非 nil 时持久记录目标 parser 版本，供 requiresRebuildCompletion/markRebuildCompleted 消费。
    public func resetForRebuild(targetParserVersion: Int? = nil) throws {
        try queue.sync {
            try transaction {
                // 先把派生表中可能高于 sync_state 的 revision 合并进持久高水位。
                // reset 后新行从高水位继续递增，旧在途 batch 因 revision 不匹配无法误 ack。
                try preserveRevisionHighWatermarksUnlocked()
                try exec("DELETE FROM usage_buckets;")
                try exec("DELETE FROM usage_sessions;")
                try exec("DELETE FROM usage_session_events;")
                try exec("DELETE FROM usage_edit_entries;")
                try exec("DELETE FROM usage_edit_metric_sources;")
                try exec("DELETE FROM usage_events;")
                try exec("DELETE FROM usage_files;")
                // 清 sync_state，但保留 per-host revision 高水位（revision\u{1}*），
                // 使 reset 后新行从高水位继续递增，旧在途 batch 因 revision 不匹配无法误 ack。
                // 注意：frozen_before_ms\u{1}* 不在保留之列——resetForRebuild 从磁盘源文件全量重扫重建，
                // 冻结水位必须一并清零，否则旧 frozen 会挡住重扫数据进入派生。生产不调用此路径。
                try exec("DELETE FROM sync_state WHERE key NOT LIKE 'revision\u{1}%';")
                // 清库与 pending 标记同事务提交：进程在后续重扫期间退出，重启仍能继续 rebuild。
                try setTextUnlocked(key: Self.rebuildPendingKey, value: "1")
                // 持久记录本次 rebuild 的目标 parser 版本（若提供），供协调层校验重扫是否达到目标版本。
                if let targetParserVersion {
                    try setIntUnlocked(key: Self.rebuildTargetParserVersionKey, value: Int64(targetParserVersion))
                }
            }
        }
    }

    // MARK: - Migration

    private func migrate() throws {
        let version = try scalar("PRAGMA user_version;")
        guard version <= Self.schemaVersion else { throw UsageLedgerError.sqlite("usage database is newer than this app") }
        if version == 0 {
            try transaction {
                try exec(Self.schemaV1SQL)
                try exec("PRAGMA user_version=1;")
            }
        }
        let afterBaseline = try scalar("PRAGMA user_version;")
        if afterBaseline == 1 {
            try transaction {
                try exec(Self.migrationV1ToV2SQL)
                try exec("PRAGMA user_version=2;")
            }
        }
        let afterV2 = try scalar("PRAGMA user_version;")
        if afterV2 == 2 {
            try transaction {
                // v2 -> v3：会话聚合表加 project 内容列（不进自然键）。
                // 逐列存在性检测后 ALTER，保证幂等且不丢现有数据（234MB 库安全迁移）。
                // session project 由原始 usage_events.project 派生，不在 usage_session_events 上冗余列。
                try addColumnIfMissing(table: "usage_sessions", column: "project", definition: "TEXT NOT NULL DEFAULT ''")
                try exec("PRAGMA user_version=3;")
            }
        }
        let afterV3 = try scalar("PRAGMA user_version;")
        if afterV3 == 3 {
            try transaction {
                // v3 -> v4：历史版本曾在此拆分对账债务键。对账门禁已整体移除，本步不再写入任何
                // 对账键，仅推进版本号；旧库遗留的对账键由 v9 -> v10 统一清理。
                try exec("PRAGMA user_version=4;")
            }
        }
        let afterV4 = try scalar("PRAGMA user_version;")
        if afterV4 == 4 {
            try transaction {
                // v4 -> v5：历史版本曾在此登记 legacy 派生行的初始全量同步对账债务。对账门禁已移除，
                // 本步不再写入任何对账键，仅推进版本号；遗留键由 v9 -> v10 清理。
                try exec("PRAGMA user_version=5;")
            }
        }
        let afterV5 = try scalar("PRAGMA user_version;")
        if afterV5 == 5 {
            try transaction {
                // v5 -> v6: 原始事件新增 merge_strategy 列，取代 insertRawEvents 里按来源名硬编码的
                // 分支。合并策略由解析路径决定并随事件持久化：Codex rollout=overwrite，
                // Claude-compatible transcript=cumulativeMax。历史 claude-code 行按其既有语义补写为
                // cumulativeMax，其余（含 codex 及任意旧数据）保持 overwrite，行为不变、无需回放。
                try addColumnIfMissing(table: "usage_events", column: "merge_strategy", definition: "TEXT NOT NULL DEFAULT 'overwrite'")
                try exec("UPDATE usage_events SET merge_strategy='cumulativeMax' WHERE source='claude-code';")
                try exec("PRAGMA user_version=6;")
            }
        }
        let afterV6 = try scalar("PRAGMA user_version;")
        if afterV6 == 6 {
            try transaction {
                // v6 -> v7: raw tool metrics/edit entries plus derived bucket/session payload fields.
                // Every added column has a lossless legacy default; natural keys and revision columns stay unchanged.
                try addColumnIfMissing(table: "usage_events", column: "skill_counts_json", definition: "TEXT NOT NULL DEFAULT '{}'")
                try addColumnIfMissing(table: "usage_events", column: "mcp_counts_json", definition: "TEXT NOT NULL DEFAULT '{}'")
                try addColumnIfMissing(table: "usage_buckets", column: "skills_json", definition: "TEXT NOT NULL DEFAULT '[]'")
                try addColumnIfMissing(table: "usage_buckets", column: "skill_counts_json", definition: "TEXT NOT NULL DEFAULT '{}'")
                try addColumnIfMissing(table: "usage_buckets", column: "mcp_counts_json", definition: "TEXT NOT NULL DEFAULT '{}'")
                try addColumnIfMissing(table: "usage_buckets", column: "lines_added", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(table: "usage_buckets", column: "lines_deleted", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(table: "usage_buckets", column: "lines_net", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(table: "usage_buckets", column: "code_metric_version", definition: "INTEGER NOT NULL DEFAULT 0")
                try addColumnIfMissing(table: "usage_sessions", column: "skills_json", definition: "TEXT NOT NULL DEFAULT '[]'")
                try exec("""
                    CREATE TABLE IF NOT EXISTS usage_edit_entries(
                      source TEXT NOT NULL,
                      tool_use_id TEXT NOT NULL,
                      model TEXT NOT NULL,
                      project TEXT NOT NULL,
                      timestamp_ms INTEGER NOT NULL,
                      lines_added INTEGER NOT NULL,
                      lines_deleted INTEGER NOT NULL,
                      created_at_ms INTEGER NOT NULL,
                      PRIMARY KEY(tool_use_id)
                    );
                    CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_bucket
                      ON usage_edit_entries(source,model,project,timestamp_ms);
                    CREATE TABLE IF NOT EXISTS usage_edit_metric_sources(
                      source TEXT PRIMARY KEY,
                      created_at_ms INTEGER NOT NULL
                    );
                    """)
                try exec("PRAGMA user_version=7;")
            }
        }
        let afterV7 = try scalar("PRAGMA user_version;")
        if afterV7 == 7 {
            try transaction {
                try migrateV7ToV8Unlocked()
                try exec("PRAGMA user_version=8;")
            }
        }
        let afterV8 = try scalar("PRAGMA user_version;")
        if afterV8 == 8 {
            try transaction {
                // v8 -> v9：usage_events 新增内容型去重键列。旧行默认空串（不参与内容折叠），
                // 由 parser v7 全库 rebuild 回填真实键；O(1) 元数据 ALTER。
                try addColumnIfMissing(table: "usage_events", column: "codex_dedup_key", definition: "TEXT NOT NULL DEFAULT ''")
                try exec("PRAGMA user_version=9;")
            }
        }
        let afterV9 = try scalar("PRAGMA user_version;")
        if afterV9 == 9 {
            try transaction {
                try migrateV9ToV10Unlocked()
                try exec("PRAGMA user_version=10;")
            }
        }
        // 版本无关的轻量元数据表/索引:每次 open 幂等补建。raw 大表性能索引只在后台派生前创建，
        // 避免存量大库升级时在 App 主线程初始化阶段同步 CREATE INDEX。
        try transaction {
            try ensureEssentialMetadataUnlocked()
        }
    }

    /// v9 -> v10：把采集机 hostname 下沉到原始事件层，rebuild 保留多机数据；并清理已废弃的
    /// 对账门禁 / 全量同步 generation 键（对账门禁子系统已整体移除）。
    ///
    /// - 三张原始表各加 `hostname TEXT NOT NULL DEFAULT ''`（O(1) 元数据 ALTER，不改主键，
    ///   保持 usage_events (source_file_hash,event_id) 的文件级 replace 幂等语义）。
    /// - 一次性把旧行的空 hostname 回填成「当时的 canonical hostname」：优先读 sync_state 的
    ///   canonical_hostname；缺失则用账本中唯一的历史 hostname 恢复；仍无则保留空串，由后续
    ///   finalize 按传入 hostname 兜底。
    /// - 若库里已有原始事件，置 raw 派生 dirty 位，确保回填后、首次 finalize 前不上报陈旧派生。
    /// - 删除历史遗留的对账债务键与 full_sync_generation 键，避免旧库升上来卡在已废弃的门禁上。
    private func migrateV9ToV10Unlocked() throws {
        try addColumnIfMissing(table: "usage_events", column: "hostname", definition: "TEXT NOT NULL DEFAULT ''")
        try addColumnIfMissing(table: "usage_session_events", column: "hostname", definition: "TEXT NOT NULL DEFAULT ''")
        if try tableExistsUnlocked("usage_edit_entries") {
            try addColumnIfMissing(table: "usage_edit_entries", column: "hostname", definition: "TEXT NOT NULL DEFAULT ''")
        }

        // 回填空 hostname：确定「当时的 canonical hostname」。
        var backfill = try readTextUnlocked(key: Self.canonicalHostnameKey).flatMap { $0.isEmpty ? nil : $0 }
        if backfill == nil { backfill = try uniqueLegacyHostnameCandidateUnlocked() }
        let hasEvents = try tableHasAnyRowUnlocked("usage_events")
        let hasSessionEvents = try tableHasAnyRowUnlocked("usage_session_events")
        let hasEditEntries = try tableHasAnyRowUnlocked("usage_edit_entries")
        let hasRawRows = hasEvents || hasSessionEvents || hasEditEntries
        if let host = backfill, !host.isEmpty {
            for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
                guard try tableExistsUnlocked(table) else { continue }
                let statement = try prepare("UPDATE \(table) SET hostname=? WHERE hostname='';")
                defer { sqlite3_finalize(statement) }
                try bind(statement, 1, host); try done(statement)
            }
            try deleteKeyUnlocked(Self.unresolvedLegacyRawHostnameKey)
        } else if hasRawRows {
            try setTextUnlocked(key: Self.unresolvedLegacyRawHostnameKey, value: "1")
        }

        // 若已有原始事件（历史库），置 raw 派生 dirty，直到一次成功 finalize 清除。
        if hasRawRows {
            try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
        }

        // 清理已废弃的对账门禁 / 全量同步 generation 键（子系统已整体移除）。
        try exec("DELETE FROM sync_state WHERE key='full_sync_generation' OR key='remote_reconciliation_required' OR key='remote_reconciliation_required_unassigned' OR key LIKE 'remote_reconciliation_required\u{1}%';")
    }

    /// 幂等列新增：仅当目标列不存在时执行 ALTER，兼容已被其它路径升级过的库。
    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let statement = try prepare("SELECT 1 FROM pragma_table_info(?) WHERE name=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, table); try bind(statement, 2, column)
        if sqlite3_step(statement) == SQLITE_ROW { return }
        try exec("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    /// v7 -> v8 迁移：把原始三表改为「文件级归属」模型，为 record 的原子 replace-by-fileID 语义奠基。
    ///
    /// 不变量：
    /// - usage_events：event_id 由「全局唯一」放宽为「文件内唯一」，PK 改为 (source_file_hash,event_id)，
    ///   允许跨文件相同 event_id 共存；聚合层按 logical event_id 去重。
    /// - usage_session_events / usage_edit_entries：新增 source_file_hash 列并纳入 PK，允许跨文件相同
    ///   (source,event_id) / tool_use_id 的原始行共存；聚合层分别按 (source,event_id) / tool_use_id 去重。
    /// - legacy 行的 source_file_hash 可能为空串（历史 append/upsert 未按文件归属）：一律**永久保留**，
    ///   既有 raw/buckets/sessions/sync_state 全部不丢，migration counts/summary 不变。
    /// - 兼容极简 v6 verifier fixture：这些库可能缺少 skill/mcp/edit 相关列与表；此处只重建三张原始表并
    ///   逐列存在性判断，缺失的派生/内容列不触碰，故极简库同样能安全迁移。
    /// 表重建采用 SQLite 官方「新建表 -> 拷贝 -> drop -> rename」流程，逐列按现有 schema 复制，缺列补默认，
    /// 全程在外层事务内完成，中途崩溃回滚不落半状态。
    private func migrateV7ToV8Unlocked() throws {
        // 1) usage_events：PK (event_id) -> (source_file_hash,event_id)。逐列复制现有值，缺列取默认。
        try rebuildTableUnlocked(
            table: "usage_events",
            createSQL: Self.usageEventsV8SQL,
            columns: [
                "event_id", "source", "model", "project", "timestamp_ms",
                "input_tokens", "output_tokens", "cached_input_tokens", "cache_creation_input_tokens",
                "reasoning_output_tokens", "total_tokens", "session_hash", "source_file_hash",
                "rollout_key", "parent_rollout_key", "inherited", "has_total_snapshot", "lineage_fingerprint",
                "merge_strategy", "skill_counts_json", "mcp_counts_json", "created_at_ms",
            ]
        )
        // 2) usage_session_events：新增 source_file_hash 并入 PK (source,event_id,source_file_hash)。
        try rebuildTableUnlocked(
            table: "usage_session_events",
            createSQL: Self.usageSessionEventsV8SQL,
            columns: ["event_id", "source", "session_hash", "role", "timestamp_ms", "source_file_hash", "created_at_ms"]
        )
        // 3) usage_edit_entries（若存在）：新增 source_file_hash 并入 PK (source_file_hash,tool_use_id)。
        //    极简 v6 fixture 可能无此表；仅在其存在时重建。
        if try tableExistsUnlocked("usage_edit_entries") {
            try rebuildTableUnlocked(
                table: "usage_edit_entries",
                createSQL: Self.usageEditEntriesV8SQL,
                columns: ["source", "tool_use_id", "model", "project", "timestamp_ms", "lines_added", "lines_deleted", "source_file_hash", "created_at_ms"]
            )
        }
        // 4) 崩溃/上传门禁：若已有任何原始事件（历史库），标记 raw 派生 dirty，直到一次成功 finalize 清除，
        //    确保「已迁移但尚未按新语义重算派生」的窗口内不会上报可能陈旧的派生。空库不置位（纯 no-op 升级）。
        let hasEvents = try tableHasAnyRowUnlocked("usage_events")
        let hasSessionEvents = try tableHasAnyRowUnlocked("usage_session_events")
        let hasEditEntries = try tableHasAnyRowUnlocked("usage_edit_entries")
        if hasEvents || hasSessionEvents || hasEditEntries {
            try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
        }
    }

    /// 官方安全表重建：建 <table>_v8new，按列名从旧表拷贝（缺列补默认），drop 旧表，rename 回原名，重建索引。
    /// 缺列检测基于旧表 pragma_table_info：极简 fixture 缺少的列在 SELECT 端用默认字面量补齐。
    private func rebuildTableUnlocked(table: String, createSQL: String, columns: [String]) throws {
        let newTable = "\(table)_v8new"
        try exec("DROP TABLE IF EXISTS \(newTable);")
        try exec(createSQL.replacingOccurrences(of: "__TABLE__", with: newTable))
        // 极简/历史库可能整表缺失（如某些 v6 fixture 无 usage_session_events）：直接建完整 v8 表并建索引，
        // 不再从缺失表 SELECT（否则 "no such table"）。语义等价于「零 legacy 行的空表」，无数据可丢。
        guard try tableExistsUnlocked(table) else {
            try exec(createSQL.replacingOccurrences(of: "__TABLE__", with: table))
            try exec("DROP TABLE \(newTable);")
            try exec(Self.v8IndexSQL(for: table))
            return
        }
        let existing = try tableColumnsUnlocked(table)
        let selectExprs = columns.map { column -> String in
            existing.contains(column) ? column : "\(Self.v8LegacyColumnDefault(column)) AS \(column)"
        }
        let insertCols = columns.joined(separator: ",")
        try exec("INSERT INTO \(newTable)(\(insertCols)) SELECT \(selectExprs.joined(separator: ",")) FROM \(table);")
        try exec("DROP TABLE \(table);")
        try exec("ALTER TABLE \(newTable) RENAME TO \(table);")
        try exec(Self.v8IndexSQL(for: table))
    }

    /// 极简/历史库缺列时的安全默认字面量（与各 ADD COLUMN 默认一致，保证语义无损）。
    private static func v8LegacyColumnDefault(_ column: String) -> String {
        switch column {
        case "source_file_hash", "session_hash", "rollout_key", "parent_rollout_key", "lineage_fingerprint",
             "model", "project": return "''"
        case "merge_strategy": return "'overwrite'"
        case "skill_counts_json", "mcp_counts_json": return "'{}'"
        case "inherited", "has_total_snapshot", "input_tokens", "output_tokens", "cached_input_tokens",
             "cache_creation_input_tokens", "reasoning_output_tokens", "total_tokens", "timestamp_ms",
             "lines_added", "lines_deleted", "created_at_ms": return "0"
        default: return "''"
        }
    }

    private static func v8IndexSQL(for table: String) -> String {
        switch table {
        case "usage_events":
            return "CREATE INDEX IF NOT EXISTS idx_usage_events_time ON usage_events(timestamp_ms);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_lineage ON usage_events(lineage_fingerprint);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_session ON usage_events(session_hash);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_file ON usage_events(source_file_hash);"
        case "usage_session_events":
            return "CREATE INDEX IF NOT EXISTS idx_session_events_group ON usage_session_events(source,session_hash,timestamp_ms);"
                + "CREATE INDEX IF NOT EXISTS idx_session_events_file ON usage_session_events(source_file_hash);"
        case "usage_edit_entries":
            return "CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_bucket ON usage_edit_entries(source,model,project,timestamp_ms);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_file ON usage_edit_entries(source_file_hash);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_dedup ON usage_edit_entries(tool_use_id);"
        default: return ""
        }
    }

    /// 性能索引：为 hostname 范围扫描、session 流式聚合及按 codex_dedup_key 反取副本提供索引。
    /// 不改 schema/parser 版本。
    private static func performanceIndexSQL(for table: String) -> String {
        switch table {
        case "usage_events":
            // source/event 索引会让 logical 聚合按索引顺序扫描后对每行回表；真实 10GB 账本上比顺序扫描
            // 更慢。恢复 hostname/time 顺序索引并换稳定名字：旧名字只清理一次，后续启动全部为 no-op。
            return "DROP INDEX IF EXISTS idx_usage_events_host;"
                + "DROP INDEX IF EXISTS idx_usage_events_host_logical;"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_host_time ON usage_events(hostname,timestamp_ms,event_id,source_file_hash);"
                // record() asks for the old raw rows of exactly one file before replacing them.
                // The existing single-column file index is not selective enough on multi-host,
                // multi-GB ledgers; SQLite can spend the scan hot path walking unrelated rows.
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_host_file ON usage_events(hostname,source_file_hash);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_dedup ON usage_events(codex_dedup_key);"
                // 增量闭包的两条正向边（logical→lineage、logical→content）把脏键表 JOIN 回
                // usage_events，连接列是 (source, event_id)。缺索引时每条边都全表扫描，50k 行
                // fixture 上两条边合计 0.25 秒，且随账本线性恶化——大库上增量会比全量还慢。
                //
                // 这里用**部分索引**而非普通索引，是为了不碰全量路径。普通的
                // (source, event_id) 索引会被全量 logical 聚合的 GROUP BY source, event_id 拿去
                // 替代排序，退化成「按索引序扫描 + 逐行回表」：实测把全量从 3.9 秒推到 52.5 秒。
                // 带 WHERE 谓词后计划器无法证明它覆盖全部行，那个 GROUP BY 就用不上它；而两条
                // 正向边的 SQL 本身带着同样的谓词，等值查找照样命中。
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_dirty_lineage ON usage_events(source,event_id,lineage_fingerprint) WHERE lineage_fingerprint <> '';"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_dirty_content ON usage_events(source,event_id,codex_dedup_key) WHERE codex_dedup_key <> '';"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_host_lineage ON usage_events(hostname,lineage_fingerprint,source,event_id) WHERE lineage_fingerprint <> '';"
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_host_content ON usage_events(hostname,codex_dedup_key,source,event_id) WHERE codex_dedup_key <> '';"
                // Full finalize only needs the small subset of rows carrying tool counters for
                // skill/MCP aggregation. Without this partial index, that step scans the entire
                // 25GB token-event table even though most rows have empty JSON counters.
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_tool_counts ON usage_events(hostname,timestamp_ms,source,event_id) WHERE skill_counts_json <> '{}' OR mcp_counts_json <> '{}';"
                // 其余增量边不带 lineage / content 谓词，需要一个通用的 (source, event_id) 入口。
                // 谓词 hostname <> '' 在真实数据上恒真（record 总是写入采集机名），所以覆盖面
                // 与普通索引一致；但计划器无法静态证明这一点，全量 GROUP BY 依旧走顺序扫描。
                // 代价是增量侧的 SQL 必须显式带上同一个谓词，否则匹配不到——见 dirtyScopeGuard。
                + "CREATE INDEX IF NOT EXISTS idx_usage_events_dirty_logical ON usage_events(source,event_id) WHERE hostname <> '';"
        case "usage_session_events":
            return "CREATE INDEX IF NOT EXISTS idx_session_events_host ON usage_session_events(hostname,source,event_id,source_file_hash);"
                + "CREATE INDEX IF NOT EXISTS idx_session_events_host_group ON usage_session_events(hostname,source,session_hash,timestamp_ms);"
                + "CREATE INDEX IF NOT EXISTS idx_session_events_host_file_dirty ON usage_session_events(hostname,source_file_hash,source,session_hash);"
        case "usage_edit_entries":
            return "CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_host ON usage_edit_entries(hostname,timestamp_ms,tool_use_id,source_file_hash);"
                + "CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_host_file_dirty ON usage_edit_entries(hostname,source_file_hash,source,model,project,timestamp_ms,tool_use_id);"
                // 增量 finalize 按脏 tool_use_id 反查该 ID 当前在册的全部 bucket。v8 rebuild 路径
                // 建过同名索引，但 v10 存量库不走那条路径，只能在这里补建。少了它这次反查会退化成
                // 全表扫描，脏 ID 数量一多就把增量的成本推回全量量级。
                + "CREATE INDEX IF NOT EXISTS idx_usage_edit_entries_dedup ON usage_edit_entries(tool_use_id);"
        default: return ""
        }
    }

    /// 幂等地补建启动路径必需的轻量元数据。不得在这里触碰 usage_events 等 raw 大表索引：
    /// UsageLedgerStore.init 可能在 App 主线程运行，存量大库上同步 CREATE INDEX 会造成冷启动假死。
    private func ensureEssentialMetadataUnlocked() throws {
        if try tableExistsUnlocked("usage_files") {
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_usage_files_source_status
                ON usage_files(source,scan_status,file_id);
                """)
        }
        if try tableExistsUnlocked("usage_buckets") {
            try exec("""
                CREATE INDEX IF NOT EXISTS idx_usage_buckets_window
                ON usage_buckets(bucket_start_ms,model);
                CREATE INDEX IF NOT EXISTS idx_usage_buckets_host_window
                ON usage_buckets(hostname,bucket_start_ms,model);
                """)
        }
        // 增量 finalize 的脏键表:record 事务内记录本轮受影响的去重/自然键,供 finalizeDerivedIncremental
        // 只重算受影响 bucket/session。自然键含 hostname,与派生单机口径一致。
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_dirty_keys(
              hostname TEXT NOT NULL,
              kind TEXT NOT NULL,
              key TEXT NOT NULL,
              created_at_ms INTEGER NOT NULL,
              PRIMARY KEY(hostname,kind,key)
            );
            """)
        // logical 组 (source, event_id) 上一轮实际贡献到的 bucket 自然键。
        // 增量 finalize 时用它把旧 bucket 纳入作用域——胜者易主后旧 bucket 的贡献行可能已不在
        // usage_events 里，无法从原始行还原出 bucket 键，必须靠这张映射表。
        try exec("""
            CREATE TABLE IF NOT EXISTS usage_logical_bucket_map(
              hostname TEXT NOT NULL,
              source TEXT NOT NULL,
              event_id TEXT NOT NULL,
              bucket_model TEXT NOT NULL,
              bucket_project TEXT NOT NULL,
              bucket_start INTEGER NOT NULL,
              PRIMARY KEY(hostname,source,event_id)
            );
            """)
        // 反向索引：闭包按 bucket 自然键反查贡献者，去重循环也拿新胜者 bucket 反查这张表。
        // 主键 (hostname,source,event_id) 对这个方向用不上，缺了它两条语句都退化成嵌套全表
        // 扫描——5 万事件的合成库上，单次胜者反查实测 171 秒。
        try exec("""
            CREATE INDEX IF NOT EXISTS idx_logical_bucket_map_bucket
            ON usage_logical_bucket_map(hostname,bucket_model,bucket_project,bucket_start,source);
            """)
    }

    /// 幂等地补建 raw 大表性能索引。只在后台 scan/finalize 路径调用，避免阻塞 App 初始化。
    private func ensurePerformanceIndexesUnlocked() throws {
        for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
            guard try tableExistsUnlocked(table) else { continue }
            let sql = Self.performanceIndexSQL(for: table)
            if !sql.isEmpty { try exec(sql) }
        }
    }

    private func tableExistsUnlocked(_ table: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, table)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func tableHasAnyRowUnlocked(_ table: String) throws -> Bool {
        guard try tableExistsUnlocked(table) else { return false }
        let statement = try prepare("SELECT 1 FROM \(table) LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func tableColumnsUnlocked(_ table: String) throws -> Set<String> {
        let statement = try prepare("SELECT name FROM pragma_table_info(?);")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, table)
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { columns.insert(text(statement, 0)) }
        return columns
    }

    private static let schemaV1SQL = """
        CREATE TABLE usage_events(event_id TEXT PRIMARY KEY,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,session_hash TEXT NOT NULL,source_file_hash TEXT NOT NULL,created_at_ms INTEGER NOT NULL);
        CREATE INDEX idx_usage_events_time ON usage_events(timestamp_ms);
        CREATE TABLE usage_buckets(hostname TEXT NOT NULL,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,bucket_start_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL,PRIMARY KEY(hostname,source,model,project,bucket_start_ms));
        CREATE TABLE usage_files(file_id TEXT PRIMARY KEY,source TEXT NOT NULL,path_hash TEXT NOT NULL,read_offset INTEGER NOT NULL,file_size INTEGER NOT NULL,mtime_ms INTEGER NOT NULL,parser_version INTEGER NOT NULL,scan_status TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
       CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
       """

    // v8 原始表 schema（用于 v7->v8 安全重建；__TABLE__ 由 rebuildTableUnlocked 替换为临时表名）。
    private static let usageEventsV8SQL = """
        CREATE TABLE __TABLE__(event_id TEXT NOT NULL,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,session_hash TEXT NOT NULL,source_file_hash TEXT NOT NULL,rollout_key TEXT NOT NULL DEFAULT '',parent_rollout_key TEXT NOT NULL DEFAULT '',inherited INTEGER NOT NULL DEFAULT 0,has_total_snapshot INTEGER NOT NULL DEFAULT 0,lineage_fingerprint TEXT NOT NULL DEFAULT '',merge_strategy TEXT NOT NULL DEFAULT 'overwrite',skill_counts_json TEXT NOT NULL DEFAULT '{}',mcp_counts_json TEXT NOT NULL DEFAULT '{}',created_at_ms INTEGER NOT NULL,PRIMARY KEY(source_file_hash,event_id));
        """
    private static let usageSessionEventsV8SQL = """
        CREATE TABLE __TABLE__(event_id TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,role TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,source_file_hash TEXT NOT NULL DEFAULT '',created_at_ms INTEGER NOT NULL,PRIMARY KEY(source,event_id,source_file_hash));
        """
    private static let usageEditEntriesV8SQL = """
        CREATE TABLE __TABLE__(source TEXT NOT NULL,tool_use_id TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,lines_added INTEGER NOT NULL,lines_deleted INTEGER NOT NULL,source_file_hash TEXT NOT NULL DEFAULT '',created_at_ms INTEGER NOT NULL,PRIMARY KEY(source_file_hash,tool_use_id));
        """

   // v1 -> v2：原始事件新增血缘列；派生表加 revision/synced_revision；新增会话事件表与会话聚合表。
   private static let migrationV1ToV2SQL = """
        ALTER TABLE usage_events ADD COLUMN rollout_key TEXT NOT NULL DEFAULT '';
        ALTER TABLE usage_events ADD COLUMN parent_rollout_key TEXT NOT NULL DEFAULT '';
        ALTER TABLE usage_events ADD COLUMN inherited INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE usage_events ADD COLUMN has_total_snapshot INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE usage_events ADD COLUMN lineage_fingerprint TEXT NOT NULL DEFAULT '';
        CREATE INDEX IF NOT EXISTS idx_usage_events_lineage ON usage_events(lineage_fingerprint);
        CREATE INDEX IF NOT EXISTS idx_usage_events_session ON usage_events(session_hash);
        ALTER TABLE usage_buckets ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE usage_buckets ADD COLUMN synced_revision INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE usage_session_events(event_id TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,role TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,created_at_ms INTEGER NOT NULL,PRIMARY KEY(source,event_id));
        CREATE INDEX IF NOT EXISTS idx_session_events_group ON usage_session_events(source,session_hash,timestamp_ms);
        CREATE TABLE usage_sessions(hostname TEXT NOT NULL,source TEXT NOT NULL,session_hash TEXT NOT NULL,first_activity_ms INTEGER NOT NULL,last_activity_ms INTEGER NOT NULL,active_seconds INTEGER NOT NULL,message_count INTEGER NOT NULL,user_message_count INTEGER NOT NULL,assistant_events INTEGER NOT NULL,hour_histogram TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,synced_revision INTEGER NOT NULL DEFAULT 0,updated_at_ms INTEGER NOT NULL,PRIMARY KEY(hostname,source,session_hash));
        """

    // MARK: - Revision + sync state (unlocked)

    private func nextRevisionUnlocked(hostname: String) throws -> Int64 {
        let next = (try readIntUnlocked(key: revisionKey(hostname)) ?? 0) + 1
        try setIntUnlocked(key: revisionKey(hostname), value: next)
        return next
    }

    private func revisionKey(_ hostname: String) -> String { "revision\u{1}\(hostname)" }
    private func lastSyncedKey(_ hostname: String) -> String { "last_synced_at_ms\u{1}\(hostname)" }
    private func reportingEligibleKey(_ hostname: String) -> String { "reporting_eligible\u{1}\(hostname)" }
    /// 冻结水位线（per-hostname）：早于该毫秒边界（对齐 30 分钟 bucket）的 bucket/session 视为已固化。
    /// 单调不减、永不回退；其原始行可被 compact 删除以省磁盘，派生行保留供本地看总数。
    private func frozenBeforeKey(_ hostname: String) -> String { "frozen_before_ms\u{1}\(hostname)" }

    /// 读取某 hostname 的冻结水位线（毫秒）；未设置返回 0（无冻结）。
    func frozenBeforeMsUnlocked(_ hostname: String) throws -> Int64 {
        try readIntUnlocked(key: frozenBeforeKey(hostname)) ?? 0
    }

    /// 因 timestamp < frozen 被 record 丢弃的迟到原始事件累计数（per-hostname，观测/验证用）。
    private func frozenDroppedEventsKey(_ hostname: String) -> String { "frozen_dropped_events\u{1}\(hostname)" }

    /// 已丢弃的迟到事件累计数（供 smoke/验证断言迟到事件确被丢弃而非入库）。
    public func frozenDroppedEventCount(hostname: String) throws -> Int64 {
        try queue.sync { try readIntUnlocked(key: frozenDroppedEventsKey(hostname)) ?? 0 }
    }
   private static let rebuildPendingKey = "rebuild_pending"
   private static let rebuildCompletedParserVersionKey = "rebuild_completed_parser_version"
    private static let canonicalHostnameKey = "canonical_hostname"
    /// v9 -> v10 迁移无法唯一确定 legacy 原始行归属时置位；仅在后续能证明归属时扫描并认领一次。
    private static let unresolvedLegacyRawHostnameKey = "unresolved_legacy_raw_hostname"
    /// raw 派生 dirty 位：每次 raw replace（record）同事务置位；finalizeDerived 成功重算派生后同事务清除。
    /// 置位期间 reportingEligible / pendingBatch 一律 fail-closed，确保文件替换后、
    /// finalize 之前进程崩溃不会上报仍反映旧原始归属的陈旧派生。
    private static let rawDerivationPendingKey = "raw_derivation_pending"
    /// parser rebuild pending 持久记录目标 parser 版本（resetForRebuild 写入），供协调层用
    /// requiresRebuildCompletion/markRebuildCompleted 完成；自动路径不再依赖 reset。
    private static let rebuildTargetParserVersionKey = "rebuild_target_parser_version"

    private func preserveRevisionHighWatermarksUnlocked() throws {
        let statement = try prepare("""
            SELECT hostname,MAX(revision) FROM (
              SELECT hostname,revision FROM usage_buckets
              UNION ALL SELECT hostname,revision FROM usage_sessions
            ) GROUP BY hostname;
            """)
        defer { sqlite3_finalize(statement) }
        var highWatermarks: [(hostname: String, revision: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            highWatermarks.append((text(statement, 0), sqlite3_column_int64(statement, 1)))
        }
        for item in highWatermarks {
            let current = try readIntUnlocked(key: revisionKey(item.hostname)) ?? 0
            if item.revision > current {
                try setIntUnlocked(key: revisionKey(item.hostname), value: item.revision)
            }
        }
    }

    private func readIntUnlocked(key: String) throws -> Int64? { try readTextUnlocked(key: key).flatMap { Int64($0) } }
    private func setIntUnlocked(key: String, value: Int64) throws { try setTextUnlocked(key: key, value: String(value)) }

    private func deleteKeyUnlocked(_ key: String) throws {
        let statement = try prepare("DELETE FROM sync_state WHERE key=?;"); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key); try done(statement)
    }

    private func readTextUnlocked(key: String) throws -> String? {
        let statement = try prepare("SELECT value FROM sync_state WHERE key=?;"); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private func setTextUnlocked(key: String, value: String) throws {
        let sql = "INSERT INTO sync_state(key,value,updated_at_ms) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updated_at_ms=excluded.updated_at_ms;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, key); try bind(statement, 2, value); try bind(statement, 3, millis(Date()))
        try done(statement)
    }

    /// 任一本地派生状态未完成都必须阻断所有上传读取与提交路径。
    private func hasLocalDerivationPendingUnlocked() throws -> Bool {
        try readTextUnlocked(key: Self.rawDerivationPendingKey) != nil
            || readTextUnlocked(key: Self.rebuildPendingKey) != nil
    }

    private func writeCheckpoint(_ checkpoint: UsageFileCheckpoint) throws {
        let checkpointSQL = """
            INSERT INTO usage_files(file_id,source,path_hash,read_offset,file_size,mtime_ms,parser_version,scan_status,updated_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(file_id) DO UPDATE SET
            source=excluded.source,path_hash=excluded.path_hash,read_offset=excluded.read_offset,file_size=excluded.file_size,mtime_ms=excluded.mtime_ms,parser_version=excluded.parser_version,scan_status=excluded.scan_status,updated_at_ms=excluded.updated_at_ms;
            """
        let statement = try prepare(checkpointSQL); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, checkpoint.fileID); try bind(statement, 2, checkpoint.source)
        try bind(statement, 3, checkpoint.pathHash); try bind(statement, 4, checkpoint.offset)
        try bind(statement, 5, checkpoint.size); try bind(statement, 6, millis(checkpoint.modifiedAt))
        try bind(statement, 7, Int64(checkpoint.parserVersion)); try bind(statement, 8, checkpoint.status)
        try bind(statement, 9, millis(Date())); try done(statement)
    }

    private func encodeHistogram(_ values: [Int64]) -> String { values.map(String.init).joined(separator: ",") }
    private func decodeHistogram(_ text: String) -> [Int64] {
        guard !text.isEmpty else { return [Int64](repeating: 0, count: 24) }
        return text.split(separator: ",").map { Int64($0) ?? 0 }
    }

    private func encodeStringArray(_ values: [String]) -> String {
        let normalized = UsageToolMetrics.normalizeSkills(values).sorted()
        guard let data = try? JSONEncoder.sorted.encode(normalized) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeStringArray(_ value: String) -> [String] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return UsageToolMetrics.normalizeSkills(decoded).sorted()
    }

    private func encodeStringIntMap(_ values: [String: Int]) -> String {
        let normalized = UsageToolMetrics.normalizeCounts(values)
        guard let data = try? JSONEncoder.sorted.encode(normalized) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func decodeStringIntMap(_ value: String) -> [String: Int] {
        guard let data = value.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return UsageToolMetrics.normalizeCounts(decoded)
    }

    private func saturatedAdd(_ left: Int64, _ right: Int64) -> Int64 {
        let (sum, overflowed) = left.addingReportingOverflow(right)
        return overflowed ? Int64.max : sum
    }

    private func maximumCounts(_ left: [String: Int], _ right: [String: Int]) -> [String: Int] {
        var result = UsageToolMetrics.normalizeCounts(left)
        for (key, value) in UsageToolMetrics.normalizeCounts(right) {
            result[key] = max(result[key] ?? 0, value)
        }
        return result
    }

    // MARK: - SQLite plumbing

    private func transaction(_ body: () throws -> Void) throws { try exec("BEGIN IMMEDIATE;"); do { try body(); try exec("COMMIT;") } catch { _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil); throw error } }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func scalar(_ sql: String) throws -> Int32 { let s = try prepare(sql); defer { sqlite3_finalize(s) }; guard sqlite3_step(s) == SQLITE_ROW else { throw error() }; return sqlite3_column_int(s, 0) }
    private func prepare(_ sql: String) throws -> OpaquePointer? { var s: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { throw error() }; return s }
    private func bind(_ s: OpaquePointer?, _ index: Int32, _ value: String) throws { guard sqlite3_bind_text(s, index, value, -1, usageSQLiteTransient) == SQLITE_OK else { throw error() } }
    private func bind(_ s: OpaquePointer?, _ index: Int32, _ value: Int64) throws { guard sqlite3_bind_int64(s, index, value) == SQLITE_OK else { throw error() } }
    private func done(_ s: OpaquePointer?) throws { guard sqlite3_step(s) == SQLITE_DONE else { throw error() } }
    private func text(_ s: OpaquePointer?, _ column: Int32) -> String { sqlite3_column_text(s, column).map { String(cString: $0) } ?? "" }
    private func error() -> UsageLedgerError { UsageLedgerError.sqlite(db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable") }
    private func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    private func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
