import AgentPulseReporting
import Foundation

// Dependency-free verification of the reporting library. The unit tests use
// XCTest, which is unavailable under the Command Line Tools toolchain, so this
// executable mirrors the same assertions and can be run with
// swift run AgentPulseReportingVerification. All fixtures use generic,
// non-routable values (example.com, X-Test-* headers).
@main
struct AgentPulseReportingVerification {
    static func main() async throws {
        try verifyTokenConfigGating()
        try verifyTokenParsing()
        try verifyTokenRedaction()
        try verifyCanonicalHostname()
        try verifyEncoderOmitEmptyAndOrder()
        try verifyEncoderOptionalFields()
        try verifyEncoderAutonomyAndFlags()
        try verifyEncoderEscaping()
        try verifyResponseAcknowledgementDecoding()
        try verifyGzip()
        try verifyTruncation()
        try verifyIdentity()
        try await verifyClientConfigGating()
        try await verifyClientHeaders()
        try await verifyLocaleHeader()
        try await verifySmallBodyNotGzipped()
        try await verifyLargeBodyGzipped()
        try await verify401SingleRefresh()
        try await verifyIdentityFence()
        try await verifyPersistent401Fails()
        try await verifyNon401Failure()
        try await verifyMalformedAcknowledgementResponses()
        try await verifyRetryableStatusCodes()
        try await verifyRequestNotWrittenRetry()
        try await verifyOtherTransportFailureNoRetry()
        try await verifyConfigured500Retry()
        try await verifyNonIngestErrorsDontGate()
        print("AgentPulseReporting verification passed")
    }

