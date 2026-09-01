import AgentPulseCore
import Foundation

// Deterministic verification of CodexRuntimeMetricsCollector's discovery and
// caching behaviour. Everything runs against a purpose-built fixture tree and a
// throwaway database under the system temporary directory, so the result never
// depends on how much history the current machine happens to have accumulated
// and never touches the production ledger. Run with:
// swift run AgentPulseCollectorVerification
@main
struct AgentPulseCollectorVerification {
    static func main() async throws {
        try await withFixture(named: "cold-discovery", verifyColdScanDiscoversRecentSessions)
        try await withFixture(named: "warm-rescan", verifyWarmRescanReusesCache)
        try await withFixture(named: "exclusions", verifyStaleAndEmptyFilesExcluded)
        try await withFixture(named: "unreadable", verifyUnreadableFilesDoNotFailScan)
        print("AgentPulseCollector verification passed")
    }

    /// Each check runs against its own sessions tree and database so discovery
    /// counts stay exact and independent of execution order.
    private static func withFixture(
        named label: String,
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try Fixture(label: label)
        defer { fixture.cleanUp() }
        try await body(fixture)
    }

    // MARK: - Checks

    /// A cold scan must see every recent non-empty JSONL file in the fixture.
    private static func verifyColdScanDiscoversRecentSessions(_ fixture: Fixture) async throws {
        let collector = try fixture.makeCollector()
        try fixture.writeRecentSession(named: "rollout-alpha.jsonl", outputTokens: 120)
        try fixture.writeRecentSession(named: "rollout-beta.jsonl", outputTokens: 80)

        let metrics = try await collector.scan(at: fixture.now)

        try expect(
            metrics.diagnostics.discoveredJSONLFiles == 2,
            "cold scan should discover both fixture sessions, got \(metrics.diagnostics.discoveredJSONLFiles)"
        )
        try expect(
            metrics.diagnostics.trackedLiveFiles == 2,
            "cold scan should track both recent sessions, got \(metrics.diagnostics.trackedLiveFiles)"
        )
        try expect(
            metrics.unreadableFiles == 0,
            "readable fixture must not report unreadable files, got \(metrics.unreadableFiles)"
        )
    }

    /// An unchanged second scan must serve every tracked file from cache rather
    /// than re-parsing it. This is the property that keeps steady-state polling
    /// cheap, and it is what a wall-clock timing threshold only approximated.
    private static func verifyWarmRescanReusesCache(_ fixture: Fixture) async throws {
        let collector = try fixture.makeCollector()
        try fixture.writeRecentSession(named: "rollout-warm.jsonl", outputTokens: 200)

        _ = try await collector.scan(at: fixture.now)
        let warm = try await collector.scan(at: fixture.now.addingTimeInterval(1))

        try expect(
            warm.filesFullyParsed == 0,
            "unchanged rescan must not fully parse any file, got \(warm.filesFullyParsed)"
        )
        try expect(
            warm.filesReusedFromCache >= 1,
            "unchanged rescan must reuse the cached file, got \(warm.filesReusedFromCache)"
        )
    }

    /// Files older than the recency window and zero-byte files must be counted as
    /// excluded instead of being tracked as live sessions.
    private static func verifyStaleAndEmptyFilesExcluded(_ fixture: Fixture) async throws {
        let collector = try fixture.makeCollector()
        try fixture.writeRecentSession(named: "rollout-live.jsonl", outputTokens: 10)
        try fixture.writeStaleSession(named: "rollout-stale.jsonl")
        try fixture.writeEmptySession(named: "rollout-empty.jsonl")

        let metrics = try await collector.scan(at: fixture.now)

        try expect(
            metrics.diagnostics.excludedStaleFiles == 1,
            "stale session must be excluded once, got \(metrics.diagnostics.excludedStaleFiles)"
        )
        try expect(
            metrics.diagnostics.excludedEmptyFiles == 1,
            "empty session must be excluded once, got \(metrics.diagnostics.excludedEmptyFiles)"
        )
        try expect(
            metrics.diagnostics.trackedLiveFiles == 1,
            "only the recent non-empty session may be tracked, got \(metrics.diagnostics.trackedLiveFiles)"
        )
    }

