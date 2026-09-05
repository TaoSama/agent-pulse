import AgentPulseCore
import Darwin
import Foundation

enum BenchmarkFailure: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self { case let .assertion(message): message }
    }
}

func benchmarkRequire(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BenchmarkFailure.assertion(message) }
}

struct BenchmarkOptions {
    let eventCount: Int
    let requireRatio: Bool

    init() throws {
        let environment = ProcessInfo.processInfo.environment
        let rawCount = environment["BENCH_EVENT_COUNT"] ?? "200000"
        guard let count = Int(rawCount), count >= 200 else {
            throw BenchmarkFailure.assertion("BENCH_EVENT_COUNT must be an integer >= 200")
        }
        eventCount = count
        let rawRatio = environment["BENCH_REQUIRE_RATIO"] ?? "0"
        guard rawRatio == "0" || rawRatio == "1" else {
            throw BenchmarkFailure.assertion("BENCH_REQUIRE_RATIO must be 0 or 1")
        }
        requireRatio = rawRatio == "1"
    }
}

/// The fixture stays open throughout these checks: closing it would hide WAL
/// growth behind SQLite's shutdown checkpoint. Only this fixture is inspected.
func verifyNoChangeResources(ledger: UsageLedgerStore, hostname: String, directory: URL) throws {
    let rounds = 8
    let memoryGrowthAllowance: UInt64 = 8 * 1_024 * 1_024
    // Warm allocators and statement caches once before establishing the baseline.
    _ = try ledger.finalizeDerived(hostname: hostname)
    let initialMemory = try residentMemoryBytes()
    let initialFiles = try fixtureFileSizes(directory)
    var peakMemory = initialMemory
    for round in 0..<rounds {
        _ = try ledger.finalizeDerived(hostname: hostname)
        let work = ledger.lastFinalizeDiagnostics
        try benchmarkRequire(work.strategy == "noChange", "unchanged round \(round) must skip derivation, got \(work.strategy)")
        try benchmarkRequire(work.scopedLogicalEvents == 0, "unchanged round \(round) must not materialize logical events")
        try benchmarkRequire(work.sqliteChangedRows == 0, "unchanged round \(round) wrote \(work.sqliteChangedRows) rows")
        peakMemory = max(peakMemory, try residentMemoryBytes())
        let files = try fixtureFileSizes(directory)
        try benchmarkRequire(files == initialFiles, "unchanged round \(round) grew or created fixture DB/WAL/temp files: before=\(initialFiles), after=\(files)")
    }
    let memoryGrowth = peakMemory > initialMemory ? peakMemory - initialMemory : 0
    try benchmarkRequire(memoryGrowth <= memoryGrowthAllowance,
                         "unchanged finalize grew resident memory by \(memoryGrowth) bytes; allowance=\(memoryGrowthAllowance)")
    print("resource gate: \(rounds) unchanged rounds, zero changed rows, stable DB/WAL/temp files, RSS growth=\(memoryGrowth) bytes")
}

private func residentMemoryBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else {
        throw BenchmarkFailure.assertion("task_info failed: \(result)")
    }
    return UInt64(info.resident_size)
}

private func fixtureFileSizes(_ directory: URL) throws -> [String: UInt64] {
    let manager = FileManager.default
    var result: [String: UInt64] = [:]
    for name in try manager.subpathsOfDirectory(atPath: directory.path) {
        let attributes = try manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { continue }
        guard let size = attributes[.size] as? NSNumber else {
            throw BenchmarkFailure.assertion("fixture file has no size: \(name)")
        }
        result[name] = size.uint64Value
    }
    return result
}
