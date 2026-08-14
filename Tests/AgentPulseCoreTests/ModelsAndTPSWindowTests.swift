import XCTest
@testable import AgentPulseCore

private func date(_ epoch: Double) -> Date { Date(timeIntervalSince1970: epoch) }

final class TPSWindowTests: XCTestCase {
    func testEmptyWindowReturnsNil() {
        let window = TPSWindow(now: { date(100) })
        XCTAssertNil(window.currentTPS())
        XCTAssertEqual(window.tokensInWindow(), 0)
    }

    func testInstantEventUsesFixed180SecondDenominator() {
        let window = TPSWindow()
        XCTAssertTrue(window.record(tokenCount: 180, durationSeconds: 0, source: .cli, timestamp: date(100)))
        XCTAssertEqual(window.currentTPS(referenceDate: date(100)), 1, accuracy: 1e-9)
        XCTAssertEqual(window.windowSeconds, 180)
    }

    func testIntervalIsAllocatedByWindowOverlap() {
        let window = TPSWindow()
        window.record(tokenCount: 6_000, durationSeconds: 600, source: .cli, timestamp: date(1_000))
        XCTAssertEqual(window.tokensInWindow(referenceDate: date(1_000)), 1_800, accuracy: 1e-9)
        XCTAssertEqual(window.currentTPS(referenceDate: date(1_000)), 10, accuracy: 1e-9)
    }

    func testInstantBoundaryIsIncludedThenExpires() {
        let window = TPSWindow()
        window.record(tokenCount: 180, durationSeconds: 0, source: .cli, timestamp: date(100))
        XCTAssertEqual(window.currentTPS(referenceDate: date(280)), 1, accuracy: 1e-9)
        XCTAssertNil(window.currentTPS(referenceDate: date(280.001)))
    }

    func testOutOfOrderArrival() {
        let window = TPSWindow()
        window.record(tokenCount: 90, durationSeconds: 0, source: .cli, timestamp: date(105))
        window.record(tokenCount: 90, durationSeconds: 0, source: .cli, timestamp: date(101))
        XCTAssertEqual(window.currentTPS(referenceDate: date(105)), 1, accuracy: 1e-9)
    }

    func testInvalidSamplesRejected() {
        let window = TPSWindow()
        XCTAssertFalse(window.record(tokenCount: -1, durationSeconds: 1, source: .cli, timestamp: date(100)))
        XCTAssertFalse(window.record(tokenCount: 1, durationSeconds: -1, source: .cli, timestamp: date(100)))
        XCTAssertFalse(window.record(tokenCount: 1, durationSeconds: .infinity, source: .cli, timestamp: date(100)))
        XCTAssertFalse(window.record(tokenCount: 1, durationSeconds: .nan, source: .cli, timestamp: date(100)))
    }

    func testFutureSamplesExcluded() {
        let window = TPSWindow()
        window.record(tokenCount: 180, durationSeconds: 0, source: .cli, timestamp: date(120))
        XCTAssertNil(window.currentTPS(referenceDate: date(110)))
    }

    func testResetClearsSamples() {
        let window = TPSWindow(now: { date(100) })
        window.record(tokenCount: 180, durationSeconds: 0, source: .cli, timestamp: date(100))
        window.reset()
        XCTAssertEqual(window.sampleCount(), 0)
        XCTAssertNil(window.currentTPS())
    }

    func testConcurrentRecordingIsThreadSafe() {
        let window = TPSWindow()
        let iterations = 1_000
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            window.record(tokenCount: 1, durationSeconds: 0, source: .cli, timestamp: date(1_000 + Double(index % 100)))
        }
        XCTAssertEqual(window.sampleCount(referenceDate: date(1_099)), iterations)
        XCTAssertEqual(window.currentTPS(referenceDate: date(1_099)), Double(iterations) / 180, accuracy: 1e-9)
    }

    func testLiveRateStateValueContract() {
        let live = LiveRateSample(timestamp: date(1), state: .live, tokensInWindow: 360, latestSignalAt: date(1))
        XCTAssertEqual(live.tps, 2)
        XCTAssertEqual(LiveRateSample(timestamp: date(1), state: .zero, tokensInWindow: nil, latestSignalAt: date(1)).tps, 0)
        for state in [LiveRateState.noData, .stale, .unavailable] {
            let missing = LiveRateSample(timestamp: date(1), state: state, tokensInWindow: 1, latestSignalAt: nil)
            XCTAssertNil(missing.tps)
            XCTAssertNil(missing.tokensInWindow)
        }
    }

    func testTokensInWindowAreGroupedByModel() {
        let window = TPSWindow(now: { date(100) })
        window.record(TPSSample(timestamp: date(100), tokenCount: 180, durationSeconds: 0, source: .cli, model: "codex-test-model"))
        window.record(TPSSample(timestamp: date(100), tokenCount: 90, durationSeconds: 0, source: .cli, model: "claude-opus"))
        window.record(TPSSample(timestamp: date(100), tokenCount: 45, durationSeconds: 0, source: .cli, model: nil))
        let byModel = window.tokensInWindowByModel(referenceDate: date(100))
        XCTAssertEqual(byModel["codex-test-model"], 180)
        XCTAssertEqual(byModel["claude-opus"], 90)
        XCTAssertEqual(byModel["unknown"], 45)
        XCTAssertEqual(byModel.values.reduce(0, +), window.tokensInWindow(referenceDate: date(100)), accuracy: 1e-9)
    }
}

