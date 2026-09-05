import Foundation
import AgentPulseCore
import Darwin

/// Benchmark for UsageLedgerStore.finalizeDerived.
///
/// Generates a synthetic ledger with realistic features (multiple sources/models/projects,
/// lineage fingerprints, codex dedup keys, inherited events, skill/mcp counts, sessions,
/// edit entries) and measures the wall-clock cost of full recomputation under three scenarios:
///  1. First finalize after bulk ingest.
///  2. Repeated finalize with no new data, including resource-growth checks.
///  3. Finalize after appending a tiny batch of new events.
@main
enum DerivedFinalizeBenchmark {
    static func main() throws {
        let options = try BenchmarkOptions()
        let targetEventCount = options.eventCount
        let hostname = "benchmark-host"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-finalize-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousTemporaryDirectory = ProcessInfo.processInfo.environment["SQLITE_TMPDIR"]
        try benchmarkRequire(setenv("SQLITE_TMPDIR", directory.path, 1) == 0, "unable to isolate SQLite temporary files")
        defer {
            let status = previousTemporaryDirectory.map { setenv("SQLITE_TMPDIR", $0, 1) } ?? unsetenv("SQLITE_TMPDIR")
            if status != 0 { FileHandle.standardError.write(Data("unable to restore SQLITE_TMPDIR\n".utf8)) }
        }

        let dbPath = directory.appendingPathComponent("usage.sqlite3").path
        let ledger = try UsageLedgerStore(path: dbPath)

        let sources = ["codex", "claude-code"]
        let models = ["gpt-4o", "gpt-5", "claude-sonnet-4-5", "claude-opus-4"]
        let projects = (0..<20).map { "project-\($0)" }
        let skills = ["git", "web-search", "python", "bash", "file-read"]
        let mcps = ["github", "slack", "postgres", "filesystem"]

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketMs = UsageLedgerStore.bucketMilliseconds
        let bucketCount = 7 * 24 * 2

        var rng = LCG(seed: 0xDEADBEEF)

        let filesPerSource = 100
        let eventsPerFile = max(1, targetEventCount / (sources.count * filesPerSource))
        let eventsPerSession = 20
        // Include the final partial group. eventsPerFile is positive, so this
        // ceiling division avoids overflowing an addition before division.
        // Counts at 20k/200k keep the existing complete-group distribution.
        let sessionsPerFile = 1 + (eventsPerFile - 1) / eventsPerSession
        if targetEventCount == 4_200 {
            try benchmarkRequire(eventsPerFile == 21 && sessionsPerFile == 2,
                                 "4200-event fixture must create two sessions per 21-event file")
        }

        print("Generating synthetic ledger: target=\(targetEventCount) events,",
              "\(sources.count) sources x \(filesPerSource) files x \(eventsPerFile) events/file")

        var totalRecorded = 0
        var lineageGroups = 0
        var contentDupGroups = 0

        for source in sources {
            for fileIdx in 0..<filesPerSource {
                let fileID = "\(source)-file-\(fileIdx)"
                let checkpoint = UsageFileCheckpoint(
                    fileID: fileID,
                    source: source,
                    pathHash: fileID,
                    offset: 0,
                    size: 1,
                    modifiedAt: baseTime,
                    parserVersion: UsageJSONLParser.parserVersion,
                    status: "complete"
                )

                var events: [UsageEvent] = []
                events.reserveCapacity(eventsPerFile)

                for i in 0..<eventsPerFile {
                    let model = models[Int(rng.next() % UInt64(models.count))]
                    let project = projects[Int(rng.next() % UInt64(projects.count))]
                    let bucketIdx = Int(rng.next() % UInt64(bucketCount))
                    let ts = baseTime.addingTimeInterval(TimeInterval(bucketIdx) * TimeInterval(bucketMs) / 1000)
                    let sessionHash = "sess-\(source)-\(fileIdx)-\(i / eventsPerSession)"

                    let input = Int64(rng.next() % 5000)
                    let output = Int64(rng.next() % 2000)
                    let counts = UsageTokenCounts(
                        input: input,
                        output: output,
                        cachedInput: Int64(rng.next() % 1000),
                        reasoningOutput: Int64(rng.next() % 500)
                    )

                    var lineageFingerprint = ""
                    var inherited = false
                    if i % 10 == 0 {
                        lineageFingerprint = "lineage-\(source)-\(fileIdx)-\(i / 10)"
                        inherited = false
                        lineageGroups += 1
                    } else if i % 10 == 1 {
                        lineageFingerprint = "lineage-\(source)-\(fileIdx)-\(i / 10)"
                        inherited = true
                    }

                    // Content dedup groups use indices that do NOT overlap with lineage
                    // groups, so they survive lineage dedup and exercise content folding.
                    var codexDedupKey = ""
                    if i % 20 == 5 {
                        codexDedupKey = "dedup-\(source)-\(fileIdx)-\(i / 20)"
                        contentDupGroups += 1
                    } else if i % 20 == 6 {
                        codexDedupKey = "dedup-\(source)-\(fileIdx)-\(i / 20)"
                    }

                    var skillCounts: [String: Int] = [:]
                    var mcpCounts: [String: Int] = [:]
                    if rng.next() % 100 < 15 {
                        let s = skills[Int(rng.next() % UInt64(skills.count))]
                        skillCounts[s] = Int(rng.next() % 5) + 1
                    }
                    if rng.next() % 100 < 15 {
                        let m = mcps[Int(rng.next() % UInt64(mcps.count))]
                        mcpCounts[m] = Int(rng.next() % 5) + 1
                    }

                    let event = UsageEvent(
                        id: "\(fileID)-evt-\(i)",
                        source: source,
                        model: model,
                        project: project,
                        timestamp: ts,
                        counts: counts,
                        sessionHash: sessionHash,
                        sourceFileHash: fileID,
                        inherited: inherited,
                        hasTotalSnapshot: !lineageFingerprint.isEmpty,
                        lineageFingerprint: lineageFingerprint,
                        codexDedupKey: codexDedupKey,
                        mergeStrategy: source == "codex" ? .overwrite : .cumulativeMax,
                        skillCounts: skillCounts,
                        mcpCounts: mcpCounts
                    )
                    events.append(event)
                }

                var sessionEvents: [UsageSessionEvent] = []
                for s in 0..<sessionsPerFile {
                    let sess = "sess-\(source)-\(fileIdx)-\(s)"
                    let ts = baseTime.addingTimeInterval(TimeInterval(s) * 60)
                    sessionEvents.append(UsageSessionEvent(
                        id: "\(sess)-user", source: source, sessionHash: sess,
                        sourceFileHash: fileID, role: .user, timestamp: ts
                    ))
                    sessionEvents.append(UsageSessionEvent(
                        id: "\(sess)-asst", source: source, sessionHash: sess,
                        sourceFileHash: fileID, role: .assistant, timestamp: ts.addingTimeInterval(30)
                    ))
                }
                try benchmarkRequire(Set(events.map(\.sessionHash)) == Set(sessionEvents.map(\.sessionHash)),
                                     "every token-event session must have activity events, including a partial final session")

                var editEntries: [UsageEditEntry] = []
                let editCount = min(5, eventsPerFile / 10)
                for e in 0..<editCount {
                    editEntries.append(UsageEditEntry(
                        source: source,
                        model: models[Int(rng.next() % UInt64(models.count))],
                        project: projects[Int(rng.next() % UInt64(projects.count))],
                        sourceFileHash: fileID,
                        timestamp: baseTime.addingTimeInterval(TimeInterval(e) * 120),
                        added: Int64(rng.next() % 100),
                        deleted: Int64(rng.next() % 50),
                        toolUseID: "\(fileID)-edit-\(e)"
                    ))
                }

                try ledger.record(
                    events: events,
                    sessionEvents: sessionEvents,
                    editEntries: editEntries,
                    checkpoint: checkpoint,
                    hostname: hostname
                )
                totalRecorded += events.count
            }
        }

        let rawEventCount = try ledger.eventCount()
        try benchmarkRequire(rawEventCount == totalRecorded, "fixture must preserve every raw event")
        let rawSessionEventCount = try ledger.sessionEventCount()
        let expectedSessionEventCount = sources.count * filesPerSource * sessionsPerFile * 2
        try benchmarkRequire(rawSessionEventCount == expectedSessionEventCount,
                             "fixture must record exactly \(expectedSessionEventCount) session activity events")
        if targetEventCount == 4_200 {
            try benchmarkRequire(rawSessionEventCount == 800,
                                 "4200-event fixture must persist 400 sessions with 800 activity events")
        }
        print("Recorded \(totalRecorded) events across \(sources.count * filesPerSource) files")
        print("usage_events rows: \(rawEventCount)")
        print("usage_session_events rows: \(rawSessionEventCount)")
        print("lineage groups: \(lineageGroups), content-dup groups: \(contentDupGroups)")
        print("")

        let t1 = Date()
        let result1 = try ledger.finalizeDerived(hostname: hostname)
        let d1 = Date().timeIntervalSince(t1)
        try benchmarkRequire(ledger.lastFinalizeDiagnostics.strategy == "full", "initial fixture must exercise full finalize")
        print("[1] first finalizeDerived: \(String(format: "%.3f", d1))s",
              "(collapsedInherited=\(result1.collapsedInheritedEvents),",
              "collapsedContent=\(result1.collapsedContentDuplicates))")

        let bucketCount1 = try ledger.buckets(hostname: hostname).count
        let sessionCount1 = try ledger.sessions(hostname: hostname).count
        print("    derived buckets: \(bucketCount1), sessions: \(sessionCount1)")
        try benchmarkRequire(bucketCount1 > 0 && sessionCount1 > 0, "fixture must exercise both derived tables")

        let t2 = Date()
        let result2 = try ledger.finalizeDerived(hostname: hostname)
        let d2 = Date().timeIntervalSince(t2)
        try verifyNoChangeResources(ledger: ledger, hostname: hostname, directory: directory)
        print("[2] second finalizeDerived (no new data): \(String(format: "%.3f", d2))s",
              "(collapsedInherited=\(result2.collapsedInheritedEvents),",
              "collapsedContent=\(result2.collapsedContentDuplicates))")
        print("    note: requiresDerivationCompletion is \(try ledger.requiresDerivationCompletion()) after finalize;",
              "the production coordinator would have skipped this call.")

        let smallFileID = "small-append-file"
        let smallCheckpoint = UsageFileCheckpoint(
            fileID: smallFileID, source: "codex", pathHash: smallFileID,
            offset: 0, size: 1, modifiedAt: Date(),
            parserVersion: UsageJSONLParser.parserVersion, status: "complete"
        )
        var smallEvents: [UsageEvent] = []
        for i in 0..<10 {
            smallEvents.append(UsageEvent(
                id: "\(smallFileID)-evt-\(i)",
                source: "codex",
                model: "gpt-5",
                project: "project-0",
                timestamp: Date(),
                counts: UsageTokenCounts(input: 100, output: 50),
                sessionHash: "\(smallFileID)-sess",
                sourceFileHash: smallFileID
            ))
        }
        try ledger.record(events: smallEvents, checkpoint: smallCheckpoint, hostname: hostname)

        let t3 = Date()
        let result3 = try ledger.finalizeDerived(hostname: hostname)
        let d3 = Date().timeIntervalSince(t3)
        let appendWork = ledger.lastFinalizeDiagnostics
        try benchmarkRequire(appendWork.strategy == "incremental", "10-event append must use incremental finalize, got \(appendWork.strategy)")
        try benchmarkRequire(appendWork.scopedLogicalEvents == smallEvents.count,
                             "independent append must scope exactly \(smallEvents.count) logical events, got \(appendWork.scopedLogicalEvents)")
        print("[3] finalizeDerived after 10 new events: \(String(format: "%.3f", d3))s",
              "(collapsedInherited=\(result3.collapsedInheritedEvents),",
              "collapsedContent=\(result3.collapsedContentDuplicates))")

        let rawEventCountAfter = try ledger.eventCount()
        try benchmarkRequire(rawEventCountAfter == rawEventCount + smallEvents.count, "append must preserve existing raw history")
        let appendedBuckets = try ledger.buckets(hostname: hostname).filter { $0.bucketStart > baseTime.addingTimeInterval(8 * 24 * 3600) }
        try benchmarkRequire(appendedBuckets.reduce(Int64(0)) { $0 + $1.counts.output } == 500,
                             "append must derive exactly 500 output tokens")
        try verifyNoChangeResources(ledger: ledger, hostname: hostname, directory: directory)
        print("    usage_events rows after append: \(rawEventCountAfter)")
        print("")
        print("Summary: first=\(String(format: "%.3f", d1))s no-change=\(String(format: "%.3f", d2))s small-append=\(String(format: "%.3f", d3))s")
        // 实际路径和作用域已按精确工作量验证；耗时比作为规模足够时的补充，
        // 捕获作用域虽小但仍执行昂贵全表查询的退化。
        let ratio = d3 / d1
        print("small-append / first = \(String(format: "%.2f", ratio))")
        // 小规模耗时容易受调度和固定事务开销影响。要求计时门禁时不能把
        // 未执行计时断言报告为成功；其余模式仍必须完成工作量及资源断言。
        let minimumBaseline = 0.5
        guard d1 >= minimumBaseline else {
            print("DerivedFinalizeBenchmark: timing ratio unavailable - full recompute took only \(String(format: "%.3f", d1))s,",
                  "below the \(String(format: "%.1f", minimumBaseline))s needed for the ratio to mean anything.",
                  "Work-scope and resource assertions ran (\(targetEventCount) requested events).")
            if options.requireRatio { Foundation.exit(2) }
            print("DerivedFinalizeBenchmark: PASS (work-scope and resources; timing ratio not evaluated)")
            return
        }
        guard ratio < 0.34 else {
            FileHandle.standardError.write(Data("""
                DerivedFinalizeBenchmark: FAIL small-append costs \(String(format: "%.0f", ratio * 100))% of a \
                full recompute (\(String(format: "%.3f", d3))s vs \(String(format: "%.3f", d1))s). \
                The incremental path is not narrowing the scope - it likely fell back to a full recompute.
                """.utf8))
            Foundation.exit(1)
        }
        print("DerivedFinalizeBenchmark: PASS")
    }
}

private struct LCG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
