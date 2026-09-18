import Foundation

/// 空间回收独立于已提交的冻结和删行事务；跳过或失败不代表统计失败。
public enum UsageSpaceReclamationResult: Sendable, Equatable {
    case notNeeded
    case completed
    case skippedInsufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case skippedCapacityUnavailable
    case failed

    public var warning: String? {
        switch self {
        case .notNeeded, .completed: nil
        case .skippedInsufficientSpace: "冻结与原始行压实已完成；磁盘余量不足，已跳过空间回收"
        case .skippedCapacityUnavailable: "冻结与原始行压实已完成；无法确认磁盘余量，已跳过空间回收"
        case .failed: "冻结与原始行压实已完成；空间回收失败，统计结果已保留"
        }
    }
}

public struct UsageCompactionEnvironment {
    static let vacuumTemporaryCopies: Int64 = 2
    static let vacuumSafetyMarginBytes: Int64 = 64 * 1_024 * 1_024

    var availableCapacity: (URL) throws -> Int64 = { directory in
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let capacity = values.volumeAvailableCapacity else {
            throw CapacityError.unavailable
        }
        return Int64(capacity)
    }
    var vacuumOverride: (() throws -> Void)?

    public init() {}

    public init(availableCapacity: @escaping (URL) throws -> Int64, vacuumOverride: (() throws -> Void)? = nil) {
        self.availableCapacity = availableCapacity
        self.vacuumOverride = vacuumOverride
    }

    static func requiredCapacity(pageCount: Int64, pageSize: Int64) throws -> Int64 {
        guard pageCount >= 0, pageSize > 0 else { throw CapacityError.unavailable }
        // SQLite VACUUM 最多需要约两份数据库的额外空间；逻辑页数包含尚在 WAL 中的页。
        let database = pageCount.multipliedReportingOverflow(by: pageSize)
        let temporary = database.partialValue.multipliedReportingOverflow(by: vacuumTemporaryCopies)
        let required = temporary.partialValue.addingReportingOverflow(vacuumSafetyMarginBytes)
        guard !database.overflow, !temporary.overflow, !required.overflow else {
            throw CapacityError.unavailable
        }
        return required.partialValue
    }

    enum CapacityError: Error { case unavailable }
}
