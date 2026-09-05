import Foundation
import XCTest
@testable import AgentPulseCore

final class UsageRecordTimestampTests: XCTestCase {
    private let fileIdentity = "timestamp-regression.jsonl"
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testCodexTimestampFormatsAreSharedByUsageAndSessionEvents() throws {
        let timestamps: [(Any, TimeInterval)] = [
            ("2023-11-14T22:13:20Z", 1_700_000_000),
            (" 2023-11-14T22:13:20.125Z ", 1_700_000_000.125),
            (1_700_000_000, 1_700_000_000),
            (1_700_000_000_125 as Int64, 1_700_000_000.125),
        ]
        for (timestamp, expectedEpoch) in timestamps {
            let parsed = try parse([codexUsage(timestamp: timestamp)], source: "codex")
            let usage = try XCTUnwrap(parsed.events.first)
            let session = try XCTUnwrap(parsed.sessionEvents.first)
            XCTAssertEqual(parsed.events.count, 1)
            XCTAssertEqual(parsed.sessionEvents.count, 1)
            XCTAssertEqual(usage.timestamp.timeIntervalSince1970, expectedEpoch, accuracy: 0.001)
            XCTAssertEqual(session.timestamp, usage.timestamp)
            XCTAssertTrue(parsed.diagnostics.isEmpty)
        }
    }

    func testCodexMissingAndInvalidTimestampsKeepUsageOnlyDiagnostic() throws {
        let invalidTimestamps: [Any?] = [nil, NSNull(), "not-a-date", " ", -1]
        for timestamp in invalidTimestamps {
            let parsed = try parse([codexUsage(timestamp: timestamp)], source: "codex")
            XCTAssertTrue(parsed.events.isEmpty)
            XCTAssertTrue(parsed.sessionEvents.isEmpty)
            XCTAssertEqual(parsed.diagnostics, ["line 1: invalid timestamp (usage skipped)"])
        }
    }

    func testUntimedCodexContextStillBackfillsAndInvalidUsageAdvancesCumulativeState() throws {
        let rows: [[String: Any]] = [
            ["type": "session_meta", "payload": ["id": "timestamp-session"]],
            codexUsage(timestamp: "bad", cumulativeInput: 100),
            ["type": "turn_context", "payload": ["model": "codex-test-model", "turn_id": "turn-1"]],
            codexUsage(timestamp: 1_700_000_000, cumulativeInput: 150),
        ]
        let full = try parse(rows, source: "codex")
        let incremental = try parseOneRecordBatches(rows, source: "codex")
        let event = try XCTUnwrap(full.events.first)
        XCTAssertEqual(full.events.count, 1)
        XCTAssertEqual(event.counts.input, 50)
        XCTAssertEqual(event.model, "codex-test-model")
        XCTAssertEqual(full.sessionEvents.count, 1)
        XCTAssertEqual(full.diagnostics, [
            "line 2: cumulative fallback", "line 2: invalid timestamp (usage skipped)",
            "line 4: cumulative fallback",
        ])
        XCTAssertEqual(incremental.flatMap(\.events), full.events)
        XCTAssertEqual(incremental.flatMap(\.sessionEvents), full.sessionEvents)
        XCTAssertEqual(incremental.flatMap(\.diagnostics), full.diagnostics)
    }

    func testCodexUntimedToolOutputStillConfirmsTimestampedEdit() throws {
        let parsed = try parseFixture("codex_edit_missing_ts", source: "codex")
        let edit = try XCTUnwrap(parsed.editEntries.first)
        XCTAssertEqual(parsed.editEntries.count, 1)
        XCTAssertEqual(edit.toolUseID, "cx-keep")
        XCTAssertEqual(edit.added, 2)
        XCTAssertEqual(edit.deleted, 1)
        XCTAssertEqual(edit.timestamp, UsageTimestamp.parse("2026-08-13T00:00:04.000Z"))
        XCTAssertTrue(parsed.diagnostics.contains { $0.contains("edit call skipped (missing timestamp)") })
        XCTAssertFalse(parsed.diagnostics.contains { $0.contains("session event skipped") })
    }

