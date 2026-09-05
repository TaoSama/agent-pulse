import Foundation

/// Supplies a bearer token on demand, optionally forcing a refresh. Injectable
/// so the ingest client can be tested without a real token source, and so an
/// unauthorized response can trigger exactly one forced refresh.
public protocol TokenSupplying: Sendable {
    func token(forceRefresh: Bool) async throws -> SecretToken
}

/// Adapts the synchronous command token provider to the async TokenSupplying
/// surface the client consumes.
public struct CommandTokenSupplier: TokenSupplying {
    private let provider: ConfiguredCommandTokenProvider

    public init(provider: ConfiguredCommandTokenProvider = ConfiguredCommandTokenProvider()) {
        self.provider = provider
    }

    /// Runs the synchronous, blocking provider off the Swift cooperative
    /// executor. The provider spawns a subprocess and waits on it, so calling
    /// it directly would tie up a cooperative thread for the whole helper
    /// duration; instead we hop to a dedicated background thread.
    ///
    /// Cancellation: a detached Thread does not inherit the calling task, so
    /// Task.isCancelled is meaningless inside the worker. Instead the task
    /// cancellation handler flips a shared latch that resolves the awaiting
    /// continuation with CancellationError immediately, so the caller is never
    /// blocked waiting on a slow helper. The helper itself is still bounded by
    /// its configured timeout and its result is simply discarded once the
    /// continuation has already been resolved. The latch guarantees the
    /// continuation is resumed exactly once, whichever path wins the race.
    public func token(forceRefresh: Bool) async throws -> SecretToken {
        try Task.checkCancellation()
        let provider = self.provider
        let latch = ContinuationLatch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SecretToken, Error>) in
                latch.attach(continuation)
                let thread = Thread {
                    do {
                        let token = try provider.token(forceRefresh: forceRefresh)
                        latch.resolve(.success(token))
                    } catch {
                        latch.resolve(.failure(error))
                    }
                }
                thread.name = "command-token-supplier"
                thread.stackSize = 512 * 1024
                thread.start()
            }
        } onCancel: {
            latch.resolve(.failure(CancellationError()))
        }
    }
}

/// Bridges a single CheckedContinuation to at-most-one resume, arbitrating
/// between the background worker finishing and the task being cancelled. The
/// first resolution wins; later resolutions are dropped. The continuation may
/// be attached after a resolution has already arrived (the cancellation handler
/// can fire before the continuation body runs), so a pending result is
/// replayed on attach.
final class ContinuationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SecretToken, Error>?
    private var pendingResult: Result<SecretToken, Error>?
    private var isResolved = false

    func attach(_ continuation: CheckedContinuation<SecretToken, Error>) {
        lock.lock()
        if let pending = pendingResult, !isResolved {
            isResolved = true
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: pending)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<SecretToken, Error>) {
        lock.lock()
        guard !isResolved else { lock.unlock(); return }
        if let continuation = continuation {
            isResolved = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            // Continuation not attached yet; stash the first result to replay.
            if pendingResult == nil { pendingResult = result }
            lock.unlock()
        }
    }
}

/// Static configuration for the ingest client. The base URL is nil by default,
/// so an unconfigured client refuses to build a request and performs no
/// networking.
public struct IngestClientConfiguration: Sendable, Equatable {
    /// Backend base URL. Nil means "not configured".
    public var baseURL: URL?
    /// Request path appended to the base URL. Empty means "not configured".
    public var path: String
    /// Hostname tag attached to every payload; canonicalized before use.
    public var hostname: String
    /// Header names to emit. Empty names are omitted.
    public var headerNames: RequestHeaderNames
    /// Static metadata headers attached to every request.
    public var staticHeaders: [StaticHeader]
    /// Environment variable names consulted, in order, to resolve a locale.
    public var localeEnvironmentVariables: [String]
    /// Retry policy for transient status and transport failures.
    public var retryPolicy: RetryPolicy
    /// Status codes that mark a response as a lock contention.
    public var lockContentionStatusCodes: Set<Int>
    /// Body fragments that mark a response as a lock contention. Empty means
    /// a matching status code alone is enough.
    public var lockContentionBodyFragments: [String]

