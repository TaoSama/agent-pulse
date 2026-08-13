import Foundation
import AgentPulseReporting

/// 本地上报配置。文件由用户自行创建；缺失或字段为空时，普通上报保持禁用。
///
/// 这里不提供任何环境相关默认值：请求路径、header 名、静态 header、取 token
/// 命令和 JSON 路径都必须显式配置。
public struct TokenReportingConfiguration: Codable, Equatable, Sendable {
    public var canonicalHostname: String
    public var path: String
    public var headers: HeaderNames
    public var staticHeaders: [StaticHeaderValue]
    public var tokenCommand: Command
    public var localeEnvironmentVariables: [String]
    public var batch: Batch
    public var retry: Retry

    public init(
        canonicalHostname: String = "",
        path: String = "",
        headers: HeaderNames = HeaderNames(),
        staticHeaders: [StaticHeaderValue] = [],
        tokenCommand: Command = Command(),
        localeEnvironmentVariables: [String] = [],
        batch: Batch = Batch(),
        retry: Retry = Retry()
    ) {
        self.canonicalHostname = canonicalHostname
        self.path = path
        self.headers = headers
        self.staticHeaders = staticHeaders
        self.tokenCommand = tokenCommand
        self.localeEnvironmentVariables = localeEnvironmentVariables
        self.batch = batch
        self.retry = retry
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canonicalHostname = Self.trimmed(try container.decodeIfPresent(String.self, forKey: .canonicalHostname))
        path = Self.trimmed(try container.decodeIfPresent(String.self, forKey: .path))
        headers = try container.decodeIfPresent(HeaderNames.self, forKey: .headers) ?? HeaderNames()
        staticHeaders = try container.decodeIfPresent([StaticHeaderValue].self, forKey: .staticHeaders) ?? []
        tokenCommand = try container.decodeIfPresent(Command.self, forKey: .tokenCommand) ?? Command()
        localeEnvironmentVariables = try container.decodeIfPresent([String].self, forKey: .localeEnvironmentVariables)?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        batch = try container.decodeIfPresent(Batch.self, forKey: .batch) ?? Batch()
        retry = try container.decodeIfPresent(Retry.self, forKey: .retry) ?? Retry()
    }

    /// 路径、取 token 命令和必要 header 都配置后，才具备发起普通上报的条件。
    public var isReady: Bool {
        !canonicalHostname.isEmpty
            && !path.isEmpty
            && tokenCommand.isConfigured
            && !headers.authToken.isEmpty
            && !headers.contentEncoding.isEmpty
            && !headers.contentType.isEmpty
            && batch.isValid
            && retry.isValid
    }

    public func ingestConfiguration(baseURL: URL, hostname: String) -> IngestClientConfiguration {
        IngestClientConfiguration(
            baseURL: baseURL,
            path: path,
            hostname: hostname,
            headerNames: headers.requestHeaderNames,
            staticHeaders: staticHeaders.compactMap { header in
                guard !header.name.isEmpty else { return nil }
                return StaticHeader(name: header.name, value: header.value)
            },
            localeEnvironmentVariables: localeEnvironmentVariables,
            retryPolicy: retry.transportPolicy,
            lockContentionStatusCodes: Set(retry.lockContentionStatusCodes),
            lockContentionBodyFragments: retry.lockContentionBodyFragments
        )
    }

    public struct Batch: Codable, Equatable, Sendable {
        public var maxBucketsPerBatch: Int
        public var maxSessionsPerBatch: Int
        public var maxConcurrentBatches: Int

        public init(
            maxBucketsPerBatch: Int = 500,
            maxSessionsPerBatch: Int = 1_000,
            maxConcurrentBatches: Int = 2
        ) {
            self.maxBucketsPerBatch = maxBucketsPerBatch
            self.maxSessionsPerBatch = maxSessionsPerBatch
            self.maxConcurrentBatches = maxConcurrentBatches
        }

        public var isValid: Bool {
            (1...UsageBatchConfiguration.maximumConfigurableBatchSize).contains(maxBucketsPerBatch)
                && (1...UsageBatchConfiguration.maximumConfigurableBatchSize).contains(maxSessionsPerBatch)
                && maxConcurrentBatches > 0
        }

        public var transportConfiguration: UsageBatchConfiguration {
            UsageBatchConfiguration(
                maxBucketsPerBatch: maxBucketsPerBatch,
                maxSessionsPerBatch: maxSessionsPerBatch,
                maxConcurrentBatches: maxConcurrentBatches
            )
        }
    }

    public struct Retry: Codable, Equatable, Sendable {
        public var maxRetries: Int
        public var retryableStatusCodes: [Int]
        public var retryableStatusBodyRules: [StatusBodyRule]
        public var backoffSeconds: [Double]
        public var lockContentionStatusCodes: [Int]
        public var lockContentionBodyFragments: [String]

