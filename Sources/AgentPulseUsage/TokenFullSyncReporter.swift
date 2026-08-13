import Foundation
import AgentPulseReporting

// The resumable full-sync state machine: reserve -> begin -> stage chunks ->
// commit, with crash-safe recovery, a single forced token refresh on 401 with
// an account-identity fence, exact-count commit acknowledgement, and
// cooperative cancellation. It is fully configuration-driven and never touches
// a ledger: the caller injects the payload snapshot, the transport, the token
// supplier, and the state store.

public struct FullSyncReporter: Sendable {
    private let configuration: FullSyncConfiguration
    private let sender: FullSyncRequestSending
    private let tokenSupplier: FullSyncTokenSupplying
    private let encoder: UsageIngestEncoder
    private let environment: [String: String]
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let retrySleeper: RetrySleeper
    private let makeUploadID: @Sendable () -> String

    /// Body byte count at or above which a request is gzip-compressed. Mirrors
    /// the incremental client's threshold for wire parity.
    public static let gzipMinimumBytes = 1024

    public init(
        configuration: FullSyncConfiguration,
        sender: FullSyncRequestSending,
        tokenSupplier: FullSyncTokenSupplying,
        encoder: UsageIngestEncoder = UsageIngestEncoder(),
        environment: [String: String] = [:],
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        retrySleeper: RetrySleeper = TaskSleepSleeper(),
        makeUploadID: @escaping @Sendable () -> String = FullSyncReporter.randomUploadID
    ) {
        self.configuration = configuration
        self.sender = sender
        self.tokenSupplier = tokenSupplier
        self.encoder = encoder
        self.environment = environment
        self.timeZone = timeZone
        self.now = now
        self.retrySleeper = retrySleeper
        self.makeUploadID = makeUploadID
    }

    // MARK: - Public entry points

    /// Reserves the remote fence before the caller captures its payload. The
    /// persisted generation baseline makes the later snapshot binding exact.
    @discardableResult
    public func reserve(
        hostname: String,
        authIdentity: String,
        generationBaseline: Int64,
        store: FullSyncStateStore
    ) async throws -> FullSyncReservation {
        try validateConfiguration()
        let identity = try normalizedIdentity(authIdentity)
        let normalizedHostname = CanonicalHostname.normalize(hostname)
        guard !normalizedHostname.isEmpty, normalizedHostname == CanonicalHostname.normalize(configuration.hostname),
              generationBaseline >= 0 else {
            throw FullSyncError.configurationMissing
        }

        if store.hasState() {
            do {
                let state = try store.load()
                try requireSameIdentity(state.authIdentity, identity)
                guard state.hostname == normalizedHostname, state.generationBaseline == generationBaseline else {
                    throw FullSyncError.rescanRequired
                }
                return reservation(from: state)
            } catch FullSyncError.corruptState {
                try store.discard()
                throw FullSyncError.rescanRequired
            }
        }

        let uploadID = makeUploadID()
        guard Self.isValidUploadID(uploadID) else { throw FullSyncError.corruptState }
        let response = try await dispatch(
            rawBody: reserveEnvelope(hostname: normalizedHostname),
            identity: identity,
            expectedStatus: configuration.successStatuses.reserve
        )
        guard let fence = response.fenceRevision else { throw FullSyncError.malformedResponse }
        guard fence >= 0 else { throw FullSyncError.invalidFenceRevision(fence) }
        let state = FullSyncState(
            uploadID: uploadID, hostname: normalizedHostname, phase: .reserved, fenceRevision: fence,
            authIdentity: identity, payloadFingerprint: "", generationBaseline: generationBaseline,
            payloadBound: false, rawGeneration: generationBaseline,
            expectedBuckets: 0, expectedSessions: 0, expectedAutonomySessions: 0,
            autonomySources: [], autonomyWindowStart: "", autonomyWindowEnd: ""
        )
        try store.save(state)
        return reservation(from: state)
    }

