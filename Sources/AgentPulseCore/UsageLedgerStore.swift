import Foundation
import SQLite3

private let usageSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// full sync 提交核对失败的内部信号：在事务内 throw 触发 ROLLBACK，确保 fail-closed 不落部分状态。
private struct FullSyncFenced: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

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

/// reserve-before-snapshot 的快照失败：generation 已被重算推进，快照整体放弃（不返回半快照）。
/// 仅携带 generation 数字（expected/actual），不含 hostname、路径或用量等敏感数据。
public enum UsageFullSyncSnapshotError: Error, Sendable, Equatable {
    case staleGeneration(expected: Int64, actual: Int64)
    case localDerivationPending
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

/// 全量同步快照：单事务读取某 hostname 的**全部**派生行（含已 synced），用于与远端做
/// 完整对账（reconciliation）。
///
/// - generation: 本次快照的单调世代号（读取不推进）。快照之后账本若被 finalize/rebuild 重算并
///   推进 generation，则本快照过期；commitFullSync 以 generation 作为围栏（fence）整体拒绝陈旧提交。
/// - buckets / sessions: 每行携带其 revision 快照；commit 时按「自然键 + revision 快照」精确匹配。
/// - reconciliationReason: 当前 remote_reconciliation_required 的原因（无则 nil）。上层据此判断
///   是否需要触发一次全量对账；成功 commit 后该门禁被清除。
/// - payload fingerprint 由上层依据 buckets/sessions 内容计算（本层不做序列化假设）。
public struct UsageFullSyncSnapshot: Sendable, Equatable {
    public let hostname: String
    public let generation: Int64
    public let buckets: [UsagePendingBucket]
    public let sessions: [UsagePendingSession]
    public let reconciliationReason: String?

    public init(hostname: String, generation: Int64, buckets: [UsagePendingBucket], sessions: [UsagePendingSession], reconciliationReason: String?) {
        self.hostname = hostname
        self.generation = generation
        self.buckets = buckets
        self.sessions = sessions
        self.reconciliationReason = reconciliationReason
    }

    public var isEmpty: Bool { buckets.isEmpty && sessions.isEmpty }
}

/// 全量同步提交凭证：由上层在**远端已确认收妥整份快照**后回传给本层。
///
/// 必须携带发起时快照的 generation 与逐行 revision 快照。commitFullSync 会：
/// 1) 用 generation 围栏确认账本自快照以来未被重算；
/// 2) 逐行按 (自然键, revision 快照) 精确核对当前库行仍完全一致；
/// 任一不满足即整体 fail-closed（不部分标记、不清 gate）。全部匹配且远端已确认后，才原子
/// 地把全部行标记为已同步、清除 remote_reconciliation_required、恢复 reportingEligible。
public struct UsageFullSyncCommit: Sendable, Equatable {
    public let hostname: String
    public let generation: Int64
    public let buckets: [UsagePendingBucket]
    public let sessions: [UsagePendingSession]

    public init(hostname: String, generation: Int64, buckets: [UsagePendingBucket], sessions: [UsagePendingSession]) {
        self.hostname = hostname
        self.generation = generation
        self.buckets = buckets
        self.sessions = sessions
    }

    /// 从快照直接构造提交凭证（远端已确认整份快照时最常用）。
    public init(snapshot: UsageFullSyncSnapshot) {
        self.init(hostname: snapshot.hostname, generation: snapshot.generation, buckets: snapshot.buckets, sessions: snapshot.sessions)
    }
}

/// 全量同步提交结果。committed == true 表示整份快照已原子标记同步且门禁清除；
/// false 表示 fail-closed（附原因），此时库状态未被改动。
public struct UsageFullSyncCommitResult: Sendable, Equatable {
    public let committed: Bool
    public let failureReason: String?

    public init(committed: Bool, failureReason: String?) {
        self.committed = committed
        self.failureReason = failureReason
    }

