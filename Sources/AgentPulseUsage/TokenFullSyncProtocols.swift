import Foundation
import AgentPulseReporting

// Configuration-driven, resumable full-sync upload core.
//
// This layer speaks a generic four-phase upload protocol
// (reserve -> begin -> stage chunks -> commit) whose every environment-specific
// value is injected by the caller: endpoint URL, request path, and header
// names all come from configuration, never a baked-in constant. It never talks
// to a ledger directly. Callers hand it an already-materialized snapshot of the
// payload rows plus the auth identity, and inject the request transport. The
// core is responsible only for the wire contract, atomic recoverable state, and
// the single-refresh identity fence.

/// The four ordered phases of the upload protocol. The wire verb for each is
/// caller-configured, so no action verb is hardcoded onto the wire.
public enum FullSyncPhase: String, Codable, Sendable, CaseIterable {
    /// A server fence has been reserved, but no local payload is bound yet.
    case reserved
    /// Prepared locally but not begun with the server yet.
    case prepared
    /// The server acknowledged begin; chunk staging may proceed.
    case begun
    /// Every chunk has been staged and confirmed; commit may proceed.
    case staged
    /// The server acknowledged commit. Terminal, carries the server counts.
    case committed
}

/// The kinds of row streams uploaded in order. Each kind is chunked and staged
/// independently; the wire "kind" token is caller-configured.
public enum FullSyncKind: String, Codable, Sendable, CaseIterable {
    case buckets
    case sessions
    case autonomySessions
}

/// The wire action verbs. Defaults are generic and overridable so the transport
/// contract carries no environment-specific vocabulary.
public struct FullSyncActionNames: Codable, Equatable, Sendable {
    public var reserve: String
    public var begin: String
    public var stage: String
    public var commit: String

    public init(
        reserve: String = "reserve",
        begin: String = "begin",
        stage: String = "stage",
        commit: String = "commit"
    ) {
        self.reserve = reserve
        self.begin = begin
        self.stage = stage
        self.commit = commit
    }
}

/// The wire "kind" tokens. Defaults are generic and overridable.
public struct FullSyncKindNames: Codable, Equatable, Sendable {
    public var buckets: String
    public var sessions: String
    public var autonomySessions: String

    public init(
        buckets: String = "buckets",
        sessions: String = "sessions",
        autonomySessions: String = "autonomy"
    ) {
        self.buckets = buckets
        self.sessions = sessions
        self.autonomySessions = autonomySessions
    }

    public func wireToken(for kind: FullSyncKind) -> String {
        switch kind {
        case .buckets: return buckets
        case .sessions: return sessions
        case .autonomySessions: return autonomySessions
        }
    }
}

/// Exact success statuses expected for each protocol phase. These values are
/// configuration-driven, but never optional or interpreted generically.
public struct FullSyncSuccessStatuses: Codable, Equatable, Sendable {
    public var reserve: String
    public var begin: String
    public var stage: String
    public var commit: String

    public init(
        reserve: String = "reserved",
        begin: String = "staging",
        stage: String = "staging",
        commit: String = "committed"
    ) {
        self.reserve = reserve
        self.begin = begin
        self.stage = stage
        self.commit = commit
    }
}

/// Static, fully caller-supplied configuration for the full-sync transport.
/// Every value is injected; the core hardcodes no host, path, header, or verb.
public struct FullSyncConfiguration: Sendable, Equatable {
    /// Backend base URL. Nil means "not configured": the core refuses to act.
    public var baseURL: URL?
    /// Request path appended to the base URL (for example "/usage/full-sync").
    public var path: String
    /// Canonicalized hostname tag attached to the upload record.
    public var hostname: String
    /// Header names to emit. Empty names are omitted from the request.
    public var headerNames: RequestHeaderNames
    /// Static metadata headers attached to every request.
    public var staticHeaders: [StaticHeader]
    /// Environment variable names consulted, in order, to resolve a locale.
    public var localeEnvironmentVariables: [String]
    /// Wire action verbs.
    public var actionNames: FullSyncActionNames
    /// Wire kind tokens.
    public var kindNames: FullSyncKindNames
    /// Exact response statuses accepted for each action.
    public var successStatuses: FullSyncSuccessStatuses
    /// Max rows per staged chunk. Clamped to at least 1.
    public var maxRowsPerChunk: Int
    /// Soft cap on raw (pre-gzip) chunk body bytes; a chunk that exceeds it is
    /// split, unless it is a single row (then rejected as too large).
    public var maxBytesPerChunk: Int
    /// Retry policy applied to transient transport / status failures.
    public var retryPolicy: RetryPolicy

