import Foundation
import AgentPulseReporting
import AgentPulseUsage

/// 拉取上游 reconcile 的错误分类（脱敏，不含 URL / token / 正文）。
public enum ReconcileFetchError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidPath
    /// reporting.json 的 authToken header 名必须是上游认可的 JWT header，否则打不通。
    case authHeaderNotJWT
    case tokenUnavailable
    case httpFailure(statusCode: Int)
    case transportFailure
    case malformedResponse
}

/// 只读拉取 `GET /api/usage/reconcile`。
///
/// 严格只读：只构造 GET、绝不构造 POST，也不 import 任何 ingest 上报路径。
/// 复用现有 token provider 取 token、复用 reporting.json 的 header 名与静态 header，
/// 保证与真实上报同一鉴权身份。base URL 由调用方从环境变量提供（不落盘）。
public struct ReconcileClient: Sendable {
    /// 上游组内 combinedAuth 仅当此 header 存在才触发 JWT 校验。
    public static let requiredJWTHeaderName = "X-Jwt-Token"

    private let sender: HTTPRequestSending

    public init(sender: HTTPRequestSending = URLSessionRequestSender()) {
        self.sender = sender
    }

    /// 用配置 + base URL + 已取到的 token 构造并发送 GET，解码为 `ReconcileResponse`。
    /// token 只在 header 内使用，绝不进入日志。
    public func fetch(
        configuration: TokenReportingConfiguration,
        baseURL: URL,
        token: SecretToken
    ) async throws -> ReconcileResponse {
        let request = try Self.makeRequest(configuration: configuration, baseURL: baseURL, token: token)
        let response: HTTPResponse
        do {
            response = try await sender.send(request)
        } catch {
            throw ReconcileFetchError.transportFailure
        }
        guard (200...299).contains(response.statusCode) else {
            throw ReconcileFetchError.httpFailure(statusCode: response.statusCode)
        }
        do {
            return try JSONDecoder().decode(ReconcileResponse.self, from: response.body)
        } catch {
            throw ReconcileFetchError.malformedResponse
        }
    }

    /// 构造 GET 请求：路径拼接与 header 装配对齐既有上报请求，但只用 GET、无 body、无
    /// content-type / content-encoding。auth header 名必须是上游认可的 JWT header。
    /// public 以便离线验证直接校验 auth-header 门禁与 URL 拼接。
    public static func makeRequest(
        configuration: TokenReportingConfiguration,
        baseURL: URL,
        token: SecretToken
    ) throws -> URLRequest {
        guard TokenUsageReporter.isValidBaseURL(baseURL) else { throw ReconcileFetchError.invalidBaseURL }
        guard TokenUsageReporter.isValidPath(configuration.path) else { throw ReconcileFetchError.invalidPath }
        let authHeaderName = configuration.headers.authToken
        guard authHeaderName.caseInsensitiveCompare(requiredJWTHeaderName) == .orderedSame else {
            throw ReconcileFetchError.authHeaderNotJWT
        }
        guard !token.isEmpty else { throw ReconcileFetchError.tokenUnavailable }

        var request = URLRequest(url: try endpointURL(baseURL: baseURL, path: configuration.path))
        request.httpMethod = "GET"
        // 只读 GET 到上游 reconcile 只依赖 JWT auth header 打通 combinedAuth；
        // 上报专用的静态 / runtime header 与 content-type / encoding 对 GET 无意义，
        // 故此处只装 auth header，保持与真实上报同一鉴权身份即可。
        request.setValue(token.reveal(), forHTTPHeaderField: authHeaderName)
        return request
    }

    /// base URL + path 拼接，去重斜杠。与 UsageIngestClient.endpointURL 同规则。
    public static func endpointURL(baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ReconcileFetchError.invalidBaseURL
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        let suffix = path.hasPrefix("/") ? path : "/" + path
        components.path = base + suffix
        guard let url = components.url else { throw ReconcileFetchError.invalidBaseURL }
        return url
    }
}
