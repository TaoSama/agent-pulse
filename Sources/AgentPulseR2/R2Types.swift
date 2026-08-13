import Foundation

public struct UploadPolicy: Sendable, Equatable {
    public let objectPrefix: String
    public let maxBytes: Int
    public let maxAttempts: Int
    public let allowedContentTypes: Set<String>

    public init(
        objectPrefix: String = "clipboard/v1",
        maxBytes: Int = 10 * 1_024 * 1_024,
        maxAttempts: Int = 1,
        allowedContentTypes: Set<String> = ["image/png", "image/jpeg"]
    ) {
        self.objectPrefix = objectPrefix
        self.maxBytes = maxBytes
        self.maxAttempts = maxAttempts
        self.allowedContentTypes = allowedContentTypes
    }
}

public struct EncodedImage: Sendable, Equatable {
    public let data: Data
    public let contentType: String
    public let fileExtension: String

    public init(data: Data, contentType: String, fileExtension: String) {
        self.data = data
        self.contentType = contentType
        self.fileExtension = fileExtension
    }
}

public struct R2Configuration: Sendable, Equatable {
    public let endpoint: URL
    public let bucket: String
    public let publicBaseURL: URL
    public let region: String

    public init(endpoint: URL, bucket: String, publicBaseURL: URL, region: String = "auto") {
        self.endpoint = endpoint
        self.bucket = bucket
        self.publicBaseURL = publicBaseURL
        self.region = region
    }
}

public struct R2Credentials: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

extension R2Credentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "R2Credentials(redacted)" }
    public var debugDescription: String { description }
}

public struct UploadReceipt: Sendable, Equatable {
    public let objectKey: String
    public let publicURL: URL
    public let eTag: String?
    public let byteCount: Int

    public init(objectKey: String, publicURL: URL, eTag: String?, byteCount: Int) {
        self.objectKey = objectKey
        self.publicURL = publicURL
        self.eTag = eTag
        self.byteCount = byteCount
    }
}

public enum R2Error: Error, Sendable, Equatable {
    case clipboardEmpty
    case unsupportedImage
    case imageTooLarge(maxBytes: Int)
    case invalidConfiguration(fields: [String])
    case credentialUnavailable
    case invalidObjectPrefix
    case invalidFileExtension
    case invalidObjectURL
    case unauthorized
    case forbidden
    case signatureRejected
    case clockSkew
    case rateLimited(retryAfterSeconds: Int?)
    case serverUnavailable(statusCode: Int)
    case httpFailure(statusCode: Int, requestID: String?)
    case networkFailure
}

extension R2Error: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .clipboardEmpty: "Clipboard does not contain an image."
        case .unsupportedImage: "Clipboard image cannot be encoded as PNG or JPEG."
        case let .imageTooLarge(maxBytes): "Encoded image exceeds the configured limit of \(maxBytes) bytes."
        case let .invalidConfiguration(fields): "R2 configuration is invalid for: \(fields.sorted().joined(separator: ", "))."
        case .credentialUnavailable: "R2 credentials are unavailable."
        case .invalidObjectPrefix: "The object prefix is invalid."
        case .invalidFileExtension: "The image file extension is invalid."
        case .invalidObjectURL: "The object URL could not be constructed safely."
        case .unauthorized: "R2 rejected the credentials."
        case .forbidden: "R2 denied permission to upload the object."
        case .signatureRejected: "R2 rejected the request signature; verify the access key configuration."
        case .clockSkew: "The request time is too far from the server clock; adjust the system time and retry."
        case let .rateLimited(retryAfter):
            retryAfter.map { "R2 rate limited the upload; retry after \($0) seconds." }
                ?? "R2 rate limited the upload."
        case let .serverUnavailable(statusCode): "R2 is temporarily unavailable (HTTP \(statusCode))."
        case let .httpFailure(statusCode, requestID):
            requestID.map { "R2 upload failed (HTTP \(statusCode), request ID \($0))." }
                ?? "R2 upload failed (HTTP \(statusCode))."
        case .networkFailure: "The R2 upload could not be completed because of a network error."
        }
    }
}

public protocol ClipboardImageSource: Sendable {
    @MainActor
    func readImage() throws -> EncodedImage
}

public protocol CredentialProvider: Sendable {
    func credentials() async throws -> R2Credentials
}

public protocol ObjectKeyGenerating: Sendable {
    func makeKey(prefix: String, date: Date, fileExtension: String) throws -> String
}

public protocol RequestSigning: Sendable {
    func signedPUT(
        url: URL,
        contentType: String,
        payload: Data,
        credentials: R2Credentials,
        date: Date
    ) throws -> URLRequest
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest, body: Data) async throws -> (HTTPURLResponse, Data)
}

public protocol ImageUploading: Sendable {
    func uploadClipboardImage() async throws -> UploadReceipt
}
