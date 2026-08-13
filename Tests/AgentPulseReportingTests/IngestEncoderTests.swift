import XCTest
@testable import AgentPulseReporting

final class IngestEncoderTests: XCTestCase {
    private func json(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    func testBucketFieldOrderAndOmitEmpty() {
        let bucket = UsageBucketPayload(source: "codex", model: "gpt", project: "demo", bucketStart: "2026-01-01T00:00:00Z", hostname: "host-a", inputTokens: 10, outputTokens: 20, reasoningOutputTokens: 5, totalTokens: 35)
        let out = json(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket])))
        XCTAssertTrue(out.contains("\"cachedInputTokens\":0"))
        XCTAssertFalse(out.contains("cacheCreationInputTokens"))
        XCTAssertFalse(out.contains("linesAdded"))
        XCTAssertFalse(out.contains("codeMetricVersion"))
        XCTAssertFalse(out.contains("sessions"))
        XCTAssertFalse(out.contains("fullSync"))
        assertKeyOrder(out, ["source", "model", "project", "bucketStart", "hostname", "inputTokens", "outputTokens", "cachedInputTokens", "reasoningOutputTokens", "totalTokens"])
    }

    func testBucketOptionalFieldsEmittedWhenPresent() {
        let bucket = UsageBucketPayload(source: "codex", model: "gpt", project: "demo", skills: ["a", "b"], skillCounts: ["b": 2, "a": 1], mcpCounts: ["x": 3], bucketStart: "t", cacheCreationInputTokens: 4, linesNet: 5, codeMetricVersion: 2)
        let out = json(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket])))
        XCTAssertTrue(out.contains("\"skills\":[\"a\",\"b\"]"))
        XCTAssertTrue(out.contains("\"skill_counts\":{\"a\":1,\"b\":2}"))
        XCTAssertTrue(out.contains("\"mcp_counts\":{\"x\":3}"))
        XCTAssertTrue(out.contains("\"cacheCreationInputTokens\":4"))
        XCTAssertTrue(out.contains("\"linesNet\":5"))
        XCTAssertTrue(out.contains("\"codeMetricVersion\":2"))
    }

    func testSessionAlwaysIncludesUserPromptHours() {
        let session = UsageSessionPayload(source: "codex", project: "demo", sessionHash: "hash", firstMessageAt: "a", lastMessageAt: "b")
        let out = json(UsageIngestEncoder().encode(UsageIngestRequest(sessions: [session])))
        XCTAssertTrue(out.contains("\"userPromptHours\":[]"))
        XCTAssertTrue(out.contains("\"buckets\":[]"))
    }

    func testAutonomyAndFlagsEncoded() {
        let autonomy = AutonomySessionPayload(source: "codex", project: "demo", sessionHash: "h", firstEventAt: "a", lastEventAt: "b", autonomyStatus: "autonomous", confidence: "high", schemaVersion: 1, computedAt: "c")
        let status = AutonomySourceStatusPayload(source: "codex", status: "ok")
        let request = UsageIngestRequest(autonomySessions: [autonomy], autonomySourceStatuses: [status], autonomyWindowStart: "w1", autonomyWindowEnd: "w2", fullSync: true, fullSyncReset: true)
        let out = json(UsageIngestEncoder().encode(request))
        XCTAssertTrue(out.contains("\"autonomySessions\":["))
        XCTAssertTrue(out.contains("\"autonomyStatus\":\"autonomous\""))
        XCTAssertTrue(out.contains("\"autonomySourceStatuses\":[{\"source\":\"codex\",\"hostname\":\"\",\"status\":\"ok\"}]"))
        XCTAssertTrue(out.contains("\"autonomyWindowStart\":\"w1\""))
        XCTAssertTrue(out.contains("\"autonomyWindowEnd\":\"w2\""))
        XCTAssertTrue(out.contains("\"fullSync\":true"))
        XCTAssertTrue(out.contains("\"fullSyncReset\":true"))
        XCTAssertFalse(out.contains("firstUserAt"))
        XCTAssertFalse(out.contains("parserVersion"))
        assertKeyOrder(out, ["source", "project", "sessionHash", "hostname", "firstEventAt", "lastEventAt", "autonomyStatus", "clarificationTurnCount", "confidence", "schemaVersion", "computedAt"])
    }

    func testFalseFlagsAreOmitted() {
        let out = json(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [UsageBucketPayload(source: "s", model: "m", project: "p", bucketStart: "t")])))
        XCTAssertFalse(out.contains("fullSync"))
        XCTAssertFalse(out.contains("fullSyncReset"))
    }

    func testHTMLSensitiveCharactersEscaped() {
        let bucket = UsageBucketPayload(source: "a<b>&c", model: "m", project: "p", bucketStart: "t")
        let out = json(UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket])))
        XCTAssertTrue(out.contains("a\\u003cb\\u003e\\u0026c"))
    }

    func testProducesValidJSON() throws {
        let bucket = UsageBucketPayload(source: "s", model: "m", project: "p", skills: ["k"], bucketStart: "t", totalTokens: 3)
        let object = try JSONSerialization.jsonObject(with: UsageIngestEncoder().encode(UsageIngestRequest(buckets: [bucket]))) as? [String: Any]
        XCTAssertNotNil(object?["buckets"])
    }

    private func assertKeyOrder(_ json: String, _ keys: [String], file: StaticString = #filePath, line: UInt = #line) {
        var searchStart = json.startIndex
        for key in keys {
            guard let range = json.range(of: "\"" + key + "\":", range: searchStart..<json.endIndex) else {
                XCTFail("missing key \(key) in order", file: file, line: line); return
            }
            searchStart = range.upperBound
        }
    }
}

