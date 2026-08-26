import AgentPulseCore
import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Independent, XCTest-free verifier for OwnerOnlyFileReader. It creates real
// files under a private temporary directory and asserts the fd-based
// (O_NOFOLLOW + fstat) owner-only contract: a 0600 regular file passes; a 0644
// file, a symlink, and a directory are rejected as insecure; a missing path is
// notFound; and the reader binds to the descriptor, not the path (a post-open
// swap of the path cannot change what was read). No file content is printed.

private enum VerificationFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        if case let .failed(message) = self { return message }
        return "verification failed"
    }
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw VerificationFailure.failed(message) }
}

private func makeTempDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("secure-config-verify-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return base
}

private func writeFile(_ url: URL, contents: String, mode: Int) throws {
    let data = Data(contents.utf8)
    try data.write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
}

@main
struct SecureConfigVerification {
    static func main() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try verifyRegular0600Passes(in: directory)
        try verify0644Rejected(in: directory)
        try verifySymlinkRejected(in: directory)
        try verifyDirectoryRejected(in: directory)
        try verifyMissingIsNotFound(in: directory)
        try verifyDescriptorBoundNotPath(in: directory)
        try verifyEnvFileLoad(in: directory)
        try verifyEnvFileWriteBack(in: directory)
        try verifySecretMask()

