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
        let encoded = try JSONEncoder().encode(state)
        try queue.sync {
            try transaction {
                try Task.checkCancellation()
                try recordNetworkEventsUnlocked(events, source: AsterUsageService.source, hostname: hostname)
                try setTextUnlocked(key: asterStateKey(hostname), value: String(decoding: encoded, as: UTF8.self))
                try Task.checkCancellation()
            }
        }
    }
}