        public init(
            maxRetries: Int = 3,
            retryableStatusCodes: [Int] = [502, 503, 504],
            retryableStatusBodyRules: [StatusBodyRule] = [],
            backoffSeconds: [Double] = [2, 5, 11],
            lockContentionStatusCodes: [Int] = [409],
            lockContentionBodyFragments: [String] = []
        ) {
            self.maxRetries = maxRetries
            self.retryableStatusCodes = retryableStatusCodes
            self.retryableStatusBodyRules = retryableStatusBodyRules
            self.backoffSeconds = backoffSeconds
            self.lockContentionStatusCodes = lockContentionStatusCodes
            self.lockContentionBodyFragments = lockContentionBodyFragments
        }

        public var isValid: Bool {
            let statusCodes = retryableStatusBodyRules.map(\.statusCode)
            return maxRetries >= 0
                && retryableStatusCodes.allSatisfy(Self.isValidStatusCode)
                && retryableStatusBodyRules.allSatisfy(\.isValid)
                && Set(statusCodes).count == statusCodes.count
                && backoffSeconds.allSatisfy { $0.isFinite && $0 >= 0 }
                && lockContentionStatusCodes.allSatisfy(Self.isValidStatusCode)
        }

        public var transportPolicy: RetryPolicy {
            RetryPolicy(
                maxRetries: maxRetries,
                retryableStatusCodes: Set(retryableStatusCodes),
                retryableStatusBodyFragments: Dictionary(
                    uniqueKeysWithValues: retryableStatusBodyRules.map { ($0.statusCode, $0.fragments) }
                ),
                backoffSeconds: backoffSeconds
            )
        }

        private static func isValidStatusCode(_ value: Int) -> Bool {
            (100...599).contains(value)
        }

        public struct StatusBodyRule: Codable, Equatable, Sendable {
            public var statusCode: Int
            public var fragments: [String]

            public init(statusCode: Int = 500, fragments: [String] = []) {
                self.statusCode = statusCode
                self.fragments = fragments
            }

            public var isValid: Bool {
                Retry.isValidStatusCode(statusCode)
                    && !fragments.isEmpty
                    && fragments.allSatisfy { !$0.isEmpty }
            }
        }
    }

    static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public struct HeaderNames: Codable, Equatable, Sendable {
        public var authToken: String
        public var timeZoneOffset: String
        public var locale: String
        public var contentEncoding: String
        public var contentType: String

        public init(
            authToken: String = "",
            timeZoneOffset: String = "",
            locale: String = "",
            contentEncoding: String = "",
            contentType: String = ""
        ) {
            self.authToken = authToken
            self.timeZoneOffset = timeZoneOffset
            self.locale = locale
            self.contentEncoding = contentEncoding
            self.contentType = contentType
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            authToken = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .authToken))
            timeZoneOffset = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .timeZoneOffset))
            locale = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .locale))
            contentEncoding = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .contentEncoding))
            contentType = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .contentType))
        }

        var requestHeaderNames: RequestHeaderNames {
            RequestHeaderNames(
                authToken: authToken,
                timeZoneOffset: timeZoneOffset,
                locale: locale,
                contentEncoding: contentEncoding,
                contentType: contentType
            )
        }
    }

    public struct StaticHeaderValue: Codable, Equatable, Sendable {
        public var name: String
        public var value: String

        public init(name: String = "", value: String = "") {
            self.name = name
            self.value = value
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .name))
            value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        }
    }

    public struct Command: Codable, Equatable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var forceRefreshArguments: [String]
        public var statusKey: String
        public var successStatus: String
        public var errorKey: String
        public var tokenKeyPath: [String]

        public init(
            executable: String = "",
            arguments: [String] = [],
            forceRefreshArguments: [String] = [],
            statusKey: String = "",
            successStatus: String = "",
            errorKey: String = "",
            tokenKeyPath: [String] = []
        ) {
            self.executable = executable
            self.arguments = arguments
            self.forceRefreshArguments = forceRefreshArguments
            self.statusKey = statusKey
            self.successStatus = successStatus
            self.errorKey = errorKey
            self.tokenKeyPath = tokenKeyPath
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            executable = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .executable))
            arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            forceRefreshArguments = try container.decodeIfPresent([String].self, forKey: .forceRefreshArguments) ?? []
            statusKey = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .statusKey))
            successStatus = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .successStatus))
            errorKey = TokenReportingConfiguration.trimmed(try container.decodeIfPresent(String.self, forKey: .errorKey))
            tokenKeyPath = try container.decodeIfPresent([String].self, forKey: .tokenKeyPath)?
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty } ?? []
        }

        public var isConfigured: Bool {
            !executable.isEmpty && !tokenKeyPath.isEmpty
        }

        public var providerConfiguration: CommandTokenProviderConfiguration {
            CommandTokenProviderConfiguration(
                executable: executable,
                arguments: arguments,
                forceRefreshArguments: forceRefreshArguments,
                statusKey: statusKey,
                successStatus: successStatus,
                errorKey: errorKey,
                tokenKeyPath: tokenKeyPath
            )
        }
    }
}
