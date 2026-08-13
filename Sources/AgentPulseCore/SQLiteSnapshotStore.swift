import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 可被 SQLiteSnapshotStore 持久化的快照抽象。
/// 存储层只依赖稳定索引列(id/timestamp)与 Codable JSON payload，不绑定业务字段；
/// 可选的 sourceIdentifier 提供来源过滤所需的索引列，默认无来源索引。
public protocol SnapshotPersistable: Codable, Sendable {
    var id: UUID { get }
    var timestamp: Date { get }
    /// 用于 source 过滤的索引键；返回 nil 表示该类型不参与来源过滤。
    var sourceIdentifier: String? { get }
}

public extension SnapshotPersistable {
    /// 默认不提供来源索引，避免强制业务模型暴露字符串来源。
    var sourceIdentifier: String? { nil }
}

/// 将正式模型 PulseSnapshot 接入存储层：以其来源枚举原始值作为索引列。
/// 该 conformance 定义在存储层文件内，不改动模型定义本身。
extension PulseSnapshot: SnapshotPersistable {
    public var sourceIdentifier: String? { source.rawValue }
}

/// 存储层错误，全部显式暴露，禁止吞错。
public enum SQLiteSnapshotStoreError: Error, Equatable, CustomStringConvertible {
    case openFailed(code: Int32, message: String)
    case executeFailed(sql: String, code: Int32, message: String)
    case prepareFailed(sql: String, code: Int32, message: String)
    case bindFailed(index: Int32, code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case corruptRow(reason: String)
    case codingFailed(underlying: String)

    public var description: String {
        switch self {
        case let .openFailed(code, message):
            return "openFailed(code: \(code), message: \(message))"
        case let .executeFailed(sql, code, message):
            return "executeFailed(sql: \(sql), code: \(code), message: \(message))"
        case let .prepareFailed(sql, code, message):
            return "prepareFailed(sql: \(sql), code: \(code), message: \(message))"
        case let .bindFailed(index, code, message):
            return "bindFailed(index: \(index), code: \(code), message: \(message))"
        case let .stepFailed(code, message):
            return "stepFailed(code: \(code), message: \(message))"
        case let .corruptRow(reason):
            return "corruptRow(reason: \(reason))"
        case let .codingFailed(underlying):
            return "codingFailed(underlying: \(underlying))"
        }
    }
}

/// 闭区间时间范围。
public struct SnapshotTimeRange: Sendable, Equatable {
    public let start: Date
    public let end: Date

    /// 若 start 晚于 end 会自动规整为有序区间，避免误传导致空结果被误判为无数据。
    public init(start: Date, end: Date) {
        if start <= end {
            self.start = start
            self.end = end
        } else {
            self.start = end
            self.end = start
        }
    }
}

/// 基于系统 SQLite3 的快照持久化存储。所有数据库访问串行化到专用队列。
public final class SQLiteSnapshotStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue: DispatchQueue
    private static let tableName = "snapshots"