    public static let success = UsageFullSyncCommitResult(committed: true, failureReason: nil)
    public static func failed(_ reason: String) -> UsageFullSyncCommitResult {
        UsageFullSyncCommitResult(committed: false, failureReason: reason)
    }
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
    public static let schemaVersion: Int32 = 9
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
                try insertRawEvents(events, fileID: fileID)
                try insertRawSessionEvents(sessionEvents, fileID: fileID)
                try insertRawEditEntries(editEntries, fileID: fileID)
                if editMetricsSupported && checkpoint.status == "complete" {
                    try markEditMetricSourceUnlocked(checkpoint.source)
                }
                try writeCheckpoint(checkpoint)
                // 每次 raw replace 都令派生 dirty：直到一次成功 finalizeDerived 才清除。
                try setTextUnlocked(key: Self.rawDerivationPendingKey, value: "1")
                if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                    try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                }
                // 无论 canonical 是首次确定还是已存在，都尝试把未绑定 host 的全局对账债务原子迁移到当前
                // 非空 hostname，使其可被针对该 host 的全量同步驱动清理（而非永久 fail-closed）。
                // relocate 在无 unassigned 债务时是 no-op，且保留已存在的 per-host 债务，不会覆盖。
                // 注意：hostname 配置变更走 rebuildForHostname，另有其对账保护路径。
                try relocateUnassignedReconciliationDebtUnlocked(to: hostname)
            }
        }
    }

    /// 只写原始 token 事件（网络主动拉取的来源，如 cliproxy），并写一条合成 checkpoint。
    ///
    /// 网络来源没有真实「文件偏移 / mtime」语义，但仍须写一条 usage_files 行，原因有二：
    /// 1) requiresParserRebuild 把「有数据却无任何 checkpoint」判为需重建；纯网络来源账本
    ///    若不写 checkpoint 会每轮被 resetForRebuild 清空。
    /// 2) checkpoint 的 parser_version 固定取一个足够大的稳定值，确保永远不小于当前本地
    ///    JSONL 解析器版本，不会误触 parser 升级重建。
    /// 归属到合成 fileID 并按文件级替换（先删该 fileID 旧行再插），幂等依赖稳定 event_id。
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
                try validateAttribution(events: events, sessionEvents: [], editEntries: [], fileID: fileID)
                try deleteRawForFileUnlocked(fileID: fileID)
                try insertRawEvents(events, fileID: fileID)
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

    private func insertRawEvents(_ events: [UsageEvent], fileID: String) throws {
        // 合并策略随事件持久化（merge_strategy），不再按来源名硬编码：
        // - cumulativeMax（Claude-compatible）：同 msg.id 流式累计增长，逐列取最大保证不丢更新，
        //   且 model=unknown 时保留既有 model（流式早行不冲掉已知 model）。
        // - overwrite（Codex rollout）：event_id 稳定且携带修正后的独立计数，重解析直接覆盖。
        let sql = """
            INSERT INTO usage_events
            (event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,source_file_hash,rollout_key,parent_rollout_key,inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,merge_strategy,skill_counts_json,mcp_counts_json,created_at_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
              mcp_counts_json=excluded.mcp_counts_json;
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
            try bind(insert, 23, millis(Date()))
            try done(insert)
        }
    }

    private func insertRawSessionEvents(_ events: [UsageSessionEvent], fileID: String) throws {
        let sql = """
            INSERT OR IGNORE INTO usage_session_events
            (event_id,source,session_hash,role,timestamp_ms,source_file_hash,created_at_ms)
            VALUES (?,?,?,?,?,?,?);
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        for event in events {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, event.id); try bind(insert, 2, event.source)
            try bind(insert, 3, event.sessionHash); try bind(insert, 4, event.role.rawValue)
            try bind(insert, 5, millis(event.timestamp)); try bind(insert, 6, fileID)
            try bind(insert, 7, millis(Date()))
            try done(insert)
        }
    }

    private func insertRawEditEntries(_ entries: [UsageEditEntry], fileID: String) throws {
        let sql = """
            INSERT OR IGNORE INTO usage_edit_entries
            (tool_use_id,source,model,project,timestamp_ms,lines_added,lines_deleted,source_file_hash,created_at_ms)
            VALUES (?,?,?,?,?,?,?,?,?);
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        for entry in entries where !entry.toolUseID.isEmpty {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, entry.toolUseID); try bind(insert, 2, entry.source)
            try bind(insert, 3, entry.model); try bind(insert, 4, entry.project)
            try bind(insert, 5, millis(entry.timestamp)); try bind(insert, 6, entry.added)
            try bind(insert, 7, entry.deleted); try bind(insert, 8, fileID)
            try bind(insert, 9, millis(Date()))
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
    public func finalizeDerived(hostname: String) throws -> UsageFinalizeResult {
        try queue.sync {
            var result = UsageFinalizeResult(reportingEligible: true, blockedReasons: [], collapsedInheritedEvents: 0)
            try transaction {
                result = try recomputeDerivedUnlocked(hostname: hostname)
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
    }

    private struct RawEditEntry {
        let source: String; let model: String; let project: String
        let timestampMs: Int64; let added: Int64; let deleted: Int64
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
    private func recomputeDerivedUnlocked(hostname: String) throws -> UsageFinalizeResult {
        var blockedReasons: [String] = []
        // 读取时按 v8 归属优先级去重（ownedActive>ownedHistory>legacy），并收集 overwrite 同 tier 冲突；
        // 冲突不静默取其一，而是 fail-closed 阻断 reporting。
        var overwriteConflicts: [String] = []
        let raw = try readAllRawEvents(overwriteConflicts: &overwriteConflicts)
        blockedReasons.append(contentsOf: overwriteConflicts)

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
                        mergeStrategy: preferred.mergeStrategy
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
                mergeStrategy: keep.mergeStrategy
            )
        }

        // 2) 重算 buckets（按 hostname,source,model,project,bucketStart 聚合）。
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

        // 3) 重算 sessions（复用聚合器）。
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
        var removedSyncedBuckets = 0
        var removedSyncedSessions = 0
        // 删除不再出现的 bucket（例如显式 rebuild 后事件减少）。
        for (key, row) in existingBuckets {
            if row.synced > 0 { removedSyncedBuckets += 1 }
            try deleteBucketUnlocked(hostname: hostname, key: key)
            changed = true
        }

        var existingSessions = try readSessionRowsUnlocked(hostname: hostname)
        for session in sessions {
            let key = "\(session.source)\u{1}\(session.sessionHash)"
            let existing = existingSessions[key]
            if existing?.session != session {
                try upsertSessionUnlocked(session, revision: newRevision)
                changed = true
            }
            existingSessions[key] = nil
        }
        for (key, row) in existingSessions {
            if row.synced > 0 { removedSyncedSessions += 1 }
            try deleteSessionUnlocked(hostname: hostname, key: key)
            changed = true
        }

        // 非 reconciliation 类阻断（如无法证明的 inherited replay）单独持久到 per-host eligibility flag；
        // reconciliation gate 用独立键，二者在 reportingEligible() 处正交组合。
        // 关键：per-host flag 不得混入 reconciliation 原因，否则 full sync 清 gate 后无法区分两类阻断。
        let nonReconciliationEligible = blockedReasons.isEmpty

        // 远端协议尚无 tombstone。若本地重算删除了曾经 ack 的自然键，远端仍会保留旧行；
        // 按 hostname 持久 fail-closed，避免下一次无变化 finalize 又自动恢复 reportingEligible，
        // 也避免用一个全局键混记多个 host 的对账债务（否则任一 host 的全量同步会误清其它 host 的债务）。
        if removedSyncedBuckets > 0 || removedSyncedSessions > 0 {
            let reason = "removed \(removedSyncedBuckets) previously synced bucket(s) and \(removedSyncedSessions) session(s) without remote tombstone support"
            try setTextUnlocked(key: reconciliationKey(hostname), value: reason)
        }
        // Reflect GLOBAL reconciliation debt: any hostname with outstanding debt blocks reporting,
        // so append every pending host reason (deterministic order), not just this host s.
        for debtHost in try pendingReconciliationHostsUnlocked() {
            if let reason = try readReconciliationReasonUnlocked(hostname: debtHost) {
                blockedReasons.append(reason)
            }
        }
        // 未绑定 host 的全局对账债务同样整体阻断上报。追加一个脱敏的通用原因（不含 hostname/路径/用量），
        // 使 finalize 返回的 reportingEligible 与 reportingEligible() 的判定保持一致，避免返回 eligible=true
        // 而实际 reportingEligible() 为 false。
        if try hasUnassignedReconciliationUnlocked() {
            blockedReasons.append("unassigned reconciliation debt pending until a canonical hostname is established")
        }

        if !changed {
            // 无变化则回退 revision 计数，避免无谓递增。
            try setIntUnlocked(key: revisionKey(hostname), value: newRevision - 1)
        } else {
            // 派生数据真实变化：推进全量同步 generation，使早于本次重算的 fullSyncSnapshot 提交被围栏拒绝。
            try nextGenerationUnlocked()
        }

        // per-host flag 仅记录非 reconciliation 阻断；reconciliation 由独立 gate 在 reportingEligible() 组合。
        try setTextUnlocked(key: reportingEligibleKey(hostname), value: nonReconciliationEligible ? "1" : "0")
        // 对外返回的整体资格仍需综合两类阻断（blockedReasons 已含 reconciliation）。
        let eligible = blockedReasons.isEmpty
        return UsageFinalizeResult(reportingEligible: eligible, blockedReasons: blockedReasons, collapsedInheritedEvents: collapsed, collapsedContentDuplicates: contentCollapsed)
    }

    public func reportingEligible(hostname: String) throws -> Bool {
        try queue.sync {
            // 任一采集/派生阶段未完成都必须 fail-closed，绝不上报陈旧或不完整派生。
            guard try !hasLocalDerivationPendingUnlocked() else { return false }
            // 未绑定 host 的全局对账债务：整体 fail-closed，直到迁移到真实 host 或被清理。
            guard try !hasUnassignedReconciliationUnlocked() else { return false }
            // 全局 fail-closed：任一 hostname 仍有未对账的远端残留（对账债务），整体不可上报。
            guard try pendingReconciliationHostsUnlocked().isEmpty else { return false }
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
        try queue.sync {
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
        let sql = "SELECT event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,skill_counts_json,mcp_counts_json,merge_strategy,source_file_hash FROM usage_events ORDER BY timestamp_ms,event_id,source_file_hash;"
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
                    mergeStrategy: text(statement, 18)
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
    private func overwriteConflictReason(existing: RawEvent, incoming event: RawEvent) -> String? {
        var mismatched: [String] = []
        if existing.counts != event.counts { mismatched.append("counts") }
        if existing.timestampMs != event.timestampMs { mismatched.append("timestamp") }
        if existing.sessionHash != event.sessionHash { mismatched.append("session") }
        // model=unknown 允许被已知 model 补齐，不算冲突；两个都非空且不同才算。
        if existing.model != event.model, existing.model != "unknown", event.model != "unknown" {
            mismatched.append("model")
        }
        if existing.project != event.project, existing.project != "unknown", event.project != "unknown" {
            mismatched.append("project")
        }
        guard !mismatched.isEmpty else { return nil }
        return "overwrite duplicate event \(existing.source)/\(existing.id) has conflicting \(mismatched.joined(separator: ",")) across files; kept deterministic first row and blocked reporting"
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
                // overwrite：保留确定性首行的计数（SQL 端已稳定排序）。
                mergedCounts = existing.counts
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
                mergeStrategy: cumulative ? "cumulativeMax" : existing.mergeStrategy
            )
    }

    private func readAllRawEditEntries() throws -> [RawEditEntry] {
        // 跨文件相同 tool_use_id 只保留确定性一条，避免同一编辑被两份文件重复计入行数指标。
        // v8 归属优先级：ownedActive > ownedHistory > legacy；有更高 tier 时完全忽略低 tier 旧行，
        // 仅当无任何 owned 行时保留 legacy。同 tier 内维持既有「按 timestamp,tool_use_id,source_file_hash
        // 稳定排序取首个」的确定性口径。
        let activeFiles = try ownedActiveFileIDsUnlocked()
        let statement = try prepare("SELECT source,model,project,timestamp_ms,lines_added,lines_deleted,tool_use_id,source_file_hash FROM usage_edit_entries ORDER BY timestamp_ms,tool_use_id,source_file_hash;")
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
                deleted: max(0, sqlite3_column_int64(statement, 5))
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
        let statement = try prepare("SELECT event_id,source,session_hash,role,timestamp_ms,source_file_hash FROM usage_session_events ORDER BY source,event_id,source_file_hash;")
        defer { sqlite3_finalize(statement) }
        var order: [String] = []
        var byKey: [String: (event: UsageSessionEvent, tier: AttributionTier)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let role = UsageSessionEvent.Role(rawValue: text(statement, 3)) else { continue }
            let key = "\(text(statement, 1))\u{1}\(text(statement, 0))"
            let tier = attributionTier(sourceFileHash: text(statement, 5), activeFiles: activeFiles)
            let event = UsageSessionEvent(id: text(statement, 0), source: text(statement, 1), sessionHash: text(statement, 2), role: role, timestamp: date(sqlite3_column_int64(statement, 4)))
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


    // MARK: - Full sync (generation-fenced reconciliation over ALL rows)

    /// 读取当前全量同步 generation（只读，不推进）。
    ///
    /// reserve-before-snapshot 流程：先取 baseline 并在远端预留，再用
    /// fullSyncSnapshot(hostname:expectedGeneration:) 取同一 generation 的快照；
    /// 期间账本若被 finalize/rebuild/reset 重算推进 generation，快照整体失败（不返回半快照）。
    public func fullSyncGenerationBaseline() throws -> Int64 {
        try queue.sync {
            if try hasLocalDerivationPendingUnlocked() {
                throw UsageFullSyncSnapshotError.localDerivationPending
            }
            return try readIntUnlocked(key: Self.fullSyncGenerationKey) ?? 0
        }
    }

    /// 兼容入口：等价于 fullSyncSnapshot(hostname:expectedGeneration: nil)。
    public func fullSyncSnapshot(hostname: String) throws -> UsageFullSyncSnapshot {
        try fullSyncSnapshot(hostname: hostname, expectedGeneration: nil)
    }

    /// 单事务读取某 hostname 的**全部**派生行（含已 synced），并附当前单调 generation 与
    /// reconciliation 原因，用于与远端做完整对账。
    ///
    /// generation 在同一事务内只读取、不推进：无数据变化时连续快照的 generation 必须相同，
    /// 否则「远端已 committed、本地 crash 未及 commit」的上传在恢复时会因重拍快照 generation
    /// 变大而永远无法通过 commit 围栏。generation 仅在派生数据真实变化（finalize 差异写入 /
    /// rebuild / reset）时推进，快照后任何这类重算都会使旧快照的 commit 整体失效。
    /// 快照与 generation 在同一事务内读取，避免读到半更新状态。
    ///
    /// expectedGeneration 非 nil 时，同一事务内先读 generation 并要求与之相等；不相等则抛
    /// UsageFullSyncSnapshotError.staleGeneration 且不读取/返回任何行（无半快照）。
    /// 全部行与 reconciliationReason 仍在同一一致性范围内读取。
    public func fullSyncSnapshot(hostname: String, expectedGeneration: Int64?) throws -> UsageFullSyncSnapshot {
        try queue.sync {
            var snapshot = UsageFullSyncSnapshot(hostname: hostname, generation: 0, buckets: [], sessions: [], reconciliationReason: nil)
            try transaction {
                if try hasLocalDerivationPendingUnlocked() {
                    throw UsageFullSyncSnapshotError.localDerivationPending
                }
                let generation = try readIntUnlocked(key: Self.fullSyncGenerationKey) ?? 0
                if let expectedGeneration, expectedGeneration != generation {
                    throw UsageFullSyncSnapshotError.staleGeneration(expected: expectedGeneration, actual: generation)
                }
                let buckets = try readAllBucketPendingUnlocked(hostname: hostname)
                let sessions = try readAllSessionPendingUnlocked(hostname: hostname)
                let reason = try readReconciliationReasonUnlocked(hostname: hostname)
                snapshot = UsageFullSyncSnapshot(hostname: hostname, generation: generation, buckets: buckets, sessions: sessions, reconciliationReason: reason)
            }
            return snapshot
        }
    }

    /// 指定 hostname 的 remote reconciliation 原因（无则 nil）。上层据此判断该 host 是否需要一次全量对账。
    public func reconciliationReason(hostname: String) throws -> String? {
        try queue.sync { try readReconciliationReasonUnlocked(hostname: hostname) }
    }

    /// 任一存在对账债务的 hostname 的原因（按 hostname 稳定排序取首个），无则 nil。
    /// 便于观测「当前是否存在任何未对账残留」而不必先知道具体 host。
    public func reconciliationReason() throws -> String? {
        try queue.sync {
            if let first = try pendingReconciliationHostsUnlocked().first {
                return try readReconciliationReasonUnlocked(hostname: first)
            }
            // 无 per-host 债务时，仍需暴露未绑定 host 的全局债务，供观测层判断整体是否 fail-closed。
            return try readTextUnlocked(key: Self.unassignedReconciliationKey).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// 存在对账债务（远端旧行待删除）的 hostname 列表，按 hostname 升序稳定排序。
    /// coordinator 据此优先驱动旧 host 的全量同步（即便它不是当前 canonical hostname）。
    public func pendingReconciliationHosts() throws -> [String] {
        try queue.sync { try pendingReconciliationHostsUnlocked() }
    }

    /// 提交一次全量同步：generation 围栏 + 逐行精确 revision 核对，整体成功或整体 fail-closed。
    ///
    /// 崩溃安全：全部核对与写入在单个 IMMEDIATE 事务内完成；核对不通过时直接返回失败且不改动任何
    /// 行（不部分标记、不清 gate）。仅当 generation 未过期、且提交携带的每个 (自然键, revision 快照)
    /// 与当前库行**精确一致**、且提交的行集与当前库该 hostname 全部行集合完全一致（无缺失/无多余）时，
    /// 才原子地：把全部行 synced_revision 抬到其 revision、清除 remote_reconciliation_required、
    /// 恢复 reportingEligible。
    @discardableResult
    public func commitFullSync(_ commit: UsageFullSyncCommit) throws -> UsageFullSyncCommitResult {
        try queue.sync {
            var result = UsageFullSyncCommitResult.failed("uninitialized")
            do {
                try transaction {
                    // 失败路径统一 throw FullSyncFenced 触发 ROLLBACK，绝不落任何部分状态（即便未来在核对前新增写入）。
                    // raw 派生 dirty（文件已 replace 但派生尚未重算）：整体 fail-closed，绝不据陈旧派生 commit。
                    if try hasLocalDerivationPendingUnlocked() {
                        throw FullSyncFenced("local derivation pending: scan or derived rebuild is incomplete")
                    }
                    // 1) generation 围栏：提交的 generation 必须等于当前 generation（快照后未被重算/推进）。
                    let currentGeneration = try readIntUnlocked(key: Self.fullSyncGenerationKey) ?? 0
                    guard commit.generation == currentGeneration else {
                        throw FullSyncFenced("full sync generation fenced: commit=\(commit.generation) current=\(currentGeneration)")
                    }

                    // 2) 逐行核对当前库行（含 synced）与提交快照精确一致；同时校验行集合完全一致。
                    // 自然键在库内因主键约束唯一；行集合计数相等 + 每个提交键精确命中，
                    // 即可证明「无缺失、无多余、无重复键」。
                    let liveBuckets = try readBucketRowsUnlocked(hostname: commit.hostname)
                    let liveSessions = try readSessionRowsUnlocked(hostname: commit.hostname)
                    guard liveBuckets.count == commit.buckets.count, liveSessions.count == commit.sessions.count else {
                        throw FullSyncFenced("full sync row set changed since snapshot (buckets \(commit.buckets.count)->\(liveBuckets.count), sessions \(commit.sessions.count)->\(liveSessions.count))")
                    }
                    var seenBucketKeys = Set<String>(); seenBucketKeys.reserveCapacity(commit.buckets.count)
                    for pending in commit.buckets {
                        let b = pending.bucket
                        let key = "\(b.source)\u{1}\(b.model)\u{1}\(b.project)\u{1}\(millis(b.bucketStart))"
                        guard seenBucketKeys.insert(key).inserted else {
                            throw FullSyncFenced("full sync commit contains duplicate bucket key: \(key)")
                        }
                        guard let row = liveBuckets[key] else {
                            throw FullSyncFenced("full sync bucket missing since snapshot: \(key)")
                        }
                        guard row.revision == pending.revision, row.bucket == b else {
                            throw FullSyncFenced("full sync bucket changed since snapshot: \(key)")
                        }
                    }
                    var seenSessionKeys = Set<String>(); seenSessionKeys.reserveCapacity(commit.sessions.count)
                    for pending in commit.sessions {
                        let s = pending.session
                        let key = "\(s.source)\u{1}\(s.sessionHash)"
                        guard seenSessionKeys.insert(key).inserted else {
                            throw FullSyncFenced("full sync commit contains duplicate session key: \(key)")
                        }
                        guard let row = liveSessions[key] else {
                            throw FullSyncFenced("full sync session missing since snapshot: \(key)")
                        }
                        guard row.revision == pending.revision, row.session == s else {
                            throw FullSyncFenced("full sync session changed since snapshot: \(key)")
                        }
                    }

                    // 3) 全部精确匹配 -> 原子标记全部行 synced、清 gate、恢复上报资格。
                    let nowMs = millis(Date())
                    let bucketSQL = "UPDATE usage_buckets SET synced_revision=?, updated_at_ms=? WHERE hostname=? AND source=? AND model=? AND project=? AND bucket_start_ms=? AND revision=?;"
                    let bucketStmt = try prepare(bucketSQL); defer { sqlite3_finalize(bucketStmt) }
                    for pending in commit.buckets {
                        let b = pending.bucket
                        sqlite3_reset(bucketStmt); sqlite3_clear_bindings(bucketStmt)
                        try bind(bucketStmt, 1, pending.revision); try bind(bucketStmt, 2, nowMs); try bind(bucketStmt, 3, b.hostname)
                        try bind(bucketStmt, 4, b.source); try bind(bucketStmt, 5, b.model); try bind(bucketStmt, 6, b.project); try bind(bucketStmt, 7, millis(b.bucketStart)); try bind(bucketStmt, 8, pending.revision)
                        try done(bucketStmt)
                    }
                    let sessionSQL = "UPDATE usage_sessions SET synced_revision=?, updated_at_ms=? WHERE hostname=? AND source=? AND session_hash=? AND revision=?;"
                    let sessionStmt = try prepare(sessionSQL); defer { sqlite3_finalize(sessionStmt) }
                    for pending in commit.sessions {
                        let s = pending.session
                        sqlite3_reset(sessionStmt); sqlite3_clear_bindings(sessionStmt)
                        try bind(sessionStmt, 1, pending.revision); try bind(sessionStmt, 2, nowMs); try bind(sessionStmt, 3, s.hostname)
                        try bind(sessionStmt, 4, s.source); try bind(sessionStmt, 5, s.sessionHash); try bind(sessionStmt, 6, pending.revision)
                        try done(sessionStmt)
                    }

                    // 全量对账完成：远端已收妥整份快照，仅清除 reconciliation gate。
                    // 不得无条件 set reportingEligible=1：per-host flag 记录的是非 reconciliation 阻断
                    //（如无法证明的 inherited replay），full sync 与其无关，覆盖会造成 fail-open。
                    // 清 gate 后由 reportingEligible() 正交组合：无 gate 且 flag==1 才恢复上报。
                    // 只清 commit.hostname 自己的对账债务；其它 host 的债务保持不变，
                    // 由后续针对各自 host 的全量同步分别清除。
                    try deleteKeyUnlocked(reconciliationKey(commit.hostname))
                    try setTextUnlocked(key: lastSyncedKey(commit.hostname), value: String(nowMs))
                    result = .success
                }
            } catch let fenced as FullSyncFenced {
                // 事务已 ROLLBACK：库状态未改动。返回失败原因，交由上层保持 fail-closed。
                result = .failed(fenced.reason)
            }
            return result
        }
    }

    /// 读取某 hostname 全部 bucket 行（含 synced），携带 revision 快照。
    private func readAllBucketPendingUnlocked(hostname: String) throws -> [UsagePendingBucket] {
        let sql = "SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,skills_json,skill_counts_json,mcp_counts_json,lines_added,lines_deleted,code_metric_version,revision FROM usage_buckets WHERE hostname=? AND bucket_start_ms>=0 ORDER BY revision,bucket_start_ms,source,model,project;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsagePendingBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5), cachedInput: sqlite3_column_int64(statement, 6), cacheCreationInput: sqlite3_column_int64(statement, 7), reasoningOutput: sqlite3_column_int64(statement, 8), reportedTotal: sqlite3_column_int64(statement, 9))
            let bucket = UsageBucket(
                hostname: hostname, source: text(statement, 0), model: text(statement, 1), project: text(statement, 2),
                bucketStart: date(sqlite3_column_int64(statement, 3)), counts: counts,
                skills: decodeStringArray(text(statement, 10)), skillCounts: decodeStringIntMap(text(statement, 11)),
                mcpCounts: decodeStringIntMap(text(statement, 12)), linesAdded: sqlite3_column_int64(statement, 13),
                linesDeleted: sqlite3_column_int64(statement, 14), codeMetricVersion: Int(sqlite3_column_int64(statement, 15))
            )
            result.append(UsagePendingBucket(bucket: bucket, revision: sqlite3_column_int64(statement, 16)))
        }
        return result
    }

    /// 读取某 hostname 全部 session 行（含 synced），携带 revision 快照。
    private func readAllSessionPendingUnlocked(hostname: String) throws -> [UsagePendingSession] {
        let sql = "SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,project,skills_json,revision FROM usage_sessions WHERE hostname=? AND first_activity_ms>=0 AND last_activity_ms>=0 ORDER BY revision,source,session_hash;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsagePendingSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let session = UsageSession(
                hostname: hostname, source: text(statement, 0), sessionHash: text(statement, 1),
                project: text(statement, 9), skills: decodeStringArray(text(statement, 10)),
                firstActivity: date(sqlite3_column_int64(statement, 2)), lastActivity: date(sqlite3_column_int64(statement, 3)),
                activeSeconds: sqlite3_column_int64(statement, 4), messageCount: sqlite3_column_int64(statement, 5),
                userMessageCount: sqlite3_column_int64(statement, 6), assistantEvents: sqlite3_column_int64(statement, 7),
                hourHistogramUTC: decodeHistogram(text(statement, 8))
            )
            result.append(UsagePendingSession(session: session, revision: sqlite3_column_int64(statement, 11)))
        }
        return result
    }


    // MARK: - Hostname gate + rebuild

    public func hostnameState(current hostname: String) throws -> UsageHostnameState {
        try queue.sync {
            guard let stored = try readTextUnlocked(key: Self.canonicalHostnameKey), !stored.isEmpty else { return .unset }
            return stored == hostname ? .match : .mismatch(stored: stored)
        }
    }

    /// canonical hostname 变化时，从原始事件事务重建目标 hostname 派生聚合，
    /// 清除所有旧 hostname 派生行，更新 canonical hostname 记录。
    public func rebuildForHostname(_ hostname: String) throws {
        try queue.sync {
            try transaction {
                try preserveRevisionHighWatermarksUnlocked()
                try preserveSyncedDeletionBlockUnlocked(reasonPrefix: "hostname rebuild")
                try exec("DELETE FROM usage_buckets;")
                try exec("DELETE FROM usage_sessions;")
                _ = try recomputeDerivedUnlocked(hostname: hostname)
                try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
            }
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
                try preserveSyncedDeletionBlockUnlocked(reasonPrefix: "parser rebuild")
                try exec("DELETE FROM usage_buckets;")
                try exec("DELETE FROM usage_sessions;")
                try exec("DELETE FROM usage_session_events;")
                try exec("DELETE FROM usage_edit_entries;")
                try exec("DELETE FROM usage_edit_metric_sources;")
                try exec("DELETE FROM usage_events;")
                try exec("DELETE FROM usage_files;")
                // full_sync_generation 单调不回退：保留其键，供 generation 围栏在 reset 后仍能拒绝旧在途提交。
                // 同时保留未绑定 host 的全局对账债务键（独立前缀，不匹配 per-host LIKE，需显式排除），
                // 否则 reset 会静默丢弃全局债务导致 fail-open。
                let deleteStmt = try prepare("DELETE FROM sync_state WHERE key NOT LIKE 'revision\u{1}%' AND key NOT LIKE 'remote_reconciliation_required\u{1}%' AND key!=? AND key!=?;")
                defer { sqlite3_finalize(deleteStmt) }
                try bind(deleteStmt, 1, Self.fullSyncGenerationKey)
                try bind(deleteStmt, 2, Self.unassignedReconciliationKey)
                try done(deleteStmt)
                // 清库与 pending 标记同事务提交：进程在后续重扫期间退出，重启仍能继续 rebuild。
                try setTextUnlocked(key: Self.rebuildPendingKey, value: "1")
                // 持久记录本次 rebuild 的目标 parser 版本（若提供），供协调层校验重扫是否达到目标版本。
                if let targetParserVersion {
                    try setIntUnlocked(key: Self.rebuildTargetParserVersionKey, value: Int64(targetParserVersion))
                }
                // 推进 generation：reset 后新快照从更高 generation 继续。
                try nextGenerationUnlocked()
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
                // v3 -> v4: split the single global reconciliation debt key into per-hostname keys.
                // Move any legacy debt to the canonical hostname when known; otherwise keep it as an
                // unassigned/global debt (fail-closed for every host) until a hostname is learned or
                // a successful full sync / manual clear resolves it. Never silently drop it.
                try migrateLegacyReconciliationDebtUnlocked()
                try exec("PRAGMA user_version=4;")
            }
        }
        let afterV4 = try scalar("PRAGMA user_version;")
        if afterV4 == 4 {
            try transaction {
                // v4 -> v5: pre-revision-tracking derived rows carry revision=0 AND synced_revision=0.
                // They may already exist on the remote (historically pushed) but the local ledger cannot
                // prove it, and the pre-ack crash window is indistinguishable. finalize's diff-write also
                // leaves them permanently non-pending whenever recomputed counts match. Register an
                // initial full-sync reconciliation debt per hostname so reporting is fail-closed until a
                // full sync reconciles them, and so a subsequent reset/rebuild cannot silently drop them
                // without leaving remote-cleanup debt.
                try markLegacyDerivedRowsAsInitialFullSyncDebtUnlocked()
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

    /// 全量同步 generation：全局单调计数（跨 hostname）。只在派生数据真实变化时推进——
    /// finalize 差异写入、rebuild、reset；fullSyncSnapshot 读取不推进，保证无数据变化时
    /// 连续快照 generation 相同，crash 恢复可用同一 generation 完成 commit。
    /// generation 只增不减，reset/rebuild 后不回退（清库时保留其 sync_state 键）。
    @discardableResult
    private func nextGenerationUnlocked() throws -> Int64 {
        let next = (try readIntUnlocked(key: Self.fullSyncGenerationKey) ?? 0) + 1
        try setIntUnlocked(key: Self.fullSyncGenerationKey, value: next)
        return next
    }

    private func revisionKey(_ hostname: String) -> String { "revision\u{1}\(hostname)" }
    private func lastSyncedKey(_ hostname: String) -> String { "last_synced_at_ms\u{1}\(hostname)" }
    private func reportingEligibleKey(_ hostname: String) -> String { "reporting_eligible\u{1}\(hostname)" }
    /// per-host reconciliation debt key (remote still holds old rows to delete): prefix + hostname.
    private func reconciliationKey(_ hostname: String) -> String { "\(Self.reconciliationKeyPrefix)\(hostname)" }
    private static let reconciliationKeyPrefix = "remote_reconciliation_required\u{1}"
    /// Legacy v1 global reconciliation key (no hostname). Migrated to the per-host key under the canonical hostname.
    private static let legacyReconciliationKey = "remote_reconciliation_required"
    /// Unassigned/global reconciliation debt (no hostname known yet). Blocks reporting for every host
    /// until it can be relocated to the canonical hostname (learned in record) or manually cleared.
    /// Uses an INDEPENDENT prefix that does not start with reconciliationKeyPrefix, so the per-host
    /// GLOB scan can never parse it into a pseudo-hostname / full-sync target.
    private static let unassignedReconciliationKey = "remote_reconciliation_required_unassigned"
   private static let fullSyncGenerationKey = "full_sync_generation"
   private static let rebuildPendingKey = "rebuild_pending"
   private static let rebuildCompletedParserVersionKey = "rebuild_completed_parser_version"
   private static let canonicalHostnameKey = "canonical_hostname"
    /// raw 派生 dirty 位：每次 raw replace（record）同事务置位；finalizeDerived 成功重算派生后同事务清除。
    /// 置位期间 reportingEligible / fullSyncSnapshot / pendingBatch 一律 fail-closed，确保文件替换后、
    /// finalize 之前进程崩溃不会上报仍反映旧原始归属的陈旧派生。
    private static let rawDerivationPendingKey = "raw_derivation_pending"
    /// parser rebuild pending 持久记录目标 parser 版本（resetForRebuild 写入），供协调层用
    /// requiresRebuildCompletion/markRebuildCompleted 完成；自动路径不再依赖 reset。
    private static let rebuildTargetParserVersionKey = "rebuild_target_parser_version"

    /// v3 -> v4 migration: relocate the legacy global reconciliation debt key to a per-host key.
    private func migrateLegacyReconciliationDebtUnlocked() throws {
        guard let legacy = try readTextUnlocked(key: Self.legacyReconciliationKey), !legacy.isEmpty else {
            try deleteKeyUnlocked(Self.legacyReconciliationKey)
            return
        }
        if let host = try readTextUnlocked(key: Self.canonicalHostnameKey), !host.isEmpty {
            // Preserve an already-migrated per-host debt if one exists; never overwrite it.
            if try readReconciliationReasonUnlocked(hostname: host) == nil {
                try setTextUnlocked(key: reconciliationKey(host), value: legacy)
            }
        } else {
            // No canonical hostname to bind the debt to. Keep it as unassigned/global debt so reporting
            // stays fail-closed for every host until a hostname is learned or the debt is cleared,
            // instead of dropping it (which would fail open). Never overwrite an existing unassigned debt.
            if try readTextUnlocked(key: Self.unassignedReconciliationKey).flatMap({ $0.isEmpty ? nil : $0 }) == nil {
                try setTextUnlocked(key: Self.unassignedReconciliationKey, value: legacy)
            }
        }
        try deleteKeyUnlocked(Self.legacyReconciliationKey)
    }

    /// v4 -> v5 migration: mark pre-revision-tracking derived rows (revision=0 AND synced_revision=0)
    /// as an initial full-sync reconciliation debt, one key per affected hostname. These rows cannot be
    /// proven synced or unsynced, so a full sync must reconcile them before reporting resumes.
    /// Idempotent: never overwrites an existing per-host debt reason.
    private func markLegacyDerivedRowsAsInitialFullSyncDebtUnlocked() throws {
        let statement = try prepare("""
            SELECT hostname,SUM(bucket_count),SUM(session_count) FROM (
              SELECT hostname,COUNT(*) AS bucket_count,0 AS session_count
                FROM usage_buckets WHERE revision=0 AND synced_revision=0 GROUP BY hostname
              UNION ALL
              SELECT hostname,0 AS bucket_count,COUNT(*) AS session_count
                FROM usage_sessions WHERE revision=0 AND synced_revision=0 GROUP BY hostname
            ) GROUP BY hostname;
            """)
        defer { sqlite3_finalize(statement) }
        var legacyRows: [(hostname: String, buckets: Int64, sessions: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            legacyRows.append((text(statement, 0), sqlite3_column_int64(statement, 1), sqlite3_column_int64(statement, 2)))
        }
        for item in legacyRows where item.buckets > 0 || item.sessions > 0 {
            // Preserve an existing per-host debt reason; never overwrite it.
            if try readReconciliationReasonUnlocked(hostname: item.hostname) != nil { continue }
            let reason = "initial full sync required for \(item.buckets) legacy bucket(s) and \(item.sessions) session(s) with unknown remote sync state"
            try setTextUnlocked(key: reconciliationKey(item.hostname), value: reason)
        }
    }
    /// Reads the reconciliation debt reason for a hostname (nil when absent/empty; unlocked, call inside queue.sync).
    private func readReconciliationReasonUnlocked(hostname: String) throws -> String? {
        try readTextUnlocked(key: reconciliationKey(hostname)).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Hostnames that carry reconciliation debt, sorted ascending for stable ordering (unlocked).
    private func pendingReconciliationHostsUnlocked() throws -> [String] {
        let prefix = Self.reconciliationKeyPrefix
        let statement = try prepare("SELECT key FROM sync_state WHERE key GLOB ? AND value<>'' ORDER BY key;")
        defer { sqlite3_finalize(statement) }
        var pat = ""
        for ch in prefix {
            if ch == "*" || ch == "?" || ch == "[" || ch == "]" {
                pat.append("["); pat.append(ch); pat.append("]")
            } else { pat.append(ch) }
        }
        try bind(statement, 1, pat + "*")
        var hosts: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = text(statement, 0)
            // The unassigned/global debt key shares the per-host prefix but is NOT a real hostname;
            // never surface it as a full-sync target. It is handled separately in reportingEligible().
            if key == Self.unassignedReconciliationKey { continue }
            hosts.append(String(key.dropFirst(prefix.count)))
        }
        return hosts
    }

    /// True when an unassigned/global reconciliation debt is outstanding (no hostname bound yet).
    /// Blocks reporting for every host until relocated to the canonical hostname or cleared.
    private func hasUnassignedReconciliationUnlocked() throws -> Bool {
        (try readTextUnlocked(key: Self.unassignedReconciliationKey).flatMap { $0.isEmpty ? nil : $0 }) != nil
    }

    /// Relocates any unassigned/global reconciliation debt onto a now-known canonical hostname, so it
    /// becomes reconcilable via a per-host full sync. Preserves an existing per-host debt; never
    /// overwrites it. Idempotent and safe to call whenever the canonical hostname is first learned.
    private func relocateUnassignedReconciliationDebtUnlocked(to hostname: String) throws {
        guard !hostname.isEmpty else { return }
        guard let debt = try readTextUnlocked(key: Self.unassignedReconciliationKey).flatMap({ $0.isEmpty ? nil : $0 }) else { return }
        if try readReconciliationReasonUnlocked(hostname: hostname) == nil {
            try setTextUnlocked(key: reconciliationKey(hostname), value: debt)
        }
        try deleteKeyUnlocked(Self.unassignedReconciliationKey)
    }

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

    private func preserveSyncedDeletionBlockUnlocked(reasonPrefix: String) throws {
        let statement = try prepare("""
            SELECT hostname,SUM(bucket_count),SUM(session_count) FROM (
              SELECT hostname,COUNT(*) AS bucket_count,0 AS session_count
                FROM usage_buckets WHERE synced_revision>0 GROUP BY hostname
              UNION ALL
              SELECT hostname,0 AS bucket_count,COUNT(*) AS session_count
                FROM usage_sessions WHERE synced_revision>0 GROUP BY hostname
            ) GROUP BY hostname;
            """)
        defer { sqlite3_finalize(statement) }
        var deletions: [(hostname: String, buckets: Int64, sessions: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            deletions.append((
                text(statement, 0),
                sqlite3_column_int64(statement, 1),
                sqlite3_column_int64(statement, 2)
            ))
        }
        // per-host reconciliation debt: one key per affected hostname
        for item in deletions where item.buckets > 0 || item.sessions > 0 {
            let reason = "\(reasonPrefix) removed \(item.buckets) previously synced bucket(s) and \(item.sessions) session(s) without remote tombstone support"
            try setTextUnlocked(key: reconciliationKey(item.hostname), value: reason)
        }

        // Legacy pre-revision-tracking rows (revision=0 AND synced_revision=0) have unknown remote sync
        // state and may already exist on the remote. Deleting them during reset/rebuild must never fail
        // open: register an initial full-sync debt for each affected host, but only when that host has no
        // reconciliation debt yet (never overwrite a more specific synced-deletion reason set above).
        let legacyStatement = try prepare("""
            SELECT hostname,SUM(bucket_count),SUM(session_count) FROM (
              SELECT hostname,COUNT(*) AS bucket_count,0 AS session_count
                FROM usage_buckets WHERE revision=0 AND synced_revision=0 GROUP BY hostname
              UNION ALL
              SELECT hostname,0 AS bucket_count,COUNT(*) AS session_count
                FROM usage_sessions WHERE revision=0 AND synced_revision=0 GROUP BY hostname
            ) GROUP BY hostname;
            """)
        defer { sqlite3_finalize(legacyStatement) }
        var legacyDeletions: [(hostname: String, buckets: Int64, sessions: Int64)] = []
        while sqlite3_step(legacyStatement) == SQLITE_ROW {
            legacyDeletions.append((text(legacyStatement, 0), sqlite3_column_int64(legacyStatement, 1), sqlite3_column_int64(legacyStatement, 2)))
        }
        for item in legacyDeletions where item.buckets > 0 || item.sessions > 0 {
            if try readReconciliationReasonUnlocked(hostname: item.hostname) != nil { continue }
            let reason = "\(reasonPrefix) removed \(item.buckets) legacy bucket(s) and \(item.sessions) session(s) with unknown remote sync state; initial full sync required"
            try setTextUnlocked(key: reconciliationKey(item.hostname), value: reason)
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