    public init(
        baseURL: URL? = nil,
        path: String = "",
        hostname: String = "",
        headerNames: RequestHeaderNames = RequestHeaderNames(),
        staticHeaders: [StaticHeader] = [],
        localeEnvironmentVariables: [String] = [],
        retryPolicy: RetryPolicy = RetryPolicy(),
        lockContentionStatusCodes: Set<Int> = [409],
        lockContentionBodyFragments: [String] = []
    ) {
        self.baseURL = baseURL
        self.path = path
        self.hostname = hostname
        self.headerNames = headerNames
        self.staticHeaders = staticHeaders
        self.localeEnvironmentVariables = localeEnvironmentVariables
        self.retryPolicy = retryPolicy
        self.lockContentionStatusCodes = lockContentionStatusCodes
        self.lockContentionBodyFragments = lockContentionBodyFragments
    }

    /// True when both a base URL and a request path are present.
    public var isConfigured: Bool { baseURL != nil && !path.isEmpty }

    /// True when the response matches the configured lock-contention
    /// markers: a configured status code, plus a configured body fragment
    /// when any are configured. The body is only inspected in-memory.
    public func isLockContention(_ response: HTTPResponse) -> Bool {
        guard lockContentionStatusCodes.contains(response.statusCode) else { return false }
        guard !lockContentionBodyFragments.isEmpty else { return true }
        let body = String(decoding: response.body, as: UTF8.self)
        return lockContentionBodyFragments.contains { body.contains($0) }
    }
}

/// Errors surfaced by the ingest client. None embed credential bytes.
public enum IngestClientError: Error, Equatable, Sendable {
    /// Batch dimensions whose rows carry a per-row natural key.
    public enum NaturalKeyDimension: String, Sendable, Equatable {
        case buckets
        case sessions
        case autonomySessions
    }

    /// No base URL / path was configured, so the client performs no networking.
    case configurationMissing
    /// The configured base URL and path could not be combined into a URL.
    case invalidURL
    /// Authentication failed even after a single forced token refresh.
    case notAuthenticated
    /// A forced refresh returned a token for a different account; the request
    /// was aborted rather than reporting under a mismatched identity.
    case authIdentityChanged
    /// The server returned a non-success, non-401 status.
    case httpFailure(statusCode: Int)
    /// The server reported a configured lock-contention condition after
    /// retries were exhausted. Callers can relieve it by serializing
    /// subsequent requests; the response body is never embedded.
    case lockContention(statusCode: Int)
    /// A transport-level failure: a network error classified as
    /// request-not-written after retries were exhausted, or a failure whose
    /// write state is unknown. Carries no body or token material.
    case transportFailure
    /// The success response could not be decoded into the expected envelope.
    case malformedResponse
    /// Two or more rows in one batch dimension collapsed to the same
    /// normalized natural key. The batch is rejected before any token is
    /// acquired or request built, so the failure has no external effect.
    case duplicateNaturalKey(dimension: NaturalKeyDimension)
}

/// Builds and dispatches usage-ingest requests over an injected transport. The
/// request contract (path, headers, gzip threshold, single refresh, identity
/// fence, one-shot 413 autonomy fallback) is honored, but every
/// environment-specific value is supplied by the caller. An unconfigured
/// client throws configurationMissing and never touches the network.
public struct UsageIngestClient: Sendable {
    /// Body byte count at or above which the request is gzip-compressed.
    public static let gzipMinimumBytes = 1024
    // Field-length caps and natural-key rejection now live in the shared
    // UsageWireNormalizer so the incremental and full-sync paths apply an
    // identical wire contract. These aliases keep the historical names in
    // scope for readers of this type.
    static var sourceMaxBytes: Int { UsageWireNormalizer.sourceMaxBytes }
    static var modelMaxBytes: Int { UsageWireNormalizer.modelMaxBytes }
    static var projectMaxBytes: Int { UsageWireNormalizer.projectMaxBytes }
    static var errorMaxBytes: Int { UsageWireNormalizer.errorMaxBytes }

    private let configuration: IngestClientConfiguration
    private let tokenSupplier: TokenSupplying
    private let sender: HTTPRequestSending
    private let encoder: UsageIngestEncoder
    private let identity: TokenAccountIdentity
    private let environment: [String: String]
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let retrySleeper: RetrySleeper