final class ModelsCodableTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    func testSnapshotRoundTripComplete() throws {
        let snapshot = PulseSnapshot(
            timestamp: date(1_700_000_000),
            source: .desktop,
            status: .generating,
            tps: 42.5,
            tokenCount: 1_234,
            completedTaskCount: 88,
            completedCountQuality: .complete,
            note: "ok",
            process: PulseProcessInfo(pid: 4_321, executableName: "codex")
        )
        XCTAssertEqual(try roundTrip(snapshot), snapshot)
    }

    func testSnapshotRoundTripDegraded() throws {
        let snapshot = PulseSnapshot.degraded(
            source: .cli,
            timestamp: date(1_700_000_100),
            reason: .permissionDenied(path: "/tmp/x")
        )
        XCTAssertEqual(snapshot.note, "permissionDenied: /tmp/x")
        XCTAssertEqual(try roundTrip(snapshot), snapshot)
    }

    func testCompletedTaskConstraints() {
        let unavailable = PulseSnapshot(
            timestamp: date(1), source: .cli, status: .idle,
            completedTaskCount: 5, completedCountQuality: .unavailable
        )
        XCTAssertNil(unavailable.completedTaskCount)
        XCTAssertFalse(unavailable.completedIsLowerBound)

        let partial = PulseSnapshot(
            timestamp: date(1), source: .cli, status: .idle,
            completedTaskCount: 7, completedCountQuality: .partial,
            completedScope: .allLocal
        )
        XCTAssertEqual(partial.completedTaskCount, 7)
        XCTAssertEqual(partial.completedScope, .allLocal)
        XCTAssertTrue(partial.completedIsLowerBound)
    }

    func testSampleAndErrorRoundTrip() throws {
        let sample = TPSSample(timestamp: date(5), tokenCount: 3, durationSeconds: 1.5, source: .desktop)
        XCTAssertEqual(try roundTrip(sample), sample)
        XCTAssertEqual(
            try roundTrip(PulseCollectionError.parseFailed(reason: "bad json")),
            .parseFailed(reason: "bad json")
        )
    }

    func testUsageInputSummaryUsesInputOnlyCacheSemantics() {
        let counts = UsageTokenCounts(
            input: 30,
            output: 1_000,
            cachedInput: 60,
            cacheCreationInput: 10,
            reasoningOutput: 500,
            reportedTotal: 2_000
        )

        let summary = UsageInputSummary(counts: counts)

        XCTAssertEqual(summary.cachedTokens, 60)
        XCTAssertEqual(summary.newTokens, 40)
        XCTAssertEqual(summary.cacheHitRate, 0.6, accuracy: 1e-9)
    }

    func testUsageInputSummaryHasNoRateWithoutInputTokens() {
        let summary = UsageInputSummary(
            counts: UsageTokenCounts(output: 100, reasoningOutput: 20, reportedTotal: 120)
        )

        XCTAssertEqual(summary.cachedTokens, 0)
        XCTAssertEqual(summary.newTokens, 0)
        XCTAssertNil(summary.cacheHitRate)
    }

    func testUsageSummaryWindowsUseDayCalendarAndRollingWeekMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2024, month: 2, day: 29, hour: 15, minute: 30
        )))

        // 日 = 自然日历日。
        let day = try XCTUnwrap(UsageSummaryWindow.day.interval(containing: reference, calendar: calendar))
        XCTAssertEqual(day.start, calendar.date(from: DateComponents(year: 2024, month: 2, day: 29)))
        XCTAssertEqual(day.end, calendar.date(from: DateComponents(year: 2024, month: 3, day: 1)))

        // 周 = 最近 7×24h 滚动窗口，右界为参考时刻。
        let week = try XCTUnwrap(UsageSummaryWindow.week.interval(containing: reference, calendar: calendar))
        XCTAssertEqual(week.end, reference)
        XCTAssertEqual(week.start, reference.addingTimeInterval(-7 * 24 * 60 * 60))

        // 月 = 最近 30×24h 滚动窗口，右界为参考时刻。
        let month = try XCTUnwrap(UsageSummaryWindow.month.interval(containing: reference, calendar: calendar))
        XCTAssertEqual(month.end, reference)
        XCTAssertEqual(month.start, reference.addingTimeInterval(-30 * 24 * 60 * 60))
    }
}
