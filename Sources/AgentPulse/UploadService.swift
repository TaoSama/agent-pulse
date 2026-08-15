import Foundation
import AgentPulseCore
import AgentPulseR2

/// App 层上传服务：负责从统一的合并 `.env` 配置文件读取 R2 凭证/配置，
/// 组装 AgentPulseR2 的上传管线，将剪贴板图片上传到 R2。
///
/// 安全约定：
/// - 只在内存中解析配置值，绝不打印、写日志或持久化任何 KEY/VALUE。
/// - 仅配置文件“路径”可由 UI/UserDefaults 保存；凭证本身永不落盘。
/// - 配置文件必须为 0600 属主专属常规文件（复用 ``EnvFile/load(url:maxBytes:)`` 的 fd 校验）。
/// - 对外暴露的错误消息经过脱敏，只描述失败类别，不含任何配置值。
@MainActor
public final class UploadService: ObservableObject {
    /// 上传状态，便于 SwiftUI 观察并驱动 UI（按钮禁用、气泡展示等）。
    public enum State: Sendable, Equatable {
        case idle
        case uploading
        case success(URL)
        case failure(String)
    }

    // MARK: - 常量

    /// 默认配置文件路径：合并后的统一凭证文件（R2 / cliproxy / 上报简单值共用）。
    public static let defaultConfigPath: String = MergedEnvKeys.defaultPath

    /// UserDefaults 中保存“合并 env 路径”的键（仅保存路径字符串，绝不保存凭证）。
    static let configPathDefaultsKey = MergedEnvPreferences.pathDefaultsKey

    /// 解析实际生效的配置路径：为空/未设置时回退到默认路径，否则原样使用保存值。
    /// - Parameter saved: UserDefaults 中读到的路径（可为空）。
    /// - Returns: 实际应生效的配置路径。
    public static func resolveConfigPath(saved: String?) -> String {
        MergedEnvKeys.resolvePath(saved: saved)
    }

    /// 单个配置文件允许的最大字节数，避免误读超大文件。
    nonisolated private static let maxConfigFileBytes = EnvFile.defaultMaxBytes

    // MARK: - 可观察状态

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isUploading: Bool = false

    // MARK: - 私有依赖

    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let policy: UploadPolicy

    /// 当前进行中的上传任务；用于防重复与取消。
    private var currentTask: Task<UploadReceipt, Error>?

    // MARK: - 初始化

    /// - Parameters:
    ///   - configPath: 初始配置路径；若 UserDefaults 中已保存路径则以保存值优先。
    ///   - defaults: 注入点，便于测试。
    ///   - policy: 上传策略（大小/类型限制）。
    ///   - now: 时间源，便于测试。
    public init(
        configPath: String = UploadService.defaultConfigPath,
        defaults: UserDefaults = .standard,
        policy: UploadPolicy = UploadPolicy(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.policy = policy
        self.now = now
        let saved = defaults.string(forKey: Self.configPathDefaultsKey)
        if let saved, !saved.isEmpty {
            // 使用已保存的路径；为空时回退到默认路径。
            self.storedConfigPath = Self.resolveConfigPath(saved: saved)
        } else {
            self.storedConfigPath = configPath
        }
    }

    // MARK: - 配置路径（仅路径可持久化）

    private var storedConfigPath: String

    /// 可编辑的配置文件路径。设置时会持久化“路径字符串”到 UserDefaults（不含任何凭证）。
    public var configPath: String {
        get { storedConfigPath }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            storedConfigPath = trimmed
            defaults.set(trimmed, forKey: Self.configPathDefaultsKey)
        }
    }

    // MARK: - 上传

    /// 触发一次剪贴板图片上传。
    ///
    /// 防重复：若已有上传进行中，本次调用复用进行中任务的结果。
    /// 可取消：调用 ``cancel()`` 会取消进行中的任务。
    ///
    /// - Returns: 上传回执（含可公开访问的 URL）。
    /// - Throws: 已脱敏的中文错误（``UploadServiceError``），或 ``CancellationError``。
    @discardableResult
    public func uploadClipboardImage() async throws -> UploadReceipt {
        if let existing = currentTask {
            return try await existing.value
        }

        state = .uploading
        isUploading = true

        let path = storedConfigPath
        let policy = self.policy
        let now = self.now

        let task = Task<UploadReceipt, Error> {
            let environment = try Self.loadEnvironment(atPath: path)
            let resolved: EnvironmentR2Configuration
            do {
                resolved = try EnvironmentR2Configuration(environment: environment)
            } catch let error as R2Error {
                throw UploadServiceError.from(error)
            }

            try Task.checkCancellation()

            let uploader = R2Uploader(
                source: PasteboardClipboardImageSource(),
                credentialProvider: StaticCredentialProvider(resolved.credentials),
                keyGenerator: UUIDObjectKeyGenerator(),
                signer: AWSSignatureV4Signer(region: resolved.configuration.region),
                transport: URLSessionHTTPTransport(),
                configuration: resolved.configuration,
                policy: policy,
                now: now
            )

            do {
                return try await uploader.uploadClipboardImage()
            } catch let error as R2Error {
                throw UploadServiceError.from(error)
            }
        }

        currentTask = task
        defer {
            currentTask = nil
            isUploading = false
        }

        do {
            let receipt = try await task.value
            state = .success(receipt.publicURL)
            return receipt
        } catch is CancellationError {
            state = .idle
            throw CancellationError()
        } catch let error as UploadServiceError {
            state = .failure(error.localizedDescription)
            throw error
        } catch {
            // 兜底：任何未分类错误都以脱敏文案对外，绝不泄露底层细节。
            let fallback = UploadServiceError.unknown
            state = .failure(fallback.localizedDescription)
            throw fallback
        }
    }

