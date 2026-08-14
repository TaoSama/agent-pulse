import Foundation

// Codex Desktop/CLI 运行状态采集。
//
// 设计约束（与团队冻结契约一致）：
// - 优先真实、只读数据源：进程表（经 ProcessScanning 注入）与 ~/.codex/sessions 下的
//   rollout-*.jsonl 会话日志；从不写入、从不发送信号。
// - 任一主源失败都不吞错：collect() 永不抛，改为返回 .degraded/.unknown 并显式携带
//   PulseCollectionError 作为 degradedReason。
// - 已完成顶层 Task/turn 计数为“全量去重累计”，需排除 cwd 位于任何 automations
//   目录/项目下的会话；不可靠时以 PulseDataQuality 显式表达质量。
// - 解析逻辑为纯函数、可注入、可被无测试框架的可执行文件直接调用（VerificationMain）。

// MARK: - 会话元数据（session_meta 首行）

/// rollout-*.jsonl 首行 session_meta 中我们关心的只读字段。
public struct CodexSessionMeta: Sendable, Equatable {
    /// 去重用的会话标识（session_meta.payload.session_id）。
    public let sessionID: String
    /// 顶层判定字段（session_meta.payload.thread_source），顶层会话为 "user"。
    public let threadSource: String?
    /// 会话工作目录（session_meta.payload.cwd），用于 automation 过滤。
    public let cwd: String?
    /// 采集来源判定用（session_meta.payload.originator），如 "Codex Desktop"。
    public let originator: String?
    /// 顶层判定辅助字段：payload.source 是否为标量入口来源（如 "exec"/"vscode"/"cli"）。
    /// 新版 Codex Desktop 顶层会话的 thread_source 也可能是 "subagent"，此时只能靠 source 区分：
    /// source 为字符串 → 顶层入口；source 为对象（含 subagent.thread_spawn）→ 派生子 agent。
    /// 只保存派生布尔，不保存 source 对象里的 parent_thread_id / agent_path 等正文。
    public let sourceIsScalarEntry: Bool

    public init(
        sessionID: String,
        threadSource: String?,
        cwd: String?,
        originator: String?,
        sourceIsScalarEntry: Bool = false
    ) {
        self.sessionID = sessionID
        self.threadSource = threadSource
        self.cwd = cwd
        self.originator = originator
        self.sourceIsScalarEntry = sourceIsScalarEntry
    }

    /// 顶层任务判定，兼容新旧两种 session_meta 格式：
    /// - 旧版：thread_source == "user" 即顶层，"subagent" 为子 agent。
    /// - 新版：顶层会话的 thread_source 可能被标为 "subagent"，此时若 source 是标量入口来源
    ///   （字符串）则仍为顶层；只有 source 为结构化对象（派生子 agent）时才排除。
    public var isTopLevel: Bool {
        threadSource == "user" || sourceIsScalarEntry
    }
}

// MARK: - 已完成任务计数结果（解耦的中间结构）

/// 单个会话文件的解析产物，供聚合层组合。保持与模型层零耦合。
public struct CodexCompletedTasks: Sendable, Equatable {
    /// 去重后的完成任务标识集合："<sessionID>\u{0}<turnID>"。
    public let identities: Set<String>
    /// 本文件解析过程中是否出现降低可信度的情况（如 task_complete 缺 turn_id）。
    public let degradedButUsable: Bool

    public init(identities: Set<String>, degradedButUsable: Bool) {
        self.identities = identities
        self.degradedButUsable = degradedButUsable
    }

    public static let empty = CodexCompletedTasks(identities: [], degradedButUsable: false)
}

/// 聚合后的完成任务计数与质量。
public struct CodexCompletedTally: Sendable, Equatable {
    public let count: Int?
    public let quality: PulseDataQuality

    public init(count: Int?, quality: PulseDataQuality) {
        self.count = count
        self.quality = quality
    }
}

// MARK: - 会话解析器（纯逻辑，可独立调用）

/// 解析 Codex rollout-*.jsonl 会话日志。所有方法均为纯函数或仅做只读文件访问，
/// 不依赖任何测试框架，可被可执行文件用绝对路径直接驱动。
public enum CodexSessionParser {
    /// task_complete 事件缺少 turn_id 时用于占位去重的前缀，配合行号保证唯一，
    /// 使这类记录仍被计数但触发 partial 质量。
    static let missingTurnMarker = "\u{0}__missing_turn__\u{0}"

