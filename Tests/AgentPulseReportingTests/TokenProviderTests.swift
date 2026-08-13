import XCTest
@testable import AgentPulseReporting

final class TokenProviderTests: XCTestCase {
    private var config: CommandTokenProviderConfiguration {
        CommandTokenProviderConfiguration(
            executable: "/usr/bin/env",
            arguments: ["auth-helper", "get-token"],
            forceRefreshArguments: ["--force-refresh"],
            statusKey: "status",
            successStatus: "success",
            errorKey: "error",
            tokenKeyPath: ["data", "token"]
        )
    }

    func testUnconfiguredProviderRunsNothingAndThrows() {
        var ran = false
        let runner = ClosureProcessRunner { _, _ in ran = true; return ProcessResult(exitCode: 0, standardOutput: Data()) }
        let provider = ConfiguredCommandTokenProvider(configuration: CommandTokenProviderConfiguration(), runner: runner)
        XCTAssertThrowsError(try provider.token()) { XCTAssertEqual($0 as? TokenProviderError, .configurationMissing) }
        XCTAssertFalse(ran)
    }

    func testParsesTokenAlongKeyPath() throws {
        let token = try ConfiguredCommandTokenProvider.parseToken(
            from: Data("{\"status\":\"success\",\"data\":{\"token\":\"header.payload.sig\"}}".utf8),
            configuration: config
        )
        XCTAssertEqual(token.reveal(), "header.payload.sig")
    }

    func testNormalFetchUsesConfiguredArguments() throws {
        let runner = ClosureProcessRunner { _, _ in ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"t\"}}".utf8)) }
        _ = try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token()
        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/env")
        XCTAssertEqual(runner.invocations.first?.arguments, ["auth-helper", "get-token"])
    }

    func testForceRefreshAppendsArguments() throws {
        let runner = ClosureProcessRunner { _, _ in ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"t\"}}".utf8)) }
        _ = try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token(forceRefresh: true)
        XCTAssertEqual(runner.invocations.first?.arguments, ["auth-helper", "get-token", "--force-refresh"])
    }

    func testNonZeroExitThrows() {
        let runner = ClosureProcessRunner { _, _ in ProcessResult(exitCode: 7, standardOutput: Data()) }
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token()) {
            XCTAssertEqual($0 as? TokenProviderError, .commandFailed(exitCode: 7))
        }
    }

    func testMalformedOutputThrows() {
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider.parseToken(from: Data("not json".utf8), configuration: config)) {
            XCTAssertEqual($0 as? TokenProviderError, .malformedOutput)
        }
    }

    func testUnsuccessfulStatusThrows() {
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider.parseToken(from: Data("{\"status\":\"failure\",\"data\":{\"token\":\"t\"}}".utf8), configuration: config)) {
            XCTAssertEqual($0 as? TokenProviderError, .unsuccessfulResponse)
        }
    }

    func testErrorFieldThrows() {
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider.parseToken(from: Data("{\"status\":\"success\",\"error\":\"boom\"}".utf8), configuration: config)) {
            XCTAssertEqual($0 as? TokenProviderError, .unsuccessfulResponse)
        }
    }

    func testMissingTokenThrows() {
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider.parseToken(from: Data("{\"status\":\"success\",\"data\":{\"token\":\"\"}}".utf8), configuration: config)) {
            XCTAssertEqual($0 as? TokenProviderError, .missingToken)
        }
    }

    func testSecretTokenNeverLeaks() {
        let token = SecretToken("super-secret-value")
        XCTAssertFalse("\(token)".contains("super-secret-value"))
        XCTAssertFalse(String(reflecting: token).contains("super-secret-value"))
        XCTAssertEqual(token.description, "SecretToken(redacted)")
    }
}

