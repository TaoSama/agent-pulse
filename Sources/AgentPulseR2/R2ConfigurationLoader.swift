import Foundation

public struct EnvironmentR2Configuration: Sendable, Equatable {
    public let configuration: R2Configuration
    public let credentials: R2Credentials

    public init(environment: [String: String]) throws {
        let requiredKeys = [
            "R2_ACCOUNT_ID", "R2_ENDPOINT", "R2_BUCKET", "R2_PUBLIC_BASE_URL",
            "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY",
        ]
        let missing = requiredKeys.filter { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        guard missing.isEmpty else {
            throw R2Error.invalidConfiguration(fields: missing)
        }

        let endpointValue = environment["R2_ENDPOINT"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let endpoint = URL(string: endpointValue),
            endpoint.scheme?.lowercased() == "https",
            endpoint.host != nil,
            endpoint.user == nil,
            endpoint.password == nil,
            endpoint.query == nil,
            endpoint.fragment == nil
        else {
            throw R2Error.invalidConfiguration(fields: ["R2_ENDPOINT"])
        }
        let publicURLValue = environment["R2_PUBLIC_BASE_URL"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let publicBaseURL = URL(string: publicURLValue),
            publicBaseURL.scheme?.lowercased() == "https",
            publicBaseURL.host != nil,
            publicBaseURL.user == nil,
            publicBaseURL.password == nil,
            publicBaseURL.query == nil,
            publicBaseURL.fragment == nil
        else {
            throw R2Error.invalidConfiguration(fields: ["R2_PUBLIC_BASE_URL"])
        }

        let bucket = environment["R2_BUCKET"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidBucket(bucket) else {
            throw R2Error.invalidConfiguration(fields: ["R2_BUCKET"])
        }

        configuration = R2Configuration(
            endpoint: endpoint,
            bucket: bucket,
            publicBaseURL: publicBaseURL,
            region: "auto"
        )
        credentials = R2Credentials(
            accessKeyID: environment["R2_ACCESS_KEY_ID"]!,
            secretAccessKey: environment["R2_SECRET_ACCESS_KEY"]!
        )
    }

    public init(processInfo: ProcessInfo = .processInfo) throws {
        try self.init(environment: processInfo.environment)
    }

    private static func isValidBucket(_ value: String) -> Bool {
        guard
            (3...63).contains(value.count),
            value.first?.isASCII == true,
            value.first?.isLetter == true || value.first?.isNumber == true,
            value.last?.isASCII == true,
            value.last?.isLetter == true || value.last?.isNumber == true
        else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-").contains($0)
        } && !value.contains("..")
    }
}

extension EnvironmentR2Configuration: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "EnvironmentR2Configuration(endpoint: redacted, bucket: redacted, publicBaseURL: redacted, credentials: redacted)"
    }

    public var debugDescription: String { description }
}

public struct StaticCredentialProvider: CredentialProvider {
    private let value: R2Credentials

    public init(_ value: R2Credentials) {
        self.value = value
    }

    public func credentials() async throws -> R2Credentials { value }
}
