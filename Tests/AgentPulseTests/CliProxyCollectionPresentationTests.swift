import XCTest
import AgentPulseCore
@testable import AgentPulse

final class CliProxyCollectionPresentationTests: XCTestCase {
    func testConfirmedCommitClearsMigrationMessage() {
        XCTAssertNil(CliProxyCollectionPresentation.diagnostic(
            states: [.init(endpoint: .analytics), .init(endpoint: .legacy)],
            failedSourceCount: 0, sourceCount: 2
        ))
    }

    func testRejectedIdentityDoesNotAppearAsOngoingDetection() throws {
        let mixed = try XCTUnwrap(CliProxyCollectionPresentation.diagnostic(
            states: [.init(endpoint: .mixed)], failedSourceCount: 0, sourceCount: 1
        ))
        XCTAssertTrue(mixed.contains("身份混用"))
        XCTAssertTrue(mixed.contains("已暂停"))
        XCTAssertFalse(mixed.contains("正在核对"))

        let unresolved = try XCTUnwrap(CliProxyCollectionPresentation.diagnostic(
            states: [.init(endpoint: .unresolved)], failedSourceCount: 0, sourceCount: 1
        ))
        XCTAssertTrue(unresolved.contains("核对未通过"))
        XCTAssertFalse(unresolved.contains("正在核对"))
    }

    func testIndependentFailuresAndPendingDetectionRemainVisible() throws {
        let message = try XCTUnwrap(CliProxyCollectionPresentation.diagnostic(
            states: [.init(endpoint: .mixed), .init(endpoint: .detectingLegacy)],
            failedSourceCount: 1, sourceCount: 3
        ))
        XCTAssertTrue(message.contains("采集失败（1/3）"))
        XCTAssertTrue(message.contains("身份混用（1 个来源）"))
        XCTAssertTrue(message.contains("正在核对 CPA 历史来源身份（1 个来源）"))
    }
}