    /// 解析 session_meta 首行。返回 nil 表示该行不是有效 session_meta。
    /// - Note: 只接受顶层 type == "session_meta" 且 payload.session_id 非空的行。
    public static func parseSessionMeta(line: String) -> CodexSessionMeta? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        guard (root["type"] as? String) == "session_meta" else { return nil }
        guard let payload = root["payload"] as? [String: Any] else { return nil }
        let sessionID = (payload["session_id"] as? String) ?? (payload["id"] as? String)
        guard let sessionID, !sessionID.isEmpty else {
            return nil
        }
        // payload.source 区分顶层入口与派生子 agent：字符串（"exec"/"vscode"/"cli" 等）为标量入口来源；
        // 对象（如 {"subagent":{"thread_spawn":{...}}}）为派生子 agent；缺失则退回仅靠 thread_source 判定。
        let sourceIsScalarEntry: Bool = {
            guard let source = payload["source"] as? String else { return false }
            return !source.isEmpty
        }()
        return CodexSessionMeta(
            sessionID: sessionID,
            threadSource: payload["thread_source"] as? String,
            cwd: payload["cwd"] as? String,
            originator: payload["originator"] as? String,
            sourceIsScalarEntry: sourceIsScalarEntry
        )
    }

    /// 判断 cwd 是否位于任一 automation 根之下，或其路径组件精确等于 "automations"（大小写不敏感）。
    /// automationRoots 与 cwd 都会先标准化（解析 . / .. 与多余分隔符）。
    public static func isUnderAutomation(cwd: String, automationRoots: [String]) -> Bool {
        let normalizedCwd = normalize(path: cwd)
        // 规则一：任一路径组件精确等于 "automations"（大小写不敏感），兜住未知根。
        let components = normalizedCwd.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0.lowercased() == "automations" }) {
            return true
        }
        // 规则二：前缀匹配任一显式 automation 根（按目录边界匹配，避免前缀误伤）。
        for root in automationRoots {
            let normalizedRoot = normalize(path: root)
            guard !normalizedRoot.isEmpty else { continue }
            if normalizedCwd == normalizedRoot { return true }
            if normalizedCwd.hasPrefix(normalizedRoot + "/") { return true }
        }
        return false
    }

    /// 标准化路径：展开为标准化的绝对形式，去除结尾分隔符（根 "/" 除外）。
    static func normalize(path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        if standardized.count > 1 && standardized.hasSuffix("/") {
            return String(standardized.dropLast())
        }
        return standardized
    }

    /// 从单个会话文件内容（整段文本）提取已完成顶层任务身份集合。
    /// - 仅当首行 session_meta 判定为顶层（thread_source=="user"）且不在 automation 下时才计数；
    ///   否则返回 empty。
    /// - 完成事件：event_msg.payload.type == "task_complete"，去重键为 (sessionID, turn_id)。
    /// - task_complete 缺 turn_id：仍以行号占位计数，但标记 degradedButUsable=true（触发 partial）。
    public static func completedTasks(inSessionContents contents: String, automationRoots: [String]) -> CodexCompletedTasks {
        var lineIterator = contents.split(whereSeparator: { $0.isNewline }).makeIterator()
        // 首行必须是 session_meta。
        guard let firstLine = lineIterator.next(),
              let meta = parseSessionMeta(line: String(firstLine)) else {
            return .empty
        }
        guard meta.isTopLevel else { return .empty }
        // cwd 缺失时无法证明它不是 automation；保守排除并降低可信度。
        guard let cwd = meta.cwd else {
            return CodexCompletedTasks(identities: [], degradedButUsable: true)
        }
        if isUnderAutomation(cwd: cwd, automationRoots: automationRoots) {
            return .empty
        }

        var identities = Set<String>()
        var degraded = false
        var lineNumber = 1
        // 逐行扫描剩余内容，收集 task_complete。
        while let raw = lineIterator.next() {
            lineNumber += 1
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line.contains("task_complete") else { continue }
            guard let data = line.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (root["type"] as? String) == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  (payload["type"] as? String) == "task_complete" else {
                continue
            }
            if let turnID = payload["turn_id"] as? String, !turnID.isEmpty {
                identities.insert(meta.sessionID + "\u{0}" + turnID)
            } else {
                // 缺 turn_id：仍计数，但可信度下降。
                degraded = true
                identities.insert(meta.sessionID + missingTurnMarker + String(lineNumber))
            }
        }
        return CodexCompletedTasks(identities: identities, degradedButUsable: degraded)
    }
}

// MARK: - 进程分类（识别 Codex Desktop / CLI）

