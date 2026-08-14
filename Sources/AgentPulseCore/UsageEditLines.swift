import Foundation

/// 单笔已应用编辑的行增删贡献。
public struct UsageEditDelta: Sendable, Equatable {
    public var added: Int64
    public var deleted: Int64
    public init(added: Int64 = 0, deleted: Int64 = 0) {
        self.added = added
        self.deleted = deleted
    }
}

/// 一条已应用、可去重、可归属到用量桶的编辑记录。
///
/// 它是代码行数指标（codeMetricVersion=2）在原始事件层的载体，与 token 事件平行：
/// 携带 source/model/project/timestamp 供后续按同一 (source, model, project, 半小时桶)
/// 归并，并以 toolUseID 做跨文件 / 跨重解析去重。
public struct UsageEditEntry: Codable, Sendable, Equatable {
    public let source: String
    public let model: String
    public let project: String
    public let sourceFileHash: String
    public let timestamp: Date
    public let added: Int64
    public let deleted: Int64
    /// 稳定的每笔编辑标识（Claude 的 tool_use.id / Codex 的 call_id），去重键。
    public let toolUseID: String

    public init(source: String, model: String, project: String, sourceFileHash: String = "", timestamp: Date, added: Int64, deleted: Int64, toolUseID: String) {
        self.source = source
        self.model = model.isEmpty ? "unknown" : model
        self.project = project.isEmpty ? "unknown" : project
        self.sourceFileHash = sourceFileHash
        self.timestamp = timestamp
        self.added = max(0, added)
        self.deleted = max(0, deleted)
        self.toolUseID = toolUseID
    }

    private enum CodingKeys: String, CodingKey {
        case source, model, project, sourceFileHash, timestamp, added, deleted, toolUseID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            source: try container.decode(String.self, forKey: .source),
            model: try container.decode(String.self, forKey: .model),
            project: try container.decode(String.self, forKey: .project),
            sourceFileHash: try container.decodeIfPresent(String.self, forKey: .sourceFileHash) ?? "",
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            added: try container.decode(Int64.self, forKey: .added),
            deleted: try container.decode(Int64.self, forKey: .deleted),
            toolUseID: try container.decode(String.self, forKey: .toolUseID)
        )
    }
}

/// 从工具调用的结构化编辑载荷计算「真实的 AI 撰写行数」。
///
/// 覆盖两类会话形态：
/// - 结构化 old/new 文本的编辑工具（Edit / Write / MultiEdit / NotebookEdit）：按行做
///   最长公共子序列差分，added = 新行数 - lcs，deleted = 旧行数 - lcs（改 1 行只记 1/1，
///   不因所在块大小膨胀）。
/// - 统一 diff 补丁（apply_patch 正文）：逐行数 +/- 前缀，排除 +++/---/@@/*** 指令行，
///   按补丁内的文件段路径决定是否整段跳过（生成 / 供应 / 锁文件）。
///
/// 只统计「已应用且成功」的编辑：编辑工具需存在对应的成功 tool_result，补丁需有成功的
/// 执行输出。被提出但失败 / 被拒的编辑绝不计入。单笔编辑任一方向超过上限视为生成 / 数据
/// 块，整笔清零。所有计数 >= 0。
public enum UsageEditLines {
    /// 单笔编辑任一方向的行数上限；超过即整笔清零（视为生成 / 供应 / 数据块而非撰写代码）。
    public static let maxCountedEditLines: Int64 = 2000

    /// 由真实编辑提取得到的代码行数所标记的度量版本。
    public static let codeMetricVersion = 2

    // MARK: - 行差分

    /// 按行 LCS 计算 (added, deleted)。
    public static func lineDiff(_ oldText: String, _ newText: String) -> UsageEditDelta {
        let oldLines = splitLines(oldText)
        let newLines = splitLines(newText)
        let lcs = lcsLength(oldLines, newLines)
        let added = Int64(newLines.count - lcs)
        let deleted = Int64(oldLines.count - lcs)
        return UsageEditDelta(added: max(0, added), deleted: max(0, deleted))
    }

