import Foundation
import XCTest
@testable import AgentPulseR2

final class AWSSignatureV4Tests: XCTestCase {
    func testReproducibleCanonicalRequestAndSignature() throws {
        let signer = AWSSignatureV4Signer()
        let payload = Data("hello".utf8)
        let payloadHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        let url = URL(string: "https://account.r2.cloudflarestorage.com/photos/folder/a%20b%2Bc.png")!
        let timestamp = "20240102T030405Z"
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

        let material = try signer.canonicalMaterial(
            url: url,
            contentType: " image/png ",
            payloadHash: payloadHash,
            timestamp: timestamp
        )
        XCTAssertEqual(material.request, expectedCanonicalRequest)
        XCTAssertEqual(
            AWSSignatureV4Signer.sha256Hex(Data(material.request.utf8)),
            "057844ef15e616f276533133b9072f7013096c22ad7b37d3046452b66d11a21c"
        )

        let request = try signer.signedPUT(
            url: url,
            contentType: "image/png",
            payload: payload,
            credentials: R2Credentials(accessKeyID: "TESTACCESS", secretAccessKey: "testsecret"),
            date: fixedDate()
        )
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), payloadHash)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "AWS4-HMAC-SHA256 Credential=TESTACCESS/20240102/auto/s3/aws4_request, SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, Signature=34e1e11b3d8cdf7b879465061a247f3e1ee2be1b528e01b01c9caf859cb37f51"
        )
    }

    private func fixedDate() -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2024
        components.month = 1
        components.day = 2
        components.hour = 3
        components.minute = 4
        components.second = 5
        return components.date!
    }
}