    enum VerificationError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case let .failed(m) = self { return m }; return "failed" }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }
    private static func jsonString(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    // MARK: - Token provider

    private static var providerConfig: CommandTokenProviderConfiguration {
        CommandTokenProviderConfiguration(
            executable: "/usr/bin/env",
            arguments: ["auth-helper", "get-token"],
            forceRefreshArguments: ["--force-refresh"],
            statusKey: "status",
            successStatus: "success",
            errorKey: "error",
            tokenKeyPath: ["data", "token"]
        )
    }

    private static func verifyTokenConfigGating() throws {
        var ran = false
        let runner = ClosureRunner { _, _ in ran = true; return ProcessResult(exitCode: 0, standardOutput: Data()) }
        let provider = ConfiguredCommandTokenProvider(configuration: CommandTokenProviderConfiguration(), runner: runner)
        do { _ = try provider.token(); try expect(false, "expected configurationMissing") }
        catch let e as TokenProviderError { try expect(e == .configurationMissing, "wrong error: \(e)") }
        try expect(!ran, "unconfigured provider must not run a process")
    }

    private static func verifyTokenParsing() throws {
        let token = try ConfiguredCommandTokenProvider.parseToken(
            from: Data("{\"status\":\"success\",\"data\":{\"token\":\"abc\"}}".utf8),
            configuration: providerConfig
        )
        try expect(token.reveal() == "abc", "token parse mismatch")

        let runner = ClosureRunner { exe, args in
            try expect(exe == "/usr/bin/env", "executable")
            try expect(args == ["auth-helper", "get-token", "--force-refresh"], "force-refresh args: \(args)")
            return ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"t\"}}".utf8))
        }
        _ = try ConfiguredCommandTokenProvider(configuration: providerConfig, runner: runner).token(forceRefresh: true)

        try expectParseThrows(Data("nope".utf8), .malformedOutput, "malformed")
        try expectParseThrows(Data("{\"status\":\"error\",\"error\":\"x\",\"data\":{\"token\":\"t\"}}".utf8), .unsuccessfulResponse, "status")
        try expectParseThrows(Data("{\"status\":\"success\",\"error\":\"boom\"}".utf8), .unsuccessfulResponse, "error field")
        try expectParseThrows(Data("{\"status\":\"success\",\"data\":{\"token\":\"\"}}".utf8), .missingToken, "empty token")

        let failRunner = ClosureRunner { _, _ in ProcessResult(exitCode: 9, standardOutput: Data()) }
        do { _ = try ConfiguredCommandTokenProvider(configuration: providerConfig, runner: failRunner).token(); try expect(false, "expected failure") }
        catch let e as TokenProviderError { try expect(e == .commandFailed(exitCode: 9), "exit: \(e)") }
    }

    private static func expectParseThrows(_ data: Data, _ expected: TokenProviderError, _ label: String) throws {
        do { _ = try ConfiguredCommandTokenProvider.parseToken(from: data, configuration: providerConfig); try expect(false, "expected throw: \(label)") }
        catch let e as TokenProviderError { try expect(e == expected, "wrong error for \(label): \(e)") }
    }

    private static func verifyTokenRedaction() throws {
        let token = SecretToken("super-secret")
        try expect(!("\(token)".contains("super-secret")), "description leaked")
        try expect(!String(reflecting: token).contains("super-secret"), "debug leaked")
        try expect(token.description == "SecretToken(redacted)", "redaction text")
    }

    // MARK: - Hostname

    private static func verifyCanonicalHostname() throws {
        try expect(CanonicalHostname.normalize("  host-a  ") == "host-a", "trim")
        // UTF-8 byte cap at 255 bytes, not scalar count.
        let long = String(repeating: "h", count: 300)
        let normalized = CanonicalHostname.normalize(long)
        try expect(Array(normalized.utf8).count == 255, "utf8 byte cap")
        // Multi-byte characters respect byte boundaries.
        let multibyte = String(repeating: "\u{6C49}", count: 100)
        let multiNorm = CanonicalHostname.normalize(multibyte)
        let multiBytes = Array(multiNorm.utf8).count
        try expect(multiBytes <= 255, "multibyte must not exceed 255 bytes")
        try expect(multiBytes >= 252, "multibyte should be close to cap")
        // Emoji (4-byte UTF-8) must also respect byte boundaries.
        let emoji = String(repeating: "\u{1F600}", count: 70)
        let emojiNorm = CanonicalHostname.normalize(emoji)
        let emojiBytes = Array(emojiNorm.utf8).count
        try expect(emojiBytes <= 255, "emoji must not exceed 255 bytes")
        try expect(emojiBytes >= 252, "emoji should be close to cap")
    }

    // MARK: - Encoder

    private static func verifyEncoderOmitEmptyAndOrder() throws {
        let bucket = UsageBucketPayload(source: "codex", model: "gpt", project: "demo", bucketStart: "2026-01-01T00:00:00Z", hostname: "host-a", inputTokens: 10, outputTokens: 20, reasoningOutputTokens: 5, totalTokens: 35)
        let json = jsonString(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket])))
        try expect(json.contains("\"cachedInputTokens\":0"), "always-present zero dropped")
        try expect(!json.contains("cacheCreationInputTokens"), "omitempty zero present")
        try expect(!json.contains("sessions"), "empty sessions present")
        try expect(!json.contains("autonomySessions"), "empty autonomy present")
        try expect(!json.contains("fullSync"), "false flag present")
        let order = ["source", "model", "project", "bucketStart", "hostname", "inputTokens", "outputTokens", "cachedInputTokens", "reasoningOutputTokens", "totalTokens"]
        try expect(keysInOrder(json, order), "field order mismatch")
    }

    private static func verifyEncoderOptionalFields() throws {
        let bucket = UsageBucketPayload(source: "codex", model: "gpt", project: "demo", skills: ["a", "b"], skillCounts: ["b": 2, "a": 1], mcpCounts: ["x": 3], bucketStart: "t", cacheCreationInputTokens: 4, linesNet: 5, codeMetricVersion: 2)
        let json = jsonString(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket])))
        try expect(json.contains("\"skills\":[\"a\",\"b\"]"), "skills")
        try expect(json.contains("\"skill_counts\":{\"a\":1,\"b\":2}"), "sorted skill_counts")
        try expect(json.contains("\"mcp_counts\":{\"x\":3}"), "mcp_counts")
        try expect(json.contains("\"codeMetricVersion\":2"), "codeMetricVersion")

        let session = UsageSessionPayload(source: "codex", project: "demo", sessionHash: "h", firstMessageAt: "a", lastMessageAt: "b")
        let sjson = jsonString(UsageIngestEncoder().encode(UsageIngestRequest(sessions: [session])))
        try expect(sjson.contains("\"userPromptHours\":[]"), "userPromptHours present when empty")
        try expect(sjson.contains("\"buckets\":[]"), "buckets present when empty")
    }

    private static func verifyEncoderAutonomyAndFlags() throws {
        let autonomy = AutonomySessionPayload(source: "codex", project: "demo", sessionHash: "h", firstEventAt: "a", lastEventAt: "b", autonomyStatus: "autonomous", confidence: "high", schemaVersion: 1, computedAt: "c")
        let status = AutonomySourceStatusPayload(source: "codex", status: "ok")
        let request = UsageIngestRequest(autonomySessions: [autonomy], autonomySourceStatuses: [status], autonomyWindowStart: "w1", autonomyWindowEnd: "w2", fullSync: true, fullSyncReset: true)
        let json = jsonString(UsageIngestEncoder().encode(request))
        try expect(json.contains("\"autonomySessions\":["), "autonomySessions present")
        try expect(json.contains("\"autonomyStatus\":\"autonomous\""), "autonomyStatus")
        try expect(json.contains("\"autonomySourceStatuses\":[{\"source\":\"codex\",\"hostname\":\"\",\"status\":\"ok\"}]"), "status shape")
        try expect(json.contains("\"autonomyWindowStart\":\"w1\""), "window start")
        try expect(json.contains("\"autonomyWindowEnd\":\"w2\""), "window end")
        try expect(json.contains("\"fullSync\":true"), "fullSync true")
        try expect(json.contains("\"fullSyncReset\":true"), "fullSyncReset true")
        // firstUserAt / handoffAt / parserVersion omitted when empty.
        try expect(!json.contains("firstUserAt"), "empty firstUserAt present")
        try expect(!json.contains("parserVersion"), "empty parserVersion present")
        let autonomyOrder = ["source", "project", "sessionHash", "hostname", "firstEventAt", "lastEventAt", "autonomyStatus", "clarificationTurnCount", "confidence", "schemaVersion", "computedAt"]
        try expect(keysInOrder(json, autonomyOrder), "autonomy field order")
    }

    private static func verifyEncoderEscaping() throws {
        let bucket = UsageBucketPayload(source: "a<b>&c", model: "m", project: "p", bucketStart: "t")
        let json = jsonString(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket])))
        try expect(json.contains("a\\u003cb\\u003e\\u0026c"), "HTML-sensitive escaping mismatch")
    }

    private static func verifyResponseAcknowledgementDecoding() throws {
        let data = Data("{\"buckets_upserted\":1,\"sessions_upserted\":0,\"autonomy_sessions_upserted\":0}".utf8)
        let response = try JSONDecoder().decode(UsageIngestResponse.self, from: data)
        try expect(response.confirmsExactCounts(for: request()), "exact acknowledgement rejected")
        try expect(
            !UsageIngestResponse(bucketsUpserted: 2).confirmsExactCounts(for: request()),
            "overcount acknowledgement accepted"
        )
    }

    // MARK: - Gzip + truncation

    private static func verifyGzip() throws {
        try expect(UsageIngestClient.gzipMinimumBytes == 1024, "threshold constant")
        guard let compressed = GzipCompressor.compress(Data(repeating: 0x41, count: 4096)) else { throw VerificationError.failed("gzip nil") }
        try expect(compressed.first == 0x1f, "gzip magic 0")
        try expect(compressed.count >= 2 && compressed[compressed.index(after: compressed.startIndex)] == 0x8b, "gzip magic 1")
    }

    private static func verifyTruncation() throws {
        try expect(UsageIngestClient.truncate(String(repeating: "a", count: 50), 30).count == 30, "ascii truncation")
        let multibyte = String(repeating: "\u{6C49}", count: 20)
        try expect(Array(UsageIngestClient.truncate(multibyte, 10).utf8).count == 9, "multibyte boundary")
    }

    // MARK: - Identity

    private static func verifyIdentity() throws {
        let keys = TokenAccountClaimKeys(tenant: "tenant_id", username: "username")
        let identity = TokenAccountIdentity(claimKeys: keys)
        let a = makeJWT("{\"iss\":\"issuer\",\"tenant_id\":\"t1\",\"username\":\"u1\"}")
        let aSame = makeJWT("{\"iss\":\"issuer\",\"tenant_id\":\"t1\",\"username\":\"u1\",\"extra\":1}")
        let b = makeJWT("{\"iss\":\"issuer\",\"tenant_id\":\"t2\",\"username\":\"u2\"}")
        try expect(identity.sameStableAccount(a, aSame), "same account should match")
        try expect(!identity.sameStableAccount(a, b), "different account should differ")
        // Opaque tokens fall back to digest equality.
        try expect(identity.sameStableAccount("opaque", "opaque"), "opaque equal")
        try expect(!identity.sameStableAccount("opaque-1", "opaque-2"), "opaque differ")
    }

    private static func makeJWT(_ payloadJSON: String) -> String {
        func b64url(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return b64url("{\"alg\":\"none\"}") + "." + b64url(payloadJSON) + ".sig"
    }

    // MARK: - Client

    private static func headerNames() -> RequestHeaderNames {
        RequestHeaderNames(authToken: "X-Test-Auth-Token", timeZoneOffset: "X-Test-Time-Zone-Offset", locale: "X-Test-Locale")
    }
    private static func configured() -> IngestClientConfiguration {
        IngestClientConfiguration(
            baseURL: URL(string: "https://example.com")!,
            path: "/api/usage/ingest",
            hostname: "host-a",
            headerNames: headerNames(),
            staticHeaders: [StaticHeader(name: "X-Test-Client", value: "test-client"), StaticHeader(name: "X-Test-Client-Version", value: "1.2.3")],
            localeEnvironmentVariables: ["TEST_LANG"]
        )
    }
    private static func ok() -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            body: Data("{\"buckets_upserted\":1,\"sessions_upserted\":0,\"autonomy_sessions_upserted\":0}".utf8)
        )
    }
    private static func request() -> UsageIngestRequest { UsageIngestRequest(buckets: [UsageBucketPayload(source: "codex", model: "gpt", project: "demo", bucketStart: "t", totalTokens: 1)]) }

    private static func verifyClientConfigGating() async throws {
        let sender = ScriptedSender(responses: [ok()])
        let supplier = ScriptedSupplier(tokens: ["t"])
        let client = UsageIngestClient(configuration: IngestClientConfiguration(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); try expect(false, "expected configurationMissing") }
        catch let e as IngestClientError { try expect(e == .configurationMissing, "wrong error: \(e)") }
        try expect(sender.requests.isEmpty, "unconfigured client must not send")
        try expect(supplier.calls.isEmpty, "unconfigured client must not fetch token")
    }

    private static func verifyClientHeaders() async throws {
        let sender = ScriptedSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["tok-1"]), sender: sender, environment: [:], timeZone: TimeZone(identifier: "Asia/Shanghai")!)
        let result = try await client.ingest(request())
        try expect(result.bucketsUpserted == 1, "upsert count")
        let req = sender.requests[0]
        try expect(req.url?.absoluteString == "https://example.com/api/usage/ingest", "url: \(req.url?.absoluteString ?? "")")
        try expect(req.httpMethod == "POST", "method")
        try expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json", "content-type")
        try expect(req.value(forHTTPHeaderField: "X-Test-Auth-Token") == "tok-1", "auth header")
        try expect(req.value(forHTTPHeaderField: "X-Test-Client") == "test-client", "static client header")
        try expect(req.value(forHTTPHeaderField: "X-Test-Client-Version") == "1.2.3", "static version header")
        try expect(req.value(forHTTPHeaderField: "X-Test-Time-Zone-Offset") == "+08:00", "tz offset")
        try expect(req.value(forHTTPHeaderField: "Content-Encoding") == nil, "unexpected gzip")
        try expect(req.value(forHTTPHeaderField: "X-Test-Locale") == nil, "unexpected locale")
        try expect(jsonString(req.httpBody ?? Data()).contains("\"hostname\":\"host-a\""), "hostname applied")
    }

    private static func verifyLocaleHeader() async throws {
        let sender = ScriptedSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender, environment: ["TEST_LANG": "en_US.UTF-8"])
        _ = try await client.ingest(request())
        try expect(sender.requests[0].value(forHTTPHeaderField: "X-Test-Locale") == "en-US", "locale header")
    }

    private static func verifySmallBodyNotGzipped() async throws {
        let sender = ScriptedSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
        _ = try await client.ingest(request())
        try expect(sender.requests[0].value(forHTTPHeaderField: "Content-Encoding") == nil, "small body gzipped")
        try expect(jsonString(sender.requests[0].httpBody ?? Data()).contains("\"buckets\""), "body readable")
    }

    private static func verifyLargeBodyGzipped() async throws {
        let sender = ScriptedSender(responses: [ok()])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
        let buckets = (0..<40).map { i in UsageBucketPayload(source: "codex", model: "gpt-model-\(i)", project: "project-\(i)", bucketStart: "2026-01-01T00:00:00Z", totalTokens: Int64(i)) }
        _ = try await client.ingest(UsageIngestRequest(buckets: buckets))
        try expect(sender.requests[0].value(forHTTPHeaderField: "Content-Encoding") == "gzip", "large body not gzipped")
        try expect((sender.requests[0].httpBody ?? Data()).first == 0x1f, "gzip magic on wire")
    }

    private static func verify401SingleRefresh() async throws {
        let sender = ScriptedSender(responses: [HTTPResponse(statusCode: 401, body: Data()), ok()])
        let supplier = ScriptedSupplier(tokens: [makeJWT("{\"iss\":\"i\",\"sub\":\"s\"}"), makeJWT("{\"iss\":\"i\",\"sub\":\"s\"}")])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let result = try await client.ingest(request())
        try expect(result.bucketsUpserted == 1, "recovered upsert")
        try expect(supplier.calls == [false, true], "refresh pattern")
        try expect(sender.requests.count == 2, "request count")
    }

    private static func verifyIdentityFence() async throws {
        let sender = ScriptedSender(responses: [HTTPResponse(statusCode: 401, body: Data()), ok()])
        let supplier = ScriptedSupplier(tokens: [makeJWT("{\"iss\":\"i\",\"sub\":\"account-a\"}"), makeJWT("{\"iss\":\"i\",\"sub\":\"account-b\"}")])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); try expect(false, "expected authIdentityChanged") }
        catch let e as IngestClientError { try expect(e == .authIdentityChanged, "wrong error: \(e)") }
        // The mismatched second request must never be sent.
        try expect(sender.requests.count == 1, "fence must not send second request")
        try expect(supplier.calls == [false, true], "one forced refresh attempted")
    }

    private static func verifyPersistent401Fails() async throws {
        let sender = ScriptedSender(responses: [HTTPResponse(statusCode: 401, body: Data()), HTTPResponse(statusCode: 401, body: Data())])
        let supplier = ScriptedSupplier(tokens: [makeJWT("{\"iss\":\"i\",\"sub\":\"s\"}"), makeJWT("{\"iss\":\"i\",\"sub\":\"s\"}")])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        do { _ = try await client.ingest(request()); try expect(false, "expected notAuthenticated") }
        catch let e as IngestClientError { try expect(e == .notAuthenticated, "wrong error: \(e)") }
        try expect(supplier.calls == [false, true], "one refresh")
        try expect(sender.requests.count == 2, "no extra attempts")
    }

    private static func verifyNon401Failure() async throws {
        let sender = ScriptedSender(responses: [HTTPResponse(statusCode: 500, body: Data("boom".utf8))])
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
        do { _ = try await client.ingest(request()); try expect(false, "expected httpFailure") }
        catch let e as IngestClientError { try expect(e == .httpFailure(statusCode: 500), "wrong error: \(e)") }
    }

    private static func verifyMalformedAcknowledgementResponses() async throws {
        let malformedBodies = [
            Data(),
            Data("{}".utf8),
            Data("{\"sessions_upserted\":0,\"autonomy_sessions_upserted\":0}".utf8),
            Data("{\"buckets_upserted\":1,\"autonomy_sessions_upserted\":0}".utf8),
            Data("{\"buckets_upserted\":1,\"sessions_upserted\":0}".utf8)
        ]
        for body in malformedBodies {
            let sender = ScriptedSender(responses: [HTTPResponse(statusCode: 200, body: body)])
            let client = UsageIngestClient(
                configuration: configured(),
                tokenSupplier: ScriptedSupplier(tokens: ["t"]),
                sender: sender
            )
            do {
                _ = try await client.ingest(request())
                try expect(false, "malformed 2xx acknowledgement accepted")
            } catch let error as IngestClientError {
                try expect(error == .malformedResponse, "wrong malformed acknowledgement error: \(error)")
            }
        }
    }

    // MARK: - Retry and backoff

    private static func verifyRetryableStatusCodes() async throws {
        // Default retryable: 502, 503, 504.
        for code in [502, 503, 504] {
            let sender = ScriptedSender(responses: [HTTPResponse(statusCode: code, body: Data()), ok()])
            let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
            let result = try await client.ingest(request())
            try expect(result.bucketsUpserted == 1, "\(code) should retry and succeed")
            try expect(sender.requests.count == 2, "\(code) should send twice")
        }
    }

    private static func verifyRequestNotWrittenRetry() async throws {
        // HTTPTransportError.requestNotWritten is retryable.
        let sender = ThrowingSender(
            errors: [HTTPTransportError.requestNotWritten],
            responses: [ok()]
        )
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
        let result = try await client.ingest(request())
        try expect(result.bucketsUpserted == 1, "requestNotWritten should retry")
        try expect(sender.sendCount == 2, "requestNotWritten retry count")
    }

    private static func verifyOtherTransportFailureNoRetry() async throws {
        // Other transport errors -> transportFailure, no retry.
        let sender = ThrowingSender(
            errors: [URLError(.networkConnectionLost)],
            responses: []
        )
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
        do { _ = try await client.ingest(request()); try expect(false, "expected transportFailure") }
        catch let e as IngestClientError {
            try expect(e == .transportFailure, "transport error: \(e)")
        }
        try expect(sender.sendCount == 1, "no retry for unknown transport errors")
    }

    private static func verifyConfigured500Retry() async throws {
        // 500 with configured body fragment should retry.
        let config = IngestClientConfiguration(
            baseURL: URL(string: "https://example.com")!,
            path: "/api/usage/ingest",
            hostname: "host-a",
            headerNames: headerNames(),
            staticHeaders: [StaticHeader(name: "X-Test-Client", value: "test")],
            localeEnvironmentVariables: [],
            retryPolicy: RetryPolicy(retryableStatusBodyFragments: [500: ["retry-me"]])
        )
        let sender = ScriptedSender(responses: [
            HTTPResponse(statusCode: 500, body: Data("error: retry-me".utf8)),
            ok()
        ])
        let client = UsageIngestClient(configuration: config, tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender)
        let result = try await client.ingest(request())
        try expect(result.bucketsUpserted == 1, "configured 500 should retry")
        try expect(sender.requests.count == 2, "configured 500 retry count")
    }

    // MARK: - Non-ingest errors don't permanently gate

    private static func verifyNonIngestErrorsDontGate() async throws {
        // Transport failures don't permanently block subsequent requests.
        let sender1 = ThrowingSender(errors: [URLError(.timedOut)], responses: [])
        let client1 = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender1)
        do { _ = try await client1.ingest(request()) }
        catch let e as IngestClientError {
            try expect(e == .transportFailure, "first attempt transport error: \(e)")
        }
        // A new client instance with a working sender should succeed.
        let sender2 = ScriptedSender(responses: [ok()])
        let client2 = UsageIngestClient(configuration: configured(), tokenSupplier: ScriptedSupplier(tokens: ["t"]), sender: sender2)
        let result = try await client2.ingest(request())
        try expect(result.bucketsUpserted == 1, "subsequent request not gated")
    }

    private static func keysInOrder(_ json: String, _ keys: [String]) -> Bool {
        var searchStart = json.startIndex
        for key in keys {
            guard let range = json.range(of: "\"" + key + "\":", range: searchStart..<json.endIndex) else { return false }
            searchStart = range.upperBound
        }
        return true
    }
}

