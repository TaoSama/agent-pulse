import Foundation
import AgentPulseCore

/// 增量 finalize 与全量 finalize 的等价性验证。
///
/// 用固定 seed 的 LCG 生成一串随机「批次」操作，对两个独立的 SQLite 库 A、B 施加
/// 完全相同的 record / markFilesMissing 调用；每批之后 A 走 .automatic（可增量则增量），
/// B 走 .fullRecompute（强制全量），逐字段比对派生结果。任一不等立即打印 diff 并 exit(1)。
@main
enum DerivedFinalizeEquivalence {
    static func main() throws {
        let rounds = try parseRounds(ProcessInfo.processInfo.environment["EQUIV_ROUNDS"])
        // UInt64("0xBEEF") 是 nil —— Swift 的十进制初始化器不认 0x 前缀。直接用它会让每个
        // 带前缀的 EQUIV_SEED 都静默落回默认种子，看起来跑了多种子其实只跑了一个。
        let seed = try parseSeed(ProcessInfo.processInfo.environment["EQUIV_SEED"])
        let hostname = "equiv-host"

        let dirA = try makeTempDir()
        let dirB = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dirA); try? FileManager.default.removeItem(at: dirB) }

        let ledgerA = try UsageLedgerStore(path: dirA.appendingPathComponent("usage.sqlite3").path)
        let ledgerB = try UsageLedgerStore(path: dirB.appendingPathComponent("usage.sqlite3").path)

        var rng = LCG(seed: seed)
        var gen = Generator()

        for round in 0..<rounds {
            let batch = gen.nextBatch(round: round, rng: &rng)

            for rec in batch.records {
                try ledgerA.record(events: rec.events, sessionEvents: rec.sessionEvents,
                                   editEntries: rec.edits, editMetricsSupported: rec.editMetricsSupported,
                                   checkpoint: rec.checkpoint, hostname: hostname)
                try ledgerB.record(events: rec.events, sessionEvents: rec.sessionEvents,
                                   editEntries: rec.edits, editMetricsSupported: rec.editMetricsSupported,
                                   checkpoint: rec.checkpoint, hostname: hostname)
            }
            if !batch.missing.isEmpty {
                try ledgerA.markFilesMissing(fileIDs: batch.missing, hostname: hostname)
                try ledgerB.markFilesMissing(fileIDs: batch.missing, hostname: hostname)
            }

            let resultA = try ledgerA.finalizeDerived(hostname: hostname, strategy: .automatic)
            let resultB = try ledgerB.finalizeDerived(hostname: hostname, strategy: .fullRecompute)

            try compare(ledgerA, ledgerB, resultA, resultB, hostname, round)
        }

        print("DerivedFinalizeEquivalence: PASS (\(rounds) rounds, seed=\(String(seed, radix: 16)))")
    }
}

// MARK: - 比对

