import AgentPulseCore
import Foundation

enum RuntimeTrackingRecoveryVerification {
    static func run() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("runtime-large-resume-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        try fileManager.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer {
            do { try fileManager.removeItem(at: root) }
            catch { NSLog("Large runtime fixture cleanup failed: %@", String(describing: error)) }
        }
        let file = sessions.appendingPathComponent("rollout-large.jsonl")
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let model = "gpt-6-astra"
        let meta = try json(["type": "session_meta", "payload": [
            "id": "large-session", "thread_source": "user", "originator": "Codex Desktop", "cwd": root.path
        ]])
        try meta.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        do {
            // A sparse prefix exercises the bounded tail reader without allocating
            // or writing a large historical transcript.
            let coldHistoricalReadLimit = 96 * 1_024 * 1_024
            try handle.seek(toOffset: UInt64(coldHistoricalReadLimit + 1))
            try handle.write(contentsOf: Data([0x0A]))
            try handle.write(contentsOf: json(["type": "turn_context", "payload": ["model": model]]))
            try handle.write(contentsOf: token(100, at: now))
            try handle.close()
        } catch {
            do { try handle.close() }
            catch { NSLog("Large runtime fixture close failed: %@", String(describing: error)) }
            throw error
        }
        let changes = Changes()
        let collector = try CodexRuntimeMetricsCollector(configuration: .init(
            sessionsDirectories: [sessions], automationRoots: [], databaseURL: root.appendingPathComponent("test.sqlite"),
            claudeSessionsDirectory: root.appendingPathComponent("registry"),
            claudeProjectsDirectory: root.appendingPathComponent("projects")
        ), processScanner: Scanner(), fileChangeMonitor: changes)
        let cold = try await collector.scan(at: now)
        try require(cold.diagnostics.trackedLiveFiles == 1 && cold.taskBreakdown.codexDesktop.totalTasks == 1,
                    "large recent rollout must initially join live tracking")

        let trackingRetentionSeconds: TimeInterval = 1_800
        let expiredAt = now.addingTimeInterval(trackingRetentionSeconds + 1)
        let expired = try await collector.scan(at: expiredAt)
        try require(expired.diagnostics.trackedLiveFiles == 0 && expired.filesScanned == 1
                    && expired.taskBreakdown.codexDesktop.totalTasks == 1,
                    "expired oversized rollout must retain its cached task and signature-check eligibility")
        changes.requireRecovery()
        let rediscovered = try await collector.scan(at: expiredAt.addingTimeInterval(1))
        try require(rediscovered.filesScanned == 1 && rediscovered.diagnostics.trackedLiveFiles == 0,
                    "subsequent discovery must preserve expired oversized rollouts without promoting old data")

        let reconciliationInterval: TimeInterval = 300
        let resumedAt = expiredAt.addingTimeInterval(reconciliationInterval)
        try append(try token(280, at: resumedAt), to: file, modifiedAt: resumedAt)
        let resumed = try await collector.scan(at: resumedAt)
        try require(resumed.diagnostics.trackedLiveFiles == 1 && resumed.liveRate.tokensInWindow == 0,
                    "oversized rollout must resume without notification and without replaying history")
        let outputAt = resumedAt.addingTimeInterval(1)
        try append(try token(460, at: outputAt), to: file, modifiedAt: outputAt)
        let output = try await collector.scan(at: outputAt)
        try require(output.liveRate.modelTokensInWindow[model] == 180 && output.liveRate.tps == 1,
                    "resumed oversized rollout must attribute exactly its next 180 output tokens")
        try require(output.diagnostics.discoveryFullScans == 2,
                    "signature recovery must not perform another discovery scan")

        try fileManager.removeItem(at: file)
        changes.requireRecovery()
        let removed = try await collector.scan(at: outputAt.addingTimeInterval(1))
        try require(removed.filesScanned == 0 && removed.diagnostics.trackedLiveFiles == 0
                    && removed.taskBreakdown.codexDesktop.totalTasks == 0,
                    "deleted oversized rollout must leave the retained cache and task aggregate")
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    private static func token(_ count: Int, at date: Date) throws -> Data {
        try json(["timestamp": ISO8601DateFormatter().string(from: date), "type": "event_msg",
                  "payload": ["type": "token_count", "info": ["total_token_usage": ["output_tokens": count]]]])
    }

    private static func append(_ data: Data, to file: URL, modifiedAt: Date) throws {
        let handle = try FileHandle(forWritingTo: file)
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            do { try handle.close() }
            catch { NSLog("Large runtime fixture close failed: %@", String(describing: error)) }
            throw error
        }
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: file.path)
    }

    private struct Scanner: ProcessScanning {
        func scan() throws -> [RunningProcess] { [] }
    }

    private final class Changes: RuntimeFileChangeMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private var recovery = false
        func requireRecovery() { lock.withLock { recovery = true } }
        func takeChanges() -> RuntimeFileChanges {
            lock.withLock {
                defer { recovery = false }
                return RuntimeFileChanges(requiresFullRescan: recovery)
            }
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AgentPulseCollectorVerification.VerificationError.failed(message) }
    }
}
