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

    /// The non-empty header names this client sets itself (auth, timezone,
    /// locale, content-encoding, content-type). Runtime/static headers are
    /// forbidden from targeting any of these so a template can never overwrite
    /// a client-controlled header. Comparison is case-insensitive because HTTP
    /// header field names are case-insensitive.
    public var reservedNames: Set<String> {
        Set([authToken, timeZoneOffset, locale, contentEncoding, contentType]
            .filter { !$0.isEmpty }
            .map { $0.lowercased() })
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

// MARK: - Runtime header templates

/// The error thrown when a header template cannot be resolved cleanly.
/// Callers must treat this as a configuration error, not a soft warning.
public enum HeaderTemplateError: Error, Equatable, Sendable {
    /// The template references a variable key that was not supplied.
    case unknownVariable(String)
    /// A placeholder was opened with {{ but never closed.
    case unclosedPlaceholder
    /// The resolved value contains a CR or LF character that would break
    /// HTTP header framing.
    case newlineInValue(String)
    /// The header name is empty or contains characters forbidden by
    /// RFC 7230 (control chars, separators, colon, CRLF).
    case invalidHeaderName(String)
    /// The header name targets a client-controlled header (auth, timezone,
    /// locale, content-encoding, content-type) and would overwrite it.
    case protectedHeaderName(String)
}

/// Predefined variable keys the library recognises in header templates.
/// Any key not in this set is rejected at resolve-time.
public enum HeaderTemplateKey: String, Sendable, CaseIterable {
    case platform
    case appVersion = "app_version"
    case userAgent = "user_agent"
    case appID = "app_id"
}

/// A resolved set of runtime variable values used to expand header templates.
/// Callers supply only the variables they know.
public struct RuntimeHeaderContext: Sendable, Equatable {
    private let values: [String: String]

    public init(_ values: [HeaderTemplateKey: String] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) })
    }

    /// Resolves {{key}} placeholders in template.
    /// Throws HeaderTemplateError on any failure — fail-closed.
    public func resolve(template: String) throws -> String {
        var result = ""
        var remaining = template[...]
        while let open = remaining.range(of: "{{") {
            result += remaining[..<open.lowerBound]
            remaining = remaining[open.upperBound...]
            guard let close = remaining.range(of: "}}") else {
                throw HeaderTemplateError.unclosedPlaceholder
            }
            let key = String(remaining[..<close.lowerBound])
            remaining = remaining[close.upperBound...]
            guard let value = values[key] else {
                throw HeaderTemplateError.unknownVariable(key)
            }
            guard !StaticHeader.containsLineBreak(value) else {
                throw HeaderTemplateError.newlineInValue(key)
            }
            result += value
        }
        result += remaining
        return result
    }
}

extension StaticHeader {
    /// Swift treats a CRLF pair as one extended grapheme cluster, so
    /// `String.contains("\r")` and `contains("\n")` can both return false.
    /// Inspect Unicode scalar values directly for HTTP framing characters.
    public static func containsLineBreak(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value == 0x0A || scalar.value == 0x0D
        }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            guard v >= 0x21, v != 0x7F else { return false }
            switch v {
            case 0x22, 0x28...0x29, 0x2C, 0x2F, 0x3A...0x40, 0x5B...0x5D, 0x7B, 0x7D:
                return false
            default:
                return true
            }
        }
    }

    public static func resolved(
        name: String,
        template: String,
        context: RuntimeHeaderContext
    ) throws -> StaticHeader {
        guard isValidName(name) else { throw HeaderTemplateError.invalidHeaderName(name) }
        let value = try context.resolve(template: template)
        guard !containsLineBreak(value) else {
            throw HeaderTemplateError.newlineInValue(name)
        }
        return StaticHeader(name: name, value: value)
    }

    /// Resolves an ordered list of (name, template) pairs into concrete
    /// headers, fail-closed. Any invalid name, unknown variable, unclosed
    /// placeholder, CR/LF in the resolved value, or a name that collides
    /// (case-insensitively) with a client-controlled header in `reservedNames`
    /// aborts the whole batch by throwing. There is no partial result.
    public static func resolvedList(
        _ templates: [(name: String, template: String)],
        context: RuntimeHeaderContext,
        reservedNames: Set<String>
    ) throws -> [StaticHeader] {
        try templates.map { entry in
            guard !reservedNames.contains(entry.name.lowercased()) else {
                throw HeaderTemplateError.protectedHeaderName(entry.name)
            }
            return try resolved(name: entry.name, template: entry.template, context: context)
        }
    }
}
