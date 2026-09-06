import Foundation
import SQLite3

extension UsageLedgerStore {
    func publishParserStageDifferentialUnlocked(fileID: String, hostname: String) throws -> Bool {
        // Apply frozen filter at EOF before publication
        try applyFrozenFilterToTypedStageUnlocked(fileID: fileID, hostname: hostname)
        guard try !parserStageMatchesRawUnlocked(fileID: fileID) else { return false }
        try markParserRowsDirtyUnlocked(fileID: fileID, allRows: true)

        try publishEventsDifferentialUnlocked(fileID: fileID, hostname: hostname)
        try publishSessionsDifferentialUnlocked(fileID: fileID, hostname: hostname)
        try publishEditsDifferentialUnlocked(fileID: fileID, hostname: hostname)

        try markParserRowsDirtyUnlocked(fileID: fileID, allRows: true)

        // The caller clears all staging after state and checkpoint publication.
        return true
    }

    private func publishEventsDifferentialUnlocked(fileID: String, hostname: String) throws {
        if try publishFreshCandidateUnlocked(table: "usage_events", candidate: "usage_stage_events_candidate", fileID: fileID) {
            return
        }

        // 1. DELETE missing
        let deleteStatement = try prepare("""
            DELETE FROM usage_events
            WHERE source_file_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM temp.usage_stage_events_candidate c
                WHERE c.source_file_hash = ? AND c.event_id = usage_events.event_id
              );
            """)
        defer { sqlite3_finalize(deleteStatement) }
        try bind(deleteStatement, 1, fileID); try bind(deleteStatement, 2, fileID); try done(deleteStatement)

        // 2. UPDATE changed (before INSERT new, to avoid re-reading newly inserted rows)
        let updateStatement = try prepare("""
            UPDATE usage_events
            SET
              source = c.source,
              model = c.model,
              project = c.project,
              timestamp_ms = c.timestamp_ms,
              input_tokens = c.input_tokens,
              output_tokens = c.output_tokens,
              cached_input_tokens = c.cached_input_tokens,
              cache_creation_input_tokens = c.cache_creation_input_tokens,
              reasoning_output_tokens = c.reasoning_output_tokens,
              total_tokens = c.total_tokens,
              session_hash = c.session_hash,
              rollout_key = c.rollout_key,
              parent_rollout_key = c.parent_rollout_key,
              inherited = c.inherited,
              has_total_snapshot = c.has_total_snapshot,
              lineage_fingerprint = c.lineage_fingerprint,
              codex_dedup_key = c.codex_dedup_key,
              merge_strategy = c.merge_strategy,
              skill_counts_json = c.skill_counts_json,
              mcp_counts_json = c.mcp_counts_json,
              hostname = c.hostname
            FROM temp.usage_stage_events_candidate c
            WHERE usage_events.source_file_hash = ?
              AND c.source_file_hash = ?
              AND usage_events.event_id = c.event_id
              AND (
                usage_events.source <> c.source OR
                usage_events.model <> c.model OR
                usage_events.project <> c.project OR
                usage_events.timestamp_ms <> c.timestamp_ms OR
                usage_events.input_tokens <> c.input_tokens OR
                usage_events.output_tokens <> c.output_tokens OR
                usage_events.cached_input_tokens <> c.cached_input_tokens OR
                usage_events.cache_creation_input_tokens <> c.cache_creation_input_tokens OR
                usage_events.reasoning_output_tokens <> c.reasoning_output_tokens OR
                usage_events.total_tokens <> c.total_tokens OR
                usage_events.session_hash <> c.session_hash OR
                usage_events.rollout_key <> c.rollout_key OR
                usage_events.parent_rollout_key <> c.parent_rollout_key OR
                usage_events.inherited <> c.inherited OR
                usage_events.has_total_snapshot <> c.has_total_snapshot OR
                usage_events.lineage_fingerprint <> c.lineage_fingerprint OR
                usage_events.codex_dedup_key <> c.codex_dedup_key OR
                usage_events.merge_strategy <> c.merge_strategy OR
                usage_events.skill_counts_json <> c.skill_counts_json OR
                usage_events.mcp_counts_json <> c.mcp_counts_json OR
                usage_events.hostname <> c.hostname
              );
            """)
        defer { sqlite3_finalize(updateStatement) }
        try bind(updateStatement, 1, fileID)
        try bind(updateStatement, 2, fileID)
        try done(updateStatement)

        // 3. INSERT new
        let insertStatement = try prepare("""
            INSERT INTO usage_events(
              event_id,source,model,project,timestamp_ms,input_tokens,output_tokens,
              cached_input_tokens,cache_creation_input_tokens,reasoning_output_tokens,
              total_tokens,session_hash,source_file_hash,rollout_key,parent_rollout_key,
              inherited,has_total_snapshot,lineage_fingerprint,codex_dedup_key,
              merge_strategy,skill_counts_json,mcp_counts_json,hostname,created_at_ms
            )
            SELECT
              c.event_id,c.source,c.model,c.project,c.timestamp_ms,c.input_tokens,c.output_tokens,
              c.cached_input_tokens,c.cache_creation_input_tokens,c.reasoning_output_tokens,
              c.total_tokens,c.session_hash,c.source_file_hash,c.rollout_key,c.parent_rollout_key,
              c.inherited,c.has_total_snapshot,c.lineage_fingerprint,c.codex_dedup_key,
              c.merge_strategy,c.skill_counts_json,c.mcp_counts_json,c.hostname,?
            FROM temp.usage_stage_events_candidate c
            WHERE c.source_file_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM usage_events e
                WHERE e.source_file_hash = ? AND e.event_id = c.event_id
              );
            """)
        defer { sqlite3_finalize(insertStatement) }
        try bind(insertStatement, 1, millis(Date()))
        try bind(insertStatement, 2, fileID)
        try bind(insertStatement, 3, fileID)
        try done(insertStatement)
    }

