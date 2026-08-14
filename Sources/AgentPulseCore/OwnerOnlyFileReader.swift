import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Reads a file only if it is a *regular* file owned by the current effective
/// user with exactly \`0600\` permissions, refusing symlinks, directories, other
/// owners, and any broader mode. The check and the read operate on the same
/// file descriptor (opened with \`O_NOFOLLOW\`), so a symlink or a swap of the
/// path between check and read cannot smuggle in a differently-permissioned or
/// attacker-controlled file (no TOCTOU on the descriptor, no symlink follow).
///
/// Failures are reported only as coarse categories; no path, errno, or file
/// content is embedded, so callers can surface a redacted error without leaking
/// filesystem details.
public enum OwnerOnlyFileReader {
    /// Why an owner-only read refused or failed. \`notFound\` lets the caller keep
    /// its existing "file absent is not an error" semantics; \`insecure\` covers a
    /// symlink, non-regular file, foreign owner, or any mode other than 0600;
    /// \`unreadable\` is any other open/stat/read failure.
    public enum Failure: Error, Equatable, Sendable {
        case notFound
        case insecure
        case unreadable
    }

    /// Required permission bits: owner read+write only.
    static let requiredMode: mode_t = 0o600

    /// Opens \`url\` with \`O_RDONLY | O_NOFOLLOW | O_CLOEXEC\`, validates via
    /// \`fstat\` that it is a regular file owned by the effective uid with mode
    /// exactly 0600, then reads and returns its full contents from that same
    /// descriptor. Throws \`Failure.notFound\` when the path does not exist.
    public static func read(url: URL) throws -> Data {
        try read(path: url.path)
    }

    /// Path-based entry point. Kept internal-friendly for direct testing.
    public static func read(path: String) throws -> Data {
        let fd = openDescriptor(path)
        guard fd >= 0 else {
            switch errno {
            case ENOENT:
                throw Failure.notFound
            // O_NOFOLLOW turns a symlink terminal component into ELOOP (some
            // platforms use EMLINK); a directory opened O_RDONLY may yield
            // EISDIR. All are "not a plain owner-only regular file".
            case ELOOP, EMLINK, EISDIR, EPERM, EACCES:
                throw Failure.insecure
            default:
                throw Failure.unreadable
            }
        }
        defer { Darwin.close(fd) }

        var status = Darwin.stat()
        guard Darwin.fstat(fd, &status) == 0 else { throw Failure.unreadable }

        // Regular file only: reject directories, FIFOs, devices, sockets.
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw Failure.insecure }
        // Owner must be the current effective user.
        guard status.st_uid == Darwin.geteuid() else { throw Failure.insecure }
        // Exactly owner read+write, nothing else (no group/other, no setuid/etc).
        guard (status.st_mode & 0o7777) == requiredMode else { throw Failure.insecure }

        return try readAll(fd: fd)
    }

    /// Opens the descriptor, retrying only on EINTR. Returns -1 with errno set.
    private static func openDescriptor(_ path: String) -> Int32 {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        while true {
            let fd = Darwin.open(path, flags)
            if fd >= 0 { return fd }
            if errno == EINTR { continue }
            return fd
        }
    }

    /// Reads to EOF from the validated descriptor. Retries EINTR; any other
    /// read error is \`unreadable\`.
    private static func readAll(fd: Int32) throws -> Data {
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress, bufferSize)
            }
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                return data
            } else {
                if errno == EINTR { continue }
                throw Failure.unreadable
            }
        }
    }
}
