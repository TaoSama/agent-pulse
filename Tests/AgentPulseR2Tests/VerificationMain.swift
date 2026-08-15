import AgentPulseR2
import Foundation

@main
struct AgentPulseR2Verification {
    static func main() async throws {
        try verifySignatureV4()
        try verifyObjectKeyAndURLs()
        try verifyRedactedConfigurationErrors()
        try verifyEndpointDerivedFromAccountID()
        try verifyHTTPStatusMapping()
        try await verifyPlainPUTTransport()
        print("AgentPulseR2 verification passed")
    }

    private static func verifySignatureV4() throws {
        let signer = AWSSignatureV4Signer()
        let payload = Data("hello".utf8)
        let payloadHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let timestamp = "20240102T030405Z"
        let url = URL(string: "https://account.r2.cloudflarestorage.com/photos/folder/a%20b%2Bc.png")!
        let expectedCanonicalRequest = """
        PUT
        /photos/folder/a%20b%2Bc.png

        content-type:image/png
        host:account.r2.cloudflarestorage.com
        x-amz-content-sha256:\(payloadHash)
        x-amz-date:\(timestamp)

        content-type;host;x-amz-content-sha256;x-amz-date
        \(payloadHash)
        """
        let canonicalRequest = try signer.canonicalRequest(
            url: url,
            contentType: "image/png",
            payloadHash: payloadHash,
            timestamp: timestamp
        )
        try expect(canonicalRequest == expectedCanonicalRequest, "canonical request mismatch")

        let request = try signer.signedPUT(
            url: url,
            contentType: "image/png",
            payload: payload,
            credentials: R2Credentials(accessKeyID: "TESTACCESS", secretAccessKey: "testsecret"),
            date: utcDate(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5)
        )
        try expect(request.value(forHTTPHeaderField: "x-amz-content-sha256") == payloadHash, "payload hash mismatch")
        let expectedAuthorization = "AWS4-HMAC-SHA256 Credential=TESTACCESS/20240102/auto/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=34e1e11b3d8cdf7b879465061a247f3e1ee2be1b528e01b01c9caf859cb37f51"
        try expect(request.value(forHTTPHeaderField: "Authorization") == expectedAuthorization, "SigV4 mismatch")
    }

