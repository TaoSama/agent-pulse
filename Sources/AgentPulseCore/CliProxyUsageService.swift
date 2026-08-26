import Foundation

/// cliproxyapi 采集服务：从统一的合并 `.env` 配置文件读取 base URL、management key
/// 与目标 apikey，主动拉取 `/v0/management/usage`，本地按目标 apikey 的 SHA256 过滤，
/// 映射为账本可 record 的 `UsageEvent`。
///
/// 安全约定（对齐 `UploadService`）：
/// - 只在内存中解析配置值，绝不打印、写日志或持久化任何 URL / KEY / VALUE。
/// - 仅配置文件「路径」可由 UI/UserDefaults 保存；凭证与目标 key 只存在于 0600 env，不另行落盘。
/// - 配置文件必须为 0600 属主专属常规文件（复用 ``EnvFile/load(path:maxBytes:)`` 的 fd 校验）；否则视为无效并禁用采集。
/// - 缺配置 / 拉取失败时返回空事件并抛出脱敏错误，绝不影响本地文件采集链路。
public struct CliProxyUsageService: Sendable {
    // MARK: - 常量

    /// 默认配置文件路径：合并后的统一凭证文件（R2 / cliproxy / 上报简单值共用）。
    public static let defaultConfigPath: String = MergedEnvKeys.defaultPath

    /// UserDefaults 中保存「合并 env 路径」的键（仅保存路径字符串，绝不保存凭证）。
    public static let configPathDefaultsKey = "com.agentpulse.env.mergedPath"

    /// 默认来源的 .env 键名；具名来源由 `CLIPROXY_<SOURCE>_*` 动态发现。
    private enum EnvKey {
        static let baseURL = MergedEnvKeys.cliProxyBaseURL
        static let managementKey = MergedEnvKeys.cliProxyManagementKey
        static let targetAPIKey = MergedEnvKeys.cliProxyTargetAPIKey
    }

    /// management API 用量端点路径（相对 base URL）。
    private static let usagePath = "/v0/management/usage"

    /// 鉴权 header：`Authorization: Bearer <management-key>`（实测该部署接受此形式）。
    private static let authorizationHeader = "Authorization"
    private static let authorizationScheme = "Bearer"

    /// 单个配置文件允许的最大字节数，避免误读超大文件。
    private static let maxConfigFileBytes = EnvFile.defaultMaxBytes

    /// usage 响应最大字节数保护（端点无界，可达数十 MB 且持续增长）。
    private static let maxResponseBytes = 128 * 1024 * 1024

    /// 请求超时（秒）。全量明细可能较大，给足时间但设硬上限。
    private static let requestTimeout: TimeInterval = 60

    // MARK: - 依赖

