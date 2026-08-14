import Foundation

/// 从会话记录中提取技能（skill）与 MCP 工具调用计数的纯函数集合。
///
/// 判定基于结构化的 tool_use 内容块，而非任意含 "skill" 字样的键：
/// - 技能：type == "tool_use" 且 name == "Skill"，读 input.skill 作为技能名并累加计数。
/// - MCP：type == "tool_use" 且 name 形如 "mcp__<server>__<tool>"，取 <server> 段累加计数。
///
/// 名称一律 trim、丢弃空串、截断到 100 字符，使计数键与呈现名逐字节一致。
public enum UsageToolMetrics {
    /// 技能名 / server 名的最大长度。
    public static let maxNameLength = 100

    /// 归一化一个技能 / server 名：trim、空串返回 nil、超长截断。
    public static func normalizeName(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if value.count > maxNameLength {
            value = String(value.prefix(maxNameLength))
        }
        return value
    }

    /// 统计一条记录里的技能调用次数。返回空字典表示未调用任何技能。
    public static func countSkillToolUses(_ object: [String: Any]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for part in toolUseParts(object) {
            guard (part["name"] as? String) == "Skill" else { continue }
            guard let input = part["input"] as? [String: Any] else { continue }
            guard let name = normalizeName((input["skill"] as? String) ?? "") else { continue }
            counts[name, default: 0] += 1
        }
        return counts
    }

    /// 统计一条记录里的 MCP server 调用次数。返回空字典表示未调用任何 MCP 工具。
    public static func countMCPToolUses(_ object: [String: Any]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for part in toolUseParts(object) {
            guard let server = mcpServerFromToolUseName((part["name"] as? String) ?? "") else { continue }
            counts[server, default: 0] += 1
        }
        return counts
    }