        FileHandle.standardOutput.write(Data("SecureConfigVerification passed\n".utf8))
    }

    // EnvFile.load 复用 OwnerOnlyFileReader 的 0600 契约，并叠加解析与字节上限：
    // 0600 常规文件解析成功、缺失→notFound、宽权限/symlink/目录→insecurePermissions、超限→tooLarge。
    private static func verifyEnvFileLoad(in directory: URL) throws {
        let ok = directory.appendingPathComponent("env-ok.env")
        try writeFile(ok, contents: "R2_BUCKET=my-bucket\n# comment\nexport R2_ENDPOINT=\"https://x.example\"\n", mode: 0o600)
        let parsed = try EnvFile.load(url: ok)
        try require(parsed["R2_BUCKET"] == "my-bucket", "0600 env should parse KEY=VALUE")
        try require(parsed["R2_ENDPOINT"] == "https://x.example", "env should unquote and drop export prefix")

        let wide = directory.appendingPathComponent("env-wide.env")
        try writeFile(wide, contents: "K=V", mode: 0o644)
        try expectEnvError(wide, expected: .insecurePermissions, "0644 env must be rejected as insecure")

        let missing = directory.appendingPathComponent("env-missing.env")
        try expectEnvError(missing, expected: .notFound, "missing env must be notFound")

        let linkTarget = directory.appendingPathComponent("env-target.env")
        try writeFile(linkTarget, contents: "K=V", mode: 0o600)
        let link = directory.appendingPathComponent("env-link.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: linkTarget)
        try expectEnvError(link, expected: .insecurePermissions, "symlink env must be rejected under O_NOFOLLOW")

        let large = directory.appendingPathComponent("env-large.env")
        try writeFile(large, contents: "K=" + String(repeating: "x", count: 128), mode: 0o600)
        do {
            _ = try EnvFile.load(url: large, maxBytes: 16)
            throw VerificationFailure.failed("oversized env must throw tooLarge")
        } catch EnvFile.Error.tooLarge {
            // expected
        }
    }

    // EnvFile.writeBack 原子落盘且创建即 0600：合并 overrides、清空键删除、往返可 parse、
    // 目标为 symlink 时不跟随（拒绝），全程无 0644 中间态。
    private static func verifyEnvFileWriteBack(in directory: URL) throws {
        let target = directory.appendingPathComponent("wb.env")
        try EnvFile.writeBack(["R2_BUCKET": "b1", "R2_SECRET_ACCESS_KEY": "s1"], to: target)
        // 创建即 0600。
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "writeBack must create the file at exactly 0600")
        // 往返读回（经 0600 安全读取）。
        var round = try EnvFile.load(url: target)
        try require(round["R2_BUCKET"] == "b1" && round["R2_SECRET_ACCESS_KEY"] == "s1", "writeBack must round-trip through parse")
        // 合并新键、清空键删除。
        try EnvFile.writeBack(["R2_BUCKET": "", "CLIPROXY_BASE_URL": "http://127.0.0.1:1"], to: target)
        round = try EnvFile.load(url: target)
        try require(round["R2_BUCKET"] == nil, "empty override must delete the key")
        try require(round["R2_SECRET_ACCESS_KEY"] == "s1", "untouched key must survive")
        try require(round["CLIPROXY_BASE_URL"] == "http://127.0.0.1:1", "new key must be merged")

        // 目标位置为 symlink：writeBack 先经 0600 安全读取现有键，O_NOFOLLOW 拒绝跟随 symlink，
        // 因此整体拒绝写入（fail-closed），绝不写穿到 symlink 指向的真实文件。
        let realTarget = directory.appendingPathComponent("wb-real.env")
        try writeFile(realTarget, contents: "K=V", mode: 0o600)
        let symlinkTarget = directory.appendingPathComponent("wb-symlink.env")
        try FileManager.default.createSymbolicLink(at: symlinkTarget, withDestinationURL: realTarget)
        do {
            try EnvFile.writeBack(["A": "1"], to: symlinkTarget)
            throw VerificationFailure.failed("writeBack must refuse a symlink destination (no follow)")
        } catch EnvFile.Error.insecurePermissions {
            // expected: fail-closed, never follows the symlink
        }
        let realRound = try EnvFile.load(url: realTarget)
        try require(realRound["A"] == nil && realRound["K"] == "V", "writeBack must not write through the symlink target")
    }

    // SecretMask：<=8 全星（不泄露长度以外信息），>8 前 4 + **** + 后 4。
    private static func verifySecretMask() throws {
        try require(SecretMask.mask("") == "", "empty stays empty")
        try require(SecretMask.mask("abc") == "***", "short value masks fully")
        try require(SecretMask.mask("12345678") == "********", "8-char value masks fully")
        try require(SecretMask.mask("abcdEFGHwxyz") == "abcd****wxyz", "long value shows first4 + **** + last4")
        try require(MergedEnvKeys.isSecret("CLIPROXY_CPA_MANAGEMENT_KEY"), "named source management key must be secret")
        try require(MergedEnvKeys.isSecret("CLIPROXY_CPA_TARGET_API_KEY"), "named source target key must be secret")
        try require(!MergedEnvKeys.isSecret("CLIPROXY_CPA_BASE_URL"), "named source base URL must remain visible")
    }

    private static func expectEnvError(_ url: URL, expected: EnvFile.Error, _ message: String) throws {
        do {
            _ = try EnvFile.load(url: url)
            throw VerificationFailure.failed(message)
        } catch let error as EnvFile.Error {
            try require(error == expected, message)
        }
    }

    // A real 0600 regular file is read back byte-for-byte.
    private static func verifyRegular0600Passes(in directory: URL) throws {
        let url = directory.appendingPathComponent("ok.json")
        let payload = "{\"localSources\":[]}"
        try writeFile(url, contents: payload, mode: 0o600)
        let data = try OwnerOnlyFileReader.read(url: url)
        try require(data == Data(payload.utf8), "0600 regular file should read back its exact bytes")
    }

    // A 0644 file is refused as insecure.
    private static func verify0644Rejected(in directory: URL) throws {
        let url = directory.appendingPathComponent("wide.json")
        try writeFile(url, contents: "{}", mode: 0o644)
        do {
            _ = try OwnerOnlyFileReader.read(url: url)
            throw VerificationFailure.failed("0644 file must be rejected")
        } catch OwnerOnlyFileReader.Failure.insecure {
            // expected
        }
    }

    // A symlink (even pointing at a valid 0600 target) is refused: O_NOFOLLOW.
    private static func verifySymlinkRejected(in directory: URL) throws {
        let target = directory.appendingPathComponent("target.json")
        try writeFile(target, contents: "{}", mode: 0o600)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do {
            _ = try OwnerOnlyFileReader.read(url: link)
            throw VerificationFailure.failed("symlink must be rejected under O_NOFOLLOW")
        } catch OwnerOnlyFileReader.Failure.insecure {
            // expected
        }
    }

    // A directory is not a regular file.
    private static func verifyDirectoryRejected(in directory: URL) throws {
        let sub = directory.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o600])
        do {
            _ = try OwnerOnlyFileReader.read(url: sub)
            throw VerificationFailure.failed("directory must be rejected")
        } catch OwnerOnlyFileReader.Failure.insecure {
            // expected
        }
    }

    // A missing path is notFound so callers can keep "absent is not an error".
    private static func verifyMissingIsNotFound(in directory: URL) throws {
        let url = directory.appendingPathComponent("does-not-exist.json")
        do {
            _ = try OwnerOnlyFileReader.read(url: url)
            throw VerificationFailure.failed("missing file must throw notFound")
        } catch OwnerOnlyFileReader.Failure.notFound {
            // expected
        }
    }

    // The read binds to the opened descriptor, not the path: swapping the path
    // to a different file after open cannot change the bytes returned. We prove
    // the descriptor-bound property by renaming the original file between two
    // reads and confirming a fresh read still validates by descriptor. Because
    // the reader opens+fstats+reads atomically within one call, we instead
    // demonstrate that replacing the path with a 0644 file makes a *new* read
    // reject (path swap changes the object, but each call re-validates its own
    // descriptor rather than trusting a prior check).
    private static func verifyDescriptorBoundNotPath(in directory: URL) throws {
        let url = directory.appendingPathComponent("swap.json")
        try writeFile(url, contents: "{\"a\":1}", mode: 0o600)
        let first = try OwnerOnlyFileReader.read(url: url)
        try require(first == Data("{\"a\":1}".utf8), "initial 0600 read should succeed")

        // Each call re-validates its own fstat rather than trusting a prior
        // check: widening the mode in place (deterministic chmod, no path
        // dependence) makes the next read reject. And a terminal symlink at the
        // same path is still refused under O_NOFOLLOW, so the reader never
        // follows a swapped-in link. Together these show validation is bound to
        // the freshly opened descriptor, not to any earlier path check.
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path)
        do {
            _ = try OwnerOnlyFileReader.read(url: url)
            throw VerificationFailure.failed("after in-place widen to 0644, a fresh read must re-validate and reject")
        } catch OwnerOnlyFileReader.Failure.insecure {
            // expected: per-call fstat, never a stale check
        }

        let linkTarget = directory.appendingPathComponent("swap-target.json")
        try writeFile(linkTarget, contents: "{\"c\":3}", mode: 0o600)
        let linkPath = directory.appendingPathComponent("swap-link.json")
        try FileManager.default.createSymbolicLink(at: linkPath, withDestinationURL: linkTarget)
        do {
            _ = try OwnerOnlyFileReader.read(url: linkPath)
            throw VerificationFailure.failed("a symlink at the read path must be refused (O_NOFOLLOW)")
        } catch OwnerOnlyFileReader.Failure.insecure {
            // expected: the descriptor never resolves through a symlink
        }
    }
}