    public init(
        baseURL: URL? = nil,
        path: String = "",
        hostname: String = "",
        headerNames: RequestHeaderNames = RequestHeaderNames(),
        staticHeaders: [StaticHeader] = [],
        localeEnvironmentVariables: [String] = [],
        actionNames: FullSyncActionNames = FullSyncActionNames(),
        kindNames: FullSyncKindNames = FullSyncKindNames(),
        successStatuses: FullSyncSuccessStatuses = FullSyncSuccessStatuses(),
        maxRowsPerChunk: Int = 2_000,
        maxBytesPerChunk: Int = 8 * 1024 * 1024,
        retryPolicy: RetryPolicy = RetryPolicy()
    ) {
        self.baseURL = baseURL
        self.path = path
        self.hostname = hostname
        self.headerNames = headerNames
        self.staticHeaders = staticHeaders
        self.localeEnvironmentVariables = localeEnvironmentVariables
        self.actionNames = actionNames
        self.kindNames = kindNames
        self.successStatuses = successStatuses
        self.maxRowsPerChunk = maxRowsPerChunk
        self.maxBytesPerChunk = maxBytesPerChunk
        self.retryPolicy = retryPolicy
    }

    public var isConfigured: Bool {
        baseURL != nil
            && !path.isEmpty
            && actionNames.allTokensArePresent
            && kindNames.allTokensArePresent
            && successStatuses.allTokensArePresent
    }

    var effectiveMaxRowsPerChunk: Int { max(1, maxRowsPerChunk) }
    var effectiveMaxBytesPerChunk: Int { max(1, maxBytesPerChunk) }
}