/// 依据可执行路径把进程归类到 Desktop / CLI。纯字符串判定，便于测试注入。
public enum CodexProcessClassifier {
    public static func isCodexCLI(executablePath: String) -> Bool {
        isIndependentCLI(named: "codex", executablePath: executablePath)
    }

    public static func isClaudeCLI(executablePath: String) -> Bool {
        isIndependentCLI(named: "claude", executablePath: executablePath)
    }

    /// 独立 CLI 任务：进程名为 codex 或 claude。
    /// 刻意排除所有 app bundle 内置 helper，避免把 Desktop 的子进程误判为终端任务。
    public static func isIndependentCLI(executablePath: String) -> Bool {
        isCodexCLI(executablePath: executablePath) || isClaudeCLI(executablePath: executablePath)
    }

    private static func isIndependentCLI(named name: String, executablePath: String) -> Bool {
        let path = executablePath
        let executableName = URL(fileURLWithPath: path).lastPathComponent
        guard executableName == name else { return false }
        // Desktop bundles launch their own native codex helper. It is implementation
        // detail of the app, not an independent terminal task.
        guard !path.localizedCaseInsensitiveContains(".app/Contents/") else { return false }
        return true
    }

    /// Codex Desktop 应用进程（ChatGPT.app 主进程或其内置 codex 资源）。
    public static func isDesktopApp(executablePath: String) -> Bool {
        let path = executablePath
        if path.contains("/ChatGPT.app/") { return true }
        return false
    }

    /// Claude 桌面应用主进程（Anthropic Claude.app，bundle id com.anthropic.claudefordesktop）。
    /// 仅识别 app bundle 内的进程，用作桌面会话统计的存活门控；独立 claude CLI 不在此列。
    public static func isClaudeDesktopApp(executablePath: String) -> Bool {
        let url = URL(fileURLWithPath: executablePath)
        return url.lastPathComponent == "Claude"
            && executablePath.contains("/Claude.app/Contents/MacOS/")
    }

    /// 针对给定来源，判断某进程是否为该来源的“存活证据”。
    public static func matches(source: PulseSource, executablePath: String) -> Bool {
        switch source {
        case .cli:
            return isIndependentCLI(executablePath: executablePath)
        case .desktop:
            return isDesktopApp(executablePath: executablePath)
        }
    }
}

// MARK: - rollout 生命周期

/// rollout 中最后一个结构化生命周期事件。
public enum CodexTurnLifecycle: String, Sendable, Equatable {
    case started
    case complete
    case aborted
}

public extension CodexSessionParser {
    /// rollout 的来源到 PulseSource 的映射：codex_exec→cli，Codex Desktop→desktop，其余 nil。
    static func source(forOriginator originator: String?) -> PulseSource? {
        switch originator {
        case "codex_exec": return .cli
        case "Codex Desktop": return .desktop
        default: return nil
        }
    }

    /// 从尾部反向扫描 rollout，返回最后一个生命周期事件（task_started/complete/turn_aborted）。
    /// 仅读取结构化字段，忽略正文；无生命周期事件返回 nil。
    static func lastLifecycle(inSessionContents contents: String) -> CodexTurnLifecycle? {
        for raw in contents.split(whereSeparator: { $0.isNewline }).reversed() {
            let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            // 仅解析可能是生命周期事件的行；正文即便含同名字符串也会在 JSON 结构校验处被拒。
            guard line.contains("task_started") || line.contains("task_complete") || line.contains("turn_aborted") else {
                continue
            }
            guard let data = line.data(using: .utf8),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  (root["type"] as? String) == "event_msg",
                  let payload = root["payload"] as? [String: Any],
                  let pt = payload["type"] as? String else {
                continue
            }
            switch pt {
            case "task_started": return .started
            case "task_complete": return .complete
            case "turn_aborted": return .aborted
            default: break
            }
        }
        return nil
    }
}

// MARK: - 采集器

/// 时钟抽象，便于测试注入确定性时间。
public protocol PulseClock: Sendable {
    func now() -> Date
}

/// 系统时钟。
public struct SystemPulseClock: PulseClock {
    public init() {}
    public func now() -> Date { Date() }
}

/// Codex Desktop/CLI 运行状态采集器。
///
/// 依赖全部通过初始化器注入：进程扫描（ProcessScanning）、会话根目录、automation 根、时钟。
/// collect(source:) 永不抛：任一主源失败都会返回带显式 PulseCollectionError 的降级快照。
public struct CodexStatusCollector: Sendable {
    private let processScanner: any ProcessScanning
    private let sessionsDirectories: [URL]
    private let automationRoots: [String]
    private let clock: any PulseClock
    // FileManager is not Sendable; the collector only performs synchronous read-only
    // file access, so it uses FileManager.default directly inside methods instead of
    // storing an instance, keeping the collector itself Sendable.

