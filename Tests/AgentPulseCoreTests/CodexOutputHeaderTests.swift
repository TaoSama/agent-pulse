import Foundation
import XCTest
@testable import AgentPulseCore

final class CodexOutputHeaderTests: XCTestCase {
    private func legacyHeader(_ output: String) -> String {
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    func testHeaderMatchesOriginalWhitespaceAndUnicodeSemantics() {
        let parts = ["", " ", "\t", "\r", "\n", "\r\n", "\u{00A0}",
                     "\u{2028}", "Script completed", "Script failed", "文本👩🏽‍💻"]
        for prefix in parts {
            for suffix in parts {
                let value = prefix + "\n" + suffix + "\nignored"
                XCTAssertEqual(UsageEditLines.firstNonEmptyLine(value), legacyHeader(value))
            }
        }
        for value in parts {
            XCTAssertEqual(UsageEditLines.firstNonEmptyLine(value), legacyHeader(value))
        }
    }

    func testLargeBodyCannotOverrideAuthoritativeHeader() {
        let body = String(repeating: "Exit code: 0\n正文\n", count: 10_000)
        XCTAssertFalse(UsageEditLines.codexExecIsApplied("Script failed\n" + body))
        XCTAssertTrue(UsageEditLines.codexProgrammaticExecIsApplied("\n \t\nScript completed\n" + body))
        XCTAssertEqual(UsageEditLines.codexProgrammaticRunningCellID("Script running with cell ID abc\n" + body), "abc")
    }

    func testHeaderBenchmark() throws {
        guard ProcessInfo.processInfo.environment["PARSER_HEADER_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with PARSER_HEADER_BENCHMARK=1; synthetic output only")
        }
        let output = "Script completed\n" + String(repeating: "synthetic output 文本\n", count: 50_000)
        let repetitions = 8
        for (name, read) in [("legacy", legacyHeader), ("prefix", UsageEditLines.firstNonEmptyLine)] {
            let start = ProcessInfo.processInfo.systemUptime
            for _ in 0..<repetitions { XCTAssertEqual(read(output), "Script completed") }
            print("output-header method=\(name) repetitions=\(repetitions) seconds=\(ProcessInfo.processInfo.systemUptime - start)")
        }
    }
}
