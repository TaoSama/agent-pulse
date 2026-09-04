import AgentPulseCore
import Foundation

private enum Failure: Error { case assertion(String) }

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw Failure.assertion(message) }
}

private final class FixtureState {
    var values: [String: Data] = [:]
    var events: [String: UsageEvent] = [:]
    var sessions: [String: UsageSessionEvent] = [:]
    var edits: [String: UsageEditEntry] = [:]
    var checkpoint: UsageFileCheckpoint?
    var batchCount = 0

    func apply(_ batch: UsageIncrementalBatch) throws {
        if batch.replacesFile {
            values.removeAll(); events.removeAll(); sessions.removeAll(); edits.removeAll()
        }
        for key in batch.stateChanges.removedKeys { values[key] = nil }
        values.merge(batch.stateChanges.values) { _, next in next }
        for id in batch.removedEventIDs { events[id] = nil }
        for id in batch.removedEditIDs { edits[id] = nil }
        for value in batch.parsed.events { events[value.id] = value }
        for value in batch.parsed.sessionEvents { sessions[value.id] = value }
        for value in batch.parsed.editEntries { edits[value.toolUseID] = value }
        if let model = batch.codexUnknownModel {
            for (key, value) in values where key.hasPrefix("codex-unknown:") {
                let id = try JSONDecoder().decode(String.self, from: value)
                guard let event = events[id] else { continue }
                events[id] = UsageEvent(id: event.id, source: event.source, model: model, project: event.project,
                    timestamp: event.timestamp, counts: event.counts, sessionHash: event.sessionHash,
                    sourceFileHash: event.sourceFileHash, rolloutKey: event.rolloutKey,
                    parentRolloutKey: event.parentRolloutKey, inherited: event.inherited,
                    hasTotalSnapshot: event.hasTotalSnapshot, lineageFingerprint: event.lineageFingerprint,
                    codexDedupKey: event.codexDedupKey, mergeStrategy: event.mergeStrategy,
                    skillCounts: event.skillCounts, mcpCounts: event.mcpCounts)
            }
        }
        checkpoint = batch.parsed.checkpoint
        batchCount += 1
    }
}

