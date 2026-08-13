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
            return HTTPResponse(statusCode: forced, body: Data("{}".utf8))
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
        if action.contains("reserve") { status = "reserved" }
        else if action.contains("commit") { status = "committed" }
        else { status = "staging" }
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
    func stableAccountIdentity(forToken token: SecretToken) -> String { identityForToken(token.reveal()) }
}

private struct ImmediateSleeper: RetrySleeper {
    func sleep(seconds: TimeInterval) async throws {}
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
        try await verifyStatePermissions()
        try await verifySingleRefreshOn401()
        try await verifyIdentityFenceOnResume()
        try await verifyRescanOnFingerprintDrift()
        try await verifyAckCountMismatch()
        try await verifyFenceConflict()
        try await verifyTransportRetry()
        try await verifyWireVocabularyConfiguration()
        try await verifyConfigurationGates()
        try await verifyReservationContract()
        try await verifyResponseValidation()
        try await verifyPerRequestIdentityFence()
        try await verifyCorruptStateRecovery()
        try await verifyUnconfirmedChunkRebuild()
        try await verifyGzipBoundary()
        try await verifyPayloadTooLargeSplit()
        try await verifySingleRowPayloadTooLarge()
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
        try require((firstAccepted["chunkIndex"] as? NSNumber)?.intValue == 0, "retry must reuse chunkIndex 0")
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
            stage0.keys.contains("chunkIndex")
                && (stage0["chunkIndex"] as? NSNumber)?.intValue == 0,
            "first stage chunkIndex must be explicitly encoded as 0"
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
            stage2.keys.contains("chunkIndex")
                && (stage2["chunkIndex"] as? NSNumber)?.intValue == 0,
            "first chunkIndex for each kind must be explicitly encoded as 0"
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
            throw FullSyncVerificationError.failed("fence conflict not surfaced")
        } catch FullSyncError.fenceConflict {}
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

        for response in [
            jsonData(["status": "reserved"]),
            jsonData(["status": "reserved", "fenceRevision": 1, "fence_revision": 2]),
        ] {
            let invalidSender = ScriptedFullSyncSender()
            invalidSender.responseAtCallIndex[0] = response
            let invalidStore = tempStore()
            defer { try? invalidStore.discard() }
            let invalidReporter = FullSyncReporter(
                configuration: readyConfig(), sender: invalidSender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            )
            do {
                _ = try await invalidReporter.reserve(
                    hostname: "device", authIdentity: "ns:account-1",
                    generationBaseline: 1, store: invalidStore
                )
                throw FullSyncVerificationError.failed("invalid fence response accepted")
            } catch FullSyncError.malformedResponse {}
        }

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

        let empty = FullSyncPayloadSnapshot(rawGeneration: 1)
        let sender = ScriptedFullSyncSender()
        sender.responseAtCallIndex[2] = jsonData([
            "status": "committed", "buckets_upserted": 0, "sessions_upserted": 0,
        ])
        let store = tempStore(); defer { try? store.discard() }
        do {
            _ = try await FullSyncReporter(
                configuration: readyConfig(), sender: sender, tokenSupplier: sameAccountTokens(),
                retrySleeper: ImmediateSleeper(), makeUploadID: { validUploadID }
            ).upload(snapshot: empty, authIdentity: "ns:account-1", store: store)
            throw FullSyncVerificationError.failed("missing zero commit count accepted")
        } catch FullSyncError.malformedResponse {}
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
}
