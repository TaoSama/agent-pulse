import Foundation
import SQLite3

extension UsageLedgerStore {
    /// Ready markers are connection-local metadata, never durable checkpoints.
    func markParserReplacementReadyUnlocked(_ checkpoint: UsageFileCheckpoint) throws {
        let statement = try prepare("INSERT INTO temp.usage_parser_ready(file_id,checkpoint) VALUES(?,?);")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, checkpoint.fileID)
        try bindParserBlob(statement, index: 2, value: JSONEncoder().encode(checkpoint))
        try done(statement)
    }

    func parserReplacementIsReadyUnlocked(fileID: String) throws -> Bool {
        let statement = try prepare("SELECT 1 FROM temp.usage_parser_ready WHERE file_id=?;")
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, fileID)
        return try step(statement) == SQLITE_ROW
    }

    func publishParserReplacementUnlocked(_ checkpoint: UsageFileCheckpoint, hostname: String) throws {
        let fileID = checkpoint.fileID
        let rawChanged = try publishParserStageDifferentialUnlocked(fileID: fileID, hostname: hostname)
        try publishParserStateDifferentialUnlocked(fileID: fileID)
        try finishParserBatchUnlocked(checkpoint, hostname: hostname, rawChanged: rawChanged)
        try abortParserReplacementUnlocked(fileID: fileID)
    }

    /// All requested files publish atomically. A failure retains every ready marker
    /// through rollback; callers must not advance their checkpoint cache on error.
    func publishReadyParserReplacements(fileIDs: [String], hostname: String) throws -> [UsageFileCheckpoint] {
        guard !fileIDs.isEmpty else { return [] }
        guard Set(fileIDs).count == fileIDs.count else { throw UsageLedgerError.invalidCheckpoint }
        return try queue.sync {
            var committed: [UsageFileCheckpoint] = []
            let decoder = JSONDecoder()
            try transaction {
                for fileID in fileIDs {
                    let statement = try prepare("""
                        SELECT ready.checkpoint,owner.hostname
                        FROM temp.usage_parser_ready ready
                        JOIN temp.usage_parser_replacements owner ON owner.file_id=ready.file_id
                        WHERE ready.file_id=?;
                        """)
                    defer { sqlite3_finalize(statement) }
                    try bind(statement, 1, fileID)
                    guard try step(statement) == SQLITE_ROW, text(statement, 1) == hostname else {
                        throw UsageLedgerError.invalidCheckpoint
                    }
                    let checkpoint = try decoder.decode(UsageFileCheckpoint.self, from: parserBlob(statement, column: 0))
                    guard checkpoint.fileID == fileID, checkpoint.offset >= 0, checkpoint.offset <= checkpoint.size else {
                        throw UsageLedgerError.invalidCheckpoint
                    }
                    try publishParserReplacementUnlocked(checkpoint, hostname: hostname)
                    committed.append(checkpoint)
                }
            }
            return committed
        }
    }

    func abortParserReplacements(fileIDs: [String]) throws {
        guard !fileIDs.isEmpty else { return }
        try queue.sync {
            try transaction {
                for fileID in fileIDs { try abortParserReplacementUnlocked(fileID: fileID) }
            }
        }
    }
}