    /// 从 "mcp__<server>__<tool>" 形式的工具名切出归一化后的 server 名；不匹配返回 nil。
    public static func mcpServerFromToolUseName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("mcp__") else { return nil }
        let rest = String(trimmed.dropFirst("mcp__".count))
        guard let sep = rest.range(of: "__") else { return nil }
        let server = String(rest[..<sep.lowerBound])
        let tool = String(rest[sep.upperBound...])
        if tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        return normalizeName(server)
    }

    /// 技能计数字典的键（排序、去重），用于并入呈现列表并维持「每个计数键都出现在
    /// 技能列表中」的不变量。
    public static func skillNames(_ counts: [String: Int]) -> [String] {
        counts.keys.sorted()
    }

    /// 归一化一组技能呈现名：trim、丢空、截断、去重，保持首次出现顺序。
    public static func normalizeSkills(_ input: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in input {
            guard let name = normalizeName(raw) else { continue }
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    /// 归一化一个计数字典：归一化键、丢弃非正计数与空键、同键累加。
    public static func normalizeCounts(_ input: [String: Int]) -> [String: Int] {
        var out: [String: Int] = [:]
        for (raw, count) in input {
            if count <= 0 { continue }
            guard let name = normalizeName(raw) else { continue }
            out[name, default: 0] += count
        }
        return out
    }

    /// 相加合并两个计数字典（归一化后）。
    public static func mergeCounts(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] {
        var merged = a
        for (k, v) in b { merged[k, default: 0] += v }
        return normalizeCounts(merged)
    }

    /// 计数字典的稳定、与顺序无关的指纹（键升序，name=count 以逗号连接）。
    /// 用于让同一 usage-less（零 token）技能 / MCP turn 的多份逐字节 fork 重刷
    /// 折叠到同一 content 去重键。空字典返回空串。
    public static func countMapFingerprint(_ counts: [String: Int]) -> String {
        let normalized = normalizeCounts(counts)
        if normalized.isEmpty { return "" }
        return normalized.keys.sorted()
            .map { "\($0)=\(normalized[$0]!)" }
            .joined(separator: ",")
    }

    /// 呈现列表与计数键的并集（归一化 + 排序），维持「每个计数键都出现在列表中」不变量。
    public static func mergeSkillCountKeys(skills: [String], counts: [String: Int]) -> [String] {
        var union = Set(normalizeSkills(skills))
        for key in counts.keys {
            if let name = normalizeName(key) { union.insert(name) }
        }
        return union.sorted()
    }

    // MARK: - Codex 技能 / MCP 调用计数
    //
    // Codex 无 Claude 那样的 Skill tool。技能调用有两种信号（一条记录至多命中其一，
    // 不重复计数）：
    //   1. 旧格式 —— exec/shell function_call 的命令真正 READ 了 <name>/SKILL.md
    //      （countCodexSkillReads）；rg/grep/find 等只把路径当模式匹配的搜索 / 列举不计。
    //   2. 新格式 —— 用户消息里 [$name](…/SKILL.md) 形式的 $skill 提及
    //      （countCodexSkillMarkers）。
    // MCP 调用计数：function_call 的 mcp__server__tool 名（countCodexMCPToolUse）；
    // programmatic JS 里可执行控制流内的 tools.mcp__…() 另见 countCodexProgrammaticMCPToolUses。
    // *_output / *_end 记录（会回显 SKILL.md 正文 / 工具名）一律不计，避免重复。

    /// 读取文件内容的 shell 工具集合：用其一读 <name>/SKILL.md 才算真正加载 / 调用该技能。
    /// 搜索 / 列举器（rg/grep/find/ls…）故意不在内：它们只把路径当模式或文件名引用，不算读取。
    private static let codexReaderCommands: Set<String> = [
        "cat", "bat", "sed", "head", "tail", "less", "more", "nl", "view",
        "xxd", "od", "strings", "fold", "tac",
    ]

    /// 统计一条 Codex rollout 记录里 function_call 形态的 mcp__server__tool 调用（每次 1）。
    /// 仅 response_item + payload.type==function_call 计入；输出 / 消息 / programmatic 包装排除。
    public static func countCodexMCPToolUse(_ object: [String: Any]) -> [String: Int] {
        guard (object["type"] as? String) == "response_item" else { return [:] }
        guard let payload = object["payload"] as? [String: Any] else { return [:] }
        return countCodexMCPToolUsePayload(payload)
    }

    /// 从已确认是 response_item 的 payload 提取直接 MCP function_call 计数。
    static func countCodexMCPToolUsePayload(_ payload: [String: Any]) -> [String: Int] {
        guard (payload["type"] as? String) == "function_call" else { return [:] }
        guard let server = mcpServerFromToolUseName((payload["name"] as? String) ?? "") else { return [:] }
        return [server: 1]
    }

    /// 直接 MCP function_call 的匹配 output 成功 gate。缺失 / 空输出、显式 error、
    /// unsupported、failed 状态均不计；其余非空结果视为成功。
    public static func codexMCPFunctionOutputIsSuccess(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let data = trimmed.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            return codexMCPJSONOutputIsSuccess(value)
        }
        return !codexMCPTextIsFailure(trimmed)
    }

    /// 统计一条 Codex rollout 记录里通过 exec/shell function_call 读取 <name>/SKILL.md 的技能调用。
    /// 每次读取计 1，键为 /SKILL.md 前的目录段；仅真正读取内容的命令段计入。
    public static func countCodexSkillReads(_ object: [String: Any]) -> [String: Int] {
        guard let payload = object["payload"] as? [String: Any] else { return [:] }
        guard (payload["type"] as? String) == "function_call" else { return [:] }
        guard codexIsExecLikeFunction((payload["name"] as? String) ?? "") else { return [:] }
        let command = codexCommandText(payload["arguments"])
        if command.isEmpty || !command.contains("/SKILL.md") { return [:] }
        var counts: [String: Int] = [:]
        for segment in codexSplitCommandSegments(command) {
            guard codexSegmentReadsFile(segment), segment.contains("/SKILL.md") else { continue }
            for name in codexSkillReadMatches(segment) {
                guard let skill = normalizeName(name) else { continue }
                counts[skill, default: 0] += 1
            }
        }
        return counts
    }

    /// 统计一条 Codex 用户消息里 [$name](…/SKILL.md) 形式的 $skill 提及（每个技能每记录计 1）。
    /// 仅 response_item + payload.type==message + role==user；developer 目录消息与镜像的
    /// user_message 事件不读，避免重复计数。
    public static func countCodexSkillMarkers(_ object: [String: Any]) -> [String: Int] {
        guard let payload = object["payload"] as? [String: Any] else { return [:] }
        guard (payload["type"] as? String) == "message" else { return [:] }
        guard (payload["role"] as? String) == "user" else { return [:] }
        let text = codexMessageText(payload["content"])
        if text.isEmpty || !text.contains("/SKILL.md") { return [:] }
        var counts: [String: Int] = [:]
        for name in codexSkillMarkerMatches(text) {
            guard let skill = normalizeName(name) else { continue }
            if counts[skill] == nil { counts[skill] = 1 }
        }
        return counts
    }

    /// 判断 Codex function_call 名是否为 shell/exec 命令（可读 SKILL.md）。
    /// apply_patch / write / edit 形态排除 —— 撰写技能文件不等于调用它。
    static func codexIsExecLikeFunction(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return false }
        if lower.contains("apply_patch") || lower.contains("patch") || lower.contains("write") || lower.contains("edit") {
            return false
        }
        return lower.contains("exec") || lower.contains("command") || lower.contains("shell")
    }

    /// 从 Codex function_call 的 arguments（JSON 串）取 shell 命令文本。
    /// 支持 {"cmd":"…"}（现代 exec_command）与 {"command":"…" | ["sh","-c","…"]}（经典 shell）。
    static func codexCommandText(_ arguments: Any?) -> String {
        guard let raw = arguments as? String, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let args = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return "" }
        if let cmd = args["cmd"] as? String, !cmd.isEmpty { return cmd }
        if let command = args["command"] as? String { return command }
        if let parts = args["command"] as? [Any] {
            return parts.compactMap { $0 as? String }.joined(separator: " ")
        }
        return ""
    }

    /// 把命令按 || && | ; 换行切成段，每段各按自己的可执行程序分类。
    static func codexSplitCommandSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let chars = Array(command)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "|" || c == "&" {
                // || 与 && 视作单个分隔；单独的 | 也分隔（单独 & 同理）。
                if i + 1 < chars.count && chars[i + 1] == c { i += 1 }
                segments.append(current); current = ""
            } else if c == ";" || c == "\n" {
                segments.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        segments.append(current)
        return segments
    }

    /// 判断命令段的首个可执行程序是否读取文件内容（codexReaderCommands），
    /// 跳过前导 VAR=value 赋值与 sudo/command/time/env/exec/nohup 等包装器。
    static func codexSegmentReadsFile(_ segment: String) -> Bool {
        for rawToken in segment.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            var token = String(rawToken)
            while let first = token.first, first == "(" || first == "{" || first == " " {
                token.removeFirst()
            }
            if token.isEmpty { continue }
            // 前导环境赋值（FOO=bar）—— 不是可执行程序。
            if let eq = token.firstIndex(of: "="), token.distance(from: token.startIndex, to: eq) > 0,
               !token.hasPrefix("/"), !token.hasPrefix(".") {
                continue
            }
            switch token {
            case "sudo", "command", "time", "exec", "nohup", "env", "\\": continue
            default: break
            }
            var base = token
            if let slash = base.lastIndex(of: "/") { base = String(base[base.index(after: slash)...]) }
            return codexReaderCommands.contains(base)
        }
        return false
    }

    /// 从命令段里匹配 /<name>/SKILL.md 的目录段名（要求前导 / 保证 name 是完整路径组件）。
    static func codexSkillReadMatches(_ segment: String) -> [String] {
        if codexSegmentUsesSedInPlace(segment) { return [] }
        let readable = codexRemovingOutputRedirections(segment)
        return matches(in: readable, pattern: "/([A-Za-z0-9_.:+-]+)/SKILL\\.md")
    }

    /// 从用户消息文本里匹配 [$name](…/SKILL.md) 的 $skill 名。
    static func codexSkillMarkerMatches(_ text: String) -> [String] {
        matches(in: text, pattern: "\\[\\$([A-Za-z0-9_.:+-]+)\\]\\([^)]*?/SKILL\\.md\\)")
    }

    /// 把 Codex 消息 payload 的 content 拉平为纯文本。content 通常是 {type,text|input_text}
    /// 列表，也兼容裸字符串。
    static func codexMessageText(_ value: Any?) -> String {
        if let s = value as? String { return s }
        guard let items = value as? [Any] else { return "" }
        var parts: [String] = []
        for item in items {
            guard let m = item as? [String: Any] else { continue }
            if let t = m["text"] as? String, !t.isEmpty { parts.append(t) }
            else if let t = m["input_text"] as? String, !t.isEmpty { parts.append(t) }
        }
        return parts.joined(separator: "\n")
    }

    /// 提取所有第一捕获组，用于上面的 SKILL.md / $skill 正则匹配。
    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard m.numberOfRanges >= 2 else { continue }
            let r = m.range(at: 1)
            if r.location != NSNotFound { out.append(ns.substring(with: r)) }
        }
        return out
    }

    /// sed -i / -i.bak 是原地写入，不算读取技能；仅检查可执行程序后的选项区。
    private static func codexSegmentUsesSedInPlace(_ segment: String) -> Bool {
        let tokens = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let sedIndex = tokens.firstIndex(where: { token in
            let base = token.split(separator: "/").last.map(String.init) ?? token
            return base == "sed"
        }) else { return false }
        for token in tokens.dropFirst(sedIndex + 1) {
            if token == "--" { break }
            if !token.hasPrefix("-") { continue }
            if token == "-i" || token.hasPrefix("-i") || token.dropFirst().contains("i") { return true }
        }
        return false
    }

    /// 移除 shell 输出重定向目标，避免 `cat source > .../SKILL.md` 把写入目标误算读取。
    private static func codexRemovingOutputRedirections(_ segment: String) -> String {
        let pattern = #"(?:[0-9]*>>?|[0-9]*>\|)\s*(?:'[^']*'|\"[^\"]*\"|[^\s;&|]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return segment }
        let range = NSRange(location: 0, length: (segment as NSString).length)
        return regex.stringByReplacingMatches(in: segment, range: range, withTemplate: " ")
    }

    private static func codexMCPJSONOutputIsSuccess(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for key in ["is_error", "isError"] where (object[key] as? Bool) == true { return false }
            if (object["supported"] as? Bool) == false { return false }
            if let status = object["status"] as? String, codexMCPTextIsFailure(status) { return false }
            if let error = object["error"], !(error is NSNull) {
                if let text = error as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                return false
            }
            for key in ["content", "output", "result", "text", "message"] {
                if let nested = object[key], !codexMCPJSONOutputIsSuccess(nested) { return false }
            }
            return true
        }
        if let array = value as? [Any] {
            return !array.isEmpty && array.allSatisfy(codexMCPJSONOutputIsSuccess)
        }
        if let text = value as? String { return !codexMCPTextIsFailure(text) }
        return !(value is NSNull)
    }

    private static func codexMCPTextIsFailure(_ text: String) -> Bool {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        return lower == "error" || lower.hasPrefix("error:") || lower.hasPrefix("error ")
            || lower == "failed" || lower.hasPrefix("failed:") || lower.hasPrefix("failure:")
            || lower == "unsupported" || lower.hasPrefix("unsupported:") || lower.hasPrefix("unsupported ")
            || lower.contains("\"iserror\":true") || lower.contains("\"is_error\":true")
    }

    // MARK: - 私有

    /// 取记录里 message.content[] 中的所有 tool_use 块。
    private static func toolUseParts(_ object: [String: Any]) -> [[String: Any]] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [Any] else { return [] }
        var parts: [[String: Any]] = []
        for item in content {
            guard let part = item as? [String: Any] else { continue }
            guard (part["type"] as? String) == "tool_use" else { continue }
            parts.append(part)
        }
        return parts
    }
}

