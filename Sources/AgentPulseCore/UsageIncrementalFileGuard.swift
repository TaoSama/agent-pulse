import Darwin
import Foundation

/// Checks an append-only scan without replacing consumed bytes with a later read.
/// Prefix/tail guards cannot detect arbitrary interior rewrites combined with append;
/// this is a bounded consistency check, not filesystem snapshot isolation.
struct UsageIncrementalFileGuard {
    private struct Snapshot {
        let status: stat

        var size: Int64 { status.st_size }
        var fileNumber: UInt64 { status.st_ino }
        var creationDate: Date { Self.date(status.st_birthtimespec) }
        var modifiedAt: Date { Self.date(status.st_mtimespec) }

        func hasSameIdentity(as other: Snapshot) -> Bool {
            status.st_dev == other.status.st_dev && status.st_ino == other.status.st_ino
                && Self.equal(status.st_birthtimespec, other.status.st_birthtimespec)
        }

        func hasSameChangeTimes(as other: Snapshot) -> Bool {
            Self.equal(status.st_mtimespec, other.status.st_mtimespec)
                && Self.equal(status.st_ctimespec, other.status.st_ctimespec)
        }

        private static func equal(_ lhs: timespec, _ rhs: timespec) -> Bool {
            lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
        }

        private static func date(_ value: timespec) -> Date {
            Date(timeIntervalSinceReferenceDate: Double(value.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
                 + Double(value.tv_nsec) / 1_000_000_000)
        }

        static func read(descriptor: Int32) throws -> Snapshot {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw UsageIncrementalReadError.fileChangedDuringRead
            }
            return try checked(status)
        }

        static func read(path: String) throws -> Snapshot {
            var status = stat()
            guard lstat(path, &status) == 0 else {
                throw UsageIncrementalReadError.fileChangedDuringRead
            }
            return try checked(status)
        }

        private static func checked(_ status: stat) throws -> Snapshot {
            guard status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
                throw UsageIncrementalReadError.invalidFile
            }
            return Snapshot(status: status)
        }
    }

    private let descriptor: Int32
    private let path: String
    private let initial: Snapshot
    private var observed: Snapshot
    private static let creationDateRoundingTolerance: TimeInterval = 0.000001

    var size: Int64 { initial.size }
    var fileNumber: UInt64 { initial.fileNumber }
    var creationDate: Date { initial.creationDate }
    var modifiedAt: Date { initial.modifiedAt }

    func matchesCreationDate(_ saved: Date) -> Bool {
        // Persisted Foundation dates may round differently when converted through
        // Unix seconds. Live descriptor identity still compares exact timespecs.
        abs(saved.timeIntervalSince(creationDate)) <= Self.creationDateRoundingTolerance
    }

    static func open(fileURL: URL) throws -> FileHandle {
        // A FIFO substituted before fstat must not block the scanner in open.
        let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        while true {
            let descriptor = Darwin.open(fileURL.path, flags)
            if descriptor >= 0 { return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true) }
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    init(handle: FileHandle, fileURL: URL) throws {
        descriptor = handle.fileDescriptor
        path = fileURL.path
        initial = try Snapshot.read(descriptor: descriptor)
        observed = initial
        try validateMetadata()
    }

    /// Positional guard reads never disturb the streaming descriptor's offset.
    func read(offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        var completed = 0
        while completed < count {
            let bytes = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress!.advanced(by: completed),
                      count - completed, off_t(offset + Int64(completed)))
            }
            if bytes < 0, errno == EINTR { continue }
            guard bytes > 0 else { throw UsageIncrementalReadError.fileChangedDuringRead }
            completed += bytes
        }
        return data
    }

    mutating func validate(prefix: Data, tail: Data, offset: Int64) throws {
        try validateMetadata()
        guard try read(offset: 0, count: prefix.count) == prefix,
              try read(offset: offset - Int64(tail.count), count: tail.count) == tail else {
            throw UsageIncrementalReadError.fileChangedDuringRead
        }
        try validateMetadata()
    }

    private mutating func validateMetadata() throws {
        try accept(Snapshot.read(descriptor: descriptor))
        try accept(Snapshot.read(path: path))
        try accept(Snapshot.read(descriptor: descriptor))
    }

    private mutating func accept(_ next: Snapshot) throws {
        guard initial.hasSameIdentity(as: next), next.size >= observed.size,
              next.size > observed.size || observed.hasSameChangeTimes(as: next) else {
            throw UsageIncrementalReadError.fileChangedDuringRead
        }
        observed = next
    }
}
