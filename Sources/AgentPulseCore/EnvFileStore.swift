import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 统一的 `.env` 凭证/配置存储：解析、合并 schema、安全 0600 读取、原子 0600 写回、密钥掩码。
///
/// 设计要点（隐私契约）：
/// - 值只在内存中流转；密钥值绝不写入 UserDefaults、SQLite 或日志，唯一持久化路径是写回本 env 文件。
/// - 读取复用 ``OwnerOnlyFileReader``（fd + `O_NOFOLLOW` + fstat），强制文件为属主 0600 常规文件，
///   拒绝 symlink / 目录 / 宽权限，关闭 check-then-read 的 TOCTOU 窗口。
/// - 写回同目录原子落盘并从创建起即 0600，绝不经过 0644 中间态。
public enum EnvFile {
    /// 单个配置文件默认允许的最大字节数，避免误读超大文件。
    public static let defaultMaxBytes = 64 * 1024

    /// `.env` 读取失败的粗粒度分类；不含 errno、路径或文件内容，便于对外脱敏。
    public enum Error: Swift.Error, Equatable, Sendable {
        case notFound
        case insecurePermissions
        case unreadable
        case tooLarge
    }

    // MARK: - 解析

    /// 解析 `KEY=VALUE` 形式的 `.env` 文本。
    /// 支持：`#` 注释、空行、可选前缀 `export`、单/双引号包裹的值。
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        text.enumerateLines { line, _ in
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
            if trimmed.hasPrefix("export ") {
                trimmed = String(trimmed.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }
            guard let separatorIndex = trimmed.firstIndex(of: "=") else { return }
            let rawKey = String(trimmed[trimmed.startIndex..<separatorIndex]).trimmingCharacters(in: .whitespaces)
            guard !rawKey.isEmpty else { return }
            let rawValue = String(trimmed[trimmed.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespaces)
            result[rawKey] = unquote(rawValue)
        }
        return result
    }

    /// 去除首尾成对的单/双引号。
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else { return value }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// 把键值序列化为 `.env` 文本，可被 ``parse(_:)`` 无损往返读回。
    /// 含空白、`#`、引号或首尾空格的值用双引号包裹并转义内部双引号；键按字典序稳定输出。
    static func serialize(_ pairs: [String: String]) -> String {
        pairs
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(quoteIfNeeded(value))" }
            .joined(separator: "\n")
            .appending("\n")
    }

    private static func quoteIfNeeded(_ value: String) -> String {
        let needsQuote = value.isEmpty
            || value.contains(where: { $0 == " " || $0 == "\t" || $0 == "#" || $0 == "\"" || $0 == "'" })
            || value.first == " " || value.last == " "
        guard needsQuote else { return value }
        let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - 安全读取

    /// 从 0600 常规文件安全读取并解析为环境字典。
    /// - Parameters:
    ///   - url: 配置文件 URL。
    ///   - maxBytes: 最大字节上限，超限抛 ``Error/tooLarge``。
    /// - Throws: ``Error``（notFound / insecurePermissions / unreadable / tooLarge）。
    public static func load(url: URL, maxBytes: Int = EnvFile.defaultMaxBytes) throws -> [String: String] {
        let data: Data
        do {
            data = try OwnerOnlyFileReader.read(url: url)
        } catch OwnerOnlyFileReader.Failure.notFound {
            throw Error.notFound
        } catch OwnerOnlyFileReader.Failure.insecure {
            throw Error.insecurePermissions
        } catch {
            throw Error.unreadable
        }
        guard data.count <= maxBytes else { throw Error.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Error.unreadable }
        return parse(text)
    }

    /// 从磁盘路径安全读取（支持前导 `~` 展开）。空路径视作 ``Error/notFound``。
    public static func load(path: String, maxBytes: Int = EnvFile.defaultMaxBytes) throws -> [String: String] {
        let expanded = (path as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expanded.isEmpty else { throw Error.notFound }
        return try load(url: URL(fileURLWithPath: expanded), maxBytes: maxBytes)
    }

    // MARK: - 原子 0600 写回

    /// 把 `overrides` 合并进现有 env 文件并原子写回（0600）。
    ///
    /// 语义：
    /// - 先安全读取现有键（文件不存在按空处理）；`overrides` 覆盖同名键，值为空串的键被删除。
    /// - 写入同目录临时文件（`O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW`，创建即 0600），`fsync` 后 `rename` 到目标，
    ///   全程不经过 0644 中间态、不跟随 symlink。
    /// - 父目录不存在时以 0700 创建。
    /// - Throws: ``Error/unreadable`` 涵盖所有 open/write/rename 失败；``Error/insecurePermissions`` 透传自读取。
    public static func writeBack(_ overrides: [String: String], to url: URL, maxBytes: Int = EnvFile.defaultMaxBytes) throws {
        var merged: [String: String]
        do {
            merged = try load(url: url, maxBytes: maxBytes)
        } catch Error.notFound {
            merged = [:]
        }
        for (key, value) in overrides {
            if value.isEmpty {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value
            }
        }

        let directory = url.deletingLastPathComponent()
        try ensureOwnerOnlyDirectory(directory)

        let text = serialize(merged)
        try atomicWrite(Data(text.utf8), to: url, inDirectory: directory)
    }

    /// 确保目录存在且属主专属（0700）。已存在的目录也显式收紧权限。
    private static func ensureOwnerOnlyDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        let mode = NSNumber(value: Int16(0o700))
        do {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw Error.unreadable }
                try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: mode]
                )
            }
        } catch let error as Error {
            throw error
        } catch {
            throw Error.unreadable
        }
    }

    /// 同目录临时文件 + rename 的原子写；从创建起即 0600，不跟随 symlink。
    private static func atomicWrite(_ data: Data, to url: URL, inDirectory directory: URL) throws {
        let tempPath = directory.appendingPathComponent(".agent-pulse-env-\(UUID().uuidString).tmp").path
        let flags = O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC
        let fd = tempPath.withCString { Darwin.open($0, flags, 0o600) }
        guard fd >= 0 else { throw Error.unreadable }

        var writeError: Error?
        data.withUnsafeBytes { raw in
            var offset = 0
            let base = raw.baseAddress
            let total = raw.count
            while offset < total {
                let written = Darwin.write(fd, base?.advanced(by: offset), total - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    writeError = .unreadable
                    return
                }
            }
        }
        if writeError == nil, Darwin.fsync(fd) != 0 {
            writeError = .unreadable
        }
        Darwin.close(fd)

        if let writeError {
            _ = tempPath.withCString { Darwin.unlink($0) }
            throw writeError
        }

        let renamed = tempPath.withCString { source in
            url.path.withCString { destination in
                Darwin.rename(source, destination)
            }
        }
        guard renamed == 0 else {
            _ = tempPath.withCString { Darwin.unlink($0) }
            throw Error.unreadable
        }
    }
}

