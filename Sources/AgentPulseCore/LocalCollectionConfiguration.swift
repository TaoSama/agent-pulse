import Foundation

/// 用户在本机声明的「额外本地采集来源」配置。
///
/// 设计目标：让协调器在不改动任何内建来源、也不硬编码任何具体路径/品牌的前提下，
/// 从一个 owner-only（0600）JSON 文件读取可选的 Claude-compatible transcript 来源。
/// 文件缺失、空、或全部条目非法都不是错误：本地采集照常只跑内建来源。
///
/// JSON 形状（最小设计）：顶层对象含可选 localSources 数组，每个元素含
/// source（来源名）、root（绝对路径）、format（目前仅 claude）、includeSubagents（缺省 true）。
/// 任何未知字段被忽略，便于向后兼容。
public struct LocalCollectionConfiguration: Sendable, Equatable {
    public let sources: [LocalCollectionSource]

    public init(sources: [LocalCollectionSource]) {
        self.sources = sources
    }

    public static let empty = LocalCollectionConfiguration(sources: [])
}

/// 单个已归一化、通过安全校验的本地来源。
public struct LocalCollectionSource: Sendable, Equatable {
    /// 归一化后的来源标识（小写、仅 [a-z0-9._-]、长度受限）。绝不等于任何内建来源。
    public let source: String
    /// 绝对、已标准化（消除 .. / 符号链接歧义）的采集根目录。
    public let root: URL
    /// 是否把 subagents/agent-*.jsonl 识别为子代理转录（计入 token、不产 session 事件）。
    public let includeSubagents: Bool

    public init(source: String, root: URL, includeSubagents: Bool) {
        self.source = source
        self.root = root
        self.includeSubagents = includeSubagents
    }
}

public enum LocalCollectionConfigurationError: Error, Equatable, Sendable {
    /// 文件存在但权限不是 owner-only 0600。拒绝读取，避免其它用户可写的采集指令。
    case insecurePermissions
    /// 文件存在但不是合法 JSON / 结构不符。
    case malformed
}

public enum LocalCollectionConfigurationLoader {
    /// 内建来源标识：用户配置的来源不得覆盖这些，否则会污染内建扫描的去重/聚合口径。
    public static let reservedSources: Set<String> = [UsageJSONLParser.codexSource, "claude-code"]

    /// 归一化来源名的最大长度。
    public static let maxSourceLength = 30

    /// 读取并校验本地采集配置。
    /// - 文件缺失：返回 empty（非错误）。
    /// - 权限非 0600：抛 insecurePermissions（fail-closed）。
    /// - JSON 非法：抛 malformed。
    /// - 单个条目非法：跳过该条目，其余照常。
    public static func load(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> LocalCollectionConfiguration {
        // Read through a descriptor opened O_NOFOLLOW and fstat-validated to be a
        // regular file owned by the current user with mode exactly 0600. A
        // symlink, directory, foreign owner, or wider mode is rejected as
        // insecurePermissions (same fail-closed semantics as before, now without
        // a check-then-read TOCTOU window). A missing file stays a non-error and
        // returns .empty so built-in collection keeps running unchanged.
        let data: Data
        do {
            data = try OwnerOnlyFileReader.read(url: url)
        } catch OwnerOnlyFileReader.Failure.notFound {
            return .empty
        } catch OwnerOnlyFileReader.Failure.insecure {
            throw LocalCollectionConfigurationError.insecurePermissions
        }
        return try decode(data)
    }

    /// 从已加载字节解码（便于测试与复用）。空文件视为 empty。
    public static func decode(_ data: Data) throws -> LocalCollectionConfiguration {
        if data.isEmpty { return .empty }
        let document: RawDocument
        do {
            document = try JSONDecoder().decode(RawDocument.self, from: data)
        } catch {
            throw LocalCollectionConfigurationError.malformed
        }
        return LocalCollectionConfiguration(sources: sanitize(document.localSources ?? []))
    }

    /// 归一化 + 安全过滤原始条目。纯函数，无 I/O。
    public static func sanitize(_ raw: [RawLocalSource]) -> [LocalCollectionSource] {
        var result: [LocalCollectionSource] = []
        var seenSources: Set<String> = []
        var acceptedRoots: [String] = []

        for entry in raw {
            let format = entry.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "claude"
            guard format == "claude" else { continue }

            guard let normalizedSource = normalizeSource(entry.source),
                  !reservedSources.contains(normalizedSource),
                  !seenSources.contains(normalizedSource) else { continue }

            guard let normalizedRoot = normalizeRoot(entry.root) else { continue }
            let rootPath = normalizedRoot.path

            if acceptedRoots.contains(where: { pathsOverlap($0, rootPath) }) { continue }

            let includeSubagents = entry.includeSubagents ?? true
            result.append(LocalCollectionSource(source: normalizedSource, root: normalizedRoot, includeSubagents: includeSubagents))
            seenSources.insert(normalizedSource)
            acceptedRoots.append(rootPath)
        }
        return result
    }

    /// 归一化来源名：trim -> 小写 -> 仅 [a-z0-9._-] -> 长度上限。空则 nil。
    public static func normalizeSource(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return nil }
        let allowed = lowered.unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") ||
            (scalar >= "0" && scalar <= "9") ||
            scalar == "." || scalar == "_" || scalar == "-"
        }
        var normalized = String(String.UnicodeScalarView(allowed))
        guard !normalized.isEmpty else { return nil }
        if normalized.count > maxSourceLength {
            normalized = String(normalized.prefix(maxSourceLength))
        }
        return normalized
    }

    /// 归一化 root：必须绝对路径；standardizedFileURL + resolvingSymlinksInPath
    /// 消除 .. 与符号链接别名。非绝对返回 nil。
    public static func normalizeRoot(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard raw.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: raw, isDirectory: true)
        return url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// 两个已标准化绝对路径是否相同或互为祖先/子孙（会导致重复扫描）。
    static func pathsOverlap(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let aTerminated = a.hasSuffix("/") ? a : a + "/"
        let bTerminated = b.hasSuffix("/") ? b : b + "/"
        return bTerminated.hasPrefix(aTerminated) || aTerminated.hasPrefix(bTerminated)
    }

    /// 顶层 JSON 文档形状。未知字段忽略。
    public struct RawDocument: Decodable, Sendable {
        public let localSources: [RawLocalSource]?
    }

    /// 单条原始条目（解码前，尚未校验）。
    public struct RawLocalSource: Decodable, Sendable {
        public let source: String?
        public let root: String?
        public let format: String?
        public let includeSubagents: Bool?

        public init(source: String?, root: String?, format: String?, includeSubagents: Bool?) {
            self.source = source
            self.root = root
            self.format = format
            self.includeSubagents = includeSubagents
        }
    }
}
