import Foundation
import AgentPulseCore

func verifyOutputReasoningMerge() throws {
    let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    for source in ["claude", "home-machine"] {
        for order in permutations {
            try OutputReasoningMergeFixture(source: source).verify(order: order)
        }
    }
    for strategy in [UsageEvent.MergeStrategy.overwrite, .cumulativeMax] {
        try OutputReasoningMergeFixture(source: "claude").verifyOtherCounters(strategy: strategy)
    }
    print("Output/reasoning merge: PASS (parent/subagent/resume, 6 orders, built-in/custom source, full/incremental, growth, counters)")
}

private struct OutputReasoningMergeFixture {
    let source: String
    private let hostname = "output-merge-host"
    private let project = "output-merge-project"
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    private let backgroundCount = 12

    private func parsed(file: String, output: Int64 = 100, thinking: String = "aaaa",
                        text: String = "bbbb", isSubagent: Bool = false) throws -> ParsedUsageFile {
        let object: [String: Any] = [
            "type": "assistant", "sessionId": "shared-session", "uuid": "shared-line",
            "cwd": "/fixture/\(project)", "timestamp": "2027-01-15T08:00:00Z",
            "message": [
                "id": "shared-message", "model": "claude-sonnet-4",
                "content": [["type": "thinking", "thinking": thinking], ["type": "text", "text": text]],
                "usage": ["input_tokens": 10, "output_tokens": output]
            ]
        ]
        return UsageJSONLParser.parse(
            data: try JSONSerialization.data(withJSONObject: object), source: source,
            fileIdentity: file, modifiedAt: timestamp, isSubagent: isSubagent
        )
    }

    private func record(_ parsed: ParsedUsageFile, in ledger: UsageLedgerStore) throws {
        try ledger.record(events: parsed.events, sessionEvents: parsed.sessionEvents,
                          checkpoint: parsed.checkpoint, hostname: hostname)
    }

    private func seed(_ ledger: UsageLedgerStore) throws {
        let file = "background-file"
        let events = (0..<backgroundCount).map { index in
            UsageEvent(id: "background-\(index)", source: source, model: "background", project: "background",
                       timestamp: timestamp, counts: UsageTokenCounts(output: 1), sessionHash: "background",
                       sourceFileHash: file)
        }
        try ledger.record(events: events, checkpoint: checkpoint(file: file), hostname: hostname)
        try ledger.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
    }

    private func checkpoint(file: String) -> UsageFileCheckpoint {
        UsageFileCheckpoint(fileID: file, source: source, pathHash: file, offset: 1, size: 1,
                            modifiedAt: timestamp, parserVersion: UsageJSONLParser.parserVersion, status: "complete")
    }

    private func counts(_ ledger: UsageLedgerStore) throws -> UsageTokenCounts {
        let matches = try ledger.buckets(hostname: hostname).filter { $0.project == project }
        try require(matches.count == 1, "one logical response must produce one bucket")
        return matches[0].counts
    }

    private func finalize(_ automatic: UsageLedgerStore, _ full: UsageLedgerStore,
                          expected: UsageTokenCounts) throws {
        var expected = expected
        expected.reportedTotal = expected.total
        let result = try automatic.finalizeDerived(hostname: hostname)
        let fullResult = try full.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
        try require(automatic.lastFinalizeDiagnostics.strategy == "incremental", "fixture must exercise scoped SQL")
        try require(result.reportingEligible && fullResult.reportingEligible, "different splits must not block reporting")
        try require(try counts(automatic) == expected, "incremental output pair differs: \(try counts(automatic)) != \(expected)")
        try require(try counts(full) == expected, "full output pair differs: \(try counts(full)) != \(expected)")
    }

    func verify(order: [Int]) throws {
        let automatic = try UsageLedgerStore(path: ":memory:")
        let full = try UsageLedgerStore(path: ":memory:")
        try seed(automatic)
        try seed(full)
        let observations = [
            try parsed(file: "parent"),
            try parsed(file: "subagent", isSubagent: true),
            try parsed(file: "resume", thinking: "aaa", text: "b")
        ]
        try require(observations.allSatisfy { $0.events.count == 1 && $0.diagnostics.isEmpty }, "invalid parser fixture")
        try require(Set(observations.map { $0.events[0].id }).count == 1, "parser must identify the same response across files")
        try require(observations[0].events[0].counts == UsageTokenCounts(input: 10, output: 50, reasoningOutput: 50),
                    "parent must split output equally")
        try require(observations[1].events[0].counts == UsageTokenCounts(input: 10, output: 100),
                    "subagent must retain unsplit output")
        var reasoning: Int64 = 0
        for index in order {
            for ledger in [automatic, full] { try record(observations[index], in: ledger) }
            reasoning = max(reasoning, observations[index].events[0].counts.reasoningOutput)
            try finalize(automatic, full, expected: UsageTokenCounts(input: 10, output: 100 - reasoning, reasoningOutput: reasoning))
        }

        // The newest unsplit observation contains more output than every prior split.
        for ledger in [automatic, full] { try record(try parsed(file: "subagent", output: 140, isSubagent: true), in: ledger) }
        try finalize(automatic, full, expected: UsageTokenCounts(input: 10, output: 140))
        for ledger in [automatic, full] { try record(try parsed(file: "parent", output: 140), in: ledger) }
        try finalize(automatic, full, expected: UsageTokenCounts(input: 10, output: 70, reasoningOutput: 70))

        // A replay with a larger reasoning share but smaller total cannot displace real growth.
        for ledger in [automatic, full] { try record(observations[2], in: ledger) }
        try finalize(automatic, full, expected: UsageTokenCounts(input: 10, output: 70, reasoningOutput: 70))
        let before = try counts(automatic)
        try automatic.finalizeDerived(hostname: hostname, strategy: .fullRecompute)
        try require(try counts(automatic) == before, "repeated full derivation must be idempotent")
    }

    func verifyOtherCounters(strategy: UsageEvent.MergeStrategy) throws {
        let automatic = try UsageLedgerStore(path: ":memory:")
        let full = try UsageLedgerStore(path: ":memory:")
        try seed(automatic)
        try seed(full)
        let observations = [
            UsageTokenCounts(input: 12, output: 50, cachedInput: 18, cacheCreationInput: 31, reasoningOutput: 50, reportedTotal: 161),
            UsageTokenCounts(input: 10, output: 140, cachedInput: 22, cacheCreationInput: 28, reportedTotal: 200)
        ]
        for (index, observation) in observations.enumerated() {
            let file = "counter-file-\(index)"
            let event = UsageEvent(id: "counter-event", source: source, model: "claude-sonnet-4", project: project,
                                   timestamp: timestamp, counts: observation, sessionHash: "counter-session",
                                   sourceFileHash: file, mergeStrategy: strategy,
                                   skillCounts: ["skill": index + 1], mcpCounts: ["server": 2 - index])
            for ledger in [automatic, full] {
                try ledger.record(events: [event], checkpoint: checkpoint(file: file), hostname: hostname)
            }
        }
        try finalize(automatic, full, expected: UsageTokenCounts(input: 12, output: 140, cachedInput: 22,
                                                               cacheCreationInput: 31, reportedTotal: 200))
        let bucket = try automatic.buckets(hostname: hostname).first { $0.project == project }
        try require(bucket?.skillCounts == ["skill": 2] && bucket?.mcpCounts == ["server": 2],
                    "tool counters must retain per-counter maxima")
    }

    private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw UsageLedgerError.sqlite("Output/reasoning merge: \(message)") }
    }
}
