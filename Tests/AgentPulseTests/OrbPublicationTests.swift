import AgentPulseCore
import Combine
import Foundation
import XCTest
@testable import AgentPulse

@MainActor
final class OrbPublicationTests: XCTestCase {
    private final class Inputs {
        @Published var tps: Double? = nil
        @Published var sparkline: Sparkline = .empty
        @Published var dayTotalTokens: Int64? = nil
        @Published var colorMode: TrendColorMode = .risingGreen
    }

    private func model() -> OrbViewModel {
        OrbViewModel(snapshot: OrbSnapshot(
            tps: nil, sparklinePoints: [], trend: .insufficient,
            trendColorMode: .risingGreen, dayTotalTokens: nil, isExpanded: false
        ))
    }

    private func bind(_ inputs: Inputs, to model: OrbViewModel) -> AnyCancellable {
        model.bind(
            tps: inputs.$tps.eraseToAnyPublisher(),
            sparkline: inputs.$sparkline.eraseToAnyPublisher(),
            dayTotalTokens: inputs.$dayTotalTokens.eraseToAnyPublisher(),
            colorMode: inputs.$colorMode.eraseToAnyPublisher()
        )
    }

    private func curve(_ values: [Double?], at seconds: Double = 0, raw: Double = 10) -> Sparkline {
        Sparkline(
            points: values.enumerated().map { index, normalized in
                SparklinePoint(
                    time: Date(timeIntervalSince1970: seconds + Double(index)),
                    value: raw, normalized: normalized
                )
            },
            regression: SparklineRegression(
                slopePerSecond: 1, normalizedSlope: 1,
                sampleCount: values.count, trend: .rising
            )
        )
    }

    func testPublishedPayloadsReachSnapshotBeforeSetterReturns() async {
        let inputs = Inputs()
        let model = model()
        let binding = bind(inputs, to: model)
        var emissions: [OrbSnapshot] = []
        let observation = model.$snapshot.dropFirst().sink { emissions.append($0) }

        // 不等待 Task、runloop 或定时器：数字在曲线尚未完成时已显示。
        inputs.tps = 12.3
        XCTAssertEqual(model.snapshot.tps, 12.3)
        XCTAssertTrue(model.snapshot.sparklinePoints.isEmpty)
        XCTAssertEqual(emissions.count, 1)

        let next = curve([0, 1])
        inputs.sparkline = next
        XCTAssertEqual(model.snapshot.sparklinePoints, next.points)
        XCTAssertEqual(model.snapshot.trend, next.regression.trend)
        XCTAssertEqual(emissions.count, 2, "一次曲线提交不发布点/趋势中间态")

        inputs.dayTotalTokens = 1_200_000
        XCTAssertEqual(model.snapshot.dayTotalTokens, 1_200_000, "不能读取 willSet 前的旧 token 值")
        inputs.colorMode = .risingRed
        XCTAssertEqual(model.snapshot.trendColorMode, .risingRed, "不能等待下一次 TPS 事件更新颜色")
        XCTAssertEqual(emissions.count, 4)
        withExtendedLifetime((binding, observation)) {}
    }

    func testTimestampAndUnusedRawValuesDoNotInvalidateOrb() async {
        let inputs = Inputs()
        let model = model()
        let binding = bind(inputs, to: model)
        inputs.sparkline = curve([0, 0.5, 1])
        var count = 0
        let observation = model.$snapshot.dropFirst().sink { _ in count += 1 }

        inputs.sparkline = curve([0, 0.5, 1], at: 500, raw: 999)
        XCTAssertEqual(count, 0)
        inputs.sparkline = curve([0, 0.7, 1], at: 501)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(model.snapshot.renderedSparklineValues, [0, 0.7, 1])
        withExtendedLifetime((binding, observation)) {}
    }

    func testOnlyEqualDisplayTextIsSuppressed() async {
        let inputs = Inputs()
        let model = model()
        let binding = bind(inputs, to: model)
        inputs.tps = 12.31
        inputs.dayTotalTokens = 1_200_001
        var count = 0
        let observation = model.$snapshot.dropFirst().sink { _ in count += 1 }

        inputs.tps = 12.32
        inputs.dayTotalTokens = 1_200_002
        XCTAssertEqual(count, 0)
        inputs.tps = 12.4
        XCTAssertEqual(model.snapshot.tps, 12.4)
        XCTAssertEqual(count, 1)
        inputs.dayTotalTokens = 1_400_000
        XCTAssertEqual(model.snapshot.dayTotalTokens, 1_400_000)
        XCTAssertEqual(count, 2)
        withExtendedLifetime((binding, observation)) {}
    }

    func testFallbackGapsAndSelectionChangesAreImmediate() async {
        let inputs = Inputs()
        let model = model()
        let binding = bind(inputs, to: model)
        inputs.sparkline = curve([nil, .nan])
        XCTAssertEqual(model.snapshot.renderedSparklineValues, [])
        inputs.tps = 0
        XCTAssertEqual(model.snapshot.renderedSparklineValues, [0.5, 0.5])
        inputs.sparkline = curve([0, nil, 1])
        XCTAssertEqual(model.snapshot.renderedSparklineValues, [0, nil, 1])
        model.setExpanded(true)
        XCTAssertTrue(model.snapshot.isExpanded)
        inputs.colorMode = .risingRed
        XCTAssertTrue(model.snapshot.isExpanded)
        XCTAssertEqual(model.snapshot.trendColorMode, .risingRed)
        inputs.tps = nil
        XCTAssertNil(model.snapshot.tps)
        XCTAssertEqual(model.snapshot.renderedSparklineValues, [0, nil, 1])
        withExtendedLifetime(binding) {}
    }

    func testBackgroundPrimarySeriesPreservesEverySampleAndTrend() async {
        let end = Date(timeIntervalSince1970: 1_000)
        let history = (0..<900).map { index in
            LiveRateSample(
                timestamp: end.addingTimeInterval(Double(index - 899)),
                state: index.isMultiple(of: 7) ? .noData : .live,
                tokensInWindow: Double(index * 180), latestSignalAt: end
            )
        }
        let expected = SparklineAnalysis.makeSparkline(from: history, end: end)
        let actual = await MetricsStore.derivePrimarySeries(history: history, end: end)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.points.count, 901, "保持逐秒栅格，不下采样")
    }

    func testMenuBarLabelSuppressesOnlyIdenticalAccessibilityText() async {
        let model = MenuBarLabelViewModel()
        var count = 0
        let observation = model.$accessibilityLabel.dropFirst().sink { _ in count += 1 }
        model.update("Tasks 2 · Active 1")
        XCTAssertEqual(model.accessibilityLabel, "Tasks 2 · Active 1")
        model.update("Tasks 2 · Active 1")
        XCTAssertEqual(count, 1)
        model.update("Tasks 2 · Active 2")
        XCTAssertEqual(model.accessibilityLabel, "Tasks 2 · Active 2")
        XCTAssertEqual(count, 2)
        withExtendedLifetime(observation) {}
    }
}
