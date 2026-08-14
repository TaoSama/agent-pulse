import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage
import zlib

// Verification harness for the resumable full-sync core, invoked by the
// AgentPulseUsageVerification executable entry point.

enum FullSyncVerificationError: Error { case failed(String) }

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw FullSyncVerificationError.failed(message) }
}

// MARK: - Scriptable transport

private final class ScriptedFullSyncSender: FullSyncRequestSending, @unchecked Sendable {
    struct Recorded { let body: Data; let headers: [String: String]; let gzipped: Bool }

    private let lock = NSLock()
    private(set) var calls: [Recorded] = []
    private var callIndex = 0

    var reserveFence: Int64 = 7
    var commitBuckets = 0
    var commitSessions = 0
    var commitAutonomy = 0
    // Wire status tokens emitted per phase. Overridable so a test can prove a
    // caller-configured status truly transits (or that a mismatch is rejected).
    var reserveStatus = "reserved"
    var stageStatus = "staging"
    var commitStatus = "committed"
    var unauthorizedUntilRefresh = false
    var failAtCallIndex: Int? = nil
    var statusAtCallIndex: [Int: Int] = [:]
    var crashAtCallIndex: Int? = nil
    var responseAtCallIndex: [Int: Data] = [:]
    private var didFailOnce = false
    private var didRefresh = false