private extension FullSyncSuccessStatuses {
    var allTokensArePresent: Bool {
        [reserve, begin, stage, commit].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension FullSyncActionNames {
    var allTokensArePresent: Bool {
        [reserve, begin, stage, commit].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension FullSyncKindNames {
    var allTokensArePresent: Bool {
        [buckets, sessions, autonomySessions].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

/// A materialized, caller-provided snapshot of everything the upload will send.
/// The core treats this as the authoritative payload: persisted state binds to
/// a fingerprint over these bytes, and staged chunk bytes are snapshotted to
/// disk, so later churn in the caller source can never shift an in-flight
/// upload's digests.
public struct FullSyncPayloadSnapshot: Sendable, Equatable {
    public var buckets: [UsageBucketPayload]
    public var sessions: [UsageSessionPayload]
    public var autonomySessions: [AutonomySessionPayload]
    public var autonomySourceStatuses: [AutonomySourceStatusPayload]
    public var autonomyWindowStart: String
    public var autonomyWindowEnd: String
    /// Caller-opaque monotonic generation of the source snapshot. Recorded so a
    /// resume can detect the source was regenerated underneath an upload.
    public var rawGeneration: Int64

    public init(
        buckets: [UsageBucketPayload] = [],
        sessions: [UsageSessionPayload] = [],
        autonomySessions: [AutonomySessionPayload] = [],
        autonomySourceStatuses: [AutonomySourceStatusPayload] = [],
        autonomyWindowStart: String = "",
        autonomyWindowEnd: String = "",
        rawGeneration: Int64 = 0
    ) {
        self.buckets = buckets
        self.sessions = sessions
        self.autonomySessions = autonomySessions
        self.autonomySourceStatuses = autonomySourceStatuses
        self.autonomyWindowStart = autonomyWindowStart
        self.autonomyWindowEnd = autonomyWindowEnd
        self.rawGeneration = rawGeneration
    }

    public func rowCount(for kind: FullSyncKind) -> Int {
        switch kind {
        case .buckets: return buckets.count
        case .sessions: return sessions.count
        case .autonomySessions: return autonomySessions.count
        }
    }

    /// Sorted, de-duplicated autonomy source names, so the fingerprint and
    /// begin metadata are order-independent.
    public var autonomySources: [String] {
        var seen = Set<String>()
        for status in autonomySourceStatuses {
            let source = status.source.trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty { seen.insert(source) }
        }
        return seen.sorted()
    }
}

/// The response the server returns for reserve/begin/stage/commit. Fields stay
/// optional at decode time so the action-specific validator can distinguish a
/// required zero from a missing value.
public struct FullSyncServerResponse: Sendable, Equatable, Decodable {
    public var status: String
    public var fenceRevision: Int64?
    public var bucketsUpserted: Int?
    public var sessionsUpserted: Int?
    public var autonomySessionsUpserted: Int?

    public init(
        status: String,
        fenceRevision: Int64? = nil,
        bucketsUpserted: Int? = nil,
        sessionsUpserted: Int? = nil,
        autonomySessionsUpserted: Int? = nil
    ) {
        self.status = status
        self.fenceRevision = fenceRevision
        self.bucketsUpserted = bucketsUpserted
        self.sessionsUpserted = sessionsUpserted
        self.autonomySessionsUpserted = autonomySessionsUpserted
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case fenceRevision
        case fenceRevisionSnake = "fence_revision"
        case bucketsUpserted = "buckets_upserted"
        case sessionsUpserted = "sessions_upserted"
        case autonomySessionsUpserted = "autonomy_sessions_upserted"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        let camel = try container.decodeIfPresent(Int64.self, forKey: .fenceRevision)
        let snake = try container.decodeIfPresent(Int64.self, forKey: .fenceRevisionSnake)
        if let camel, let snake, camel != snake {
            throw DecodingError.dataCorruptedError(
                forKey: .fenceRevision,
                in: container,
                debugDescription: "conflicting fence revision fields"
            )
        }
        fenceRevision = camel ?? snake
        bucketsUpserted = try container.decodeIfPresent(Int.self, forKey: .bucketsUpserted)
        sessionsUpserted = try container.decodeIfPresent(Int.self, forKey: .sessionsUpserted)
        autonomySessionsUpserted = try container.decodeIfPresent(Int.self, forKey: .autonomySessionsUpserted)
    }
}

/// Durable result of the reserve step. The payload must be captured at exactly
/// this generation before `completeUpload` binds it to the reservation.
public struct FullSyncReservation: Sendable, Equatable {
    public var uploadID: String
    public var fenceRevision: Int64
    public var generationBaseline: Int64

    public init(uploadID: String, fenceRevision: Int64, generationBaseline: Int64) {
        self.uploadID = uploadID
        self.fenceRevision = fenceRevision
        self.generationBaseline = generationBaseline
    }
}

/// Final result surfaced to the caller once commit is acknowledged.
public struct FullSyncResult: Sendable, Equatable {
    public var uploadID: String
    public var fenceRevision: Int64
    public var bucketsUpserted: Int
    public var sessionsUpserted: Int
    public var autonomySessionsUpserted: Int
    /// True when returned from a previously committed upload rather than a
    /// commit performed on this call (idempotent replay).
    public var wasAlreadyCommitted: Bool

    public init(
        uploadID: String,
        fenceRevision: Int64,
        bucketsUpserted: Int,
        sessionsUpserted: Int,
        autonomySessionsUpserted: Int,
        wasAlreadyCommitted: Bool
    ) {
        self.uploadID = uploadID
        self.fenceRevision = fenceRevision
        self.bucketsUpserted = bucketsUpserted
        self.sessionsUpserted = sessionsUpserted
        self.autonomySessionsUpserted = autonomySessionsUpserted
        self.wasAlreadyCommitted = wasAlreadyCommitted
    }
}

/// Errors surfaced by the full-sync core. None embed credential bytes or raw
/// server bodies beyond a status code.
public enum FullSyncError: Error, Equatable, Sendable {
    case configurationMissing
    case invalidURL
    case authIdentityMissing
    case invalidFenceRevision(Int64)
    case notAuthenticated
    case authIdentityChanged
    case authIdentityUnverifiable
    case rescanRequired
    case payloadTooLarge(kind: FullSyncKind, chunkIndex: Int)
    case fenceConflict
    case chunkDigestMismatch(kind: FullSyncKind, chunkIndex: Int)
    case acknowledgementCountMismatch
    case httpFailure(statusCode: Int)
    case transportFailure
    case malformedResponse
    case corruptState
}

/// A single full-sync request the transport must deliver. Action, kind, and
/// header vocabulary are already resolved to caller-configured wire values.
public struct FullSyncTransportRequest: Sendable, Equatable {
    public var url: URL
    /// Header name -> value pairs, already resolved (the auth header carries the
    /// revealed token; callers must not log this).
    public var headers: [String: String]
    /// Raw or gzip-compressed body bytes, per isGzipped.
    public var body: Data
    public var isGzipped: Bool

    public init(url: URL, headers: [String: String], body: Data, isGzipped: Bool) {
        self.url = url
        self.headers = headers
        self.body = body
        self.isGzipped = isGzipped
    }
}

/// Injectable transport. A thrown HTTPTransportError.requestNotWritten is the
/// only failure safe to retry; any other thrown error is treated as
/// write-unknown, matching the incremental client's contract.
public protocol FullSyncRequestSending: Sendable {
    func send(_ request: FullSyncTransportRequest) async throws -> HTTPResponse
}

/// Supplies the bearer token and the stable account identity derived from it,
/// so the core can perform exactly one forced refresh on 401 and fence when the
/// account provably changes. Injectable for tests and to reuse the incremental
/// client's token plumbing.
public protocol FullSyncTokenSupplying: Sendable {
    func token(forceRefresh: Bool) async throws -> SecretToken
    /// Derives a stable, comparable account identity from a revealed token.
    /// Returns an empty string when it cannot be derived; empty is treated as
    /// "unverifiable" and fences the upload.
    func stableAccountIdentity(forToken token: SecretToken) -> String
}
