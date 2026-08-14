import CryptoKit
import Foundation

/// Normalizes an HTTP(S) origin (scheme + host + port) so it can be one stable
/// half of the account-namespace key. Scheme and host are lowercased, the
/// default port for the scheme is dropped, and any path/query/user info is
/// discarded. An input that is not an absolute http/https URL with a host
/// yields nil, which the caller must treat as unverifiable and fail closed.
public enum RequestOrigin {
    public static func normalize(_ url: URL) -> String? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let portSuffix: String
        if let port = components.port, port != defaultPort {
            portSuffix = ":\(port)"
        } else {
            portSuffix = ""
        }
        components.percentEncodedUser = nil
        components.percentEncodedPassword = nil
        return scheme + "://" + host + portSuffix
    }
}

/// The dedicated errors the identity resolver surfaces. They never embed a
/// token or a raw response body; only a status code and a category leak out.
public enum IdentityResolutionError: Error, Equatable, Sendable {
    /// The identity endpoint is not fully configured (no path, no id key, or an
    /// unresolvable origin), so no request is attempted.
    case notConfigured
    /// The endpoint answered 401. The caller decides whether a single forced
    /// refresh is still available; a second 401 stays unauthenticated.
    case notAuthenticated
    /// The response could not be parsed into a positive integer user id under
    /// the configured key, so the identity is unverifiable and fails closed.
    case malformedResponse
    /// A non-success, non-401 status the resolver will not interpret.
    case httpFailure(statusCode: Int)
    /// The transport failed in a way that is not safe to interpret as a
    /// verified identity.
    case transportFailure
}

/// HTTP verb the identity endpoint is queried with. Both carry the same auth
/// and metadata headers; POST additionally sends an empty JSON object body so a
/// server that only accepts POST still receives a well-formed request.
public enum IdentityRequestMethod: String, Sendable, Equatable {
    case get = "GET"
    case post = "POST"
}

/// Fully caller-supplied configuration for the identity endpoint. Every value
/// is injected from local configuration; nothing environment-specific is baked
/// in. Header names and static headers are shared with the main request so the
/// endpoint reuses the same auth and metadata contract.
public struct IdentityEndpointConfiguration: Sendable, Equatable {
    /// Request path appended to the base URL.
    public var path: String
    /// HTTP method used to query the endpoint.
    public var method: IdentityRequestMethod
    /// Ordered JSON keys that locate the user id in the response object. A
    /// single key reads a top-level field; multiple keys descend nested
    /// objects. Empty means the endpoint is not configured.
    public var responseIDKeyPath: [String]
    /// Exact HTTP status codes accepted as a successful identity answer.
    public var successStatusCodes: Set<Int>
    /// Header names shared with the main request (auth token, metadata).
    public var headerNames: RequestHeaderNames
    /// Static metadata headers attached to the identity request.
    public var staticHeaders: [StaticHeader]

    public init(
        path: String = "",
        method: IdentityRequestMethod = .get,
        responseIDKeyPath: [String] = [],
        successStatusCodes: Set<Int> = [200],
        headerNames: RequestHeaderNames = RequestHeaderNames(),
        staticHeaders: [StaticHeader] = []
    ) {
        self.path = path
        self.method = method
        self.responseIDKeyPath = responseIDKeyPath
        self.successStatusCodes = successStatusCodes
        self.headerNames = headerNames
        self.staticHeaders = staticHeaders
    }

    public var isConfigured: Bool {
        !path.isEmpty && !responseIDKeyPath.isEmpty && !successStatusCodes.isEmpty
    }
}

/// Resolves a stable, comparable account namespace by asking a configured,
/// authenticated identity endpoint for the current user id, then deriving
/// SHA-256 over the normalized origin, a NUL separator, and the positive
/// integer user id. The namespace never contains the raw user id, the origin
/// bytes verbatim beyond the hash, or any token material, and it is versioned
/// so a future derivation change is detectable.
///
/// This replaces any identity derived from JWT claims or a whole-token digest
/// for the full-sync path: identity is proven by a live authenticated lookup,
/// not by trusting opaque token bytes.
public struct OriginUserIdentityResolver: Sendable {
    /// Namespace derivation version tag. Bump only when the derivation changes.
    public static let namespaceVersion = "user-origin-v1"

