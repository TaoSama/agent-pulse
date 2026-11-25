import AgentPulseCore
import Foundation
import SQLite3

private enum VerificationFailure: Error { case failed(String) }

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationFailure.failed(message) }
}

private func row(_ id: String = "event-1", date: String = "2026-11-23T01:02:03.123456Z",
                 provider: String = "openai", semantic: String? = nil,
                 measured: Bool = true) -> [String: Any] {
    var value: [String: Any] = [
        "event_id": id, "provider": provider, "requested_model": "test-model",
        "created_at": date, "input_tokens": 100, "output_tokens": 50,
        "cache_creation_tokens": 10, "cache_tokens": 20, "reasoning_tokens": 5,
        "usage_measured": measured,
    ]
    value["usage_semantic"] = semantic
    return value
}

private func data(_ rows: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: rows)
}

private actor FixtureServer {
    let pages: [Data]
    var requests: [URLRequest] = []
    init(_ pages: [Data]) { self.pages = pages }

    func transport(_ request: URLRequest) throws -> (Data, URLResponse) {
        let index = requests.count
        requests.append(request)
        guard index < pages.count, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw VerificationFailure.failed("unexpected extra request")
        }
        return (pages[index], response)
    }

    func queries() -> [[String: String]] {
        requests.map { request in
            let query = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            return Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        }
    }
}

private func service(_ server: FixtureServer) -> AsterUsageService {
    AsterUsageService { try await server.transport($0) }
}

private let empty = Data("[]".utf8)
private let hostname = "test-host"

@main
struct AsterUsageVerification {
    static func main() async throws {
        try await verifyTokenSemantics()
        try await verifyUnmeasuredCursorAndPrecision()
        try await verifyMalformedPages()
        try await verifyShortPagesAndIdempotency()
        try await verifyFailedPassResumes()
        try await verifyFrozenHistoryBound()
        try await verifyHostnameReplays()
        print("AsterUsageVerification passed (7 checks)")
    }

    private static func verifyTokenSemantics() async throws {
        let cases: [(String, String?, Int64, Int64, Int64)] = [
            ("openai", nil, 70, 45, 150),
            ("anthropic", nil, 100, 45, 180),
            ("gemini", nil, 70, 50, 155),
            ("openai", "independent", 100, 45, 180),
            ("anthropic-oauth", "unrecognized", 100, 45, 180),
        ]
        for (provider, semantic, input, output, total) in cases {
            let ledger = try UsageLedgerStore(path: ":memory:")
            let server = FixtureServer([try data([row(provider: provider, semantic: semantic)]), empty])
            _ = try await service(server).collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
            let buckets = try ledger.buckets(hostname: hostname)
            guard let counts = buckets.first?.counts else { throw VerificationFailure.failed("missing bucket") }
            try require(counts.input == input && counts.output == output && counts.total == total,
                        "provider token components must remain disjoint")
            try require(counts.cachedInput == 20 && counts.cacheCreationInput == 10 && counts.reasoningOutput == 5,
                        "cache and reasoning components must be preserved")
        }
    }

