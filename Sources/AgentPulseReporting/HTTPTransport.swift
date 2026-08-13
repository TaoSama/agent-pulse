import Foundation

/// Category of a transport-level failure. The sender is expected to classify
/// connectivity errors before they reach the client, because a blind retry of
/// a request that may already have been written can duplicate an effect.
public enum HTTPTransportError: Error, Equatable, Sendable {
    /// The request never reached the wire (for example, name resolution or
    /// connection establishment failed). Replaying it is safe.
    case requestNotWritten
    /// The request may already have been written; the outcome is unknown and
    /// the request must not be replayed without an idempotency guarantee.
    case requestOutcomeUnknown
}

/// The outcome of an HTTP round-trip: the status code plus the raw response
/// body. The body is retained on purpose so the client can apply configured
/// response classifications (retry fragments, lock-contention markers) without
/// a second round-trip; it is never embedded in errors or logs. Kept
/// intentionally small so tests can build responses without a live server.
public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let body: Data

    public init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }
}

/// Abstraction over "send this request and give me the response" so the ingest
/// client can be exercised without real networking. Implementations receive the
/// fully-formed request (URL, method, headers, body already set).
public protocol HTTPRequestSending: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// Default HTTPRequestSending backed by URLSession.
public struct URLSessionRequestSender: HTTPRequestSending {
    /// URLSession error codes that prove the request was not written, so a
    /// retry cannot duplicate a server-side effect.
    static let requestNotWrittenCodes: Set<URLError.Code> = [
        .cannotFindHost,
        .cannotConnectToHost,
        .notConnectedToInternet,
        .dnsLookupFailed,
    ]

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw IngestClientError.malformedResponse
            }
            return HTTPResponse(statusCode: http.statusCode, body: data)
        } catch let error as HTTPTransportError {
            throw error
        } catch let error as IngestClientError {
            throw error
        } catch let error as URLError {
            if Self.requestNotWrittenCodes.contains(error.code) {
                throw HTTPTransportError.requestNotWritten
            }
            throw HTTPTransportError.requestOutcomeUnknown
        } catch {
            throw HTTPTransportError.requestOutcomeUnknown
        }
    }
}