    /// 以 \n 切分，并丢弃单个末尾空元素，使末尾换行不虚增行数。
    static func splitLines(_ s: String) -> [Substring] {
        if s.isEmpty { return [] }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        if let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    /// 两个行序列的最长公共子序列长度。O(n*m) 时间、O(min) 空间滚动数组。
    static func lcsLength(_ a: [Substring], _ b: [Substring]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        var long = a
        var short = b
        if short.count > long.count { swap(&long, &short) }
        var prev = [Int](repeating: 0, count: short.count + 1)
        var curr = [Int](repeating: 0, count: short.count + 1)
        for i in 1...long.count {
            for j in 1...short.count {
                if long[i - 1] == short[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else if prev[j] >= curr[j - 1] {
                    curr[j] = prev[j]
                } else {
                    curr[j] = curr[j - 1]
                }
            }
            swap(&prev, &curr)
        }
        return prev[short.count]
    }

    /// 单笔编辑任一方向超过上限则整笔清零，否则原样返回。
    static func cap(_ delta: UsageEditDelta) -> UsageEditDelta {
        if delta.added > maxCountedEditLines || delta.deleted > maxCountedEditLines {
            return UsageEditDelta()
        }
        return delta
    }

    // MARK: - 生成 / 供应 / 锁文件路径过滤

    private static let generatedLockBasenames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "go.sum",
        "cargo.lock", "composer.lock", "poetry.lock", "gemfile.lock",
        "bun.lockb", "podfile.lock", "flake.lock",
    ]
    private static let generatedSuffixes = [
        ".min.js", ".min.css", ".pb.go", "_pb2.py",
        ".g.dart", ".freezed.dart", ".generated.go", "_gen.go", ".lock",
    ]
    private static let generatedComponents = [
        "node_modules", "vendor", "dist", "build",
        ".next", "target", ".venv", "site-packages", "third_party", ".git",
    ]

    /// 判断路径是否为不计入撰写行数的生成 / 供应 / 锁内容。空路径不过滤。
    public static func isGeneratedEditPath(_ path: String) -> Bool {
        if path.isEmpty { return false }
        let lower = path.lowercased()
        var base = lower
        if let idx = base.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            base = String(base[base.index(after: idx)...])
        }
        if generatedLockBasenames.contains(base) { return true }
        for suffix in generatedSuffixes where lower.hasSuffix(suffix) { return true }
        // 路径按组件精确匹配：先把反斜杠归一为 /，去掉首尾 /，再用 / 包裹，避免误伤
        // 同名前缀目录（例如与受控目录同前缀但不同的目录名）。
        let normalized = lower.replacingOccurrences(of: "\\", with: "/")
        let trimmed = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let component = "/" + trimmed + "/"
        for dir in generatedComponents where component.contains("/" + dir + "/") { return true }
        return false
    }

    // MARK: - Claude 结构化编辑工具

    /// 从单个 Claude tool_use 内容块提取编辑行增删。
    /// 返回 nil 表示该块不是编辑工具或路径被排除。
    public static func claudeToolUseEditLines(_ part: [String: Any]) -> UsageEditDelta? {
        guard let name = part["name"] as? String,
              let input = part["input"] as? [String: Any] else { return nil }
        let filePath = (input["file_path"] as? String) ?? ""
        if isGeneratedEditPath(filePath) { return nil }
        switch name {
        case "Edit":
            let oldS = (input["old_string"] as? String) ?? ""
            let newS = (input["new_string"] as? String) ?? ""
            return cap(lineDiff(oldS, newS))
        case "Write":
            let content = (input["content"] as? String) ?? ""
            return cap(UsageEditDelta(added: Int64(splitLines(content).count), deleted: 0))
        case "NotebookEdit":
            let oldS = (input["old_source"] as? String) ?? ""
            let newS = (input["new_source"] as? String) ?? ""
            return cap(lineDiff(oldS, newS))
        case "MultiEdit":
            let edits = (input["edits"] as? [Any]) ?? []
            var total = UsageEditDelta()
            for e in edits {
                guard let em = e as? [String: Any] else { continue }
                let oldS = (em["old_string"] as? String) ?? ""
                let newS = (em["new_string"] as? String) ?? ""
                let d = lineDiff(oldS, newS)
                total.added += d.added
                total.deleted += d.deleted
            }
            return cap(total)
        default:
            return nil
        }
    }

    // MARK: - Codex apply_patch 正文

