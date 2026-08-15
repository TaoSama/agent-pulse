import Foundation
import SQLite3

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
            // ORDER BY 临时排序走内存，减少落盘。
            try exec("PRAGMA synchronous=NORMAL;")
            try exec("PRAGMA cache_size=-32768;")
            try exec("PRAGMA temp_store=MEMORY;")
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
                // 先删除该 fileID 的旧归属原始行，再插入本批新行：同事务实现「对该文件的原子替换」。
                try deleteRawForFileUnlocked(fileID: fileID)
                try insertRawEvents(events, fileID: fileID, hostname: hostname)
                try insertRawSessionEvents(sessionEvents, fileID: fileID, hostname: hostname)
                try insertRawEditEntries(editEntries, fileID: fileID, hostname: hostname)
                if editMetricsSupported && checkpoint.status == "complete" {
                    try markEditMetricSourceUnlocked(checkpoint.source)
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
    /// 网络来源不是「文件」：每个事件自带稳定的 per-event sourceFileHash（幂等键的一部分），
    /// 不存在单一 fileID 的原子替换语义，因此不走 record() 的文件级 replace 路径，只做
    /// 基于 (source_file_hash, event_id) 的幂等 upsert。仍写一条合成 checkpoint，原因有二：
    /// 1) requiresParserRebuild 把「有数据却无任何 checkpoint」判为需重建；纯网络来源账本
    ///    若不写 checkpoint 会每轮被 resetForRebuild 清空。
    /// 2) checkpoint 的 parser_version 取一个足够大的稳定值，保证不小于任何本地 JSONL 解析器
    ///    版本，从而永不触发 parser 升级重建。
    /// 扫描结束后仍须调用 finalizeDerived(hostname:)。
    public func recordNetworkEvents(_ events: [UsageEvent], source: String, hostname: String) throws {
        guard !events.isEmpty else { return }
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
                try insertRawEvents(events, fileID: fileID, hostname: hostname)
                try writeCheckpoint(checkpoint)
                if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                    try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                }
            }
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

    private func markEditMetricSourceUnlocked(_ source: String) throws {
        let normalized = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let statement = try prepare("INSERT OR IGNORE INTO usage_edit_metric_sources(source,created_at_ms) VALUES(?,?);")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, normalized); try bind(statement, 2, millis(Date()))
        try done(statement)
    }


    // MARK: - Finalize derived (global dedup + aggregate)

    @discardableResult
    public func finalizeDerived(
        hostname: String,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> UsageFinalizeResult {
        try queue.sync {
            var result = UsageFinalizeResult(reportingEligible: true, blockedReasons: [], collapsedInheritedEvents: 0)
            try transaction {
                result = try recomputeDerivedUnlocked(hostname: hostname, progress: progress)
                // 只有显式 finalize 表示调用方已经成功完成整轮来源扫描。其它内部重算
                // （例如 hostname 对齐）不能清除此门禁，否则部分扫描失败后会 fail-open。
                try deleteKeyUnlocked(Self.rawDerivationPendingKey)
            }
            return result
        }
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
        // 重算内部按 8 个自然阶段边界回报进度，让协调层的 .finalizing 段平滑推进而非跳变。
        // 回调是纯计数、在本 worker 队列 + 事务体内同步调用，不触碰主线程（主线程搬运在协调层适配）。
        let progressTotalStages = 8
        var progressStage = 0
        func advanceStage() {
            progressStage += 1
            progress?(progressStage, progressTotalStages)
        }
        var blockedReasons: [String] = []
        // 读取时按 v8 归属优先级去重（ownedActive>ownedHistory>legacy），并收集 overwrite 同 tier 冲突；
        // 冲突不静默取其一，而是 fail-closed 阻断 reporting。
        var overwriteConflicts: [String] = []
        let raw = try readAllRawEvents(overwriteConflicts: &overwriteConflicts)
        blockedReasons.append(contentsOf: overwriteConflicts)
        advanceStage() // 1) 读原始事件完成

        // 1) 血缘证明去重：同一 lineage_fingerprint（仅完整 total 快照才有）只保留一条。
        var fingerprintIndexes: [String: Int] = [:]
        var deduped: [RawEvent] = []
        var collapsed = 0
        var unprovable = 0
        for event in raw {
            if !event.lineageFingerprint.isEmpty {
                if let existingIndex = fingerprintIndexes[event.lineageFingerprint] {
                    // 同一完整 total 快照优先保留非继承的原始事件，避免扫描顺序决定
                    // model/project/session 等聚合维度。
                    let existing = deduped[existingIndex]
                    let preferred = existing.inherited && !event.inherited ? event : existing
                    deduped[existingIndex] = RawEvent(
                        id: preferred.id, source: preferred.source, model: preferred.model, project: preferred.project,
                        timestampMs: preferred.timestampMs, counts: preferred.counts, sessionHash: preferred.sessionHash,
                        inherited: preferred.inherited, hasTotalSnapshot: preferred.hasTotalSnapshot,
                        lineageFingerprint: preferred.lineageFingerprint,
                        codexDedupKey: preferred.codexDedupKey,
                        skillCounts: maximumCounts(existing.skillCounts, event.skillCounts),
                        mcpCounts: maximumCounts(existing.mcpCounts, event.mcpCounts),
                        mergeStrategy: preferred.mergeStrategy,
                        hostname: preferred.hostname
                    )
                    collapsed += 1
                    continue
                }
                fingerprintIndexes[event.lineageFingerprint] = deduped.count
                deduped.append(event)
            } else {
                // 无血缘指纹（无完整 total 快照）。若是继承回放行，则无法证明是否重复。
                if event.inherited {
                    unprovable += 1
                }
                deduped.append(event)
            }
        }
        if unprovable > 0 {
            blockedReasons.append("\(unprovable) inherited replay event(s) lack a complete total snapshot; cannot prove they are not duplicates")
        }
        advanceStage() // 2) 血缘去重完成

        // 1.5) 内容型去重：折叠共享同一 codexDedupKey 的 codex 事件（fork / subagent
        // 回放出的逐字节相同 turn）。同键保留 5 分量之和更大的一行（与参考实现的
        // largest-total-wins 一致，不用 reportedTotal 以免偏差），skill/mcp 取 max 并集。
        // 空键（含所有非 codex 事件）永不折叠。顺序在血缘去重之后，与参考实现的
        // ①replay ②dedupKey 一致。
        var dedupKeyIndexes: [String: Int] = [:]
        var contentDeduped: [RawEvent] = []
        contentDeduped.reserveCapacity(deduped.count)
        var contentCollapsed = 0
        for event in deduped {
            guard !event.codexDedupKey.isEmpty else { contentDeduped.append(event); continue }
            guard let existingIndex = dedupKeyIndexes[event.codexDedupKey] else {
                dedupKeyIndexes[event.codexDedupKey] = contentDeduped.count
                contentDeduped.append(event)
                continue
            }
            let existing = contentDeduped[existingIndex]
            contentCollapsed += 1
            let mergedSkill = maximumCounts(existing.skillCounts, event.skillCounts)
            let mergedMcp = maximumCounts(existing.mcpCounts, event.mcpCounts)
            // 快速路径：保留行仍是 existing（新行不更大）且 skill/mcp 并集未变化，
            // 免去整份 RawEvent 重建（codex token 事件的 skill/mcp 几乎恒空）。
            if event.counts.billableTotal <= existing.counts.billableTotal,
               mergedSkill == existing.skillCounts, mergedMcp == existing.mcpCounts {
                continue
            }
            let keep = event.counts.billableTotal > existing.counts.billableTotal ? event : existing
            contentDeduped[existingIndex] = RawEvent(
                id: keep.id, source: keep.source, model: keep.model, project: keep.project,
                timestampMs: keep.timestampMs, counts: keep.counts, sessionHash: keep.sessionHash,
                inherited: keep.inherited, hasTotalSnapshot: keep.hasTotalSnapshot,
                lineageFingerprint: keep.lineageFingerprint,
                codexDedupKey: keep.codexDedupKey,
                skillCounts: mergedSkill,
                mcpCounts: mergedMcp,
                mergeStrategy: keep.mergeStrategy,
                hostname: keep.hostname
            )
        }

        // 2) 重算 buckets（按 source,model,project,bucketStart 聚合）。
        // 派生全部归属到传入的当前 hostname（单一本机口径）。原始层虽存各事件采集机 hostname，
        // 但派生不做多机拆分——历史归属由 hostname 改名时的原地 UPDATE 统一维护。
        advanceStage() // 3) 内容去重完成
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
        for event in contentDeduped {
            let start = (event.timestampMs / Self.bucketMilliseconds) * Self.bucketMilliseconds
            let key = "\(event.source)\u{1}\(event.model)\u{1}\(event.project)\u{1}\(start)"
            var agg = buckets[key] ?? BucketAgg()
            let c = event.counts
            agg.counts = UsageTokenCounts(
                input: saturatedAdd(agg.counts.input, c.input), output: saturatedAdd(agg.counts.output, c.output),
                cachedInput: saturatedAdd(agg.counts.cachedInput, c.cachedInput),
                cacheCreationInput: saturatedAdd(agg.counts.cacheCreationInput, c.cacheCreationInput),
                reasoningOutput: saturatedAdd(agg.counts.reasoningOutput, c.reasoningOutput),
                reportedTotal: saturatedAdd(agg.counts.reportedTotal, c.total)
            )
            agg.skillCounts = UsageToolMetrics.mergeCounts(agg.skillCounts, event.skillCounts)
            agg.mcpCounts = UsageToolMetrics.mergeCounts(agg.mcpCounts, event.mcpCounts)
            buckets[key] = agg
            bucketMeta[key] = (event.source, event.model, event.project, start)
        }

        let editMetricSources = try readEditMetricSourcesUnlocked()
        for key in bucketMeta.keys {
            guard let meta = bucketMeta[key], editMetricSources.contains(meta.source) else { continue }
            buckets[key]?.codeMetricVersion = UsageEditLines.codeMetricVersion
        }
        advanceStage() // 4) bucket 聚合完成
        for edit in try readAllRawEditEntries() {
            let start = (edit.timestampMs / Self.bucketMilliseconds) * Self.bucketMilliseconds
            let key = "\(edit.source)\u{1}\(edit.model)\u{1}\(edit.project)\u{1}\(start)"
            var agg = buckets[key] ?? BucketAgg()
            agg.linesAdded = saturatedAdd(agg.linesAdded, edit.added)
            agg.linesDeleted = saturatedAdd(agg.linesDeleted, edit.deleted)
            agg.codeMetricVersion = UsageEditLines.codeMetricVersion
            buckets[key] = agg
            bucketMeta[key] = (edit.source, edit.model, edit.project, start)
        }

        // 3) 重算 sessions（复用聚合器，全部归属当前 hostname）。
        advanceStage() // 5) edit 聚合完成
        let sessionEvents = try readAllSessionEvents()
        // session project 内容策略：以同一 (source, sessionHash) 下**最新有效** UsageEvent.project 为准
        // （按 timestamp 取最大，非空优先），无则回落空串。project 不参与自然键/分组/去重。
        // 注意：从**全量 raw**（而非血缘去重后的 deduped）计算 —— 去重可能丢弃携带 project 的行，
        // 从 deduped 取会漏算 project；project 只是内容字段，用全量取最新非空更稳。
        var sessionProject: [String: (project: String, timestampMs: Int64)] = [:]
        var sessionSkillCounts: [String: [String: Int]] = [:]
        for event in raw where !event.project.isEmpty {
            let key = "\(event.source)\u{1}\(event.sessionHash)"
            if let current = sessionProject[key], current.timestampMs >= event.timestampMs { continue }
            sessionProject[key] = (event.project, event.timestampMs)
        }
        for event in raw where !event.inherited {
            let key = "\(event.source)\u{1}\(event.sessionHash)"
            sessionSkillCounts[key] = UsageToolMetrics.mergeCounts(sessionSkillCounts[key] ?? [:], event.skillCounts)
        }
        let sessions = UsageSessionAggregator.aggregate(
            events: sessionEvents,
            hostname: hostname,
            projectForSession: { source, sessionHash in
                sessionProject["\(source)\u{1}\(sessionHash)"]?.project ?? ""
            },
            skillsForSession: { source, sessionHash in
                UsageToolMetrics.skillNames(sessionSkillCounts["\(source)\u{1}\(sessionHash)"] ?? [:])
            }
        )

        // 4) 差异写入：仅对内容变化的行提升 revision（变 dirty），未变行保持原 revision/synced。
        advanceStage() // 6) session 聚合完成
        let newRevision = try nextRevisionUnlocked(hostname: hostname)
        var changed = false

        var existingBuckets = try readBucketRowsUnlocked(hostname: hostname)
        for (key, meta) in bucketMeta {
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
        // 删除不再出现的 bucket（例如事件减少）。
        for (key, _) in existingBuckets {
            try deleteBucketUnlocked(hostname: hostname, key: key)
            changed = true
        }

        var existingSessions = try readSessionRowsUnlocked(hostname: hostname)
        advanceStage() // 7) bucket 差异写完成
        for session in sessions {
            let key = "\(session.source)\u{1}\(session.sessionHash)"
            let existing = existingSessions[key]
            if existing?.session != session {
                try upsertSessionUnlocked(session, revision: newRevision)
                changed = true
            }
            existingSessions[key] = nil
        }
        for (key, _) in existingSessions {
            try deleteSessionUnlocked(hostname: hostname, key: key)
            changed = true
        }

        if !changed {
            // 无变化则回退 revision 计数，避免无谓递增。
            try setIntUnlocked(key: revisionKey(hostname), value: newRevision - 1)
        }

        // 非对账类阻断（如无法证明的 inherited replay）持久到 per-host eligibility flag。
        let eligible = blockedReasons.isEmpty
        try setTextUnlocked(key: reportingEligibleKey(hostname), value: eligible ? "1" : "0")
        advanceStage() // 8) session 差异写完成（重算结束）
        return UsageFinalizeResult(reportingEligible: eligible, blockedReasons: blockedReasons, collapsedInheritedEvents: collapsed, collapsedContentDuplicates: contentCollapsed)
    }

    public func reportingEligible(hostname: String) throws -> Bool {
        try queue.sync {
            // 任一采集/派生阶段未完成都必须 fail-closed，绝不上报陈旧或不完整派生。
            guard try !hasLocalDerivationPendingUnlocked() else { return false }
            return (try readTextUnlocked(key: reportingEligibleKey(hostname)) ?? "1") == "1"
        }
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

    /// 兼容入口：汇总 usage_buckets 中所有 hostname 的全时段派生数据。
    /// 新调用方应使用 hostname 版，避免 canonical host 变更时混入旧 host。
    public func summary(prices: [UsageModelPrice] = []) throws -> UsageSummary? {
        try queue.sync {
            let sql = "SELECT model,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,updated_at_ms FROM usage_buckets;"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            return try summarizeBucketRows(statement, prices: prices)
        }
    }

    /// 指定 canonical hostname 的派生桶汇总。window=nil 表示该 hostname 的全时段；
    /// 非 nil 使用调用方 calendar 的自然日/月/年区间，边界为 [start,end)。
    public func summary(
        window: UsageSummaryWindow?,
        containing date: Date,
        hostname: String,
        calendar: Calendar = .current,
        prices: [UsageModelPrice] = []
    ) throws -> UsageSummary? {
        try queue.sync {
            var sql = "SELECT model,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,updated_at_ms FROM usage_buckets WHERE hostname=?"
            var interval: DateInterval?
            if let window {
                interval = window.interval(containing: date, calendar: calendar)
                guard interval != nil else { return nil }
                sql += " AND bucket_start_ms>=? AND bucket_start_ms<?"
            }
            sql += ";"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            if let interval {
                try bind(statement, 2, millis(interval.start))
                try bind(statement, 3, millis(interval.end))
            }
            return try summarizeBucketRows(statement, prices: prices)
        }
    }

    /// 指定 canonical hostname 的按模型 token 汇总。window=nil 表示全时段；
    /// 非 nil 使用调用方 calendar 的窗口区间，边界为 [start,end)。
    /// 仅聚合 token 计数（不含费用），按 total 降序返回；无数据返回空数组。
    public func modelSummary(
        window: UsageSummaryWindow?,
        containing date: Date,
        hostname: String,
        calendar: Calendar = .current
    ) throws -> [UsageModelTokenSummary] {
        try queue.sync {
            var sql = "SELECT model,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens FROM usage_buckets WHERE hostname=?"
            var interval: DateInterval?
            if let window {
                interval = window.interval(containing: date, calendar: calendar)
                guard interval != nil else { return [] }
                sql += " AND bucket_start_ms>=? AND bucket_start_ms<?"
            }
            sql += ";"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            if let interval {
                try bind(statement, 2, millis(interval.start))
                try bind(statement, 3, millis(interval.end))
            }
            var byModel: [String: UsageTokenCounts] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let model = text(statement, 0)
                let counts = UsageTokenCounts(
                    input: sqlite3_column_int64(statement, 1), output: sqlite3_column_int64(statement, 2),
                    cachedInput: sqlite3_column_int64(statement, 3), cacheCreationInput: sqlite3_column_int64(statement, 4),
                    reasoningOutput: sqlite3_column_int64(statement, 5), reportedTotal: sqlite3_column_int64(statement, 6)
                )
                let existing = byModel[model] ?? UsageTokenCounts()
                byModel[model] = UsageTokenCounts(
                    input: saturatedAdd(existing.input, counts.input), output: saturatedAdd(existing.output, counts.output),
                    cachedInput: saturatedAdd(existing.cachedInput, counts.cachedInput),
                    cacheCreationInput: saturatedAdd(existing.cacheCreationInput, counts.cacheCreationInput),
                    reasoningOutput: saturatedAdd(existing.reasoningOutput, counts.reasoningOutput),
                    reportedTotal: saturatedAdd(existing.reportedTotal, counts.total)
                )
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return byModel
                .map { UsageModelTokenSummary(model: $0.key, counts: $0.value) }
                .sorted {
                    if $0.counts.total == $1.counts.total { return $0.model < $1.model }
                    return $0.counts.total > $1.counts.total
                }
        }
    }

    /// 指定 hostname 在 [start,end) 内、按 30min bucket_start 聚合的 output_tokens 时间序列。
    /// 用于看板 1 天 TPS 曲线（每个 30min bucket 的 output 之和 → /1800 = 平均 TPS）。
    /// 按 bucketStart 升序返回；无数据返回空数组。queue.sync 阻塞，勿在主线程调用。
    public func outputTokenBuckets(
        hostname: String,
        start: Date,
        end: Date
    ) throws -> [(bucketStart: Date, outputTokens: Int64)] {
        try queue.sync {
            let sql = "SELECT bucket_start_ms,SUM(output_tokens) FROM usage_buckets "
                + "WHERE hostname=? AND bucket_start_ms>=? AND bucket_start_ms<? "
                + "GROUP BY bucket_start_ms ORDER BY bucket_start_ms;"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            try bind(statement, 2, millis(start))
            try bind(statement, 3, millis(end))
            var rows: [(bucketStart: Date, outputTokens: Int64)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let bucketStartMs = sqlite3_column_int64(statement, 0)
                let output = sqlite3_column_int64(statement, 1)
                rows.append((Date(timeIntervalSince1970: Double(bucketStartMs) / 1000), output))
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return rows
        }
    }

    /// 同上，但按 (bucket_start, model) 分组，供看板 1 天分模型曲线。
    public func outputTokenBucketsByModel(
        hostname: String,
        start: Date,
        end: Date
    ) throws -> [(bucketStart: Date, model: String, outputTokens: Int64)] {
        try queue.sync {
            let sql = "SELECT bucket_start_ms,model,SUM(output_tokens) FROM usage_buckets "
                + "WHERE hostname=? AND bucket_start_ms>=? AND bucket_start_ms<? "
                + "GROUP BY bucket_start_ms,model ORDER BY bucket_start_ms;"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            try bind(statement, 1, hostname)
            try bind(statement, 2, millis(start))
            try bind(statement, 3, millis(end))
            var rows: [(bucketStart: Date, model: String, outputTokens: Int64)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let bucketStartMs = sqlite3_column_int64(statement, 0)
                let model = text(statement, 1)
                let output = sqlite3_column_int64(statement, 2)
                rows.append((Date(timeIntervalSince1970: Double(bucketStartMs) / 1000), model, output))
            }
            if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
            return rows
        }
    }

    private func summarizeBucketRows(_ statement: OpaquePointer?, prices: [UsageModelPrice]) throws -> UsageSummary? {
        var total = UsageTokenCounts(); var cost = 0.0; var newest: Int64?
        var found = false
        while sqlite3_step(statement) == SQLITE_ROW {
            found = true
            let counts = UsageTokenCounts(
                input: sqlite3_column_int64(statement, 1), output: sqlite3_column_int64(statement, 2),
                cachedInput: sqlite3_column_int64(statement, 3), cacheCreationInput: sqlite3_column_int64(statement, 4),
                reasoningOutput: sqlite3_column_int64(statement, 5), reportedTotal: sqlite3_column_int64(statement, 6)
            )
            total = UsageTokenCounts(
                input: saturatedAdd(total.input, counts.input), output: saturatedAdd(total.output, counts.output),
                cachedInput: saturatedAdd(total.cachedInput, counts.cachedInput),
                cacheCreationInput: saturatedAdd(total.cacheCreationInput, counts.cacheCreationInput),
                reasoningOutput: saturatedAdd(total.reasoningOutput, counts.reasoningOutput),
                reportedTotal: saturatedAdd(total.reportedTotal, counts.total)
            )
            cost += UsageCostEstimator.cost(model: text(statement, 0), counts: counts, prices: prices)
            newest = max(newest ?? 0, sqlite3_column_int64(statement, 7))
        }
        if sqlite3_errcode(db) != SQLITE_OK && sqlite3_errcode(db) != SQLITE_DONE { throw error() }
        return found ? UsageSummary(updatedAt: newest.map(date), counts: total, estimatedCostUSD: cost) : nil
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

    private func readAllRawEvents() throws -> [RawEvent] {
        var ignoredConflicts: [String] = []
        return try readAllRawEvents(overwriteConflicts: &ignoredConflicts)
    }

    private func readAllRawEvents(overwriteConflicts: inout [String]) throws -> [RawEvent] {
        // 读全部（跨文件）原始 token 行，稳定排序（含 source_file_hash 使跨文件同 id 顺序确定）。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let sql = "SELECT event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,skill_counts_json,mcp_counts_json,merge_strategy,source_file_hash,hostname FROM usage_events ORDER BY timestamp_ms,event_id,source_file_hash;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
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

    private func readAllRawEditEntries() throws -> [RawEditEntry] {
        // 跨文件相同 tool_use_id 只保留确定性一条，避免同一编辑被两份文件重复计入行数指标。
        // v8 归属优先级：ownedActive > ownedHistory > legacy；有更高 tier 时完全忽略低 tier 旧行，
        // 仅当无任何 owned 行时保留 legacy。同 tier 内维持既有「按 timestamp,tool_use_id,source_file_hash
        // 稳定排序取首个」的确定性口径。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let statement = try prepare("SELECT source,model,project,timestamp_ms,lines_added,lines_deleted,tool_use_id,source_file_hash,hostname FROM usage_edit_entries ORDER BY timestamp_ms,tool_use_id,source_file_hash;")
        defer { sqlite3_finalize(statement) }
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

    private func readAllSessionEvents() throws -> [UsageSessionEvent] {
        // 跨文件相同 (source,event_id) 的会话事件只保留一条。
        // v8 归属优先级：ownedActive > ownedHistory > legacy；有更高 tier 时完全忽略低 tier 旧行，
        // 仅当无任何 owned 行时保留 legacy。同 tier 内维持既有「按 source,event_id,source_file_hash
        // 稳定排序取首个」的确定性口径。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let statement = try prepare("SELECT event_id,source,session_hash,role,timestamp_ms,source_file_hash,hostname FROM usage_session_events ORDER BY source,event_id,source_file_hash;")
        defer { sqlite3_finalize(statement) }
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

    /// 标记一批磁盘上已消失的文件为 checkpoint missing，但绝不删除其原始行或派生历史。
    /// 删除源文件不应由 record 自动删历史；本 API 仅把这些 fileID 的 scan_status 置 "missing"，
    /// 保留 raw 以维持历史与去重口径。未登记的 fileID 忽略。
    public func markFilesMissing(fileIDs: [String]) throws {
        guard !fileIDs.isEmpty else { return }
        try queue.sync {
            try transaction {
                let statement = try prepare("UPDATE usage_files SET scan_status=?, updated_at_ms=? WHERE file_id=?;")
                defer { sqlite3_finalize(statement) }
                let nowMs = millis(Date())
                for fileID in fileIDs {
                    sqlite3_reset(statement); sqlite3_clear_bindings(statement)
                    try bind(statement, 1, "missing"); try bind(statement, 2, nowMs); try bind(statement, 3, fileID)
                    try done(statement)
                }
            }
        }
    }

    /// 以 source 为原子作用域，把本轮未出现的 checkpoint 标为 missing；只改 checkpoint，
    /// 不删除任何 raw。调用方必须先合并同 source 的全部 root（例如 Codex sessions + archive）。
    public func markFilesMissing(source: String, presentFileIDs: [String]) throws {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else { throw UsageLedgerError.invalidCheckpoint }
        let present = Set(presentFileIDs)
        try queue.sync {
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
        if let host = backfill, !host.isEmpty {
            for table in ["usage_events", "usage_session_events", "usage_edit_entries"] {
                guard try tableExistsUnlocked(table) else { continue }
                let statement = try prepare("UPDATE \(table) SET hostname=? WHERE hostname='';")
                defer { sqlite3_finalize(statement) }
                try bind(statement, 1, host); try done(statement)
            }
        }

        // 若已有原始事件（历史库），置 raw 派生 dirty，直到一次成功 finalize 清除。
        let hasEvents = try tableHasAnyRowUnlocked("usage_events")
        let hasSessionEvents = try tableHasAnyRowUnlocked("usage_session_events")
        let hasEditEntries = try tableHasAnyRowUnlocked("usage_edit_entries")
        if hasEvents || hasSessionEvents || hasEditEntries {
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
   private static let rebuildPendingKey = "rebuild_pending"
   private static let rebuildCompletedParserVersionKey = "rebuild_completed_parser_version"
   private static let canonicalHostnameKey = "canonical_hostname"
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