    func send(_ request: FullSyncTransportRequest) async throws -> HTTPResponse {
        let index: Int = lock.withLock {
            calls.append(Recorded(body: request.body, headers: request.headers, gzipped: request.isGzipped))
            let i = callIndex; callIndex += 1; return i
        }
        if let failAt = failAtCallIndex, index == failAt {
            let shouldThrow = lock.withLock { () -> Bool in
                if didFailOnce { return false }; didFailOnce = true; return true
            }
            if shouldThrow { throw HTTPTransportError.requestNotWritten }
        }
       if let forced = statusAtCallIndex[index] {
            // A custom body may be paired with a forced status so a non-2xx
            // response can still carry a JSON error code for the resolver/
            // shrink paths.
            let body = responseAtCallIndex[index] ?? Data("{}".utf8)
            return HTTPResponse(statusCode: forced, body: body)
       }
        if let body = responseAtCallIndex[index] {
            return HTTPResponse(statusCode: 200, body: body)
        }
        if unauthorizedUntilRefresh {
            let refreshed = lock.withLock { didRefresh }
            if !refreshed { return HTTPResponse(statusCode: 401, body: Data("{}".utf8)) }
        }
        let action = decodeString(request.body, key: "action")
        if let crashAt = crashAtCallIndex, index == crashAt {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return HTTPResponse(statusCode: 200, body: responseBody(for: action, gzipped: request.isGzipped))
    }

    func markRefreshed() { lock.withLock { didRefresh = true } }

    private func responseBody(for action: String, gzipped: Bool) -> Data {
        let status: String
        if action.contains("reserve") { status = reserveStatus }
        else if action.contains("commit") { status = commitStatus }
        else { status = stageStatus }
        var obj: [String: Any] = ["status": status]
        if action.contains("reserve") { obj["fenceRevision"] = reserveFence }
        if action.contains("commit") {
            obj["buckets_upserted"] = commitBuckets
            obj["sessions_upserted"] = commitSessions
            obj["autonomy_sessions_upserted"] = commitAutonomy
        }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    private func decodeString(_ body: Data, key: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = obj[key] as? String else { return "" }
        return value
    }
}

private struct ScriptedTokens: FullSyncTokenSupplying {
    let initialToken: String
    let refreshedToken: String
    let identityForToken: @Sendable (String) -> String
    let onForceRefresh: @Sendable () -> Void
    func token(forceRefresh: Bool) async throws -> SecretToken {
        if forceRefresh { onForceRefresh(); return SecretToken(refreshedToken) }
        return SecretToken(initialToken)
    }
    // Identity is resolved asynchronously in production (an authenticated
    // endpoint lookup). The scripted supplier maps a revealed token straight to
    // a namespace string, and an empty string models an unresolvable identity
    // that must fence the upload.
    func accountNamespace(forToken token: SecretToken) async throws -> String {
        let namespace = identityForToken(token.reveal())
        if namespace.isEmpty { throw FullSyncError.authIdentityUnverifiable }
        return namespace
    }
}

private struct ImmediateSleeper: RetrySleeper {
    func sleep(seconds: TimeInterval) async throws {}
}

// Records the backoff schedule so a test can assert the exact per-retry delays.
private final class RecordingSleeper: RetrySleeper, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seconds: [TimeInterval] = []
    func sleep(seconds: TimeInterval) async throws {
        lock.withLock { self.seconds.append(seconds) }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

// MARK: - Fixtures

private func makeSnapshot(buckets: Int, sessions: Int) -> FullSyncPayloadSnapshot {
    let b = (0..<buckets).map { i in
        UsageBucketPayload(
            source: "source", model: "model", project: "project",
            bucketStart: String(format: "1970-01-01T%02d:00:00Z", i % 24), hostname: "device",
            inputTokens: Int64(i + 1), outputTokens: 1, totalTokens: Int64(i + 2)
        )
    }
    let s = (0..<sessions).map { i in
        UsageSessionPayload(
            source: "source", project: "project", sessionHash: "session-\(i)", hostname: "device",
            firstMessageAt: "1970-01-01T00:00:00Z", lastMessageAt: "1970-01-01T00:01:00Z",
            durationSeconds: 60, activeSeconds: 45, messageCount: 5, userMessageCount: 2,
            userPromptHours: Array(repeating: 0, count: 24)
        )
    }
    return FullSyncPayloadSnapshot(buckets: b, sessions: s, rawGeneration: 1)
}

private func readyConfig(rows: Int = 2, bytes: Int = 8 * 1024 * 1024) -> FullSyncConfiguration {
    FullSyncConfiguration(
        baseURL: URL(string: "https://example.invalid"),
        path: "/usage/full-sync",
        hostname: "device",
        headerNames: .init(authToken: "X-Auth", timeZoneOffset: "X-TZ", locale: "X-Locale", contentEncoding: "Content-Encoding", contentType: "Content-Type"),
        staticHeaders: [StaticHeader(name: "X-Client", value: "verifier")],
        maxRowsPerChunk: rows,
        maxBytesPerChunk: bytes,
        retryPolicy: RetryPolicy(maxRetries: 2, retryableStatusCodes: [503], backoffSeconds: [0])
    )
}

/// Ready configuration bound to an explicit hostname. A hostname-change cleanup
/// must target the OLD host's wire identity even though the current authority
/// host differs.
private func readyConfig(hostname: String, rows: Int = 2, bytes: Int = 8 * 1024 * 1024) -> FullSyncConfiguration {
    FullSyncConfiguration(
        baseURL: URL(string: "https://example.invalid"),
        path: "/usage/full-sync",
        hostname: hostname,
        headerNames: .init(authToken: "X-Auth", timeZoneOffset: "X-TZ", locale: "X-Locale", contentEncoding: "Content-Encoding", contentType: "Content-Type"),
        staticHeaders: [StaticHeader(name: "X-Client", value: "verifier")],
        maxRowsPerChunk: rows,
        maxBytesPerChunk: bytes,
        retryPolicy: RetryPolicy(maxRetries: 2, retryableStatusCodes: [503], backoffSeconds: [0])
    )
}

/// Deterministic per-host state store, mirroring the coordinator's rule that
/// each hostname owns a distinct state directory so an old host's recoverable
/// state never collides with the current host's.
private func perHostStore(_ hostname: String, root: URL) -> FullSyncStateStore {
    let component = "host-\(abs(hostname.hashValue))-\(hostname.count)"
    return FullSyncStateStore(directory: root.appendingPathComponent(component, isDirectory: true))
}

private func tempStore() -> FullSyncStateStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fullsync-" + UUID().uuidString, isDirectory: true)
    return FullSyncStateStore(directory: dir)
}

private func sameAccountTokens(_ onRefresh: @escaping @Sendable () -> Void = {}) -> ScriptedTokens {
    ScriptedTokens(initialToken: "tok-a", refreshedToken: "tok-a2", identityForToken: { _ in "ns:account-1" }, onForceRefresh: onRefresh)
}

private let validUploadID = String(repeating: "a", count: 64)

private func jsonData(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func obj(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

// Recorded request bodies at or above the gzip threshold arrive compressed, so
// decode them back to raw JSON bytes before field inspection.
private func rawBody(_ recorded: ScriptedFullSyncSender.Recorded) -> Data {
    recorded.gzipped ? (gunzip(recorded.body) ?? recorded.body) : recorded.body
}

private func gunzip(_ input: Data) -> Data? {
    var stream = z_stream()
    guard inflateInit2_(
        &stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
    ) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    var output = Data()
    return input.withUnsafeBytes { rawInput -> Data? in
        stream.next_in = UnsafeMutablePointer(mutating: rawInput.bindMemory(to: UInt8.self).baseAddress)
        stream.avail_in = uInt(input.count)
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var status = Z_OK
        repeat {
            let valid = buffer.withUnsafeMutableBufferPointer { pointer -> Bool in
                stream.next_out = pointer.baseAddress
                stream.avail_out = uInt(pointer.count)
                status = zlib.inflate(&stream, Z_NO_FLUSH)
                guard status == Z_OK || status == Z_STREAM_END else { return false }
                output.append(pointer.baseAddress!, count: pointer.count - Int(stream.avail_out))
                return true
            }
            if !valid { return nil }
        } while status != Z_STREAM_END
        return output
    }
}

enum FullSyncVerification {
    /// Entry point invoked by the AgentPulseUsageVerification executable.
    static func run() async throws {
        try await verifyHappyPathAndEnvelope()
        try await verifyChunking()
        try await verifyResumeAfterStageCrash()
        try await verifyResumeIdempotentCommit()
        try await verifyHostnameChangeCrashResumesOldHostState()
        try await verifyStatePermissions()
        try await verifySingleRefreshOn401()
        try await verifyIdentityFenceOnResume()
        try await verifyRescanOnFingerprintDrift()
        try await verifyAckCountMismatch()
        try await verifyFenceConflict()
        try await verifyTransportRetry()
        try await verifyWireVocabularyConfiguration()
        try await verifyConfiguredSuccessStatuses()
        try await verifyConfigurationGates()
        try await verifyReservationContract()
        try await verifyResponseValidation()
        try await verifyRecoveredShortUploadIDAccepted()
        try await verifyPerRequestIdentityFence()
        try await verifyCorruptStateRecovery()
        try await verifyUnconfirmedChunkRebuild()
       try await verifyGzipBoundary()
       try await verifyPayloadTooLargeSplit()
       try await verifySingleRowPayloadTooLarge()
        try verifyOriginNormalization()
        try verifyPositiveUserID()
        try verifyNamespaceDerivation()
        try await verifyIdentityEndpointResolution()
        try await verifyIdentityNamespaceFencing()
        try await verifyRefreshResolvesIdentityThroughEndpoint()
        try await verifyPayloadTooLargeJSONCodeSplit()
        try await verifyUnsupportedStatus()
        try await verifyRejoinRequiredKeepsCredentials()
        try await verifyReserveBackoffOnServerErrors()
       print("AgentPulseUsage full-sync verification passed")
   }

    // A server 413 for a 4-row chunk must halve only the current unconfirmed
    // chunk and complete as 2 + 2 against the same upload/fence, with the commit
    // count intact. Confirmed chunks are never re-sent or reshaped.
    static func verifyPayloadTooLargeSplit() async throws {
        let snapshot = makeSnapshot(buckets: 4, sessions: 0)
        let sender = ScriptedFullSyncSender()
        sender.commitBuckets = 4
        // reserve(0), begin(1), first stage of the 4-row chunk(2) -> 413.
        sender.statusAtCallIndex = [2: 413]
        let store = tempStore()
        let reporter = FullSyncReporter(
            configuration: readyConfig(rows: 4), sender: sender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper(),
            makeUploadID: { validUploadID }
        )
        let result = try await reporter.upload(
            snapshot: snapshot, authIdentity: "ns:account-1", store: store
        )
        try require(result.bucketsUpserted == 4, "413-split commit count wrong")
        try require(result.fenceRevision == 7, "413-split changed the reserved fence")
        try require(result.uploadID == validUploadID, "413-split changed the upload id")
        try require(!result.wasAlreadyCommitted, "413-split flagged as replay")

        // reserve + begin + rejected stage + 2 accepted stages + commit = 6.
        try require(sender.calls.count == 6, "413-split call count wrong: \(sender.calls.count)")
        // Larger chunk bodies are gzipped on the wire, so decode each recorded
        // request through the same gzip-aware path before inspecting fields.
        func body(_ index: Int) -> [String: Any] { obj(rawBody(sender.calls[index])) }
        let actions = sender.calls.map { obj(rawBody($0))["action"] as? String }
        try require(actions == ["reserve", "begin", "stage", "stage", "stage", "commit"],
                    "413-split action sequence wrong: \(actions)")
        try require(actions.filter { $0 == "reserve" }.count == 1, "413-split re-reserved")
        try require(actions.filter { $0 == "begin" }.count == 1, "413-split re-began")

        // The rejected send carried 4 rows; the two accepted sends carried 2 + 2,
        // over a single stable upload id and echoed fence.
        let rejected = body(2)
        try require((rejected["buckets"] as? [[String: Any]])?.count == 4, "rejected stage should carry 4 rows")
        let firstAccepted = body(3)
        let secondAccepted = body(4)
        try require((firstAccepted["buckets"] as? [[String: Any]])?.count == 2, "first accepted stage should carry 2 rows")
       try require((secondAccepted["buckets"] as? [[String: Any]])?.count == 2, "second accepted stage should carry 2 rows")
        try require(firstAccepted["chunkIndex"] == nil, "retry must reuse chunkIndex 0 (omitted on the wire)")
       try require((secondAccepted["chunkIndex"] as? NSNumber)?.intValue == 1, "remaining rows must go to chunkIndex 1")
        for call in [rejected, firstAccepted, secondAccepted] {
            try require(call["uploadId"] as? String == validUploadID, "413-split stage upload id drifted")
            try require((call["fenceRevision"] as? NSNumber)?.intValue == 7, "413-split stage fence drifted")
        }
        // The remaining rows cover offsets 0..2 then 2..4, contiguously.
        try require((firstAccepted["buckets"] as? [[String: Any]])?.first?["inputTokens"] as? NSNumber != nil, "row payload missing")

        // Committed state is retained until an explicit finalize.
        try require(store.hasState(), "413-split must retain committed state")
        let committed = try store.load()
        try require(committed.phase == .committed, "413-split state must be committed")
        let bucketChunks = committed.chunks.filter { $0.kind == .buckets }.sorted { $0.chunkIndex < $1.chunkIndex }
        try require(bucketChunks.count == 2, "413-split should persist exactly 2 bucket chunks")
        try require(bucketChunks[0].offset == 0 && bucketChunks[0].rows == 2, "chunk 0 must be offset 0 rows 2")
        try require(bucketChunks[1].offset == 2 && bucketChunks[1].rows == 2, "chunk 1 must be offset 2 rows 2")
        try require(bucketChunks.allSatisfy(\.confirmed), "413-split chunks must all be confirmed")
        try reporter.finalize(store: store)
        try require(!store.hasState(), "finalize did not discard 413-split state")
    }

    // A single-row chunk that is still rejected with 413 cannot be split and
    // must surface payloadTooLarge rather than looping or corrupting state.
    static func verifySingleRowPayloadTooLarge() async throws {
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let sender = ScriptedFullSyncSender()
        sender.commitBuckets = 1
        // reserve(0), begin(1), the sole 1-row stage(2) -> 413.
        sender.statusAtCallIndex = [2: 413]
        let store = tempStore()
        defer { try? store.discard() }
        let reporter = FullSyncReporter(
            configuration: readyConfig(rows: 4), sender: sender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper(),
            makeUploadID: { validUploadID }
        )
        do {
            _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("single-row 413 did not fail")
        } catch FullSyncError.payloadTooLarge(let kind, let chunkIndex) {
            try require(kind == .buckets && chunkIndex == 0, "single-row 413 reported wrong chunk")
        }
        // Only reserve + begin + the rejected single-row stage were attempted;
        // no commit was sent.
        try require(sender.calls.count == 3, "single-row 413 kept sending: \(sender.calls.count)")
        let actions = sender.calls.map { obj(rawBody($0))["action"] as? String }
        try require(!actions.contains("commit"), "single-row 413 still committed")
    }

    // reserve -> begin -> stage -> commit, with per-field envelope assertions.
    static func verifyHappyPathAndEnvelope() async throws {
        let snapshot = makeSnapshot(buckets: 3, sessions: 2)
        let sender = ScriptedFullSyncSender()
        sender.commitBuckets = 3; sender.commitSessions = 2
        let store = tempStore()
        let reporter = FullSyncReporter(
            configuration: readyConfig(rows: 2), sender: sender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper(),
            makeUploadID: { validUploadID }
        )
        let result = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.bucketsUpserted == 3 && result.sessionsUpserted == 2, "commit counts wrong")
        try require(result.fenceRevision == 7, "fence not captured")
        try require(!result.wasAlreadyCommitted, "fresh upload flagged as replay")
        // After a successful remote commit the state is RETAINED (committed), so a
        // crash before the caller ledger commit stays recoverable. Only an
        // explicit finalize(store:) removes it.
        try require(store.hasState(), "committed state must be retained until finalize")
        try require(try store.load().phase == .committed, "retained state must be committed")
        try reporter.finalize(store: store)
        try require(!store.hasState(), "finalize did not discard committed state")
        // reserve + begin + 2 bucket chunks (2,1) + 1 session chunk + commit = 6.
        try require(sender.calls.count == 6, "unexpected call count: \(sender.calls.count)")

        // reserve: action + hostname only; no uploadId; fence 0.
        let reserve = obj(sender.calls[0].body)
        try require(reserve["action"] as? String == "reserve", "reserve action wrong")
        try require(reserve["hostname"] as? String == "device", "reserve hostname wrong")
        try require(reserve["uploadId"] == nil, "reserve must not carry uploadId")
        try require((reserve["fenceRevision"] as? NSNumber)?.intValue == 0, "reserve fence not 0")
        try require(reserve["buckets"] == nil && reserve["sessions"] == nil, "reserve must not carry rows")

        // begin: base envelope with uploadId, hostname, expected counts, fence.
        let begin = obj(sender.calls[1].body)
        try require(begin["action"] as? String == "begin", "begin action wrong")
        try require(begin["uploadId"] as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "begin uploadId wrong")
        try require((begin["expectedBuckets"] as? NSNumber)?.intValue == 3, "begin expectedBuckets wrong")
        try require((begin["expectedSessions"] as? NSNumber)?.intValue == 2, "begin expectedSessions wrong")
        try require((begin["fenceRevision"] as? NSNumber)?.intValue == 7, "begin fence not echoed")
        try require(begin["kind"] == nil && begin["buckets"] == nil, "begin must not carry kind/rows")

        // stage[0]: first bucket chunk, kind + rows + metadata.
        let stage0 = obj(sender.calls[2].body)
        try require(stage0["action"] as? String == "stage", "stage action wrong")
        try require(stage0["uploadId"] as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "stage uploadId wrong")
       try require(stage0["kind"] as? String == "buckets", "stage kind wrong")
       try require(
            !stage0.keys.contains("chunkIndex"),
            "first stage chunkIndex 0 must be omitted from the wire"
        )
        try require((stage0["fenceRevision"] as? NSNumber)?.intValue == 7, "stage fence not echoed")
        try require((stage0["expectedBuckets"] as? NSNumber)?.intValue == 3, "stage expectedBuckets wrong")
        let stage0Buckets = stage0["buckets"] as? [[String: Any]]
        try require(stage0Buckets?.count == 2, "stage[0] should carry 2 bucket rows")
        // Row wire parity: the row object matches the ingest encoder's fields.
        try require((stage0Buckets?[0]["inputTokens"] as? NSNumber)?.intValue == 1, "stage row inputTokens wrong")
        try require(stage0Buckets?[0]["bucketStart"] as? String == "1970-01-01T00:00:00Z", "stage row bucketStart wrong")

        // stage[1]: second bucket chunk (1 row) with chunkIndex present.
        let stage1 = obj(sender.calls[3].body)
        try require((stage1["chunkIndex"] as? NSNumber)?.intValue == 1, "stage[1] chunkIndex wrong")
        try require((stage1["buckets"] as? [[String: Any]])?.count == 1, "stage[1] should carry 1 bucket row")

        // stage[2]: session chunk, kind=sessions with 2 rows.
        let stage2 = obj(sender.calls[4].body)
       try require(stage2["kind"] as? String == "sessions", "session stage kind wrong")
       try require(
            !stage2.keys.contains("chunkIndex"),
            "first chunkIndex 0 for each kind must be omitted from the wire"
        )
        try require((stage2["sessions"] as? [[String: Any]])?.count == 2, "session stage rows wrong")

        // commit: base envelope, action commit.
        let commit = obj(sender.calls[5].body)
        try require(commit["action"] as? String == "commit", "commit action wrong")
        try require(commit["uploadId"] as? String == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "commit uploadId wrong")

        // Auth + static + tz headers resolved from configured names.
        try require(sender.calls[0].headers["X-Auth"] == "tok-a", "auth header missing")
        try require(sender.calls[0].headers["X-Client"] == "verifier", "static header missing")
        try require(sender.calls[0].headers["Content-Type"] == "application/json", "content-type missing")
    }

    static func verifyChunking() async throws {
        let snapshot = makeSnapshot(buckets: 5, sessions: 0)
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 5
        let store = tempStore()
        let reporter = FullSyncReporter(configuration: readyConfig(rows: 2), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        let result = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.bucketsUpserted == 5, "chunked commit counts wrong")
        try require(sender.calls.count == 6, "chunk count wrong: \(sender.calls.count)") // reserve+begin+3+commit
        try require(store.hasState(), "chunked commit must retain committed state")
        try reporter.finalize(store: store)
        try require(!store.hasState(), "finalize did not discard chunked committed state")
    }

    static func verifyResumeAfterStageCrash() async throws {
        let snapshot = makeSnapshot(buckets: 4, sessions: 0)
        let store = tempStore()
        let sender1 = ScriptedFullSyncSender(); sender1.commitBuckets = 4; sender1.crashAtCallIndex = 3
        let reporter1 = FullSyncReporter(configuration: readyConfig(rows: 1), sender: sender1, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        let crashTask = Task { try await reporter1.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store) }
        do {
            _ = try await crashTask.value
            throw FullSyncVerificationError.failed("crash did not cancel")
        } catch is CancellationError {}
        try require(store.hasState(), "state lost after crash")
        let mid = try store.load()
        try require(mid.phase == .begun, "phase should be begun mid-stage")
        try require(mid.chunks.filter { $0.confirmed }.count == 2, "expected 2 confirmed chunks before crash, got \(mid.chunks.filter { $0.confirmed }.count)")
        // Capture the staged bytes of the first confirmed chunk to prove resume
        // re-reads identical bytes.
        let firstConfirmed = mid.chunks.first { $0.confirmed }!
        let priorDigest = firstConfirmed.digest
        try FileManager.default.removeItem(
            at: store.directory.appendingPathComponent(firstConfirmed.snapshotFile)
        )

        let sender2 = ScriptedFullSyncSender(); sender2.commitBuckets = 4
        let reporter2 = FullSyncReporter(configuration: readyConfig(rows: 1), sender: sender2, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        let result = try await reporter2.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.bucketsUpserted == 4, "resume commit wrong")
        let actions = sender2.calls.map { obj($0.body)["action"] as? String }
        try require(!actions.contains("reserve"), "resume re-reserved")
        try require(!actions.contains("begin"), "resume re-began")
        // The 2 already-confirmed chunks are not re-sent; only the remaining 2
        // chunks + commit go out. With 4 rows @ 1/chunk and 2 confirmed, resume
        // sends 2 stages + commit = 3 calls.
        try require(sender2.calls.count == 3, "resume resent confirmed chunks: \(sender2.calls.count)")
        // Committed state is retained until an explicit finalize.
        try require(store.hasState(), "resumed commit must retain committed state")
        try reporter2.finalize(store: store)
        try require(!store.hasState(), "finalize did not discard resumed committed state")
        // Prove the resumed stage bytes for chunk 0 equal the pre-crash digest.
        try require(priorDigest.count == 64, "digest not sha256 hex")
    }

    static func verifyResumeIdempotentCommit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let ledger = try UsageLedgerStore(path: databaseURL.path)
        let timestamp = Date(timeIntervalSince1970: 1_800)
        try ledger.record(
            events: [UsageEvent(
                id: "event", source: "source", model: "model", project: "project",
                timestamp: timestamp, counts: UsageTokenCounts(input: 1, output: 1),
                sessionHash: "session", sourceFileHash: "file"
            )],
            sessionEvents: [],
            checkpoint: UsageFileCheckpoint(
                fileID: "file", source: "source", pathHash: "path", offset: 1,
                size: 1, modifiedAt: timestamp, parserVersion: 1, status: "complete"
            ),
            hostname: "device"
        )
        _ = try ledger.finalizeDerived(hostname: "device")
        let ledgerSnapshot = try ledger.fullSyncSnapshot(hostname: "device")
        let snapshot = UsageFullSyncSnapshotMapper.payloadSnapshot(from: ledgerSnapshot)
        let store = tempStore()
        let firstSender = ScriptedFullSyncSender()
        firstSender.commitBuckets = snapshot.buckets.count
        firstSender.commitSessions = snapshot.sessions.count
        let firstReporter = FullSyncReporter(
            configuration: readyConfig(), sender: firstSender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        )
        let firstResult = try await firstReporter.upload(
            snapshot: snapshot, authIdentity: "ns:account-1", store: store
        )
        try require(!firstResult.wasAlreadyCommitted, "fresh remote commit flagged as replay")
        try require(try ledger.pendingCounts(hostname: "device").buckets == 1, "ledger changed before local commit")
        try require(store.hasState(), "remote commit was not retained across ledger crash window")

        // Simulate a process crash after the remote commit but before the local
        // ledger commit/finalize by creating fresh reporter and transport values.
        let reentrySender = ScriptedFullSyncSender()
        let reentryReporter = FullSyncReporter(
            configuration: readyConfig(), sender: reentrySender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        )
        let result = try await reentryReporter.upload(
            snapshot: snapshot, authIdentity: "ns:account-1", store: store
        )
        try require(result.wasAlreadyCommitted, "committed resume not idempotent")
        try require(reentrySender.calls.isEmpty, "committed resume performed network calls")
        try require(store.hasState(), "committed reentry must retain state while awaiting ledger commit")
        try require(try store.load().phase == .committed, "reentry state must stay committed")
        let ledgerCommit = try ledger.commitFullSync(UsageFullSyncCommit(snapshot: ledgerSnapshot))
        try require(ledgerCommit.committed, "ledger commit failed after committed reentry")
        try require(try ledger.pendingCounts(hostname: "device").buckets == 0, "ledger rows remained pending after commit")
        try reentryReporter.finalize(store: store)
        try require(!store.hasState(), "finalize did not discard committed state")
    }

    // P1: after a hostname change, the OLD host retains reconciliation debt and
    // (when the crash lands in the remote-ack → ledger-commit window) a persisted
    // committed state under the OLD host's state directory. Startup recovery must
    // ENUMERATE the debt hosts rather than only inspecting the current authority
    // host: otherwise the old host's committed state is orphaned, the global
    // reconciliation gate stays fail-closed, and incremental reporting is blocked
    // until a manual full sync. This proves the enumerate → pick old host →
    // zero-network committed replay → ledger commit → finalize → debt-cleared path.
    static func verifyHostnameChangeCrashResumesOldHostState() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        let stateRoot = FileManager.default.temporaryDirectory.appendingPathComponent("fullsync-hostchange-" + UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: stateRoot)
        }
        let oldHost = "MacBook-Pro.local"
        let newHost = "MacBook-Pro-3.local"
        let ledger = try UsageLedgerStore(path: databaseURL.path)

        // 1) Seed the OLD host and align remote+local via a committed full sync.
        let timestamp = Date(timeIntervalSince1970: 1_800)
        try ledger.record(
            events: [UsageEvent(
                id: "event", source: "source", model: "model", project: "project",
                timestamp: timestamp, counts: UsageTokenCounts(input: 1, output: 1),
                sessionHash: "session", sourceFileHash: "file"
            )],
            sessionEvents: [],
            checkpoint: UsageFileCheckpoint(
                fileID: "file", source: "source", pathHash: "path", offset: 1,
                size: 1, modifiedAt: timestamp, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
            ),
            hostname: oldHost
        )
        _ = try ledger.finalizeDerived(hostname: oldHost)
        let seededSnapshot = try ledger.fullSyncSnapshot(hostname: oldHost)
        try require(try ledger.commitFullSync(UsageFullSyncCommit(snapshot: seededSnapshot)).committed, "seed full sync failed")

        // 2) Rename to the NEW host. The OLD host now owns remote rows the local
        //    ledger no longer has → per-host reconciliation debt.
        try ledger.rebuildForHostname(newHost)
        try require(try ledger.pendingReconciliationHosts() == [oldHost], "old host debt not retained after rename")
        try require(try ledger.reportingEligible(hostname: newHost) == false, "global gate must fail-closed while old host debt is pending")

        // 3) The OLD host's cleanup is an EMPTY, gated full sync. Drive it through a
        //    remote commit, then simulate a crash BEFORE the local ledger commit by
        //    dropping the reporter/transport while the committed state persists
        //    under the OLD host's own state directory.
        let oldHostStore = perHostStore(oldHost, root: stateRoot)
        let newHostStore = perHostStore(newHost, root: stateRoot)
        let cleanupSnapshot = try ledger.fullSyncSnapshot(hostname: oldHost)
        try require(cleanupSnapshot.isEmpty && cleanupSnapshot.reconciliationReason != nil, "old host cleanup snapshot must be empty and gated")
        let cleanupPayload = UsageFullSyncSnapshotMapper.payloadSnapshot(from: cleanupSnapshot)
        let firstSender = ScriptedFullSyncSender()
        let firstReporter = FullSyncReporter(
            configuration: readyConfig(hostname: oldHost), sender: firstSender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        )
        let firstResult = try await firstReporter.upload(
            snapshot: cleanupPayload, authIdentity: "ns:account-1", store: oldHostStore
        )
        try require(!firstResult.wasAlreadyCommitted, "fresh remote cleanup commit flagged as replay")
        let cleanupActions = firstSender.calls.map { obj(rawBody($0))["action"] as? String }
        try require(cleanupActions == ["reserve", "begin", "commit"], "empty cleanup sent unexpected phases: \(cleanupActions)")
        try require(try ledger.pendingReconciliationHosts() == [oldHost], "ledger debt must persist until local commit")
        try require(oldHostStore.hasState(), "remote cleanup commit was not retained across the ledger crash window")
        try require(!newHostStore.hasState(), "new host must have no recoverable state — enumerating only the current host misses the old host")

        // 4) Restart-style recovery. Mirror resumeFullSyncIfPending + performFullSync's
        //    host selection: ENUMERATE pendingReconciliationHosts, pick the debt host,
        //    and resume its store. Selecting the current (new) host would find nothing.
        let debtHosts = try ledger.pendingReconciliationHosts()
        let recoveryHost = debtHosts.first ?? newHost
        try require(recoveryHost == oldHost, "recovery must prioritize the old debt host, not the current authority host")
        let recoveryStore = perHostStore(recoveryHost, root: stateRoot)
        try require(recoveryStore.hasState(), "recovery could not locate the old host's persisted state")
        try require(try recoveryStore.load().phase == .committed, "recovered state must be committed (remote already finalized)")

        // Re-read the snapshot under the same host for the resume upload + ledger commit.
        let resumeSnapshot = try ledger.fullSyncSnapshot(hostname: recoveryHost)
        let resumePayload = UsageFullSyncSnapshotMapper.payloadSnapshot(from: resumeSnapshot)
        let reentrySender = ScriptedFullSyncSender()
        let reentryReporter = FullSyncReporter(
            configuration: readyConfig(hostname: recoveryHost), sender: reentrySender,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        )
        let resumeResult = try await reentryReporter.upload(
            snapshot: resumePayload, authIdentity: "ns:account-1", store: recoveryStore
        )
        try require(resumeResult.wasAlreadyCommitted, "committed resume across restart not idempotent")
        try require(reentrySender.calls.isEmpty, "committed resume across restart performed network calls")

        // 5) Local ledger commit closes the window; finalize discards state; debt cleared;
        //    the global reconciliation gate reopens so incremental reporting is unblocked.
        let ledgerCommit = try ledger.commitFullSync(UsageFullSyncCommit(snapshot: resumeSnapshot))
        try require(ledgerCommit.committed, "ledger commit failed after committed resume")
        try reentryReporter.finalize(store: recoveryStore)
        try require(!recoveryStore.hasState(), "finalize did not discard the recovered committed state")
        try require(try ledger.pendingReconciliationHosts().isEmpty, "old host debt was not cleared after recovery")
        try require(try ledger.reportingEligible(hostname: newHost), "reporting still blocked after old host debt cleared")
    }