private final class ClosureRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation { let executable: String; let arguments: [String] }
    private let body: (String, [String]) throws -> ProcessResult
    init(_ body: @escaping (String, [String]) throws -> ProcessResult) { self.body = body }
    func run(executable: String, arguments: [String]) throws -> ProcessResult { try body(executable, arguments) }
}

private final class ScriptedSender: HTTPRequestSending, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let responses: [HTTPResponse]
    private var index = 0
    init(responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        defer { index += 1 }
        return responses[min(index, responses.count - 1)]
    }
}

private final class ThrowingSender: HTTPRequestSending, @unchecked Sendable {
    private(set) var sendCount = 0
    private let errors: [Error]
    private let responses: [HTTPResponse]
    init(errors: [Error], responses: [HTTPResponse]) {
        self.errors = errors
        self.responses = responses
    }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        defer { sendCount += 1 }
        if sendCount < errors.count {
            throw errors[sendCount]
        }
        let responseIndex = sendCount - errors.count
        return responses[min(responseIndex, responses.count - 1)]
    }
}

private final class ScriptedSupplier: TokenSupplying, @unchecked Sendable {
    private(set) var calls: [Bool] = []
    private let tokens: [String]
    private var index = 0
    init(tokens: [String]) { self.tokens = tokens }
    func token(forceRefresh: Bool) async throws -> SecretToken {
        calls.append(forceRefresh)
        defer { index += 1 }
        return SecretToken(tokens[min(index, tokens.count - 1)])
    }
}