    /// Binds a snapshot captured at the reserved generation, then completes the
    /// begin/stage/commit sequence. No implicit reservation is performed.
    @discardableResult
    public func completeUpload(
        snapshot: FullSyncPayloadSnapshot,
        authIdentity: String,
        store: FullSyncStateStore
    ) async throws -> FullSyncResult {
        try validateConfiguration()
        let identity = try normalizedIdentity(authIdentity)
        let state: FullSyncState
        do {
            state = try store.load()
        } catch FullSyncError.corruptState {
            try store.discard()
            throw FullSyncError.rescanRequired
        }
        try requireSameIdentity(state.authIdentity, identity)
        guard snapshot.rawGeneration == state.generationBaseline else {
            try store.discard()
            throw FullSyncError.rescanRequired
        }

        let fingerprint = FullSyncDigest.fingerprint(for: snapshot, hostname: state.hostname, encoder: encoder)
        var current = state
        if !current.payloadBound {
            guard current.phase == .reserved else { throw FullSyncError.corruptState }
            current.payloadBound = true
            current.payloadFingerprint = fingerprint
            current.rawGeneration = snapshot.rawGeneration
            current.expectedBuckets = snapshot.rowCount(for: .buckets)
            current.expectedSessions = snapshot.rowCount(for: .sessions)
            current.expectedAutonomySessions = snapshot.rowCount(for: .autonomySessions)
            current.autonomySources = snapshot.autonomySources
            current.autonomyWindowStart = snapshot.autonomyWindowStart
            current.autonomyWindowEnd = snapshot.autonomyWindowEnd
            current.phase = .prepared
            try store.save(current)
        } else {
            guard current.payloadFingerprint == fingerprint,
                  current.rawGeneration == snapshot.rawGeneration,
                  current.expectedBuckets == snapshot.rowCount(for: .buckets),
                  current.expectedSessions == snapshot.rowCount(for: .sessions),
                  current.expectedAutonomySessions == snapshot.rowCount(for: .autonomySessions),
                  current.autonomySources == snapshot.autonomySources,
                  current.autonomyWindowStart == snapshot.autonomyWindowStart,
                  current.autonomyWindowEnd == snapshot.autonomyWindowEnd else {
                try store.discard()
                throw FullSyncError.rescanRequired
            }
        }

        if current.phase == .committed { return committedResult(from: current, alreadyCommitted: true) }
        try Task.checkCancellation()
        if current.phase == .prepared {
            _ = try await dispatch(
                rawBody: baseEnvelope(action: configuration.actionNames.begin, state: current),
                identity: identity, expectedStatus: configuration.successStatuses.begin
            )
            current.phase = .begun
            try store.save(current)
        }
        try Task.checkCancellation()
        if current.phase == .begun {
            for kind in FullSyncKind.allCases {
                current = try await stage(kind: kind, state: current, snapshot: snapshot, identity: identity, store: store)
                try Task.checkCancellation()
            }
            current.phase = .staged
            try store.save(current)
        }
        guard current.phase == .staged else { throw FullSyncError.corruptState }
        try Task.checkCancellation()
        let response = try await dispatch(
            rawBody: baseEnvelope(action: configuration.actionNames.commit, state: current),
            identity: identity, expectedStatus: configuration.successStatuses.commit
        )
        guard let buckets = response.bucketsUpserted,
              let sessions = response.sessionsUpserted,
              let autonomy = response.autonomySessionsUpserted else {
            throw FullSyncError.malformedResponse
        }
        guard buckets == current.expectedBuckets, sessions == current.expectedSessions,
              autonomy == current.expectedAutonomySessions else {
            throw FullSyncError.acknowledgementCountMismatch
        }
        current.phase = .committed
        current.committedBucketsUpserted = buckets
        current.committedSessionsUpserted = sessions
        current.committedAutonomySessionsUpserted = autonomy
        try store.save(current)
        return committedResult(from: current, alreadyCommitted: false)
    }

