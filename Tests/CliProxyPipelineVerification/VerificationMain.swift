import Foundation
import AgentPulseCore
import AgentPulseReporting

private enum CheckFailure: Error { case assertion(String) }
private func check(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure.assertion(message) }
}

private struct RemoteEvent: Sendable {
    let id: Int64
    let timestamp: Int64
}

private actor FakeCPA {
    let targetHash: String
    var events: [RemoteEvent]
    var analyticsSupported = true
    var failAtRequest: Int?
    var requestCount = 0
    var legacyRequests = 0

    init(events: [RemoteEvent], key: String) {
        self.events = events
        targetHash = CliProxyUsageParser.apiKeyHash(for: key)
    }
    func append(_ event: RemoteEvent) { events.append(event) }
    func setSupported(_ supported: Bool) { analyticsSupported = supported }
    func failRequest(_ request: Int?) { failAtRequest = request }
    func legacyCount() -> Int { legacyRequests }
    func transport(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        if failAtRequest == requestCount { throw URLError(.networkConnectionLost) }
        let status = request.httpMethod == "POST" && !analyticsSupported ? 404 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        if status == 404 { return (Data(), response) }
        if request.httpMethod != "POST" {
            legacyRequests += 1
            return (try legacyData(), response)
        }
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        let include = body["include"] as! [String: Any]
        let paging = include["events_page"] as! [String: Any]
        let from = (body["from_ms"] as! NSNumber).int64Value
        let to = (body["to_ms"] as! NSNumber).int64Value
        let limit = (paging["limit"] as! NSNumber).intValue
        let before = (paging["before_ms"] as? NSNumber)?.int64Value
        let beforeID = (paging["before_id"] as? NSNumber)?.int64Value ?? 0
        let matching = events.filter { event in
            event.timestamp >= from && event.timestamp <= to && (before == nil
                || event.timestamp < before! || (event.timestamp == before! && event.id < beforeID))
        }.sorted { $0.timestamp == $1.timestamp ? $0.id > $1.id : $0.timestamp > $1.timestamp }
        let page = Array(matching.prefix(limit))
        return (try analyticsData(page, hasMore: matching.count > limit), response)
    }
    func analyticsData(_ page: [RemoteEvent], hasMore: Bool = false) throws -> Data {
        let items: [[String: Any]] = page.map {
            ["id": $0.id, "event_hash": "event-\($0.id)", "timestamp_ms": $0.timestamp,
             "api_key_hash": targetHash, "resolved_model": "test-model", "output_tokens": 1, "total_tokens": 1]
        }
        return try JSONSerialization.data(withJSONObject: ["events": [
            "items": items, "has_more": hasMore, "next_before_ms": page.last?.timestamp ?? 0,
            "next_before_id": page.last?.id ?? 0, "total_count": page.count]])
    }
    func legacyData() throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let details: [[String: Any]] = events.map {
            ["timestamp": formatter.string(from: Date(timeIntervalSince1970: Double($0.timestamp) / 1_000)),
             "api_key_hash": targetHash, "resolved_model": "test-model",
             "tokens": ["output_tokens": 1, "total_tokens": 1]]
        }
        return try JSONSerialization.data(withJSONObject: ["apis": ["endpoint": ["models": [
            "test-model": ["details": details]]]]])
    }
}

