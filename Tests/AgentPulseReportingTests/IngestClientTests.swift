import XCTest
@testable import AgentPulseReporting

final class IngestClientTests: XCTestCase {
    private func headerNames() -> RequestHeaderNames {
        RequestHeaderNames(authToken: "X-Test-Auth-Token", timeZoneOffset: "X-Test-Time-Zone-Offset", locale: "X-Test-Locale")
    }
    private func configured(base: String = "https://example.invalid", path: String = "/api/usage/ingest") -> IngestClientConfiguration {
        IngestClientConfiguration(
            baseURL: URL(string: base),
            path: path,
            hostname: "host-a",
            headerNames: headerNames(),
            staticHeaders: [StaticHeader(name: "X-Test-Client", value: "test-client"), StaticHeader(name: "X-Test-Client-Version", value: "1.2.3")],
            localeEnvironmentVariables: ["TEST_LANG"]
        )
    }
    private func ok() -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            body: Data("{\"buckets_upserted\":1,\"sessions_upserted\":0,\"autonomy_sessions_upserted\":0}".utf8)
        )
    }
    private func request() -> UsageIngestRequest { UsageIngestRequest(buckets: [UsageBucketPayload(source: "codex", model: "gpt", project: "demo", bucketStart: "t", totalTokens: 1)]) }
    private func stableJWT(_ subject: String) -> String { makeTestJWT("{\"iss\":\"issuer\",\"sub\":\"\(subject)\"}") }

    func testUnconfiguredClientSendsNothing() async {
        let sender = CapturingSender(responses: [ok()])
        let supplier = StubTokenSupplier(tokens: ["t"])
        let client = UsageIngestClient(configuration: IngestClientConfiguration(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); XCTFail("expected configurationMissing") }
        catch { XCTAssertEqual(error as? IngestClientError, .configurationMissing) }
        XCTAssertTrue(sender.requests.isEmpty)
        XCTAssertTrue(supplier.calls.isEmpty)
    }

    func testBuildsURLMethodAndHeaders() async throws {
        let sender = CapturingSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: StubTokenSupplier(tokens: ["tok-1"]), sender: sender, environment: [:], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let result = try await client.ingest(request())
        XCTAssertEqual(result.bucketsUpserted, 1)
        let req = sender.requests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://example.invalid/api/usage/ingest")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Test-Auth-Token"), "tok-1")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Test-Client"), "test-client")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Test-Client-Version"), "1.2.3")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Test-Time-Zone-Offset"), "+08:00")
        XCTAssertNil(req.value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Test-Locale"))
    }

    func testLocaleHeaderResolvedFromEnvironment() async throws {
        let sender = CapturingSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: StubTokenSupplier(tokens: ["t"]), sender: sender, environment: ["TEST_LANG": "ja_JP.UTF-8"])
        _ = try await client.ingest(request())
        XCTAssertEqual(sender.requests[0].value(forHTTPHeaderField: "X-Test-Locale"), "ja-JP")
    }

    func testSmallBodyNotGzipped() async throws {
        let sender = CapturingSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: StubTokenSupplier(tokens: ["t"]), sender: sender)
        _ = try await client.ingest(request())
        XCTAssertNil(sender.requests[0].value(forHTTPHeaderField: "Content-Encoding"))
        XCTAssertTrue(String(decoding: sender.requests[0].httpBody ?? Data(), as: UTF8.self).contains("\"buckets\""))
    }

    func testLargeBodyGzipped() async throws {
        let sender = CapturingSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: StubTokenSupplier(tokens: ["t"]), sender: sender)
        let buckets = (0..<40).map { i in UsageBucketPayload(source: "codex", model: "gpt-model-\(i)", project: "project-\(i)", bucketStart: "2026-01-01T00:00:00Z", totalTokens: Int64(i)) }
        _ = try await client.ingest(UsageIngestRequest(buckets: buckets))
        XCTAssertEqual(sender.requests[0].value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        let body = sender.requests[0].httpBody ?? Data()
        XCTAssertEqual(body.first, 0x1f)
    }

    func testGzipThresholdConstant() {
        XCTAssertEqual(UsageIngestClient.gzipMinimumBytes, 1024)
        XCTAssertEqual(GzipCompressor.compress(Data(repeating: 0x41, count: 4096))?.first, 0x1f)
    }

    func test401TriggersSingleRefreshWhenIdentityStable() async throws {
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 401, body: Data()), ok()])
        let supplier = StubTokenSupplier(tokens: [stableJWT("s"), stableJWT("s")])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let result = try await client.ingest(request())
        XCTAssertEqual(result.bucketsUpserted, 1)
        XCTAssertEqual(supplier.calls, [false, true])
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testIdentityFenceAbortsWhenAccountChanges() async {
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 401, body: Data()), ok()])
        let supplier = StubTokenSupplier(tokens: [stableJWT("account-a"), stableJWT("account-b")])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); XCTFail("expected authIdentityChanged") }
        catch { XCTAssertEqual(error as? IngestClientError, .authIdentityChanged) }
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(supplier.calls, [false, true])
    }

    func testOpaqueTokenRefreshPassesFenceWhenUnchanged() async throws {
        // A non-JWT opaque token falls back to digest identity; the same opaque
        // value on refresh keeps the same identity and the retry succeeds.
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 401, body: Data()), ok()])
        let supplier = StubTokenSupplier(tokens: ["opaque-token", "opaque-token"])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let result = try await client.ingest(request())
        XCTAssertEqual(result.bucketsUpserted, 1)
        XCTAssertEqual(supplier.calls, [false, true])
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testOpaqueTokenRefreshFencesWhenChanged() async {
        // A changed opaque token yields a different digest identity, so the
        // fence aborts before sending the second request.
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 401, body: Data()), ok()])
        let supplier = StubTokenSupplier(tokens: ["opaque-token-a", "opaque-token-b"])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); XCTFail("expected authIdentityChanged") }
        catch { XCTAssertEqual(error as? IngestClientError, .authIdentityChanged) }
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(supplier.calls, [false, true])
    }

    func testPersistent401FailsAfterSingleRefresh() async {
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 401, body: Data()), HTTPResponse(statusCode: 401, body: Data())])
        let supplier = StubTokenSupplier(tokens: [stableJWT("s"), stableJWT("s")])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); XCTFail("expected notAuthenticated") }
        catch { XCTAssertEqual(error as? IngestClientError, .notAuthenticated) }
        XCTAssertEqual(supplier.calls, [false, true])
        XCTAssertEqual(sender.requests.count, 2)
    }

    func testNon401FailureSurfacesStatus() async {
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 500, body: Data("boom".utf8))])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: StubTokenSupplier(tokens: ["t"]), sender: sender)
        do { _ = try await client.ingest(request()); XCTFail("expected httpFailure") }
        catch { XCTAssertEqual(error as? IngestClientError, .httpFailure(statusCode: 500)) }
    }

    func testEndpointURLPreservesBasePath() throws {
        let client = UsageIngestClient(configuration: configured(base: "https://example.invalid/prefix/"), tokenSupplier: StubTokenSupplier(tokens: ["t"]))
        let url = try client.endpointURL()
        XCTAssertEqual(url.absoluteString, "https://example.invalid/prefix/api/usage/ingest")
    }

    func testTruncationCapsFieldLengths() {
        XCTAssertEqual(UsageIngestClient.truncate(String(repeating: "a", count: 50), 30).count, 30)
        let multibyte = String(repeating: "\u{6C49}", count: 20)
        XCTAssertEqual(Array(UsageIngestClient.truncate(multibyte, 10).utf8).count, 9)
    }

    func testCanonicalHostnameCapsUTF8BytesWithoutSplittingScalars() {
        XCTAssertEqual(CanonicalHostname.normalize("  host-a  "), "host-a")
        let byteLimit = 255
        XCTAssertEqual(CanonicalHostname.maximumByteCount, byteLimit)
        let shortASCII = String(repeating: "h", count: 250)
        XCTAssertEqual(CanonicalHostname.normalize(shortASCII), shortASCII)
        XCTAssertEqual(
            CanonicalHostname.normalize(String(repeating: "h", count: 300)),
            String(repeating: "h", count: byteLimit)
        )
        let emoji = "\u{1F600}"
        let normalizedEmoji = CanonicalHostname.normalize(String(repeating: emoji, count: 150))
        XCTAssertEqual(normalizedEmoji, String(repeating: emoji, count: byteLimit / emoji.utf8.count))
        XCTAssertLessThanOrEqual(normalizedEmoji.utf8.count, byteLimit)
        let exactlyFits = String(repeating: "h", count: byteLimit - emoji.utf8.count) + emoji
        XCTAssertEqual(CanonicalHostname.normalize(exactlyFits), exactlyFits)
        let prefixBeforePartialScalar = String(repeating: "h", count: byteLimit - emoji.utf8.count + 1)
        XCTAssertEqual(CanonicalHostname.normalize(prefixBeforePartialScalar + emoji), prefixBeforePartialScalar)
    }

    func testHostnameCanonicalizedIntoPayload() async throws {
        let sender = CapturingSender(responses: [ok()])
        let config = IngestClientConfiguration(baseURL: URL(string: "https://example.invalid"), path: "/api/usage/ingest", hostname: "  host-a  ", headerNames: headerNames())
        let client = UsageIngestClient(configuration: config, tokenSupplier: StubTokenSupplier(tokens: ["t"]), sender: sender)
        _ = try await client.ingest(request())
        XCTAssertTrue(String(decoding: sender.requests[0].httpBody ?? Data(), as: UTF8.self).contains("\"hostname\":\"host-a\""))
    }

    // MARK: - 413 autonomy fallback

    private func autonomyRequest() -> UsageIngestRequest {
        let autonomy = AutonomySessionPayload(source: "codex", project: "demo", sessionHash: "auto-hash", firstEventAt: "a", lastEventAt: "b", autonomyStatus: "autonomous", confidence: "high", computedAt: "c")
        let status = AutonomySourceStatusPayload(source: "codex", status: "ok")
        let bucket = UsageBucketPayload(source: "codex", model: "gpt", project: "demo", bucketStart: "bucket-time", totalTokens: 1)
        let session = UsageSessionPayload(source: "codex", project: "demo", sessionHash: "session-hash", firstMessageAt: "a", lastMessageAt: "b")
        return UsageIngestRequest(buckets: [bucket], sessions: [session], autonomySessions: [autonomy], autonomySourceStatuses: [status], autonomyWindowStart: "w1", autonomyWindowEnd: "w2", fullSync: true, fullSyncReset: true)
    }

    func test413StripsAutonomyAndResendsOnce() async throws {
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 413, body: Data()), ok()])
        let supplier = StubTokenSupplier(tokens: ["t"])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let result = try await client.ingest(autonomyRequest())
        XCTAssertEqual(result.bucketsUpserted, 1)

        XCTAssertEqual(sender.requests.count, 2, "degraded body must be resent exactly once")
        XCTAssertEqual(supplier.calls, [false], "413 fallback must not refresh the token")

        let firstBody = String(decoding: sender.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(firstBody.contains("\"autonomySessions\":["))
        XCTAssertTrue(firstBody.contains("\"autonomySourceStatuses\":["))
        XCTAssertTrue(firstBody.contains("\"autonomyWindowStart\":\"w1\""))
        XCTAssertTrue(firstBody.contains("\"autonomyWindowEnd\":\"w2\""))
        XCTAssertTrue(firstBody.contains("\"bucketStart\":\"bucket-time\""))
        XCTAssertTrue(firstBody.contains("\"sessionHash\":\"session-hash\""))
        XCTAssertTrue(firstBody.contains("\"fullSync\":true"))

        let second = sender.requests[1]
        let secondBody = String(decoding: second.httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(secondBody.contains("autonomy"), "degraded body must carry no autonomy fields")
        XCTAssertTrue(secondBody.contains("\"bucketStart\":\"bucket-time\""), "buckets must survive the fallback")
        XCTAssertTrue(secondBody.contains("\"sessionHash\":\"session-hash\""), "sessions must survive the fallback")
        XCTAssertTrue(secondBody.contains("\"fullSync\":true"), "fullSync flag must survive the fallback")
        XCTAssertTrue(secondBody.contains("\"fullSyncReset\":true"), "fullSyncReset flag must survive the fallback")
        // The degraded request is rebuilt from scratch, headers included.
        XCTAssertEqual(second.url?.absoluteString, "https://example.invalid/api/usage/ingest")
        XCTAssertEqual(second.value(forHTTPHeaderField: "X-Test-Auth-Token"), "t")
        XCTAssertEqual(second.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(second.value(forHTTPHeaderField: "Content-Encoding"))
    }

    func test413WithoutAutonomyFailsImmediately() async {
        // Even when 413 is configured as retryable, it must not be treated as
        // generic backoff: a body with no autonomy fields fails on the first
        // response.
        let retryPolicy = RetryPolicy(maxRetries: 3, retryableStatusCodes: [413, 502, 503, 504])
        let config = IngestClientConfiguration(
            baseURL: URL(string: "https://example.invalid"),
            path: "/api/usage/ingest",
            hostname: "host-a",
            headerNames: headerNames(),
            retryPolicy: retryPolicy
        )
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 413, body: Data())])
        let supplier = StubTokenSupplier(tokens: ["t"])
        let client = UsageIngestClient(configuration: config, tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); XCTFail("expected httpFailure 413") }
        catch { XCTAssertEqual(error as? IngestClientError, .httpFailure(statusCode: 413)) }
        XCTAssertEqual(sender.requests.count, 1)
        XCTAssertEqual(supplier.calls, [false])
    }

    func testDegraded413FailsAfterSingleResend() async {
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 413, body: Data()), HTTPResponse(statusCode: 413, body: Data())])
        let supplier = StubTokenSupplier(tokens: ["t"])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(autonomyRequest()); XCTFail("expected httpFailure 413") }
        catch { XCTAssertEqual(error as? IngestClientError, .httpFailure(statusCode: 413)) }
        XCTAssertEqual(sender.requests.count, 2, "degraded body is resent at most once")
        XCTAssertEqual(supplier.calls, [false])
        let secondBody = String(decoding: sender.requests[1].httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(secondBody.contains("autonomy"))
    }

    func testReportTokenSupplierCoalescesConcurrentFirstAcquisition() async throws {
        let source = ControlledReportTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let tasks = (0..<8).map { _ in Task { try await supplier.token(forceRefresh: false) } }
        try await waitForWaiters(supplier, count: tasks.count)
        try await waitForCalls(source, count: 1)
        let expected = stableJWT("first")
        try await source.complete(0, with: .success(SecretToken(expected)))
        for task in tasks { let token = try await task.value; XCTAssertEqual(token.reveal(), expected) }
        let cached = try await supplier.token(forceRefresh: false)
        XCTAssertEqual(cached.reveal(), expected)
        let history = await source.history()
        XCTAssertEqual(history, [false])
    }

    func testReportTokenSupplierCoalescesForceOverlappingInitialAndRefresh() async throws {
        let source = ControlledReportTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let initial = Task { try await supplier.token(forceRefresh: false) }
        try await waitForWaiters(supplier, count: 1)
        try await waitForCalls(source, count: 1)
        let forced = (0..<2).map { _ in Task { try await supplier.token(forceRefresh: true) } }
        try await waitForWaiters(supplier, count: 3)
        let first = stableJWT("first")
        let refreshed = makeTestJWT("{\"iss\":\"issuer\",\"sub\":\"first\",\"nonce\":2}")
        try await source.complete(0, with: .success(SecretToken(first)))
        let original = try await initial.value
        XCTAssertEqual(original.reveal(), first)
        try await waitForCalls(source, count: 2)
        let overlapping = Task { try await supplier.token(forceRefresh: true) }
        let ordinary = Task { try await supplier.token(forceRefresh: false) }
        try await waitForWaiters(supplier, count: 4)
        try await source.complete(1, with: .success(SecretToken(refreshed)))
        for task in forced + [overlapping, ordinary] {
            let token = try await task.value
            XCTAssertEqual(token.reveal(), refreshed)
        }
        let history = await source.history()
        XCTAssertEqual(history, [false, true])
    }

    func testReportTokenSupplierHonorsQueuedForceAfterInitialFailure() async throws {
        let source = ControlledReportTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let initial = Task { try await supplier.token(forceRefresh: false) }
        try await waitForCalls(source, count: 1)
        let forced = (0..<2).map { _ in Task { try await supplier.token(forceRefresh: true) } }
        try await waitForWaiters(supplier, count: 3)
        try await source.complete(0, with: .failure(URLError(.timedOut)))
        do { _ = try await initial.value; XCTFail("expected initial acquisition failure") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        try await waitForCalls(source, count: 2)
        let expected = stableJWT("first")
        try await source.complete(1, with: .success(SecretToken(expected)))
        for task in forced { let token = try await task.value; XCTAssertEqual(token.reveal(), expected) }
        let history = await source.history()
        XCTAssertEqual(history, [false, true])
    }

    func testReportTokenSupplierFencesSharedRefreshAndRecoversFromFailure() async throws {
        let source = ControlledReportTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let first = stableJWT("first")
        let initial = Task { try await supplier.token(forceRefresh: false) }
        try await waitForCalls(source, count: 1)
        try await source.complete(0, with: .success(SecretToken(first)))
        _ = try await initial.value
        let rejected = (0..<2).map { _ in Task { try await supplier.token(forceRefresh: true) } }
        try await waitForWaiters(supplier, count: 2)
        try await waitForCalls(source, count: 2)
        try await source.complete(1, with: .success(SecretToken(stableJWT("different"))))
        for task in rejected {
            do { _ = try await task.value; XCTFail("expected identity fence") }
            catch { XCTAssertEqual(error as? IngestClientError, .authIdentityChanged) }
        }
        let retained = try await supplier.token(forceRefresh: false)
        XCTAssertEqual(retained.reveal(), first)
        let failed = (0..<2).map { _ in Task { try await supplier.token(forceRefresh: true) } }
        try await waitForWaiters(supplier, count: 2)
        try await waitForCalls(source, count: 3)
        try await source.complete(2, with: .failure(URLError(.timedOut)))
        for task in failed {
            do { _ = try await task.value; XCTFail("expected helper failure") }
            catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        }
        let retry = Task { try await supplier.token(forceRefresh: true) }
        try await waitForCalls(source, count: 4)
        try await source.complete(3, with: .success(SecretToken(first)))
        let recovered = try await retry.value
        XCTAssertEqual(recovered.reveal(), first)
        let history = await source.history()
        XCTAssertEqual(history, [false, true, true, true])
    }

    func testReportTokenSupplierCancellationDoesNotCancelOtherWaiters() async throws {
        let source = ControlledReportTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let cancelled = Task { try await supplier.token(forceRefresh: false) }
        let surviving = Task { try await supplier.token(forceRefresh: false) }
        try await waitForWaiters(supplier, count: 2)
        try await waitForCalls(source, count: 1)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("expected immediate cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitForWaiters(supplier, count: 1)
        try await source.complete(0, with: .success(SecretToken(stableJWT("first"))))
        _ = try await surviving.value
        let cancellations = await source.cancelledCalls()
        let history = await source.history()
        XCTAssertTrue(cancellations.isEmpty)
        XCTAssertEqual(history, [false])
    }

    func testReportTokenSupplierDropsLateResultAfterLastWaiterCancels() async throws {
        let source = ControlledReportTokens()
        let supplier = ReportTokenSupplier(supplier: source)
        let abandoned = Task { try await supplier.token(forceRefresh: false) }
        try await waitForCalls(source, count: 1)
        abandoned.cancel()
        do { _ = try await abandoned.value; XCTFail("expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitForWaiters(supplier, count: 0)
        let replacement = Task { try await supplier.token(forceRefresh: false) }
        try await waitForCalls(source, count: 2)
        try await source.complete(0, with: .success(SecretToken(stableJWT("abandoned"))))
        try await source.complete(1, with: .success(SecretToken(stableJWT("replacement"))))
        let token = try await replacement.value
        XCTAssertEqual(token.reveal(), stableJWT("replacement"))
        let cached = try await supplier.token(forceRefresh: false)
        XCTAssertEqual(cached.reveal(), token.reveal())
        try await waitForCondition { await source.cancelledCalls() == [0] }
    }

    private func waitForWaiters(_ supplier: ReportTokenSupplier, count: Int) async throws {
        try await waitForCondition { await supplier.pendingWaiterCount == count }
    }

    private func waitForCalls(_ source: ControlledReportTokens, count: Int) async throws {
        try await waitForCondition { await source.history().count == count }
    }

    private func waitForCondition(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            guard Date() < deadline else { throw ReportTokenFixtureError.timeout }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func test413RebuildsGzipAndHeaders() async throws {
        // An oversized autonomy section pushes the first body past the gzip
        // threshold; the degraded body drops back below it, proving the JSON,
        // the gzip decision, and the headers are rebuilt rather than reused.
        let autonomy = AutonomySessionPayload(source: "codex", project: "demo", sessionHash: "h", firstEventAt: "a", lastEventAt: "b", autonomyStatus: "autonomous", confidence: "high", confidenceReasons: [String(repeating: "x", count: 2048)], computedAt: "c")
        let request = UsageIngestRequest(buckets: [UsageBucketPayload(source: "codex", model: "gpt", project: "demo", bucketStart: "t", totalTokens: 1)], autonomySessions: [autonomy])
        let sender = CapturingSender(responses: [HTTPResponse(statusCode: 413, body: Data()), ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: StubTokenSupplier(tokens: ["t"]), sender: sender)
        _ = try await client.ingest(request)
        XCTAssertEqual(sender.requests[0].value(forHTTPHeaderField: "Content-Encoding"), "gzip")
        XCTAssertEqual(sender.requests[0].httpBody?.first, 0x1f)
        XCTAssertNil(sender.requests[1].value(forHTTPHeaderField: "Content-Encoding"))
        let secondBody = String(decoding: sender.requests[1].httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(secondBody.contains("autonomy"))
        XCTAssertTrue(secondBody.contains("\"bucketStart\":\"t\""))
    }
}

private enum ReportTokenFixtureError: Error { case timeout, missingCall }

/// Explicitly released calls keep concurrent requests overlapping. Deliberately
/// returns after cancellation to exercise the supplier's stale-generation fence.
private actor ControlledReportTokens: TokenSupplying {
    private var calls: [Bool] = []
    private var cancelled: [Int] = []
    private var pending: [Int: CheckedContinuation<SecretToken, Error>] = [:]
    func token(forceRefresh: Bool) async throws -> SecretToken {
        let index = calls.count
        calls.append(forceRefresh)
        let token = try await withCheckedThrowingContinuation { pending[index] = $0 }
        if Task.isCancelled { cancelled.append(index) }
        return token
    }
    func complete(_ index: Int, with result: Result<SecretToken, Error>) throws {
        guard let continuation = pending.removeValue(forKey: index) else { throw ReportTokenFixtureError.missingCall }
        continuation.resume(with: result)
    }
    func history() -> [Bool] { calls }
    func cancelledCalls() -> [Int] { cancelled }
}
