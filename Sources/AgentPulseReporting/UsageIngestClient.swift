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
private final class ContinuationLatch: @unchecked Sendable {
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
}

/// Builds and dispatches usage-ingest requests over an injected transport. The
/// request contract (path, headers, gzip threshold, single refresh, identity
/// fence) is honored, but every environment-specific value is supplied by the
/// caller. An unconfigured client throws configurationMissing and never touches
/// the network.
public struct UsageIngestClient: Sendable {
    /// Body byte count at or above which the request is gzip-compressed.
    public static let gzipMinimumBytes = 1024
    /// Field-length caps applied before encoding (defense in depth).
    static let sourceMaxBytes = 30
    static let modelMaxBytes = 255
    static let projectMaxBytes = 200
    static let errorMaxBytes = 300

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
    /// Throws configurationMissing (sending nothing) if not configured.
    @discardableResult
    public func ingest(_ request: UsageIngestRequest) async throws -> UsageIngestResponse {
        guard configuration.isConfigured else {
            throw IngestClientError.configurationMissing
        }

        let normalizedRequest = normalized(request)
        let rawBody = encoder.encode(normalizedRequest)
        let responseBody = try await send(rawBody: rawBody)
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

    // MARK: - Dispatch with single refresh + identity fence

    private func send(rawBody: Data) async throws -> Data {
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
        var token = try await tokenSupplier.token(forceRefresh: false)
        var didForceRefresh = false
        var retryCount = 0

        while true {
            do {
                let response = try await sender.send(makeRequest(body: body, gzip: gzipApplied, token: token))
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
                    let retried = try await sender.send(makeRequest(body: body, gzip: gzipApplied, token: token))
                    switch retried.statusCode {
                    case 200...299:
                        return retried.body
                    case 401:
                        throw IngestClientError.notAuthenticated
                    default:
                        if policy.isRetryable(retried), retryCount < policy.maxRetries {
                            try await sleepBeforeRetry(policy, retryCount: retryCount)
                            retryCount += 1
                            continue
                        }
                        throw terminalFailure(for: retried)
                    }
                case 401:
                    // A forced refresh already happened; do not refresh again.
                    throw IngestClientError.notAuthenticated
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

    private func normalized(_ request: UsageIngestRequest) -> UsageIngestRequest {
        let hostname = CanonicalHostname.normalize(configuration.hostname)
        var copy = request
        copy.buckets = request.buckets.map { bucket in
            var b = bucket
            b.hostname = hostname
            b.model = Self.truncate(bucket.model, Self.modelMaxBytes)
            b.source = Self.truncate(bucket.source, Self.sourceMaxBytes)
            b.project = Self.truncate(bucket.project, Self.projectMaxBytes)
            return b
        }
        copy.sessions = request.sessions.map { session in
            var s = session
            s.hostname = hostname
            s.source = Self.truncate(session.source, Self.sourceMaxBytes)
            s.project = Self.truncate(session.project, Self.projectMaxBytes)
            return s
        }
        copy.autonomySessions = request.autonomySessions.map { session in
            var s = session
            s.hostname = hostname
            s.source = Self.truncate(session.source, Self.sourceMaxBytes)
            s.project = Self.truncate(session.project, Self.projectMaxBytes)
            return s
        }
        copy.autonomySourceStatuses = request.autonomySourceStatuses.map { status in
            var s = status
            s.hostname = hostname
            s.source = Self.truncate(status.source, Self.sourceMaxBytes)
            s.error = Self.truncate(status.error, Self.errorMaxBytes)
            return s
        }
        return copy
    }

    /// Truncates to at most n UTF-8 bytes without splitting a multibyte scalar.
    public static func truncate(_ value: String, _ maxBytes: Int) -> String {
        let utf8 = Array(value.utf8)
        guard utf8.count > maxBytes else { return value }
        var end = maxBytes
        while end > 0 && (utf8[end] & 0xC0) == 0x80 { end -= 1 }
        return String(decoding: utf8[0..<end], as: UTF8.self)
    }
}
