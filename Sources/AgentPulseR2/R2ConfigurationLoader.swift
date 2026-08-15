import Foundation

public struct EnvironmentR2Configuration: Sendable, Equatable {
    public let configuration: R2Configuration
    public let credentials: R2Credentials

    /// R2 S3 兼容端点的固定模板：`https://<account-id>.r2.cloudflarestorage.com`。
    /// endpoint 不再单独配置，由 account id 拼出，避免与 account id 不一致或被手填错。
    private static let endpointHostSuffix = ".r2.cloudflarestorage.com"

    public init(environment: [String: String]) throws {
        let requiredKeys = [
            "R2_ACCOUNT_ID", "R2_BUCKET", "R2_PUBLIC_BASE_URL",
            "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY",
        ]
        let missing = requiredKeys.filter { environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        guard missing.isEmpty else {
            throw R2Error.invalidConfiguration(fields: missing)
        }

        // endpoint 由 account id 拼出固定模板；account id 限定为不含点/斜杠等 host 边界字符的
        // 安全字符集，避免拼进 host 后越界或注入。
        let accountID = environment["R2_ACCOUNT_ID"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            Self.isValidAccountID(accountID),
            let endpoint = URL(string: "https://\(accountID)\(Self.endpointHostSuffix)"),
            endpoint.host != nil
        else {
            throw R2Error.invalidConfiguration(fields: ["R2_ACCOUNT_ID"])
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

    /// account id 只允许字母数字，长度 1...64；不含点、斜杠、@、冒号等能破坏 host 边界或注入的字符。
    /// 拼进 `https://<id>.r2.cloudflarestorage.com` 后保证 id 是单一 host 标签。
    private static func isValidAccountID(_ value: String) -> Bool {
        guard (1...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains($0)
        }
    }

    private static func isValidBucket(_ value: String) -> Bool {        guard
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
