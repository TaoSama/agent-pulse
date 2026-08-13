import Foundation
import XCTest
@testable import AgentPulseR2

final class ObjectKeyAndURLTests: XCTestCase {
    func testObjectKeyUsesUTCDateAndFixedUUID() throws {
        let uuid = UUID(uuidString: "0B1A2C3D-4E5F-6071-8293-A4B5C6D7E8F9")!
        let generator = UUIDObjectKeyGenerator(generateUUID: { uuid })
        let date = Date(timeIntervalSince1970: 1_786_326_400)

        XCTAssertEqual(
            try generator.makeKey(prefix: "clipboard/v1", date: date, fileExtension: "PNG"),
            "clipboard/v1/2026/08/10/0b1a2c3d-4e5f-6071-8293-a4b5c6d7e8f9.png"
        )
    }

    func testRejectsUnsafePrefixes() {
        for prefix in ["/leading", "trailing/", "a//b", "a/../b", "a/./b", "a\\b", "a/\u{0001}b"] {
            XCTAssertThrowsError(
                try UUIDObjectKeyGenerator().makeKey(prefix: prefix, date: Date(), fileExtension: "png"),
                "Expected rejection for \(prefix.debugDescription)"
            )
        }
    }

    func testURLBuilderEncodesEachPathSegmentUsingRFC3986() throws {
        let configuration = R2Configuration(
            endpoint: URL(string: "https://account.r2.cloudflarestorage.com/")!,
            bucket: "image-bucket",
            publicBaseURL: URL(string: "https://images.example.test/base/")!
        )
        let key = "folder/space + café 🚀/(1)@&=.png"

        let uploadURL = try R2URLBuilder.uploadURL(configuration: configuration, objectKey: key)
        let publicURL = try R2URLBuilder.publicURL(configuration: configuration, objectKey: key)

        XCTAssertEqual(
            uploadURL.absoluteString,
            "https://account.r2.cloudflarestorage.com/image-bucket/folder/space%20%2B%20caf%C3%A9%20%F0%9F%9A%80/%281%29%40%26%3D.png"
        )
        XCTAssertEqual(
            publicURL.absoluteString,
            "https://images.example.test/base/folder/space%20%2B%20caf%C3%A9%20%F0%9F%9A%80/%281%29%40%26%3D.png"
        )
    }
}