    /// 打开(或创建)指定路径数据库并初始化 schema。传入 ":memory:" 使用内存库。
    public init(path: String) throws {
        self.queue = DispatchQueue(label: "com.agentpulse.sqlite.\(UUID().uuidString)")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(path, &handle, flags, nil)
        guard openResult == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let h = handle { sqlite3_close_v2(h) }
            throw SQLiteSnapshotStoreError.openFailed(code: openResult, message: message)
        }
        self.db = opened
        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try execute(
                "CREATE TABLE IF NOT EXISTS \(Self.tableName) (" +
                "id TEXT PRIMARY KEY NOT NULL, " +
                "timestamp_ms INTEGER NOT NULL, " +
                "source TEXT, " +
                "payload TEXT NOT NULL" +
                ");"
            )
            try execute(
                "CREATE INDEX IF NOT EXISTS idx_\(Self.tableName)_timestamp " +
                "ON \(Self.tableName)(timestamp_ms);"
            )
        } catch {
            sqlite3_close_v2(opened)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Public API

    /// 插入或按主键覆盖写入一条快照。
    public func upsert<S: SnapshotPersistable>(_ snapshot: S) throws {
        try upsert(contentsOf: [snapshot])
    }

    /// 批量写入，整体事务；任一失败即回滚。
    public func upsert<S: SnapshotPersistable>(contentsOf snapshots: [S]) throws {
        guard !snapshots.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try queue.sync {
            try withinTransaction {
                let sql = "INSERT OR REPLACE INTO \(Self.tableName) " +
                    "(id, timestamp_ms, source, payload) VALUES (?, ?, ?, ?);"
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                for snapshot in snapshots {
                    let payloadData: Data
                    do {
                        payloadData = try encoder.encode(snapshot)
                    } catch {
                        throw SQLiteSnapshotStoreError.codingFailed(underlying: "\(error)")
                    }
                    guard let payloadString = String(data: payloadData, encoding: .utf8) else {
                        throw SQLiteSnapshotStoreError.codingFailed(underlying: "payload not valid UTF-8")
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    try bindText(statement, 1, snapshot.id.uuidString)
                    try bindInt(statement, 2, Self.millis(from: snapshot.timestamp))
                    if let source = snapshot.sourceIdentifier {
                        try bindText(statement, 3, source)
                    } else {
                        try bindNull(statement, 3)
                    }
                    try bindText(statement, 4, payloadString)
                    let step = sqlite3_step(statement)
                    guard step == SQLITE_DONE else {
                        throw SQLiteSnapshotStoreError.stepFailed(code: step, message: self.errmsg())
                    }
                }
            }
        }
    }

    /// 按时间范围(闭区间)查询，可选按来源过滤，按时间升序返回。
    public func query<S: SnapshotPersistable>(
        _ type: S.Type,
        in range: SnapshotTimeRange? = nil,
        source: String? = nil
    ) throws -> [S] {
        let decoder = JSONDecoder()
        return try queue.sync {
            var sql = "SELECT payload FROM \(Self.tableName)"
            var clauses: [String] = []
            if range != nil { clauses.append("timestamp_ms >= ? AND timestamp_ms <= ?") }
            if source != nil { clauses.append("source = ?") }
            if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
            sql += " ORDER BY timestamp_ms ASC, id ASC;"

            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var nextIndex: Int32 = 1
            if let range {
                try bindInt(statement, nextIndex, Self.millis(from: range.start)); nextIndex += 1
                try bindInt(statement, nextIndex, Self.millis(from: range.end)); nextIndex += 1
            }
            if let source {
                try bindText(statement, nextIndex, source); nextIndex += 1
            }

            var results: [S] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    guard let cString = sqlite3_column_text(statement, 0) else {
                        throw SQLiteSnapshotStoreError.corruptRow(reason: "payload column is NULL")
                    }
                    let json = String(cString: cString)
                    guard let data = json.data(using: .utf8) else {
                        throw SQLiteSnapshotStoreError.corruptRow(reason: "payload not valid UTF-8")
                    }
                    do {
                        results.append(try decoder.decode(S.self, from: data))
                    } catch {
                        throw SQLiteSnapshotStoreError.codingFailed(underlying: "\(error)")
                    }
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteSnapshotStoreError.stepFailed(code: step, message: self.errmsg())
                }
            }
            return results
        }
    }

    /// 统计快照总数。
    public func count() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM \(Self.tableName);")
            defer { sqlite3_finalize(statement) }
            let step = sqlite3_step(statement)
            guard step == SQLITE_ROW else {
                throw SQLiteSnapshotStoreError.stepFailed(code: step, message: self.errmsg())
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// 保留策略：删除早于 cutoff 的快照，返回删除行数。
    @discardableResult
    public func deleteSnapshots(olderThan cutoff: Date) throws -> Int {
        try queue.sync {
            let sql = "DELETE FROM \(Self.tableName) WHERE timestamp_ms < ?;"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindInt(statement, 1, Self.millis(from: cutoff))
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE else {
                throw SQLiteSnapshotStoreError.stepFailed(code: step, message: self.errmsg())
            }
            return Int(sqlite3_changes(db))
        }
    }

    /// 保留策略：仅保留最近 maxCount 条(按时间倒序)，删除其余，返回删除行数。
    @discardableResult
    public func enforceRetention(maxCount: Int) throws -> Int {
        guard maxCount >= 0 else {
            throw SQLiteSnapshotStoreError.executeFailed(
                sql: "enforceRetention", code: SQLITE_MISUSE, message: "maxCount must be >= 0"
            )
        }
        return try queue.sync {
            let sql = "DELETE FROM \(Self.tableName) WHERE id NOT IN (" +
                "SELECT id FROM \(Self.tableName) ORDER BY timestamp_ms DESC, id DESC LIMIT ?" +
                ");"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindInt(statement, 1, Int64(maxCount))
            let step = sqlite3_step(statement)
            guard step == SQLITE_DONE else {
                throw SQLiteSnapshotStoreError.stepFailed(code: step, message: self.errmsg())
            }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Private helpers (queue-confined)

    private func withinTransaction(_ body: () throws -> Void) throws {
        try execUnlocked("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            try execUnlocked("COMMIT;")
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func execUnlocked(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errmsg()
            if let errorPointer { sqlite3_free(errorPointer) }
            throw SQLiteSnapshotStoreError.executeFailed(sql: sql, code: result, message: message)
        }
    }

    private func execute(_ sql: String) throws {
        try execUnlocked(sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK, statement != nil else {
            let message = errmsg()
            if let statement { sqlite3_finalize(statement) }
            throw SQLiteSnapshotStoreError.prepareFailed(sql: sql, code: result, message: message)
        }
        return statement
    }

    private func bindText(_ statement: OpaquePointer?, _ index: Int32, _ value: String) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        guard result == SQLITE_OK else {
            throw SQLiteSnapshotStoreError.bindFailed(index: index, code: result, message: errmsg())
        }
    }

    private func bindInt(_ statement: OpaquePointer?, _ index: Int32, _ value: Int64) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else {
            throw SQLiteSnapshotStoreError.bindFailed(index: index, code: result, message: errmsg())
        }
    }

    private func bindNull(_ statement: OpaquePointer?, _ index: Int32) throws {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw SQLiteSnapshotStoreError.bindFailed(index: index, code: result, message: errmsg())
        }
    }

    private func errmsg() -> String {
        guard let db else { return "no database handle" }
        return String(cString: sqlite3_errmsg(db))
    }

    private static func millis(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}
