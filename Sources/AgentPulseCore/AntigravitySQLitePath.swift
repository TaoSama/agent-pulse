import Darwin
import Foundation

enum AntigravitySQLitePath {
    /// SQLite's NOFOLLOW checks directory components as well as the database.
    /// macOS exposes system paths such as /var through symlinks. Resolve the
    /// parent directory while still requiring the database leaf to be real.
    static func resolvingParent(of file: URL) -> URL? {
        let parentPath = file.deletingLastPathComponent().path
        guard let resolved = realpath(parentPath, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent(file.lastPathComponent)
    }
}
