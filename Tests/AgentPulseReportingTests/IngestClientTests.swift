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

    func testCanonicalHostnameCapsScalars() {
        XCTAssertEqual(CanonicalHostname.normalize("  host-a  "), "host-a")
        XCTAssertEqual(CanonicalHostname.normalize(String(repeating: "h", count: 250)).unicodeScalars.count, 100)
        XCTAssertEqual(CanonicalHostname.normalize(String(repeating: "\u{1F600}", count: 150)).unicodeScalars.count, 100)
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