    private let baseURL: URL
    private let configuration: IdentityEndpointConfiguration
    private let sender: HTTPRequestSending

    public init(baseURL: URL, configuration: IdentityEndpointConfiguration, sender: HTTPRequestSending) {
        self.baseURL = baseURL
        self.configuration = configuration
        self.sender = sender
    }

    /// Queries the endpoint with the given token and returns the derived
    /// namespace. Throws IdentityResolutionError on any failure so the caller
    /// fails closed rather than continuing under an unverifiable identity.
    public func resolveNamespace(token: SecretToken) async throws -> String {
        guard configuration.isConfigured, let origin = RequestOrigin.normalize(baseURL) else {
            throw IdentityResolutionError.notConfigured
        }
        let request = try makeRequest(token: token)
        let response: HTTPResponse
        do {
            response = try await sender.send(request)
        } catch let error as IdentityResolutionError {
            throw error
        } catch {
            throw IdentityResolutionError.transportFailure
        }
        if configuration.successStatusCodes.contains(response.statusCode) {
            let userID = try Self.positiveUserID(from: response.body, keyPath: configuration.responseIDKeyPath)
            return Self.namespace(origin: origin, userID: userID)
        }
        if response.statusCode == 401 {
            throw IdentityResolutionError.notAuthenticated
        }
        throw IdentityResolutionError.httpFailure(statusCode: response.statusCode)
    }

    /// Derives the versioned namespace: version tag + SHA-256(origin + NUL +
    /// decimal user id). Exposed for deterministic verification.
    public static func namespace(origin: String, userID: Int64) -> String {
        var material = Data(origin.utf8)
        material.append(0x00)
        material.append(Data(String(userID).utf8))
        let digest = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        return namespaceVersion + ":" + digest
    }

    /// Extracts a strictly positive integer user id from the JSON response at
    /// the configured key path. A missing key, wrong type, non-integral number,
   /// numeric-string overflow, or a value <= 0 is rejected as malformed.
    public static func positiveUserID(from body: Data, keyPath: [String]) throws -> Int64 {
        guard !keyPath.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: body) else {
            throw IdentityResolutionError.malformedResponse
        }
        var current: Any? = root
        for key in keyPath {
            guard let object = current as? [String: Any], let next = object[key] else {
                throw IdentityResolutionError.malformedResponse
            }
            current = next
        }
        guard let value = current, let userID = Self.integerValue(value), userID > 0 else {
            throw IdentityResolutionError.malformedResponse
        }
        return userID
    }

    /// Accepts a JSON integer (never a fractional or boolean number) or a
    /// decimal string of digits. Rejects Bool, fractional numbers, and any
    /// non-decimal representation so only an exact positive integer id passes.
    private static func integerValue(_ value: Any) -> Int64? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let doubleValue = number.doubleValue
            guard doubleValue.rounded() == doubleValue,
                  doubleValue >= Double(Int64.min), doubleValue <= Double(Int64.max) else { return nil }
            return number.int64Value
        }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }) else { return nil }
            return Int64(trimmed)
        }
        return nil
    }

    private func makeRequest(token: SecretToken) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw IdentityResolutionError.notConfigured
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let suffix = configuration.path.hasPrefix("/") ? configuration.path : "/" + configuration.path
        components.path = base + suffix
        guard let url = components.url else { throw IdentityResolutionError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = configuration.method.rawValue
        let names = configuration.headerNames
        if !names.authToken.isEmpty { request.setValue(token.reveal(), forHTTPHeaderField: names.authToken) }
        for header in configuration.staticHeaders where !header.name.isEmpty {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        if configuration.method == .post {
            if !names.contentType.isEmpty { request.setValue("application/json", forHTTPHeaderField: names.contentType) }
            request.httpBody = Data("{}".utf8)
        }
        return request
    }
}
