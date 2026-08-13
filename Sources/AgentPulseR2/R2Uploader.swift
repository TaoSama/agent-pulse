import Foundation

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest, body: Data) async throws -> (HTTPURLResponse, Data) {
        do {
            var request = request
            request.httpBody = body
            // The upload-task API adds resumable-upload draft headers on recent CFNetwork releases.
            // R2's S3 endpoint expects a plain signed PUT, so send the body as a data request.
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw R2Error.networkFailure }
            return (response, data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as R2Error {
            throw error
        } catch {
            throw R2Error.networkFailure
        }
    }
}

public enum R2HTTPStatusMapper {
    /// Maximum number of bytes inspected from the error body. R2/S3 error
    /// payloads are small XML documents; this cap keeps parsing bounded even if
    /// an unexpected response arrives.
    private static let maxErrorBodyBytes = 8 * 1_024

    public static func error(for response: HTTPURLResponse) -> R2Error? {
        error(for: response, body: nil)
    }

    /// Maps a non-success response to an `R2Error`. When a body is provided,
    /// the S3 XML `<Code>` element refines the mapping so signature and clock
    /// failures surface actionable errors instead of a generic 403.
    public static func error(for response: HTTPURLResponse, body: Data?) -> R2Error? {
        guard !(200...299).contains(response.statusCode) else { return nil }
        if let refined = refinedError(from: body) { return refined }
        switch response.statusCode {
        case 401:
            return .unauthorized
        case 403:
            return .forbidden
        case 429:
            return .rateLimited(retryAfterSeconds: retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599:
            return .serverUnavailable(statusCode: response.statusCode)
        default:
            return .httpFailure(
                statusCode: response.statusCode,
                requestID: sanitizedRequestID(
                    response.value(forHTTPHeaderField: "cf-ray")
                        ?? response.value(forHTTPHeaderField: "x-amz-request-id")
                )
            )
        }
    }

    /// Refines the mapping using the S3 error `<Code>` when it names a
    /// signature or clock-skew failure. Returns nil for any other or missing code.
    private static func refinedError(from body: Data?) -> R2Error? {
        guard let code = errorCode(from: body) else { return nil }
        switch code {
        case "SignatureDoesNotMatch":
            return .signatureRejected
        case "RequestTimeTooSkewed", "RequestExpired":
            return .clockSkew
        default:
            return nil
        }
    }

    /// Safely extracts the text inside the first `<Code>...</Code>` element of an
    /// S3 XML error body. Bounded in size and length, and never surfaces raw body
    /// bytes to callers or logs.
    static func errorCode(from body: Data?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        let slice = body.count > maxErrorBodyBytes ? body.prefix(maxErrorBodyBytes) : body[...]
        guard let text = String(data: Data(slice), encoding: .utf8) else { return nil }
        guard let openRange = text.range(of: "<Code>"),
              let closeRange = text.range(of: "</Code>", range: openRange.upperBound..<text.endIndex)
        else { return nil }
        let value = text[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics
        let scalars = value.unicodeScalars.prefix(128)
        guard !scalars.isEmpty, scalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func retryAfter(_ value: String?) -> Int? {
        guard let value, let seconds = Int(value), seconds >= 0 else { return nil }
        return seconds
    }

    private static func sanitizedRequestID(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.prefix(128)
        guard !scalars.isEmpty, scalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return String(String.UnicodeScalarView(scalars))
    }
}

public struct R2Uploader<Source, Credentials, KeyGenerator, Signer, Transport>: ImageUploading
where
    Source: ClipboardImageSource,
    Credentials: CredentialProvider,
    KeyGenerator: ObjectKeyGenerating,
    Signer: RequestSigning,
    Transport: HTTPTransport
{
    private let source: Source
    private let credentialProvider: Credentials
    private let keyGenerator: KeyGenerator
    private let signer: Signer
    private let transport: Transport
    private let configuration: R2Configuration
    private let policy: UploadPolicy
    private let now: @Sendable () -> Date

    public init(
        source: Source,
        credentialProvider: Credentials,
        keyGenerator: KeyGenerator,
        signer: Signer,
        transport: Transport,
        configuration: R2Configuration,
        policy: UploadPolicy = UploadPolicy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.credentialProvider = credentialProvider
        self.keyGenerator = keyGenerator
        self.signer = signer
        self.transport = transport
        self.configuration = configuration
        self.policy = policy
        self.now = now
    }

    public func uploadClipboardImage() async throws -> UploadReceipt {
        let image = try await source.readImage()
        guard policy.allowedContentTypes.contains(image.contentType) else { throw R2Error.unsupportedImage }
        guard image.data.count <= policy.maxBytes else { throw R2Error.imageTooLarge(maxBytes: policy.maxBytes) }

        let date = now()
        let objectKey = try keyGenerator.makeKey(
            prefix: policy.objectPrefix,
            date: date,
            fileExtension: image.fileExtension
        )
        let uploadURL = try R2URLBuilder.uploadURL(configuration: configuration, objectKey: objectKey)
        let publicURL = try R2URLBuilder.publicURL(configuration: configuration, objectKey: objectKey)
        let credentials: R2Credentials
        do {
            credentials = try await credentialProvider.credentials()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw R2Error.credentialUnavailable
        }
        let request = try signer.signedPUT(
            url: uploadURL,
            contentType: image.contentType,
            payload: image.data,
            credentials: credentials,
            date: date
        )
        let response: HTTPURLResponse
        let responseBody: Data
        do {
            (response, responseBody) = try await transport.send(request, body: image.data)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as R2Error {
            throw error
        } catch {
            throw R2Error.networkFailure
        }
        if let error = R2HTTPStatusMapper.error(for: response, body: responseBody) { throw error }
        return UploadReceipt(
            objectKey: objectKey,
            publicURL: publicURL,
            eTag: response.value(forHTTPHeaderField: "ETag"),
            byteCount: image.data.count
        )
    }
}