    private static func verifyUnmeasuredCursorAndPrecision() async throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        let timestamp = "2026-11-23T01:02:02.123456Z"
        let server = FixtureServer([try data([
            row("measured", semantic: "independent"),
            row("unmeasured", date: timestamp, measured: false),
        ]), empty])
        _ = try await service(server).collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
        let queries = await server.queries()
        try require(queries.count == 2 && queries[1]["after_created_at"] == timestamp
                    && queries[1]["after_event_id"] == "unmeasured", "cursor precision and skipped rows")
        try require(try ledger.buckets(hostname: hostname).first?.counts.total == 180,
                    "unmeasured rows must not count")
    }

    private static func verifyMalformedPages() async throws {
        var negative = row()
        negative["input_tokens"] = -1
        let cases = [try data([negative]), try data([row(), row()]), try data([
            row("older", date: "2026-11-23T01:02:01Z"), row("newer"),
        ])]
        for payload in cases {
            let ledger = try UsageLedgerStore(path: ":memory:")
            do {
                _ = try await service(FixtureServer([payload])).collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
                throw VerificationFailure.failed("malformed page accepted")
            } catch AsterUsageError.invalidResponse {
                try require(try ledger.buckets(hostname: hostname).isEmpty, "malformed page must not partially commit")
            }
        }
    }

    private static func verifyShortPagesAndIdempotency() async throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        let payload = try data([row()])
        let server = FixtureServer([payload, empty, payload, empty])
        let collector = service(server)
        let first = try await collector.collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
        let second = try await collector.collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
        try require(first == 1 && second == 1, "short nonempty pages must continue until empty")
        try require(try ledger.buckets(hostname: hostname).first?.counts.total == 150, "retries must not accumulate")
        let queries = await server.queries()
        try require(queries.count == 4 && queries[2]["since"] != nil, "completed history switches to increment")
    }

    private static func verifyFailedPassResumes() async throws {
        let ledger = try UsageLedgerStore(path: ":memory:")
        do {
            _ = try await service(FixtureServer([try data([row()])])).collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
            throw VerificationFailure.failed("transport failure expected")
        } catch AsterUsageError.network {
            try require(try ledger.buckets(hostname: hostname).first?.counts.total == 150,
                        "successful earlier page must remain committed")
        }
        let server = FixtureServer([empty, empty])
        _ = try await service(server).collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
        let queries = await server.queries()
        try require(queries.count == 2 && queries[0]["since"] != nil && queries[1]["after_event_id"] == "event-1",
                    "retry must resume historical cursor after refreshing increments")
    }

    private static func verifyFrozenHistoryBound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aster-verification-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let path = directory.appendingPathComponent("usage.sqlite3").path
            let ledger = try UsageLedgerStore(path: path)
            let frozenDate = Date(timeIntervalSince1970: 1_795_392_000) // 2026-11-23T00:00:00Z
            try writeFrozen(path: path, milliseconds: Int64(frozenDate.timeIntervalSince1970 * 1_000))
            let payload = try data([
                row("kept", date: frozenDate.addingTimeInterval(10).ISO8601Format()),
                row("frozen", date: frozenDate.addingTimeInterval(-10).ISO8601Format()),
            ])
            let server = FixtureServer([payload])
            _ = try await service(server).collect(managementKey: "test-secret", ledger: ledger, hostname: hostname)
            let queries = await server.queries()
            try require(queries.count == 1 && queries[0]["since"] == frozenDate.ISO8601Format(),
                        "initial history must request the frozen lower bound and stop at that boundary")
            try require(try ledger.buckets(hostname: hostname).first?.counts.total == 150,
                        "frozen history must stay excluded")
            try FileManager.default.removeItem(at: directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func writeFrozen(path: String, milliseconds: Int64) throws {
        let sql = "INSERT INTO sync_state(key,value,updated_at_ms) VALUES('frozen_before_ms\u{1}\(hostname)','\(milliseconds)',0);"
        try executeSQL(sql, path: path)
    }

    private static func executeSQL(_ sql: String, path: String) throws {
        var db: OpaquePointer?
        let result = sqlite3_open(path, &db)
        defer { sqlite3_close(db) }
        guard result == SQLITE_OK else { throw VerificationFailure.failed("open fixture database") }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VerificationFailure.failed("write fixture database") }
    }

    private static func verifyHostnameReplays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aster-replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let path = directory.appendingPathComponent("usage.sqlite3").path
            let original = try UsageLedgerStore(path: path)
            let recent = Date()
            let historical = recent.addingTimeInterval(-45 * 24 * 60 * 60)
            let firstPage = try data([
                row("live", date: recent.ISO8601Format()),
                row("compacted", date: historical.ISO8601Format()),
            ])
            _ = try await service(FixtureServer([firstPage, empty]))
                .collect(managementKey: "test-secret", ledger: original, hostname: hostname)

            try executeSQL("DROP TABLE usage_compacted_network_events; PRAGMA user_version=10;", path: path)
            let ledger = try UsageLedgerStore(path: path)
            try require(try ledger.eventCount() == 2, "v10 migration must retain existing Aster raw events")

            let newHost = "adopted-host"
            _ = try ledger.compactFrozenRaw(hostname: "unrelated-host")
            try require(try ledger.eventCount() == 2, "compaction must preserve unfrozen network rows on another host")
            let compacted = try ledger.compactFrozenRaw(hostname: hostname)
            try require(compacted.deletedRows == 1 && (try ledger.eventCount()) == 1,
                        "compaction must delete only the frozen raw Aster event")
            try ledger.adoptHostname(newHost)

            let reopened = try UsageLedgerStore(path: path)
            let replayPage = try data([
                row("live", date: recent.addingTimeInterval(7_200).ISO8601Format()),
                row("compacted", date: recent.addingTimeInterval(3_600).ISO8601Format()),
                row("new-history", date: historical.addingTimeInterval(-3_600).ISO8601Format()),
            ])
            let server = FixtureServer([replayPage, empty])
            _ = try await service(server).collect(managementKey: "test-secret", ledger: reopened, hostname: newHost)
            let oldBuckets = try reopened.buckets(hostname: hostname)
            let newBuckets = try reopened.buckets(hostname: newHost)
            try require(oldBuckets.reduce(0) { $0 + $1.counts.total } == 300
                        && newBuckets.count == 1 && newBuckets.first?.counts.total == 150
                        && (newBuckets.first?.bucketStart ?? .distantFuture) < historical
                        && (try reopened.eventCount()) == 2,
                        "only the unseen historical ID belongs to the adopted hostname")
            let queries = await server.queries()
            try require(queries.last?["after_event_id"] == "new-history", "filtered replays must advance pagination")

            try reopened.resetForRebuild()
            _ = try await service(FixtureServer([firstPage, empty]))
                .collect(managementKey: "test-secret", ledger: reopened, hostname: newHost)
            try require(try reopened.eventCount() == 2, "an explicit reset must clear compacted IDs")
            try FileManager.default.removeItem(at: directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
