import SQLite3

extension UsageLedgerStore {
    /// Called inside the file publication transaction. Missing state keys must
    /// disappear, while identical values retain their existing database pages.
    func publishParserStateDifferentialUnlocked(fileID: String) throws {
        let remove = try prepare("""
            DELETE FROM usage_parser_state
            WHERE file_id=? AND NOT EXISTS (
                SELECT 1 FROM temp.usage_parser_stage AS staged
                WHERE staged.file_id=usage_parser_state.file_id
                  AND staged.kind='state' AND staged.key=usage_parser_state.key
            );
            """)
        defer { sqlite3_finalize(remove) }
        try bind(remove, 1, fileID)
        try done(remove)

        let publish = try prepare("""
            INSERT INTO usage_parser_state(file_id,key,value)
            SELECT file_id,key,value FROM temp.usage_parser_stage
            WHERE file_id=? AND kind='state'
            ON CONFLICT(file_id,key) DO UPDATE SET value=excluded.value
            WHERE usage_parser_state.value IS NOT excluded.value;
            """)
        defer { sqlite3_finalize(publish) }
        try bind(publish, 1, fileID)
        try done(publish)
    }
}
