import XCTest
import Foundation
import AgentPulseCore
@testable import AgentPulse

final class UsageSnapshotPublicationTests: XCTestCase {
    func testDelayedLocalResultCannotReplaceNewerNetworkSnapshot() {
        var gate = UsageSnapshotRevisionGate()
        var displayedTokens = 0
        func publish(revision: Int64, tokens: Int) {
            if gate.accept(revision) { displayedTokens = tokens }
        }
        publish(revision: 2, tokens: 20)
        publish(revision: 1, tokens: 10)
        XCTAssertEqual(displayedTokens, 20)
        publish(revision: 3, tokens: 30)
        publish(revision: 2, tokens: 20)
        XCTAssertEqual(displayedTokens, 30)
    }

    func testNewLedgerInstanceRestartsSnapshotSequence() {
        var gate = UsageSnapshotRevisionGate()
        XCTAssertTrue(gate.accept(100))
        XCTAssertFalse(gate.accept(1))
        gate = UsageSnapshotRevisionGate()
        XCTAssertTrue(gate.accept(1))
        XCTAssertFalse(gate.accept(1))
    }
}

@MainActor
final class CoordinatorCalendarBehaviorTests: XCTestCase {
    func testSystemDefaultAndInjectedCalendarControlBootstrapAndScan() async throws {
        let now = Date()
        let systemCalendar = Calendar.autoupdatingCurrent
        var alternateCalendar = Calendar(identifier: .gregorian)
        let halfDaySeconds = 12 * 60 * 60
        let alternateOffset = systemCalendar.timeZone.secondsFromGMT(for: now) == 0 ? halfDaySeconds : 0
        alternateCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: alternateOffset))
        let systemStart = systemCalendar.startOfDay(for: now)
        let alternateStart = alternateCalendar.startOfDay(for: now)
        XCTAssertNotEqual(systemStart, alternateStart)
        let timestamp = min(systemStart, alternateStart).addingTimeInterval(abs(systemStart.timeIntervalSince(alternateStart)) / 2)

        let ledger = try UsageLedgerStore(path: ":memory:")
        let hostname = "calendar-behavior"
        try ledger.record(events: [UsageEvent(
            id: "calendar-event", source: "fixture", model: "calendar-model", project: "fixture",
            timestamp: timestamp, counts: UsageTokenCounts(output: 17),
            sessionHash: "calendar-session", sourceFileHash: "calendar-file"
        )], checkpoint: UsageFileCheckpoint(
            fileID: "calendar-file", source: "fixture", pathHash: "calendar-file",
            offset: 1, size: 1, modifiedAt: now, parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        ), hostname: hostname)
        _ = try ledger.finalizeDerived(hostname: hostname)

        let suite = "CoordinatorCalendarBehaviorTests.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try FileManager.default.removeItem(at: directory)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let envURL = directory.appendingPathComponent("fixture.env")
        try EnvFile.writeBack([MergedEnvKeys.reportCanonicalHostname: hostname], to: envURL)
        defaults.set(envURL.path, forKey: MergedEnvPreferences.pathDefaultsKey)
        let configurationURL = directory.appendingPathComponent("reporting.json")
        let system = TokenSyncCoordinator(defaults: defaults, configurationURL: configurationURL,
                                          ledgerFactory: { ledger }, scanRoots: [])
        let injected = TokenSyncCoordinator(defaults: defaults, configurationURL: configurationURL,
                                            usageSummaryCalendar: alternateCalendar,
                                            ledgerFactory: { ledger }, scanRoots: [])
        defer { system.stop(); injected.stop() }
        try await waitUntil { system.summary.all != nil && injected.summary.all != nil }
        let expectedSystem = try ledger.summarySnapshot(containing: now, calendar: systemCalendar)
        let expectedAlternate = try ledger.summarySnapshot(containing: now, calendar: alternateCalendar)
        assertSummary(system.summary, equals: expectedSystem)
        assertSummary(injected.summary, equals: expectedAlternate)
        XCTAssertNotEqual(system.summary.day?.totalTokens, injected.summary.day?.totalTokens)

        system.scanNow()
        injected.scanNow()
        try await waitUntil { system.status.lastScanAt != nil && injected.status.lastScanAt != nil }
        assertSummary(system.summary, equals: expectedSystem)
        assertSummary(injected.summary, equals: expectedAlternate)
    }

    private func assertSummary(_ actual: TokenUsageSummary, equals expected: UsageLedgerSummarySnapshot) {
        for item in expected.windows {
            let window: TokenUsageWindow
            switch item.window {
            case .day: window = .day
            case .week: window = .week
            case .month: window = .month
            case nil: window = .all
            }
            XCTAssertEqual(actual[window]?.totalTokens, item.summary?.counts.total)
            XCTAssertEqual(actual[window]?.perModel.reduce(Int64(0)) { $0 + $1.totalTokens } ?? 0,
                           item.models.reduce(Int64(0)) { $0 + $1.counts.total })
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("calendar coordinator did not finish its fixture operation")
        throw NSError(domain: "CoordinatorCalendarBehaviorTests", code: 1)
    }
}