    /// 取消进行中的上传（若有）。
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isUploading = false
        if case .uploading = state { state = .idle }
    }

    // MARK: - 配置文件解析

    /// 从磁盘安全读取并解析合并 `.env` 文件为环境字典。
    ///
    /// 复用 ``EnvFile/load(path:maxBytes:)``：fd + `O_NOFOLLOW` + fstat 强制 0600 属主常规文件，
    /// 只将值放入内存字典返回，不打印/记录/落盘任何键值。
    ///
    /// - Parameter path: 配置路径，支持前导 ~ 展开。
    nonisolated static func loadEnvironment(atPath path: String) throws -> [String: String] {
        do {
            return try EnvFile.load(path: path, maxBytes: maxConfigFileBytes)
        } catch EnvFile.Error.notFound {
            throw UploadServiceError.configFileMissing
        } catch EnvFile.Error.insecurePermissions {
            throw UploadServiceError.insecurePermissions
        } catch {
            throw UploadServiceError.configFileUnreadable
        }
    }
}

/// App 层上传错误：全部为脱敏中文文案，绝不包含任何配置值或凭证。
public enum UploadServiceError: Error, Sendable, Equatable {
    case configFileMissing
    case configFileUnreadable
    case insecurePermissions
    case invalidConfiguration
    case credentialUnavailable
    case clipboardEmpty
    case unsupportedImage
    case imageTooLarge
    case clockSkew
    case signatureRejected
    case unauthorized
    case forbidden
    case rateLimited
    case serverUnavailable
    case network
    case unknown

    /// 将底层 R2Error 映射为脱敏的 App 层错误（不透传字段细节）。
    static func from(_ error: R2Error) -> UploadServiceError {
        switch error {
        case .clipboardEmpty: return .clipboardEmpty
        case .unsupportedImage: return .unsupportedImage
        case .imageTooLarge: return .imageTooLarge
        case .invalidConfiguration: return .invalidConfiguration
        case .credentialUnavailable: return .credentialUnavailable
        case .invalidObjectPrefix, .invalidFileExtension, .invalidObjectURL: return .invalidConfiguration
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .signatureRejected: return .signatureRejected
        case .clockSkew: return .clockSkew
        case .rateLimited: return .rateLimited
        case .serverUnavailable: return .serverUnavailable
        case .httpFailure: return .unknown
        case .networkFailure: return .network
        @unknown default: return .unknown
        }
    }
}

extension UploadServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configFileMissing: return "未找到配置文件，请检查配置路径。"
        case .configFileUnreadable: return "无法读取配置文件，请检查文件权限或格式。"
        case .insecurePermissions: return "配置文件权限不安全（需 0600）。"
        case .invalidConfiguration: return "配置不完整或格式有误，请检查配置文件内容。"
        case .credentialUnavailable: return "无法获取上传凭证，请检查配置文件。"
        case .clipboardEmpty: return "剪贴板中没有可上传的图片。"
        case .unsupportedImage: return "剪贴板图片格式不受支持。"
        case .imageTooLarge: return "图片体积超出上传限制。"
        case .clockSkew: return "系统时间偏差过大，请校准时间后重试。"
        case .signatureRejected: return "请求签名被拒绝，请检查访问密钥配置。"
        case .unauthorized: return "凭证被拒绝，请检查访问密钥。"
        case .forbidden: return "没有上传权限，请检查存储桶权限。"
        case .rateLimited: return "请求过于频繁，请稍后再试。"
        case .serverUnavailable: return "服务暂时不可用，请稍后再试。"
        case .network: return "网络异常，上传未完成，请检查网络连接。"
        case .unknown: return "上传失败，请稍后重试。"
        }
    }
}
