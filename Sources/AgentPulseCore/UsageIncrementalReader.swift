import Foundation

public struct UsageIncrementalBatch: Sendable {
    public let parsed: ParsedUsageFile
    public let stateChanges: UsageParserStateChanges
    public let removedEventIDs: [String]
    public let removedEditIDs: [String]
    public let replacesFile: Bool
    public let isFinalBatch: Bool
    public let codexUnknownModel: String?

    public init(parsed: ParsedUsageFile, stateChanges: UsageParserStateChanges,
                removedEventIDs: [String], removedEditIDs: [String],
                replacesFile: Bool, isFinalBatch: Bool, codexUnknownModel: String? = nil) {
        self.parsed = parsed; self.stateChanges = stateChanges
        self.removedEventIDs = removedEventIDs; self.removedEditIDs = removedEditIDs
        self.replacesFile = replacesFile; self.isFinalBatch = isFinalBatch
        self.codexUnknownModel = codexUnknownModel
    }
}

public struct UsageIncrementalReadResult: Sendable {
    public let bytesRead: Int64
    public let committedOffset: Int64
    public let batchCount: Int
}

public enum UsageIncrementalReadError: Error {
    case invalidFile, fileChangedDuringRead, invalidState, requiresRebuild
}

struct UsageStreamCursor: Codable {
    var version: Int
    var fileNumber: UInt64
    var creationDate: Date
    var offset: Int64
    var lineCount: Int
    var tailHash: String
    var tailLength: Int
    var prefixHash: String
    var prefixLength: Int
    var endedWithoutNewline: Bool
}

extension UsageJSONLParser {
    private static let readChunkBytes = 256 * 1024
    private static let batchBytes = 1024 * 1024
    private static let guardBytes = 256

