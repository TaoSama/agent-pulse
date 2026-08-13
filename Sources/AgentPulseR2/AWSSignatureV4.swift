import CryptoKit
import Foundation

public struct AWSSignatureV4Signer: RequestSigning {
    public let region: String
    public let service: String

    public init(region: String = "auto", service: String = "s3") {
        self.region = region
        self.service = service
    }

    public func signedPUT(
        url: URL,
        contentType: String,
        payload: Data,
        credentials: R2Credentials,
        date: Date
    ) throws -> URLRequest {
        let timestamp = Self.timestamp(date)
        let payloadHash = Self.sha256Hex(payload)
        let material = try canonicalMaterial(
            url: url,
            contentType: contentType,
            payloadHash: payloadHash,
            timestamp: timestamp
        )
        let shortDate = String(timestamp.prefix(8))
        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let canonicalHash = Self.sha256Hex(Data(material.request.utf8))
        let stringToSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(canonicalHash)"
        let signature = Self.signature(
            secretAccessKey: credentials.secretAccessKey,
            shortDate: shortDate,
            region: region,
            service: service,
            stringToSign: stringToSign
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyID)/\(scope), SignedHeaders=\(material.signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    public func canonicalRequest(
        url: URL,
        contentType: String,
        payloadHash: String,
        timestamp: String
    ) throws -> String {
        try canonicalMaterial(
            url: url,
            contentType: contentType,
            payloadHash: payloadHash,
            timestamp: timestamp
        ).request
    }

    struct CanonicalMaterial: Equatable {
        let request: String
        let signedHeaders: String
    }

    func canonicalMaterial(
        url: URL,
        contentType: String,
        payloadHash: String,
        timestamp: String
    ) throws -> CanonicalMaterial {
        guard
            url.scheme?.lowercased() == "https",
            let host = Self.canonicalHost(url),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.query == nil
        else {
            throw R2Error.invalidObjectURL
        }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let headers = [
            "content-type:\(Self.trimmedHeaderValue(contentType))",
            "host:\(host)",
            "x-amz-content-sha256:\(payloadHash)",
            "x-amz-date:\(timestamp)",
        ].joined(separator: "\n") + "\n"
        let signedHeaders = "content-type;host;x-amz-content-sha256;x-amz-date"
        return CanonicalMaterial(
            request: "PUT\n\(path)\n\n\(headers)\n\(signedHeaders)\n\(payloadHash)",
            signedHeaders: signedHeaders
        )
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func canonicalHost(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        guard let port = url.port else { return host }
        return port == 443 ? host : "\(host):\(port)"
    }

    private static func trimmedHeaderValue(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func signature(
        secretAccessKey: String,
        shortDate: String,
        region: String,
        service: String,
        stringToSign: String
    ) -> String {
        let dateKey = hmac(key: Data("AWS4\(secretAccessKey)".utf8), message: Data(shortDate.utf8))
        let regionKey = hmac(key: dateKey, message: Data(region.utf8))
        let serviceKey = hmac(key: regionKey, message: Data(service.utf8))
        let signingKey = hmac(key: serviceKey, message: Data("aws4_request".utf8))
        return hmac(key: signingKey, message: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, message: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code)
    }
}
