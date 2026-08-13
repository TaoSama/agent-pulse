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
        let runner = ClosureProcessRunner { _, _, _ in ran = true; return ProcessResult(exitCode: 0, standardOutput: Data()) }
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
        let runner = ClosureProcessRunner { _, _, _ in ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"t\"}}".utf8)) }
        _ = try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token()
        XCTAssertEqual(runner.invocations.first?.executable, "/usr/bin/env")
        XCTAssertEqual(runner.invocations.first?.arguments, ["auth-helper", "get-token"])
        XCTAssertEqual(runner.invocations.first?.timeout, 30)
    }

    func testForceRefreshAppendsArguments() throws {
        let runner = ClosureProcessRunner { _, _, _ in ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"t\"}}".utf8)) }
        _ = try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token(forceRefresh: true)
        XCTAssertEqual(runner.invocations.first?.arguments, ["auth-helper", "get-token", "--force-refresh"])
    }

    func testNonZeroExitThrows() {
        let runner = ClosureProcessRunner { _, _, _ in ProcessResult(exitCode: 7, standardOutput: Data()) }
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token()) {
            XCTAssertEqual($0 as? TokenProviderError, .commandFailed(exitCode: 7))
        }
    }

    func testConfiguredTimeoutIsPassedToRunner() throws {
        var timedConfig = config
        timedConfig.timeoutSeconds = 12
        let runner = ClosureProcessRunner { _, _, _ in ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"t\"}}".utf8)) }
        _ = try ConfiguredCommandTokenProvider(configuration: timedConfig, runner: runner).token()
        XCTAssertEqual(runner.invocations.first?.timeout, 12)
    }

    func testDefaultTimeoutIs30Seconds() {
        XCTAssertEqual(CommandTokenProviderConfiguration().timeoutSeconds, 30)
    }

    func testRunnerTimeoutErrorSurfacesAsTimedOut() {
        let runner = ClosureProcessRunner { _, _, _ in throw TokenProviderError.timedOut }
        XCTAssertThrowsError(try ConfiguredCommandTokenProvider(configuration: config, runner: runner).token()) {
            XCTAssertEqual($0 as? TokenProviderError, .timedOut)
        }
    }

    func testSubprocessRunnerTerminatesOnTimeoutWithoutLeakingOutput() {
        // A helper that sleeps far past the timeout must be terminated and
        // surface .timedOut. Standard error/out are never captured or echoed.
        let runner = SubprocessRunner()
        let start = Date()
        XCTAssertThrowsError(
            try runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3)
        ) { XCTAssertEqual($0 as? TokenProviderError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.0, "timeout should fire well before the child exits")
    }

    func testSubprocessRunnerDrainsLargeStdoutWithoutDeadlock() throws {
        // Emit far more than a pipe buffer (~64KB) so a naive wait-then-read
        // would deadlock; the background drain must let it complete.
        let big = String(repeating: "a", count: 512 * 1024)
        let runner = SubprocessRunner()
        let result = try runner.run(
            executable: "/bin/echo",
            arguments: [big],
            timeout: 30
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertGreaterThanOrEqual(result.standardOutput.count, 512 * 1024)
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

    func testCommandTokenSupplierReturnsTokenOffCooperativePool() async throws {
        let runner = ClosureProcessRunner { _, _, _ in
            ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"tok\"}}".utf8))
        }
        let supplier = CommandTokenSupplier(provider: ConfiguredCommandTokenProvider(configuration: config, runner: runner))
        let token = try await supplier.token(forceRefresh: false)
        XCTAssertEqual(token.reveal(), "tok")
    }

    func testCommandTokenSupplierCancellationReturnsPromptlyWithoutDoubleResume() async {
        // The runner blocks until released; cancelling the surrounding task must
        // resolve the await promptly with CancellationError, and the later
        // worker completion must not resume the continuation again (a double
        // resume would trap). We release the runner after observing the result.
        let gate = DispatchSemaphore(value: 0)
        let runner = ClosureProcessRunner { _, _, _ in
            gate.wait()
            return ProcessResult(exitCode: 0, standardOutput: Data("{\"status\":\"success\",\"data\":{\"token\":\"late\"}}".utf8))
        }
        let supplier = CommandTokenSupplier(provider: ConfiguredCommandTokenProvider(configuration: config, runner: runner))
        let task = Task { () -> Bool in
            do { _ = try await supplier.token(forceRefresh: false); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        // Give the worker time to start and block on the gate, then cancel.
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled, "cancellation should surface as CancellationError promptly")
        // Release the still-blocked worker; its late completion must be dropped
        // by the latch rather than double-resuming the continuation.
        gate.signal()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