    /// Reads complete JSONL records from the last committed offset. Each callback
    /// must atomically save the batch and its state before returning. Memory is
    /// bounded by a batch plus the largest individual record and touched identities.
    /// Unterminated records stay in the source file and are retried after append.
    public static func readIncrementally(
        fileURL: URL,
        source: String,
        fileIdentity: String,
        isSubagent: Bool = false,
        previousCheckpoint: UsageFileCheckpoint?,
        stateLookup: @escaping (String) throws -> Data?,
        onBatch: (UsageIncrementalBatch) throws -> Void,
        checkCancellation: () throws -> Void = {}
    ) throws -> UsageIncrementalReadResult {
        let handle = try UsageIncrementalFileGuard.open(fileURL: fileURL)
        defer { handle.closeFile() }
        var fileGuard = try UsageIncrementalFileGuard(handle: handle, fileURL: fileURL)
        let size = fileGuard.size
        let modified = fileGuard.modifiedAt
        let prefix = try fileGuard.read(offset: 0, count: Int(min(Int64(Self.guardBytes), size)))
        var cursor: UsageStreamCursor?
        if let checkpoint = previousCheckpoint,
           checkpoint.parserVersion == parserVersion,
           let saved = try stateLookup("stream-cursor") {
            cursor = try JSONDecoder().decode(UsageStreamCursor.self, from: saved)
        }
        var replacesFile = true
        var consumedTail = Data()
        if let saved = cursor, let checkpoint = previousCheckpoint,
           saved.version == parserVersion,
           saved.fileNumber == fileGuard.fileNumber, fileGuard.matchesCreationDate(saved.creationDate),
           saved.offset == checkpoint.offset, saved.offset >= 0, saved.offset <= size,
           (0...Self.guardBytes).contains(saved.prefixLength), saved.prefixLength <= prefix.count,
           (0...Self.guardBytes).contains(saved.tailLength), Int64(saved.tailLength) <= saved.offset,
           saved.prefixHash == streamHash(Data(prefix.prefix(saved.prefixLength))),
           (size != checkpoint.size || abs(modified.timeIntervalSince(checkpoint.modifiedAt)) < 0.001) {
            let tail = try fileGuard.read(offset: saved.offset - Int64(saved.tailLength), count: saved.tailLength)
            replacesFile = streamHash(tail) != saved.tailHash
            if !replacesFile { consumedTail = tail }
            if !replacesFile, saved.endedWithoutNewline, size > saved.offset {
                let separator = try fileGuard.read(offset: saved.offset, count: Int(min(2, size - saved.offset)))
                replacesFile = separator.first != 0x0A && !separator.starts(with: [0x0D, 0x0A])
            }
        }
        if replacesFile {
            consumedTail = Data()
            cursor = UsageStreamCursor(version: parserVersion, fileNumber: fileGuard.fileNumber,
                                       creationDate: fileGuard.creationDate, offset: 0, lineCount: 0,
                                       tailHash: streamHash(Data()), tailLength: 0,
                                       prefixHash: streamHash(prefix), prefixLength: prefix.count,
                                       endedWithoutNewline: false)
        }
        guard var current = cursor else { throw UsageIncrementalReadError.invalidState }
        if !replacesFile, let checkpoint = previousCheckpoint,
           checkpoint.size == size, abs(modified.timeIntervalSince(checkpoint.modifiedAt)) < 0.001 {
            try fileGuard.validate(prefix: prefix, tail: consumedTail, offset: current.offset)
            return UsageIncrementalReadResult(bytesRead: 0, committedOffset: current.offset, batchCount: 0)
        }
        let initialCodexCursor: Data?
        if replacesFile && source == codexSource {
            initialCodexCursor = try findCodexCursor(handle: handle, size: size,
                                                    fileIdentity: fileIdentity, checkCancellation: checkCancellation)
        } else {
            initialCodexCursor = nil
        }
        try handle.seek(toOffset: UInt64(current.offset))
        let startOffset = current.offset
        var fetchedOffset = current.offset
        var pending = Data()
        var completeLength = 0
        var batches = 0
        func lookup(_ key: String) throws -> Data? {
            if replacesFile { return key == "codex-cursor" ? initialCodexCursor : nil }
            return try stateLookup(key)
        }

        func emit(_ data: Data, final: Bool) throws {
            // A scan is one long-running dispatch work item. Foundation's JSON
            // temporaries must not survive until that entire work item returns.
            try autoreleasepool {
                try checkCancellation()
                let state = UsageParserState(lookup: lookup)
                let nextOffset = current.offset + Int64(data.count)
                let parseData: Data
                if current.endedWithoutNewline && data.starts(with: [0x0D, 0x0A]) {
                    parseData = Data(data.dropFirst(2))
                } else if current.endedWithoutNewline && data.first == 0x0A {
                    parseData = Data(data.dropFirst())
                } else {
                    parseData = data
                }
                let parsed = try parseIncrementalChunk(data: parseData, source: source, fileIdentity: fileIdentity,
                                                  modifiedAt: modified, isSubagent: isSubagent,
                                                  offset: nextOffset, size: size,
                                                  lineOffset: current.lineCount, state: state)
                current.offset = nextOffset
                if !data.isEmpty { current.endedWithoutNewline = data.last != 0x0A }
                current.lineCount += parseData.split(separator: 0x0A, omittingEmptySubsequences: true).count
                // Fingerprint the bytes parsed above, never a later filesystem read.
                if data.count >= Self.guardBytes {
                    consumedTail = Data(data.suffix(Self.guardBytes))
                } else {
                    consumedTail.append(data)
                    consumedTail = Data(consumedTail.suffix(Self.guardBytes))
                }
                current.tailLength = consumedTail.count
                current.tailHash = streamHash(consumedTail)
                state.write(current, key: "stream-cursor")
                let changes = try state.changes()
                let batch = UsageIncrementalBatch(parsed: parsed, stateChanges: changes,
                                                 removedEventIDs: Array(state.removedEventIDs),
                                                 removedEditIDs: Array(state.removedEditIDs), replacesFile: replacesFile,
                                                 isFinalBatch: final, codexUnknownModel: state.codexUnknownModel)
                try checkCancellation()
                try fileGuard.validate(prefix: prefix, tail: consumedTail, offset: current.offset)
                try onBatch(batch)
                // The callback persists state. Retain only cursor-sized local state;
                // subsequent batches read keyed values from that committed store.
                replacesFile = false
                batches += 1
            }
        }

        do {
            while fetchedOffset < size {
                try autoreleasepool {
                    try checkCancellation()
                    let amount = Int(min(Int64(Self.readChunkBytes), size - fetchedOffset))
                    guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                        throw UsageIncrementalReadError.fileChangedDuringRead
                    }
                    fetchedOffset += Int64(chunk.count)
                    if let newline = chunk.lastIndex(of: 0x0A) {
                        completeLength = pending.count + chunk.distance(from: chunk.startIndex, to: newline) + 1
                    }
                    pending.append(chunk)
                    if pending.count >= Self.batchBytes, completeLength > 0 {
                        let complete = Data(pending.prefix(completeLength))
                        pending = Data(pending.dropFirst(completeLength))
                        completeLength = 0
                        try emit(complete, final: false)
                    }
                }
            }
            if completeLength > 0 {
                let remainder = Data(pending.dropFirst(completeLength))
                if completeJSONRecord(remainder) {
                    try emit(pending, final: true)
                } else {
                    try emit(Data(pending.prefix(completeLength)), final: true)
                }
            } else if completeJSONRecord(pending) {
                try emit(pending, final: true)
            } else {
                try emit(Data(), final: true)
            }
            return UsageIncrementalReadResult(bytesRead: fetchedOffset - startOffset,
                                              committedOffset: current.offset, batchCount: batches)
        } catch UsageIncrementalReadError.requiresRebuild {
            return try readIncrementally(fileURL: fileURL, source: source, fileIdentity: fileIdentity,
                                         isSubagent: isSubagent, previousCheckpoint: nil,
                                         stateLookup: stateLookup, onBatch: onBatch,
                                         checkCancellation: checkCancellation)
        }
    }

    private static func streamHash(_ data: Data) -> String {
        ContentDigest.sha256(data)
    }

    private static func completeJSONRecord(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        do {
            return try JSONSerialization.jsonObject(with: data) is [String: Any]
        } catch {
            // The unfinished EOF record remains unconsumed in the source file.
            return false
        }
    }

    /// The legacy parser uses the first session_meta anywhere in the file for
    /// every record. Resolve that metadata once on rebuild without materializing
    /// all lines; ordinary rollouts resolve it from their first record.
    private static func findCodexCursor(
        handle: FileHandle, size: Int64, fileIdentity: String,
        checkCancellation: () throws -> Void
    ) throws -> Data? {
        try handle.seek(toOffset: 0)
        var remaining = size
        var pending = Data()
        while remaining > 0 {
            let seed: Data? = try autoreleasepool {
                try checkCancellation()
                guard let chunk = try handle.read(upToCount: Int(min(Int64(readChunkBytes), remaining))),
                      !chunk.isEmpty else { throw UsageIncrementalReadError.fileChangedDuringRead }
                remaining -= Int64(chunk.count)
                let previousLength = pending.count
                pending.append(chunk)
                if let newline = chunk.lastIndex(of: 0x0A) {
                    let completeLength = previousLength + chunk.distance(from: chunk.startIndex, to: newline) + 1
                    for line in pending.prefix(completeLength).split(separator: 0x0A, omittingEmptySubsequences: true) {
                        if let seed = try codexCursorSeed(line: Data(line), fileIdentity: fileIdentity) { return seed }
                    }
                    pending = Data(pending.dropFirst(completeLength))
                }
                return nil
            }
            if let seed { return seed }
        }
        return try codexCursorSeed(line: pending, fileIdentity: fileIdentity)
    }
}
