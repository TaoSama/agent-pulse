import Foundation

extension UsageLedgerStore {
    private func asterStateKey(_ hostname: String) -> String { "aster_collection_v1\u{1}" + hostname }

    func asterCollectionLowerBound(hostname: String) throws -> Date? {
        try queue.sync {
            let frozen = try frozenBeforeMsUnlocked(hostname)
            return frozen > 0 ? Date(timeIntervalSince1970: Double(frozen) / 1_000) : nil
        }
    }

    func asterCollectionState(hostname: String) throws -> AsterCollectionState {
        try queue.sync {
            guard let json = try readTextUnlocked(key: asterStateKey(hostname)) else {
                return AsterCollectionState()
            }
            return try JSONDecoder().decode(AsterCollectionState.self, from: Data(json.utf8))
        }
    }

    func commitAsterCollection(events: [UsageEvent], state: AsterCollectionState, hostname: String) throws {
        guard !hostname.isEmpty, events.allSatisfy({ $0.source == AsterUsageService.source }) else {
            throw UsageLedgerError.invalidCheckpoint
        }
        let fileID = "network\u{1}" + AsterUsageService.source
        let encoded = try JSONEncoder().encode(state)
        try queue.sync {
            try transaction {
                try Task.checkCancellation()
                if !events.isEmpty {
                    let frozen = try frozenBeforeMsUnlocked(hostname)
                    let kept = frozen > 0 ? events.filter { millis($0.timestamp) >= frozen } : events
                    let previous = try networkPreviousBucketEventsUnlocked(kept,
                        source: AsterUsageService.source, hostname: hostname)
                    try insertRawEvents(kept, fileID: fileID, hostname: hostname)
                    try writeCheckpoint(UsageFileCheckpoint(fileID: fileID, source: AsterUsageService.source,
                        pathHash: fileID, offset: 0, size: 0, modifiedAt: Date(timeIntervalSince1970: 0),
                        parserVersion: Int(Self.networkParserVersion), status: "complete"))
                    try recomputeNetworkBucketsUnlocked(events: kept + previous,
                        source: AsterUsageService.source, hostname: hostname)
                    if try readTextUnlocked(key: Self.canonicalHostnameKey) == nil {
                        try setTextUnlocked(key: Self.canonicalHostnameKey, value: hostname)
                    }
                }
                try setTextUnlocked(key: asterStateKey(hostname), value: String(decoding: encoded, as: UTF8.self))
                try Task.checkCancellation()
            }
        }
    }
}
