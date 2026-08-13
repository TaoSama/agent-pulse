import CryptoKit
import Foundation

/// Names of the token claims used to derive a stable account identity. All keys
/// are caller-supplied; only the issuer and subject keys have generic defaults.
/// Leave a key empty to skip that claim.
public struct TokenAccountClaimKeys: Sendable, Equatable {
    public var issuer: String
    public var subject: String
    public var tenant: String
    public var username: String
    public var uuid: String

    public init(
        issuer: String = "iss",
        subject: String = "sub",
        tenant: String = "",
        username: String = "",
        uuid: String = ""
    ) {
        self.issuer = issuer
        self.subject = subject
        self.tenant = tenant
        self.username = username
        self.uuid = uuid
    }
}

/// Derives a stable account identity from a bearer token so a forced refresh
/// after an unauthorized response can be fenced: if the refreshed credential
/// belongs to a different account, the request is aborted instead of silently
/// reporting one account's usage under another's session.
///
/// The identity is computed from the token's claims when decodable, falling
/// back to a digest of the whole token. It is a comparison key only and never
/// exposes raw token bytes.
public struct TokenAccountIdentity: Sendable {
    private let claimKeys: TokenAccountClaimKeys

    public init(claimKeys: TokenAccountClaimKeys = TokenAccountClaimKeys()) {
        self.claimKeys = claimKeys
    }

    /// Returns true only when both tokens resolve to the same non-empty stable
    /// account identity.
    public func sameStableAccount(_ previousToken: String, _ refreshedToken: String) -> Bool {
        let previous = comparisonIdentity(previousToken)
        return !previous.isEmpty && previous == comparisonIdentity(refreshedToken)
    }

    /// Computes the comparison identity: claim-derived when available, otherwise
    /// a digest of the raw token.
    public func comparisonIdentity(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let claims = Self.decodeClaims(trimmed), let identity = claimIdentity(claims), !identity.isEmpty {
            return identity
        }
        return "token-sha256:" + Self.digestHex(Data(trimmed.utf8))
    }

    /// Builds the identity from the strongest available claim combination:
    /// issuer+tenant+username, then issuer+subject, then issuer+uuid.
    private func claimIdentity(_ claims: [String: Any]) -> String? {
        let issuer = stringClaim(claims, claimKeys.issuer)
        guard !issuer.isEmpty else { return nil }

        let tenant = stringClaim(claims, claimKeys.tenant)
        let username = stringClaim(claims, claimKeys.username)
        if !tenant.isEmpty && !username.isEmpty {
            return "issuer-tenant-username:" + Self.digestHex(Data((issuer + "\u{0}" + tenant + "\u{0}" + username).utf8))
        }
        let subject = stringClaim(claims, claimKeys.subject)
        if !subject.isEmpty {
            return "issuer-subject:" + Self.digestHex(Data((issuer + "\u{0}" + subject).utf8))
        }
        let uuid = stringClaim(claims, claimKeys.uuid)
        if !uuid.isEmpty {
            return "issuer-uuid:" + Self.digestHex(Data((issuer + "\u{0}" + uuid).utf8))
        }
        return nil
    }

    private func stringClaim(_ claims: [String: Any], _ key: String) -> String {
        guard !key.isEmpty, let value = claims[key] as? String else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes the token's second dot-separated segment (base64url, optional
    /// padding) into a claims dictionary.
    static func decodeClaims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        guard let payload = base64URLDecode(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder != 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }

    /// Lowercase hex SHA-256 digest.
    static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