private final class Fixture {
    static let key = "synthetic-pipeline-key"
    static let hostname = "pipeline-fixture"
    let directory: URL
    let configuration: URL
    let ledger: UsageLedgerStore
    let identity = CliProxyUsageParser.apiKeyIdentity(for: Fixture.key)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cpa-verification-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        configuration = directory.appendingPathComponent("fixture.env")
        let data = Data("CLIPROXY_BASE_URL=https://fixture.invalid\nCLIPROXY_MANAGEMENT_KEY=synthetic\nCLIPROXY_TARGET_API_KEY=\(Self.key)\n".utf8)
        guard FileManager.default.createFile(atPath: configuration.path, contents: data,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw CheckFailure.assertion("fixture creation")
        }
        ledger = try UsageLedgerStore(path: directory.appendingPathComponent("usage.sqlite3").path)
    }
    func states() throws -> [String: CliProxyCollectionState] {
        try ledger.cliProxyCollectionStates(identities: [identity], hostname: Self.hostname)
    }
    func tokens() throws -> Int64 {
        try ledger.buckets(hostname: Self.hostname).reduce(0) { $0 + $1.counts.total }
    }
    @discardableResult
    func round(_ remote: FakeCPA, now: Int64 = 10_000_000, auditPages: Int = 1) async throws -> CliProxyCollectionState {
        let service = CliProxyUsageService { try await remote.transport($0) }
        let result = try await service.collectUsage(atPath: configuration.path, statesByIdentity: states(),
            options: CliProxyCollectionOptions(pageSize: 2, auditPageBudget: auditPages),
            now: Date(timeIntervalSince1970: Double(now) / 1_000))
        for collection in result.collections {
            try ledger.commitCliProxyCollection(collection, hostname: Self.hostname)
            try collection.removeStaging()
        }
        return try states()[identity]!
    }
    deinit {
        do { try FileManager.default.removeItem(at: directory) }
        catch { NSLog("CPA verification cleanup failed") }
    }
}

private actor FakeTokens: TokenSupplying {
    private var calls: [Bool] = []
    let switchedAccount: Bool
    init(switchedAccount: Bool = false) { self.switchedAccount = switchedAccount }
    func token(forceRefresh: Bool) throws -> SecretToken {
        calls.append(forceRefresh)
        let subject = forceRefresh && switchedAccount ? "second" : "first"
        let claims = try JSONSerialization.data(withJSONObject: ["iss": "fixture", "sub": subject, "nonce": calls.count])
        return SecretToken("header." + claims.base64EncodedString() + ".signature")
    }
    func history() -> [Bool] { calls }
}

private actor FakeIngest: HTTPRequestSending {
    var statuses: [Int]
    var requests = 0
    let unknownOutcome: Bool
    init(_ statuses: [Int], unknownOutcome: Bool = false) { self.statuses = statuses; self.unknownOutcome = unknownOutcome }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests += 1
        if unknownOutcome { throw HTTPTransportError.requestOutcomeUnknown }
        return HTTPResponse(statusCode: statuses.removeFirst(),
            body: Data("{\"buckets_upserted\":0,\"sessions_upserted\":0}".utf8))
    }
    func count() -> Int { requests }
}

private final class OversizedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
            httpVersion: nil, headerFields: ["Transfer-Encoding": "chunked"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 128))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
private struct CliProxyPipelineVerification {
    static func main() async throws {
        try await verifyLateEventsAndRecovery()
        try await verifyProtocolMigration()
        try await verifyCommitCancellation()
        try await verifyBoundedBackfill()
        try await verifyTokenReuse()
        try await verifyResponseBound()
        print("CliProxyPipelineVerification: PASS (late events, persisted audit, protocol migration, atomic retry, token reuse, byte limit)")
    }

    private static func verifyLateEventsAndRecovery() async throws {
        let fixture = try Fixture()
        let remote = FakeCPA(events: [.init(id: 1, timestamp: 10_000_000), .init(id: 2, timestamp: 10_000_000),
                                     .init(id: 3, timestamp: 1_000)], key: Fixture.key)
        await remote.failRequest(2)
        do { try await fixture.round(remote); throw CheckFailure.assertion("failed source committed") }
        catch let error as CliProxyUsageError { try check(error == .network, "failure classification") }
        try check(fixture.tokens() == 0, "partial pages must not reach the ledger")
        try check(fixture.states()[fixture.identity]?.endpoint == .discover, "failed source advanced state")
        await remote.failRequest(nil)
        let state = try await fixture.round(remote)
        try check(state.auditBeforeMS != nil, "audit cursor must persist across rounds")
        try check(fixture.tokens() == 2, "new events must publish before historical sweep finishes")
        await remote.append(.init(id: 4, timestamp: 10_000_000))
        await remote.append(.init(id: 5, timestamp: 500))
        _ = try await fixture.round(remote, now: 10_000_001)
        try check(fixture.tokens() == 5, "same-ms boundary and arbitrarily old late event were skipped")
        await remote.append(.init(id: 6, timestamp: 9_000_000))
        for _ in 0..<5 { try await fixture.round(remote, now: 10_000_002) }
        try check(fixture.tokens() == 6, "insert behind a passed cursor must appear on the next sweep")
        let before = try fixture.states()
        await remote.setSupported(false)
        do { try await fixture.round(remote); throw CheckFailure.assertion("pinned analytics switched protocol") }
        catch is CliProxyUsageError {}
        try check(await remote.legacyCount() == 0, "pinned analytics must never call legacy")
        try check(fixture.states() == before && fixture.tokens() == 6, "protocol failure changed ledger/state")
    }

