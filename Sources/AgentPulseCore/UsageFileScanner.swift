import Foundation

public struct UsageScanRoot: Sendable {
    public let root: URL
    public let source: String
    public let includeSubagents: Bool

    public init(root: URL, source: String, includeSubagents: Bool = false) {
        self.root = root
        self.source = source
        self.includeSubagents = includeSubagents
    }
}

public struct UsageScanFile: Sendable {
    public let url: URL
    public let size: Int64
    public let modifiedAt: Date
}

public struct UsageScanManifest: Sendable {
    public let source: UsageScanRoot
    public let files: [UsageScanFile]

    /// Discovery is shared by progress and ingestion. A partially enumerated root is never
    /// accepted as evidence that files disappeared: its errors abort before any missing update.
    public static func discover(
        source: UsageScanRoot,
        checkCancellation: () throws -> Void = {}
    ) throws -> UsageScanManifest {
        try checkCancellation()
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: source.root.path, isDirectory: &directory) else {
            do {
                _ = try manager.attributesOfItem(atPath: source.root.path)
                throw UsageFileScanError.rootNotEnumerable
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return UsageScanManifest(source: source, files: [])
            }
        }
        guard directory.boolValue else { throw UsageFileScanError.rootNotEnumerable }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var enumerationError: Error?
        guard let enumerator = manager.enumerator(
            at: source.root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw UsageFileScanError.rootNotEnumerable }
        var files: [UsageScanFile] = []
        for case let url as URL in enumerator {
            try checkCancellation()
            guard url.pathExtension == "jsonl" else { continue }
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            guard let size = values.fileSize, let modifiedAt = values.contentModificationDate else {
                throw UsageFileScanError.metadataUnavailable
            }
            files.append(UsageScanFile(url: url, size: Int64(size), modifiedAt: modifiedAt))
        }
        if let enumerationError { throw enumerationError }
        return UsageScanManifest(source: source, files: files)
    }
}

public enum UsageFileScanError: Error {
    case rootNotEnumerable
    case metadataUnavailable
}

public enum UsageFileScanner {
    /// Processes every discovered file without admission limits based on total file size.
    /// The incremental reader commits bounded batches and resumes from durable parser state.
    @discardableResult
    public static func scan(
        manifest: UsageScanManifest,
        ledger: UsageLedgerStore,
        hostname: String,
        checkpoints: inout [String: UsageFileCheckpoint],
        legacyCodexRoots: [URL] = [],
        onFile: () -> Void = {},
        checkCancellation: () throws -> Void = {}
    ) throws -> [String] {
        var present: [String] = []
        let legacyRoots = manifest.source.source == UsageJSONLParser.codexSource
            ? legacyCodexRoots.flatMap { root in
                let resolved = root.resolvingSymlinksInPath()
                return resolved.path == root.path ? [root] : [root, resolved]
            } : []
        for file in manifest.files {
            try checkCancellation()
            let source = manifest.source.source
            let identity = fileIdentity(for: file.url, source: source)
            let fileID = UsageJSONLParser.fileID(for: identity)
            present.append(fileID)
            onFile()
            if checkpoints[fileID] == nil, source == UsageJSONLParser.codexSource {
                for legacy in legacyIdentities(for: file.url, roots: legacyRoots) {
                    let oldFileID = UsageJSONLParser.fileID(for: legacy)
                    guard checkpoints[oldFileID] != nil else { continue }
                    if let migrated = try ledger.migrateFileIdentityIfCheckpointMatches(
                        from: oldFileID, to: fileID, expectedSource: source,
                        expectedSize: file.size, expectedModifiedAt: file.modifiedAt,
                        expectedParserVersion: UsageJSONLParser.parserVersion
                    ) {
                        checkpoints.removeValue(forKey: oldFileID)
                        checkpoints[fileID] = migrated
                        break
                    }
                }
            }
            let checkpoint = checkpoints[fileID]
            if let checkpoint, checkpoint.status == "complete",
               checkpoint.parserVersion == UsageJSONLParser.parserVersion,
               checkpoint.size == file.size,
               abs(checkpoint.modifiedAt.timeIntervalSince(file.modifiedAt)) < 0.001 {
                continue
            }
            do {
                _ = try UsageJSONLParser.readIncrementally(
                    fileURL: file.url, source: source, fileIdentity: identity,
                    isSubagent: manifest.source.includeSubagents && isSubagent(file.url),
                    previousCheckpoint: checkpoint,
                    stateLookup: { try ledger.parserState(fileID: fileID, key: $0) },
                    onBatch: { batch in
                        try ledger.recordIncremental(batch: batch, hostname: hostname)
                        checkpoints[fileID] = batch.parsed.checkpoint
                    },
                    checkCancellation: checkCancellation
                )
            } catch {
                try ledger.abortParserReplacement(fileID: fileID)
                throw error
            }
        }
        return present
    }

    public static func fileIdentity(for url: URL, source: String) -> String {
        if source == UsageJSONLParser.codexSource,
           url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" {
            return url.lastPathComponent
        }
        return url.path
    }

    private static func isSubagent(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "subagents"
            && url.deletingPathExtension().lastPathComponent.hasPrefix("agent-")
    }

    private static func legacyIdentities(for url: URL, roots: [URL]) -> [String] {
        var result = [url.path]
        let prefix = "rollout-"
        let name = url.lastPathComponent
        guard name.hasPrefix(prefix), name.count >= prefix.count + 10 else { return result }
        let dateStart = name.index(name.startIndex, offsetBy: prefix.count)
        let dateEnd = name.index(dateStart, offsetBy: 10)
        let parts = name[dateStart..<dateEnd].split(separator: "-")
        guard parts.count == 3 else { return result }
        let relative = (parts.map(String.init) + [name]).joined(separator: "/")
        for root in roots {
            result.append(root.appending(path: relative).path)
        }
        return result
    }
}
