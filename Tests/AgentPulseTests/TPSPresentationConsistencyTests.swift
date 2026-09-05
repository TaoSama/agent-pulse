import AgentPulseCore
import Combine
import Foundation
import XCTest
@testable import AgentPulse

@MainActor
final class TPSPresentationConsistencyTests: XCTestCase {
    private let sampledAt = Date(timeIntervalSince1970: 180_000)

    private func sample(_ state: LiveRateState = .live, secondsLater: TimeInterval = 0) -> LiveRateSample {
        LiveRateSample(
            timestamp: sampledAt.addingTimeInterval(secondsLater), state: state,
            tokensInWindow: 1_800, latestSignalAt: sampledAt,
            modelTokensInWindow: ["alpha": 1_080, "beta": 360],
            tokensInShortWindow: 500, modelTokensInShortWindow: ["alpha": 500],
            tokensInLastSecond: 7, modelTokensInLastSecond: ["beta": 7]
        )
    }

    func testFreshTotalAndModelValuesUseTheSame180SecondSample() async throws {
        let presentation = CurrentTPSPresentation(sample: sample())
        XCTAssertEqual(presentation.sampledAt, sampledAt)
        XCTAssertEqual(presentation.state, .live)
        XCTAssertEqual(presentation.totalTPS, 10)
        XCTAssertEqual(presentation.tps(for: "alpha"), 6)
        XCTAssertEqual(presentation.tps(for: "beta"), 2)
        XCTAssertEqual(presentation.tps(for: "unknown"), 2)
        XCTAssertEqual(presentation.tps(for: "historical-only"), 0)
        XCTAssertEqual(presentation.modelTPS.values.reduce(0, +), try XCTUnwrap(presentation.totalTPS), accuracy: 1e-12)

        let rows = presentation.models(including: ["historical-only", "alpha", "alpha"])
        XCTAssertEqual(Set(rows.map(\.model)), ["alpha", "beta", "unknown", "historical-only"])
        XCTAssertEqual(rows.count, 4, "历史模型与当前模型合并时不能重复")
        XCTAssertEqual(rows.compactMap(\.tps).reduce(0, +), 10, accuracy: 1e-12)
    }

    func testUnattributedTokensMergeIntoExistingUnknownModel() async throws {
        let current = LiveRateSample(
            timestamp: sampledAt, state: .live, tokensInWindow: 1_800,
            latestSignalAt: sampledAt, modelTokensInWindow: ["alpha": 720, "unknown": 180]
        )
        let presentation = CurrentTPSPresentation(sample: current)
        XCTAssertEqual(presentation.tps(for: "alpha"), 4)
        XCTAssertEqual(presentation.tps(for: "unknown"), 6)
        XCTAssertEqual(presentation.modelTPS.values.reduce(0, +), try XCTUnwrap(presentation.totalTPS), accuracy: 1e-12)
    }

    func testZeroIsKnownZeroButMissingAndExpiredStatesNeverRecoverHistoricalRates() async {
        let zero = CurrentTPSPresentation(sample: sample(.zero))
        XCTAssertEqual(zero.totalTPS, 0)
        XCTAssertEqual(zero.tps(for: "alpha"), 0)
        XCTAssertTrue(zero.modelTPS.isEmpty)
        XCTAssertEqual(zero.models(including: ["alpha"]).first?.tps, 0)

        for state in [LiveRateState.noData, .stale, .unavailable] {
            let missing = CurrentTPSPresentation(sample: sample(state))
            XCTAssertEqual(missing.state, state)
            XCTAssertNil(missing.totalTPS)
            XCTAssertNil(missing.tps(for: "alpha"))
            XCTAssertTrue(missing.modelTPS.isEmpty)
            let rows = missing.models(including: ["alpha", "beta"])
            XCTAssertEqual(Set(rows.map(\.model)), ["alpha", "beta"])
            XCTAssertTrue(rows.allSatisfy { $0.tps == nil }, "\(state) 不能把历史模型值显示为当前值或零")
        }
        XCTAssertEqual(CurrentTPSPresentation.empty.state, .noData)
        XCTAssertNil(CurrentTPSPresentation.empty.totalTPS)
    }

