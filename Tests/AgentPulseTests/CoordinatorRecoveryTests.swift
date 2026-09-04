import XCTest
import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage
@testable import AgentPulse

@MainActor
final class CoordinatorRecoveryTests: XCTestCase {
    private static let hostname = "coordinator-test"
    private static let pollingInterval: Duration = .milliseconds(10)
    private static let conditionTimeout: Duration = .seconds(3)

    func testFailedLedgerBootstrapRetriesAutomaticallyAndStartsCollection() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.sourceRoot, withIntermediateDirectories: false)
        let factory = CoordinatorRetryingLedgerFactory(ledger: fixture.ledger)
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(fixture, clock: clock, ledgerFactory: { try factory.open() })
        defer { coordinator.stop() }
        coordinator.start()

        try await eventually("failed bootstrap should retain an automatic retry") {
            let hasRetry = await clock.pendingCount > 0
            return coordinator.status.scanError == "本地账本读取失败" && hasRetry
        }
        XCTAssertEqual(factory.attempts, 1)
        XCTAssertNil(coordinator.status.lastScanAt)
        await clock.advance()
        try await eventually("retry should reopen the ledger and complete the first local scan") {
            coordinator.status.lastScanAt != nil && !coordinator.status.scanningInProgress
        }
        XCTAssertEqual(factory.attempts, 2)
        XCTAssertNil(coordinator.status.scanError)
    }

    func testStoppingAfterBootstrapFailureCancelsItsRetry() async throws {
        let fixture = try makeFixture()
        let factory = CoordinatorRetryingLedgerFactory(ledger: fixture.ledger)
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(fixture, clock: clock, ledgerFactory: { try factory.open() })
        defer { coordinator.stop() }
        coordinator.start()
        try await eventually("bootstrap failure should schedule a retry before stopping") {
            let hasRetry = await clock.pendingCount > 0
            return coordinator.status.scanError == "本地账本读取失败" && hasRetry
        }

        coordinator.stop()
        try await eventually("stop should cancel the pending bootstrap retry") { await clock.pendingCount == 0 }
        await clock.advance()
        await Task.yield()
        XCTAssertEqual(factory.attempts, 1, "a stopped coordinator reopened its ledger")
        XCTAssertNil(coordinator.status.lastScanAt)
    }

    func testFailedStartupRecoveryRetriesAfterSourceBecomesReadable() async throws {
        let fixture = try makeFixture()
        try fixture.ledger.beginParserRebuild(targetParserVersion: UsageJSONLParser.parserVersion)
        // A regular file in place of a source directory produces a real scanner I/O failure.
        try Data("temporarily unavailable".utf8).write(to: fixture.sourceRoot)
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(fixture, clock: clock)
        defer { coordinator.stop() }
        coordinator.start()

        try await eventually("startup recovery should expose its failed scan") {
            coordinator.status.scanError == "本地扫描失败，可重试"
                && !coordinator.status.scanningInProgress
        }
        XCTAssertTrue(try fixture.ledger.requiresRebuildCompletion())
        XCTAssertNil(coordinator.status.lastScanAt)

        try FileManager.default.removeItem(at: fixture.sourceRoot)
        try FileManager.default.createDirectory(at: fixture.sourceRoot, withIntermediateDirectories: false)
        try await eventually("failed recovery must retain a scheduled local retry") {
            await clock.pendingCount > 0
        }
        await clock.advance()
        try await eventually("scheduled retry should complete without a manual scan") {
            coordinator.status.lastScanAt != nil && !coordinator.status.scanningInProgress
        }
        XCTAssertFalse(try fixture.ledger.requiresRebuildCompletion())
        XCTAssertFalse(try fixture.ledger.requiresDerivationCompletion())
        XCTAssertFalse(coordinator.status.reportingEnabled)
    }

    func testInvalidReportingConfigurationKeepsLocalPeriodicCollectionRunning() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.sourceRoot, withIntermediateDirectories: false)
        let configuration = CoordinatorTestConfiguration(hostname: Self.hostname)
        let reporter = TokenUsageReporter(
            configurationLoader: { _ in try configuration.load() },
            clientFactory: { _, _ in CoordinatorNoNetworkClient() }
        )
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(fixture, clock: clock, reporter: reporter)
        defer { coordinator.stop() }
        coordinator.start()
        try await eventually("initial local scan should complete") {
            coordinator.status.lastScanAt != nil && !coordinator.status.scanningInProgress
        }
        coordinator.setReportingEnabled(true)
        XCTAssertTrue(coordinator.status.reportingEnabled)
        try await eventually("enabling reporting should finish its immediate scan/report") {
            !coordinator.status.scanningInProgress && !coordinator.status.reportingInProgress
        }

        configuration.invalidate()
        let beforeInvalidation = coordinator.status.lastScanAt
        try await eventually("periodic collection should have a scheduled tick") {
            await clock.pendingCount > 0
        }
        await clock.advance()
        try await eventually("invalid configuration should disable reporting and finish this local scan") {
            !coordinator.status.reportingEnabled
                && coordinator.status.lastScanAt != beforeInvalidation
                && !coordinator.status.scanningInProgress
        }
        XCTAssertTrue(coordinator.status.localCollectionEnabled)

        let afterInvalidation = coordinator.status.lastScanAt
        try await eventually("local collection must remain scheduled after reporting is disabled") {
            await clock.pendingCount > 0
        }
        await clock.advance()
        try await eventually("a subsequent automatic local scan should still run") {
            coordinator.status.lastScanAt != afterInvalidation && !coordinator.status.scanningInProgress
        }
        XCTAssertFalse(coordinator.status.reportingEnabled)
    }

    func testChangingIntervalDoesNotWaitForBusyLedgerQueueOnMainActor() async throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.sourceRoot, withIntermediateDirectories: false)
        let clock = CoordinatorTestClock()
        let coordinator = makeCoordinator(fixture, clock: clock)
        defer { coordinator.stop() }
        coordinator.start()
        try await eventually("initial local scan should complete") {
            coordinator.status.lastScanAt != nil && !coordinator.status.scanningInProgress
        }

        // Hold the real ledger's serial queue from its finalize progress callback.
        let hold = CoordinatorLedgerHold()
        let ledger = fixture.ledger
        let hostname = Self.hostname
        let worker = Task.detached {
            try ledger.finalizeDerived(hostname: hostname, strategy: .fullRecompute) { _, _ in
                hold.blockOnce()
            }
        }
        defer { hold.release() }
        try await eventually("the fixture must actually hold the ledger queue") { hold.hasEntered }

        // Release independently of MainActor so a regression fails rather than deadlocking the suite.
        DispatchQueue.global().asyncAfter(deadline: .now() + CoordinatorLedgerHold.fallbackReleaseSeconds) {
            hold.release()
        }
        let started = ContinuousClock.now
        coordinator.setAutoReportInterval(.fiveMinutes)
        let elapsed = started.duration(to: .now)
        hold.release()
        _ = try await worker.value

        XCTAssertLessThan(elapsed, .milliseconds(500), "changing a UI setting waited on SQLite")
        XCTAssertEqual(coordinator.status.autoReportInterval, .fiveMinutes)
        try await eventually("the replacement loop should use the new interval") {
            await clock.pendingIntervals.contains(TokenReportInterval.fiveMinutes.seconds)
        }
    }

    private func makeCoordinator(
        _ fixture: CoordinatorFixture,
        clock: CoordinatorTestClock,
        reporter: TokenUsageReporter? = nil,
        ledgerFactory: (@Sendable () throws -> UsageLedgerStore)? = nil
    ) -> TokenSyncCoordinator {
        let ledger = fixture.ledger
        return TokenSyncCoordinator(
            defaults: fixture.defaults,
            configurationURL: fixture.directory.appendingPathComponent("reporting.json"),
            reporter: reporter,
            ledgerFactory: ledgerFactory ?? { ledger },
            scanRoots: [UsageScanRoot(root: fixture.sourceRoot, source: "fixture")],
            autoLoopSleep: { interval in try await clock.sleep(interval) }
        )
    }

    private func makeFixture() throws -> CoordinatorFixture {
        let suite = "CoordinatorRecoveryTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let envURL = directory.appendingPathComponent("fixture.env")
        try EnvFile.writeBack([
            MergedEnvKeys.reportCanonicalHostname: Self.hostname,
            MergedEnvKeys.reportBaseURL: "https://reporting.invalid"
        ], to: envURL)
        defaults.set(envURL.path, forKey: MergedEnvPreferences.pathDefaultsKey)
        defaults.set(Self.hostname, forKey: "tokenSync.canonicalHostname")
        defaults.set(true, forKey: "tokenSync.localCollectionEnabled")
        defaults.set(false, forKey: "tokenSync.reportingEnabled")
        let ledger = try UsageLedgerStore(path: ":memory:")
        try ledger.adoptHostname(Self.hostname)
        return CoordinatorFixture(
            directory: directory, sourceRoot: directory.appendingPathComponent("source"),
            defaults: defaults, ledger: ledger
        )
    }

    private func eventually(
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.conditionTimeout)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail(message, file: file, line: line)
                throw CoordinatorFixtureError.conditionTimedOut
            }
            try await Task.sleep(for: Self.pollingInterval)
        }
    }
}