/// Codex programmatic（JS）MCP 调用计数：仅统计「可执行控制流」里真正会跑到的
/// tools.mcp__<server>__<tool>(...) 调用 —— 顶层、被执行的 IIFE、被调用的具名函数 / 箭头
/// （按调用次数计重），排除字符串 / 正则字面量 / 注释 / 未被调用的函数体 / 未执行的嵌套回调。
/// 不执行任何 JS，仅做词法 + 作用域可达性静态分析。
public enum CodexProgrammaticMCP {
    /// 唯一入口：统计一段 programmatic exec 的 JS 源码里可执行到的 MCP server 调用次数。
    public static func toolUses(_ input: String) -> [String: Int] {
        if !input.contains("tools.mcp__") { return [:] }
        let tokens = tokenize(input)
        var scopes: [Scope] = [Scope(parent: -1, expressionEnd: -1)]
        var frames: [Frame] = []
        var currentScope = 0

        var i = 0
        while i < tokens.count {
            while currentScope != 0, scopes[currentScope].expressionEnd >= 0, i > scopes[currentScope].expressionEnd {
                currentScope = scopes[currentScope].parent
            }
            let token = tokens[i]
            // arrow：X => <expr>（非 { 体）：开一个表达式作用域。
            if token.text == "=", i + 2 < tokens.count, tokens[i + 1].text == ">", tokens[i + 2].text != "{" {
                let end = arrowExpressionEnd(tokens, i + 2)
                var name = assignedArrowName(tokens, i)
                if name.isEmpty {
                    name = objectCallableName(frames, arrowPropertyName(tokens, i))
                }
                scopes.append(Scope(
                    name: name, parent: currentScope, iifeEligible: true,
                    iife: functionImmediatelyInvoked(tokens, end) || eagerCallback(tokens, i),
                    expressionEnd: end
                ))
                currentScope = scopes.count - 1
                i += 1
                continue
            }
            if token.kind == .punct {
                if token.text == "{" {
                    let block = functionBlock(tokens, i)
                    if block.ok {
                        var name = block.name
                        if name.isEmpty { name = objectCallableName(frames, block.propertyName) }
                        scopes.append(Scope(
                            name: name, parent: currentScope, iifeEligible: block.iifeEligible,
                            iife: block.eager, expressionEnd: -1
                        ))
                        currentScope = scopes.count - 1
                        frames.append(Frame(scope: currentScope, function: true, objectPath: ""))
                    } else {
                        frames.append(Frame(scope: currentScope, function: false, objectPath: objectBlockPath(tokens, i, frames)))
                    }
                    i += 1
                    continue
                }
                if token.text == "}" {
                    if frames.isEmpty { i += 1; continue }
                    let frame = frames.removeLast()
                    if frame.function, scopes[frame.scope].iifeEligible {
                        scopes[frame.scope].iife = functionImmediatelyInvoked(tokens, i) || scopes[frame.scope].iife
                    }
                    if frame.function {
                        currentScope = scopes[frame.scope].parent
                    } else {
                        currentScope = frame.scope
                    }
                    i += 1
                    continue
                }
            }

            let callName = directCallName(tokens, i)
            if !callName.isEmpty {
                scopes[currentScope].calls[callName, default: 0] += 1
            }

            // tools . <mcp__server__tool> ( … )
            if token.text == "tools", i + 3 < tokens.count, tokens[i + 1].text == ".", tokens[i + 3].text == "(" {
                if let server = UsageToolMetrics.mcpServerFromToolUseName(tokens[i + 2].text),
                   callEnd(tokens, i + 3) >= 0 {
                    scopes[currentScope].toolUses[server, default: 0] += 1
                }
            }
            i += 1
        }

        // 可达性：顶层作用域激活；被激活作用域内 iife 子作用域、被调用的具名函数/箭头级联激活。
        var active = [Bool](repeating: false, count: scopes.count)
        active[0] = true
        var functionsByName: [String: Int] = [:]
        var ambiguousNames: Set<String> = []
        for idx in 1..<max(scopes.count, 1) {
            if idx >= scopes.count { break }
            let name = scopes[idx].name
            if name.isEmpty { continue }
            if functionsByName[name] != nil { ambiguousNames.insert(name); continue }
            functionsByName[name] = idx
        }
        var changed = true
        while changed {
            changed = false
            for idx in 0..<scopes.count {
                if idx > 0, !active[idx], scopes[idx].iife, active[scopes[idx].parent] {
                    active[idx] = true; changed = true
                }
                if !active[idx] { continue }
                for name in scopes[idx].calls.keys {
                    guard let target = functionsByName[name], !ambiguousNames.contains(name) else { continue }
                    if active[target] || !active[scopes[target].parent] { continue }
                    active[target] = true; changed = true
                }
            }
        }

        var iifeChildren: [Int: [Int]] = [:]
        for idx in 1..<max(scopes.count, 1) {
            if idx >= scopes.count { break }
            if scopes[idx].iife, active[idx] {
                iifeChildren[scopes[idx].parent, default: []].append(idx)
            }
        }

        var counts: [String: Int] = [:]
        var visiting: Set<Int> = []
        func visit(_ scope: Int, _ executions: Int) {
            if executions <= 0 || visiting.contains(scope) { return }
            visiting.insert(scope)
            for (server, count) in scopes[scope].toolUses {
                counts[server, default: 0] += count * executions
            }
            for child in iifeChildren[scope] ?? [] {
                visit(child, executions)
            }
            for (name, callCount) in scopes[scope].calls {
                guard let target = functionsByName[name], !ambiguousNames.contains(name),
                      active[target], active[scopes[target].parent] else { continue }
                visit(target, executions * callCount)
            }
            visiting.remove(scope)
        }
        visit(0, 1)
        return counts
    }

