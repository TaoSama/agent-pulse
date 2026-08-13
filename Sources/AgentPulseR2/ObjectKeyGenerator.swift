import Foundation

public struct UUIDObjectKeyGenerator: ObjectKeyGenerating {
    private let generateUUID: @Sendable () -> UUID

    public init(generateUUID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.generateUUID = generateUUID
    }

    public func makeKey(prefix: String, date: Date, fileExtension: String) throws -> String {
        let normalizedPrefix = try Self.normalizedPrefix(prefix)
        let normalizedExtension = fileExtension.lowercased()
        guard ["png", "jpg"].contains(normalizedExtension) else { throw R2Error.invalidFileExtension }

        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw R2Error.invalidObjectURL
        }
        return String(
            format: "%@/%04d/%02d/%02d/%@.%@",
            normalizedPrefix, year, month, day,
            generateUUID().uuidString.lowercased(), normalizedExtension
        )
    }

    public static func normalizedPrefix(_ prefix: String) throws -> String {
        let value = prefix
        let segments = value.split(separator: "/", omittingEmptySubsequences: false)
        let invalid = value.isEmpty || prefix.hasPrefix("/") || prefix.hasSuffix("/") || prefix.contains("\\") || segments.contains {
            $0.isEmpty || $0 == "." || $0 == ".." || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        guard !invalid else { throw R2Error.invalidObjectPrefix }
        return value
    }
}

public enum R2URLBuilder {
    public static func uploadURL(configuration: R2Configuration, objectKey: String) throws -> URL {
        try append(pathSegments: [configuration.bucket] + objectPathSegments(objectKey), to: configuration.endpoint)
    }

    public static func publicURL(configuration: R2Configuration, objectKey: String) throws -> URL {
        try append(pathSegments: objectPathSegments(objectKey), to: configuration.publicBaseURL)
    }

    private static func objectPathSegments(_ objectKey: String) throws -> [String] {
        let segments = objectKey.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !segments.isEmpty, segments.allSatisfy({ segment in
            !segment.isEmpty && segment != "." && segment != ".." && !segment.contains("\\")
                && !segment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }) else {
            throw R2Error.invalidObjectURL
        }
        return segments
    }

    static func append(pathSegments: [String], to baseURL: URL) throws -> URL {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil else { throw R2Error.invalidObjectURL }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw R2Error.invalidObjectURL
        }
        let encodedSegments = try pathSegments.map { segment -> String in
            guard !segment.isEmpty, segment != ".", segment != ".." else { throw R2Error.invalidObjectURL }
            return percentEncodePathSegment(segment)
        }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + ([basePath].filter { !$0.isEmpty } + encodedSegments).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let result = components.url else { throw R2Error.invalidObjectURL }
        return result
    }


    private static func percentEncodePathSegment(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var result = ""
        for byte in value.utf8 {
            let isUnreserved =
                (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57) || byte == 45 || byte == 46 || byte == 95 || byte == 126
            if isUnreserved {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append("%")
                result.append(Character(UnicodeScalar(hexadecimal[Int(byte >> 4)])))
                result.append(Character(UnicodeScalar(hexadecimal[Int(byte & 0x0F)])))
            }
        }
        return result
    }
}
