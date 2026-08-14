import Foundation
import AgentPulseCore

/// App 层 cliproxyapi 采集服务：从可编辑的 `.env` 配置文件读取 base URL、management key
/// 与目标 apikey，主动拉取 `/v0/management/usage`，本地按目标 apikey 的 SHA256 过滤，
/// 映射为账本可 record 的 `UsageEvent`。
///
/// 安全约定（对齐 `UploadService`）：
/// - 只在内存中解析配置值，绝不打印、写日志或持久化任何 URL / KEY / VALUE。
/// - 仅配置文件「路径」可由 UI/UserDefaults 保存；凭证与目标 key 永不落盘。
/// - 配置文件必须为 0600；否则视为无效并禁用采集（不崩溃）。
/// - 缺配置 / 拉取失败时返回空事件并抛出脱敏错误，绝不影响本地文件采集链路。
public struct CliProxyUsageService: Sendable {
    // MARK: - 常量

    /// 默认配置文件路径：当前用户家目录下的凭证文件（不硬编码用户名）。
    public static let defaultConfigPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials/env/agent-pulse-cliproxy.env")
            .path
    }()

    /// UserDefaults 中保存「配置路径」的键（仅保存路径字符串，绝不保存凭证）。
    public static let configPathDefaultsKey = "com.agentpulse.cliproxy.configPath"

    /// .env 键名（由用户在配置文件中提供实际值）。
    private enum EnvKey {
        static let baseURL = "CLIPROXY_BASE_URL"
        static let managementKey = "CLIPROXY_MANAGEMENT_KEY"
        static let targetAPIKey = "CLIPROXY_TARGET_API_KEY"
    }

    /// management API 用量端点路径（相对 base URL）。
    private static let usagePath = "/v0/management/usage"

    /// 鉴权 header：`Authorization: Bearer <management-key>`（实测该部署接受此形式）。
    private static let authorizationHeader = "Authorization"
    private static let authorizationScheme = "Bearer"

    /// 单个配置文件允许的最大字节数，避免误读超大文件。
    private static let maxConfigFileBytes = 64 * 1024

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
        guard let saved else { return defaultConfigPath }
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultConfigPath : trimmed
    }

    /// 配置文件是否存在且 0600、字段齐全 —— 用于 UI 展示可用性，不读取用量。
    public static func isConfigured(atPath path: String) -> Bool {
        (try? loadConfiguration(atPath: path)) != nil
    }

    // MARK: - 采集

    /// 拉取并解析目标 apikey 的用量事件。
    ///
    /// - Parameter path: 配置文件路径（支持前导 `~` 展开）。
    /// - Returns: 目标 apikey 的 `UsageEvent` 列表（可能为空）。
    /// - Throws: 已脱敏的 ``CliProxyUsageError``。
    public func fetchUsageEvents(atPath path: String) async throws -> [UsageEvent] {
        let configuration = try Self.loadConfiguration(atPath: path)
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

        return CliProxyUsageParser.parse(data: data, targetAPIKey: configuration.targetAPIKey)
    }

    // MARK: - 配置解析

    /// 内存态配置：base URL、management key、目标 apikey。绝不落盘 / 日志。
    struct Configuration {
        let usageURL: URL
        let managementKey: String
        let targetAPIKey: String
    }

    /// 从 0600 的 `.env` 读取并校验配置。
    static func loadConfiguration(atPath path: String) throws -> Configuration {
        let expanded = (path as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { throw CliProxyUsageError.configFileMissing }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CliProxyUsageError.configFileMissing
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: expanded)
        } catch {
            throw CliProxyUsageError.configFileUnreadable
        }
        guard let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o777 == 0o600 else {
            throw CliProxyUsageError.insecurePermissions
        }

        let url = URL(fileURLWithPath: expanded)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw CliProxyUsageError.configFileUnreadable
        }
        guard data.count <= maxConfigFileBytes, let text = String(data: data, encoding: .utf8) else {
            throw CliProxyUsageError.configFileUnreadable
        }

        let environment = parseEnvironment(text)
        let baseURLValue = environment[EnvKey.baseURL]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let managementKey = environment[EnvKey.managementKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetAPIKey = environment[EnvKey.targetAPIKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !baseURLValue.isEmpty, !managementKey.isEmpty, !targetAPIKey.isEmpty else {
            throw CliProxyUsageError.invalidConfiguration
        }
        guard let usageURL = usageURL(base: baseURLValue) else {
            throw CliProxyUsageError.invalidConfiguration
        }
        return Configuration(usageURL: usageURL, managementKey: managementKey, targetAPIKey: targetAPIKey)
    }

    /// 由 base URL 组装 usage 端点 URL；校验传输安全（生产只允许 https，http 仅限 loopback）。
    static func usageURL(base: String) -> URL? {
        guard let base = URL(string: base),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
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

    /// 解析 KEY=VALUE 形式的 `.env` 文本：支持 `#` 注释、空行、可选 `export`、单/双引号包裹值。
    static func parseEnvironment(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        text.enumerateLines { line, _ in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separatorIndex = trimmed.firstIndex(of: "=") else { return }
            let rawKey = String(trimmed[trimmed.startIndex..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty else { return }
            let rawValue = String(trimmed[trimmed.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            result[rawKey] = unquote(rawValue)
        }
        return result
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else { return value }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
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
