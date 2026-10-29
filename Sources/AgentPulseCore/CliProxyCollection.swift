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
    /// A proven source with compacted raw rows, or a source whose bounded
    /// audit has become a slow backlog. Keep polling the realtime window, but
    /// don't let an unbounded historical sweep block fresh usage forever.
    public var skipHistoricalAudit: Bool

    public init(endpoint: Endpoint = .discover, incrementalThroughMS: Int64 = 0,
                auditThroughMS: Int64? = nil, auditBeforeMS: Int64? = nil,
                auditBeforeID: Int64? = nil, auditedPages: Int = 0,
                skipHistoricalAudit: Bool = false) {
        self.endpoint = endpoint
        self.incrementalThroughMS = incrementalThroughMS
        self.auditThroughMS = auditThroughMS
        self.auditBeforeMS = auditBeforeMS
        self.auditBeforeID = auditBeforeID
        self.auditedPages = auditedPages
        self.skipHistoricalAudit = skipHistoricalAudit
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, incrementalThroughMS, auditThroughMS, auditBeforeMS,
             auditBeforeID, auditedPages, backfill, queuedBackfillFromMS,
             queuedBackfillThroughMS, skipHistoricalAudit
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try values.decodeIfPresent(Endpoint.self, forKey: .endpoint) ?? .discover
        incrementalThroughMS = try values.decodeIfPresent(Int64.self, forKey: .incrementalThroughMS) ?? 0
        auditThroughMS = try values.decodeIfPresent(Int64.self, forKey: .auditThroughMS)
        auditBeforeMS = try values.decodeIfPresent(Int64.self, forKey: .auditBeforeMS)
        auditBeforeID = try values.decodeIfPresent(Int64.self, forKey: .auditBeforeID)
        auditedPages = try values.decodeIfPresent(Int.self, forKey: .auditedPages) ?? 0
        backfill = try values.decodeIfPresent(CliProxyBackfillCursor.self, forKey: .backfill)
        queuedBackfillFromMS = try values.decodeIfPresent(Int64.self, forKey: .queuedBackfillFromMS)
        queuedBackfillThroughMS = try values.decodeIfPresent(Int64.self, forKey: .queuedBackfillThroughMS)
        skipHistoricalAudit = try values.decodeIfPresent(Bool.self, forKey: .skipHistoricalAudit) ?? false
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