    private func publishSessionsDifferentialUnlocked(fileID: String, hostname: String) throws {
        if try publishFreshCandidateUnlocked(table: "usage_session_events", candidate: "usage_stage_sessions_candidate", fileID: fileID) {
            return
        }

        // 1. DELETE missing
        let deleteStatement = try prepare("""
            DELETE FROM usage_session_events
            WHERE source_file_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM temp.usage_stage_sessions_candidate c
                WHERE c.source_file_hash = ?
                  AND c.source = usage_session_events.source
                  AND c.event_id = usage_session_events.event_id
              );
            """)
        defer { sqlite3_finalize(deleteStatement) }
        try bind(deleteStatement, 1, fileID); try bind(deleteStatement, 2, fileID); try done(deleteStatement)

        // 2. UPDATE changed (before INSERT new)
        let updateStatement = try prepare("""
            UPDATE usage_session_events
            SET
              session_hash = c.session_hash,
              role = c.role,
              timestamp_ms = c.timestamp_ms,
              hostname = c.hostname
            FROM temp.usage_stage_sessions_candidate c
            WHERE usage_session_events.source_file_hash = ?
              AND c.source_file_hash = ?
              AND usage_session_events.source = c.source
              AND usage_session_events.event_id = c.event_id
              AND (
                usage_session_events.session_hash <> c.session_hash OR
                usage_session_events.role <> c.role OR
                usage_session_events.timestamp_ms <> c.timestamp_ms OR
                usage_session_events.hostname <> c.hostname
              );
            """)
        defer { sqlite3_finalize(updateStatement) }
        try bind(updateStatement, 1, fileID)
        try bind(updateStatement, 2, fileID)
        try done(updateStatement)

        // 3. INSERT new
        let insertStatement = try prepare("""
            INSERT INTO usage_session_events(
              event_id,source,session_hash,role,timestamp_ms,source_file_hash,hostname,created_at_ms
            )
            SELECT
              c.event_id,c.source,c.session_hash,c.role,c.timestamp_ms,c.source_file_hash,c.hostname,?
            FROM temp.usage_stage_sessions_candidate c
            WHERE c.source_file_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM usage_session_events s
                WHERE s.source_file_hash = ?
                  AND s.source = c.source
                  AND s.event_id = c.event_id
              );
            """)
        defer { sqlite3_finalize(insertStatement) }
        try bind(insertStatement, 1, millis(Date()))
        try bind(insertStatement, 2, fileID)
        try bind(insertStatement, 3, fileID)
        try done(insertStatement)
    }

    private func publishEditsDifferentialUnlocked(fileID: String, hostname: String) throws {
        if try publishFreshCandidateUnlocked(table: "usage_edit_entries", candidate: "usage_stage_edits_candidate", fileID: fileID) {
            return
        }

        // 1. DELETE missing
        let deleteStatement = try prepare("""
            DELETE FROM usage_edit_entries
            WHERE source_file_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM temp.usage_stage_edits_candidate c
                WHERE c.source_file_hash = ?
                  AND c.tool_use_id = usage_edit_entries.tool_use_id
              );
            """)
        defer { sqlite3_finalize(deleteStatement) }
        try bind(deleteStatement, 1, fileID); try bind(deleteStatement, 2, fileID); try done(deleteStatement)

        // 2. UPDATE changed (before INSERT new)
        let updateStatement = try prepare("""
            UPDATE usage_edit_entries
            SET
              source = c.source,
              model = c.model,
              project = c.project,
              timestamp_ms = c.timestamp_ms,
              lines_added = c.lines_added,
              lines_deleted = c.lines_deleted,
              hostname = c.hostname
            FROM temp.usage_stage_edits_candidate c
            WHERE usage_edit_entries.source_file_hash = ?
              AND c.source_file_hash = ?
              AND usage_edit_entries.tool_use_id = c.tool_use_id
              AND (
                usage_edit_entries.source <> c.source OR
                usage_edit_entries.model <> c.model OR
                usage_edit_entries.project <> c.project OR
                usage_edit_entries.timestamp_ms <> c.timestamp_ms OR
                usage_edit_entries.lines_added <> c.lines_added OR
                usage_edit_entries.lines_deleted <> c.lines_deleted OR
                usage_edit_entries.hostname <> c.hostname
              );
            """)
        defer { sqlite3_finalize(updateStatement) }
        try bind(updateStatement, 1, fileID)
        try bind(updateStatement, 2, fileID)
        try done(updateStatement)

        // 3. INSERT new
        let insertStatement = try prepare("""
            INSERT INTO usage_edit_entries(
              tool_use_id,source,model,project,timestamp_ms,lines_added,lines_deleted,
              source_file_hash,hostname,created_at_ms
            )
            SELECT
              c.tool_use_id,c.source,c.model,c.project,c.timestamp_ms,c.lines_added,c.lines_deleted,
              c.source_file_hash,c.hostname,?
            FROM temp.usage_stage_edits_candidate c
            WHERE c.source_file_hash = ?
              AND NOT EXISTS (
                SELECT 1 FROM usage_edit_entries e
                WHERE e.source_file_hash = ?
                  AND e.tool_use_id = c.tool_use_id
              );
            """)
        defer { sqlite3_finalize(insertStatement) }
        try bind(insertStatement, 1, millis(Date()))
        try bind(insertStatement, 2, fileID)
        try bind(insertStatement, 3, fileID)
        try done(insertStatement)
    }
}
