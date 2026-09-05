import Foundation

public struct CliProxyBackfillCursor: Codable, Sendable, Equatable {
    public var fromMS: Int64
    public var throughMS: Int64
    public var beforeMS: Int64?
    public var beforeID: Int64?
}

/// Only hashed source identities and collection cursors are persisted.
public struct CliProxyCollectionState: Codable, Sendable, Equatable {
    public enum Endpoint: String, Codable, Sendable {
        case discover, analytics, legacy, detectingAnalytics, detectingLegacy, unresolved, mixed
    }

    public var endpoint: Endpoint
    public var incrementalThroughMS: Int64
    public var auditThroughMS: Int64?
    public var auditBeforeMS: Int64?
    public var auditBeforeID: Int64?
    public var auditedPages: Int
    public var backfill: CliProxyBackfillCursor?
    public var queuedBackfillFromMS: Int64?
    public var queuedBackfillThroughMS: Int64?

    public init(endpoint: Endpoint = .discover, incrementalThroughMS: Int64 = 0,
                auditThroughMS: Int64? = nil, auditBeforeMS: Int64? = nil,
                auditBeforeID: Int64? = nil, auditedPages: Int = 0) {
        self.endpoint = endpoint
        self.incrementalThroughMS = incrementalThroughMS
        self.auditThroughMS = auditThroughMS
        self.auditBeforeMS = auditBeforeMS
        self.auditBeforeID = auditBeforeID
        self.auditedPages = auditedPages
    }

    public var requiresIdentityCheck: Bool {
        [.detectingAnalytics, .detectingLegacy, .unresolved, .mixed].contains(endpoint)
    }

    mutating func resetAudit() {
        auditThroughMS = nil
        auditBeforeMS = nil
        auditBeforeID = nil
        auditedPages = 0
    }
}

/// Owns bounded-size pages containing only normalized usage metadata. The
/// ledger commits these pages and the completion cursor in one transaction.
public final class CliProxyStagedCollection: @unchecked Sendable {
    public let identity: String
    public let state: CliProxyCollectionState
    public let eventCount: Int
    public let migrationPassComplete: Bool
    private let directory: URL
    private let pages: [URL]

    init(identity: String, state: CliProxyCollectionState, eventCount: Int,
         migrationPassComplete: Bool, directory: URL, pages: [URL]) {
        self.identity = identity
        self.state = state
        self.eventCount = eventCount
        self.migrationPassComplete = migrationPassComplete
        self.directory = directory
        self.pages = pages
    }

    public func forEachPage(_ consume: ([UsageEvent]) throws -> Void) throws {
        for page in pages {
            try Task.checkCancellation()
            try consume(JSONDecoder().decode([UsageEvent].self, from: Data(contentsOf: page)))
        }
    }

    public func removeStaging() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    deinit {
        do { try removeStaging() }
        catch { NSLog("CPA normalized staging cleanup failed") }
    }
}

public struct CliProxyCollectionResult: Sendable {
    public let collections: [CliProxyStagedCollection]
    public let sourceCount: Int
    public let failedSourceCount: Int
    public let migrationSourceCount: Int
}

/// A source owns one writer until completion; no credential or raw API JSON is
/// written. Failure disposes the uncommitted pages without advancing cursors.
final class CliProxyStageWriter {
    private let directory: URL
    private var pages: [URL] = []
    private var eventCount = 0
    private var transferred = false
    private let maximumBytes: Int
    private var writtenBytes = 0

    init(maximumBytes: Int = 256 * 1024 * 1024) throws {
        self.maximumBytes = maximumBytes
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-pulse-cpa-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
    }

    func append(_ events: [UsageEvent]) throws {
        guard !events.isEmpty else { return }
        let page = directory.appendingPathComponent("\(pages.count).json")
        let data = try JSONEncoder().encode(events)
        guard data.count <= maximumBytes - writtenBytes else { throw CliProxyUsageError.responseTooLarge }
        guard FileManager.default.createFile(atPath: page.path, contents: data,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw CliProxyUsageError.staging
        }
        pages.append(page)
        eventCount += events.count
        writtenBytes += data.count
    }

    func finish(identity: String, state: CliProxyCollectionState,
                migrationPassComplete: Bool = false) -> CliProxyStagedCollection {
        transferred = true
        return CliProxyStagedCollection(identity: identity, state: state, eventCount: eventCount,
                                        migrationPassComplete: migrationPassComplete,
                                        directory: directory, pages: pages)
    }

    deinit {
        guard !transferred else { return }
        do { try FileManager.default.removeItem(at: directory) }
        catch { NSLog("CPA incomplete staging cleanup failed") }
    }
}