    func testPersistedInactivePayloadCannotResurrectItsOldNumericFields() async throws {
        // 解码路径保留旧记录数值，展示层仍必须优先遵守状态，不能只检查 tps 非 nil。
        let encoded = try JSONEncoder().encode(sample())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for state in [LiveRateState.zero, .stale, .noData, .unavailable] {
            object["state"] = state.rawValue
            let restored = try JSONDecoder().decode(
                LiveRateSample.self, from: JSONSerialization.data(withJSONObject: object)
            )
            XCTAssertEqual(restored.tps, 10, "fixture 必须真的携带旧数值")
            let presentation = CurrentTPSPresentation(sample: restored)
            if state == .zero {
                XCTAssertEqual(presentation.totalTPS, 0)
                XCTAssertEqual(presentation.tps(for: "alpha"), 0)
            } else {
                XCTAssertNil(presentation.totalTPS)
                XCTAssertNil(presentation.tps(for: "alpha"))
            }
            XCTAssertTrue(presentation.modelTPS.isEmpty)
        }
    }

    func testStorePublishesTotalAndModelsSynchronouslyWithoutWaitingForCurves() async throws {
        let store = try makeStore()
        let orb = OrbViewModel(snapshot: OrbSnapshot(
            tps: nil, sparklinePoints: [], trend: .insufficient,
            trendColorMode: .risingGreen, dayTotalTokens: nil, isExpanded: false
        ))
        let binding = orb.bind(
            tps: store.$currentTPS.map(\.totalTPS).eraseToAnyPublisher(),
            sparkline: store.$sparkline.eraseToAnyPublisher(),
            dayTotalTokens: Just<Int64?>(nil).eraseToAnyPublisher(),
            colorMode: Just(TrendColorMode.risingGreen).eraseToAnyPublisher()
        )
        var snapshots: [CurrentTPSPresentation] = []
        var curvePublications = 0
        let rates = store.$currentTPS.dropFirst().sink { snapshots.append($0) }
        let curves = store.$sparkline.dropFirst().sink { _ in curvePublications += 1 }

        for (index, state) in [LiveRateState.live, .zero, .stale, .noData, .unavailable].enumerated() {
            let next = sample(state, secondsLater: Double(index))
            store.applyLiveRate(next)
            // 不等待 Task、runloop 或派生计算：每次 setter 返回前完整快照已到达订阅者。
            XCTAssertEqual(snapshots.count, index + 1)
            XCTAssertEqual(snapshots.last, CurrentTPSPresentation(sample: next))
            XCTAssertEqual(store.currentTPS, snapshots.last)
            XCTAssertEqual(orb.snapshot.tps, snapshots.last?.totalTPS,
                           "UI 必须消费 publisher 的新快照，不能回读 willSet 前的旧值")
            XCTAssertTrue(orb.snapshot.sparklinePoints.isEmpty)
            XCTAssertEqual(curvePublications, 0)
            XCTAssertEqual(store.sparkline, .empty)
        }
        let last = sample(.unavailable, secondsLater: 4)
        store.applyLiveRate(last)
        XCTAssertEqual(snapshots.count, 5, "完全相同快照不重复发布")
        withExtendedLifetime((binding, rates, curves)) {}
    }

    func testCompactGeometryUsesRawValuesAndPreservesGapsAndPeaks() async throws {
        let points = makePoints([0, 50, nil, 100], normalized: [1, 0, 0.5, 0])
        let values = CompactTPSGeometry.normalizedValues(points: points)
        XCTAssertEqual(values.count, points.count)
        XCTAssertEqual(values, [0, 0.5, nil, 1])
        XCTAssertNil(values[2], "不能把历史缺口插值成真实样本")
        let low = try XCTUnwrap(values[0])
        let middle = try XCTUnwrap(values[1])
        let high = try XCTUnwrap(values[3])
        XCTAssertLessThan(low, middle)
        XCTAssertLessThan(middle, high)
        XCTAssertEqual(middle - low, high - middle, accuracy: 1e-12, "原始 TPS 必须线性共用尺度")

        let outliers = makePoints(Array(repeating: 10, count: 20) + [20, 1_000])
        let outlierValues = CompactTPSGeometry.normalizedValues(points: outliers)
        XCTAssertLessThan(try XCTUnwrap(outlierValues[20]), try XCTUnwrap(outlierValues[21]),
                          "分位裁剪不能把 20 与 1000 的真实峰值压到同一高度")
        XCTAssertEqual(points.map(\.value), [0, 50, nil, 100], "几何转换不改历史统计值")
    }

    func testCompactModelCurvesShareTheTotalScale() async {
        let total = makePoints([0, 50, nil, 100])
        let alpha = makePoints([0, 30, nil, 60])
        let beta = makePoints([0, 20, nil, 40])
        let totalGeometry = CompactTPSGeometry.normalizedValues(points: total)
        let alphaGeometry = CompactTPSGeometry.normalizedValues(points: alpha, referencePoints: total)
        let betaGeometry = CompactTPSGeometry.normalizedValues(points: beta, referencePoints: total)
        XCTAssertEqual(alphaGeometry, [0, 0.3, nil, 0.6])
        XCTAssertEqual(betaGeometry, [0, 0.2, nil, 0.4])
        for index in [0, 1, 3] {
            XCTAssertEqual((alphaGeometry[index] ?? 0) + (betaGeometry[index] ?? 0), totalGeometry[index])
        }
        XCTAssertNil(alphaGeometry[2])
        XCTAssertNil(betaGeometry[2])
    }

