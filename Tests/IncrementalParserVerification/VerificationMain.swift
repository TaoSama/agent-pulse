import AgentPulseCore
import Darwin
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
    static let longTextBytes = 8 * 1024 * 1024

    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try verifyNonRegularFiles(directory)
            try verifyLegacyCreationDates(directory)
            try verifyCodex(directory)
            try verifyClaude(directory)
            try verifyMetadataBoundaries(directory)
            try verifyEOFAndDiagnostics(directory)
            try verifyLargeBatch(directory)
            try verifyLongRecordAndBoundedAppend(directory)
            try verifyLongCodexMetadata(directory)
            try verifyConcurrentMutations(directory)
            try verifyFailurePropagation(directory)
        } catch {
            try FileManager.default.removeItem(at: directory)
            throw error
        }
        try FileManager.default.removeItem(at: directory)
        print("Incremental parser verification passed: append, restart, partial line, truncation, cross-batch state, privacy, storage error, 8 MiB record, bounded append, concurrent mutations, non-regular file rejection")
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

    static func scan(_ file: URL, source: String, state: FixtureState,
                     checkCancellation: () throws -> Void = {}) throws -> UsageIncrementalReadResult {
        try UsageJSONLParser.readIncrementally(fileURL: file, source: source, fileIdentity: file.lastPathComponent,
                                              previousCheckpoint: state.checkpoint,
                                              stateLookup: { state.values[$0] }, onBatch: { try state.apply($0) },
                                              checkCancellation: checkCancellation)
    }

    static func parity(_ data: Data, source: String, file: URL, state: FixtureState, context: String = "") throws {
        let parsed = UsageJSONLParser.parse(data: data, source: source, fileIdentity: file.lastPathComponent)
        try require(state.events == Dictionary(parsed.events.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }), "\(context) token/tool parity")
        try require(state.sessions == Dictionary(parsed.sessionEvents.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }), "\(context) session parity")
        try require(state.edits == Dictionary(parsed.editEntries.map { ($0.toolUseID, $0) }, uniquingKeysWith: { _, b in b }), "\(context) edit parity")
    }

    static func claudeRecord(_ id: String, output: Int, text: String = "answer",
                             tools: [[String: Any]] = []) throws -> Data {
        try encode(["type": "assistant", "uuid": id, "sessionId": "session", "timestamp": "2026-01-01T00:00:00Z",
                    "message": ["id": id, "model": "claude-opus-4", "usage": ["output_tokens": output],
                                "content": [["type": "text", "text": text]] + tools]])
    }

    static func setCursorCreationDate(_ created: Date, state: FixtureState) throws {
        guard let cursorData = state.values["stream-cursor"],
              var cursor = try JSONSerialization.jsonObject(with: cursorData) as? [String: Any] else {
            throw Failure.assertion("legacy cursor fixture requires cursor state")
        }
        cursor["creationDate"] = created.timeIntervalSinceReferenceDate
        state.values["stream-cursor"] = try JSONSerialization.data(withJSONObject: cursor)
    }

    static func verifyLegacyCreationDates(_ directory: URL) throws {
        let file = directory.appendingPathComponent("legacy-date.jsonl")
        let state = FixtureState()
        var data = try claudeRecord("baseline", output: 5, text: String(repeating: "p", count: 1024))
        try data.write(to: file)
        _ = try scan(file, source: "claude-code", state: state)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let created = attributes[.creationDate] as? Date else {
            throw Failure.assertion("legacy date fixture requires FileManager creation date")
        }
        var status = stat()
        guard lstat(file.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let seconds = Double(status.st_birthtimespec.tv_sec)
        let fraction = Double(status.st_birthtimespec.tv_nsec) / 1_000_000_000
        let referenceSeconds = created.timeIntervalSinceReferenceDate
        let variants = [
            created,
            Date(timeIntervalSince1970: seconds + fraction),
            Date(timeIntervalSinceReferenceDate: seconds - Date.timeIntervalBetween1970AndReferenceDate + fraction),
            Date(timeIntervalSinceReferenceDate: referenceSeconds.nextDown),
            Date(timeIntervalSinceReferenceDate: referenceSeconds.nextUp)
        ]
        for (index, variant) in variants.enumerated() {
            try setCursorCreationDate(variant, state: state)
            let extra = try claudeRecord("date-\(index)", output: 7)
            try append(extra, to: file); data += extra
            let result = try scan(file, source: "claude-code", state: state)
            try require(result.bytesRead == Int64(extra.count), "legacy date variant \(index) resumes without historical reread")
            try parity(data, source: "claude-code", file: file, state: state, context: "legacy date variant \(index)")
        }
        let incompatibleBirthDateDifference: TimeInterval = 0.000002
        try setCursorCreationDate(created.addingTimeInterval(incompatibleBirthDateDifference), state: state)
        let extra = try claudeRecord("changed-birth-date", output: 9)
        try append(extra, to: file); data += extra
        let rebuilt = try scan(file, source: "claude-code", state: state)
        try require(rebuilt.bytesRead == Int64(data.count), "birth date difference above rounding tolerance rebuilds the file")
        try parity(data, source: "claude-code", file: file, state: state, context: "incompatible birth date rebuild")
        print("Legacy creation dates verified: \(variants.count) rounding variants, incompatible date rebuild")
    }

    static func verifyNonRegularFiles(_ directory: URL) throws {
        let fifo = directory.appendingPathComponent("input-fifo.jsonl")
        let folder = directory.appendingPathComponent("input-directory.jsonl")
        let target = directory.appendingPathComponent("symlink-target.jsonl")
        let symlink = directory.appendingPathComponent("input-symlink.jsonl")
        let ownerReadWrite = mode_t(S_IRUSR | S_IWUSR)
        guard Darwin.mkfifo(fifo.path, ownerReadWrite) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try claudeRecord("symlink-target", output: 7).write(to: target)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        for file in [fifo, folder, symlink] {
            let state = FixtureState()
            do {
                // No FIFO writer exists: a blocking open would stall before the type check.
                _ = try scan(file, source: "claude-code", state: state)
                throw Failure.assertion("non-regular input must be rejected: \(file.lastPathComponent)")
            } catch UsageIncrementalReadError.invalidFile {
                try require(file != symlink, "symlink must be rejected by no-follow open")
            } catch let error as POSIXError {
                try require(file == symlink && error.code == .ELOOP, "expected no-follow symlink error")
            }
            try require(state.batchCount == 0 && state.checkpoint == nil,
                        "non-regular input cannot publish a batch or checkpoint")
        }
    }

    static func verifyLongRecordAndBoundedAppend(_ directory: URL) throws {
        let file = directory.appendingPathComponent("long-record.jsonl")
        let state = FixtureState()
        let longRecord = try claudeRecord("long", output: 17, text: String(repeating: "z", count: longTextBytes), tools: [
            ["type": "tool_use", "id": "long-edit", "name": "Edit",
             "input": ["file_path": "/tmp/project/f", "old_string": "old", "new_string": "new\nextra"]]
        ])
        let initial = try claudeRecord("before", output: 3)
        let firstPartialBytes = longRecord.count / 3
        let secondPartialBytes = longRecord.count * 2 / 3
        try (initial + longRecord.prefix(firstPartialBytes)).write(to: file)
        _ = try scan(file, source: "claude-code", state: state)
        try require(state.checkpoint?.offset == Int64(initial.count), "long partial record keeps the previous committed boundary")
        try parity(initial, source: "claude-code", file: file, state: state, context: "first long partial")
        let unchanged = try scan(file, source: "claude-code", state: state)
        try require(unchanged.bytesRead == 0 && unchanged.batchCount == 0, "unchanged long partial is skipped")

        try append(Data(longRecord[firstPartialBytes..<secondPartialBytes]), to: file)
        _ = try scan(file, source: "claude-code", state: state)
        try require(state.checkpoint?.offset == Int64(initial.count), "repeated incomplete append cannot consume the long record")
        try parity(initial, source: "claude-code", file: file, state: state, context: "second long partial")
        try append(Data(longRecord[secondPartialBytes..<longRecord.count - 1]), to: file)
        let completed = try scan(file, source: "claude-code", state: state)
        let withoutNewline = initial + longRecord.dropLast()
        try require(completed.committedOffset == Int64(withoutNewline.count), "complete 8 MiB EOF JSON is consumed without newline")
        try parity(withoutNewline, source: "claude-code", file: file, state: state, context: "complete long EOF")

        let result = try encode(["type": "user", "uuid": "long-result", "sessionId": "session",
                                 "timestamp": "2026-01-01T00:00:01Z",
                                 "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "long-edit", "is_error": false]]]])
        let extensionData = Data("\r\n".utf8) + result + (try claudeRecord("after", output: 5))
        try append(extensionData, to: file)
        let appended = try scan(file, source: "claude-code", state: state)
        try require(appended.bytesRead == Int64(extensionData.count), "tiny append after 8 MiB history reads only the appended payload")
        try require(appended.batchCount == 1, "tiny append publishes one batch")
        try parity(withoutNewline + extensionData, source: "claude-code", file: file, state: state, context: "long record plus CRLF and edit result")
        try require(state.edits.count == 1, "edit in long record is counted after its successful result")
        try require(state.events.count == 3 && !state.sessions.isEmpty, "long record retains token and session events")
        print("Long record verified: history=\(withoutNewline.count) bytes, appended=\(extensionData.count) bytes, read=\(appended.bytesRead) bytes")

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard let created = attributes[.creationDate] as? Date else {
            throw Failure.assertion("legacy cursor fixture requires creation date")
        }
        try setCursorCreationDate(created, state: state)
        let legacyAppend = try claudeRecord("legacy-append", output: 9)
        try append(legacyAppend, to: file)
        let legacyResult = try scan(file, source: "claude-code", state: state)
        try require(legacyResult.bytesRead == Int64(legacyAppend.count), "legacy FileManager creation date cursor resumes without historical reread")
        try parity(withoutNewline + extensionData + legacyAppend, source: "claude-code", file: file, state: state, context: "legacy checkpoint append")
        print("Legacy cursor verified: appended=\(legacyAppend.count) bytes, read=\(legacyResult.bytesRead) bytes")
    }

    static func verifyLongCodexMetadata(_ directory: URL) throws {
        let file = directory.appendingPathComponent("long-codex-metadata.jsonl")
        let state = FixtureState()
        let message = try encode(["type": "event_msg", "timestamp": "2026-01-01T00:00:00Z",
                                  "payload": ["type": "user_message", "message": String(repeating: "z", count: longTextBytes)]])
        let token = try encode(["type": "event_msg", "timestamp": "2026-01-01T00:00:01Z",
                                "payload": ["type": "token_count", "info": ["last_token_usage": ["output_tokens": 9]]]])
        let metadata = try encode(["type": "session_meta", "timestamp": "2026-01-01T00:00:02Z",
                                   "payload": ["id": "long-metadata-rollout", "cwd": "/tmp/project"]])
        let data = message + token + metadata
        try data.write(to: file)
        let result = try scan(file, source: "codex", state: state)
        try require(result.committedOffset == Int64(data.count), "long Codex record and late metadata are fully consumed")
        try parity(data, source: "codex", file: file, state: state, context: "8 MiB Codex record before metadata")
        try require(!state.events.isEmpty && !state.sessions.isEmpty, "long Codex record retains token and session events")
    }

    static func verifyConcurrentMutations(_ directory: URL) throws {
        let original = try claudeRecord("original", output: 11, text: String(repeating: "p", count: 1024))
        let rewritten = try claudeRecord("original", output: 22, text: String(repeating: "p", count: 1024))
        try require(original.count == rewritten.count, "rewrite fixture preserves file length")
        let baseline = try claudeRecord("baseline", output: 5)
        let suffix = try claudeRecord("later", output: 3)
        // The small record is read after check one; checks two and three surround parsing.
        let injectionChecks = [2, 3]
        let cases = ["rewrite", "replace", "truncate"].flatMap { mutation in injectionChecks.map { (mutation, $0) } }
        for (mutation, injectionCheck) in cases {
            let file = directory.appendingPathComponent("during-\(mutation)-\(injectionCheck).jsonl")
            let state = FixtureState()
            try baseline.write(to: file)
            _ = try scan(file, source: "claude-code", state: state)
            let checkpointBeforeMutation = state.checkpoint
            let batchesBeforeMutation = state.batchCount
            try append(original, to: file)
            let replacementRow: Data
            switch mutation {
            case "truncate": replacementRow = try claudeRecord("short", output: 7)
            case "replace": replacementRow = original
            default: replacementRow = rewritten
            }
            let replacement = baseline + replacementRow
            var checks = 0
            var rejected = false
            do {
                _ = try scan(file, source: "claude-code", state: state, checkCancellation: {
                    checks += 1
                    guard checks == injectionCheck else { return }
                    if mutation == "replace" {
                        try replacement.write(to: file, options: .atomic)
                    } else {
                        let handle = try FileHandle(forWritingTo: file)
                        defer { handle.closeFile() }
                        try handle.write(contentsOf: replacement)
                        if mutation == "truncate" { try handle.truncate(atOffset: UInt64(replacement.count)) }
                    }
                })
            } catch UsageIncrementalReadError.fileChangedDuringRead {
                rejected = true
            }
            let batchesAfterMutation = state.batchCount
            let checkpointAfterMutation = state.checkpoint
            try require(checks >= injectionCheck, "\(mutation) mutation hook \(injectionCheck) was reached")
            try append(suffix, to: file)
            _ = try scan(file, source: "claude-code", state: state)
            try parity(replacement + suffix, source: "claude-code", file: file, state: state,
                       context: "\(mutation) at check \(injectionCheck) during read then append")
            try require(rejected && batchesAfterMutation == batchesBeforeMutation,
                        "\(mutation) during read must reject before publishing stale data")
            try require(checkpointAfterMutation == checkpointBeforeMutation, "\(mutation) rejection preserves the last committed checkpoint")
        }

        let file = directory.appendingPathComponent("during-append.jsonl")
        let state = FixtureState()
        try original.write(to: file)
        var checks = 0
        let concurrent = try scan(file, source: "claude-code", state: state, checkCancellation: {
            checks += 1
            if checks == 2 { try append(suffix, to: file) }
        })
        try require(checks >= 2, "concurrent append hook was reached")
        try require(concurrent.bytesRead == Int64(original.count) && concurrent.committedOffset == Int64(original.count),
                    "concurrent append preserves the starting file boundary")
        try parity(original, source: "claude-code", file: file, state: state, context: "concurrent append first scan")
        let next = try scan(file, source: "claude-code", state: state)
        try require(next.bytesRead == Int64(suffix.count), "next scan consumes only concurrent appended bytes")
        try parity(original + suffix, source: "claude-code", file: file, state: state, context: "concurrent append recovery")
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