    /// Uploads the snapshot to completion, resuming any recoverable upload found
    /// in the store. authIdentity is the stable identity of the current account;
    /// it must be non-empty so the resume fence and the 401-refresh fence can
    /// compare against it.
    @discardableResult
    public func upload(
        snapshot: FullSyncPayloadSnapshot,
        authIdentity: String,
        store: FullSyncStateStore
    ) async throws -> FullSyncResult {
        _ = try await reserve(
            hostname: configuration.hostname, authIdentity: authIdentity,
            generationBaseline: snapshot.rawGeneration, store: store
        )
        return try await completeUpload(snapshot: snapshot, authIdentity: authIdentity, store: store)
    }

    /// Discards the persisted upload state and all chunk snapshots. The caller
    /// invokes this only after its own local ledger commit has durably recorded
    /// that the full sync succeeded, so the remote-ack -> ledger-commit window
    /// stays crash-recoverable: until finalize runs, a restart re-enters the
    /// idempotent committed branch (zero network) and can retry the ledger
    /// commit. Safe to call when no state exists.
    public func finalize(store: FullSyncStateStore) throws {
        try store.discard()
    }

    // MARK: - Staging

    /// Stages every chunk of one kind. Confirmed chunks are skipped; an
    /// unconfirmed chunk with a persisted snapshot is re-read and digest-checked
    /// (never re-encoded from the live snapshot) so resume bytes never drift.
    private func stage(
        kind: FullSyncKind,
        state: FullSyncState,
        snapshot: FullSyncPayloadSnapshot,
        identity: String,
        store: FullSyncStateStore
    ) async throws -> FullSyncState {
        var current = state
        let total = current.expectedRows(for: kind)
        var offset = 0
        var chunkIndex = 0
        while offset < total {
            try Task.checkCancellation()
            var record = current.chunk(kind: kind, index: chunkIndex)

            if let existing = record, existing.confirmed {
                offset = existing.offset + existing.rows
                chunkIndex += 1
                continue
            }

            if record == nil {
                let boundary = try makeBoundary(kind: kind, offset: offset, total: total, snapshot: snapshot, state: current, chunkIndex: chunkIndex)
                let body = stageEnvelope(kind: kind, chunkIndex: chunkIndex, offset: boundary.offset, rows: boundary.rows, snapshot: snapshot, state: current)
                let snapshotFile = try store.writeChunkSnapshot(body, kind: kind, chunkIndex: chunkIndex)
                let newRecord = FullSyncChunkRecord(
                    kind: kind, chunkIndex: chunkIndex, offset: boundary.offset, rows: boundary.rows,
                    digest: FullSyncDigest.hex(body), snapshotFile: snapshotFile, confirmed: false
                )
                current.chunks.append(newRecord)
                try store.save(current)
                record = newRecord
            }

            guard let boundaryRecord = record else { throw FullSyncError.corruptState }

            let rebuiltBody = stageEnvelope(
                kind: kind, chunkIndex: boundaryRecord.chunkIndex, offset: boundaryRecord.offset,
                rows: boundaryRecord.rows, snapshot: snapshot, state: current
            )
            let stagedBody: Data
            if let saved = try? store.readChunkSnapshot(boundaryRecord.snapshotFile),
               FullSyncDigest.hex(saved) == boundaryRecord.digest {
                stagedBody = saved
            } else {
                stagedBody = rebuiltBody
                let rebuiltName = try store.writeChunkSnapshot(
                    rebuiltBody, kind: kind, chunkIndex: boundaryRecord.chunkIndex
                )
                guard let idx = current.chunks.firstIndex(where: {
                    $0.kind == kind && $0.chunkIndex == boundaryRecord.chunkIndex
                }) else { throw FullSyncError.corruptState }
                current.chunks[idx].digest = FullSyncDigest.hex(rebuiltBody)
                current.chunks[idx].snapshotFile = rebuiltName
                try store.save(current)
            }

            do {
                _ = try await dispatch(
                    rawBody: stagedBody, identity: identity,
                    expectedStatus: configuration.successStatuses.stage
                )
            } catch is PayloadTooLargeSignal {
                // The server rejected this unconfirmed chunk as too large. Halve
                // only this chunk's row span and retry the same offset/index; a
                // single row that is still rejected is unrecoverable. Confirmed
                // chunks are never touched, so re-splitting here is safe.
                current = try shrinkUnconfirmedChunk(
                    kind: kind, chunkIndex: chunkIndex, snapshot: snapshot,
                    state: current, store: store
                )
                continue
            }

            if let idx = current.chunks.firstIndex(where: { $0.kind == kind && $0.chunkIndex == chunkIndex }) {
                current.chunks[idx].confirmed = true
                try store.save(current)
            }
            offset = boundaryRecord.offset + boundaryRecord.rows
            chunkIndex += 1
        }
        return current
    }

