import AgentPulseReporting
import Foundation

// Dependency-free verification of the ingest client's duplicate natural-key
// guard. The guard runs after natural keys are normalized and before any token
// acquisition or network I/O, so every rejection path must leave the injected
// token supplier and HTTP transport untouched. Run with:
// swift run NaturalKeyGuardVerification
@main
struct NaturalKeyGuardVerification {
    static func main() async throws {
        try await verifyDuplicateBucketsRejectedWithoutSideEffects()
        try await verifyDuplicateSessionsRejectedWithoutSideEffects()
        try await verifyDuplicateAutonomyRejectedWithoutSideEffects()
        try await verifyCleanBatchWithDistinctKeysPasses()
        try await verifyGuardRunsBeforeTokenAcquisitionAndNetwork()
        try await verifyNormalizationCollapsesNaturalKeys()
        print("NaturalKeyGuard verification passed")
    }

    enum VerificationError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case let .failed(m) = self { return m }; return "failed" }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }

    private static func expectDuplicate(
        _ error: Error,
        dimension: IngestClientError.NaturalKeyDimension,
        label: String
    ) throws {
        guard let ingestError = error as? IngestClientError else {
            throw VerificationError.failed("\(label): expected IngestClientError, got \(error)")
        }
        guard ingestError == .duplicateNaturalKey(dimension: dimension) else {
            throw VerificationError.failed("\(label): wrong error: \(ingestError)")
        }
    }

    // MARK: - Fixtures

    private static func configured() -> IngestClientConfiguration {
        IngestClientConfiguration(
            baseURL: URL(string: "https://example.com")!,
            path: "/api/usage/ingest",
            hostname: "host-a",
            headerNames: RequestHeaderNames(authToken: "X-Test-Auth-Token")
        )
    }

    private static func ack(buckets: Int, sessions: Int, autonomy: Int) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            body: Data("{\"buckets_upserted\":\(buckets),\"sessions_upserted\":\(sessions),\"autonomy_sessions_upserted\":\(autonomy)}".utf8)
        )
    }

    private static func bucket(model: String, sessionTag: String = "") -> UsageBucketPayload {
        UsageBucketPayload(
            source: "codex",
            model: model,
            project: "demo",
            bucketStart: "2026-01-01T00:\(sessionTag)00:00Z",
            totalTokens: 1
        )
    }

    private static func session(project: String, hash: String) -> UsageSessionPayload {
        UsageSessionPayload(
            source: "codex",
            project: project,
            sessionHash: hash,
            firstMessageAt: "2026-01-01T00:00:00Z",
            lastMessageAt: "2026-01-01T00:30:00Z"
        )
    }

    private static func autonomy(project: String, hash: String) -> AutonomySessionPayload {
        AutonomySessionPayload(
            source: "codex",
            project: project,
            sessionHash: hash,
            firstEventAt: "2026-01-01T00:00:00Z",
            lastEventAt: "2026-01-01T00:30:00Z",
            autonomyStatus: "autonomous",
            confidence: "high",
            computedAt: "2026-01-01T00:30:00Z"
        )
    }

    // MARK: - (a) duplicate buckets

    private static func verifyDuplicateBucketsRejectedWithoutSideEffects() async throws {
        let sender = RecordingSender(response: ack(buckets: 2, sessions: 0, autonomy: 0))
        let supplier = RecordingSupplier(token: "t")
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let request = UsageIngestRequest(buckets: [
            bucket(model: "gpt", sessionTag: "0"),
            bucket(model: "gpt", sessionTag: "0"),
        ])
        do {
            _ = try await client.ingest(request)
            try expect(false, "duplicate buckets must be rejected")
        } catch {
            try expectDuplicate(error, dimension: .buckets, label: "buckets")
        }
        try expect(supplier.calls.isEmpty, "duplicate buckets must not acquire a token")
        try expect(sender.requests.isEmpty, "duplicate buckets must not send a request")
    }

    // MARK: - (b) duplicate sessions

    private static func verifyDuplicateSessionsRejectedWithoutSideEffects() async throws {
        let sender = RecordingSender(response: ack(buckets: 0, sessions: 2, autonomy: 0))
        let supplier = RecordingSupplier(token: "t")
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        // project is descriptive, not part of the session natural key.
        let request = UsageIngestRequest(sessions: [
            session(project: "demo", hash: "h1"),
            session(project: "other-project", hash: "h1"),
        ])
        do {
            _ = try await client.ingest(request)
            try expect(false, "duplicate sessions must be rejected")
        } catch {
            try expectDuplicate(error, dimension: .sessions, label: "sessions")
        }
        try expect(supplier.calls.isEmpty, "duplicate sessions must not acquire a token")
        try expect(sender.requests.isEmpty, "duplicate sessions must not send a request")
    }

    // MARK: - (c) duplicate autonomy

    private static func verifyDuplicateAutonomyRejectedWithoutSideEffects() async throws {
        let sender = RecordingSender(response: ack(buckets: 0, sessions: 0, autonomy: 2))
        let supplier = RecordingSupplier(token: "t")
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let request = UsageIngestRequest(autonomySessions: [
            autonomy(project: "demo", hash: "h1"),
            autonomy(project: "other-project", hash: "h1"),
        ])
        do {
            _ = try await client.ingest(request)
            try expect(false, "duplicate autonomy rows must be rejected")
        } catch {
            try expectDuplicate(error, dimension: .autonomySessions, label: "autonomy")
        }
        try expect(supplier.calls.isEmpty, "duplicate autonomy rows must not acquire a token")
        try expect(sender.requests.isEmpty, "duplicate autonomy rows must not send a request")
    }

    // MARK: - (d) clean batch with all-distinct keys still passes

    private static func verifyCleanBatchWithDistinctKeysPasses() async throws {
        let sender = RecordingSender(response: ack(buckets: 2, sessions: 2, autonomy: 2))
        let supplier = RecordingSupplier(token: "t")
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        // Values intentionally overlap across dimensions to prove the guard is
        // per-dimension: only duplicates WITHIN one dimension are rejected.
        let request = UsageIngestRequest(
            buckets: [bucket(model: "gpt", sessionTag: "0"), bucket(model: "gpt", sessionTag: "3")],
            sessions: [session(project: "demo", hash: "h1"), session(project: "demo", hash: "h2")],
            autonomySessions: [autonomy(project: "demo", hash: "h1"), autonomy(project: "demo", hash: "h2")]
        )
        let result = try await client.ingest(request)
        try expect(result.bucketsUpserted == 2, "clean batch ack mismatch")
        try expect(sender.requests.count == 1, "clean batch must send exactly one request")
        try expect(supplier.calls == [false], "clean batch must acquire exactly one token")
    }

    // MARK: - (e) guard runs before token acquisition and network

    private static func verifyGuardRunsBeforeTokenAcquisitionAndNetwork() async throws {
        // A batch carrying duplicates in every dimension at once must fail on
        // the first dimension deterministically, with the supplier and sender
        // never touched.
        let sender = RecordingSender(response: ack(buckets: 2, sessions: 2, autonomy: 2))
        let supplier = RecordingSupplier(token: "t")
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let request = UsageIngestRequest(
            buckets: [bucket(model: "gpt", sessionTag: "0"), bucket(model: "gpt", sessionTag: "0")],
            sessions: [session(project: "demo", hash: "h1"), session(project: "demo", hash: "h1")],
            autonomySessions: [autonomy(project: "demo", hash: "h1"), autonomy(project: "demo", hash: "h1")]
        )
        do {
            _ = try await client.ingest(request)
            try expect(false, "multi-dimension duplicate batch must be rejected")
        } catch {
            try expectDuplicate(error, dimension: .buckets, label: "multi-dimension")
        }
        try expect(supplier.calls.isEmpty, "token supplier must not be invoked on the duplicate path")
        try expect(sender.requests.isEmpty, "transport must not be invoked on the duplicate path")
    }

    // MARK: - guard applies to normalized keys

    private static func verifyNormalizationCollapsesNaturalKeys() async throws {
        // Two models that differ only past the 255-byte cap collapse to the
        // same normalized key, so the guard must treat them as duplicates.
        let longA = String(repeating: "m", count: 255) + "-tail-a"
        let longB = String(repeating: "m", count: 255) + "-tail-b"
        let sender = RecordingSender(response: ack(buckets: 2, sessions: 0, autonomy: 0))
        let supplier = RecordingSupplier(token: "t")
        let client = UsageIngestClient(configuration: configured(), tokenSupplier: supplier, sender: sender)
        let request = UsageIngestRequest(buckets: [
            bucket(model: longA, sessionTag: "0"),
            bucket(model: longB, sessionTag: "0"),
        ])
        do {
            _ = try await client.ingest(request)
            try expect(false, "rows collapsing to one normalized key must be rejected")
        } catch {
            try expectDuplicate(error, dimension: .buckets, label: "normalized")
        }
        try expect(supplier.calls.isEmpty, "normalized-key duplicate must not acquire a token")
        try expect(sender.requests.isEmpty, "normalized-key duplicate must not send a request")
    }
}

private final class RecordingSender: HTTPRequestSending, @unchecked Sendable {
    private(set) var requests: [URLRequest] = []
    private let response: HTTPResponse
    init(response: HTTPResponse) { self.response = response }
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        return response
    }
}

private final class RecordingSupplier: TokenSupplying, @unchecked Sendable {
    private(set) var calls: [Bool] = []
    private let token: String
    init(token: String) { self.token = token }
    func token(forceRefresh: Bool) async throws -> SecretToken {
        calls.append(forceRefresh)
        return SecretToken(token)
    }
}