    func testOrbAndCompactGeometryShareRawShapeAndFallbackSemantics() async {
        let points = makePoints([0, nil, 20, 40], normalized: [1, 1, 1, 0])
        let snapshot = OrbSnapshot(
            tps: 10, sparklinePoints: points, trend: .rising,
            trendColorMode: .risingGreen, dayTotalTokens: nil, isExpanded: false
        )
        XCTAssertEqual(snapshot.renderedSparklineValues,
                       CompactTPSGeometry.normalizedValues(points: points, fallbackTPS: 10))
        let invalid = makePoints([nil, .nan, .infinity, -1])
        XCTAssertEqual(CompactTPSGeometry.normalizedValues(points: invalid), [])
        XCTAssertEqual(CompactTPSGeometry.normalizedValues(points: invalid, fallbackTPS: 0), [0.5, 0.5])
        XCTAssertEqual(CompactTPSGeometry.normalizedValues(points: [], fallbackTPS: 10), [0.5, 0.5])
        XCTAssertEqual(CompactTPSGeometry.normalizedValues(points: [], fallbackTPS: .nan), [])
        XCTAssertEqual(CompactTPSGeometry.normalizedValues(points: [], fallbackTPS: -1), [])
    }

    func testDashboardSpansKeepBucketStatisticsSeparateFromCurrentTPS() async throws {
        let store = try makeStore()
        store.applyLiveRate(sample())
        let current = store.currentTPS
        // 每秒净增量为 7；180s 当前 TPS 为 10；5s 重叠 TPS 为 100，三者故意不同。
        let history = (0..<3_600).map { second in
            sample(secondsLater: Double(second - 3_600))
        }
        for span in DashboardTPSSpan.allCases where span.source == .perSecondSamples {
            store.setDashboardSpan(span)
            XCTAssertEqual(store.currentTPS, current, "跨度选择不能把当前值切换为历史均值")
            let total = SparklineAnalysis.makeBucketedDashboardSparkline(from: history, end: sampledAt, span: span)
            let model = SparklineAnalysis.makeBucketedDashboardModelSparkline(
                from: history, model: "beta", end: sampledAt, span: span
            )
            XCTAssertEqual(total.count, span.bucketCount)
            XCTAssertEqual(total.map(\.time), model.map(\.time))
            XCTAssertEqual(total.first?.time, sampledAt.addingTimeInterval(-span.totalSeconds + span.bucketSeconds / 2))
            for point in total + model {
                XCTAssertEqual(try XCTUnwrap(point.value), 7, accuracy: 1e-10,
                               "桶平均仅来自逐秒净增量，不得替换为 180s 或 5s 重叠量")
            }
        }
        store.setDashboardSpan(.oneDay)
        XCTAssertEqual(store.currentTPS, current)
        XCTAssertTrue(store.dashboardSparklinePoints.isEmpty, "一天曲线继续交由长期账本提供")
        let day = SparklineAnalysis.makeUsageLedgerTPSPoints(
            buckets: [(bucketStart: sampledAt.addingTimeInterval(-1_800), outputTokens: 36_000)], end: sampledAt
        )
        XCTAssertEqual(day.count, DashboardTPSSpan.oneDay.bucketCount)
        XCTAssertEqual(day.compactMap(\.value), [20], "长期账本保留 output / 1800 秒的历史口径")
    }

    private func makePoints(_ values: [Double?], normalized: [Double?]? = nil) -> [SparklinePoint] {
        values.enumerated().map { index, value in
            SparklinePoint(time: sampledAt.addingTimeInterval(Double(index)), value: value,
                           normalized: normalized?[index])
        }
    }

    private func makeStore() throws -> MetricsStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tps-presentation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        // 所有来源与数据库均限定在合成临时目录；不启动定时器或访问用户会话。
        return MetricsStore(configuration: .init(
            sessionsDirectory: root.appendingPathComponent("codex"), automationDirectories: [],
            claudeSessionsDirectory: root.appendingPathComponent("claude-sessions"),
            claudeProjectsDirectory: root.appendingPathComponent("claude-projects"),
            databaseURL: root.appendingPathComponent("metrics.sqlite3")
        ))
    }
}