    private static func verifyProtocolMigration() async throws {
        let fixture = try Fixture()
        let remote = FakeCPA(events: [.init(id: 1, timestamp: 1_000)], key: Fixture.key)
        let oldData = try await remote.analyticsData([.init(id: 1, timestamp: 1_000)])
        let old = try CliProxyUsageParser.parseAnalyticsPage(data: oldData, targetAPIKey: Fixture.key).events
        try fixture.ledger.recordNetworkEvents(old, source: CliProxyUsageParser.source, hostname: Fixture.hostname)
        await remote.append(.init(id: 2, timestamp: 9_000_000))
        await remote.append(.init(id: 3, timestamp: 8_000_000))
        let partial = try await fixture.round(remote)
        try check(partial.endpoint == .detectingAnalytics && partial.auditBeforeMS != nil,
                  "first page with no matching old ID must keep resumable migration")
        try check(fixture.tokens() == 1, "unproved protocol appended new events")
        let resolved = try await fixture.round(remote)
        try check(resolved.endpoint == .analytics, "later matching ID must resolve migration")
        for _ in 0..<3 { try await fixture.round(remote) }
        try check(fixture.tokens() == 3, "confirmed migration must recover historical and new events")

        let mixed = try Fixture()
        let legacy = CliProxyUsageParser.parse(data: try await remote.legacyData(), targetAPIKey: Fixture.key)
        try mixed.ledger.recordNetworkEvents(old + legacy, source: CliProxyUsageParser.source, hostname: Fixture.hostname)
        for _ in 0..<2 { try await mixed.round(remote, auditPages: 4) }
        try check(mixed.states()[mixed.identity]?.endpoint == .mixed, "mixed old ID domains must be diagnosed")
        try check(mixed.tokens() == 4, "mixed migration must preserve existing statistics")

        let unknown = try Fixture()
        let orphan = UsageEvent(id: "unmatched-old-event", source: CliProxyUsageParser.source,
            model: "test-model", project: unknown.identity, timestamp: Date(timeIntervalSince1970: 1),
            counts: UsageTokenCounts(output: 1), sessionHash: unknown.identity, sourceFileHash: unknown.identity)
        try unknown.ledger.recordNetworkEvents([orphan], source: CliProxyUsageParser.source, hostname: Fixture.hostname)
        for _ in 0..<2 { try await unknown.round(remote, auditPages: 4) }
        try check(unknown.states()[unknown.identity]?.endpoint == .unresolved && unknown.tokens() == 1,
                  "unmatched legacy data must fail closed without removal")
    }

    private static func verifyTokenReuse() async throws {
        let source = FakeTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let sender = FakeIngest([200, 401, 200, 200])
        let configuration = IngestClientConfiguration(baseURL: URL(string: "https://fixture.invalid"), path: "/ingest")
        let client = UsageIngestClient(configuration: configuration, tokenSupplier: supplier, sender: sender)
        for _ in 0..<3 { try await client.ingest(UsageIngestRequest()) }
        try check(await source.history() == [false, true], "report must reuse initial and refreshed tokens")
        let switched = FakeTokens(switchedAccount: true)
        let guarded = UsageIngestClient(configuration: configuration,
            tokenSupplier: ReportTokenSupplier(supplier: switched), sender: FakeIngest([401]))
        do { try await guarded.ingest(UsageIngestRequest()); throw CheckFailure.assertion("identity switch accepted") }
        catch let error as IngestClientError { try check(error == .authIdentityChanged, "identity refresh fence") }
        let uncertain = FakeIngest([], unknownOutcome: true)
        let noRetry = UsageIngestClient(configuration: configuration, tokenSupplier: supplier, sender: uncertain)
        do { try await noRetry.ingest(UsageIngestRequest()); throw CheckFailure.assertion("unknown outcome accepted") }
        catch let error as IngestClientError { try check(error == .transportFailure, "unknown outcome classification") }
        try check(await uncertain.count() == 1, "unknown send outcome must not be retried")
    }

