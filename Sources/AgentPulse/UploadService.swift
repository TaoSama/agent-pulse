import Foundation
import AgentPulseR2

/// Uploads clipboard images using the active 1Password configuration.
@MainActor
public final class UploadService: ObservableObject {
    /// 上传状态，便于 SwiftUI 观察并驱动 UI（按钮禁用、气泡展示等）。
    public enum State: Sendable, Equatable {
        case idle
        case uploading
        case success(URL)
        case failure(String)
    }

    // MARK: - 可观察状态

    @Published public private(set) var state: State = .idle
    @Published public private(set) var isUploading: Bool = false

    // MARK: - 私有依赖

    private let configuration: @MainActor () -> EnvironmentR2Configuration?
    private let now: @Sendable () -> Date
    private let policy: UploadPolicy

    /// 当前进行中的上传任务；用于防重复与取消。
    private var currentTask: Task<UploadReceipt, Error>?

    public init(
        policy: UploadPolicy = UploadPolicy(),
        now: @escaping @Sendable () -> Date = Date.init,
        configuration: @escaping @MainActor () -> EnvironmentR2Configuration?
    ) {
        self.configuration = configuration
        self.policy = policy
        self.now = now
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

        let configuration = self.configuration
        let policy = self.policy
        let now = self.now

        let task = Task<UploadReceipt, Error> {
            guard let resolved = configuration() else { throw UploadServiceError.credentialUnavailable }

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


}

/// App 层上传错误：全部为脱敏中文文案，绝不包含任何配置值或凭证。
public enum UploadServiceError: Error, Sendable, Equatable {
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
        case .invalidConfiguration: return "R2 配置格式有误，请检查 1Password 中的 Agent Pulse 条目。"
        case .credentialUnavailable: return "R2 上传凭证缺失，请检查 1Password 中的 Agent Pulse 条目。"
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