    /// A file the process cannot read must be reported through unreadableFiles
    /// rather than aborting the whole scan.
    private static func verifyUnreadableFilesDoNotFailScan(_ fixture: Fixture) async throws {
        let collector = try fixture.makeCollector()
        try fixture.writeRecentSession(named: "rollout-readable.jsonl", outputTokens: 30)
        let blocked = try fixture.writeRecentSession(named: "rollout-blocked.jsonl", outputTokens: 30)
        try fixture.makeUnreadable(blocked)

        let metrics = try await collector.scan(at: fixture.now)

        try expect(
            metrics.diagnostics.discoveredJSONLFiles == 2,
            "discovery must still enumerate the unreadable file, got \(metrics.diagnostics.discoveredJSONLFiles)"
        )
        try expect(
            metrics.unreadableFiles >= 1,
            "unreadable file must be surfaced, got \(metrics.unreadableFiles)"
        )
    }

    // MARK: - Fixture

    /// Isolated sessions tree plus database directory. Both live under a unique
    /// temporary root so concurrent runs and the real ledger never interfere.
    private struct Fixture {
        /// Well inside CodexRuntimeMetricsCollector's 15 minute recency window.
        private static let recentAge: TimeInterval = 60
        /// Comfortably outside that window.
        private static let staleAge: TimeInterval = 60 * 60
        private static let readablePermissions = 0o600
        private static let unreadablePermissions = 0o000

        let root: URL
        let sessionsDirectory: URL
        let now = Date()

        private let fileManager = FileManager.default

        init(label: String) throws {
            root = fileManager.temporaryDirectory
                .appendingPathComponent(
                    "agent-pulse-collector-verification-\(label)-\(UUID().uuidString)",
                    isDirectory: true
                )
            sessionsDirectory = root.appendingPathComponent("sessions", isDirectory: true)
            try fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }

        func cleanUp() {
            // Restore permissions first so the deliberately blocked fixture file
            // can still be removed.
            if let contents = try? fileManager.subpathsOfDirectory(atPath: sessionsDirectory.path) {
                for relative in contents {
                    let path = sessionsDirectory.appendingPathComponent(relative).path
                    try? fileManager.setAttributes(
                        [.posixPermissions: Self.readablePermissions],
                        ofItemAtPath: path
                    )
                }
            }
            try? fileManager.removeItem(at: root)
        }

        func makeCollector() throws -> CodexRuntimeMetricsCollector {
            let directory = root.appendingPathComponent("store", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = CodexRuntimeMetricsConfiguration(
                sessionsDirectories: [sessionsDirectory],
                automationRoots: [],
                databaseURL: directory.appendingPathComponent("verification.sqlite", isDirectory: false),
                claudeSessionsDirectory: directory.appendingPathComponent("claude-sessions", isDirectory: true),
                claudeProjectsDirectory: directory.appendingPathComponent("claude-projects", isDirectory: true)
            )
            return try CodexRuntimeMetricsCollector(configuration: configuration)
        }

        @discardableResult
        func writeRecentSession(named name: String, outputTokens: Int) throws -> URL {
            let url = try write(name: name, lines: [sessionLine(outputTokens: outputTokens)])
            try touch(url, age: Self.recentAge)
            return url
        }

        @discardableResult
        func writeStaleSession(named name: String) throws -> URL {
            let url = try write(name: name, lines: [sessionLine(outputTokens: 5)])
            try touch(url, age: Self.staleAge)
            return url
        }

        @discardableResult
        func writeEmptySession(named name: String) throws -> URL {
            let url = try write(name: name, lines: [])
            try touch(url, age: Self.recentAge)
            return url
        }

        func makeUnreadable(_ url: URL) throws {
            try fileManager.setAttributes(
                [.posixPermissions: Self.unreadablePermissions],
                ofItemAtPath: url.path
            )
        }

        private func write(name: String, lines: [String]) throws -> URL {
            let url = sessionsDirectory.appendingPathComponent(name, isDirectory: false)
            let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
            guard let data = body.data(using: .utf8) else {
                throw VerificationError.failed("fixture \(name) is not valid UTF-8")
            }
            try data.write(to: url, options: .atomic)
            return url
        }

        private func touch(_ url: URL, age: TimeInterval) throws {
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: url.path
            )
        }

        private func sessionLine(outputTokens: Int) -> String {
            let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-Self.recentAge))
            let usage = "{\"input_tokens\":10,\"cached_input_tokens\":0,"
                + "\"output_tokens\":\(outputTokens),\"reasoning_output_tokens\":0,"
                + "\"total_tokens\":\(outputTokens + 10)}"
            let info = "{\"model_context_window\":200000,\"last_token_usage\":" + usage
                + ",\"total_token_usage\":" + usage + "}"
            return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\","
                + "\"payload\":{\"type\":\"token_count\",\"info\":" + info + "}}"
        }
    }

    // MARK: - Assertions

    enum VerificationError: Error, CustomStringConvertible {
        case failed(String)
        var description: String { if case let .failed(message) = self { return message }; return "failed" }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw VerificationError.failed(message) }
    }
}