    /// 从一段 shell 命令文本中解析 apply_patch 正文的行增删。
    /// 返回 nil 表示不是 apply_patch 调用或无有效增删。按文件段路径排除生成 / 供应内容。
    public static func codexApplyPatchLines(_ command: String) -> UsageEditDelta? {
        guard let beginRange = command.range(of: "*** Begin Patch") else { return nil }
        var body = String(command[beginRange.lowerBound...])
        if let endRange = body.range(of: "*** End Patch") {
            body = String(body[..<endRange.lowerBound])
        }
        var total = UsageEditDelta()
        var skipFile = false
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("*** Begin Patch") { continue }
            if line.hasPrefix("*** Update File:") || line.hasPrefix("*** Add File:") || line.hasPrefix("*** Delete File:") {
                skipFile = isGeneratedEditPath(pathAfterColon(line))
                continue
            }
            if line.hasPrefix("*** Move to:") {
                // 移动后归属以目标路径为准重新判定。
                skipFile = isGeneratedEditPath(pathAfterColon(line))
                continue
            }
            if line.hasPrefix("***") || line.hasPrefix("@@") { continue }
            if skipFile { continue }
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                total.added += 1
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                total.deleted += 1
            }
        }
        if total.added == 0 && total.deleted == 0 { return nil }
        return cap(total)
    }

    private static func pathAfterColon(_ line: String) -> String {
        guard let idx = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Codex 执行成功判定

    /// 判断 apply_patch 的执行输出是否代表成功应用。
    /// 若首个非空行以编排包装状态开头，则以该状态为权威（成功状态文本才算成功）；
    /// 否则回退到通用成功标记。
    public static func codexExecIsApplied(_ output: String) -> Bool {
        let first = firstNonEmptyLine(output)
        if first.hasPrefix("Script ") {
            return first == "Script completed"
        }
        return output.contains("exited with code 0")
            || output.contains("Exit code: 0")
            || output.contains("Success. Updated the following files")
    }

    static func firstNonEmptyLine(_ output: String) -> String {
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    // MARK: - Codex 编排（programmatic）执行成功判定

    /// programmatic exec 包装的成功判定：仅以首个非空行的包装状态为权威。
    /// 只有 "Script completed" 视为成功；"Script running…" / "Script failed" / 缺头
    /// 一律不成功，且绝不回退到 legacy 标记（诊断脚本可能在正文里引用旧成功标记）。
    public static func codexProgrammaticExecIsApplied(_ output: String) -> Bool {
        codexProgrammaticExecOutcome(output).applied
    }

    /// programmatic exec 输出判定：applied 表示成功；resolved 表示已得到终态
    /// （completed / failed 为终态，running / 缺头未终态，可能在后续扫描才补齐）。
    public static func codexProgrammaticExecOutcome(_ output: String) -> (applied: Bool, resolved: Bool) {
        switch firstNonEmptyLine(output) {
        case "Script completed":
            return (true, true)
        case "Script failed":
            return (false, true)
        default:
            // 含 "Script running with cell ID …" 与任何未知 / 缺失包装头：未终态。
            return (false, false)
        }
    }

    /// 从 "Script running with cell ID <id>" 首行取出 cell id；非该形态返回空串。
    public static func codexProgrammaticRunningCellID(_ output: String) -> String {
        let prefix = "Script running with cell ID "
        let first = firstNonEmptyLine(output)
        guard first.hasPrefix(prefix) else { return "" }
        return String(first.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Codex Programmatic Tool Calling（tools.apply_patch）

    /// 从一段 programmatic exec 的 JavaScript 源码里，仅在“可证明的顶层
    /// await tools.apply_patch(<字面量/常量>)”调用存在时，还原其补丁正文。
    ///
    /// 参数必须可静态求值：内联 JSON 兼容双引号字符串、静态模板字面量，或被前置顶层
    /// const/let/var 赋成这类字符串的标识符。字符串 / 注释保持不透明，因此诊断脚本引用的
    /// 协议文本、缺失调用的赋值、含动态 ${…} 的模板都不会被误当作真实补丁。不执行任何 JS。
    /// 返回 nil 表示未证明存在可还原的 apply_patch 调用。
    public static func codexProgrammaticPatchBody(_ input: String) -> String? {
        let tokens = tokenizeCodexProgrammaticJS(input)
        var stringVars: [String: String] = [:]
        var braceDepth = 0
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            if token.kind == .punct {
                if token.text == "{" { braceDepth += 1; i += 1; continue }
                if token.text == "}" { if braceDepth > 0 { braceDepth -= 1 }; i += 1; continue }
            }
            if braceDepth != 0 { i += 1; continue }

            // 顶层 const/let/var <ident> = "<string>"：记入可解析的字符串变量表。
            if (token.text == "const" || token.text == "let" || token.text == "var"),
               i + 3 < tokens.count,
               tokens[i + 1].kind == .identifier,
               tokens[i + 2].text == "=",
               let value = tokens[i + 3].stringValue {
                stringVars[tokens[i + 1].text] = value
            }

            // 顶层 await tools . apply_patch ( <arg> )
            if token.text == "await",
               codexProgrammaticAwaitContext(tokens, i),
               i + 6 < tokens.count,
               tokens[i + 1].text == "tools",
               tokens[i + 2].text == ".",
               tokens[i + 3].text == "apply_patch",
               tokens[i + 4].text == "(",
               tokens[i + 6].text == ")" {
                let arg = tokens[i + 5]
                var body = ""
                if let literal = arg.stringValue {
                    body = literal
                } else if arg.kind == .identifier {
                    body = stringVars[arg.text] ?? ""
                }
                if body.contains("*** Begin Patch") && body.contains("*** End Patch") {
                    return body
                }
            }
            i += 1
        }
        return nil
    }

    private enum CodexJSTokenKind { case identifier, string, punct }

    private struct CodexJSToken {
        let kind: CodexJSTokenKind
        let text: String
        /// 仅当 kind == .string 且可静态求值时非 nil（已解码 JSON/JS 转义）。
        let stringValue: String?
    }

    private static func isCodexJSIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private static func isCodexJSIdentifierPart(_ c: Character) -> Bool {
        isCodexJSIdentifierStart(c) || (c >= "0" && c <= "9")
    }

    /// await 必须出现在语句 / 表达式起始位置（前一 token 为 = ( ; return 或位于开头），
    /// 才把它当作真实 await 调用而非标识符片段。
    private static func codexProgrammaticAwaitContext(_ tokens: [CodexJSToken], _ i: Int) -> Bool {
        if i == 0 { return true }
        switch tokens[i - 1].text {
        case "=", "(", ";", "return": return true
        default: return false
        }
    }

    /// 只对证明 tools.apply_patch 调用所需的 JS 表面做词法切分：字符串 / 注释保持不透明。
    private static func tokenizeCodexProgrammaticJS(_ src: String) -> [CodexJSToken] {
        let chars = Array(src)
        var tokens: [CodexJSToken] = []
        var i = 0
        let n = chars.count
        while i < n {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" || c == "\u{0C}" { i += 1; continue }

            // 注释：// 行注释与 /* */ 块注释整体丢弃。
            if c == "/" && i + 1 < n {
                if chars[i + 1] == "/" {
                    i += 2
                    while i < n && chars[i] != "\n" { i += 1 }
                    continue
                }
                if chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    if i + 1 < n { i += 2 }
                    continue
                }
            }

            // 字符串 / 模板字面量。
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                let start = i
                i += 1
                var closed = false
                while i < n {
                    if chars[i] == "\\" {
                        i += (i + 1 < n) ? 2 : 1
                        continue
                    }
                    if chars[i] == quote { i += 1; closed = true; break }
                    i += 1
                }
                let raw = String(chars[start..<i])
                var decoded: String? = nil
                if quote == "\"" && closed {
                    decoded = decodeCodexJSDoubleQuoted(raw)
                } else if quote == "`" && closed {
                    decoded = decodeCodexJSStaticTemplate(raw)
                }
                tokens.append(CodexJSToken(kind: .string, text: raw, stringValue: decoded))
                continue
            }

            // 标识符。
            if isCodexJSIdentifierStart(c) {
                let start = i
                i += 1
                while i < n && isCodexJSIdentifierPart(chars[i]) { i += 1 }
                tokens.append(CodexJSToken(kind: .identifier, text: String(chars[start..<i]), stringValue: nil))
                continue
            }

            // 其余单字符标点。
            tokens.append(CodexJSToken(kind: .punct, text: String(c), stringValue: nil))
            i += 1
        }
        return tokens
    }

    /// 解码 JSON 兼容的双引号字符串字面量（含完整 \uXXXX / 代理对）；不合法返回 nil。
    private static func decodeCodexJSDoubleQuoted(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let value = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
        else { return nil }
        return value
    }

    /// 解码未加标签的 JavaScript 模板字面量，仅当其值可静态确定时成功。
    /// 任意未转义的 ${…} 插值使正文运行期可变，拒绝（返回 nil）。
    static func decodeCodexJSStaticTemplate(_ raw: String) -> String? {
        let chars = Array(raw)
        guard chars.count >= 2, chars.first == "`", chars.last == "`" else { return nil }
        let content = Array(chars[1..<(chars.count - 1)])
        var out = ""
        var i = 0
        let n = content.count
        func hexScalar(_ s: [Character]) -> UInt32? {
            if s.isEmpty { return nil }
            guard let v = UInt32(String(s), radix: 16), v <= 0x10FFFF else { return nil }
            return v
        }
        while i < n {
            if content[i] == "$" && i + 1 < n && content[i + 1] == "{" { return nil }
            if content[i] != "\\" { out.append(content[i]); i += 1; continue }
            guard i + 1 < n else { return nil }
            let escape = content[i + 1]
            i += 2
            switch escape {
            case "\\", "`", "\"", "'", "$": out.append(escape)
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "v": out.append("\u{0B}")
            case "0":
                if i < n && content[i] >= "0" && content[i] <= "9" { return nil }
                out.append("\u{00}")
            case "\n":
                break // 行继续符，不产生字符。
            case "\r":
                if i < n && content[i] == "\n" { i += 1 }
            case "x":
                guard i + 2 <= n, let v = hexScalar(Array(content[i..<(i + 2)])), let scalar = Unicode.Scalar(v) else { return nil }
                out.unicodeScalars.append(scalar)
                i += 2
            case "u":
                if i < n && content[i] == "{" {
                    guard let close = content[(i + 1)...].firstIndex(of: "}") else { return nil }
                    guard let v = hexScalar(Array(content[(i + 1)..<close])), !(0xD800...0xDFFF).contains(v), let scalar = Unicode.Scalar(v) else { return nil }
                    out.unicodeScalars.append(scalar)
                    i = close + 1
                    continue
                }
                guard i + 4 <= n, var v = hexScalar(Array(content[i..<(i + 4)])) else { return nil }
                i += 4
                if (0xD800...0xDBFF).contains(v) {
                    // 高位代理，必须紧跟 \uXXXX 低位代理。
                    guard i + 6 <= n, content[i] == "\\", content[i + 1] == "u",
                          let low = hexScalar(Array(content[(i + 2)..<(i + 6)])), (0xDC00...0xDFFF).contains(low)
                    else { return nil }
                    v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                } else if (0xDC00...0xDFFF).contains(v) {
                    return nil
                }
                guard let scalar = Unicode.Scalar(v) else { return nil }
                out.unicodeScalars.append(scalar)
            default:
                // JS 恒等转义 cook 成被转义字符本身。
                out.append(escape)
            }
        }
        return out
    }

    // MARK: - 按桶归并 + 去重

    private struct EditBucketKey: Hashable {
        let source: String
        let model: String
        let project: String
        let bucketStartMs: Int64
    }

    /// 把已应用编辑按 (source, model, project, 桶) 归并，返回每个桶的增删小计。
    /// 以 toolUseID 全局去重（同一编辑只计一次）。bucketMilliseconds 与 token 桶一致。
    public static func aggregate(_ entries: [UsageEditEntry], bucketMilliseconds: Int64) -> [UsageEditBucketDelta] {
        var seen = Set<String>()
        var out: [EditBucketKey: UsageEditDelta] = [:]
        for e in entries {
            if !e.toolUseID.isEmpty {
                if seen.contains(e.toolUseID) { continue }
                seen.insert(e.toolUseID)
            }
            let ms = Int64(e.timestamp.timeIntervalSince1970 * 1000)
            let start = (ms / bucketMilliseconds) * bucketMilliseconds
            let key = EditBucketKey(source: e.source, model: e.model, project: e.project, bucketStartMs: start)
            var d = out[key] ?? UsageEditDelta()
            d.added += e.added
            d.deleted += e.deleted
            out[key] = d
        }
        return out
            .map { key, delta in
                UsageEditBucketDelta(
                    source: key.source, model: key.model, project: key.project,
                    bucketStartMs: key.bucketStartMs, added: delta.added, deleted: delta.deleted
                )
            }
            .sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source < rhs.source }
                if lhs.model != rhs.model { return lhs.model < rhs.model }
                if lhs.project != rhs.project { return lhs.project < rhs.project }
                return lhs.bucketStartMs < rhs.bucketStartMs
            }
    }
}

/// 归并后的每桶编辑增删小计（净值 = added - deleted，可为负）。
public struct UsageEditBucketDelta: Sendable, Equatable {
    public let source: String
    public let model: String
    public let project: String
    public let bucketStartMs: Int64
    public let added: Int64
    public let deleted: Int64
    public var net: Int64 { added - deleted }

    public init(source: String, model: String, project: String, bucketStartMs: Int64, added: Int64, deleted: Int64) {
        self.source = source
        self.model = model
        self.project = project
        self.bucketStartMs = bucketStartMs
        self.added = added
        self.deleted = deleted
    }
}