private func compare(_ a: UsageLedgerStore, _ b: UsageLedgerStore,
                     _ ra: UsageFinalizeResult, _ rb: UsageFinalizeResult,
                     _ hostname: String, _ round: Int) throws {
    let bucketsA = try a.buckets(hostname: hostname)
    let bucketsB = try b.buckets(hostname: hostname)
    let sessionsA = try a.sessions(hostname: hostname)
    let sessionsB = try b.sessions(hostname: hostname)
    let eligibleA = try a.reportingEligible(hostname: hostname)
    let eligibleB = try b.reportingEligible(hostname: hostname)

    // Buckets：按自然键建字典，直接定位「只在 A」「只在 B」的 bucket。
    let dictA = Dictionary(uniqueKeysWithValues: bucketsA.map { (bucketKey($0), $0) })
    let dictB = Dictionary(uniqueKeysWithValues: bucketsB.map { (bucketKey($0), $0) })
    let keysA = Set(dictA.keys)
    let keysB = Set(dictB.keys)
    let onlyA = keysA.subtracting(keysB).sorted()
    let onlyB = keysB.subtracting(keysA).sorted()
    if !onlyA.isEmpty || !onlyB.isEmpty {
        print("MISMATCH at round \(round): bucket set differs (A=\(bucketsA.count), B=\(bucketsB.count))")
        print("  only in A (automatic): \(onlyA.count)")
        for k in onlyA {
            let bkt = dictA[k]!
            print("    \(k)")
            print("      counts=\(bkt.counts)")
            print("      linesAdded=\(bkt.linesAdded) linesDeleted=\(bkt.linesDeleted) codeMetricVersion=\(bkt.codeMetricVersion)")
            print("      skillCounts=\(bkt.skillCounts) mcpCounts=\(bkt.mcpCounts)")
        }
        print("  only in B (fullRecompute): \(onlyB.count)")
        for k in onlyB {
            let bkt = dictB[k]!
            print("    \(k)  counts=\(bkt.counts)")
        }
        exit(1)
    }
    for k in keysA.sorted() {
        try compareBucket(dictA[k]!, dictB[k]!, round, k)
    }

    // Sessions：同样按自然键比对。
    let sdictA = Dictionary(uniqueKeysWithValues: sessionsA.map { (sessionKey($0), $0) })
    let sdictB = Dictionary(uniqueKeysWithValues: sessionsB.map { (sessionKey($0), $0) })
    let skeysA = Set(sdictA.keys)
    let skeysB = Set(sdictB.keys)
    let sonlyA = skeysA.subtracting(skeysB).sorted()
    let sonlyB = skeysB.subtracting(skeysA).sorted()
    if !sonlyA.isEmpty || !sonlyB.isEmpty {
        print("MISMATCH at round \(round): session set differs (A=\(sessionsA.count), B=\(sessionsB.count))")
        print("  only in A (automatic): \(sonlyA.count)")
        for k in sonlyA {
            print("    \(k)")
        }
        print("  only in B (fullRecompute): \(sonlyB.count)")
        for k in sonlyB {
            print("    \(k)")
        }
        exit(1)
    }
    for k in skeysA.sorted() {
        try compareSession(sdictA[k]!, sdictB[k]!, round, k)
    }

    guard eligibleA == eligibleB else { fail(round, "reportingEligible(ledger)", "\(eligibleA)", "\(eligibleB)") }
    guard ra.reportingEligible == rb.reportingEligible else {
        fail(round, "result.reportingEligible", "\(ra.reportingEligible)", "\(rb.reportingEligible)")
    }
}

private func compareBucket(_ a: UsageBucket, _ b: UsageBucket, _ round: Int, _ key: String) throws {
    if a.source != b.source { fail(round, "\(key).source", a.source, b.source) }
    if a.model != b.model { fail(round, "\(key).model", a.model, b.model) }
    if a.project != b.project { fail(round, "\(key).project", a.project, b.project) }
    if a.bucketStart != b.bucketStart { fail(round, "\(key).bucketStart", "\(a.bucketStart)", "\(b.bucketStart)") }
    let ca = a.counts, cb = b.counts
    if ca.input != cb.input { fail(round, "\(key).counts.input", "\(ca.input)", "\(cb.input)") }
    if ca.output != cb.output { fail(round, "\(key).counts.output", "\(ca.output)", "\(cb.output)") }
    if ca.cachedInput != cb.cachedInput { fail(round, "\(key).counts.cachedInput", "\(ca.cachedInput)", "\(cb.cachedInput)") }
    if ca.cacheCreationInput != cb.cacheCreationInput { fail(round, "\(key).counts.cacheCreationInput", "\(ca.cacheCreationInput)", "\(cb.cacheCreationInput)") }
    if ca.reasoningOutput != cb.reasoningOutput { fail(round, "\(key).counts.reasoningOutput", "\(ca.reasoningOutput)", "\(cb.reasoningOutput)") }
    if ca.reportedTotal != cb.reportedTotal { fail(round, "\(key).counts.reportedTotal", "\(ca.reportedTotal)", "\(cb.reportedTotal)") }
    if a.skillCounts != b.skillCounts { fail(round, "\(key).skillCounts", "\(a.skillCounts)", "\(b.skillCounts)") }
    if a.mcpCounts != b.mcpCounts { fail(round, "\(key).mcpCounts", "\(a.mcpCounts)", "\(b.mcpCounts)") }
    if a.linesAdded != b.linesAdded { fail(round, "\(key).linesAdded", "\(a.linesAdded)", "\(b.linesAdded)") }
    if a.linesDeleted != b.linesDeleted { fail(round, "\(key).linesDeleted", "\(a.linesDeleted)", "\(b.linesDeleted)") }
    if a.codeMetricVersion != b.codeMetricVersion { fail(round, "\(key).codeMetricVersion", "\(a.codeMetricVersion)", "\(b.codeMetricVersion)") }
}

