import Foundation
import AgentPulseCore

/// Benchmark for UsageLedgerStore.finalizeDerived.
///
/// Generates a synthetic ledger with realistic features (multiple sources/models/projects,
/// lineage fingerprints, codex dedup keys, inherited events, skill/mcp counts, sessions,
/// edit entries) and measures the wall-clock cost of full recomputation under three scenarios:
///  1. First finalize after bulk ingest.
///  2. Second finalize with no new data (still a full recompute when called directly;
///     the coordinator-level needsFinalize gate would skip this in production).
///  3. Finalize after appending a tiny batch of new events.
@main
enum DerivedFinalizeBenchmark {
    static func main() throws {
        let targetEventCount = Int(ProcessInfo.processInfo.environment["BENCH_EVENT_COUNT"] ?? "200000") ?? 200_000
        let hostname = "benchmark-host"

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("derived-finalize-benchmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

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
                    let sessionHash = "sess-\(source)-\(fileIdx)-\(i / 20)"

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
                let sessionCount = eventsPerFile / 20
                for s in 0..<sessionCount {
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
        let rawSessionEventCount = try ledger.sessionEventCount()
        print("Recorded \(totalRecorded) events across \(sources.count * filesPerSource) files")
        print("usage_events rows: \(rawEventCount)")
        print("usage_session_events rows: \(rawSessionEventCount)")
        print("lineage groups: \(lineageGroups), content-dup groups: \(contentDupGroups)")
        print("")

        let t1 = Date()
        let result1 = try ledger.finalizeDerived(hostname: hostname)
        let d1 = Date().timeIntervalSince(t1)
        print("[1] first finalizeDerived: \(String(format: "%.3f", d1))s",
              "(collapsedInherited=\(result1.collapsedInheritedEvents),",
              "collapsedContent=\(result1.collapsedContentDuplicates))")

        let bucketCount1 = try ledger.buckets(hostname: hostname).count
        let sessionCount1 = try ledger.sessions(hostname: hostname).count
        print("    derived buckets: \(bucketCount1), sessions: \(sessionCount1)")

        let t2 = Date()
        let result2 = try ledger.finalizeDerived(hostname: hostname)
        let d2 = Date().timeIntervalSince(t2)
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
        print("[3] finalizeDerived after 10 new events: \(String(format: "%.3f", d3))s",
              "(collapsedInherited=\(result3.collapsedInheritedEvents),",
              "collapsedContent=\(result3.collapsedContentDuplicates))")

        let rawEventCountAfter = try ledger.eventCount()
        print("    usage_events rows after append: \(rawEventCountAfter)")
        print("")
        print("Summary: first=\(String(format: "%.3f", d1))s no-change=\(String(format: "%.3f", d2))s small-append=\(String(format: "%.3f", d3))s")
        // 增量重算的全部意义就在这条断言上：追加 10 个事件的代价必须与账本规模脱钩，
        // 而不是随它线性增长。阈值取全量耗时的三分之一 —— 留足机器抖动余量，同时任何
        // 「悄悄退回全量」的回归（脏键漏登记、闭包爆炸、索引失效）都会把 small-append
        // 推回全量量级从而在这里失败。绝对秒数不做断言：它随机器和账本规模变化。
        let ratio = d3 / d1
        print("small-append / first = \(String(format: "%.2f", ratio))")
        // 比值只有在 baseline 本身够大时才有意义。d1 太小的时候，进程启动、SQLite 打开
        // 库、WAL 建立这些每次调用都要付的固定开销会盖过真实差异，比值退化成噪声，
        // 断言既可能假过也可能假失败。BENCH_EVENT_COUNT 由调用方给定，小到几百个事件时
        // 全量本来就是毫秒级 —— 那种规模下这条断言不成立，直接说明原因并跳过，而不是
        // 拿一个无意义的比值报成功。
        let minimumBaseline = 0.5
        guard d1 >= minimumBaseline else {
            print("DerivedFinalizeBenchmark: SKIP ratio assertion - full recompute took only \(String(format: "%.3f", d1))s,",
                  "below the \(String(format: "%.1f", minimumBaseline))s needed for the ratio to mean anything.",
                  "Re-run with a larger BENCH_EVENT_COUNT (currently \(targetEventCount)) to exercise the gate.")
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
