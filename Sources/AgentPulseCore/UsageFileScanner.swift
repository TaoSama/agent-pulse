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
    /// Long-running scans have visible progress and must keep file I/O moving.
    /// A utility ledger queue alone does not change the caller's requested QoS.
    public static let workerQueue = DispatchQueue(label: "com.agentpulse.usage-scan.worker", qos: .utility)
    private static let publicationFileLimit = 8
    private static let publicationRowLimit = 16_384
    private static let publicationMaxDelay: TimeInterval = 1
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
        var readyFiles: [String] = []
        var readyRows = 0
        var readySince: TimeInterval?
        func flushReady() throws {
            guard !readyFiles.isEmpty else { return }
            let committed = try ledger.publishReadyParserReplacements(fileIDs: readyFiles, hostname: hostname)
            for checkpoint in committed { checkpoints[checkpoint.fileID] = checkpoint }
            readyFiles.removeAll(keepingCapacity: true)
            readyRows = 0
            readySince = nil
        }
        let legacyRoots = manifest.source.source == UsageJSONLParser.codexSource
            ? legacyCodexRoots.flatMap { root in
                let resolved = root.resolvingSymlinksInPath()
                return resolved.path == root.path ? [root] : [root, resolved]
            } : []
        do {
            for file in manifest.files {
                try autoreleasepool {
                    try checkCancellation()
                    let source = manifest.source.source
                    let identity = fileIdentity(for: file.url, source: source)
                    let fileID = UsageJSONLParser.fileID(for: identity)
                    if readyFiles.contains(fileID) { try flushReady() }
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
                        return
                    }
                    do {
                        var stagedRows = 0
                        _ = try UsageJSONLParser.readIncrementally(
                            fileURL: file.url, source: source, fileIdentity: identity,
                            isSubagent: manifest.source.includeSubagents && isSubagent(file.url),
                            previousCheckpoint: checkpoint,
                            stateLookup: { try ledger.parserState(fileID: fileID, key: $0) },
                            onBatch: { batch in
                                // Flush older completed files at a parser boundary, never
                                // expose a staged checkpoint as committed progress.
                                if let readySince,
                                   ProcessInfo.processInfo.systemUptime - readySince >= publicationMaxDelay {
                                    try flushReady()
                                }
                                let committed = try ledger.recordIncrementalForScan(batch: batch, hostname: hostname)
                                if committed {
                                    checkpoints[fileID] = batch.parsed.checkpoint
                                } else {
                                    stagedRows += batch.parsed.events.count + batch.parsed.sessionEvents.count
                                        + batch.parsed.editEntries.count
                                    if batch.isFinalBatch {
                                        if readyFiles.isEmpty { readySince = ProcessInfo.processInfo.systemUptime }
                                        readyFiles.append(fileID)
                                        readyRows += stagedRows
                                        if readyFiles.count >= publicationFileLimit || readyRows >= publicationRowLimit {
                                            try flushReady()
                                        }
                                    }
                                }
                            },
                            checkCancellation: checkCancellation
                        )
                    } catch {
                        try ledger.abortParserReplacement(fileID: fileID)
                        throw error
                    }
                }
            }
            try checkCancellation()
            try flushReady()
        } catch {
            try ledger.abortParserReplacements(fileIDs: readyFiles)
            throw error
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