    /// Reacts to an HTTP 413 for the unconfirmed chunk at (kind, chunkIndex) by
    /// halving its row span. The chunk's offset is preserved; only its rows are
    /// reduced to max(1, rows / 2). The chunk body, digest, and snapshot are
    /// rebuilt and atomically persisted so the subsequent retry re-reads the
    /// smaller staged bytes. A single-row chunk that still triggered 413 cannot
    /// be split further and is rejected as too large. Confirmed chunks are never
    /// consulted or modified here.
    private func shrinkUnconfirmedChunk(
        kind: FullSyncKind,
        chunkIndex: Int,
        snapshot: FullSyncPayloadSnapshot,
        state: FullSyncState,
        store: FullSyncStateStore
    ) throws -> FullSyncState {
        var current = state
        guard let idx = current.chunks.firstIndex(where: {
            $0.kind == kind && $0.chunkIndex == chunkIndex
        }) else { throw FullSyncError.corruptState }
        let record = current.chunks[idx]
        guard !record.confirmed else { throw FullSyncError.corruptState }
        guard record.rows > 1 else {
            throw FullSyncError.payloadTooLarge(kind: kind, chunkIndex: chunkIndex)
        }
        let shrunkRows = max(1, record.rows / 2)
        let rebuiltBody = stageEnvelope(
            kind: kind, chunkIndex: record.chunkIndex, offset: record.offset,
            rows: shrunkRows, snapshot: snapshot, state: current
        )
        let snapshotFile = try store.writeChunkSnapshot(
            rebuiltBody, kind: kind, chunkIndex: record.chunkIndex
        )
        current.chunks[idx].rows = shrunkRows
        current.chunks[idx].digest = FullSyncDigest.hex(rebuiltBody)
        current.chunks[idx].snapshotFile = snapshotFile
        try store.save(current)
        return current
    }

    private struct ChunkBoundary { let offset: Int; let rows: Int }

    /// Determines the row span of a chunk: at most the configured row cap, and
    /// halved repeatedly while the encoded envelope exceeds the byte cap. A
    /// single row that still exceeds the byte cap is rejected as too large.
    private func makeBoundary(
        kind: FullSyncKind,
        offset: Int,
        total: Int,
        snapshot: FullSyncPayloadSnapshot,
        state: FullSyncState,
        chunkIndex: Int
    ) throws -> ChunkBoundary {
        var rows = min(configuration.effectiveMaxRowsPerChunk, total - offset)
        while true {
            let body = stageEnvelope(kind: kind, chunkIndex: chunkIndex, offset: offset, rows: rows, snapshot: snapshot, state: state)
            if body.count <= configuration.effectiveMaxBytesPerChunk {
                return ChunkBoundary(offset: offset, rows: rows)
            }
            if rows == 1 { throw FullSyncError.payloadTooLarge(kind: kind, chunkIndex: chunkIndex) }
            rows = max(1, rows / 2)
        }
    }

    private func committedResult(from state: FullSyncState, alreadyCommitted: Bool) -> FullSyncResult {
        FullSyncResult(
            uploadID: state.uploadID,
            fenceRevision: state.fenceRevision,
            bucketsUpserted: state.committedBucketsUpserted ?? state.expectedBuckets,
            sessionsUpserted: state.committedSessionsUpserted ?? state.expectedSessions,
            autonomySessionsUpserted: state.committedAutonomySessionsUpserted ?? state.expectedAutonomySessions,
            wasAlreadyCommitted: alreadyCommitted
        )
    }

    // MARK: - Identity fence

    private enum IdentityMatch { case same, different, unverifiable }

