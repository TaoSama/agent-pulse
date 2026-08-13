import Foundation

/// Canonicalizes a hostname for reporting: trims surrounding whitespace and
/// caps the result at a fixed number of UTF-8 bytes so an unusually long or
/// padded value cannot bloat the payload. The cap counts UTF-8 bytes and
/// never splits a multibyte scalar.
public enum CanonicalHostname {
    /// Maximum number of UTF-8 bytes retained.
    public static let maximumByteCount = 255

    public static func normalize(_ raw: String, maximumByteCount: Int = CanonicalHostname.maximumByteCount) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return UsageIngestClient.truncate(trimmed, maximumByteCount)
    }
}

/// Names of the request headers the client emits. Every name is caller-supplied
/// and defaults to empty, in which case that header is omitted entirely. This
/// keeps the transport contract free of any hardcoded, environment-specific
/// header vocabulary.
public struct RequestHeaderNames: Sendable, Equatable {
    /// Header carrying the bearer token. Empty means the token is not attached.
    public var authToken: String
    /// Header carrying the local UTC offset. Empty means it is not sent.
    public var timeZoneOffset: String
    /// Header carrying the resolved locale. Empty means it is not sent.
    public var locale: String
    /// Header used to declare a gzip-compressed body.
    public var contentEncoding: String
    /// Header declaring the body content type.
    public var contentType: String

    public init(
        authToken: String = "",
        timeZoneOffset: String = "",
        locale: String = "",
        contentEncoding: String = "Content-Encoding",
        contentType: String = "Content-Type"
    ) {
        self.authToken = authToken
        self.timeZoneOffset = timeZoneOffset
        self.locale = locale
        self.contentEncoding = contentEncoding
        self.contentType = contentType
    }
}

/// A static request header (name/value) attached to every request. Callers use
/// this to supply any client-metadata headers their backend expects without the
/// library hardcoding names or values.
public struct StaticHeader: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Resolves the local UTC offset and an optional locale from the environment.
public enum RequestEnvironment {
    /// Formats the local UTC offset as "+HH:MM" / "-HH:MM".
    public static func timeZoneOffset(for date: Date, timeZone: TimeZone = .current) -> String {
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return sign + twoDigits(magnitude / 3600) + ":" + twoDigits((magnitude % 3600) / 60)
    }

    /// Resolves a locale tag from the given environment variables in order,
    /// returning the first recognized value. Only the zh, en, and ja families
    /// are recognized; anything else yields nil so no locale header is sent.
    public static func locale(environment: [String: String], variableNames: [String]) -> String? {
        for name in variableNames {
            guard let value = environment[name], !value.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let matched = matchLocale(value) { return matched }
        }
        return nil
    }

    static func matchLocale(_ value: String) -> String? {
        let normalized = value.replacingOccurrences(of: "_", with: "-").trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }
        let lower = normalized.lowercased()
        if lower == "zh" || lower.hasPrefix("zh-") { return "zh-CN" }
        if lower == "en" || lower.hasPrefix("en-") { return "en-US" }
        if lower == "ja" || lower == "jp" || lower.hasPrefix("ja-") { return "ja-JP" }
        return nil
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