    func testClaudeSharedTimestampPreservesToolsAndUntimedResultGate() throws {
        let valid: [String: Any] = [
            "type": "assistant", "sessionId": "timestamp-session", "timestamp": 1_700_000_000,
            "message": ["id": "message-1", "model": "claude-sonnet", "content": [
                ["type": "tool_use", "id": "edit-1", "name": "Edit",
                 "input": ["old_string": "old", "new_string": "new"]],
                ["type": "tool_use", "id": "skill-1", "name": "Skill", "input": ["skill": "audit"]],
            ], "usage": ["input_tokens": 10, "output_tokens": 4]],
        ]
        var invalid = valid
        invalid["timestamp"] = "not-a-date"
        let result: [String: Any] = [
            "type": "user", "sessionId": "timestamp-session", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "edit-1", "is_error": false],
            ]],
        ]
        let parsed = try parse([valid, invalid, result], source: "claude")
        let event = try XCTUnwrap(parsed.events.first)
        let edit = try XCTUnwrap(parsed.editEntries.first)
        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.editEntries.count, 1)
        XCTAssertEqual(parsed.sessionEvents.count, 1)
        XCTAssertEqual(event.counts.input, 10)
        XCTAssertEqual(event.counts.output, 4)
        XCTAssertEqual(event.skillCounts, ["audit": 1])
        XCTAssertEqual(event.timestamp, referenceDate)
        XCTAssertEqual(edit.timestamp, event.timestamp)
        XCTAssertEqual(parsed.sessionEvents.first?.timestamp, event.timestamp)
        XCTAssertEqual(parsed.diagnostics, [
            "line 2: edit call skipped (missing timestamp)",
            "line 2: invalid timestamp (session event skipped)",
            "line 2: invalid timestamp (usage skipped)",
            "line 3: invalid timestamp (session event skipped)",
        ])
    }

    func testClaudeDedupKeepsEarliestTimestampAndBackfillsModelForMainAndSubagent() throws {
        let early: [String: Any] = [
            "type": "assistant", "sessionId": "timestamp-session", "timestamp": 1_700_000_000,
            "message": ["id": "same-message", "model": "unknown",
                        "usage": ["input_tokens": 10, "output_tokens": 4]],
        ]
        var later = early
        later["timestamp"] = 1_700_000_010
        later["message"] = ["id": "same-message", "model": "claude-sonnet",
                            "usage": ["input_tokens": 20, "output_tokens": 8]]
        let data = try jsonl([early, later])
        for isSubagent in [false, true] {
            let parsed = UsageJSONLParser.parse(data: data, source: "claude", fileIdentity: fileIdentity,
                                               modifiedAt: referenceDate, isSubagent: isSubagent)
            let event = try XCTUnwrap(parsed.events.first)
            XCTAssertEqual(parsed.events.count, 1)
            XCTAssertEqual(event.timestamp, referenceDate)
            XCTAssertEqual(event.model, "claude-sonnet")
            XCTAssertEqual(event.counts.input, 20)
            XCTAssertEqual(event.counts.output, 8)
            XCTAssertEqual(parsed.sessionEvents.count, isSubagent ? 0 : 1)
            XCTAssertTrue(parsed.diagnostics.isEmpty)
        }
    }

    private func codexUsage(timestamp: Any?, cumulativeInput: Int? = nil) -> [String: Any] {
        let usage = ["input_tokens": cumulativeInput ?? 10, "output_tokens": 0,
                     "total_tokens": cumulativeInput ?? 10]
        var row: [String: Any] = [
            "type": "event_msg", "payload": ["type": "token_count", "info": [
                cumulativeInput == nil ? "last_token_usage" : "total_token_usage": usage,
            ]],
        ]
        row["timestamp"] = timestamp
        return row
    }

    private func jsonl(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { data, row in
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
    }

    private func parse(_ rows: [[String: Any]], source: String) throws -> ParsedUsageFile {
        UsageJSONLParser.parse(data: try jsonl(rows), source: source, fileIdentity: fileIdentity,
                               modifiedAt: referenceDate)
    }

    private func parseFixture(_ name: String, source: String) throws -> ParsedUsageFile {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name + ".jsonl")
        return UsageJSONLParser.parse(data: try Data(contentsOf: url), source: source,
                                     fileIdentity: fileIdentity, modifiedAt: referenceDate)
    }

    private func parseOneRecordBatches(_ rows: [[String: Any]], source: String) throws -> [ParsedUsageFile] {
        var persisted: [String: Data] = [:]
        var offset: Int64 = 0
        let size = Int64(try jsonl(rows).count)
        return try rows.enumerated().map { index, row in
            let data = try jsonl([row])
            offset += Int64(data.count)
            let state = UsageParserState(lookup: { persisted[$0] })
            let parsed = try UsageJSONLParser.parseIncrementalChunk(
                data: data, source: source, fileIdentity: fileIdentity, modifiedAt: referenceDate,
                isSubagent: false, offset: offset, size: size, lineOffset: index, state: state
            )
            let changes = try state.changes()
            for key in changes.removedKeys { persisted.removeValue(forKey: key) }
            persisted.merge(changes.values) { _, new in new }
            return parsed
        }
    }
}