private func compareSession(_ a: UsageSession, _ b: UsageSession, _ round: Int, _ key: String) throws {
    if a.source != b.source { fail(round, "\(key).source", a.source, b.source) }
    if a.sessionHash != b.sessionHash { fail(round, "\(key).sessionHash", a.sessionHash, b.sessionHash) }
    if a.project != b.project { fail(round, "\(key).project", a.project, b.project) }
    if a.skills != b.skills { fail(round, "\(key).skills", "\(a.skills)", "\(b.skills)") }
    if a.firstActivity != b.firstActivity { fail(round, "\(key).firstActivity", "\(a.firstActivity)", "\(b.firstActivity)") }
    if a.lastActivity != b.lastActivity { fail(round, "\(key).lastActivity", "\(a.lastActivity)", "\(b.lastActivity)") }
    if a.activeSeconds != b.activeSeconds { fail(round, "\(key).activeSeconds", "\(a.activeSeconds)", "\(b.activeSeconds)") }
    if a.messageCount != b.messageCount { fail(round, "\(key).messageCount", "\(a.messageCount)", "\(b.messageCount)") }
    if a.userMessageCount != b.userMessageCount { fail(round, "\(key).userMessageCount", "\(a.userMessageCount)", "\(b.userMessageCount)") }
    if a.assistantEvents != b.assistantEvents { fail(round, "\(key).assistantEvents", "\(a.assistantEvents)", "\(b.assistantEvents)") }
    if a.hourHistogramUTC != b.hourHistogramUTC { fail(round, "\(key).hourHistogramUTC", "\(a.hourHistogramUTC)", "\(b.hourHistogramUTC)") }
}

private func bucketKey(_ b: UsageBucket) -> String {
    "\(b.source)\u{1}\(b.model)\u{1}\(b.project)\u{1}\(Int(b.bucketStart.timeIntervalSince1970))"
}
private func sessionKey(_ s: UsageSession) -> String { "\(s.source)\u{1}\(s.sessionHash)" }

private func fail(_ round: Int, _ field: String, _ a: String, _ b: String) -> Never {
    print("MISMATCH at round \(round): \(field)")
    print("  A (automatic): \(a)")
    print("  B (fullRecompute): \(b)")
    exit(1)
}

// MARK: - 临时目录

/// 解析 EQUIV_SEED：接受 0x / 0X 十六进制或十进制。无法解析时响亮失败，
/// 不静默回退——静默回退会让「换了种子」的验证实际上一直跑同一个种子。
/// 轮数解析。0 会让下面的循环一轮都不跑却照样打印 PASS —— 一个什么都没比对的
/// 门禁报成功，比直接报错危险得多；负数则会在构造 0..<rounds 时直接陷入 trap。
/// 两种都当作调用方配置错误，响亮失败。
private func parseRounds(_ raw: String?) throws -> Int {
    let fallback = 40
    guard let raw, !raw.isEmpty else { return fallback }
    guard let parsed = Int(raw), parsed > 0 else {
        FileHandle.standardError.write(Data("EQUIV_ROUNDS=\(raw) is not a positive integer\n".utf8))
        exit(2)
    }
    return parsed
}

private func parseSeed(_ raw: String?) throws -> UInt64 {
    let fallback: UInt64 = 0xC0FFEE
    guard let raw, !raw.isEmpty else { return fallback }
    let lowered = raw.lowercased()
    let parsed: UInt64? = lowered.hasPrefix("0x")
        ? UInt64(lowered.dropFirst(2), radix: 16)
        : UInt64(lowered)
    guard let parsed else {
        FileHandle.standardError.write(Data("EQUIV_SEED=\(raw) is not a valid decimal or 0x-prefixed hex integer\n".utf8))
        exit(2)
    }
    return parsed
}

