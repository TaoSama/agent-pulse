import Foundation
import SQLite3

private let usageSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// full sync 提交核对失败的内部信号：在事务内 throw 触发 ROLLBACK，确保 fail-closed 不落部分状态。
private struct FullSyncFenced: Error { let reason: String; init(_ reason: String) { self.reason = reason } }

public enum UsageLedgerError: Error, CustomStringConvertible {
    case sqlite(String)
    case invalidCheckpoint

    public var description: String {
        switch self { case let .sqlite(message): message; case .invalidCheckpoint: "invalid checkpoint" }
    }
}

/// reserve-before-snapshot 的快照失败：generation 已被重算推进，快照整体放弃（不返回半快照）。
/// 仅携带 generation 数字（expected/actual），不含 hostname、路径或用量等敏感数据。
public enum UsageFullSyncSnapshotError: Error, Sendable, Equatable {
    case staleGeneration(expected: Int64, actual: Int64)
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

    public init(reportingEligible: Bool, blockedReasons: [String], collapsedInheritedEvents: Int) {
        self.reportingEligible = reportingEligible
        self.blockedReasons = blockedReasons
        self.collapsedInheritedEvents = collapsedInheritedEvents
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
    public static let schemaVersion: Int32 = 4
    public static let bucketMilliseconds: Int64 = 30 * 60 * 1_000
    public static let defaultMaxBucketsPerBatch = 500
    public static let defaultMaxSessionsPerBatch = 1_000

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.agentpulse.usage-ledger")

    public init(path: String) throws {
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
        } catch { sqlite3_close_v2(handle); db = nil; throw error }
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
        guard checkpoint.offset <= checkpoint.size else { throw UsageLedgerError.invalidCheckpoint }
        try queue.sync {
            try transaction {
                try insertRawEvents(events)
                try insertRawSessionEvents(sessionEvents)
                try writeCheckpoint(checkpoint)
                if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                    try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                }
            }
        }
    }

    private func insertRawEvents(_ events: [UsageEvent]) throws {
        // Claude 同 msg.id 累计增长：计数取每列最大，保证不丢更新。
        // Codex 稳定 event_id：重解析可覆盖 parser 可修正的计数与元数据。
        let sql = """
            INSERT INTO usage_events
            (event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,source_file_hash,rollout_key,parent_rollout_key,inherited,has_total_snapshot,lineage_fingerprint,created_at_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(event_id) DO UPDATE SET
              source=excluded.source,
              input_tokens=CASE WHEN excluded.source='claude-code' THEN MAX(input_tokens,excluded.input_tokens) ELSE excluded.input_tokens END,
              output_tokens=CASE WHEN excluded.source='claude-code' THEN MAX(output_tokens,excluded.output_tokens) ELSE excluded.output_tokens END,
              cached_input_tokens=CASE WHEN excluded.source='claude-code' THEN MAX(cached_input_tokens,excluded.cached_input_tokens) ELSE excluded.cached_input_tokens END,
              cache_creation_input_tokens=CASE WHEN excluded.source='claude-code' THEN MAX(cache_creation_input_tokens,excluded.cache_creation_input_tokens) ELSE excluded.cache_creation_input_tokens END,
              reasoning_output_tokens=CASE WHEN excluded.source='claude-code' THEN MAX(reasoning_output_tokens,excluded.reasoning_output_tokens) ELSE excluded.reasoning_output_tokens END,
              total_tokens=CASE WHEN excluded.source='claude-code' THEN MAX(total_tokens,excluded.total_tokens) ELSE excluded.total_tokens END,
              model=CASE WHEN excluded.source='claude-code' AND excluded.model='unknown' THEN model ELSE excluded.model END,
              project=excluded.project,
              timestamp_ms=excluded.timestamp_ms,
              session_hash=excluded.session_hash,
              source_file_hash=excluded.source_file_hash,
              rollout_key=excluded.rollout_key,
              parent_rollout_key=excluded.parent_rollout_key,
              inherited=excluded.inherited,
              has_total_snapshot=excluded.has_total_snapshot,
              lineage_fingerprint=excluded.lineage_fingerprint;
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        for event in events {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            let c = event.counts
            try bind(insert, 1, event.id); try bind(insert, 2, event.source)
            try bind(insert, 3, event.model); try bind(insert, 4, event.project)
            try bind(insert, 5, millis(event.timestamp)); try bind(insert, 6, c.input)
            try bind(insert, 7, c.output); try bind(insert, 8, c.cachedInput)
            try bind(insert, 9, c.cacheCreationInput); try bind(insert, 10, c.reasoningOutput)
            try bind(insert, 11, c.total); try bind(insert, 12, event.sessionHash)
            try bind(insert, 13, event.sourceFileHash); try bind(insert, 14, event.rolloutKey)
            try bind(insert, 15, event.parentRolloutKey); try bind(insert, 16, event.inherited ? 1 : 0)
            try bind(insert, 17, event.hasTotalSnapshot ? 1 : 0); try bind(insert, 18, event.lineageFingerprint)
            try bind(insert, 19, millis(Date()))
            try done(insert)
        }
    }

    private func insertRawSessionEvents(_ events: [UsageSessionEvent]) throws {
        let sql = """
            INSERT OR IGNORE INTO usage_session_events
            (event_id,source,session_hash,role,timestamp_ms,created_at_ms)
            VALUES (?,?,?,?,?,?);
            """
        let insert = try prepare(sql); defer { sqlite3_finalize(insert) }
        for event in events {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, event.id); try bind(insert, 2, event.source)
            try bind(insert, 3, event.sessionHash); try bind(insert, 4, event.role.rawValue)
            try bind(insert, 5, millis(event.timestamp)); try bind(insert, 6, millis(Date()))
            try done(insert)
        }
    }


    // MARK: - Finalize derived (global dedup + aggregate)

    @discardableResult
    public func finalizeDerived(hostname: String) throws -> UsageFinalizeResult {
        try queue.sync {
            var result = UsageFinalizeResult(reportingEligible: true, blockedReasons: [], collapsedInheritedEvents: 0)
            try transaction {
                result = try recomputeDerivedUnlocked(hostname: hostname)
            }
            return result
        }
    }

    private struct RawEvent {
        let id: String; let source: String; let model: String; let project: String
        let timestampMs: Int64; let counts: UsageTokenCounts
        let sessionHash: String; let inherited: Bool; let hasTotalSnapshot: Bool; let lineageFingerprint: String
    }

    // 全局重算派生表：读取全部原始事件 -> 血缘证明去重 -> 重算 buckets/sessions -> 差异写入并递增 revision。
    private func recomputeDerivedUnlocked(hostname: String) throws -> UsageFinalizeResult {
        let raw = try readAllRawEvents()

        // 1) 血缘证明去重：同一 lineage_fingerprint（仅完整 total 快照才有）只保留一条。
        var fingerprintIndexes: [String: Int] = [:]
        var deduped: [RawEvent] = []
        var collapsed = 0
        var blockedReasons: [String] = []
        var unprovable = 0
        for event in raw {
            if !event.lineageFingerprint.isEmpty {
                if let existingIndex = fingerprintIndexes[event.lineageFingerprint] {
                    // 同一完整 total 快照优先保留非继承的原始事件，避免扫描顺序决定
                    // model/project/session 等聚合维度。
                    if deduped[existingIndex].inherited && !event.inherited {
                        deduped[existingIndex] = event
                    }
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

        // 2) 重算 buckets（按 hostname,source,model,project,bucketStart 聚合）。
        struct BucketAgg { var counts: UsageTokenCounts }
        var buckets: [String: BucketAgg] = [:]
        var bucketMeta: [String: (source: String, model: String, project: String, start: Int64)] = [:]
        for event in deduped {
            let start = (event.timestampMs / Self.bucketMilliseconds) * Self.bucketMilliseconds
            let key = "\(event.source)\u{1}\(event.model)\u{1}\(event.project)\u{1}\(start)"
            var agg = buckets[key]?.counts ?? UsageTokenCounts()
            let c = event.counts
            agg = UsageTokenCounts(
                input: agg.input + c.input, output: agg.output + c.output,
                cachedInput: agg.cachedInput + c.cachedInput, cacheCreationInput: agg.cacheCreationInput + c.cacheCreationInput,
                reasoningOutput: agg.reasoningOutput + c.reasoningOutput, reportedTotal: agg.reportedTotal + c.total
            )
            buckets[key] = BucketAgg(counts: agg)
            bucketMeta[key] = (event.source, event.model, event.project, start)
        }

        // 3) 重算 sessions（复用聚合器）。
        let sessionEvents = try readAllSessionEvents()
        // session project 内容策略：以同一 (source, sessionHash) 下**最新有效** UsageEvent.project 为准
        // （按 timestamp 取最大，非空优先），无则回落空串。project 不参与自然键/分组/去重。
        // 注意：从**全量 raw**（而非血缘去重后的 deduped）计算 —— 去重可能丢弃携带 project 的行，
        // 从 deduped 取会漏算 project；project 只是内容字段，用全量取最新非空更稳。
        var sessionProject: [String: (project: String, timestampMs: Int64)] = [:]
        for event in raw where !event.project.isEmpty {
            let key = "\(event.source)\u{1}\(event.sessionHash)"
            if let current = sessionProject[key], current.timestampMs >= event.timestampMs { continue }
            sessionProject[key] = (event.project, event.timestampMs)
        }
        let sessions = UsageSessionAggregator.aggregate(events: sessionEvents, hostname: hostname) { source, sessionHash in
            sessionProject["\(source)\u{1}\(sessionHash)"]?.project ?? ""
        }

        // 4) 差异写入：仅对内容变化的行提升 revision（变 dirty），未变行保持原 revision/synced。
        let newRevision = try nextRevisionUnlocked(hostname: hostname)
        var changed = false

        var existingBuckets = try readBucketRowsUnlocked(hostname: hostname)
        for (key, meta) in bucketMeta {
            let counts = buckets[key]!.counts
            let existing = existingBuckets[key]
            if existing?.counts != counts {
                try upsertBucketUnlocked(hostname: hostname, source: meta.source, model: meta.model, project: meta.project, start: meta.start, counts: counts, revision: newRevision)
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
        return UsageFinalizeResult(reportingEligible: eligible, blockedReasons: blockedReasons, collapsedInheritedEvents: collapsed)
    }

    public func reportingEligible(hostname: String) throws -> Bool {
        try queue.sync {
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
            let checkpoint = try prepare("SELECT 1 FROM usage_files WHERE parser_version<? LIMIT 1;")
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

            let invalidTimestampSQL = """
                SELECT 1 FROM (
                  SELECT timestamp_ms AS value FROM usage_events WHERE timestamp_ms<0
                  UNION ALL SELECT timestamp_ms FROM usage_session_events WHERE timestamp_ms<0
                  UNION ALL SELECT bucket_start_ms FROM usage_buckets WHERE bucket_start_ms<0
                  UNION ALL SELECT first_activity_ms FROM usage_sessions WHERE first_activity_ms<0
                  UNION ALL SELECT last_activity_ms FROM usage_sessions WHERE last_activity_ms<0
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

    public func summary(prices: [UsageModelPrice] = []) throws -> UsageSummary? {
        try queue.sync {
            let sql = "SELECT model,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,updated_at_ms FROM usage_buckets;"
            let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
            var total = UsageTokenCounts(); var cost = 0.0; var newest: Int64?
            var found = false
            while sqlite3_step(statement) == SQLITE_ROW {
                found = true
                let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 1), output: sqlite3_column_int64(statement, 2), cachedInput: sqlite3_column_int64(statement, 3), cacheCreationInput: sqlite3_column_int64(statement, 4), reasoningOutput: sqlite3_column_int64(statement, 5), reportedTotal: sqlite3_column_int64(statement, 6))
                total.input += counts.input; total.output += counts.output; total.cachedInput += counts.cachedInput
                total.cacheCreationInput += counts.cacheCreationInput; total.reasoningOutput += counts.reasoningOutput
                total.reportedTotal += counts.total
                cost += UsageCostEstimator.cost(model: text(statement, 0), counts: counts, prices: prices)
                newest = max(newest ?? 0, sqlite3_column_int64(statement, 7))
            }
            return found ? UsageSummary(updatedAt: newest.map(date), counts: total, estimatedCostUSD: cost) : nil
        }
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
            SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens
            FROM usage_buckets WHERE hostname=? ORDER BY bucket_start_ms,source,model,project;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsageBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5), cachedInput: sqlite3_column_int64(statement, 6), cacheCreationInput: sqlite3_column_int64(statement, 7), reasoningOutput: sqlite3_column_int64(statement, 8), reportedTotal: sqlite3_column_int64(statement, 9))
            result.append(UsageBucket(hostname: hostname, source: text(statement, 0), model: text(statement, 1), project: text(statement, 2), bucketStart: date(sqlite3_column_int64(statement, 3)), counts: counts))
        }
        return result
    }

    private func readSessionsUnlocked(hostname: String) throws -> [UsageSession] {
        let sql = """
            SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,project
            FROM usage_sessions WHERE hostname=? ORDER BY source,session_hash;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsageSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(UsageSession(
                hostname: hostname, source: text(statement, 0), sessionHash: text(statement, 1),
                project: text(statement, 9),
                firstActivity: date(sqlite3_column_int64(statement, 2)), lastActivity: date(sqlite3_column_int64(statement, 3)),
                activeSeconds: sqlite3_column_int64(statement, 4), messageCount: sqlite3_column_int64(statement, 5),
                userMessageCount: sqlite3_column_int64(statement, 6), assistantEvents: sqlite3_column_int64(statement, 7),
                hourHistogramUTC: decodeHistogram(text(statement, 8))
            ))
        }
        return result
    }

    private func readAllRawEvents() throws -> [RawEvent] {
        let sql = "SELECT event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,session_hash,inherited,has_total_snapshot,lineage_fingerprint FROM usage_events ORDER BY timestamp_ms,event_id;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        var result: [RawEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 5), output: sqlite3_column_int64(statement, 6), cachedInput: sqlite3_column_int64(statement, 7), cacheCreationInput: sqlite3_column_int64(statement, 8), reasoningOutput: sqlite3_column_int64(statement, 9), reportedTotal: sqlite3_column_int64(statement, 10))
            result.append(RawEvent(
                id: text(statement, 0), source: text(statement, 1), model: text(statement, 2), project: text(statement, 3),
                timestampMs: sqlite3_column_int64(statement, 4), counts: counts, sessionHash: text(statement, 11),
                inherited: sqlite3_column_int64(statement, 12) != 0, hasTotalSnapshot: sqlite3_column_int64(statement, 13) != 0,
                lineageFingerprint: text(statement, 14)
            ))
        }
        return result
    }

    private func readAllSessionEvents() throws -> [UsageSessionEvent] {
        let statement = try prepare("SELECT event_id,source,session_hash,role,timestamp_ms FROM usage_session_events;")
        defer { sqlite3_finalize(statement) }
        var result: [UsageSessionEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let role = UsageSessionEvent.Role(rawValue: text(statement, 3)) else { continue }
            result.append(UsageSessionEvent(id: text(statement, 0), source: text(statement, 1), sessionHash: text(statement, 2), role: role, timestamp: date(sqlite3_column_int64(statement, 4))))
        }
        return result
    }


    // MARK: - Derived row helpers (unlocked; inside transaction)

    private struct BucketRow: Equatable { let counts: UsageTokenCounts; let revision: Int64; let synced: Int64 }

    private func readBucketRowsUnlocked(hostname: String) throws -> [String: BucketRow] {
        let sql = "SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,revision,synced_revision FROM usage_buckets WHERE hostname=?;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [String: BucketRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let start = sqlite3_column_int64(statement, 3)
            let key = "\(text(statement,0))\u{1}\(text(statement,1))\u{1}\(text(statement,2))\u{1}\(start)"
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5), cachedInput: sqlite3_column_int64(statement, 6), cacheCreationInput: sqlite3_column_int64(statement, 7), reasoningOutput: sqlite3_column_int64(statement, 8), reportedTotal: sqlite3_column_int64(statement, 9))
            result[key] = BucketRow(counts: counts, revision: sqlite3_column_int64(statement, 10), synced: sqlite3_column_int64(statement, 11))
        }
        return result
    }

    private func upsertBucketUnlocked(hostname: String, source: String, model: String, project: String, start: Int64, counts: UsageTokenCounts, revision: Int64) throws {
        let c = counts
        let sql = """
            INSERT INTO usage_buckets(hostname,source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,revision,synced_revision,updated_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,?)
            ON CONFLICT(hostname,source,model,project,bucket_start_ms) DO UPDATE SET
              input_tokens=excluded.input_tokens,output_tokens=excluded.output_tokens,cached_input_tokens=excluded.cached_input_tokens,
              cache_creation_input_tokens=excluded.cache_creation_input_tokens,reasoning_output_tokens=excluded.reasoning_output_tokens,
              total_tokens=excluded.total_tokens,revision=excluded.revision,updated_at_ms=excluded.updated_at_ms;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, hostname); try bind(statement, 2, source); try bind(statement, 3, model); try bind(statement, 4, project); try bind(statement, 5, start)
        try bind(statement, 6, c.input); try bind(statement, 7, c.output); try bind(statement, 8, c.cachedInput); try bind(statement, 9, c.cacheCreationInput); try bind(statement, 10, c.reasoningOutput); try bind(statement, 11, c.total)
        try bind(statement, 12, revision); try bind(statement, 13, millis(Date()))
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
            SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,revision,synced_revision,project
            FROM usage_sessions WHERE hostname=?;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var map: [String: SessionRow] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let session = UsageSession(
                hostname: hostname, source: text(statement, 0), sessionHash: text(statement, 1),
                project: text(statement, 11),
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
            INSERT INTO usage_sessions(hostname,source,session_hash,project,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,revision,synced_revision,updated_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0,?)
            ON CONFLICT(hostname,source,session_hash) DO UPDATE SET
              project=excluded.project,first_activity_ms=excluded.first_activity_ms,last_activity_ms=excluded.last_activity_ms,active_seconds=excluded.active_seconds,
              message_count=excluded.message_count,user_message_count=excluded.user_message_count,assistant_events=excluded.assistant_events,
              hour_histogram=excluded.hour_histogram,revision=excluded.revision,updated_at_ms=excluded.updated_at_ms;
            """
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }
        try bind(statement, 1, session.hostname); try bind(statement, 2, session.source); try bind(statement, 3, session.sessionHash)
        try bind(statement, 4, session.project)
        try bind(statement, 5, millis(session.firstActivity)); try bind(statement, 6, millis(session.lastActivity))
        try bind(statement, 7, session.activeSeconds); try bind(statement, 8, session.messageCount); try bind(statement, 9, session.userMessageCount); try bind(statement, 10, session.assistantEvents)
        try bind(statement, 11, encodeHistogram(session.hourHistogramUTC)); try bind(statement, 12, revision); try bind(statement, 13, millis(Date()))
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
            let bucketLimit = maxBuckets.map { max(0, $0) }
            let sessionLimit = maxSessions.map { max(0, $0) }

            var bucketSQL = "SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,revision FROM usage_buckets WHERE hostname=? AND revision>synced_revision ORDER BY revision,bucket_start_ms,source,model,project"
            if let bucketLimit { bucketSQL += " LIMIT \(bucketLimit + 1)" }
            bucketSQL += ";"
            let bucketStmt = try prepare(bucketSQL); defer { sqlite3_finalize(bucketStmt) }; try bind(bucketStmt, 1, hostname)
            var pendingBuckets: [UsagePendingBucket] = []
            var moreBuckets = false
            while sqlite3_step(bucketStmt) == SQLITE_ROW {
                if let bucketLimit, pendingBuckets.count >= bucketLimit { moreBuckets = true; break }
                let counts = UsageTokenCounts(input: sqlite3_column_int64(bucketStmt, 4), output: sqlite3_column_int64(bucketStmt, 5), cachedInput: sqlite3_column_int64(bucketStmt, 6), cacheCreationInput: sqlite3_column_int64(bucketStmt, 7), reasoningOutput: sqlite3_column_int64(bucketStmt, 8), reportedTotal: sqlite3_column_int64(bucketStmt, 9))
                let bucket = UsageBucket(hostname: hostname, source: text(bucketStmt, 0), model: text(bucketStmt, 1), project: text(bucketStmt, 2), bucketStart: date(sqlite3_column_int64(bucketStmt, 3)), counts: counts)
                pendingBuckets.append(UsagePendingBucket(bucket: bucket, revision: sqlite3_column_int64(bucketStmt, 10)))
            }

            var sessionSQL = "SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,revision,project FROM usage_sessions WHERE hostname=? AND revision>synced_revision ORDER BY revision,source,session_hash"
            if let sessionLimit { sessionSQL += " LIMIT \(sessionLimit + 1)" }
            sessionSQL += ";"
            let sessionStmt = try prepare(sessionSQL); defer { sqlite3_finalize(sessionStmt) }; try bind(sessionStmt, 1, hostname)
            var pendingSessions: [UsagePendingSession] = []
            var moreSessions = false
            while sqlite3_step(sessionStmt) == SQLITE_ROW {
                if let sessionLimit, pendingSessions.count >= sessionLimit { moreSessions = true; break }
                let session = UsageSession(
                    hostname: hostname, source: text(sessionStmt, 0), sessionHash: text(sessionStmt, 1),
                    project: text(sessionStmt, 10),
                    firstActivity: date(sqlite3_column_int64(sessionStmt, 2)), lastActivity: date(sqlite3_column_int64(sessionStmt, 3)),
                    activeSeconds: sqlite3_column_int64(sessionStmt, 4), messageCount: sqlite3_column_int64(sessionStmt, 5),
                    userMessageCount: sqlite3_column_int64(sessionStmt, 6), assistantEvents: sqlite3_column_int64(sessionStmt, 7),
                    hourHistogramUTC: decodeHistogram(text(sessionStmt, 8))
                )
                pendingSessions.append(UsagePendingSession(session: session, revision: sqlite3_column_int64(sessionStmt, 9)))
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
                let bucketSQL = "UPDATE usage_buckets SET synced_revision=?, updated_at_ms=? WHERE hostname=? AND source=? AND model=? AND project=? AND bucket_start_ms=? AND revision=?;"
                let bucketStmt = try prepare(bucketSQL); defer { sqlite3_finalize(bucketStmt) }
                for pending in batch.buckets {
                    let b = pending.bucket
                    sqlite3_reset(bucketStmt); sqlite3_clear_bindings(bucketStmt)
                    try bind(bucketStmt, 1, pending.revision); try bind(bucketStmt, 2, nowMs); try bind(bucketStmt, 3, b.hostname)
                    try bind(bucketStmt, 4, b.source); try bind(bucketStmt, 5, b.model); try bind(bucketStmt, 6, b.project); try bind(bucketStmt, 7, millis(b.bucketStart)); try bind(bucketStmt, 8, pending.revision)
                    try done(bucketStmt)
                }
                let sessionSQL = "UPDATE usage_sessions SET synced_revision=?, updated_at_ms=? WHERE hostname=? AND source=? AND session_hash=? AND revision=?;"
                let sessionStmt = try prepare(sessionSQL); defer { sqlite3_finalize(sessionStmt) }
                for pending in batch.sessions {
                    let s = pending.session
                    sqlite3_reset(sessionStmt); sqlite3_clear_bindings(sessionStmt)
                    try bind(sessionStmt, 1, pending.revision); try bind(sessionStmt, 2, nowMs); try bind(sessionStmt, 3, s.hostname)
                    try bind(sessionStmt, 4, s.source); try bind(sessionStmt, 5, s.sessionHash); try bind(sessionStmt, 6, pending.revision)
                    try done(sessionStmt)
                }
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
            let b = try countUnlocked("SELECT COUNT(*) FROM usage_buckets WHERE hostname=? AND revision>synced_revision;", hostname)
            let s = try countUnlocked("SELECT COUNT(*) FROM usage_sessions WHERE hostname=? AND revision>synced_revision;", hostname)
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
            try readIntUnlocked(key: Self.fullSyncGenerationKey) ?? 0
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
            guard let first = try pendingReconciliationHostsUnlocked().first else { return nil }
            return try readReconciliationReasonUnlocked(hostname: first)
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
                        guard row.revision == pending.revision, row.counts == b.counts else {
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
        let sql = "SELECT source,model,project,bucket_start_ms,input_tokens,output_tokens,cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,total_tokens,revision FROM usage_buckets WHERE hostname=? ORDER BY revision,bucket_start_ms,source,model,project;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsagePendingBucket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let counts = UsageTokenCounts(input: sqlite3_column_int64(statement, 4), output: sqlite3_column_int64(statement, 5), cachedInput: sqlite3_column_int64(statement, 6), cacheCreationInput: sqlite3_column_int64(statement, 7), reasoningOutput: sqlite3_column_int64(statement, 8), reportedTotal: sqlite3_column_int64(statement, 9))
            let bucket = UsageBucket(hostname: hostname, source: text(statement, 0), model: text(statement, 1), project: text(statement, 2), bucketStart: date(sqlite3_column_int64(statement, 3)), counts: counts)
            result.append(UsagePendingBucket(bucket: bucket, revision: sqlite3_column_int64(statement, 10)))
        }
        return result
    }

    /// 读取某 hostname 全部 session 行（含 synced），携带 revision 快照。
    private func readAllSessionPendingUnlocked(hostname: String) throws -> [UsagePendingSession] {
        let sql = "SELECT source,session_hash,first_activity_ms,last_activity_ms,active_seconds,message_count,user_message_count,assistant_events,hour_histogram,revision,project FROM usage_sessions WHERE hostname=? ORDER BY revision,source,session_hash;"
        let statement = try prepare(sql); defer { sqlite3_finalize(statement) }; try bind(statement, 1, hostname)
        var result: [UsagePendingSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let session = UsageSession(
                hostname: hostname, source: text(statement, 0), sessionHash: text(statement, 1),
                project: text(statement, 10),
                firstActivity: date(sqlite3_column_int64(statement, 2)), lastActivity: date(sqlite3_column_int64(statement, 3)),
                activeSeconds: sqlite3_column_int64(statement, 4), messageCount: sqlite3_column_int64(statement, 5),
                userMessageCount: sqlite3_column_int64(statement, 6), assistantEvents: sqlite3_column_int64(statement, 7),
                hourHistogramUTC: decodeHistogram(text(statement, 8))
            )
            result.append(UsagePendingSession(session: session, revision: sqlite3_column_int64(statement, 9)))
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

    /// 显式 rebuild：事务性清空派生 + 原始 + checkpoint（仅显式 rebuild 时调用）。
    /// 随后由协调层清空重扫全部源文件重建，用于修正历史错误时间数据（parserVersion 提升）。
    public func resetForRebuild() throws {
        try queue.sync {
            try transaction {
                // 先把派生表中可能高于 sync_state 的 revision 合并进持久高水位。
                // reset 后新行从高水位继续递增，旧在途 batch 因 revision 不匹配无法误 ack。
                try preserveRevisionHighWatermarksUnlocked()
                try preserveSyncedDeletionBlockUnlocked(reasonPrefix: "parser rebuild")
                try exec("DELETE FROM usage_buckets;")
                try exec("DELETE FROM usage_sessions;")
                try exec("DELETE FROM usage_session_events;")
                try exec("DELETE FROM usage_events;")
                try exec("DELETE FROM usage_files;")
                // full_sync_generation 单调不回退：保留其键，供 generation 围栏在 reset 后仍能拒绝旧在途提交。
                try exec("DELETE FROM sync_state WHERE key NOT LIKE 'revision\u{1}%' AND key NOT LIKE 'remote_reconciliation_required\u{1}%' AND key!='\(Self.fullSyncGenerationKey)';")
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
                // Move any legacy debt to the canonical hostname when known; otherwise drop it,
                // since without a hostname it cannot be reconciled per host anyway.
                try migrateLegacyReconciliationDebtUnlocked()
                try exec("PRAGMA user_version=4;")
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

    private static let schemaV1SQL = """
        CREATE TABLE usage_events(event_id TEXT PRIMARY KEY,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,timestamp_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,session_hash TEXT NOT NULL,source_file_hash TEXT NOT NULL,created_at_ms INTEGER NOT NULL);
        CREATE INDEX idx_usage_events_time ON usage_events(timestamp_ms);
        CREATE TABLE usage_buckets(hostname TEXT NOT NULL,source TEXT NOT NULL,model TEXT NOT NULL,project TEXT NOT NULL,bucket_start_ms INTEGER NOT NULL,input_tokens INTEGER NOT NULL,output_tokens INTEGER NOT NULL,cached_input_tokens INTEGER NOT NULL,cache_creation_input_tokens INTEGER NOT NULL,reasoning_output_tokens INTEGER NOT NULL,total_tokens INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL,PRIMARY KEY(hostname,source,model,project,bucket_start_ms));
        CREATE TABLE usage_files(file_id TEXT PRIMARY KEY,source TEXT NOT NULL,path_hash TEXT NOT NULL,read_offset INTEGER NOT NULL,file_size INTEGER NOT NULL,mtime_ms INTEGER NOT NULL,parser_version INTEGER NOT NULL,scan_status TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
        CREATE TABLE sync_state(key TEXT PRIMARY KEY,value TEXT NOT NULL,updated_at_ms INTEGER NOT NULL);
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
    private static let fullSyncGenerationKey = "full_sync_generation"
    private static let canonicalHostnameKey = "canonical_hostname"

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
        }
        try deleteKeyUnlocked(Self.legacyReconciliationKey)
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
            hosts.append(String(key.dropFirst(prefix.count)))
        }
        return hosts
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
