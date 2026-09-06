import Foundation
import SQLite3

extension UsageLedgerStore {
    /// Compare before mutation so a changed generation can still mark its old
    /// owners and buckets. The private candidate schema excludes created_at_ms.
    func parserStageMatchesRawUnlocked(fileID: String) throws -> Bool {
        for (table, candidate, identity) in [
            ("usage_events", "usage_stage_events_candidate", ["event_id"]),
            ("usage_session_events", "usage_stage_sessions_candidate", ["source", "event_id"]),
            ("usage_edit_entries", "usage_stage_edits_candidate", ["tool_use_id"])
        ] {
            let columns = try candidateColumnsUnlocked(candidate)
            let join = (["source_file_hash"] + identity).map { "r.\($0)=c.\($0)" }.joined(separator: " AND ")
            let different = columns.map { "r.\($0) IS NOT c.\($0)" }.joined(separator: " OR ")
            let statement = try prepare("""
                SELECT 1 FROM \(table) r
                LEFT JOIN temp.\(candidate) c ON \(join)
                WHERE r.source_file_hash=? AND (c.source_file_hash IS NULL OR \(different))
                UNION ALL
                SELECT 1 FROM temp.\(candidate) c
                LEFT JOIN \(table) r ON \(join)
                WHERE c.source_file_hash=? AND r.source_file_hash IS NULL
                LIMIT 1;
                """)
            defer { sqlite3_finalize(statement) }
            try bind(statement, 1, fileID); try bind(statement, 2, fileID)
            if try step(statement) == SQLITE_ROW { return false }
        }
        return true
    }

    /// A new file has no old generation to compare. Both checks and insertion
    /// run under the caller's IMMEDIATE transaction, so this cannot race a writer.
    func publishFreshCandidateUnlocked(table: String, candidate: String, fileID: String) throws -> Bool {
        let existing = try prepare("SELECT 1 FROM \(table) WHERE source_file_hash=? LIMIT 1;")
        defer { sqlite3_finalize(existing) }
        try bind(existing, 1, fileID)
        if try step(existing) == SQLITE_ROW { return false }

        // Candidate columns are the normalized durable fields, excluding the
        // insertion timestamp. Derive the projection from that private schema
        // so adding a candidate field cannot silently omit it on the fresh path.
        let projection = try candidateColumnsUnlocked(candidate).joined(separator: ",")
        let insert = try prepare("""
            INSERT INTO \(table)(\(projection),created_at_ms)
            SELECT \(projection),? FROM temp.\(candidate) WHERE source_file_hash=?;
            """)
        defer { sqlite3_finalize(insert) }
        try bind(insert, 1, millis(Date()))
        try bind(insert, 2, fileID)
        try done(insert)
        return true
    }

    private func candidateColumnsUnlocked(_ candidate: String) throws -> [String] {
        let fields = try prepare("PRAGMA temp.table_info(\(candidate));")
        defer { sqlite3_finalize(fields) }
        var columns: [String] = []
        while try step(fields) == SQLITE_ROW {
            columns.append("\"" + text(fields, 1).replacingOccurrences(of: "\"", with: "\"\"") + "\"")
        }
        guard !columns.isEmpty else { throw UsageLedgerError.sqlite("publication candidate schema missing") }
        return columns
    }
}