    /// Compares two stable identities. Equal non-empty values are the same
    /// account. Two non-empty values that share a namespace prefix but differ
    /// prove a different account. Anything else (empty, or an unrecognized
    /// namespace pairing) is unverifiable and fails safe.
    private func identityMatch(_ expected: String, _ current: String) -> IdentityMatch {
        let e = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty || c.isEmpty { return .unverifiable }
        if e == c { return .same }
        if let ePrefix = namespacePrefix(e), let cPrefix = namespacePrefix(c), ePrefix == cPrefix {
            return .different
        }
        return .unverifiable
    }

    private func namespacePrefix(_ identity: String) -> String? {
        guard let range = identity.range(of: ":") else { return nil }
        return String(identity[identity.startIndex..<range.upperBound])
    }

    private func normalizedIdentity(_ identity: String) throws -> String {
        let value = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FullSyncError.authIdentityMissing }
        return value
    }

    private func requireSameIdentity(_ expected: String, _ current: String) throws {
        switch identityMatch(expected, current) {
        case .same: return
        case .different: throw FullSyncError.authIdentityChanged
        case .unverifiable: throw FullSyncError.authIdentityUnverifiable
        }
    }

    private func validateConfiguration() throws {
        guard configuration.isConfigured else { throw FullSyncError.configurationMissing }
        _ = try endpointURL()
    }

    private func reservation(from state: FullSyncState) -> FullSyncReservation {
        FullSyncReservation(
            uploadID: state.uploadID, fenceRevision: state.fenceRevision,
            generationBaseline: state.generationBaseline
        )
    }

    public static func randomUploadID() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
    }

    static func isValidUploadID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
    }

    // MARK: - Envelope construction

    private func endpointURL() throws -> URL {
        guard let baseURL = configuration.baseURL, !configuration.path.isEmpty else {
            throw FullSyncError.configurationMissing
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FullSyncError.invalidURL
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let suffix = configuration.path.hasPrefix("/") ? configuration.path : "/" + configuration.path
        components.path = base + suffix
        guard let url = components.url else { throw FullSyncError.invalidURL }
        return url
    }

    /// reserve envelope: action + hostname only (fence echoes 0). No uploadId.
    private func reserveEnvelope(hostname: String) -> Data {
        var root = OrderedFullSyncJSON()
        root.putString("action", configuration.actionNames.reserve)
        root.putStringOmitEmpty("hostname", hostname)
        root.putInt64("fenceRevision", 0)
        return root.finish()
    }

    /// begin / commit envelope: action, uploadId, hostname, expected counts,
    /// autonomy sources, echoed fence, autonomy window. No rows.
    private func baseEnvelope(action: String, state: FullSyncState) -> Data {
        envelopeBody(
            action: action, uploadID: state.uploadID, hostname: state.hostname,
            kind: nil, chunkIndex: nil,
            expectedBuckets: state.expectedBuckets, expectedSessions: state.expectedSessions,
            expectedAutonomy: state.expectedAutonomySessions,
            autonomySources: state.autonomySources, fenceRevision: state.fenceRevision,
            autonomyWindowStart: state.autonomyWindowStart, autonomyWindowEnd: state.autonomyWindowEnd,
            rowsKind: nil, rowsOffset: 0, rows: 0, snapshot: nil
        )
    }

    /// stage envelope: the base envelope plus kind, chunkIndex, and the chunk's
    /// rows serialized with the shared ingest encoder for exact wire parity.
    private func stageEnvelope(
        kind: FullSyncKind, chunkIndex: Int, offset: Int, rows: Int,
        snapshot: FullSyncPayloadSnapshot, state: FullSyncState
    ) -> Data {
        envelopeBody(
            action: configuration.actionNames.stage, uploadID: state.uploadID, hostname: state.hostname,
            kind: kind, chunkIndex: chunkIndex,
            expectedBuckets: state.expectedBuckets, expectedSessions: state.expectedSessions,
            expectedAutonomy: state.expectedAutonomySessions,
            autonomySources: state.autonomySources, fenceRevision: state.fenceRevision,
            autonomyWindowStart: state.autonomyWindowStart, autonomyWindowEnd: state.autonomyWindowEnd,
            rowsKind: kind, rowsOffset: offset, rows: rows, snapshot: snapshot
        )
    }

    /// Single canonical envelope builder used for begin/stage/commit. Emits keys
    /// in a fixed, deterministic order; omit-empty rules keep an absent field
    /// off the wire. Row arrays are produced by the shared ingest encoder so a
    /// staged chunk's row bytes equal the incremental wire byte-for-byte.
    private func envelopeBody(
        action: String, uploadID: String, hostname: String,
        kind: FullSyncKind?, chunkIndex: Int?,
        expectedBuckets: Int, expectedSessions: Int, expectedAutonomy: Int,
        autonomySources: [String], fenceRevision: Int64,
        autonomyWindowStart: String, autonomyWindowEnd: String,
        rowsKind: FullSyncKind?, rowsOffset: Int, rows: Int,
        snapshot: FullSyncPayloadSnapshot?
    ) -> Data {
        var root = OrderedFullSyncJSON()
        root.putString("action", action)
        root.putStringOmitEmpty("uploadId", uploadID)
        root.putStringOmitEmpty("hostname", hostname)
        if let kind { root.putString("kind", configuration.kindNames.wireToken(for: kind)) }
        if let chunkIndex { root.putInt64("chunkIndex", Int64(chunkIndex)) }
        root.putIntOmitZero("expectedBuckets", expectedBuckets)
        root.putIntOmitZero("expectedSessions", expectedSessions)
        root.putIntOmitZero("expectedAutonomy", expectedAutonomy)
        root.putStringArrayOmitEmpty("autonomySources", autonomySources)
        root.putInt64("fenceRevision", fenceRevision)
        root.putStringOmitEmpty("autonomyWindowStart", autonomyWindowStart)
        root.putStringOmitEmpty("autonomyWindowEnd", autonomyWindowEnd)
        if let rowsKind, let snapshot, rows > 0 {
            root.putRawOmitEmpty(rowsKey(for: rowsKind), rowsArrayJSON(kind: rowsKind, offset: rowsOffset, rows: rows, snapshot: snapshot))
        }
        return root.finish()
    }

    private func rowsKey(for kind: FullSyncKind) -> String {
        switch kind {
        case .buckets: return "buckets"
        case .sessions: return "sessions"
        case .autonomySessions: return "autonomySessions"
        }
    }

    /// Produces the JSON array bytes for a chunk's rows by encoding a single-kind
    /// request with the shared encoder and extracting the balanced array that
    /// follows its key. This guarantees the row bytes are identical to the
    /// incremental wire (field order, omit-empty, HTML escaping).
    private func rowsArrayJSON(kind: FullSyncKind, offset: Int, rows: Int, snapshot: FullSyncPayloadSnapshot) -> Data {
        var request = UsageIngestRequest()
        let key: String
        switch kind {
        case .buckets:
            request.buckets = Array(snapshot.buckets[offset..<(offset + rows)])
            key = "buckets"
        case .sessions:
            request.sessions = Array(snapshot.sessions[offset..<(offset + rows)])
            key = "sessions"
        case .autonomySessions:
            request.autonomySessions = Array(snapshot.autonomySessions[offset..<(offset + rows)])
            key = "autonomySessions"
        }
        let encoded = encoder.encode(request)
        return Self.extractArray(forKey: key, from: encoded) ?? Data("[]".utf8)
    }

    /// Extracts the balanced JSON array value that follows "key": in an object,
    /// respecting string literals and escapes so brackets inside strings do not
    /// confuse the scan.
    static func extractArray(forKey key: String, from data: Data) -> Data? {
        let bytes = Array(data)
        let needle = Array(Data(("\"" + key + "\":").utf8))
        guard let start = firstIndex(of: needle, in: bytes) else { return nil }
        var i = start + needle.count
        guard i < bytes.count, bytes[i] == UInt8(ascii: "[") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        let begin = i
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if escaped { escaped = false }
                else if b == UInt8(ascii: "\\") { escaped = true }
                else if b == UInt8(ascii: "\"") { inString = false }
            } else {
                if b == UInt8(ascii: "\"") { inString = true }
                else if b == UInt8(ascii: "[") { depth += 1 }
                else if b == UInt8(ascii: "]") {
                    depth -= 1
                    if depth == 0 { return Data(bytes[begin...i]) }
                }
            }
            i += 1
        }
        return nil
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for j in 0..<needle.count where haystack[start + j] != needle[j] { matched = false; break }
            if matched { return start }
        }
        return nil
    }

    // MARK: - Dispatch (single 401 refresh + identity fence, retry, decode)

    private func dispatch(
        rawBody: Data,
        identity: String,
        expectedStatus: String
    ) async throws -> FullSyncServerResponse {
        let useGzip = rawBody.count >= Self.gzipMinimumBytes
        let body: Data
        let gzipApplied: Bool
        if useGzip, let compressed = GzipCompressor.compress(rawBody) {
            body = compressed
            gzipApplied = true
        } else {
            body = rawBody
            gzipApplied = false
        }

        let policy = configuration.retryPolicy
        var didForceRefresh = false
        var retryCount = 0

        while true {
            try Task.checkCancellation()
            do {
                var token = try await tokenSupplier.token(forceRefresh: false)
                try requireSameIdentity(
                    identity, tokenSupplier.stableAccountIdentity(forToken: token)
                )
                let response = try await sender.send(makeRequest(body: body, gzip: gzipApplied, token: token))
                switch response.statusCode {
                case 200...299:
                    return try decode(response.body, expectedStatus: expectedStatus)
                case 401 where !didForceRefresh:
                    didForceRefresh = true
                    let refreshed = try await tokenSupplier.token(forceRefresh: true)
                    try requireSameIdentity(
                        tokenSupplier.stableAccountIdentity(forToken: token),
                        tokenSupplier.stableAccountIdentity(forToken: refreshed)
                    )
                    try requireSameIdentity(
                        identity, tokenSupplier.stableAccountIdentity(forToken: refreshed)
                    )
                    token = refreshed
                    let retried = try await sender.send(makeRequest(body: body, gzip: gzipApplied, token: token))
                    switch retried.statusCode {
                    case 200...299:
                        return try decode(retried.body, expectedStatus: expectedStatus)
                    case 401: throw FullSyncError.notAuthenticated
                    case 409: throw FullSyncError.fenceConflict
                    case 413: throw PayloadTooLargeSignal()
                    default:
                        if policy.isRetryable(retried), retryCount < policy.maxRetries {
                            try await sleepBeforeRetry(policy, retryCount: retryCount); retryCount += 1; continue
                        }
                        throw FullSyncError.httpFailure(statusCode: retried.statusCode)
                    }
                case 401: throw FullSyncError.notAuthenticated
                case 409: throw FullSyncError.fenceConflict
                case 413: throw PayloadTooLargeSignal()
                default:
                    if policy.isRetryable(response), retryCount < policy.maxRetries {
                        try await sleepBeforeRetry(policy, retryCount: retryCount); retryCount += 1; continue
                    }
                    throw FullSyncError.httpFailure(statusCode: response.statusCode)
                }
            } catch let error as FullSyncError {
                throw error
            } catch let signal as PayloadTooLargeSignal {
                // A 413 is a chunk-shaping signal, not a transport failure: never
                // retried or converted here. The staging loop halves the current
                // unconfirmed chunk and retries the same offset/index.
                throw signal
            } catch HTTPTransportError.requestNotWritten {
                guard retryCount < policy.maxRetries else { throw FullSyncError.transportFailure }
                try await sleepBeforeRetry(policy, retryCount: retryCount); retryCount += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw FullSyncError.transportFailure
            }
        }
    }

    private func decode(_ body: Data, expectedStatus: String) throws -> FullSyncServerResponse {
        do {
            let response = try JSONDecoder().decode(FullSyncServerResponse.self, from: body)
            guard response.status == expectedStatus else { throw FullSyncError.malformedResponse }
            return response
        } catch let error as FullSyncError {
            throw error
        } catch {
            throw FullSyncError.malformedResponse
        }
    }

    private func makeRequest(body: Data, gzip: Bool, token: SecretToken) throws -> FullSyncTransportRequest {
        let url = try endpointURL()
        var headers: [String: String] = [:]
        let names = configuration.headerNames
        if !names.contentType.isEmpty { headers[names.contentType] = "application/json" }
        for header in configuration.staticHeaders where !header.name.isEmpty {
            headers[header.name] = header.value
        }
        if !names.authToken.isEmpty { headers[names.authToken] = token.reveal() }
        if !names.timeZoneOffset.isEmpty {
            headers[names.timeZoneOffset] = RequestEnvironment.timeZoneOffset(for: now(), timeZone: timeZone)
        }
        if !names.locale.isEmpty,
           let locale = RequestEnvironment.locale(environment: environment, variableNames: configuration.localeEnvironmentVariables) {
            headers[names.locale] = locale
        }
        if gzip, !names.contentEncoding.isEmpty { headers[names.contentEncoding] = "gzip" }
        return FullSyncTransportRequest(url: url, headers: headers, body: body, isGzipped: gzip)
    }

    private func sleepBeforeRetry(_ policy: RetryPolicy, retryCount: Int) async throws {
        try await retrySleeper.sleep(seconds: policy.backoff(forRetryIndex: retryCount + 1))
    }
}

