import SQLite3

extension UsageLedgerStore {
    static let compactedNetworkEventsSchema = """
        CREATE TABLE IF NOT EXISTS usage_compacted_network_events(
            source TEXT NOT NULL,
            event_id TEXT NOT NULL,
            PRIMARY KEY(source, event_id)
        ) WITHOUT ROWID;
        """

    func eligibleNetworkEventsUnlocked(
        _ events: [UsageEvent], source: String, hostname: String
    ) throws -> [UsageEvent] {
        guard !events.isEmpty, source == AsterUsageService.source || source == AntigravityUsageCollector.source
        else { return events }
        let statement = try prepare("""
            SELECT NOT EXISTS (
                SELECT 1 FROM usage_events WHERE source_file_hash=?1 AND event_id=?2 AND hostname<>?3
            ) AND NOT EXISTS (
                SELECT 1 FROM usage_compacted_network_events WHERE source=?4 AND event_id=?2
            );
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, "network\u{1}\(source)")
        try bind(statement, 3, hostname)
        try bind(statement, 4, source)
        return try events.filter { event in
            sqlite3_reset(statement)
            try bind(statement, 2, event.id)
            return try step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) != 0
        }
    }

    func compactFrozenUsageEventsUnlocked(frozen: Int64, limit: Int) throws -> Int64 {
        // An adopted hostname may leave old-host buckets with a lower
        // watermark. Keep those rows available for a later recomputation.
        let eligibleBatch = """
            FROM usage_events INDEXED BY idx_usage_events_time
            WHERE timestamp_ms < ?1
              AND (
                source_file_hash NOT IN (?3,?4) OR timestamp_ms < COALESCE(
                    (SELECT CAST(value AS INTEGER) FROM sync_state WHERE key=(?5 || usage_events.hostname)), 0
                )
              )
            ORDER BY timestamp_ms, rowid
            LIMIT ?2
            """
        // Both statements select the same ordered batch within one write
        // transaction, so a crash cannot delete a hashed ID before saving it.
        let remember = try prepare("""
            INSERT OR IGNORE INTO usage_compacted_network_events(source,event_id)
            SELECT source,event_id FROM (SELECT source,event_id,source_file_hash \(eligibleBatch))
            WHERE source_file_hash IN (?3,?4);
            """)
        defer { sqlite3_finalize(remember) }
        try bindCompactionBatchUnlocked(remember, frozen: frozen, limit: limit)
        try done(remember)

        let delete = try prepare("DELETE FROM usage_events WHERE rowid IN (SELECT rowid \(eligibleBatch));")
        defer { sqlite3_finalize(delete) }
        try bindCompactionBatchUnlocked(delete, frozen: frozen, limit: limit)
        try done(delete)
        return Int64(sqlite3_changes(db))
    }

    private func bindCompactionBatchUnlocked(_ statement: OpaquePointer?, frozen: Int64, limit: Int) throws {
        try bind(statement, 1, frozen)
        try bind(statement, 2, Int64(limit))
        try bind(statement, 3, "network\u{1}\(AsterUsageService.source)")
        try bind(statement, 4, "network\u{1}\(AntigravityUsageCollector.source)")
        try bind(statement, 5, Self.frozenBeforeKeyPrefix)
    }
}
