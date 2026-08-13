import Foundation
import XCTest
@testable import AgentPulseR2

final class UploadStatusTests: XCTestCase {
    func testMapsHTTPStatusesAndSanitizesRequestID() {
        XCTAssertNil(R2HTTPStatusMapper.error(for: response(status: 204)))
        XCTAssertEqual(R2HTTPStatusMapper.error(for: response(status: 401)), .unauthorized)
        XCTAssertEqual(R2HTTPStatusMapper.error(for: response(status: 403)), .forbidden)
        XCTAssertEqual(
            R2HTTPStatusMapper.error(for: response(status: 429, headers: ["Retry-After": "17"])),
            .rateLimited(retryAfterSeconds: 17)
        )
        XCTAssertEqual(R2HTTPStatusMapper.error(for: response(status: 503)), .serverUnavailable(statusCode: 503))
        XCTAssertEqual(
            R2HTTPStatusMapper.error(for: response(status: 418, headers: ["cf-ray": "safe-id_123"])),
            .httpFailure(statusCode: 418, requestID: "safe-id_123")
        )
        XCTAssertEqual(
            R2HTTPStatusMapper.error(for: response(status: 400, headers: ["cf-ray": "unsafe secret/value"])),
            .httpFailure(statusCode: 400, requestID: nil)
        )
        XCTAssertEqual(
            R2HTTPStatusMapper.error(
                for: response(status: 403),
                body: Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8)
            ),
            .signatureRejected
        )
        XCTAssertEqual(
            R2HTTPStatusMapper.error(
                for: response(status: 400),
                body: Data("<Error><Code>RequestTimeTooSkewed</Code></Error>".utf8)
            ),
            .clockSkew
        )
        XCTAssertEqual(
            R2HTTPStatusMapper.error(
                for: response(status: 400),
                body: Data("<Error><Code>RequestExpired</Code></Error>".utf8)
            ),
            .clockSkew
        )
        XCTAssertEqual(
            R2HTTPStatusMapper.error(
                for: response(status: 403),
                body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)
            ),
            .forbidden
        )
    }

    func testUploaderReturnsReceiptAndSendsUnchangedBody() async throws {
        let payload = Data([0x89, 0x50, 0x4E, 0x47])
        let transport = CapturingTransport(response: response(status: 200, headers: ["ETag": "etag-value"]))
        let uploader = R2Uploader(
            source: FixedImageSource(image: EncodedImage(data: payload, contentType: "image/png", fileExtension: "png")),
            credentialProvider: StaticCredentialProvider(R2Credentials(accessKeyID: "test", secretAccessKey: "test")),
            keyGenerator: FixedKeyGenerator(key: "clipboard/v1/fixed.png"),
            signer: PassthroughSigner(),
            transport: transport,
            configuration: R2Configuration(
                endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
                bucket: "image-bucket",
                publicBaseURL: URL(string: "https://images.example.test")!
            )
        )

        let receipt = try await uploader.uploadClipboardImage()
        XCTAssertEqual(receipt.objectKey, "clipboard/v1/fixed.png")
        XCTAssertEqual(receipt.publicURL.absoluteString, "https://images.example.test/clipboard/v1/fixed.png")
        XCTAssertEqual(receipt.eTag, "etag-value")
        XCTAssertEqual(receipt.byteCount, payload.count)
        let captured = await transport.capturedBody
        XCTAssertEqual(captured, payload)
    }

    func testURLSessionTransportSendsPlainPUTWithBodyOnRequest() async throws {
        RecordingURLProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let payload = Data("plain put body".utf8)
        var request = URLRequest(url: URL(string: "https://account.r2.cloudflarestorage.com/image-bucket/object.png")!)
        request.httpMethod = "PUT"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("fixed-payload-hash", forHTTPHeaderField: "x-amz-content-sha256")

        let transport = URLSessionHTTPTransport(session: session)
        let (response, _) = try await transport.send(request, body: payload)

        XCTAssertEqual(response.statusCode, 200)
        let capturedRequest = try XCTUnwrap(RecordingURLProtocol.state.capturedRequest())
        XCTAssertEqual(capturedRequest.httpMethod, "PUT")
        XCTAssertEqual(RecordingURLProtocol.state.capturedBody(), payload)
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "x-amz-content-sha256"), "fixed-payload-hash")
        XCTAssertNil(capturedRequest.value(forHTTPHeaderField: "Upload-Complete"))
        XCTAssertNil(capturedRequest.value(forHTTPHeaderField: "Upload-Draft-Interop-Version"))
    }

    func testOversizedImageDoesNotReachTransport() async {
        let transport = CapturingTransport(response: response(status: 200))
        let uploader = R2Uploader(
            source: FixedImageSource(image: EncodedImage(data: Data(repeating: 1, count: 2), contentType: "image/png", fileExtension: "png")),
            credentialProvider: StaticCredentialProvider(R2Credentials(accessKeyID: "test", secretAccessKey: "test")),
            keyGenerator: FixedKeyGenerator(key: "unused.png"),
            signer: PassthroughSigner(),
            transport: transport,
            configuration: R2Configuration(
                endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
                bucket: "image-bucket",
                publicBaseURL: URL(string: "https://images.example.test")!
            ),
            policy: UploadPolicy(maxBytes: 1)
        )

        do {
            _ = try await uploader.uploadClipboardImage()
            XCTFail("Expected imageTooLarge")
        } catch {
            XCTAssertEqual(error as? R2Error, .imageTooLarge(maxBytes: 1))
        }
        let capturedBody = await transport.capturedBody
        XCTAssertNil(capturedBody)
    }

    private func response(status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://account.r2.cloudflarestorage.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }
}

private struct FixedImageSource: ClipboardImageSource {
    let image: EncodedImage

    @MainActor
    func readImage() throws -> EncodedImage { image }
}

private struct FixedKeyGenerator: ObjectKeyGenerating {
    let key: String
    func makeKey(prefix: String, date: Date, fileExtension: String) throws -> String { key }
}

private struct PassthroughSigner: RequestSigning {
    func signedPUT(
        url: URL,
        contentType: String,
        payload: Data,
        credentials: R2Credentials,
        date: Date
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }
}

private actor CapturingTransport: HTTPTransport {
    let response: HTTPURLResponse
    private(set) var capturedBody: Data?

    init(response: HTTPURLResponse) { self.response = response }

    func send(_ request: URLRequest, body: Data) async throws -> (HTTPURLResponse, Data) {
        capturedBody = body
        return (response, Data())
    }
}

private final class RecordingURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?
    private var body: Data?

    func reset() {
        lock.withLock {
            request = nil
            body = nil
        }
    }

    func record(_ request: URLRequest, body: Data?) {
        lock.withLock {
            self.request = request
            self.body = body
        }
    }

    func capturedRequest() -> URLRequest? {
        lock.withLock { request }
    }

    func capturedBody() -> Data? {
        lock.withLock { body }
    }
}

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = RecordingURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.state.record(request, body: requestBody(request))
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }
}
