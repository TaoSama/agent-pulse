import Foundation
import SQLite3

extension UsageLedgerStore {
    func initializeTypedStageTablesUnlocked() throws {
        try exec("""
        CREATE TEMP TABLE IF NOT EXISTS usage_stage_events_candidate(
          event_id TEXT NOT NULL,
          source TEXT NOT NULL,
          model TEXT NOT NULL,
          project TEXT NOT NULL,
          timestamp_ms INTEGER NOT NULL,
          input_tokens INTEGER NOT NULL,
          output_tokens INTEGER NOT NULL,
          cached_input_tokens INTEGER NOT NULL,
          cache_creation_input_tokens INTEGER NOT NULL,
          reasoning_output_tokens INTEGER NOT NULL,
          total_tokens INTEGER NOT NULL,
          session_hash TEXT NOT NULL,
          source_file_hash TEXT NOT NULL,
          rollout_key TEXT NOT NULL DEFAULT '',
          parent_rollout_key TEXT NOT NULL DEFAULT '',
          inherited INTEGER NOT NULL DEFAULT 0,
          has_total_snapshot INTEGER NOT NULL DEFAULT 0,
          lineage_fingerprint TEXT NOT NULL DEFAULT '',
          codex_dedup_key TEXT NOT NULL DEFAULT '',
          merge_strategy TEXT NOT NULL DEFAULT 'overwrite',
          skill_counts_json TEXT NOT NULL DEFAULT '{}',
          mcp_counts_json TEXT NOT NULL DEFAULT '{}',
          hostname TEXT NOT NULL DEFAULT '',
          PRIMARY KEY(source_file_hash, event_id)
        ) WITHOUT ROWID;

        CREATE TEMP TABLE IF NOT EXISTS usage_stage_sessions_candidate(
          event_id TEXT NOT NULL,
          source TEXT NOT NULL,
          session_hash TEXT NOT NULL,
          role TEXT NOT NULL,
          timestamp_ms INTEGER NOT NULL,
          source_file_hash TEXT NOT NULL DEFAULT '',
          hostname TEXT NOT NULL DEFAULT '',
          PRIMARY KEY(source_file_hash, event_id)
        ) WITHOUT ROWID;

        CREATE TEMP TABLE IF NOT EXISTS usage_stage_edits_candidate(
          tool_use_id TEXT NOT NULL,
          source TEXT NOT NULL,
          model TEXT NOT NULL,
          project TEXT NOT NULL,
          timestamp_ms INTEGER NOT NULL,
          lines_added INTEGER NOT NULL,
          lines_deleted INTEGER NOT NULL,
          source_file_hash TEXT NOT NULL DEFAULT '',
          hostname TEXT NOT NULL DEFAULT '',
          PRIMARY KEY(source_file_hash, tool_use_id)
        ) WITHOUT ROWID;
        """)
    }