    private let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        }
    ) {
        self.transport = transport
    }

    // MARK: - 配置路径解析（仅路径可持久化）

    /// 解析实际生效的配置路径：为空/未设置时回退到默认路径。
    public static func resolveConfigPath(saved: String?) -> String {
        MergedEnvKeys.resolvePath(saved: saved)
    }

    /// 配置文件是否存在且 0600、字段齐全 —— 用于 UI 展示可用性，不读取用量。
    public static func isConfigured(atPath path: String) -> Bool {
        ((try? loadConfigurations(atPath: path))?.isEmpty == false)
    }

    /// 当前完整配置的来源数；配置不可读或任一来源三元组残缺时返回 0。
    public static func configuredSourceCount(atPath path: String) -> Int {
        (try? loadConfigurationSet(atPath: path).configurations.count) ?? 0
    }

    // MARK: - 采集

    /// 拉取并解析目标 apikey 的用量事件。
    ///
    /// - Parameter path: 配置文件路径（支持前导 `~` 展开）。
    /// - Returns: 目标 apikey 的 `UsageEvent` 列表（可能为空）。
    /// - Throws: 已脱敏的 ``CliProxyUsageError``。
    public func fetchUsageEvents(atPath path: String) async throws -> [UsageEvent] {
        try await fetchUsage(atPath: path).events
    }

    /// 拉取全部已配置来源。来源级 HTTP / 网络失败相互隔离；只要一个来源成功就返回其数据。
    public func fetchUsage(atPath path: String) async throws -> FetchResult {
        let loaded = try Self.loadConfigurationSet(atPath: path)
        let configurations = loaded.configurations
        var events: [UsageEvent] = []
        var failures = loaded.invalidSourceCount
        var errors = Array(repeating: CliProxyUsageError.invalidConfiguration, count: loaded.invalidSourceCount)
        try await withThrowingTaskGroup(of: SourceResult.self) { group in
            for configuration in configurations {
                group.addTask {
                    do {
                        return .success(try await fetch(configuration))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
                        throw CancellationError()
                    } catch let error as CliProxyUsageError {
                        return .failure(error)
                    } catch {
                        return .failure(.network)
                    }
                }
            }
            for try await result in group {
                switch result {
                case let .success(sourceEvents): events += sourceEvents
                case let .failure(error):
                    failures += 1
                    errors.append(error)
                }
            }
        }
        let sourceCount = configurations.count + loaded.invalidSourceCount
        if failures == sourceCount, let representativeError = errors.sorted(by: {
            $0.reportingPriority > $1.reportingPriority
        }).first {
            throw representativeError
        }
        return FetchResult(
            events: events,
            sourceCount: sourceCount,
            failedSourceCount: failures
        )
    }

    private func fetch(_ configuration: Configuration) async throws -> [UsageEvent] {
        var request = URLRequest(url: configuration.usageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(
            "\(Self.authorizationScheme) \(configuration.managementKey)",
            forHTTPHeaderField: Self.authorizationHeader
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CliProxyUsageError.network
        }

        guard let http = response as? HTTPURLResponse else { throw CliProxyUsageError.network }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403: throw CliProxyUsageError.unauthorized
            default: throw CliProxyUsageError.httpFailure(http.statusCode)
            }
        }
        guard data.count <= Self.maxResponseBytes else { throw CliProxyUsageError.responseTooLarge }

        return CliProxyUsageParser.parse(
            data: data,
            targetAPIKey: configuration.targetAPIKey,
            sourceIdentifier: configuration.sourceIdentifier
        )
    }

    // MARK: - 配置解析

    /// 内存态配置：base URL、management key、目标 apikey。绝不落盘 / 日志。
    struct Configuration {
        /// nil 为历史默认来源；非 nil 为具名来源标识。
        let sourceIdentifier: String?
        let usageURL: URL
        let managementKey: String
        let targetAPIKey: String
    }

    public struct FetchResult: Sendable, Equatable {
        public let events: [UsageEvent]
        public let sourceCount: Int
        public let failedSourceCount: Int
    }

    private enum SourceResult: Sendable {
        case success([UsageEvent])
        case failure(CliProxyUsageError)
    }

    private struct ConfigurationSet {
        let configurations: [Configuration]
        let invalidSourceCount: Int
    }

    /// 从 0600 的合并 `.env` 读取并校验配置。复用 ``EnvFile/load(path:maxBytes:)`` 的 fd 级 0600 校验，
    /// 消除 check-then-read 的 TOCTOU 窗口。
    static func loadConfigurations(atPath path: String) throws -> [Configuration] {
        try loadConfigurationSet(atPath: path).configurations
    }

    private static func loadConfigurationSet(atPath path: String) throws -> ConfigurationSet {
        let environment: [String: String]
        do {
            environment = try EnvFile.load(path: path, maxBytes: maxConfigFileBytes)
        } catch EnvFile.Error.notFound {
            throw CliProxyUsageError.configFileMissing
        } catch EnvFile.Error.insecurePermissions {
            throw CliProxyUsageError.insecurePermissions
        } catch {
            throw CliProxyUsageError.configFileUnreadable
        }

        var configurations: [Configuration] = []
        var invalidSourceCount = 0
        let defaultValues = values(
            environment: environment,
            baseURLKey: EnvKey.baseURL,
            managementKeyKey: EnvKey.managementKey,
            targetAPIKeyKey: EnvKey.targetAPIKey
        )
        if defaultValues.contains(where: { !$0.isEmpty }) {
            if let configuration = configuration(sourceIdentifier: nil, values: defaultValues) {
                configurations.append(configuration)
            } else {
                invalidSourceCount += 1
            }
        }

        let sourceIdentifiers = Set(environment.keys.compactMap(namedSourceIdentifier(for:))).sorted()
        for sourceIdentifier in sourceIdentifiers {
            let prefix = MergedEnvKeys.cliProxyPrefix + sourceIdentifier
            let sourceValues = values(
                environment: environment,
                baseURLKey: prefix + MergedEnvKeys.cliProxyBaseURLSuffix,
                managementKeyKey: prefix + MergedEnvKeys.cliProxyManagementKeySuffix,
                targetAPIKeyKey: prefix + MergedEnvKeys.cliProxyTargetAPIKeySuffix
            )
            if let configuration = configuration(sourceIdentifier: sourceIdentifier, values: sourceValues) {
                configurations.append(configuration)
            } else {
                invalidSourceCount += 1
            }
        }
        guard !configurations.isEmpty else { throw CliProxyUsageError.invalidConfiguration }
        return ConfigurationSet(configurations: configurations, invalidSourceCount: invalidSourceCount)
    }

    private static func values(
        environment: [String: String],
        baseURLKey: String,
        managementKeyKey: String,
        targetAPIKeyKey: String
    ) -> [String] {
        [baseURLKey, managementKeyKey, targetAPIKeyKey].map {
            environment[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private static func configuration(sourceIdentifier: String?, values: [String]) -> Configuration? {
        guard values.count == 3, values.allSatisfy({ !$0.isEmpty }), let usageURL = usageURL(base: values[0]) else {
            return nil
        }
        return Configuration(
            sourceIdentifier: sourceIdentifier,
            usageURL: usageURL,
            managementKey: values[1],
            targetAPIKey: values[2]
        )
    }

    private static func namedSourceIdentifier(for key: String) -> String? {
        guard key.hasPrefix(MergedEnvKeys.cliProxyPrefix) else { return nil }
        let suffixes = [
            MergedEnvKeys.cliProxyBaseURLSuffix,
            MergedEnvKeys.cliProxyManagementKeySuffix,
            MergedEnvKeys.cliProxyTargetAPIKeySuffix,
        ]
        guard let suffix = suffixes.first(where: key.hasSuffix) else { return nil }
        let start = key.index(key.startIndex, offsetBy: MergedEnvKeys.cliProxyPrefix.count)
        let end = key.index(key.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let identifier = String(key[start..<end])
        guard identifier.allSatisfy({ character in
            character.isASCII && (character.isNumber || character == "_" || ("A"..."Z").contains(character))
        }) else { return nil }
        return identifier
    }

    /// 由 base URL 组装 usage 端点 URL；校验传输安全（生产只允许 https，http 仅限 loopback）。
    static func usageURL(base: String) -> URL? {
        guard let base = URL(string: base),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            // 内网 IP 场景：允许 http（该部署为内网地址，无 TLS）。仅拒绝明显不安全的公网 http。
            guard scheme == "http", isPrivateHost(host) else { return nil }
            components.path = usagePath
            return components.url
        }
        components.path = usagePath
        return components.url
    }

    /// 判断是否为私有 / 内网主机（允许内网 http）。
    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 127 { return true }
        return false
    }
}

/// cliproxyapi 采集错误：全部为脱敏文案，绝不包含任何配置值、URL 或凭证。
public enum CliProxyUsageError: Error, Sendable, Equatable {
    case configFileMissing
    case configFileUnreadable
    case insecurePermissions
    case invalidConfiguration
    case unauthorized
    case httpFailure(Int)
    case responseTooLarge
    case network
}

private extension CliProxyUsageError {
    var reportingPriority: Int {
        switch self {
        case .unauthorized: return 4
        case .responseTooLarge: return 3
        case .httpFailure: return 2
        case .network: return 1
        case .invalidConfiguration: return 5
        case .configFileMissing, .configFileUnreadable, .insecurePermissions: return 0
        }
    }
}

extension CliProxyUsageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configFileMissing: return "未找到 cliproxyapi 配置文件，请检查配置路径。"
        case .configFileUnreadable: return "无法读取 cliproxyapi 配置文件，请检查文件权限或格式。"
        case .insecurePermissions: return "cliproxyapi 配置文件权限不安全（需 0600）。"
        case .invalidConfiguration: return "cliproxyapi 配置不完整或地址无效，请检查配置文件内容。"
        case .unauthorized: return "cliproxyapi management key 被拒绝，请检查凭证。"
        case let .httpFailure(code): return "cliproxyapi 用量拉取失败（HTTP \(code)）。"
        case .responseTooLarge: return "cliproxyapi 用量响应过大，已跳过本轮采集。"
        case .network: return "cliproxyapi 网络异常，采集未完成，请检查网络连接。"
        }
    }
}
