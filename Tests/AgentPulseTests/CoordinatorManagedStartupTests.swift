import Foundation
import XCTest
import AgentPulseCore
@testable import AgentPulse

@MainActor
final class CoordinatorManagedStartupTests: XCTestCase {
    func testStartupWaitsForManagedHostnameBeforeCheckingForRename() async throws {
        try await verifyStartup(resolution: ManagedSettingsSnapshot(
            reportingBaseURL: nil, canonicalHostname: "managed-host", reporting: nil,
            asterManagementKey: nil, r2: nil
        ))
    }

    func testFailedManagedLookupStartsLocalCollection() async throws {
        try await verifyStartup(resolution: nil)
    }

    private func verifyStartup(resolution: ManagedSettingsSnapshot?) async throws {
        let suite = "CoordinatorManagedStartupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults.set(configuration.appendingPathComponent("fixture.env").path,
                     forKey: MergedEnvPreferences.pathDefaultsKey)
        let storedHostname = "local-host"
        let expectedHostname = resolution?.canonicalHostname ?? storedHostname
        defaults.set(storedHostname, forKey: "tokenSync.canonicalHostname")

        let ledger = try UsageLedgerStore(path: ":memory:")
        try ledger.adoptHostname(expectedHostname)
        let coordinator = TokenSyncCoordinator(defaults: defaults,
                                               configurationURL: configuration.appendingPathComponent("reporting.json"),
                                               ledgerFactory: { ledger }, scanRoots: [], waitsForManagedSettings: true)
        defer { coordinator.stop() }
        var renamePrompts = 0
        coordinator.hostnameRenamePrompt = { _, _, _ in renamePrompts += 1 }

        coordinator.start()
        try await waitUntil { coordinator.summary.all != nil }
        coordinator.scanNow()
        XCTAssertNil(coordinator.status.lastScanAt)
        XCTAssertFalse(coordinator.status.scanningInProgress)
        XCTAssertEqual(renamePrompts, 0)

        coordinator.applyManagedSettings(resolution)
        try await waitUntil { coordinator.status.lastScanAt != nil && !coordinator.status.scanningInProgress }
        XCTAssertEqual(coordinator.status.canonicalHostname, expectedHostname)
        XCTAssertEqual(renamePrompts, 0)
        XCTAssertFalse(coordinator.status.reportingEnabled)
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try XCTUnwrap(condition() ? true : nil, "Coordinator did not reach the expected state", file: file, line: line)
    }
}