@main
private enum IncrementalParserVerification {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try verifyCodex(directory)
        try verifyClaude(directory)
        try verifyMetadataBoundaries(directory)
        try verifyEOFAndDiagnostics(directory)
        try verifyLargeBatch(directory)
        try verifyFailurePropagation(directory)
        try FileManager.default.removeItem(at: directory)
        print("Incremental parser verification passed: append, restart, partial line, truncation, cross-batch state, privacy, storage error")
    }

    static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    static func append(_ data: Data, to file: URL) throws {
        if !FileManager.default.fileExists(atPath: file.path) { try Data().write(to: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { handle.closeFile() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    static func scan(_ file: URL, source: String, state: FixtureState) throws -> UsageIncrementalReadResult {
        try UsageJSONLParser.readIncrementally(fileURL: file, source: source, fileIdentity: file.lastPathComponent,
                                              previousCheckpoint: state.checkpoint,
                                              stateLookup: { state.values[$0] }, onBatch: { try state.apply($0) })
    }

    static func parity(_ data: Data, source: String, file: URL, state: FixtureState) throws {
        let parsed = UsageJSONLParser.parse(data: data, source: source, fileIdentity: file.lastPathComponent)
        try require(state.events == Dictionary(parsed.events.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }), "token/tool parity")
        try require(state.sessions == Dictionary(parsed.sessionEvents.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }), "session parity")
        try require(state.edits == Dictionary(parsed.editEntries.map { ($0.toolUseID, $0) }, uniquingKeysWith: { _, b in b }), "edit parity")
    }

    static func verifyCodex(_ directory: URL) throws {
        let file = directory.appendingPathComponent("codex.jsonl")
        let state = FixtureState()
        let meta = try encode(["type": "session_meta", "timestamp": "2026-01-01T00:00:00Z", "payload": ["id": "rollout", "cwd": "/tmp/project"]])
        func token(_ count: Int, second: Int) throws -> Data {
            try encode(["type": "event_msg", "timestamp": String(format: "2026-01-01T00:00:%02dZ", second),
                        "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": count, "output_tokens": count, "total_tokens": count * 2]]]])
        }
        var data = meta + (try token(10, second: 1))
        try append(data, to: file)
        _ = try scan(file, source: "codex", state: state)
        try parity(data, source: "codex", file: file, state: state)
        let turn = try encode(["type": "turn_context", "timestamp": "2026-01-01T00:00:02Z", "payload": ["turn_id": "turn", "model": "gpt-5"]])
        let extensionData = turn + (try token(15, second: 3)) + (try token(2, second: 4))
        try append(extensionData, to: file); data += extensionData
        let result = try scan(file, source: "codex", state: state)
        try require(result.bytesRead == Int64(extensionData.count), "append reads only new bytes")
        try parity(data, source: "codex", file: file, state: state)
        let call = try encode(["type": "response_item", "timestamp": "2026-01-01T00:00:05Z", "payload": ["type": "custom_tool_call", "call_id": "edit", "name": "apply_patch", "input": "*** Begin Patch\n*** Add File: f\n+secret-body-canary\n*** End Patch"]])
        try append(call, to: file); data += call
        _ = try scan(file, source: "codex", state: state)
        let output = try encode(["type": "response_item", "timestamp": "2026-01-01T00:00:06Z", "payload": ["type": "custom_tool_call_output", "call_id": "edit", "output": "Success. Updated the following files:\nA f"]])
        let half = output.count / 2
        try append(Data(output.prefix(half)), to: file)
        let prior = state.checkpoint!.offset
        _ = try scan(file, source: "codex", state: state)
        try require(state.checkpoint?.offset == prior, "half line does not advance committed offset")
        let unchanged = try scan(file, source: "codex", state: state)
        try require(unchanged.batchCount == 0 && unchanged.bytesRead == 0, "unchanged partial file performs no batch writes")
        try append(Data(output.dropFirst(half)), to: file); data += output
        _ = try scan(file, source: "codex", state: state)
        try parity(data, source: "codex", file: file, state: state)
        try require(!state.values.values.contains { String(data: $0, encoding: .utf8)?.contains("secret-body-canary") == true }, "state must not retain source text")
        try meta.write(to: file)
        _ = try scan(file, source: "codex", state: state)
        try parity(meta, source: "codex", file: file, state: state)
    }

    static func verifyClaude(_ directory: URL) throws {
        let file = directory.appendingPathComponent("claude.jsonl")
        let state = FixtureState()
        func message(_ content: [[String: Any]], output: Int?, uuid: String) throws -> Data {
            var message: [String: Any] = ["id": "shared-message", "model": "claude-opus-4", "content": content]
            if let output { message["usage"] = ["input_tokens": 10, "output_tokens": output] }
            return try encode(["type": "assistant", "sessionId": "session", "uuid": uuid, "timestamp": "2026-01-01T00:00:00Z", "message": message])
        }
        let rows = [
            try message([["type": "tool_use", "id": "skill", "name": "Skill", "input": ["skill": "review", "api_key": "credential-value-canary"]]], output: nil, uuid: "a"),
            try message([["type": "thinking", "thinking": "private-thought-canary"]], output: 20, uuid: "b"),
            try message([["type": "text", "text": "answer"]], output: 30, uuid: "c"),
            try message([["type": "thinking", "thinking": "private-thought-canary"]], output: 25, uuid: "d")
        ]
        var data = Data()
        for row in rows {
            try append(row, to: file); data += row
            _ = try scan(file, source: "claude-code", state: state)
            try parity(data, source: "claude-code", file: file, state: state)
        }
        try require(!state.values.values.contains { String(data: $0, encoding: .utf8)?.contains("private-thought-canary") == true }, "thinking content is hashed")
        try require(!state.values.values.contains { String(data: $0, encoding: .utf8)?.contains("credential-value-canary") == true }, "tool parameters never enter state")
    }

    static func verifyLargeBatch(_ directory: URL) throws {
        let file = directory.appendingPathComponent("large-claude.jsonl")
        let state = FixtureState()
        var data = Data()
        for index in 0..<600 {
            data += try encode(["type": "assistant", "uuid": "row-\(index)", "sessionId": "session", "timestamp": "2026-01-01T00:00:00Z",
                                "message": ["id": "same-message", "model": "claude-opus-4", "usage": ["output_tokens": index + 1],
                                            "content": [["type": "text", "text": String(repeating: "z", count: 2048)]]]])
        }
        try data.write(to: file)
        _ = try scan(file, source: "claude-code", state: state)
        try require(state.batchCount > 1, "fixture crosses reader batch boundary")
        try parity(data, source: "claude-code", file: file, state: state)
    }

    static func verifyMetadataBoundaries(_ directory: URL) throws {
        let file = directory.appendingPathComponent("metadata.jsonl")
        let state = FixtureState()
        let meta = try encode(["type": "session_meta", "timestamp": "2026-01-01T00:00:00Z", "payload": ["id": "late-rollout"]])
        let half = meta.count / 2
        try append(Data(meta.prefix(half)), to: file)
        _ = try scan(file, source: "codex", state: state)
        try require(state.sessions.isEmpty, "initial partial metadata emits no fallback identity")
        try append(Data(meta.dropFirst(half)), to: file)
        _ = try scan(file, source: "codex", state: state)
        try parity(meta, source: "codex", file: file, state: state)

        let second = directory.appendingPathComponent("late-metadata.jsonl")
        let lateState = FixtureState()
        let row = try encode(["type": "event_msg", "timestamp": "2026-01-01T00:00:01Z", "payload": ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 3]]]])
        try append(row, to: second)
        _ = try scan(second, source: "codex", state: lateState)
        try append(meta, to: second)
        _ = try scan(second, source: "codex", state: lateState)
        try parity(row + meta, source: "codex", file: second, state: lateState)
    }

    static func verifyFailurePropagation(_ directory: URL) throws {
        let file = directory.appendingPathComponent("failure.jsonl")
        let state = FixtureState()
        try append(try encode(["type": "user", "uuid": "one", "timestamp": "2026-01-01T00:00:00Z"]), to: file)
        _ = try scan(file, source: "claude-code", state: state)
        try append(try encode(["type": "user", "uuid": "two", "timestamp": "2026-01-01T00:00:01Z"]), to: file)
        var committed = false
        do {
            _ = try UsageJSONLParser.readIncrementally(fileURL: file, source: "claude-code", fileIdentity: file.lastPathComponent,
                previousCheckpoint: state.checkpoint, stateLookup: { key in
                    if key == "stream-cursor" { return state.values[key] }
                    throw Failure.assertion("injected state read failure")
                }, onBatch: { _ in committed = true })
            throw Failure.assertion("storage error must escape")
        } catch Failure.assertion(let message) {
            try require(message == "injected state read failure", "expected storage failure")
        }
        try require(!committed, "failed state read cannot publish a batch")
    }

    static func verifyEOFAndDiagnostics(_ directory: URL) throws {
        let file = directory.appendingPathComponent("eof.jsonl")
        let state = FixtureState()
        let meta = Data(try encode(["type": "session_meta", "timestamp": "2026-01-01T00:00:00Z", "payload": ["id": "eof-rollout"]]).dropLast())
        try append(meta, to: file)
        _ = try scan(file, source: "codex", state: state)
        try parity(meta, source: "codex", file: file, state: state)
        try require(state.checkpoint?.status == "complete", "complete EOF JSON is consumed without newline")
        let next = Data("\r\n".utf8) + (try encode(["type": "turn_context", "timestamp": "2026-01-01T00:00:01Z", "payload": ["model": "gpt-5", "turn_id": "eof-turn"]]))
        try append(next, to: file)
        _ = try scan(file, source: "codex", state: state)
        try parity(meta + next, source: "codex", file: file, state: state)

        let invalid = directory.appendingPathComponent("invalid.jsonl")
        let invalidState = FixtureState()
        try append(Data("{invalid}\n".utf8), to: invalid)
        _ = try scan(invalid, source: "claude-code", state: invalidState)
        try require(invalidState.checkpoint?.status == "degraded", "invalid complete line retains diagnostics status")
        let unchanged = try scan(invalid, source: "claude-code", state: invalidState)
        try require(unchanged.batchCount == 0, "unchanged degraded file does not repeatedly reparse")
    }
}
