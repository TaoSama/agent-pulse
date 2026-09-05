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
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let sizeNumber = attributes[.size] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber,
              let created = attributes[.creationDate] as? Date,
              let modified = attributes[.modificationDate] as? Date else {
            throw UsageIncrementalReadError.invalidFile
        }
        let size = sizeNumber.int64Value
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { handle.closeFile() }
        let prefix = try handle.read(upToCount: min(Self.guardBytes, Int(size))) ?? Data()
        var cursor: UsageStreamCursor?
        if let checkpoint = previousCheckpoint,
           checkpoint.parserVersion == parserVersion,
           let saved = try stateLookup("stream-cursor") {
            cursor = try JSONDecoder().decode(UsageStreamCursor.self, from: saved)
        }
        var replacesFile = true
        if let saved = cursor, let checkpoint = previousCheckpoint,
           saved.version == parserVersion,
           saved.fileNumber == fileNumber.uint64Value, saved.creationDate == created,
           saved.offset == checkpoint.offset, saved.offset <= size,
           saved.prefixHash == streamHash(Data(prefix.prefix(saved.prefixLength))),
           (size != checkpoint.size || abs(modified.timeIntervalSince(checkpoint.modifiedAt)) < 0.001) {
            try handle.seek(toOffset: UInt64(max(0, saved.offset - Int64(saved.tailLength))))
            let tail = try handle.read(upToCount: saved.tailLength) ?? Data()
            replacesFile = streamHash(tail) != saved.tailHash
            if !replacesFile, saved.endedWithoutNewline, size > saved.offset {
                try handle.seek(toOffset: UInt64(saved.offset))
                let separator = try handle.read(upToCount: 2) ?? Data()
                replacesFile = separator.first != 0x0A && !separator.starts(with: [0x0D, 0x0A])
            }
        }
        if replacesFile {
            cursor = UsageStreamCursor(version: parserVersion, fileNumber: fileNumber.uint64Value,
                                       creationDate: created, offset: 0, lineCount: 0,
                                       tailHash: streamHash(Data()), tailLength: 0,
                                       prefixHash: streamHash(prefix), prefixLength: prefix.count,
                                       endedWithoutNewline: false)
        }
        guard var current = cursor else { throw UsageIncrementalReadError.invalidState }
        if !replacesFile, let checkpoint = previousCheckpoint,
           checkpoint.size == size, abs(modified.timeIntervalSince(checkpoint.modifiedAt)) < 0.001 {
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
        var batches = 0
        func lookup(_ key: String) throws -> Data? {
            if replacesFile { return key == "codex-cursor" ? initialCodexCursor : nil }
            return try stateLookup(key)
        }

        func emit(_ data: Data, final: Bool) throws {
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
            current.tailLength = min(Self.guardBytes, Int(current.offset))
            try handle.seek(toOffset: UInt64(current.offset - Int64(current.tailLength)))
            current.tailHash = streamHash(try handle.read(upToCount: current.tailLength) ?? Data())
            try handle.seek(toOffset: UInt64(fetchedOffset))
            state.write(current, key: "stream-cursor")
            let changes = try state.changes()
            let batch = UsageIncrementalBatch(parsed: parsed, stateChanges: changes,
                                             removedEventIDs: Array(state.removedEventIDs),
                                             removedEditIDs: Array(state.removedEditIDs), replacesFile: replacesFile,
                                             isFinalBatch: final, codexUnknownModel: state.codexUnknownModel)
            try onBatch(batch)
            // The callback persists state. Retain only cursor-sized local state;
            // subsequent batches read keyed values from that committed store.
            replacesFile = false
            batches += 1
        }

        do {
            while fetchedOffset < size {
                try checkCancellation()
                let amount = Int(min(Int64(Self.readChunkBytes), size - fetchedOffset))
                guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else {
                    throw UsageIncrementalReadError.fileChangedDuringRead
                }
                fetchedOffset += Int64(chunk.count)
                pending.append(chunk)
                if pending.count >= Self.batchBytes, let newline = pending.lastIndex(of: 0x0A) {
                    let end = pending.index(after: newline)
                    let complete = Data(pending[..<end])
                    pending = Data(pending[end...])
                    try emit(complete, final: false)
                }
            }
            if let newline = pending.lastIndex(of: 0x0A) {
                let next = pending.index(after: newline)
                let remainder = Data(pending[next...])
                if completeJSONRecord(remainder) {
                    try emit(pending, final: true)
                } else {
                    try emit(Data(pending[...newline]), final: true)
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
            try checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(min(Int64(readChunkBytes), remaining))),
                  !chunk.isEmpty else { throw UsageIncrementalReadError.fileChangedDuringRead }
            remaining -= Int64(chunk.count)
            pending.append(chunk)
            if let newline = pending.lastIndex(of: 0x0A) {
                let end = pending.index(after: newline)
                for line in pending[..<end].split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if let seed = try codexCursorSeed(line: Data(line), fileIdentity: fileIdentity) { return seed }
                }
                pending = Data(pending[end...])
            }
        }
        return try codexCursorSeed(line: pending, fileIdentity: fileIdentity)
    }
}