    func abortTypedParserStageUnlocked(fileID: String) throws {
        let tables = [
            "temp.usage_stage_events_candidate",
            "temp.usage_stage_sessions_candidate",
            "temp.usage_stage_edits_candidate"
        ]
        for table in tables {
            let statement = try prepare("DELETE FROM \(table) WHERE source_file_hash=?;")
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, fileID); try done(statement)
        }
    }

    func resetTypedParserStageUnlocked() throws {
        try exec("""
        DELETE FROM temp.usage_stage_events_candidate;
        DELETE FROM temp.usage_stage_sessions_candidate;
        DELETE FROM temp.usage_stage_edits_candidate;
        """)
    }

    func stageTypedEventsUnlocked(_ events: [UsageEvent], fileID: String, hostname: String) throws {
        guard !events.isEmpty else { return }
        let insertSQL = """
            INSERT OR REPLACE INTO temp.usage_stage_events_candidate(
              event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,
              cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,
              total_tokens,session_hash,source_file_hash,rollout_key,parent_rollout_key,
              inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,
              merge_strategy,skill_counts_json,mcp_counts_json,hostname
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
        let insert = try prepare(insertSQL)
        defer { sqlite3_finalize(insert) }

        for event in events {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            let c = event.counts
            let skillCounts = UsageToolMetrics.normalizeCounts(event.skillCounts)
            let mcpCounts = UsageToolMetrics.normalizeCounts(event.mcpCounts)

            try bind(insert, 1, event.id)
            try bind(insert, 2, event.source)
            try bind(insert, 3, event.model)
            try bind(insert, 4, event.project)
            try bind(insert, 5, millis(event.timestamp))
            try bind(insert, 6, c.input)
            try bind(insert, 7, c.output)
            try bind(insert, 8, c.cachedInput)
            try bind(insert, 9, c.cacheCreationInput)
            try bind(insert, 10, c.reasoningOutput)
            try bind(insert, 11, c.total)
            try bind(insert, 12, event.sessionHash)
            try bind(insert, 13, fileID)
            try bind(insert, 14, event.rolloutKey)
            try bind(insert, 15, event.parentRolloutKey)
            try bind(insert, 16, event.inherited ? 1 : 0)
            try bind(insert, 17, event.hasTotalSnapshot ? 1 : 0)
            try bind(insert, 18, event.lineageFingerprint)
            try bind(insert, 19, event.codexDedupKey)
            try bind(insert, 20, event.mergeStrategy.rawValue)
            try bind(insert, 21, encodeStringIntMap(skillCounts))
            try bind(insert, 22, encodeStringIntMap(mcpCounts))
            try bind(insert, 23, hostname)
            try done(insert)
        }
    }

    func stageTypedSessionsUnlocked(_ sessions: [UsageSessionEvent], fileID: String, hostname: String) throws {
        guard !sessions.isEmpty else { return }
        let insertSQL = """
            INSERT OR REPLACE INTO temp.usage_stage_sessions_candidate(
              event_id,source,session_hash,role,timestamp_ms,source_file_hash,hostname
            ) VALUES(?,?,?,?,?,?,?);
            """
        let insert = try prepare(insertSQL)
        defer { sqlite3_finalize(insert) }

        for session in sessions {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, session.id)
            try bind(insert, 2, session.source)
            try bind(insert, 3, session.sessionHash)
            try bind(insert, 4, session.role.rawValue)
            try bind(insert, 5, millis(session.timestamp))
            try bind(insert, 6, fileID)
            try bind(insert, 7, hostname)
            try done(insert)
        }
    }

    func stageTypedEditsUnlocked(_ edits: [UsageEditEntry], fileID: String, hostname: String) throws {
        guard !edits.isEmpty else { return }
        let insertSQL = """
            INSERT OR REPLACE INTO temp.usage_stage_edits_candidate(
              tool_use_id,source,model,project,timestamp_ms,lines_added,lines_deleted,
              source_file_hash,hostname
            ) VALUES(?,?,?,?,?,?,?,?,?);
            """
        let insert = try prepare(insertSQL)
        defer { sqlite3_finalize(insert) }

        for entry in edits where !entry.toolUseID.isEmpty {
            sqlite3_reset(insert); sqlite3_clear_bindings(insert)
            try bind(insert, 1, entry.toolUseID)
            try bind(insert, 2, entry.source)
            try bind(insert, 3, entry.model)
            try bind(insert, 4, entry.project)
            try bind(insert, 5, millis(entry.timestamp))
            try bind(insert, 6, entry.added)
            try bind(insert, 7, entry.deleted)
            try bind(insert, 8, fileID)
            try bind(insert, 9, hostname)
            try done(insert)
        }
    }

    func deleteTypedStageRemovedEventsUnlocked(_ ids: [String], fileID: String) throws {
        guard !ids.isEmpty else { return }
        let statement = try prepare("DELETE FROM temp.usage_stage_events_candidate WHERE source_file_hash=? AND event_id=?;")
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(statement, 1, fileID); try bind(statement, 2, id); try done(statement)
        }
    }

    func deleteTypedStageRemovedEditsUnlocked(_ ids: [String], fileID: String) throws {
        guard !ids.isEmpty else { return }
        let statement = try prepare("DELETE FROM temp.usage_stage_edits_candidate WHERE source_file_hash=? AND tool_use_id=?;")
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
            try bind(statement, 1, fileID); try bind(statement, 2, id); try done(statement)
        }
    }

    func backfillTypedStageUnknownModelUnlocked(fileID: String, model: String) throws {
        let statement = try prepare("""
            UPDATE temp.usage_stage_events_candidate SET model=?
            WHERE source_file_hash=? AND event_id IN (
              SELECT json_extract(CAST(value AS TEXT),'$') FROM temp.usage_parser_stage
              WHERE file_id=? AND kind='state' AND key>='codex-unknown:' AND key<'codex-unknown;'
            );
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, model); try bind(statement, 2, fileID); try bind(statement, 3, fileID); try done(statement)
    }

    func applyFrozenFilterToTypedStageUnlocked(fileID: String, hostname: String) throws {
        let frozen = try frozenBeforeMsUnlocked(hostname)
        guard frozen > 0 else { return }

        // Count the actual deletions in the publication transaction instead of
        // walking both candidate ranges once to count and again to delete.
        let delEvents = try prepare("DELETE FROM temp.usage_stage_events_candidate WHERE source_file_hash=? AND timestamp_ms < ?;")
        defer { sqlite3_finalize(delEvents) }
        try bind(delEvents, 1, fileID); try bind(delEvents, 2, frozen); try done(delEvents)
        let droppedEvents = sqlite3_changes64(db)

        let delSessions = try prepare("DELETE FROM temp.usage_stage_sessions_candidate WHERE source_file_hash=? AND timestamp_ms < ?;")
        defer { sqlite3_finalize(delSessions) }
        try bind(delSessions, 1, fileID); try bind(delSessions, 2, frozen); try done(delSessions)
        let droppedSessions = sqlite3_changes64(db)

        let totalDropped = droppedEvents + droppedSessions
        if totalDropped > 0 {
            let key = frozenDroppedEventsKey(hostname)
            try setIntUnlocked(key: key, value: (try readIntUnlocked(key: key) ?? 0) + totalDropped)
        }
    }
}