    // MARK: - 作用域 / 帧

    private struct Scope {
        var name: String = ""
        var parent: Int
        var iifeEligible: Bool = false
        var iife: Bool = false
        var expressionEnd: Int
        var toolUses: [String: Int] = [:]
        var calls: [String: Int] = [:]
    }

    private struct Frame {
        var scope: Int
        var function: Bool
        var objectPath: String
    }

    private struct FunctionBlock {
        var name: String = ""
        var propertyName: String = ""
        var ok: Bool = false
        var iifeEligible: Bool = false
        var eager: Bool = false
    }

    // MARK: - 词法（字符串 / 注释不透明；MCP 计数无需解码字符串内容）

    private enum Kind { case identifier, string, punct }
    private struct Tok { let kind: Kind; let text: String }

    private static func isIdentStart(_ c: Character) -> Bool {
        c == "_" || c == "$" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }
    private static func isIdentPart(_ c: Character) -> Bool { isIdentStart(c) || (c >= "0" && c <= "9") }

    private static func tokenize(_ src: String) -> [Tok] {
        let chars = Array(src)
        let n = chars.count
        var tokens: [Tok] = []
        var i = 0
        while i < n {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\r" || c == "\n" || c == "\u{0C}" { i += 1; continue }
            // 注释
            if c == "/" && i + 1 < n {
                if chars[i + 1] == "/" { i += 2; while i < n && chars[i] != "\n" { i += 1 }; continue }
                if chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < n && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    if i + 1 < n { i += 2 }
                    continue
                }
                // 正则字面量：/ 出现在可作为表达式起始处时按正则整体吞掉（不产生 token）。
                if regexAllowedHere(tokens) {
                    var j = i + 1
                    var inClass = false
                    var closed = false
                    while j < n {
                        let ch = chars[j]
                        if ch == "\\" { j += 2; continue }
                        if ch == "\n" { break }
                        if ch == "[" { inClass = true }
                        else if ch == "]" { inClass = false }
                        else if ch == "/" && !inClass { closed = true; j += 1; break }
                        j += 1
                    }
                    if closed {
                        while j < n && isIdentPart(chars[j]) { j += 1 } // 正则 flags
                        i = j
                        continue
                    }
                }
            }
            // 字符串 / 模板
            if c == "\"" || c == "'" || c == "`" {
                let quote = c
                i += 1
                while i < n {
                    if chars[i] == "\\" { i += (i + 1 < n) ? 2 : 1; continue }
                    if chars[i] == quote { i += 1; break }
                    i += 1
                }
                tokens.append(Tok(kind: .string, text: ""))
                continue
            }
            if isIdentStart(c) {
                let start = i
                i += 1
                while i < n && isIdentPart(chars[i]) { i += 1 }
                tokens.append(Tok(kind: .identifier, text: String(chars[start..<i])))
                continue
            }
            tokens.append(Tok(kind: .punct, text: String(c)))
            i += 1
        }
        return tokens
    }

    /// 判断 / 是否可作为正则起始（前一个有意义 token 不是可结束表达式的值 / 标识符 / ) ]）。
    private static func regexAllowedHere(_ tokens: [Tok]) -> Bool {
        guard let prev = tokens.last else { return true }
        switch prev.kind {
        case .identifier:
            switch prev.text {
            case "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "await", "yield", "case", "do", "else": return true
            default: return false
            }
        case .string: return false
        case .punct:
            switch prev.text { case ")", "]", "}": return false; default: return true }
        }
    }

    // MARK: - helpers

    private static func functionBlock(_ tokens: [Tok], _ openBrace: Int) -> FunctionBlock {
        if openBrace <= 0 || openBrace >= tokens.count || tokens[openBrace].text != "{" { return FunctionBlock() }
        let previous = openBrace - 1
        if previous >= 1, tokens[previous - 1].text == "=", tokens[previous].text == ">" {
            return FunctionBlock(
                name: assignedArrowName(tokens, previous - 1),
                propertyName: arrowPropertyName(tokens, previous - 1),
                ok: true, iifeEligible: true, eager: eagerCallback(tokens, previous - 1)
            )
        }
        if tokens[previous].text != ")" { return FunctionBlock() }
        let openParen = matchingOpen(tokens, previous, "(", ")")
        if openParen < 0 { return FunctionBlock() }
        let beforeParen = openParen - 1
        if beforeParen >= 0, controlBlockKeyword(tokens[beforeParen].text) { return FunctionBlock() }
        if beforeParen >= 1, tokens[beforeParen].text == "await", tokens[beforeParen - 1].text == "for" { return FunctionBlock() }

        var functionIndex = -1
        var k = beforeParen
        while k >= 0 && k >= beforeParen - 4 {
            if tokens[k].text == "function" { functionIndex = k; break }
            if tokens[k].text == ";" || tokens[k].text == "{" || tokens[k].text == "}" { break }
            k -= 1
        }
        if functionIndex >= 0 {
            let propertyName = functionPropertyName(tokens, functionIndex)
            var name = assignedFunctionName(tokens, functionIndex)
            if name.isEmpty && propertyName.isEmpty {
                var j = functionIndex + 1
                while j < openParen {
                    if tokens[j].kind == .identifier, tokens[j].text != "async" { name = tokens[j].text; break }
                    j += 1
                }
            }
            return FunctionBlock(
                name: name, propertyName: propertyName, ok: true,
                iifeEligible: functionExpressionContext(tokens, functionIndex),
                eager: eagerCallback(tokens, functionIndex)
            )
        }
        if beforeParen >= 0, tokens[beforeParen].kind == .identifier {
            return FunctionBlock(name: "", propertyName: tokens[beforeParen].text, ok: true, iifeEligible: false, eager: false)
        }
        return FunctionBlock()
    }

    private static func functionExpressionContext(_ tokens: [Tok], _ functionIndex: Int) -> Bool {
        var start = functionIndex
        if start > 0, tokens[start - 1].text == "async" { start -= 1 }
        if start == 0 { return false }
        switch tokens[start - 1].text {
        case "(", "[", "=", ":", ",", "return": return true
        default: return false
        }
    }

    private static func assignedFunctionName(_ tokens: [Tok], _ before: Int) -> String {
        var cursor = before - 1
        if cursor >= 0, tokens[cursor].text == "async" { cursor -= 1 }
        if cursor >= 1, tokens[cursor].text == "=", tokens[cursor - 1].kind == .identifier { return tokens[cursor - 1].text }
        return ""
    }

    private static func assignedArrowName(_ tokens: [Tok], _ arrowEqual: Int) -> String {
        var cursor = arrowEqual - 1
        if cursor >= 0, tokens[cursor].text == ")" {
            cursor = matchingOpen(tokens, cursor, "(", ")") - 1
        } else if cursor >= 0, tokens[cursor].kind == .identifier {
            cursor -= 1
        } else { return "" }
        if cursor >= 0, tokens[cursor].text == "async" { cursor -= 1 }
        if cursor >= 1, tokens[cursor].text == "=", tokens[cursor - 1].kind == .identifier { return tokens[cursor - 1].text }
        return ""
    }

    private static func arrowPropertyName(_ tokens: [Tok], _ arrowEqual: Int) -> String {
        var cursor = arrowEqual - 1
        if cursor >= 0, tokens[cursor].text == ")" {
            cursor = matchingOpen(tokens, cursor, "(", ")") - 1
        } else if cursor >= 0, tokens[cursor].kind == .identifier {
            cursor -= 1
        } else { return "" }
        if cursor >= 0, tokens[cursor].text == "async" { cursor -= 1 }
        if cursor >= 1, tokens[cursor].text == ":", tokens[cursor - 1].kind == .identifier { return tokens[cursor - 1].text }
        return ""
    }

    private static func functionPropertyName(_ tokens: [Tok], _ functionIndex: Int) -> String {
        var cursor = functionIndex - 1
        if cursor >= 0, tokens[cursor].text == "async" { cursor -= 1 }
        if cursor >= 1, tokens[cursor].text == ":", tokens[cursor - 1].kind == .identifier { return tokens[cursor - 1].text }
        return ""
    }

    private static func objectCallableName(_ frames: [Frame], _ property: String) -> String {
        if property.isEmpty { return "" }
        var i = frames.count - 1
        while i >= 0 {
            if !frames[i].objectPath.isEmpty { return frames[i].objectPath + "." + property }
            i -= 1
        }
        return ""
    }

    private static func objectBlockPath(_ tokens: [Tok], _ openBrace: Int, _ frames: [Frame]) -> String {
        if openBrace >= 2, tokens[openBrace - 1].text == "=", tokens[openBrace - 2].kind == .identifier {
            return tokens[openBrace - 2].text
        }
        if openBrace >= 2, tokens[openBrace - 1].text == ":", tokens[openBrace - 2].kind == .identifier {
            return objectCallableName(frames, tokens[openBrace - 2].text)
        }
        return ""
    }

    private static func arrowExpressionEnd(_ tokens: [Tok], _ start: Int) -> Int {
        var parenDepth = 0, bracketDepth = 0, braceDepth = 0
        var i = start
        while i < tokens.count {
            switch tokens[i].text {
            case "(": parenDepth += 1
            case ")": if parenDepth == 0 { return i - 1 }; parenDepth -= 1
            case "[": bracketDepth += 1
            case "]": if bracketDepth == 0 { return i - 1 }; bracketDepth -= 1
            case "{": braceDepth += 1
            case "}": if braceDepth == 0 { return i - 1 }; braceDepth -= 1
            case ",", ";": if parenDepth == 0 && bracketDepth == 0 && braceDepth == 0 { return i - 1 }
            default: break
            }
            i += 1
        }
        return tokens.count - 1
    }

    private static func controlBlockKeyword(_ token: String) -> Bool {
        switch token { case "if", "for", "while", "switch", "catch", "with": return true; default: return false }
    }

    private static func matchingOpen(_ tokens: [Tok], _ close: Int, _ openToken: String, _ closeToken: String) -> Int {
        var depth = 0
        var i = close
        while i >= 0 {
            if tokens[i].text == closeToken { depth += 1 }
            else if tokens[i].text == openToken { depth -= 1; if depth == 0 { return i } }
            i -= 1
        }
        return -1
    }

    private static func matchingClose(_ tokens: [Tok], _ open: Int, _ openToken: String, _ closeToken: String) -> Int {
        var depth = 0
        var i = open
        while i < tokens.count {
            if tokens[i].text == openToken { depth += 1 }
            else if tokens[i].text == closeToken { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return -1
    }

    private static func directCallName(_ tokens: [Tok], _ i: Int) -> String {
        if i < 0 || i + 1 >= tokens.count || tokens[i].kind != .identifier || tokens[i + 1].text != "(" { return "" }
        var name = tokens[i].text
        if i > 0, tokens[i - 1].text == "." {
            var parts = [name]
            var cursor = i - 2
            while cursor >= 0, tokens[cursor].kind == .identifier {
                parts.append(tokens[cursor].text)
                if cursor < 2 || tokens[cursor - 1].text != "." { break }
                cursor -= 2
            }
            name = parts.reversed().joined(separator: ".")
        } else if i > 0, tokens[i - 1].text == "function" {
            return ""
        }
        let closeParen = matchingClose(tokens, i + 1, "(", ")")
        if closeParen >= 0, closeParen + 1 < tokens.count, tokens[closeParen + 1].text == "{" {
            if functionBlock(tokens, closeParen + 1).ok { return "" }
        }
        return name
    }

    private static func functionImmediatelyInvoked(_ tokens: [Tok], _ closeBrace: Int) -> Bool {
        var i = closeBrace + 1
        while i < tokens.count {
            if tokens[i].text == ")" { i += 1; continue }
            return tokens[i].text == "("
        }
        return false
    }

    private static func eagerCallback(_ tokens: [Tok], _ functionToken: Int) -> Bool {
        var cursor = functionToken - 1
        if functionToken >= 0, functionToken < tokens.count, tokens[functionToken].text == "=" {
            if cursor >= 0, tokens[cursor].text == ")" {
                cursor = matchingOpen(tokens, cursor, "(", ")") - 1
            } else if cursor >= 0, tokens[cursor].kind == .identifier {
                cursor -= 1
            } else { return false }
        }
        if cursor >= 0, tokens[cursor].text == "async" { cursor -= 1 }
        if cursor < 2 || tokens[cursor].text != "(" || tokens[cursor - 1].kind != .identifier || tokens[cursor - 2].text != "." { return false }
        switch tokens[cursor - 1].text {
        case "map", "flatMap", "forEach", "filter", "some", "every", "find", "findIndex", "findLast", "findLastIndex", "reduce", "reduceRight", "sort": return true
        default: return false
        }
    }

    private static func callEnd(_ tokens: [Tok], _ open: Int) -> Int {
        if open < 0 || open >= tokens.count || tokens[open].text != "(" { return -1 }
        var depth = 0
        var i = open
        while i < tokens.count {
            if tokens[i].text == "(" { depth += 1 }
            else if tokens[i].text == ")" { depth -= 1; if depth == 0 { return i } }
            i += 1
        }
        return -1
    }
}