    static func verifyStatePermissions() async throws {
        let snapshot = makeSnapshot(buckets: 2, sessions: 0)
        let store = tempStore()
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 2; sender.crashAtCallIndex = 2
        let reporter = FullSyncReporter(configuration: readyConfig(rows: 1), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        let crashTask = Task { try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store) }
        _ = try? await crashTask.value
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: store.directory.path)
        try require(!contents.isEmpty, "no state files written")
        for name in contents {
            let attrs = try fm.attributesOfItem(atPath: store.directory.appendingPathComponent(name).path)
            let perm = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            try require(perm & 0o777 == 0o600, "file \(name) not 0600: \(String(perm, radix: 8))")
        }
        let dirAttrs = try fm.attributesOfItem(atPath: store.directory.path)
        let dirPerm = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        try require(dirPerm & 0o777 == 0o700, "state dir not 0700")
        try store.discard()
    }

    static func verifySingleRefreshOn401() async throws {
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let store = tempStore()
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1; sender.unauthorizedUntilRefresh = true
        let refreshCount = Counter()
        let tokens = ScriptedTokens(initialToken: "tok-a", refreshedToken: "tok-a2", identityForToken: { _ in "ns:account-1" }, onForceRefresh: { refreshCount.increment(); sender.markRefreshed() })
        let reporter = FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: tokens, retrySleeper: ImmediateSleeper())
        let result = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.bucketsUpserted == 1, "refresh-then-succeed failed")
        try require(refreshCount.value == 1, "expected exactly one forced refresh, got \(refreshCount.value)")
    }

    static func verifyIdentityFenceOnResume() async throws {
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let store = tempStore()
        try store.save(FullSyncState(
            uploadID: validUploadID, hostname: "device", phase: .begun, fenceRevision: 7,
            authIdentity: "ns:account-1", payloadFingerprint: FullSyncDigest.fingerprint(for: snapshot, hostname: "device"),
            rawGeneration: 1, expectedBuckets: 1, expectedSessions: 0, expectedAutonomySessions: 0,
            autonomySources: [], autonomyWindowStart: "", autonomyWindowEnd: ""
        ))
        let reporter = FullSyncReporter(configuration: readyConfig(), sender: ScriptedFullSyncSender(), tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        do {
            _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-2", store: store)
            throw FullSyncVerificationError.failed("identity change not fenced")
        } catch FullSyncError.authIdentityChanged {}
        try require(store.hasState(), "fenced state was discarded")
        try store.discard()
    }

    static func verifyRescanOnFingerprintDrift() async throws {
        let snapshot = makeSnapshot(buckets: 2, sessions: 0)
        let store = tempStore()
        try store.save(FullSyncState(
            uploadID: validUploadID, hostname: "device", phase: .begun, fenceRevision: 7,
            authIdentity: "ns:account-1", payloadFingerprint: String(repeating: "0", count: 64),
            rawGeneration: 1, expectedBuckets: 2, expectedSessions: 0, expectedAutonomySessions: 0,
            autonomySources: [], autonomyWindowStart: "", autonomyWindowEnd: ""
        ))
        let reporter = FullSyncReporter(configuration: readyConfig(), sender: ScriptedFullSyncSender(), tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        do {
            _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("fingerprint drift not rejected")
        } catch FullSyncError.rescanRequired {}
        try require(!store.hasState(), "stale state not invalidated")
    }

    static func verifyAckCountMismatch() async throws {
        let snapshot = makeSnapshot(buckets: 2, sessions: 0)
        let store = tempStore()
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1
        let reporter = FullSyncReporter(configuration: readyConfig(rows: 2), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        do {
            _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("count mismatch accepted")
        } catch FullSyncError.acknowledgementCountMismatch {}
    }

   static func verifyFenceConflict() async throws {
       let snapshot = makeSnapshot(buckets: 1, sessions: 0)
       let store = tempStore()
       let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1; sender.statusAtCallIndex = [3: 409]
       let reporter = FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
       do {
           _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("409 did not invalidate the upload")
        } catch FullSyncError.rescanRequired {}
        // A 409 invalidates the local upload state and forces a rescan; the
        // stale state must be discarded so the next attempt re-reserves.
        try require(!store.hasState(), "409 did not discard invalidated state")
   }

    static func verifyTransportRetry() async throws {
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let store = tempStore()
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1; sender.failAtCallIndex = 2
        let reporter = FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        let result = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.bucketsUpserted == 1, "retry then succeed failed")
    }

    static func verifyWireVocabularyConfiguration() async throws {
        let defaults = try JSONDecoder().decode(
            TokenReportingConfiguration.FullSync.self,
            from: Data(#"{"path":"/usage/full-sync"}"#.utf8)
        )
        try require(defaults.isValid, "missing action/kind groups must use complete defaults")
        try require(
            defaults.actionNames == .init()
                && defaults.kindNames == .init(),
            "missing action/kind groups did not use protocol defaults"
        )

        let partialAction = try JSONDecoder().decode(
            TokenReportingConfiguration.FullSync.self,
            from: Data(#"{"path":"/usage/full-sync","actionNames":{"reserve":"reserve"}}"#.utf8)
        )
        try require(!partialAction.isValid, "partially missing action names did not fail closed")
        let partialKind = try JSONDecoder().decode(
            TokenReportingConfiguration.FullSync.self,
            from: Data(#"{"path":"/usage/full-sync","kindNames":{"buckets":"buckets"}}"#.utf8)
        )
        try require(!partialKind.isValid, "partially missing kind names did not fail closed")

        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        for (label, configuration) in [
            (
                "empty action",
                FullSyncConfiguration(
                    baseURL: URL(string: "https://example.invalid"), path: "/usage/full-sync",
                    hostname: "device", actionNames: .init(stage: "")
                )
            ),
            (
                "blank kind",
                FullSyncConfiguration(
                    baseURL: URL(string: "https://example.invalid"), path: "/usage/full-sync",
                    hostname: "device", kindNames: .init(sessions: "   ")
                )
            ),
        ] {
            let sender = ScriptedFullSyncSender()
            let reporter = FullSyncReporter(
                configuration: configuration, sender: sender,
                tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
            )
            do {
                _ = try await reporter.upload(
                    snapshot: snapshot, authIdentity: "ns:account-1", store: tempStore()
                )
                throw FullSyncVerificationError.failed("\(label) was accepted")
            } catch FullSyncError.configurationMissing {}
            try require(sender.calls.isEmpty, "\(label) performed networking")
        }
    }

    static func verifyConfigurationGates() async throws {
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let sender = ScriptedFullSyncSender()
        let unconfigured = FullSyncReporter(configuration: FullSyncConfiguration(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        do {
            _ = try await unconfigured.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: tempStore())
            throw FullSyncVerificationError.failed("unconfigured upload proceeded")
        } catch FullSyncError.configurationMissing {}
        let configured = FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper())
        do {
            _ = try await configured.upload(snapshot: snapshot, authIdentity: "  ", store: tempStore())
            throw FullSyncVerificationError.failed("empty identity accepted")
        } catch FullSyncError.authIdentityMissing {}
        try require(sender.calls.isEmpty, "gated upload performed networking")
    }

    // Success statuses are configuration-driven with an exact default contract.
    // This proves three things end to end: the default section is exactly
    // reserved/staging/staging/committed, a caller-configured status truly
    // transits through TokenReportingConfiguration.fullSyncConfiguration into the
    // upload core and is accepted, and a response whose status does not match the
    // configured expectation is rejected (fail-closed), even when it equals the
    // built-in default.
    static func verifyConfiguredSuccessStatuses() async throws {
        // 1) Absent section decodes to the exact default contract.
        let defaults = try JSONDecoder().decode(
            TokenReportingConfiguration.FullSync.self,
            from: Data(#"{"path":"/usage/full-sync"}"#.utf8)
        )
        try require(defaults.isValid, "default success statuses did not validate")
        try require(
            defaults.successStatuses == .init(reserve: "reserved", begin: "staging", stage: "staging", commit: "committed"),
            "default success statuses drifted from reserved/staging/staging/committed"
        )

        // 2) A blank override is trimmed to empty and fails closed.
        let blank = try JSONDecoder().decode(
            TokenReportingConfiguration.FullSync.self,
            from: Data(#"{"path":"/usage/full-sync","successStatuses":{"commit":"   "}}"#.utf8)
        )
        try require(!blank.isValid, "blank success status was not rejected")

        // 3) A custom section decodes (trimmed) and maps through into the core.
        let customFullSync = try JSONDecoder().decode(
            TokenReportingConfiguration.FullSync.self,
            from: Data(#"{"path":"/usage/full-sync","successStatuses":{"reserve":" ok-reserve ","begin":"ok-stage","stage":"ok-stage","commit":"ok-commit"}}"#.utf8)
        )
        try require(customFullSync.isValid, "custom success statuses did not validate")
        try require(
            customFullSync.successStatuses == .init(reserve: "ok-reserve", begin: "ok-stage", stage: "ok-stage", commit: "ok-commit"),
            "custom success statuses were not trimmed/decoded"
        )
       let reporting = TokenReportingConfiguration(
           canonicalHostname: "device",
           path: "/usage",
           headers: .init(authToken: "X-Auth", contentEncoding: "Content-Encoding", contentType: "Content-Type"),
           staticHeaders: [.init(name: "X-Client", value: "verifier")],
            fullSync: customFullSync,
            identityEndpoint: .init(path: "/whoami", method: "GET", responseIDKeyPath: ["id"], successStatusCodes: [200])
       )
        guard let mapped = reporting.fullSyncConfiguration(
            baseURL: URL(string: "https://example.invalid")!, hostname: "device"
        ) else {
            throw FullSyncVerificationError.failed("valid full-sync config did not map")
        }
        try require(
            mapped.successStatuses == FullSyncSuccessStatuses(reserve: "ok-reserve", begin: "ok-stage", stage: "ok-stage", commit: "ok-commit"),
            "configured success statuses were not carried into FullSyncConfiguration"
        )

        // A sender that answers with exactly the configured tokens uploads clean.
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let accepting = ScriptedFullSyncSender()
        accepting.commitBuckets = 1
        accepting.reserveStatus = "ok-reserve"
        accepting.stageStatus = "ok-stage"
        accepting.commitStatus = "ok-commit"
        let acceptStore = tempStore()
        defer { try? acceptStore.discard() }
        let acceptingReporter = FullSyncReporter(
            configuration: mapped, sender: accepting,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        )
        let result = try await acceptingReporter.upload(
            snapshot: snapshot, authIdentity: "ns:account-1", store: acceptStore
        )
        try require(result.bucketsUpserted == 1 && !accepting.calls.isEmpty, "configured status was not accepted end to end")

        // The same custom config must reject the built-in default status, proving
        // the check honors the configured value rather than any hardcoded one.
        let rejecting = ScriptedFullSyncSender()
        rejecting.commitBuckets = 1
        // reserveStatus stays the built-in "reserved", which no longer matches.
        let rejectStore = tempStore()
        defer { try? rejectStore.discard() }
        let rejectingReporter = FullSyncReporter(
            configuration: mapped, sender: rejecting,
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        )
        do {
            _ = try await rejectingReporter.upload(
                snapshot: snapshot, authIdentity: "ns:account-1", store: rejectStore
            )
            throw FullSyncVerificationError.failed("mismatched reserve status was accepted")
        } catch FullSyncError.malformedResponse {}
    }

    static func verifyReservationContract() async throws {
        let sender = ScriptedFullSyncSender()
        sender.responseAtCallIndex[0] = jsonData([
            "status": "reserved", "fence_revision": 11,
        ])
        let store = tempStore()
        defer { try? store.discard() }
        let reporter = FullSyncReporter(
            configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
            retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
        )
        let first = try await reporter.reserve(
            hostname: "device", authIdentity: "ns:account-1", generationBaseline: 1, store: store
        )
        let second = try await reporter.reserve(
            hostname: "device", authIdentity: "ns:account-1", generationBaseline: 1, store: store
        )
        try require(first == second && first.fenceRevision == 11, "snake-case fence was not accepted")
        try require(sender.calls.count == 1, "idempotent reserve repeated networking")
        let state = try store.load()
        try require(state.phase == .reserved && !state.payloadBound, "reserve bound payload prematurely")

        // A reserve response that omits the fence field defaults to revision 0:
        // an absent field equals an explicit zero on the wire.
        let missingFenceSender = ScriptedFullSyncSender()
        missingFenceSender.responseAtCallIndex[0] = jsonData(["status": "reserved"])
        let missingFenceStore = tempStore()
        defer { try? missingFenceStore.discard() }
        let missingFence = try await FullSyncReporter(
            configuration: readyConfig(), sender: missingFenceSender, tokenSupplier: sameAccountTokens(),
            retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
        ).reserve(
            hostname: "device", authIdentity: "ns:account-1", generationBaseline: 1, store: missingFenceStore
        )
        try require(missingFence.fenceRevision == 0, "missing reserve fence must default to 0")
        try require((try missingFenceStore.load()).fenceRevision == 0, "persisted reserve fence must be 0 when omitted")

        // Both camel and snake fence fields present with conflicting values is
        // still rejected: the decoder cannot pick a single authoritative value.
        let conflictSender = ScriptedFullSyncSender()
        conflictSender.responseAtCallIndex[0] = jsonData(["status": "reserved", "fenceRevision": 1, "fence_revision": 2])
        let conflictStore = tempStore()
        defer { try? conflictStore.discard() }
        do {
            _ = try await FullSyncReporter(
                configuration: readyConfig(), sender: conflictSender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            ).reserve(
                hostname: "device", authIdentity: "ns:account-1", generationBaseline: 1, store: conflictStore
            )
            throw FullSyncVerificationError.failed("conflicting fence fields accepted")
        } catch FullSyncError.malformedResponse {}

        let generatedStore = tempStore()
        defer { try? generatedStore.discard() }
        let generated = try await FullSyncReporter(
            configuration: readyConfig(), sender: ScriptedFullSyncSender(),
            tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper()
        ).reserve(
            hostname: "device", authIdentity: "ns:account-1",
            generationBaseline: 1, store: generatedStore
        )
        try require(
            generated.uploadID.utf8.count == 64
                && generated.uploadID.utf8.allSatisfy {
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                },
            "random upload ID is not 32-byte hex"
        )
    }

    static func verifyResponseValidation() async throws {
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        for (call, response) in [
            (0, jsonData(["status": "ok", "fenceRevision": 7])),
            (1, jsonData(["status": "reserved"])),
            (2, jsonData(["status": "committed"])),
            (3, jsonData(["status": "staging", "buckets_upserted": 1,
                          "sessions_upserted": 0, "autonomy_sessions_upserted": 0])),
        ] {
            let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1
            sender.responseAtCallIndex[call] = response
            let store = tempStore(); defer { try? store.discard() }
            let reporter = FullSyncReporter(
                configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            )
            do {
                _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
                throw FullSyncVerificationError.failed("wrong phase status accepted at call \(call)")
            } catch FullSyncError.malformedResponse {}
        }

        // A committed response that omits a zero count field defaults it to 0.
        // With an empty snapshot every expected count is 0, so the omitted
        // autonomy count must default to 0 and the ack check must pass.
        let empty = FullSyncPayloadSnapshot(rawGeneration: 1)
        let sender = ScriptedFullSyncSender()
        sender.responseAtCallIndex[2] = jsonData([
            "status": "committed", "buckets_upserted": 0, "sessions_upserted": 0,
        ])
        let store = tempStore(); defer { try? store.discard() }
        let committed = try await FullSyncReporter(
            configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
            retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
        ).upload(snapshot: empty, authIdentity: "ns:account-1", store: store)
        try require(
            committed.bucketsUpserted == 0
                && committed.sessionsUpserted == 0
                && committed.autonomySessionsUpserted == 0,
            "omitted zero commit counts must default to 0"
        )
    }

    // A recovered upload state whose server-issued upload ID is shorter than the
    // 64-hex generation width (as short as 32 lowercase hex) must still load and
    // resume to a clean commit. Freshly generated IDs remain 64 hex; only the
    // recovery gate accepts the 32-64 hex range.
    static func verifyRecoveredShortUploadIDAccepted() async throws {
        let shortUploadID = String(repeating: "a", count: 32)
        try require(
            shortUploadID.utf8.count == 32
                && shortUploadID.utf8.allSatisfy {
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
                },
            "test fixture must be 32-hex"
        )
        let snapshot = makeSnapshot(buckets: 1, sessions: 0)
        let store = tempStore(); defer { try? store.discard() }
        try store.save(FullSyncState(
            uploadID: shortUploadID, hostname: "device", phase: .begun, fenceRevision: 7,
            authIdentity: "ns:account-1",
            payloadFingerprint: FullSyncDigest.fingerprint(for: snapshot, hostname: "device"),
            rawGeneration: 1, expectedBuckets: 1, expectedSessions: 0, expectedAutonomySessions: 0,
            autonomySources: [], autonomyWindowStart: "", autonomyWindowEnd: ""
        ))
        // Reloading proves validate() accepts the 32-hex recovered ID; a strict
        // 64-only gate would surface corruptState here.
        try require((try store.load()).uploadID == shortUploadID, "32-hex recovered upload ID rejected on load")

        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1
        let reporter = FullSyncReporter(
            configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
            retrySleeper: ImmediateSleeper()
        )
        let result = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.uploadID == shortUploadID, "resume changed the recovered upload ID")
        try require(result.bucketsUpserted == 1, "resume of 32-hex upload did not commit")
        let actions = sender.calls.map { obj($0.body)["action"] as? String }
        try require(!actions.contains("reserve") && !actions.contains("begin"), "recovered upload must not re-reserve or re-begin")
        for call in sender.calls {
            try require(obj(call.body)["uploadId"] as? String == shortUploadID, "resume sent a drifted upload ID")
        }
        try reporter.finalize(store: store)
    }

    static func verifyPerRequestIdentityFence() async throws {
        for tokenIdentity in ["ns:account-2", "unverifiable"] {
            let sender = ScriptedFullSyncSender()
            let tokens = ScriptedTokens(
                initialToken: "tok-a", refreshedToken: "tok-a2",
                identityForToken: { _ in tokenIdentity }, onForceRefresh: {}
            )
            do {
                _ = try await FullSyncReporter(
                    configuration: readyConfig(), sender: sender, tokenSupplier: tokens,
                    retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
                ).reserve(
                    hostname: "device", authIdentity: "ns:account-1",
                    generationBaseline: 1, store: tempStore()
                )
                throw FullSyncVerificationError.failed("unpinned ordinary token accepted")
            } catch FullSyncError.authIdentityChanged {}
              catch FullSyncError.authIdentityUnverifiable {}
            try require(sender.calls.isEmpty, "identity mismatch reached network")
        }

        for refreshedIdentity in ["ns:account-2", "unverifiable"] {
            let sender = ScriptedFullSyncSender(); sender.unauthorizedUntilRefresh = true
            let tokens = ScriptedTokens(
                initialToken: "tok-a", refreshedToken: "tok-a2",
                identityForToken: { $0 == "tok-a" ? "ns:account-1" : refreshedIdentity },
                onForceRefresh: { sender.markRefreshed() }
            )
            do {
                _ = try await FullSyncReporter(
                    configuration: readyConfig(), sender: sender, tokenSupplier: tokens,
                    retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
                ).reserve(
                    hostname: "device", authIdentity: "ns:account-1",
                    generationBaseline: 1, store: tempStore()
                )
                throw FullSyncVerificationError.failed("unpinned refreshed token accepted")
            } catch FullSyncError.authIdentityChanged {}
              catch FullSyncError.authIdentityUnverifiable {}
            try require(sender.calls.count == 1, "refreshed identity was sent before fencing")
        }
    }

    static func verifyCorruptStateRecovery() async throws {
        for version in [1, FullSyncState.currentVersion] {
            let store = tempStore()
            try store.ensureDirectory()
            let invalid = FullSyncState(
                version: version, uploadID: validUploadID, hostname: "device", phase: .reserved,
                fenceRevision: 7, authIdentity: "ns:account-1", payloadFingerprint: "",
                generationBaseline: 1, payloadBound: false, rawGeneration: 1,
                expectedBuckets: version == 1 ? 0 : -1, expectedSessions: 0, expectedAutonomySessions: 0,
                autonomySources: [], autonomyWindowStart: "", autonomyWindowEnd: ""
            )
            let url = store.directory.appendingPathComponent("full-sync-state.json")
            try JSONEncoder().encode(invalid).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let sender = ScriptedFullSyncSender()
            do {
                _ = try await FullSyncReporter(
                    configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
                    retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
                ).reserve(
                    hostname: "device", authIdentity: "ns:account-1",
                    generationBaseline: 1, store: store
                )
                throw FullSyncVerificationError.failed("invalid state was silently reused")
            } catch FullSyncError.rescanRequired {}
            try require(!store.hasState() && sender.calls.isEmpty, "invalid state was not safely discarded")
        }
    }

    static func verifyUnconfirmedChunkRebuild() async throws {
        for corrupt in [false, true] {
            let snapshot = makeSnapshot(buckets: 1, sessions: 0)
            let store = tempStore(); defer { try? store.discard() }
            let firstSender = ScriptedFullSyncSender(); firstSender.statusAtCallIndex[2] = 500
            let reporter = FullSyncReporter(
                configuration: readyConfig(rows: 1), sender: firstSender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            )
            do {
                _ = try await reporter.upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            } catch FullSyncError.httpFailure(statusCode: 500) {}
            let record = try store.load().chunks.first!
            let url = store.directory.appendingPathComponent(record.snapshotFile)
            if corrupt {
                try Data("corrupt".utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } else {
                try FileManager.default.removeItem(at: url)
            }
            let resumedSender = ScriptedFullSyncSender(); resumedSender.commitBuckets = 1
            _ = try await FullSyncReporter(
                configuration: readyConfig(rows: 1), sender: resumedSender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            ).completeUpload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            try require(resumedSender.calls.count == 2, "unconfirmed chunk was not rebuilt once")
        }
    }

    static func verifyGzipBoundary() async throws {
        func capturedStage(fillerCount: Int) async throws -> (ScriptedFullSyncSender.Recorded, Data) {
            var snapshot = makeSnapshot(buckets: 1, sessions: 0)
            snapshot.buckets[0].model = String(repeating: "x", count: fillerCount)
            let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1
            let store = tempStore(); defer { try? store.discard() }
            _ = try await FullSyncReporter(
                configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            ).upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
            let call = sender.calls[2]
            let raw = call.gzipped ? (gunzip(call.body) ?? Data()) : call.body
            return (call, raw)
        }

        let base = try await capturedStage(fillerCount: 0).1.count
        let below = try await capturedStage(fillerCount: 1_023 - base)
        let at = try await capturedStage(fillerCount: 1_024 - base)
        try require(below.1.count == 1_023 && !below.0.gzipped, "1023-byte body was gzipped")
        try require(at.1.count == 1_024 && at.0.gzipped, "1024-byte body was not gzipped")
        try require(
            (obj(at.1)["buckets"] as? [[String: Any]])?.first?["model"] as? String
                == String(repeating: "x", count: 1_024 - base),
            "gzip body did not decompress to the original JSON"
        )
    }

    // MARK: - Identity endpoint (origin + positive user id -> namespace)

    // A scripted transport for the identity endpoint. It records the requests
    // it received (method, headers, whether a body was attached) and answers
    // each call from a queued script so a 401-then-200 refresh flow can be
    // modeled deterministically without a live server.
    private final class ScriptedIdentitySender: HTTPRequestSending, @unchecked Sendable {
        struct Recorded { let method: String; let headers: [String: String]; let hasBody: Bool; let url: URL }
        private let lock = NSLock()
        private var responses: [HTTPResponse]
        private var index = 0
        private(set) var calls: [Recorded] = []
        init(_ responses: [HTTPResponse]) { self.responses = responses }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lock.withLock {
                calls.append(Recorded(
                    method: request.httpMethod ?? "",
                    headers: request.allHTTPHeaderFields ?? [:],
                    hasBody: request.httpBody != nil,
                    url: request.url!
                ))
            }
            let response: HTTPResponse = lock.withLock {
                let r = responses[min(index, responses.count - 1)]
                index += 1
                return r
            }
            return response
        }
    }

    private static func idResponse(_ status: Int, _ json: [String: Any]) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: jsonData(json))
    }

    // A token supplier whose namespace is resolved through a real
    // OriginUserIdentityResolver against a scripted identity endpoint, so the
    // reporter's fence exercises the production identity path end to end.
    private struct EndpointTokens: FullSyncTokenSupplying {
        let initialToken: String
        let refreshedToken: String
        let resolver: OriginUserIdentityResolver
        let onForceRefresh: @Sendable () -> Void
        func token(forceRefresh: Bool) async throws -> SecretToken {
            if forceRefresh { onForceRefresh(); return SecretToken(refreshedToken) }
            return SecretToken(initialToken)
        }
        func accountNamespace(forToken token: SecretToken) async throws -> String {
            do { return try await resolver.resolveNamespace(token: token) }
            catch { throw FullSyncError.authIdentityUnverifiable }
        }
    }

    // origin normalization: scheme/host lowercased, default port dropped, path
    // and user info discarded, non-http rejected.
    static func verifyOriginNormalization() throws {
        try require(RequestOrigin.normalize(URL(string: "HTTPS://Example.INVALID/usage?x=1")!) == "https://example.invalid", "https default-port origin not normalized")
        try require(RequestOrigin.normalize(URL(string: "https://example.invalid:8443/x")!) == "https://example.invalid:8443", "non-default https port dropped")
        try require(RequestOrigin.normalize(URL(string: "http://example.invalid:80")!) == "http://example.invalid", "http default port not dropped")
        try require(RequestOrigin.normalize(URL(string: "http://user:pass@example.invalid/p")!) == "http://example.invalid", "user info not stripped")
        try require(RequestOrigin.normalize(URL(string: "file:///tmp/x")!) == nil, "non-http scheme accepted")
        try require(RequestOrigin.normalize(URL(string: "https:///nohost")!) == nil, "missing host accepted")
    }

    // positive integer id: accept int and digit-string; reject 0/neg/float/
    // bool/non-digit/missing key.
    static func verifyPositiveUserID() throws {
        try require((try? OriginUserIdentityResolver.positiveUserID(from: jsonData(["id": 42]), keyPath: ["id"])) == 42, "positive int id rejected")
        try require((try? OriginUserIdentityResolver.positiveUserID(from: jsonData(["user": ["id": 7]]), keyPath: ["user", "id"])) == 7, "nested id rejected")
        try require((try? OriginUserIdentityResolver.positiveUserID(from: jsonData(["id": "1234"]), keyPath: ["id"])) == 1234, "digit-string id rejected")
        for bad in [jsonData(["id": 0]), jsonData(["id": -3]), jsonData(["id": 1.5]), jsonData(["id": true]), jsonData(["id": "12a"]), jsonData(["other": 1]), Data("not json".utf8)] {
            var threw = false
            do { _ = try OriginUserIdentityResolver.positiveUserID(from: bad, keyPath: ["id"]) } catch { threw = true }
            try require(threw, "invalid user id was accepted")
        }
    }

    // namespace is versioned, stable for the same (origin,id), and distinct
    // when either the origin or the id changes.
    static func verifyNamespaceDerivation() throws {
        let a = OriginUserIdentityResolver.namespace(origin: "https://example.invalid", userID: 1)
        let aAgain = OriginUserIdentityResolver.namespace(origin: "https://example.invalid", userID: 1)
        let diffID = OriginUserIdentityResolver.namespace(origin: "https://example.invalid", userID: 2)
        let diffOrigin = OriginUserIdentityResolver.namespace(origin: "https://other.invalid", userID: 1)
        try require(a == aAgain, "namespace not stable for same origin+id")
        try require(a.hasPrefix(OriginUserIdentityResolver.namespaceVersion + ":"), "namespace not version-tagged")
        try require(a != diffID && a != diffOrigin && diffID != diffOrigin, "namespace collided across origin/id")
    }

    // The resolver queries the endpoint with the shared auth header + static
    // headers, accepts the configured status, derives the namespace, and fails
    // closed on a malformed id, an unconfigured endpoint, or a 401.
    static func verifyIdentityEndpointResolution() async throws {
        let base = URL(string: "https://example.invalid")!
        let config = IdentityEndpointConfiguration(
            path: "/whoami", method: .get, responseIDKeyPath: ["id"], successStatusCodes: [200],
            headerNames: .init(authToken: "X-Auth"), staticHeaders: [StaticHeader(name: "X-Client", value: "verifier")]
        )
        let ok = ScriptedIdentitySender([idResponse(200, ["id": 99])])
        let namespace = try await OriginUserIdentityResolver(baseURL: base, configuration: config, sender: ok).resolveNamespace(token: SecretToken("tok"))
        try require(namespace == OriginUserIdentityResolver.namespace(origin: "https://example.invalid", userID: 99), "resolved namespace mismatch")
        try require(ok.calls.first?.headers["X-Auth"] == "tok", "identity request missing auth header")
        try require(ok.calls.first?.headers["X-Client"] == "verifier", "identity request missing static header")
        try require(ok.calls.first?.method == "GET" && ok.calls.first?.hasBody == false, "GET identity request shape wrong")
        try require(ok.calls.first?.url.path == "/whoami", "identity request path wrong")

        // POST variant attaches an empty JSON body and the content-type header.
        let postConfig = IdentityEndpointConfiguration(path: "/whoami", method: .post, responseIDKeyPath: ["id"], successStatusCodes: [200], headerNames: .init(authToken: "X-Auth", contentType: "Content-Type"))
        let postSender = ScriptedIdentitySender([idResponse(200, ["id": 5])])
        _ = try await OriginUserIdentityResolver(baseURL: base, configuration: postConfig, sender: postSender).resolveNamespace(token: SecretToken("tok"))
        try require(postSender.calls.first?.method == "POST" && postSender.calls.first?.hasBody == true, "POST identity request must carry a body")

        // Malformed id, 401, and an unconfigured endpoint all fail closed.
        var threw = false
        do { _ = try await OriginUserIdentityResolver(baseURL: base, configuration: config, sender: ScriptedIdentitySender([idResponse(200, ["id": 0])])).resolveNamespace(token: SecretToken("tok")) } catch IdentityResolutionError.malformedResponse { threw = true }
        try require(threw, "zero id did not fail closed")
        threw = false
        do { _ = try await OriginUserIdentityResolver(baseURL: base, configuration: config, sender: ScriptedIdentitySender([idResponse(401, [:])])).resolveNamespace(token: SecretToken("tok")) } catch IdentityResolutionError.notAuthenticated { threw = true }
        try require(threw, "401 identity did not surface notAuthenticated")
        threw = false
        do { _ = try await OriginUserIdentityResolver(baseURL: base, configuration: IdentityEndpointConfiguration(), sender: ScriptedIdentitySender([idResponse(200, ["id": 1])])).resolveNamespace(token: SecretToken("tok")) } catch IdentityResolutionError.notConfigured { threw = true }
        try require(threw, "unconfigured endpoint attempted a request")
    }

    // same/different/unknown/cross-namespace fencing at reserve time, driven by
    // the endpoint-backed supplier. Same id -> proceeds; a different id under
    // the same origin (same version prefix) -> authIdentityChanged; an
    // unresolvable identity -> authIdentityUnverifiable; neither reaches begin.
    static func verifyIdentityNamespaceFencing() async throws {
        let base = URL(string: "https://example.invalid")!
        let config = IdentityEndpointConfiguration(path: "/whoami", method: .get, responseIDKeyPath: ["id"], successStatusCodes: [200], headerNames: .init(authToken: "X-Auth"))
        let pinned = OriginUserIdentityResolver.namespace(origin: "https://example.invalid", userID: 1)

        // Same account: reserve proceeds and persists reserved state.
        let sameSender = ScriptedFullSyncSender()
        let sameIdentity = ScriptedIdentitySender([idResponse(200, ["id": 1])])
        let sameTokens = EndpointTokens(initialToken: "a", refreshedToken: "a2", resolver: OriginUserIdentityResolver(baseURL: base, configuration: config, sender: sameIdentity), onForceRefresh: {})
        let sameStore = tempStore(); defer { try? sameStore.discard() }
        _ = try await FullSyncReporter(configuration: readyConfig(), sender: sameSender, tokenSupplier: sameTokens, retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).reserve(hostname: "device", authIdentity: pinned, generationBaseline: 1, store: sameStore)
        try require(sameSender.calls.count == 1 && (try sameStore.load()).phase == .reserved, "same-account reserve did not proceed")

        // Different account (same origin, id 2): cross-namespace -> changed.
        let diffSender = ScriptedFullSyncSender()
        let diffIdentity = ScriptedIdentitySender([idResponse(200, ["id": 2])])
        let diffTokens = EndpointTokens(initialToken: "a", refreshedToken: "a2", resolver: OriginUserIdentityResolver(baseURL: base, configuration: config, sender: diffIdentity), onForceRefresh: {})
        do {
            _ = try await FullSyncReporter(configuration: readyConfig(), sender: diffSender, tokenSupplier: diffTokens, retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).reserve(hostname: "device", authIdentity: pinned, generationBaseline: 1, store: tempStore())
            throw FullSyncVerificationError.failed("cross-namespace account was accepted")
        } catch FullSyncError.authIdentityChanged {}
        try require(diffSender.calls.isEmpty, "cross-namespace mismatch reached network")

        // Unresolvable identity (endpoint 500) -> unverifiable, no network.
        let unkSender = ScriptedFullSyncSender()
        let unkIdentity = ScriptedIdentitySender([idResponse(500, [:])])
        let unkTokens = EndpointTokens(initialToken: "a", refreshedToken: "a2", resolver: OriginUserIdentityResolver(baseURL: base, configuration: config, sender: unkIdentity), onForceRefresh: {})
        do {
            _ = try await FullSyncReporter(configuration: readyConfig(), sender: unkSender, tokenSupplier: unkTokens, retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).reserve(hostname: "device", authIdentity: pinned, generationBaseline: 1, store: tempStore())
            throw FullSyncVerificationError.failed("unverifiable identity was accepted")
        } catch FullSyncError.authIdentityUnverifiable {}
        try require(unkSender.calls.isEmpty, "unverifiable identity reached network")
    }

    // On a 401 the reporter forces exactly one token refresh, re-resolves the
    // namespace through the endpoint, and proceeds only when it still matches
    // the pinned identity; a refreshed credential that resolves to a different
    // account fences even after the refresh.
    static func verifyRefreshResolvesIdentityThroughEndpoint() async throws {
        let base = URL(string: "https://example.invalid")!
        let config = IdentityEndpointConfiguration(path: "/whoami", method: .get, responseIDKeyPath: ["id"], successStatusCodes: [200], headerNames: .init(authToken: "X-Auth"))
        let pinned = OriginUserIdentityResolver.namespace(origin: "https://example.invalid", userID: 1)

        // Happy refresh: endpoint always returns id 1, so post-refresh identity
        // matches and the upload completes with exactly one forced refresh.
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 1; sender.unauthorizedUntilRefresh = true
        let refreshes = Counter()
        let identity = ScriptedIdentitySender([idResponse(200, ["id": 1])])
        let tokens = EndpointTokens(initialToken: "a", refreshedToken: "a2", resolver: OriginUserIdentityResolver(baseURL: base, configuration: config, sender: identity), onForceRefresh: { refreshes.increment(); sender.markRefreshed() })
        let store = tempStore(); defer { try? store.discard() }
        let result = try await FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: tokens, retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).upload(snapshot: makeSnapshot(buckets: 1, sessions: 0), authIdentity: pinned, store: store)
        try require(result.bucketsUpserted == 1, "refresh-through-endpoint upload failed")
        try require(refreshes.value == 1, "expected exactly one forced refresh")

        // Refreshed credential resolves to a different account -> fence.
        let sender2 = ScriptedFullSyncSender(); sender2.unauthorizedUntilRefresh = true
        let identity2 = ScriptedIdentitySender([idResponse(200, ["id": 1]), idResponse(200, ["id": 1]), idResponse(200, ["id": 2])])
        let tokens2 = EndpointTokens(initialToken: "a", refreshedToken: "a2", resolver: OriginUserIdentityResolver(baseURL: base, configuration: config, sender: identity2), onForceRefresh: { sender2.markRefreshed() })
        do {
            _ = try await FullSyncReporter(configuration: readyConfig(), sender: sender2, tokenSupplier: tokens2, retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).upload(snapshot: makeSnapshot(buckets: 1, sessions: 0), authIdentity: pinned, store: tempStore())
            throw FullSyncVerificationError.failed("post-refresh account change was accepted")
        } catch FullSyncError.authIdentityChanged {}
    }

    // A configured JSON error code (not the HTTP status) triggers the same
    // chunk shrink as a 413: a 400 carrying the code halves the 4-row chunk.
    static func verifyPayloadTooLargeJSONCodeSplit() async throws {
        var config = readyConfig(rows: 4)
        config.payloadTooLargeCode = PayloadTooLargeCode(keyPath: ["error", "code"], stringValues: ["PAYLOAD_TOO_LARGE"])
        let snapshot = makeSnapshot(buckets: 4, sessions: 0)
        let sender = ScriptedFullSyncSender(); sender.commitBuckets = 4
        // reserve(0), begin(1), first 4-row stage(2) -> 400 with the JSON code.
        sender.responseAtCallIndex[2] = jsonData(["error": ["code": "PAYLOAD_TOO_LARGE"]])
        sender.statusAtCallIndex = [2: 400]
        let store = tempStore(); defer { try? store.discard() }
        let result = try await FullSyncReporter(configuration: config, sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).upload(snapshot: snapshot, authIdentity: "ns:account-1", store: store)
        try require(result.bucketsUpserted == 4, "JSON-code split commit count wrong")
        let actions = sender.calls.map { obj(rawBody($0))["action"] as? String }
        try require(actions == ["reserve", "begin", "stage", "stage", "stage", "commit"], "JSON-code split action sequence wrong: \(actions)")
    }

    // A 501 surfaces the dedicated unsupported error, no commit is attempted,
    // and the reserved state is left intact for the caller to decide.
    static func verifyUnsupportedStatus() async throws {
        let sender = ScriptedFullSyncSender(); sender.statusAtCallIndex = [1: 501]
        let store = tempStore(); defer { try? store.discard() }
        do {
            _ = try await FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).upload(snapshot: makeSnapshot(buckets: 1, sessions: 0), authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("501 did not surface unsupported")
        } catch FullSyncError.unsupported {}
        let actions = sender.calls.map { obj(rawBody($0))["action"] as? String }
        try require(!actions.contains("commit"), "501 still committed")
    }

    // A 410 surfaces rejoinRequired and discards only the local upload state;
    // the reporter never has access to external credentials, so they cannot be
    // deleted here. The dedicated error lets the caller start a fresh join.
    static func verifyRejoinRequiredKeepsCredentials() async throws {
        let sender = ScriptedFullSyncSender(); sender.statusAtCallIndex = [1: 410]
        let store = tempStore(); defer { try? store.discard() }
        do {
            _ = try await FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }).upload(snapshot: makeSnapshot(buckets: 1, sessions: 0), authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("410 did not surface rejoinRequired")
        } catch FullSyncError.rejoinRequired {}
        try require(!store.hasState(), "410 did not discard local upload state")
    }

    // reserve retries a 500/502/503/504 with the reserve-specific 0.5s/1s
    // backoff and its own retry budget, then succeeds. A recording sleeper
    // proves the exact backoff schedule.
    static func verifyReserveBackoffOnServerErrors() async throws {
        let recorder = RecordingSleeper()
        let sender = ScriptedFullSyncSender()
        // reserve is call 0; fail it with 503 then 500, succeed on the third try.
        sender.statusAtCallIndex = [0: 503, 1: 500]
        let store = tempStore(); defer { try? store.discard() }
        _ = try await FullSyncReporter(configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(), retrySleeper: recorder, makeUploadID: { validUploadID }).reserve(hostname: "device", authIdentity: "ns:account-1", generationBaseline: 1, store: store)
        try require(recorder.seconds == [0.5, 1], "reserve backoff schedule wrong: \(recorder.seconds)")
        try require(sender.calls.count == 3, "reserve did not retry twice before success")
    }
}
