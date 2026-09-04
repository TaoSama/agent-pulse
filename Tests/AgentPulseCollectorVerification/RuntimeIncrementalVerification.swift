import AgentPulseCore
import Foundation

/// Work-count assertions verify bounded parsing without machine-speed thresholds.
enum RuntimeIncrementalVerification {
    static func run() async throws {
        try await withFixture("desktop", verifyDesktopAppendRecovery)
        try await withFixture("models", verifySingleDecodeAndModelSearch)
        try await withFixture("aggregate", verifyAggregateReplacementAndRemoval)
        try await withFixture("discovery", verifyImmediateDiscoveryAndRecovery)
        try await withFixture("notifications", verifyRealNotifications)
        try await withFixture("historical-change", verifyHistoricalChangeAtTrackingCapacity)
        try await withFixture("permission-recovery", verifySubdirectoryPermissionRecovery)
        try await withFixture("alias-events", verifyAliasChangesAndDeletion)
    }

    private static func withFixture(_ name: String, _ body: (Fixture) async throws -> Void) async throws {
        let fixture = try Fixture(name)
        do {
            try await body(fixture)
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            try FileManager.default.removeItem(at: fixture.root)
            throw error
        }
    }

    private static func verifyDesktopAppendRecovery(_ fixture: Fixture) async throws {
        let url = fixture.projects.appendingPathComponent("desktop.jsonl")
        let user = try fixture.record(type: "user", session: "desktop", desktop: true)
        let ended = try fixture.record(type: "assistant", session: "desktop", endTurn: true)
        // A large CLI-like prefix is valid history; entrypoint may appear later.
        let history = String(repeating: "{\"type\":\"progress\"}\n", count: 2_000)
        try fixture.write(history + user, to: url)
        let collector = try fixture.collector()
        let first = try await collector.scan(at: fixture.now)
        try require(first.taskBreakdown.claudeDesktop.activeTasks == 1, "desktop user must be active")
        try require(first.diagnostics.claudeDesktopBytesRead == (history + user).utf8.count,
                    "desktop baseline reads its history once")
        try fixture.append(ended, to: url)
        let second = try await collector.scan(at: fixture.time(1))
        try require(second.taskBreakdown.claudeDesktop.activeTasks == 0, "end_turn visible on next second")
        try require(second.diagnostics.claudeDesktopBytesRead == ended.utf8.count,
                    "desktop append must not reread history")
        try require(second.diagnostics.discoveryFullScans == 1 && second.diagnostics.discoveryMetadataReads == 1,
                    "tracked append updates one metadata entry without full discovery")
        let warm = try await collector.scan(at: fixture.time(2))
        try require(warm.diagnostics.claudeDesktopBytesRead == 0, "unchanged desktop reads no bytes")

        let half = user.index(user.startIndex, offsetBy: user.count / 2)
        try fixture.append(String(user[..<half]), to: url)
        let partial = try await collector.scan(at: fixture.time(3))
        try require(partial.taskBreakdown.claudeDesktop.activeTasks == 0, "partial row cannot change lifecycle")
        try fixture.append(String(user[half...]), to: url)
        let completed = try await collector.scan(at: fixture.time(4))
        try require(completed.taskBreakdown.claudeDesktop.activeTasks == 1, "partial row must recover")

        try fixture.write(ended, to: url)
        let replaced = try await collector.scan(at: fixture.time(5))
        try require(replaced.taskBreakdown.claudeDesktop.totalTasks == 0,
                    "atomic replacement cannot inherit desktop identity")
        try fixture.append(user, to: url)
        let lateIdentity = try await collector.scan(at: fixture.time(6))
        try require(lateIdentity.taskBreakdown.claudeDesktop.totalTasks == 1,
                    "late entrypoint must promote an existing file")

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(ended.utf8))
        try handle.close()
        let truncated = try await collector.scan(at: fixture.time(7))
        try require(truncated.taskBreakdown.claudeDesktop.totalTasks == 0,
                    "same-inode truncation resets desktop identity")
        fixture.scanner.setRunning(false)
        let closed = try await collector.scan(at: fixture.time(8))
        try require(!closed.taskBreakdown.claudeDesktop.present, "process exit visible on next sample")
        fixture.scanner.setRunning(true)
        let reopened = try await collector.scan(at: fixture.time(9))
        try require(reopened.taskBreakdown.claudeDesktop.present, "process startup visible on next sample")
    }

    private static func verifySingleDecodeAndModelSearch(_ fixture: Fixture) async throws {
        let url = fixture.sessions.appendingPathComponent("rollout-model.jsonl")
        let text = String(repeating: "turn_context model ", count: 4_000)
        let noisy = try fixture.json(["type": "response_item", "payload": ["text": text]])
        let context = try fixture.json(["type": "turn_context", "payload": ["model": "authoritative"]])
        try fixture.write(try fixture.meta("model") + context + fixture.token(10, at: 0) + noisy, to: url)
        let collector = try fixture.collector()
        let initial = try await collector.scan(at: fixture.now)
        try require(initial.diagnostics.modelSearchRecordsDecoded <= 2,
                    "thousands of keyword matches in one row must decode that row once")
        let misleading = try fixture.json(["type": "response_item", "model": "untrusted"])
        let increment = try fixture.token(30, at: 1)
        try fixture.append(misleading + increment, to: url)
        let updated = try await collector.scan(at: fixture.time(1))
        try require(updated.diagnostics.runtimeJSONRecordsDecoded == 2, "each appended JSON row decoded once")
        try require(updated.liveRate.modelTokensInWindow["authoritative"] == 20,
                    "shared decode must preserve authoritative turn model")
        let expired = try await collector.scan(at: fixture.time(182))
        try require(expired.diagnostics.retainedTokenEvents == 0, "idle cached events expire from retained arrays")

        // An incomplete first read must preserve the consumed offset for its next append.
        let half = increment.index(increment.startIndex, offsetBy: increment.count / 2)
        let partialURL = fixture.sessions.appendingPathComponent("rollout-partial.jsonl")
        try fixture.write(try fixture.meta("partial") + context + fixture.token(10, at: 190)
                          + String(increment[..<half]), to: partialURL)
        _ = try await collector.scan(at: fixture.time(190))
        try fixture.append(String(increment[half...]), to: partialURL)
        let recovered = try await collector.scan(at: fixture.time(191))
        try require(recovered.filesReadIncrementally >= 1, "initial partial record must resume incrementally")
        try require(recovered.diagnostics.runtimeJSONRecordsDecoded == 1, "completed initial partial row decoded once")
    }

    private static func verifyAggregateReplacementAndRemoval(_ fixture: Fixture) async throws {
        let first = fixture.sessions.appendingPathComponent("rollout-first.jsonl")
        let second = fixture.sessions.appendingPathComponent("rollout-second.jsonl")
        let complete = try fixture.json(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "one"]])
        let duplicate = try fixture.meta("shared") + complete
        try fixture.write(duplicate, to: first)
        try fixture.write(duplicate, to: second)
        let collector = try fixture.collector()
        let initial = try await collector.scan(at: fixture.now)
        try require(initial.completed.value == 1 && initial.taskBreakdown.codexDesktop.totalTasks == 1,
                    "duplicate paths must not double count shared task or completion")
        try fixture.write(try fixture.meta("replacement"), to: first)
        let replaced = try await collector.scan(at: fixture.time(1))
        try require(replaced.completed.value == 1 && replaced.taskBreakdown.codexDesktop.totalTasks == 2,
                    "replacement removes only its own completion reference")
        try FileManager.default.removeItem(at: second)
        let removed = try await collector.scan(at: fixture.time(2))
        try require(removed.completed.value == 0 && removed.taskBreakdown.codexDesktop.totalTasks == 1,
                    "unreadable removed file cannot retain aggregate counts")
        try fixture.write(duplicate, to: second)
        let restored = try await collector.scan(at: fixture.time(3))
        try require(restored.completed.value == 1 && restored.taskBreakdown.codexDesktop.totalTasks == 2,
                    "restored file must rejoin aggregate exactly once")
    }

    private static func verifyImmediateDiscoveryAndRecovery(_ fixture: Fixture) async throws {
        try FileManager.default.removeItem(at: fixture.projects)
        let collector = try fixture.collector()
        let initial = try await collector.scan(at: fixture.now)
        try require(initial.diagnostics.discoveredJSONLFiles == 0, "empty baseline")
        let nested = fixture.sessions.appendingPathComponent("new-directory")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let original = nested.appendingPathComponent("rollout-created.jsonl")
        try fixture.write(try fixture.meta("created"), to: original)
        fixture.changes.record(nested)
        let created = try await collector.scan(at: fixture.time(1))
        try require(created.diagnostics.discoveredJSONLFiles == 1,
                    "new directory and rollout must be discovered on the next sample")
        try require(created.diagnostics.discoveryFullScans == 1, "new subtree does not rescan all roots")
        let renamed = fixture.sessions.appendingPathComponent("renamed-directory")
        try FileManager.default.moveItem(at: nested, to: renamed)
        fixture.changes.record(nested)
        fixture.changes.record(renamed)
        let moved = try await collector.scan(at: fixture.time(2))
        try require(moved.diagnostics.discoveredJSONLFiles == 1 && moved.taskBreakdown.codexDesktop.totalTasks == 1,
                    "renamed subtree must replace old paths without duplicate tasks")

        try FileManager.default.createDirectory(at: fixture.projects, withIntermediateDirectories: true)
        let desktop = fixture.projects.appendingPathComponent("created-late.jsonl")
        try fixture.write(try fixture.record(type: "user", session: "late", desktop: true), to: desktop)
        fixture.changes.record(fixture.projects)
        let rootCreated = try await collector.scan(at: fixture.time(3))
        try require(rootCreated.taskBreakdown.claudeDesktop.totalTasks == 1,
                    "missing watched root must become available when created")

        let lost = fixture.sessions.appendingPathComponent("rollout-lost-event.jsonl")
        try Data(fixture.meta("lost").utf8).write(to: lost, options: .atomic)
        fixture.changes.requireRecovery()
        let recovered = try await collector.scan(at: fixture.time(4))
        try require(recovered.diagnostics.discoveredJSONLFiles == 3 && recovered.diagnostics.discoveryFullScans == 2,
                    "lost notifications trigger a complete inventory recovery")
        let warm = try await collector.scan(at: fixture.time(5))
        try require(warm.diagnostics.discoveryMetadataReads == 0 && warm.diagnostics.discoveryFullScans == 2,
                    "unchanged tick performs no discovery metadata reads")
    }

    private static func verifyRealNotifications(_ fixture: Fixture) async throws {
        let collector = try fixture.collector(useRealNotifications: true)
        _ = try await collector.scan(at: fixture.now)
        let url = fixture.sessions.appendingPathComponent("rollout-notified.jsonl")
        try fixture.write(try fixture.meta("notified"), to: url)
        // This bounds OS notification delivery, not collector execution speed.
        // The deterministic checks above cover next-tick processing and work counts.
        let maximumAttempts = 100
        let notificationPollNanoseconds: UInt64 = 50_000_000
        for attempt in 1...maximumAttempts {
            try await Task.sleep(nanoseconds: notificationPollNanoseconds)
            let result = try await collector.scan(at: fixture.time(attempt))
            if result.diagnostics.discoveredJSONLFiles == 1 { return }
        }
        try require(false, "real FSEvents must discover a created fixture file without periodic full scans")
    }

    private static func verifyHistoricalChangeAtTrackingCapacity(_ fixture: Fixture) async throws {
        let trackingCapacity = 96
        for index in 0..<trackingCapacity {
            let url = fixture.sessions.appendingPathComponent("rollout-live-\(index).jsonl")
            try fixture.write(try fixture.meta("live-\(index)"), to: url)
        }
        let historical = fixture.sessions.appendingPathComponent("rollout-history.jsonl")
        let initialCompletion = try fixture.json([
            "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "initial"]
        ])
        try fixture.write(try fixture.meta("history") + initialCompletion, to: historical)
        let historicalAge: TimeInterval = 3_600
        try FileManager.default.setAttributes(
            [.modificationDate: fixture.now.addingTimeInterval(-historicalAge)], ofItemAtPath: historical.path
        )
        let collector = try fixture.collector()
        let initial = try await collector.scan(at: fixture.now)
        try require(initial.diagnostics.trackedLiveFiles == trackingCapacity && initial.completed.value == 1,
                    "fixture must fill live capacity while retaining the historical completion")
        let appendedCompletion = try fixture.json([
            "type": "event_msg", "payload": ["type": "task_complete", "turn_id": "appended"]
        ])
        try fixture.append(appendedCompletion, to: historical)
        let updated = try await collector.scan(at: fixture.time(1))
        try require(updated.diagnostics.trackedLiveFiles == trackingCapacity && updated.completed.value == 2,
                    "notified history must update next tick even when it cannot join the live set")
        try require(updated.filesReadIncrementally == 1,
                    "historical append must bypass the stale-signature fast path and read only its append")
    }

    private static func verifySubdirectoryPermissionRecovery(_ fixture: Fixture) async throws {
        try FileManager.default.removeItem(at: fixture.projects)
        let inaccessible = fixture.sessions.appendingPathComponent("restricted")
        try FileManager.default.createDirectory(at: inaccessible, withIntermediateDirectories: true)
        let hidden = inaccessible.appendingPathComponent("rollout-hidden.jsonl")
        let visible = fixture.sessions.appendingPathComponent("rollout-visible.jsonl")
        try fixture.write(try fixture.meta("hidden"), to: hidden)
        try fixture.write(try fixture.meta("visible"), to: visible)
        let deniedPermissions = 0o000
        let restoredPermissions = 0o700
        try FileManager.default.setAttributes([.posixPermissions: deniedPermissions], ofItemAtPath: inaccessible.path)
        do {
            let collector = try fixture.collector()
            let failed = try await collector.scan(at: fixture.now)
            try require(failed.liveRate.state == .unavailable && failed.taskBreakdown.codexDesktop.quality == .partial,
                        "inaccessible subtree must surface incomplete discovery")
            try fixture.append("{\"type\":\"progress\"}\n", to: visible)
            let stillFailed = try await collector.scan(at: fixture.time(1))
            try require(stillFailed.diagnostics.discoveryFullScans == 1,
                        "unrelated active append must not repeatedly reconcile a failed root")
            try FileManager.default.setAttributes([.posixPermissions: restoredPermissions], ofItemAtPath: inaccessible.path)
            fixture.changes.record(inaccessible)
            let recovered = try await collector.scan(at: fixture.time(2))
            try require(recovered.taskBreakdown.codexDesktop.quality == .complete
                        && recovered.liveRate.state != .unavailable
                        && recovered.diagnostics.discoveredJSONLFiles == 2,
                        "subtree permission recovery must clear the root failure and discover its files")
            try require(recovered.diagnostics.discoveryFullScans == 2,
                        "recovery reconciles the affected root once")
        } catch {
            try FileManager.default.setAttributes([.posixPermissions: restoredPermissions], ofItemAtPath: inaccessible.path)
            throw error
        }
    }

    private static func verifyAliasChangesAndDeletion(_ fixture: Fixture) async throws {
        let rootAlias = fixture.root.appendingPathComponent("sessions-alias")
        try FileManager.default.createSymbolicLink(at: rootAlias, withDestinationURL: fixture.sessions)
        let collector = try fixture.collector()
        _ = try await collector.scan(at: fixture.now)
        let aliasedFile = rootAlias.appendingPathComponent("rollout-through-alias.jsonl")
        try fixture.write(try fixture.meta("through-alias"), to: aliasedFile)
        let created = try await collector.scan(at: fixture.time(1))
        try require(created.taskBreakdown.codexDesktop.totalTasks == 1,
                    "directory-alias notification must match the canonical root")
        let complete = try fixture.json(["type": "event_msg", "payload": ["type": "task_complete", "turn_id": "one"]])
        try fixture.append(complete, to: aliasedFile)
        let changed = try await collector.scan(at: fixture.time(2))
        try require(changed.completed.value == 1, "aliased append must update canonical file state")
        try FileManager.default.removeItem(at: aliasedFile)
        fixture.changes.record(aliasedFile)
        let deleted = try await collector.scan(at: fixture.time(3))
        try require(deleted.taskBreakdown.codexDesktop.totalTasks == 0 && deleted.completed.value == 0,
                    "deleted alias path must still resolve through its surviving ancestor")

        let target = fixture.root.appendingPathComponent("rollout-external-target.jsonl")
        try fixture.write(try fixture.meta("external") + complete, to: target)
        let firstAlias = fixture.sessions.appendingPathComponent("rollout-alias-first.jsonl")
        let secondAlias = fixture.sessions.appendingPathComponent("rollout-alias-second.jsonl")
        try FileManager.default.createSymbolicLink(at: firstAlias, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: secondAlias, withDestinationURL: target)
        fixture.changes.record(firstAlias)
        fixture.changes.record(secondAlias)
        let linked = try await collector.scan(at: fixture.time(4))
        try require(linked.completed.value == 1 && linked.taskBreakdown.codexDesktop.totalTasks == 1,
                    "two file aliases share one canonical task and completion")
        try FileManager.default.removeItem(at: firstAlias)
        fixture.changes.record(firstAlias)
        let oneAlias = try await collector.scan(at: fixture.time(5))
        try require(oneAlias.completed.value == 1 && oneAlias.taskBreakdown.codexDesktop.totalTasks == 1,
                    "removing one alias must preserve the remaining canonical reference")
        try FileManager.default.removeItem(at: secondAlias)
        fixture.changes.record(secondAlias)
        let noAliases = try await collector.scan(at: fixture.time(6))
        try require(noAliases.completed.value == 0 && noAliases.taskBreakdown.codexDesktop.totalTasks == 0
                    && FileManager.default.fileExists(atPath: target.path),
                    "last alias deletion removes inventory membership even though the external target remains")
    }

    private final class Scanner: ProcessScanning, @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        func setRunning(_ value: Bool) { lock.withLock { running = value } }
        func scan() throws -> [RunningProcess] {
            lock.withLock {
                running ? [RunningProcess(pid: 42, executablePath: "/Applications/Claude.app/Contents/MacOS/Claude")] : []
            }
        }
    }

    private final class Changes: RuntimeFileChangeMonitoring, @unchecked Sendable {
        private let lock = NSLock()
        private var paths = Set<String>()
        private var recovery = false
        func record(_ url: URL) { lock.withLock { _ = paths.insert(url.path) } }
        func requireRecovery() { lock.withLock { recovery = true } }
        func takeChanges() -> RuntimeFileChanges {
            lock.withLock {
                let changes = RuntimeFileChanges(paths: paths, requiresFullRescan: recovery)
                paths.removeAll()
                recovery = false
                return changes
            }
        }
    }

    private struct Fixture {
        let root: URL
        let sessions: URL
        let projects: URL
        let scanner = Scanner()
        let changes = Changes()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        init(_ name: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-\(name)-\(UUID().uuidString)")
            sessions = root.appendingPathComponent("sessions")
            projects = root.appendingPathComponent("projects")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        }
        func time(_ seconds: Int) -> Date { now.addingTimeInterval(Double(seconds)) }
        func collector(useRealNotifications: Bool = false) throws -> CodexRuntimeMetricsCollector {
            try CodexRuntimeMetricsCollector(configuration: CodexRuntimeMetricsConfiguration(
                sessionsDirectories: [sessions], automationRoots: [], databaseURL: root.appendingPathComponent("test.sqlite"),
                claudeSessionsDirectory: root.appendingPathComponent("registry"), claudeProjectsDirectory: projects
            ), processScanner: scanner, fileChangeMonitor: useRealNotifications ? nil : changes)
        }
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
        }
        func meta(_ id: String) throws -> String {
            try json(["type": "session_meta", "payload": ["id": id, "thread_source": "user",
                     "originator": "Codex Desktop", "cwd": root.path]])
        }
        func token(_ count: Int, at seconds: Int) throws -> String {
            try json(["timestamp": ISO8601DateFormatter().string(from: time(seconds)), "type": "event_msg",
                      "payload": ["type": "token_count", "info": ["total_token_usage": ["output_tokens": count]]]])
        }
        func record(type: String, session: String, desktop: Bool = false, endTurn: Bool = false) throws -> String {
            var object: [String: Any] = ["type": type, "sessionId": session,
                "timestamp": ISO8601DateFormatter().string(from: now), "message": ["role": type, "stop_reason": endTurn ? "end_turn" : "tool_use"]]
            if desktop { object["entrypoint"] = "claude-desktop-3p" }
            return try json(object)
        }
        func write(_ text: String, to url: URL) throws {
            try Data(text.utf8).write(to: url, options: .atomic)
            changes.record(url)
        }
        func append(_ text: String, to url: URL) throws {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            changes.record(url)
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw AgentPulseCollectorVerification.VerificationError.failed(message) }
    }
}
