import Foundation
import SQLite3

extension UsageLedgerStore {
    private static let cliProxyStatePrefix = "cliproxy_collection_v1:"
    private static let cliProxyFileID = "network\u{1}cliproxy"

    /// One queue hop for all configured sources; credentials never enter this
    /// interface. Old sources must prove their existing event-ID domain before
    /// historical auditing can safely append records.
    public func cliProxyCollectionStates(identities: [String], hostname: String) throws -> [String: CliProxyCollectionState] {
        try queue.sync {
            var states: [String: CliProxyCollectionState] = [:]
            for identity in identities {
                states[identity] = try cliProxyStateUnlocked(identity: identity, hostname: hostname)
            }
            return states
        }
    }

    @discardableResult
    public func commitCliProxyCollection(_ collection: CliProxyStagedCollection,
                                         hostname: String,
                                         checkCancellation: () throws -> Void = {}) throws -> CliProxyCollectionState {
        try queue.sync {
            var state = collection.state
            try transaction {
                try checkCancellation()
                if state.requiresIdentityCheck {
                    try recordCliProxyIdentityEvidenceUnlocked(collection, hostname: hostname,
                                                               checkCancellation: checkCancellation)
                    if collection.migrationPassComplete {
                        state = try resolveCliProxyIdentityUnlocked(identity: collection.identity,
                                                                   hostname: hostname, state: state)
                    }
                } else {
                    var affected: [String: UsageEvent] = [:]
                    let frozen = try frozenBeforeMsUnlocked(hostname)
                    try collection.forEachPage { events in
                        try checkCancellation()
                        guard events.allSatisfy({ $0.source == CliProxyUsageParser.source && $0.project == collection.identity }) else {
                            throw UsageLedgerError.invalidCheckpoint
                        }
                        let kept = frozen > 0 ? events.filter { millis($0.timestamp) >= frozen } : events
                        let previous = try networkPreviousBucketEventsUnlocked(kept,
                            source: CliProxyUsageParser.source, hostname: hostname)
                        try insertRawEvents(kept, fileID: Self.cliProxyFileID, hostname: hostname)
                        for event in kept + previous {
                            let bucket = millis(event.timestamp) / Self.bucketMilliseconds
                            affected["\(event.model)\u{1}\(event.project)\u{1}\(bucket)"] = event
                        }
                    }
                    try writeCheckpoint(UsageFileCheckpoint(fileID: Self.cliProxyFileID,
                        source: CliProxyUsageParser.source, pathHash: Self.cliProxyFileID,
                        offset: 0, size: 0, modifiedAt: Date(timeIntervalSince1970: 0),
                        parserVersion: Int(Self.networkParserVersion), status: "complete"))
                    try recomputeNetworkBucketsUnlocked(events: Array(affected.values),
                        source: CliProxyUsageParser.source, hostname: hostname)
                    if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                        try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                    }
                }
                let encoded = try JSONEncoder().encode(state)
                try setTextUnlocked(key: cliProxyStateKey(identity: collection.identity, hostname: hostname),
                                    value: String(decoding: encoded, as: UTF8.self))
                try checkCancellation()
            }
            return state
        }
    }

    private func cliProxyStateUnlocked(identity: String, hostname: String) throws -> CliProxyCollectionState {
        if let value = try readTextUnlocked(key: cliProxyStateKey(identity: identity, hostname: hostname)) {
            return try JSONDecoder().decode(CliProxyCollectionState.self, from: Data(value.utf8))
        }
        let statement = try prepare("""
            SELECT 1 FROM usage_events
            WHERE source_file_hash=? AND hostname=? AND source=? AND project=? LIMIT 1;
            """)
        defer { sqlite3_finalize(statement) }
        try bind(statement, 1, Self.cliProxyFileID)
        try bind(statement, 2, hostname)
        try bind(statement, 3, CliProxyUsageParser.source)
        try bind(statement, 4, identity)
        return CliProxyCollectionState(endpoint: try step(statement) == SQLITE_ROW ? .detectingAnalytics : .discover)
    }

    private func cliProxyStateKey(identity: String, hostname: String) -> String {
        Self.cliProxyStatePrefix + hostname + "\u{1}" + identity
    }

    private func recordCliProxyIdentityEvidenceUnlocked(_ collection: CliProxyStagedCollection,
                                                       hostname: String,
                                                       checkCancellation: () throws -> Void) throws {
        let create = try prepare("""
            CREATE TABLE IF NOT EXISTS usage_cliproxy_identity_matches(
                hostname TEXT NOT NULL, identity TEXT NOT NULL, endpoint TEXT NOT NULL, event_id TEXT NOT NULL,
                PRIMARY KEY(hostname,identity,endpoint,event_id)
            ) WITHOUT ROWID;
            """)
        defer { sqlite3_finalize(create) }
        try done(create)
        let insert = try prepare("""
            INSERT OR IGNORE INTO usage_cliproxy_identity_matches(hostname,identity,endpoint,event_id)
            SELECT ?,?,?,? WHERE EXISTS (
                SELECT 1 FROM usage_events WHERE source_file_hash=? AND event_id=? AND hostname=? AND project=?
            );
            """)
        defer { sqlite3_finalize(insert) }
        let endpoint = collection.state.endpoint == .detectingLegacy ? "legacy" : "analytics"
        try collection.forEachPage { events in
            try checkCancellation()
            for event in events {
                guard event.project == collection.identity, event.source == CliProxyUsageParser.source else {
                    throw UsageLedgerError.invalidCheckpoint
                }
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                try bind(insert, 1, hostname)
                try bind(insert, 2, collection.identity)
                try bind(insert, 3, endpoint)
                try bind(insert, 4, event.id)
                try bind(insert, 5, Self.cliProxyFileID)
                try bind(insert, 6, event.id)
                try bind(insert, 7, hostname)
                try bind(insert, 8, collection.identity)
                try done(insert)
            }
        }
    }

    private func resolveCliProxyIdentityUnlocked(identity: String, hostname: String,
                                                state original: CliProxyCollectionState) throws -> CliProxyCollectionState {
        let count = try prepare("""
            SELECT COUNT(DISTINCT event_id) FROM usage_events
            WHERE source_file_hash=? AND hostname=? AND project=?;
            """)
        defer { sqlite3_finalize(count) }
        try bind(count, 1, Self.cliProxyFileID)
        try bind(count, 2, hostname)
        try bind(count, 3, identity)
        _ = try step(count)
        let existing = sqlite3_column_int64(count, 0)
        let evidence = try prepare("""
            SELECT endpoint,COUNT(*) FROM usage_cliproxy_identity_matches
            WHERE hostname=? AND identity=? GROUP BY endpoint;
            """)
        defer { sqlite3_finalize(evidence) }
        try bind(evidence, 1, hostname)
        try bind(evidence, 2, identity)
        var matches: [String: Int64] = [:]
        while try step(evidence) == SQLITE_ROW { matches[text(evidence, 0)] = sqlite3_column_int64(evidence, 1) }
        let analytics = matches["analytics", default: 0]
        let legacy = matches["legacy", default: 0]
        var state = original
        state.resetAudit()
        if analytics > 0 && legacy > 0 {
            state.endpoint = .mixed
        } else if analytics == existing && analytics > 0 {
            state.endpoint = .analytics
        } else if legacy == existing && legacy > 0 {
            state.endpoint = .legacy
        } else if original.endpoint == .detectingAnalytics {
            state.endpoint = .detectingLegacy
        } else {
            state.endpoint = .unresolved
        }
        if !state.requiresIdentityCheck {
            let clear = try prepare("DELETE FROM usage_cliproxy_identity_matches WHERE hostname=? AND identity=?;")
            defer { sqlite3_finalize(clear) }
            try bind(clear, 1, hostname)
            try bind(clear, 2, identity)
            try done(clear)
        }
        return state
    }
}
