import XCTest
@testable import AgentPulseCore

/// CodexStatusCollector / ProcessScanning / 会话解析器测试。
///
/// 说明：本环境可能缺少 XCTest 运行时；按团队约束仍以 XCTestCase 编写。
/// 所有被测公共 API 均为无框架可调用（纯函数 + 注入 + 绝对路径 fixtures），
/// 因此同一批断言也可由无框架的验证可执行文件复用。
final class CodexStatusCollectorTests: XCTestCase {

    // MARK: Fixtures 定位（不依赖 Bundle.module，可被无框架 executable 复用同一目录）

    /// Fixtures 目录：相对本测试源文件解析，避免依赖测试 bundle。
    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    static func fixture(_ name: String) throws -> String {
        let url = fixturesDirectory.appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: ps 解析

    func testProcessScannerParsesPidRssCpuAndCommandWithSpaces() {
        let sample = [
            "  59014 123456 12.5 /Applications/ChatGPT.app/Contents/Resources/codex",
            "  34418 654321 0.0 /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex",
            "  58979 999999 3.2 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            "",
            "garbage line without pid"
        ].joined(separator: "\n")
        let procs = SystemProcessScanner.parse(psOutput: sample)
        XCTAssertEqual(procs.count, 3)
        XCTAssertEqual(procs[0].pid, 59014)
        XCTAssertEqual(procs[0].residentMemoryBytes, 123456 * 1024)
        XCTAssertEqual(procs[0].cpuUsagePercent, 12.5)
        XCTAssertEqual(procs[0].executablePath, "/Applications/ChatGPT.app/Contents/Resources/codex")
        XCTAssertTrue(procs[1].executablePath.contains("@openai/codex"))
    }

    func testProcessClassifier() {
        XCTAssertTrue(CodexProcessClassifier.isIndependentCLI(executablePath: "/opt/homebrew/lib/node_modules/@openai/codex/vendor/x/bin/codex"))
        XCTAssertFalse(CodexProcessClassifier.isIndependentCLI(executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"))
        XCTAssertTrue(CodexProcessClassifier.isDesktopApp(executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        XCTAssertTrue(CodexProcessClassifier.matches(source: .cli, executablePath: "/x/@openai/codex/bin/codex"))
        XCTAssertTrue(CodexProcessClassifier.matches(source: .desktop, executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
    }

    // MARK: session_meta 解析

    func testParseSessionMeta() throws {
        let contents = try Self.fixture("cli_user_two_complete.jsonl")
        let firstLine = String(contents.split(whereSeparator: { $0.isNewline }).first!)
        let meta = CodexSessionParser.parseSessionMeta(line: firstLine)
        XCTAssertNotNil(meta)
        XCTAssertEqual(meta?.sessionID, "11111111-1111-7111-8111-111111111111")
        XCTAssertEqual(meta?.threadSource, "user")
        XCTAssertEqual(meta?.originator, "codex_exec")
        XCTAssertTrue(meta!.isTopLevel)
        XCTAssertEqual(CodexSessionParser.source(forOriginator: meta?.originator), .cli)
    }

    func testParseSessionMetaRejectsNonMeta() {
        XCTAssertNil(CodexSessionParser.parseSessionMeta(line: "not json"))
        XCTAssertNil(CodexSessionParser.parseSessionMeta(line: "{\"type\":\"event_msg\",\"payload\":{}}"))
        XCTAssertNil(CodexSessionParser.parseSessionMeta(line: ""))
    }

    // MARK: automation 过滤

    func testAutomationComponentMatch() {
        XCTAssertTrue(CodexSessionParser.isUnderAutomation(cwd: "/workspace/.codex/automations/x", automationRoots: []))
        XCTAssertTrue(CodexSessionParser.isUnderAutomation(cwd: "/workspace/Automations/x", automationRoots: []))
        // 不得误伤形似目录名。
        XCTAssertFalse(CodexSessionParser.isUnderAutomation(cwd: "/workspace/my-automations-demo/x", automationRoots: []))
        // 显式 root 前缀（按目录边界）。
        XCTAssertTrue(CodexSessionParser.isUnderAutomation(cwd: "/opt/robot/jobs/y", automationRoots: ["/opt/robot/jobs"]))
        XCTAssertFalse(CodexSessionParser.isUnderAutomation(cwd: "/opt/robot/jobs-extra", automationRoots: ["/opt/robot/jobs"]))
    }

    // MARK: 完成任务计数 + 去重 + 边界

    func testCompletedTasksCountsTopLevelDistinctTurns() throws {
        let contents = try Self.fixture("cli_user_two_complete.jsonl")
        let r = CodexSessionParser.completedTasks(inSessionContents: contents, automationRoots: [])
        XCTAssertEqual(r.identities.count, 2)
        XCTAssertFalse(r.degradedButUsable)
    }

    func testCompletedTasksDeduplicatesSameTurnID() throws {
        let contents = try Self.fixture("cli_user_duplicate_turn.jsonl")
        let r = CodexSessionParser.completedTasks(inSessionContents: contents, automationRoots: [])
        XCTAssertEqual(r.identities.count, 1)
    }

    func testCompletedTasksMissingTurnIsUsableButDegraded() throws {
        let contents = try Self.fixture("cli_user_missing_turn.jsonl")
        let r = CodexSessionParser.completedTasks(inSessionContents: contents, automationRoots: [])
        XCTAssertEqual(r.identities.count, 1)
        XCTAssertTrue(r.degradedButUsable)
    }

    func testCompletedTasksExcludesSubagent() throws {
        let contents = try Self.fixture("subagent_excluded.jsonl")
        let r = CodexSessionParser.completedTasks(inSessionContents: contents, automationRoots: [])
        XCTAssertEqual(r.identities.count, 0)
    }

    func testCompletedTasksExcludesAutomationCwd() throws {
        let contents = try Self.fixture("automation_excluded.jsonl")
        let r = CodexSessionParser.completedTasks(inSessionContents: contents, automationRoots: [])
        XCTAssertEqual(r.identities.count, 0)
    }

    func testLastLifecycle() throws {
        let active = try Self.fixture("cli_user_active.jsonl")
        XCTAssertEqual(CodexSessionParser.lastLifecycle(inSessionContents: active), .started)
        let complete = try Self.fixture("cli_user_two_complete.jsonl")
        XCTAssertEqual(CodexSessionParser.lastLifecycle(inSessionContents: complete), .complete)
        let aborted = try Self.fixture("aborted_last.jsonl")
        XCTAssertEqual(CodexSessionParser.lastLifecycle(inSessionContents: aborted), .aborted)
    }

    // MARK: 采集器状态映射（注入 fake 进程扫描 + fixtures 目录）

    struct FakeScanner: ProcessScanning {
        let result: Result<[RunningProcess], ProcessScanError>
        func scan() throws -> [RunningProcess] {
            switch result {
            case let .success(v): return v
            case let .failure(e): throw e
            }
        }
    }

    struct FixedClock: PulseClock {
        let date: Date
        func now() -> Date { date }
    }

    func makeCollector(processes: Result<[RunningProcess], ProcessScanError>) -> CodexStatusCollector {
        CodexStatusCollector(
            processScanner: FakeScanner(result: processes),
            sessionsDirectories: [Self.fixturesDirectory],
            automationRoots: [],
            clock: FixedClock(date: Date(timeIntervalSince1970: 1_786_298_400))
        )
    }

    func testCollectGeneratingWhenLiveProcessAndActiveCandidate() {
        // fixtures 含 CLI 活跃候选（cli_user_active）。提供一个匹配的 live CLI 进程。
        let cli = RunningProcess(pid: 42, executablePath: "/x/@openai/codex/bin/codex", residentMemoryBytes: 2048, cpuUsagePercent: 7.0)
        let snapshot = makeCollector(processes: .success([cli])).collect(source: .cli)
        XCTAssertEqual(snapshot.status, .generating)
        XCTAssertEqual(snapshot.process?.pid, 42)
        XCTAssertEqual(snapshot.process?.residentMemoryBytes, 2048)
        XCTAssertEqual(snapshot.completedCountQuality, .partial)
        XCTAssertEqual(snapshot.completedScope, .allLocal)
        XCTAssertTrue(snapshot.completedIsLowerBound)
        // CLI 来源已完成：two_complete(2) + duplicate(1) + missing(1) + active(0) + aborted(0) = 4。
        XCTAssertEqual(snapshot.completedTaskCount, 4)
    }

    func testCollectDegradedWhenCandidateButNoLiveProcess() {
        let snapshot = makeCollector(processes: .success([])).collect(source: .cli)
        XCTAssertEqual(snapshot.status, .degraded)
        XCTAssertNotNil(snapshot.degradedReason)
        if case .other = snapshot.degradedReason {} else { XCTFail("expected .other") }
    }

    func testCollectDesktopCountsOnlyDesktopOriginator() {
        let desktop = RunningProcess(pid: 7, executablePath: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        let snapshot = makeCollector(processes: .success([desktop])).collect(source: .desktop)
        // desktop_user_one_complete 提供 1 个；无 desktop 活跃候选 => idle。
        XCTAssertEqual(snapshot.completedTaskCount, 1)
        XCTAssertEqual(snapshot.status, .idle)
    }

    func testCollectProcessScanFailureIsDegradedWithExplicitError() {
        let snapshot = makeCollector(processes: .failure(.launchFailed("boom"))).collect(source: .cli)
        XCTAssertEqual(snapshot.status, .degraded)
        XCTAssertNotNil(snapshot.degradedReason)
        XCTAssertNil(snapshot.completedTaskCount)
    }

    func testCollectUnavailableWhenNoSessionsDirectory() {
        let collector = CodexStatusCollector(
            processScanner: FakeScanner(result: .success([])),
            sessionsDirectories: [URL(fileURLWithPath: "/nonexistent-agentpulse-dir-xyz")],
            automationRoots: [],
            clock: FixedClock(date: Date(timeIntervalSince1970: 1_786_298_400))
        )
        let snapshot = collector.collect(source: .cli)
        XCTAssertEqual(snapshot.completedCountQuality, .unavailable)
        XCTAssertNil(snapshot.completedTaskCount)
        XCTAssertEqual(snapshot.status, .notRunning)
    }
}