    private static func verifyObjectKeyAndURLs() throws {
        let uuid = UUID(uuidString: "0B1A2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
        let generator = UUIDObjectKeyGenerator(generateUUID: { uuid })
        let key = try generator.makeKey(
            prefix: "clipboard/v1",
            date: utcDate(year: 2026, month: 8, day: 10),
            fileExtension: "png"
        )
        try expect(
            key == "clipboard/v1/2026/08/10/0b1a2c3d-4e5f-6071-8293-a4b5c6d7e8f9.png",
            "object key mismatch"
        )

        let configuration = R2Configuration(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com")!,
            bucket: "image-bucket",
            publicBaseURL: URL(string: "https://images.example.test/base/")!
        )
        let specialKey = "folder/space + café 🚀/(1)@&=.png"
        let uploadURL = try R2URLBuilder.uploadURL(configuration: configuration, objectKey: specialKey)
        let publicURL = try R2URLBuilder.publicURL(configuration: configuration, objectKey: specialKey)
        try expect(
            uploadURL.absoluteString == "https://account.r2.cloudflarestorage.com/image-bucket/folder/space%20%2B%20caf%C3%A9%20%F0%9F%9A%80/%281%29%40%26%3D.png",
            "upload URL encoding mismatch"
        )
        try expect(
            publicURL.absoluteString == "https://images.example.test/base/folder/space%20%2B%20caf%C3%A9%20%F0%9F%9A%80/%281%29%40%26%3D.png",
            "public URL encoding mismatch"
        )
        do {
            _ = try R2URLBuilder.publicURL(configuration: configuration, objectKey: "a//b.png")
            throw VerificationFailure("unsafe object key was accepted")
        } catch R2Error.invalidObjectURL {
            // Expected.
        }
    }

    private static func verifyRedactedConfigurationErrors() throws {
        // endpoint 已由 account id 拼出，不再单独配置；用非法 account id（含 host 边界字符）
        // 触发 invalidConfiguration，断言字段名为 R2_ACCOUNT_ID 且不回显值。
        let sensitiveValue = "bad/account@evil.example"
        let environment = [
            "R2_ACCOUNT_ID": sensitiveValue,
            "R2_BUCKET": "image-bucket",
            "R2_PUBLIC_BASE_URL": "https://images.example.test",
            "R2_ACCESS_KEY_ID": "test-access",
            "R2_SECRET_ACCESS_KEY": "test-secret",
        ]
        do {
            _ = try EnvironmentR2Configuration(environment: environment)
            throw VerificationFailure("invalid configuration was accepted")
        } catch let error as R2Error {
            try expect(error == .invalidConfiguration(fields: ["R2_ACCOUNT_ID"]), "configuration error mapping mismatch")
            try expect(!error.localizedDescription.contains(sensitiveValue), "configuration error leaked a value")
        }
    }

    /// endpoint 由 account id 拼出固定模板：https://<account-id>.r2.cloudflarestorage.com。
    private static func verifyEndpointDerivedFromAccountID() throws {
        let environment = [
            "R2_ACCOUNT_ID": "acc0unt123",
            "R2_BUCKET": "image-bucket",
            "R2_PUBLIC_BASE_URL": "https://images.example.test",
            "R2_ACCESS_KEY_ID": "test-access",
            "R2_SECRET_ACCESS_KEY": "test-secret",
        ]
        let resolved = try EnvironmentR2Configuration(environment: environment)
        try expect(
            resolved.configuration.endpoint.absoluteString == "https://acc0unt123.r2.cloudflarestorage.com",
            "endpoint not derived from account id"
        )
    }

    private static func verifyHTTPStatusMapping() throws {
        try expect(R2HTTPStatusMapper.error(for: response(204)) == nil, "2xx mapping mismatch")
        try expect(R2HTTPStatusMapper.error(for: response(401)) == .unauthorized, "401 mapping mismatch")
        try expect(R2HTTPStatusMapper.error(for: response(403)) == .forbidden, "403 mapping mismatch")
        try expect(
            R2HTTPStatusMapper.error(for: response(429, headers: ["Retry-After": "9"])) == .rateLimited(retryAfterSeconds: 9),
            "429 mapping mismatch"
        )
        try expect(R2HTTPStatusMapper.error(for: response(503)) == .serverUnavailable(statusCode: 503), "5xx mapping mismatch")
        try expect(
            R2HTTPStatusMapper.error(for: response(418, headers: ["cf-ray": "safe-id_123"])) == .httpFailure(statusCode: 418, requestID: "safe-id_123"),
            "other 4xx mapping mismatch"
        )
        try expect(
            R2HTTPStatusMapper.error(for: response(400, headers: ["cf-ray": "unsafe secret/value"])) == .httpFailure(statusCode: 400, requestID: nil),
            "request ID sanitization mismatch"
        )
        try expect(
            R2HTTPStatusMapper.error(
                for: response(403),
                body: Data("<Error><Code>SignatureDoesNotMatch</Code><Message>redacted</Message></Error>".utf8)
            ) == .signatureRejected,
            "signature error mapping mismatch"
        )
        try expect(
            R2HTTPStatusMapper.error(
                for: response(400),
                body: Data("<Error><Code>RequestTimeTooSkewed</Code></Error>".utf8)
            ) == .clockSkew,
            "clock skew mapping mismatch"
        )
        try expect(
            R2HTTPStatusMapper.error(
                for: response(400),
                body: Data("<Error><Code>RequestExpired</Code></Error>".utf8)
            ) == .clockSkew,
            "expired request mapping mismatch"
        )
        try expect(
            R2HTTPStatusMapper.error(
                for: response(403),
                body: Data("<Error><Code>AccessDenied</Code></Error>".utf8)
            ) == .forbidden,
            "unknown XML code must preserve status mapping"
        )
    }

    private static func verifyPlainPUTTransport() async throws {
        VerificationURLProtocol.state.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VerificationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let body = Data("plain put body".utf8)
        var request = URLRequest(url: URL(string: "https://account.r2.cloudflarestorage.com/image-bucket/object.png")!)
        request.httpMethod = "PUT"
        request.setValue("image/png", forHTTPHeaderField: "Content-Type")
        request.setValue("fixed-payload-hash", forHTTPHeaderField: "x-amz-content-sha256")

        let transport = URLSessionHTTPTransport(session: session)
        let (response, _) = try await transport.send(request, body: body)
        guard let capturedRequest = VerificationURLProtocol.state.capturedRequest() else {
            throw VerificationFailure("URLSession transport did not issue a request")
        }

        try expect(response.statusCode == 200, "URLSession transport response mismatch")
        try expect(capturedRequest.httpMethod == "PUT", "URLSession transport method mismatch")
        try expect(VerificationURLProtocol.state.capturedBody() == body, "URLSession transport body mismatch")
        try expect(capturedRequest.value(forHTTPHeaderField: "Content-Type") == "image/png", "Content-Type changed before send")
        try expect(
            capturedRequest.value(forHTTPHeaderField: "x-amz-content-sha256") == "fixed-payload-hash",
            "payload hash changed before send"
        )
        try expect(capturedRequest.value(forHTTPHeaderField: "Upload-Complete") == nil, "resumable upload header was added")
        try expect(
            capturedRequest.value(forHTTPHeaderField: "Upload-Draft-Interop-Version") == nil,
            "resumable upload draft header was added"
        )
    }

    private static func response(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://account.r2.cloudflarestorage.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    private static func utcDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw VerificationFailure(message) }
    }
}

private struct VerificationFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

private final class VerificationURLProtocolState: @unchecked Sendable {
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

private final class VerificationURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = VerificationURLProtocolState()

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