/// 合并 env 的键 schema 与默认路径：R2 / cliproxy / 上报简单值的单一事实来源。
public enum MergedEnvKeys {
    // R2（键名保持不变，兼容既有 R2 解析）。endpoint 不再单独配置，
    // 由 account id 拼出固定模板 https://<account-id>.r2.cloudflarestorage.com。
    public static let r2AccountID = "R2_ACCOUNT_ID"
    public static let r2Bucket = "R2_BUCKET"
    public static let r2PublicBaseURL = "R2_PUBLIC_BASE_URL"
    public static let r2AccessKeyID = "R2_ACCESS_KEY_ID"
    public static let r2SecretAccessKey = "R2_SECRET_ACCESS_KEY"

    // cliproxy（键名保持不变）。
    public static let cliProxyBaseURL = "CLIPROXY_BASE_URL"
    public static let cliProxyManagementKey = "CLIPROXY_MANAGEMENT_KEY"
    public static let cliProxyTargetAPIKey = "CLIPROXY_TARGET_API_KEY"

    // 上报简单值（新键，明文）。
    public static let reportBaseURL = "REPORT_BASE_URL"
    public static let reportCanonicalHostname = "REPORT_CANONICAL_HOSTNAME"

    /// 需在 UI 中间星号掩码的密钥集合；其余键明文回显。
    public static let secretKeys: Set<String> = [
        r2SecretAccessKey,
        r2AccessKeyID,
        cliProxyManagementKey,
        cliProxyTargetAPIKey,
    ]

    /// 某键是否为密钥（掩码判定）。
    public static func isSecret(_ key: String) -> Bool { secretKeys.contains(key) }

    /// 默认合并 env 路径：当前用户家目录下的凭证文件（不硬编码用户名）。
    public static let defaultPath: String = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials/env/agent-pulse.env")
            .path
    }()

    /// 解析实际生效的合并 env 路径：为空/未设置时回退默认。
    public static func resolvePath(saved: String?) -> String {
        guard let saved else { return defaultPath }
        let trimmed = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultPath : trimmed
    }
}

/// 密钥掩码：中间星号，保留首尾少量字符便于人工核对，绝不回显完整密钥。
public enum SecretMask {
    /// `<= 8` 字符：整串以等长星号替换（不泄露长度以外信息）；
    /// 否则展示前 4 + `****` + 后 4（固定 4 个星号，不暴露真实长度）。
    public static func mask(_ value: String) -> String {
        if value.isEmpty { return "" }
        if value.count <= 8 {
            return String(repeating: "*", count: value.count)
        }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)****\(suffix)"
    }
}
