import Foundation
import SQLite3

extension UsageLedgerStore {
    private func antigravityRevisionKey(_ databaseID: String) -> String {
        "antigravity_database_v1\u{1}\(databaseID)"
    }

    func antigravityRevision(for databaseID: String) throws -> String? {
        try queue.sync {
            try readTextUnlocked(key: antigravityRevisionKey(databaseID))
        }
    }

    func commitAntigravityEvents(
        _ events: [UsageEvent], databaseID: String, revision: String?, hostname: String
    ) throws {
        try queue.sync {
            try transaction {
                let key = antigravityRevisionKey(databaseID)
                if let revision, try readTextUnlocked(key: key) == revision { return }
                let source = AntigravityUsageCollector.source
                let improved = try antigravityChangedEventsUnlocked(events, hostname: hostname)
                try recordNetworkEventsUnlocked(improved, source: source, hostname: hostname)
                if let revision {
                    try setTextUnlocked(key: key, value: revision)
                } else {
                    try deleteKeyUnlocked(key)
                }
            }
        }
    }

    private func antigravityChangedEventsUnlocked(_ events: [UsageEvent], hostname: String) throws -> [UsageEvent] {
        guard !events.isEmpty else { return [] }
        let source = AntigravityUsageCollector.source
        let statement = try prepare("""
            SELECT hostname, total_tokens, timestamp_ms, model, project, session_hash
            FROM usage_events WHERE source_file_hash=? AND event_id=?;
            """)
        defer { sqlite3_finalize(statement) }
        return try events.compactMap { event in
            sqlite3_reset(statement)
            try bind(statement, 1, "network\u{1}\(source)")
            try bind(statement, 2, event.id)
            guard try step(statement) == SQLITE_ROW else { return event }
            guard text(statement, 0) == hostname, event.counts.total > sqlite3_column_int64(statement, 1) else { return nil }
            // The reporting protocol upserts buckets and cannot retire a prior
            // natural key when a mirror disagrees on attribution or time.
            return UsageEvent(
                id: event.id, source: source, model: text(statement, 3), project: text(statement, 4),
                timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 2)) / 1_000),
                counts: event.counts, sessionHash: text(statement, 5), sourceFileHash: ""
            )
        }
    }

}