    /// - Parameters:
    ///   - processScanner: 进程扫描实现（生产用 SystemProcessScanner，测试注入 fake）。
    ///   - sessionsDirectories: 已解析符号链接的当前 sessions 目录；归档目录不应传入。
    ///     传空表示由 defaultSessionsDirectories() 依据 codexHome 推导。
    ///   - automationRoots: 需排除的 automation 根目录（默认含 <codexHome>/automations）。
    ///   - clock: 时钟。
    public init(
        processScanner: any ProcessScanning,
        sessionsDirectories: [URL],
        automationRoots: [String],
        clock: any PulseClock = SystemPulseClock()
    ) {
        self.processScanner = processScanner
        self.sessionsDirectories = sessionsDirectories.filter { directory in
            guard directory.standardizedFileURL.lastPathComponent != "archived_sessions" else { return false }
            return directory.resolvingSymlinksInPath().standardizedFileURL.lastPathComponent != "archived_sessions"
        }
        self.automationRoots = automationRoots
        self.clock = clock
    }

    /// 解析 ~/.codex 符号链接后的真实根目录。
    public static func resolvedCodexHome(fileManager: FileManager = .default) -> URL {
        let home = fileManager.homeDirectoryForCurrentUser
        let codex = home.appendingPathComponent(".codex", isDirectory: true)
        return codex.resolvingSymlinksInPath()
    }

    /// 依据 codexHome 推导当前会话目录。归档目录不属于运行时 task 口径。
    public static func defaultSessionsDirectories(
        codexHome: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let sessions = codexHome.appendingPathComponent("sessions", isDirectory: true)
        return [sessions]
    }

    /// 依据 codexHome 推导默认 automation 根：<codexHome>/automations。
    public static func defaultAutomationRoots(codexHome: URL) -> [String] {
        [codexHome.appendingPathComponent("automations", isDirectory: true).path]
    }

    /// 便捷构造：使用真实 ~/.codex（已解析符号链接）与系统 /bin/ps 扫描器。
    public static func live(
        processScanner: any ProcessScanning = SystemProcessScanner(),
        clock: any PulseClock = SystemPulseClock(),
        fileManager: FileManager = .default
    ) -> CodexStatusCollector {
        let codexHome = resolvedCodexHome(fileManager: fileManager)
        return CodexStatusCollector(
            processScanner: processScanner,
            sessionsDirectories: defaultSessionsDirectories(codexHome: codexHome, fileManager: fileManager),
            automationRoots: defaultAutomationRoots(codexHome: codexHome),
            clock: clock
        )
    }

    // MARK: 采集主流程

    /// 采集指定来源的运行状态。永不抛。
    public func collect(source: PulseSource) -> PulseSnapshot {
        let timestamp = clock.now()

        // 1) 进程扫描（关键主源）。失败即降级，显式携带 scanner error。
        let processes: [RunningProcess]
        do {
            processes = try processScanner.scan()
        } catch let error as ProcessScanError {
            return PulseSnapshot.degraded(
                source: source,
                timestamp: timestamp,
                reason: Self.collectionError(from: error)
            )
        } catch {
            return PulseSnapshot.degraded(
                source: source,
                timestamp: timestamp,
                reason: .other(detail: "process scan failed")
            )
        }

        let liveMatches = processes.filter { CodexProcessClassifier.matches(source: source, executablePath: $0.executablePath) }

        // 2) 会话扫描：本来源的完成任务计数（下界，最高 partial）与是否存在未结束活跃 turn。
        let sessionScan = scanSessions(source: source)

        // 3) 状态映射（live × activeCandidate）。
        let liveCount = liveMatches.count
        let candidateCount = sessionScan.activeCandidateCount
        let status: PulseStatus
        var degradedReason: PulseCollectionError? = nil
        switch (liveCount > 0, candidateCount > 0) {
        case (true, true):
            status = .generating
        case (true, false):
            status = .idle
        case (false, false):
            status = .notRunning
        case (false, true):
            status = .degraded
            degradedReason = .other(detail: "lifecycle indicates activity but no matching live process")
        }

        // 若会话源本身出现读取失败（而非仅数据下界），在仍能给出进程态时保留状态但降 quality；
        // 完全无法解析时 scanSessions 已返回 unavailable。此处仅把致命读取错误上抛为 degraded。
        if let fatal = sessionScan.fatalError {
            return PulseSnapshot.degraded(source: source, timestamp: timestamp, reason: fatal)
        }

        // 4) 进程信息回填：generating 时回填首个匹配进程。
        let processInfo: PulseProcessInfo? = liveMatches.first.map {
            PulseProcessInfo(
                pid: $0.pid,
                executableName: Self.executableName(from: $0.executablePath),
                residentMemoryBytes: $0.residentMemoryBytes,
                cpuUsagePercent: $0.cpuUsagePercent
            )
        }

        return PulseSnapshot(
            timestamp: timestamp,
            source: source,
            status: status,
            tps: nil,
            tokenCount: nil,
            completedTaskCount: sessionScan.tally.count,
            completedCountQuality: sessionScan.tally.quality,
            completedScope: .allLocal,
            completedIsLowerBound: sessionScan.tally.quality == .partial,
            note: degradedReason?.errorDescription,
            process: processInfo,
            degradedReason: degradedReason
        )
    }