    public init(
        configuration: IngestClientConfiguration,
        tokenSupplier: TokenSupplying,
        sender: HTTPRequestSending = URLSessionRequestSender(),
        encoder: UsageIngestEncoder = UsageIngestEncoder(),
        identity: TokenAccountIdentity = TokenAccountIdentity(),
        environment: [String: String] = [:],
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        retrySleeper: RetrySleeper = TaskSleepSleeper()
    ) {
        self.configuration = configuration
        self.tokenSupplier = tokenSupplier
        self.sender = sender
        self.encoder = encoder
        self.identity = identity
        self.environment = environment
        self.timeZone = timeZone
        self.now = now
        self.retrySleeper = retrySleeper
    }

    /// Sends a single ingest request. Applies field-length caps, encodes the
    /// body, compresses when large enough, and decodes the server envelope.
    /// A 413 response on a body carrying autonomy fields triggers a single
    /// rebuilt resend with every autonomy field removed. A batch whose rows
    /// collapse to duplicate natural keys within one dimension is rejected
    /// before any token acquisition or network I/O. Throws
    /// configurationMissing (sending nothing) if not configured.
    @discardableResult
    public func ingest(_ request: UsageIngestRequest) async throws -> UsageIngestResponse {
        guard configuration.isConfigured else {
            throw IngestClientError.configurationMissing
        }

        let normalizedRequest = UsageWireNormalizer.normalize(request, hostname: configuration.hostname)
        try UsageWireNormalizer.ensureUniqueNaturalKeys(normalizedRequest)
        let responseBody = try await send(normalizedRequest)
        do {
            return try JSONDecoder().decode(UsageIngestResponse.self, from: responseBody)
        } catch {
            throw IngestClientError.malformedResponse
        }
    }

    // MARK: - Request assembly

    /// Combined endpoint URL. Throws configurationMissing / invalidURL rather
    /// than silently defaulting.
    func endpointURL() throws -> URL {
        guard let baseURL = configuration.baseURL, !configuration.path.isEmpty else {
            throw IngestClientError.configurationMissing
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw IngestClientError.invalidURL
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let suffix = configuration.path.hasPrefix("/") ? configuration.path : "/" + configuration.path
        components.path = base + suffix
        guard let url = components.url else { throw IngestClientError.invalidURL }
        return url
    }

    func makeRequest(body: Data, gzip: Bool, token: SecretToken) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.httpBody = body

        let names = configuration.headerNames
        setHeader(&request, names.contentType, "application/json")
        for header in configuration.staticHeaders where !header.name.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if !names.authToken.isEmpty {
            request.setValue(token.reveal(), forHTTPHeaderField: names.authToken)
        }
        if !names.timeZoneOffset.isEmpty {
            let offset = RequestEnvironment.timeZoneOffset(for: now(), timeZone: timeZone)
            setHeader(&request, names.timeZoneOffset, offset)
        }
        if !names.locale.isEmpty, let locale = RequestEnvironment.locale(environment: environment, variableNames: configuration.localeEnvironmentVariables) {
            setHeader(&request, names.locale, locale)
        }
        if gzip {
            setHeader(&request, names.contentEncoding, "gzip")
        }
        return request
    }

    private func setHeader(_ request: inout URLRequest, _ name: String, _ value: String) {
        guard !name.isEmpty else { return }
        request.setValue(value, forHTTPHeaderField: name)
    }

    // MARK: - Dispatch with single refresh, identity fence, and one-shot 413 fallback

    /// Status code marking a request body as too large. Handled specially
    /// rather than through the generic retry policy: a body still carrying
    /// autonomy fields is rebuilt without them and resent exactly once.
    static let payloadTooLargeStatusCode = 413