private struct CoordinatorFixture {
    let directory: URL
    let sourceRoot: URL
    let defaults: UserDefaults
    let ledger: UsageLedgerStore
}

private enum CoordinatorFixtureError: Error {
    case conditionTimedOut
    case ledgerTemporarilyUnavailable
    case invalidConfiguration
    case unexpectedNetworkRequest
}

private final class CoordinatorRetryingLedgerFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: UsageLedgerStore
    private var attemptCount = 0
    var attempts: Int { lock.withLock { attemptCount } }

    init(ledger: UsageLedgerStore) { self.ledger = ledger }

    func open() throws -> UsageLedgerStore {
        try lock.withLock {
            attemptCount += 1
            guard attemptCount > 1 else { throw CoordinatorFixtureError.ledgerTemporarilyUnavailable }
            return ledger
        }
    }
}

private actor CoordinatorTestClock {
    private struct Sleep {
        let interval: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }
    private var sleepers: [UUID: Sleep] = [:]
    var pendingCount: Int { sleepers.count }
    var pendingIntervals: [TimeInterval] { sleepers.values.map(\.interval) }

    func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleep(interval: interval, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance() {
        let pending = sleepers
        sleepers.removeAll()
        for sleep in pending.values { sleep.continuation.resume() }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

private final class CoordinatorTestConfiguration: @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: TokenReportingConfiguration
    private var isValid = true

    init(hostname: String) {
        configuration = TokenReportingConfiguration(
            canonicalHostname: hostname, path: "/usage",
            headers: .init(authToken: "Auth", contentEncoding: "Encoding", contentType: "Type"),
            tokenCommand: .init(executable: "/usr/bin/false", tokenKeyPath: ["value"]),
            retry: .init(maxRetries: 0, retryableStatusCodes: [], backoffSeconds: [])
        )
    }

    func load() throws -> TokenReportingConfiguration {
        try lock.withLock {
            guard isValid else { throw CoordinatorFixtureError.invalidConfiguration }
            return configuration
        }
    }

    func invalidate() { lock.withLock { isValid = false } }
}

private struct CoordinatorNoNetworkClient: UsageBatchReporting {
    func ingest(batches: [UsageBatch]) async throws -> UsageBatchOutcome {
        throw CoordinatorFixtureError.unexpectedNetworkRequest
    }
}

private final class CoordinatorLedgerHold: @unchecked Sendable {
    static let fallbackReleaseSeconds: TimeInterval = 1.5
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false
    var hasEntered: Bool { lock.withLock { entered } }

    func blockOnce() {
        let shouldBlock = lock.withLock {
            guard !entered else { return false }
            entered = true
            return true
        }
        if shouldBlock { semaphore.wait() }
    }

    func release() { semaphore.signal() }
}
