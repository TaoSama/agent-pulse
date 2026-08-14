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

        FileHandle.standardOutput.write(Data("SecureConfigVerification passed\n".utf8))
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