    private func send(_ request: UsageIngestRequest) async throws -> Data {
        let policy = configuration.retryPolicy
        var token = try await tokenSupplier.token(forceRefresh: false)
        var didForceRefresh = false
        var retryCount = 0
        var isAutonomyDegraded = false
        var currentRequest = request
        var encoded = encodedBody(currentRequest)

        while true {
            do {
                let response = try await sender.send(makeRequest(body: encoded.body, gzip: encoded.gzipApplied, token: token))
                switch response.statusCode {
                case 200...299:
                    return response.body
                case 401 where !didForceRefresh:
                    // Exactly one forced refresh for the whole call; fence when
                    // the account identity changes.
                    didForceRefresh = true
                    let refreshedToken = try await tokenSupplier.token(forceRefresh: true)
                    guard identity.sameStableAccount(token.reveal(), refreshedToken.reveal()) else {
                        throw IngestClientError.authIdentityChanged
                    }
                    token = refreshedToken
                    // Immediate resend with the refreshed token, without
                    // spending a retry or a backoff.
                    continue
                case 401:
                    // A forced refresh already happened; do not refresh again.
                    throw IngestClientError.notAuthenticated
                case Self.payloadTooLargeStatusCode where !isAutonomyDegraded && currentRequest.containsAutonomyFields:
                    // One-shot size fallback: drop every autonomy field, then
                    // rebuild the JSON, the gzip decision, and the headers,
                    // and resend once with the same token. No backoff, no
                    // refresh, and no retry budget is spent.
                    isAutonomyDegraded = true
                    currentRequest = currentRequest.removingAutonomyFields()
                    encoded = encodedBody(currentRequest)
                    continue
                case Self.payloadTooLargeStatusCode:
                    // Nothing left to strip, or the fallback already fired.
                    // A 413 is terminal: it never falls through to the generic
                    // retry/backoff path.
                    throw IngestClientError.httpFailure(statusCode: response.statusCode)
                default:
                    if policy.isRetryable(response), retryCount < policy.maxRetries {
                        try await sleepBeforeRetry(policy, retryCount: retryCount)
                        retryCount += 1
                        continue
                    }
                    throw terminalFailure(for: response)
                }
            } catch let error as IngestClientError {
                throw error
            } catch HTTPTransportError.requestNotWritten {
                // The request never reached the wire: the only network
                // failure that is safe to retry.
                guard retryCount < policy.maxRetries else {
                    throw IngestClientError.transportFailure
                }
                try await sleepBeforeRetry(policy, retryCount: retryCount)
                retryCount += 1
            } catch {
                // Any other transport error may have been written; never
                // retry blindly.
                throw IngestClientError.transportFailure
            }
        }
    }

    /// Encodes the request and decides whether the wire body is gzipped.
    /// Recomputed on every resend so a degraded (smaller) body is rebuilt
    /// from scratch instead of reusing stale bytes or headers.
    private func encodedBody(_ request: UsageIngestRequest) -> (body: Data, gzipApplied: Bool) {
        let rawBody = encoder.encode(request)
        if rawBody.count >= Self.gzipMinimumBytes, let compressed = GzipCompressor.compress(rawBody) {
            return (compressed, true)
        }
        return (rawBody, false)
    }

    private func sleepBeforeRetry(_ policy: RetryPolicy, retryCount: Int) async throws {
        try await retrySleeper.sleep(seconds: policy.backoff(forRetryIndex: retryCount + 1))
    }

    /// Classifies a terminal (post-retry) response. Lock contention is
    /// reported distinctly so a batch orchestrator can degrade to serial
    /// dispatch; the response body is never embedded in the error.
    private func terminalFailure(for response: HTTPResponse) -> IngestClientError {
        if configuration.isLockContention(response) {
            return .lockContention(statusCode: response.statusCode)
        }
        return .httpFailure(statusCode: response.statusCode)
    }

    // MARK: - Normalization

    /// Truncates to at most n UTF-8 bytes without splitting a multibyte scalar.
    /// Retained as a thin passthrough to the shared normalizer so existing
    /// callers and verifiers keep a stable entry point while the canonical
    /// implementation lives in one place.
    public static func truncate(_ value: String, _ maxBytes: Int) -> String {
        UsageWireNormalizer.truncate(value, maxBytes)
    }
}

private extension UsageIngestRequest {
    /// True when the request carries at least one autonomy field the encoder
    /// would emit. Empty values are omitted on the wire, so they cannot have
    /// contributed to an oversized body.
    var containsAutonomyFields: Bool {
        !autonomySessions.isEmpty
            || !autonomySourceStatuses.isEmpty
            || !autonomyWindowStart.isEmpty
            || !autonomyWindowEnd.isEmpty
    }

    /// The same request with every autonomy field cleared, so the encoder
    /// omits them. Buckets, sessions, and the full-sync flags are untouched.
    func removingAutonomyFields() -> UsageIngestRequest {
        var copy = self
        copy.autonomySessions = []
        copy.autonomySourceStatuses = []
        copy.autonomyWindowStart = ""
        copy.autonomyWindowEnd = ""
        return copy
    }
}