    private static func verifyCommitCancellation() async throws {
        let fixture = try Fixture()
        let remote = FakeCPA(events: [.init(id: 1, timestamp: 10_000_000), .init(id: 2, timestamp: 1_000)], key: Fixture.key)
        let service = CliProxyUsageService { try await remote.transport($0) }
        let fetched = try await service.collectUsage(atPath: fixture.configuration.path, statesByIdentity: fixture.states(),
            options: CliProxyCollectionOptions(pageSize: 1, auditPageBudget: 1),
            now: Date(timeIntervalSince1970: 10_000))
        var checks = 0
        do {
            try fixture.ledger.commitCliProxyCollection(fetched.collections[0], hostname: Fixture.hostname) {
                checks += 1
                if checks == 3 { throw CancellationError() }
            }
            throw CheckFailure.assertion("cancelled commit succeeded")
        } catch is CancellationError {}
        try check(fixture.tokens() == 0 && fixture.states()[fixture.identity]?.endpoint == .discover,
                  "cancel after first page must roll back raw events and cursor together")
    }

    private static func verifyBoundedBackfill() async throws {
        let fixture = try Fixture()
        let remote = FakeCPA(events: (1...8).map { .init(id: Int64($0), timestamp: 10_000_000) }, key: Fixture.key)
        let service = CliProxyUsageService { try await remote.transport($0) }
        let options = CliProxyCollectionOptions(pageSize: 1, auditPageBudget: 1,
                                                incrementalPageBudget: 1, backfillPageBudget: 1)
        func collect(_ now: Int64) async throws -> CliProxyCollectionState {
            let result = try await service.collectUsage(atPath: fixture.configuration.path,
                statesByIdentity: fixture.states(), options: options,
                now: Date(timeIntervalSince1970: Double(now) / 1_000))
            return try fixture.ledger.commitCliProxyCollection(result.collections[0], hostname: Fixture.hostname)
        }
        let first = try await collect(10_000_000)
        try check(first.backfill?.beforeID == 7 && fixture.tokens() == 2, "bounded incremental backlog must commit progress")
        let reopened = try UsageLedgerStore(path: fixture.directory.appendingPathComponent("usage.sqlite3").path)
        let persisted = try reopened.cliProxyCollectionStates(identities: [fixture.identity], hostname: Fixture.hostname)
        try check(persisted[fixture.identity]?.backfill == first.backfill, "backfill cursor must survive opening another ledger")
        await remote.append(.init(id: 9, timestamp: 10_000_001))
        let second = try await collect(10_000_001)
        try check(second.backfill?.beforeID == 6 && second.backfill?.throughMS == 10_000_000,
                  "new arrivals must not reset an active backlog cursor")
        try check(second.queuedBackfillThroughMS == 10_000_001 && fixture.tokens() == 4,
                  "newest event must publish while a separate overflow range is queued")
        for tick in 2...20 { _ = try await collect(10_000_000 + Int64(tick)) }
        try check(fixture.tokens() == 9 && fixture.states()[fixture.identity]?.backfill == nil,
                  "all overflow ranges must drain without depending on a single unbounded request")

        let capped = try Fixture()
        do {
            _ = try await service.collectUsage(atPath: capped.configuration.path, statesByIdentity: capped.states(),
                options: CliProxyCollectionOptions(pageSize: 1, maximumStagingBytes: 64),
                now: Date(timeIntervalSince1970: 10_000))
            throw CheckFailure.assertion("total normalized staging byte cap ignored")
        } catch let error as CliProxyUsageError { try check(error == .responseTooLarge, "staging byte cap classification") }
        try check(capped.tokens() == 0 && capped.states()[capped.identity]?.endpoint == .discover,
                  "staging limit must not advance data or collection state")
    }

    private static func verifyResponseBound() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await CliProxyUsageService.boundedResponse(for: URLRequest(url: URL(string: "https://fixture.invalid")!),
                                                               session: session, maximumBytes: 64)
            throw CheckFailure.assertion("chunked oversized response accepted")
        } catch let error as CliProxyUsageError { try check(error == .responseTooLarge, "stream byte bound") }
    }
}