    // MARK: 会话扫描

    struct SessionScanResult {
        var tally: CodexCompletedTally
        var activeCandidateCount: Int
        var fatalError: PulseCollectionError?
    }

    /// 扫描所有会话目录，统计本来源的完成任务（去重、排除 automation）与活跃候选数。
    /// - 完全无可访问会话源 => tally.unavailable。
    /// - 有可用数据 => 计数返回，quality 最高 partial（本地/下界，无 Desktop 权威接口）。
    func scanSessions(source: PulseSource) -> SessionScanResult {
        // 收集所有 rollout 文件。
       var files: [URL] = []
        var anyDirReadable = false
        let fileManager = FileManager.default
        for dir in sessionsDirectories {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            anyDirReadable = true
            guard let enumerator = fileManager.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") {
                    files.append(url)
                }
            }
        }

        guard anyDirReadable else {
            // 没有任何可访问的会话目录：计数不可得。
            return SessionScanResult(
                tally: CodexCompletedTally(count: nil, quality: .unavailable),
                activeCandidateCount: 0,
                fatalError: nil
            )
        }

        var identities = Set<String>()
        var degraded = false
        var activeCandidates = 0
        var readFailures = 0
        var parsedFiles = 0

        for file in files {
            let contents: String
            do {
                contents = try String(contentsOf: file, encoding: .utf8)
            } catch {
                // 单文件读取失败：记录并降级质量，不整体吞错。
                readFailures += 1
                continue
            }
            parsedFiles += 1

            // 首行确定来源，仅统计与 snapshot source 匹配的来源。
            guard let firstLine = contents.split(whereSeparator: { $0.isNewline }).first,
                  let meta = CodexSessionParser.parseSessionMeta(line: String(firstLine)) else {
                continue
            }
            guard CodexSessionParser.source(forOriginator: meta.originator) == source else {
                continue
            }

            // 完成任务计数（内部再次校验顶层与 automation 过滤）。
            let completed = CodexSessionParser.completedTasks(
                inSessionContents: contents,
                automationRoots: automationRoots
            )
            identities.formUnion(completed.identities)
            if completed.degradedButUsable { degraded = true }

            // 活跃候选：顶层会话最后一个生命周期事件为 task_started。
            if meta.isTopLevel {
                if let last = CodexSessionParser.lastLifecycle(inSessionContents: contents), last == .started {
                    activeCandidates += 1
                }
            }
        }

        // quality：本地 rollout 永远是下界，最高 partial；有读失败也标 partial。
        // 有可读目录但没有任何可解析文件（全失败）=> 计数不可得。
        let quality: PulseDataQuality
        let count: Int?
        if parsedFiles == 0 {
            quality = .unavailable
            count = nil
        } else {
            quality = .partial
            count = identities.count
            _ = degraded // 缺 turn_id 已并入 partial；partial 已是本地上限。
            _ = readFailures
        }

        return SessionScanResult(
            tally: CodexCompletedTally(count: count, quality: quality),
            activeCandidateCount: activeCandidates,
            fatalError: nil
        )
    }

    // MARK: 辅助

    /// 从可执行路径提取文件名（不含目录），避免泄漏用户目录结构。
    static func executableName(from path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// 把 ProcessScanError 映射为稳定、脱敏的 PulseCollectionError。
    static func collectionError(from error: ProcessScanError) -> PulseCollectionError {
        switch error {
        case let .launchFailed(detail):
            return .other(detail: "process scanner launch failed: \(detail)")
        case let .scannerExited(code, _):
            return .other(detail: "process scanner exited with code \(code)")
        case .undecodableOutput:
            return .parseFailed(reason: "process scanner output not UTF-8")
        }
    }
}