private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("derived-equiv-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - LCG

private struct LCG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - 随机操作生成器

private struct RecordOp {
    let events: [UsageEvent]
    let sessionEvents: [UsageSessionEvent]
    let edits: [UsageEditEntry]
    let editMetricsSupported: Bool
    let checkpoint: UsageFileCheckpoint
}

private struct Batch {
    let records: [RecordOp]
    let missing: [String]
}

private struct Generator {
    private var activeIDs: [String] = []
    private var logicalKeys: [String] = []          // "source\teventID"
    private var lineageKeys: [String] = []
    private var codexKeys: [String] = []
    private var logicalModel: [String: String] = [:]
    private var logicalProject: [String: String] = [:]
    private var logicalSession: [String: String] = [:]

    private let sources = ["codex", "claude-code"]
    private let models = ["gpt-4o", "gpt-5", "claude-sonnet-4-5", "unknown"]
    private let projects = ["proj-alpha", "proj-beta", "proj-gamma"]
    private let skills = ["git", "bash", "python", "web-search"]
    private let mcps = ["github", "filesystem", "postgres"]
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
    private let bucketMs = UsageLedgerStore.bucketMilliseconds

    mutating func nextBatch(round: Int, rng: inout LCG) -> Batch {
        let fileCount = 3 + Int(rng.next() % 6)   // 3...8
        var records: [RecordOp] = []
        var missing: [String] = []

        for _ in 0..<fileCount {
            let fileID: String
            if !activeIDs.isEmpty && rng.next() % 100 < 40 {
                fileID = activeIDs[Int(rng.next() % UInt64(activeIDs.count))]
            } else {
                fileID = "file-\(round)-\(rng.next())"
                activeIDs.append(fileID)
            }

            let source = sources[Int(rng.next() % UInt64(sources.count))]
            let editMetricsSupported = rng.next() % 2 == 0

            let eventCount = Int(rng.next() % 31)   // 0...30（含空批次）
            var events: [UsageEvent] = []
            events.reserveCapacity(eventCount)
            for i in 0..<eventCount {
                events.append(makeEvent(fileID: fileID, source: source, index: i, rng: &rng))
            }

            var sessionEvents: [UsageSessionEvent] = []
            let sessCount = Int(rng.next() % 4)
            for s in 0..<sessCount {
                let sess = "sess-\(fileID)-\(s)"
                let ts = baseTime.addingTimeInterval(TimeInterval(rng.next() % 10000))
                sessionEvents.append(UsageSessionEvent(id: "\(sess)-u", source: source, sessionHash: sess,
                    sourceFileHash: fileID, role: .user, timestamp: ts))
                sessionEvents.append(UsageSessionEvent(id: "\(sess)-a", source: source, sessionHash: sess,
                    sourceFileHash: fileID, role: .assistant, timestamp: ts.addingTimeInterval(30)))
            }

            var edits: [UsageEditEntry] = []
            let editCount = Int(rng.next() % 4)
            for e in 0..<editCount {
                let toolUseID: String
                if rng.next() % 100 < 30 && !codexKeys.isEmpty {
                    toolUseID = "edit-\(codexKeys[Int(rng.next() % UInt64(codexKeys.count))])"
                } else {
                    toolUseID = "edit-\(fileID)-\(e)"
                }
                edits.append(UsageEditEntry(source: source,
                    model: models[Int(rng.next() % UInt64(models.count))],
                    project: projects[Int(rng.next() % UInt64(projects.count))],
                    sourceFileHash: fileID,
                    timestamp: baseTime.addingTimeInterval(TimeInterval(rng.next() % 10000)),
                    added: Int64(rng.next() % 100), deleted: Int64(rng.next() % 50),
                    toolUseID: toolUseID))
            }

            let checkpoint = UsageFileCheckpoint(fileID: fileID, source: source, pathHash: fileID,
                offset: 0, size: 1,
                modifiedAt: baseTime.addingTimeInterval(TimeInterval(round) * 3600),
                parserVersion: UsageJSONLParser.parserVersion, status: "complete")

            records.append(RecordOp(events: events, sessionEvents: sessionEvents, edits: edits,
                                    editMetricsSupported: editMetricsSupported, checkpoint: checkpoint))
        }

        // 随机把部分活跃文件标为 missing，改变 tier 归属，触发 logical 去重胜者易主。
        if !activeIDs.isEmpty && rng.next() % 100 < 30 {
            let missCount = 1 + Int(rng.next() % 2)
            for _ in 0..<missCount where !activeIDs.isEmpty {
                let idx = Int(rng.next() % UInt64(activeIDs.count))
                missing.append(activeIDs.remove(at: idx))
            }
        }

        return Batch(records: records, missing: missing)
    }

    private mutating func makeEvent(fileID: String, source: String, index: Int, rng: inout LCG) -> UsageEvent {
        // logical 键：约 25% 概率复用已有 (source, event_id)，制造跨文件 logical 去重；
        // 其中约 40% 故意用不同 model/project/session，触发 identity conflict。
        let logicalKey: String
        let model: String
        let project: String
        let session: String

        if rng.next() % 100 < 25 && !logicalKeys.isEmpty {
            let key = logicalKeys[Int(rng.next() % UInt64(logicalKeys.count))]
            logicalKey = key
            if rng.next() % 100 < 40 {
                model = models[Int(rng.next() % UInt64(models.count))]
                project = projects[Int(rng.next() % UInt64(projects.count))]
                session = "sess-conflict-\(rng.next())"
            } else {
                model = logicalModel[key] ?? models[0]
                project = logicalProject[key] ?? projects[0]
                session = logicalSession[key] ?? "sess-0"
            }
        } else {
            let eventID = "evt-\(fileID)-\(index)"
            logicalKey = "\(source)\t\(eventID)"
            logicalKeys.append(logicalKey)
            model = models[Int(rng.next() % UInt64(models.count))]
            project = projects[Int(rng.next() % UInt64(projects.count))]
            session = "sess-\(fileID)-\(index / 3)"
            logicalModel[logicalKey] = model
            logicalProject[logicalKey] = project
            logicalSession[logicalKey] = session
        }

        let parts = logicalKey.split(separator: "\t")
        let eventSource = String(parts[0])
        let eventID = String(parts[1])

        // 时间戳跨多个 30 分钟 bucket，也有同 bucket 内的。
        let bucketOffset = Int(rng.next() % 20)
        let ts = baseTime.addingTimeInterval(
            TimeInterval(bucketOffset) * TimeInterval(bucketMs) / 1000
            + TimeInterval(rng.next() % 1000))

        let counts = UsageTokenCounts(
            input: Int64(rng.next() % 500),
            output: Int64(rng.next() % 200),
            cachedInput: Int64(rng.next() % 100),
            reasoningOutput: Int64(rng.next() % 50))

        // lineage 指纹：约 15% 概率，一半复用已有指纹（跨文件继承回放），一半新建。
        var lineageFingerprint = ""
        var inherited = false
        if rng.next() % 100 < 15 {
            if rng.next() % 100 < 50 && !lineageKeys.isEmpty {
                lineageFingerprint = lineageKeys[Int(rng.next() % UInt64(lineageKeys.count))]
            } else {
                lineageFingerprint = "lineage-\(rng.next())"
                lineageKeys.append(lineageFingerprint)
            }
            inherited = rng.next() % 2 == 0
        }

        // codex 去重键：约 15% 概率，一半复用（fork 副本，胜者按 billableTotal 最大）。
        var codexDedupKey = ""
        if rng.next() % 100 < 15 {
            if rng.next() % 100 < 50 && !codexKeys.isEmpty {
                codexDedupKey = codexKeys[Int(rng.next() % UInt64(codexKeys.count))]
            } else {
                codexDedupKey = "codex-\(rng.next())"
                codexKeys.append(codexDedupKey)
            }
        }

        var skillCounts: [String: Int] = [:]
        var mcpCounts: [String: Int] = [:]
        if rng.next() % 100 < 30 {
            skillCounts[skills[Int(rng.next() % UInt64(skills.count))]] = Int(rng.next() % 5) + 1
        }
        if rng.next() % 100 < 30 {
            mcpCounts[mcps[Int(rng.next() % UInt64(mcps.count))]] = Int(rng.next() % 5) + 1
        }

        let mergeStrategy: UsageEvent.MergeStrategy = eventSource == "codex" ? .overwrite : .cumulativeMax

        return UsageEvent(id: eventID, source: eventSource, model: model, project: project,
            timestamp: ts, counts: counts, sessionHash: session, sourceFileHash: fileID,
            inherited: inherited, hasTotalSnapshot: !lineageFingerprint.isEmpty,
            lineageFingerprint: lineageFingerprint, codexDedupKey: codexDedupKey,
            mergeStrategy: mergeStrategy, skillCounts: skillCounts, mcpCounts: mcpCounts)
    }
}
