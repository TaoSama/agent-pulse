import CryptoKit
import Foundation
import XCTest
@testable import AgentPulseCore

final class ContentDigestTests: XCTestCase {
    private static let expectedHexLength = 64
    private static let lowercaseHexDigits = Set("0123456789abcdef".utf8)

    func testKnownSHA256Vectors() {
        let vectors = [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
             "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        ]
        for (input, expected) in vectors {
            XCTAssertEqual(ContentDigest.sha256(input), expected)
            XCTAssertEqual(ContentDigest.sha256(Data(input.utf8)), expected)
        }
    }

    func testBinaryInputsMatchKnownVectorAndPreviousEncoding() {
        let allBytes = Data(UInt8.min...UInt8.max)
        XCTAssertEqual(ContentDigest.sha256(allBytes),
                       "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880")
        let lengths = [0, 1, 31, 32, 63, 64, 65, 255, 256, 1_024, 4_096]
        let byteStride = 73
        for length in lengths {
            let data = Data((0..<length).map { UInt8(truncatingIfNeeded: $0 * byteStride + length) })
            assertMatchesPreviousEncoding(data)
        }
        assertMatchesPreviousEncoding(allBytes)
    }

    func testUnicodeAndParserIdentityInputsMatchPreviousEncoding() {
        let inputs = [
            "中文会话/模型", "👩🏽‍💻🧪", "café", "cafe\u{301}", "a\0b\n\r\t",
            "codex|session-event|会话|assistant|message:123|occurrence:42",
            "session-identities:" + String(repeating: "0", count: Self.expectedHexLength),
        ]
        for input in inputs {
            let data = Data(input.utf8)
            assertMatchesPreviousEncoding(data)
            XCTAssertEqual(ContentDigest.sha256(input), ContentDigest.sha256(data))
        }
        XCTAssertNotEqual(ContentDigest.sha256("café"), ContentDigest.sha256("cafe\u{301}"))
    }

    /// Report a bounded comparison without a timing assertion: CI load must not
    /// turn an otherwise byte-identical digest implementation into a failure.
    func testBoundedEncodingPerformanceComparison() {
        let iterations = 2_000
        let rounds = 3
        let distinctInputs = 64
        let inputs = (0..<distinctInputs).map { Data("codex|session-event|session|assistant|message:\($0)".utf8) }
        for input in inputs { assertMatchesPreviousEncoding(input) }

        var previousDuration = Duration.zero
        var optimizedDuration = Duration.zero
        for round in 0..<rounds {
            let previous: (duration: Duration, digests: [String])
            let optimized: (duration: Duration, digests: [String])
            if round.isMultiple(of: 2) {
                previous = timeHashes(inputs: inputs, iterations: iterations, hash: previousEncoding)
                optimized = timeHashes(inputs: inputs, iterations: iterations, hash: ContentDigest.sha256)
            } else {
                optimized = timeHashes(inputs: inputs, iterations: iterations, hash: ContentDigest.sha256)
                previous = timeHashes(inputs: inputs, iterations: iterations, hash: previousEncoding)
            }
            XCTAssertEqual(optimized.digests, previous.digests)
            previousDuration += previous.duration
            optimizedDuration += optimized.duration
        }
        print("ContentDigest comparison: hashes_per_variant=\(iterations * rounds) "
              + "previous=\(previousDuration) optimized=\(optimizedDuration)")
    }

    private func assertMatchesPreviousEncoding(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let actual = ContentDigest.sha256(data)
        XCTAssertEqual(actual, previousEncoding(data), file: file, line: line)
        XCTAssertEqual(actual.utf8.count, Self.expectedHexLength, file: file, line: line)
        XCTAssertTrue(actual.utf8.allSatisfy { Self.lowercaseHexDigits.contains($0) }, file: file, line: line)
    }

    private func previousEncoding(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func timeHashes(
        inputs: [Data], iterations: Int, hash: (Data) -> String
    ) -> (duration: Duration, digests: [String]) {
        autoreleasepool {
            var digests: [String] = []
            digests.reserveCapacity(iterations)
            let start = ContinuousClock.now
            for index in 0..<iterations { digests.append(hash(inputs[index % inputs.count])) }
            return (start.duration(to: .now), digests)
        }
    }
}