// MARK: - Minimal ordered JSON for full-sync envelopes

/// Internal signal that the server rejected a staged chunk body with HTTP 413.
/// It never escapes the reporter: dispatch throws it, and the staging loop
/// catches it to re-split the current unconfirmed chunk. It is deliberately
/// distinct from FullSyncError so it can never be surfaced or retried as a
/// generic transport failure.
private struct PayloadTooLargeSignal: Error {}

/// A tiny deterministic ordered-object JSON writer. Reuses the same string
/// escaping as the shared ingest encoder so envelope bytes stay consistent
/// across producers. Raw values (pre-serialized arrays) are spliced verbatim.
struct OrderedFullSyncJSON {
    private var members: [(String, String)] = []

    mutating func putString(_ key: String, _ value: String) {
        members.append((key, FullSyncJSONEscape.encode(value)))
    }
    mutating func putStringOmitEmpty(_ key: String, _ value: String) {
        guard !value.isEmpty else { return }
        putString(key, value)
    }
    mutating func putInt64(_ key: String, _ value: Int64) {
        members.append((key, String(value)))
    }
    mutating func putIntOmitZero(_ key: String, _ value: Int) {
        guard value != 0 else { return }
        members.append((key, String(value)))
    }
    mutating func putStringArrayOmitEmpty(_ key: String, _ values: [String]) {
        guard !values.isEmpty else { return }
        let joined = values.map { FullSyncJSONEscape.encode($0) }.joined(separator: ",")
        members.append((key, "[" + joined + "]"))
    }
    /// Splices an already-serialized JSON fragment (for example a row array).
    mutating func putRawOmitEmpty(_ key: String, _ raw: Data) {
        let text = String(decoding: raw, as: UTF8.self)
        guard !text.isEmpty, text != "[]" else { return }
        members.append((key, text))
    }

    func finish() -> Data {
        var out = "{"
        for (index, member) in members.enumerated() {
            if index > 0 { out.append(",") }
            out.append(FullSyncJSONEscape.encode(member.0))
            out.append(":")
            out.append(member.1)
        }
        out.append("}")
        return Data(out.utf8)
    }
}

/// String escaping matching the shared ingest encoder (HTML-safe < > &), so
/// the full-sync envelopes serialize identically to the ingest wire.
enum FullSyncJSONEscape {
    static func encode(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result.append("\\\"")
            case "\\": result.append("\\\\")
            case "\n": result.append("\\n")
            case "\r": result.append("\\r")
            case "\t": result.append("\\t")
            case "<": result.append("\\u003c")
            case ">": result.append("\\u003e")
            case "&": result.append("\\u0026")
            default:
                if scalar.value < 0x20 {
                    result.append(String(format: "\\u%04x", scalar.value))
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result.append("\"")
        return result
    }
}
