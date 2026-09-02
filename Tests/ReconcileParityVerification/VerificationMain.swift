import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage
import AgentPulseReconcileParity

/// 离线对齐验证工具：证明本地账本聚合与 upstream `GET /api/usage/reconcile` 逐维度一致。
///
/// 严格只读、绝不上报（不构造任何 POST /ingest）。分两段：
/// 1. 离线自检（永远跑）：mock 数据喂纯函数，验证口径处理与对齐逻辑正确。
/// 2. 实拉（配置齐才跑）：读 reporting.json + env base URL → 取 token → GET → 逐维度对齐。
///    默认环境未配置时优雅跳过；设 AGENT_PULSE_RECONCILE_REQUIRE_LIVE=1 后「跳过」即失败。
///    一旦真的拉到 upstream 数据，不对齐一律失败，与该开关无关 —— 已经拿到证据还放行，
///    这个 target 就只剩打印功能。
///
/// 脱敏：只输出字段名、聚合数与 ✓/✗；不输出 token、凭证、会话正文、完整路径。
@main
enum ReconcileParityVerification {
    /// env：upstream base URL 覆盖开关（可选）。默认从合并 env 的 REPORT_BASE_URL 读；
    /// 设了此环境变量则优先用它,便于临时指向测试后端。工具不落盘、不碰 UserDefaults。
    private static let baseURLEnvKey = "AGENT_PULSE_RECONCILE_BASE_URL"

    /// env：把实拉从「可选」升级为「必须」。发布前用它跑 —— 配置不全就直接失败，
    /// 而不是打印一行「跳过实拉」再 exit 0，后者会让验证清单上的这条绿色不含任何信息。
    private static let requireLiveEnvKey = "AGENT_PULSE_RECONCILE_REQUIRE_LIVE"

    /// 实拉结论。skipped 携带原因，供 require 模式下原样打印并据以判失败。
    private enum LiveOutcome {
        case skipped(String)
        case aligned
        case misaligned(String)
    }

    static func main() async throws {
        try await runOfflineSelfCheck()
        print("离线自检通过：唯一 total 含 cacheCreation、差值归因 upstream 漏计、逐维度对齐、脱敏渲染均正确。")
        print("")
        if ProcessInfo.processInfo.environment["AGENT_PULSE_RECONCILE_DEMO"] != nil {
            printDemoTables()
        }
        if ProcessInfo.processInfo.environment["AGENT_PULSE_RECONCILE_LOCAL"] != nil {
            try printLocalAggregate()
        }
        let requireLive = isEnabled(ProcessInfo.processInfo.environment[requireLiveEnvKey])
        switch await runLiveReconcile() {
        case let .skipped(reason):
            print("跳过实拉：\(reason)")
            guard !requireLive else {
                FileHandle.standardError.write(Data("""
                    ReconcileParityVerification: FAIL \(requireLiveEnvKey) 已设置但实拉没能执行（\(reason)）。\
                    该模式下「跳过」即失败：没有真的打到 upstream，就没有任何证据说明本地账本与服务端一致。

                    """.utf8))
                Foundation.exit(2)
            }
            print("提示：设 \(requireLiveEnvKey)=1 可要求实拉必须执行，配置不全时直接失败而非静默跳过。")
        case .aligned:
            print("✅ 实拉对齐通过：全部 authoritative 维度相等。")
        case let .misaligned(reason):
            FileHandle.standardError.write(Data("""
                ReconcileParityVerification: FAIL 本地账本与 upstream 不对齐 —— \(reason)

                """.utf8))
            Foundation.exit(1)
        }
    }

    /// 环境变量真值判定：非空且不是 0/false/no 即视为开启。
    private static func isEnabled(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return false }
        return !["0", "false", "no"].contains(value)
    }

    /// 本机真实账本聚合（env AGENT_PULSE_RECONCILE_LOCAL 触发）：只读账本、按合并 env 的
    /// REPORT_CANONICAL_HOSTNAME 聚合，打印工具口径下的每一维数字并做口径自洽断言
    /// （五分量相加 = total、total − cacheCreation = upstream 应回值）。不连 upstream、不上报、脱敏。
    private static func printLocalAggregate() throws {
        let mergedEnv = (try? EnvFile.load(path: MergedEnvKeys.defaultPath)) ?? [:]
        // hostname 优先取 env 覆盖（离线库对齐用），否则合并 env 的 REPORT_CANONICAL_HOSTNAME。
        let hostname = CanonicalHostname.normalize(
            ProcessInfo.processInfo.environment["AGENT_PULSE_RECONCILE_HOSTNAME"]
                ?? mergedEnv[MergedEnvKeys.reportCanonicalHostname] ?? ""
        )
        guard !hostname.isEmpty else {
            print("跳过本地聚合：未提供 hostname（AGENT_PULSE_RECONCILE_HOSTNAME 或合并 env 的 REPORT_CANONICAL_HOSTNAME）。")
            return
        }
        // 库路径：优先 env 指定的离线副本（绝不传活库），否则默认 appSupport 库。
        let ledger: UsageLedgerStore?
        if let offline = ProcessInfo.processInfo.environment["AGENT_PULSE_RECONCILE_DB"], !offline.isEmpty {
            ledger = try? UsageLedgerStore(path: offline)
        } else {
            ledger = openLedger()
        }
        guard let ledger else {
            print("跳过本地聚合：无法打开账本。")
            return
        }
        let buckets: [UsageBucket]
        let sessions: [UsageSession]
        do {
            buckets = try ledger.buckets(hostname: hostname)
            sessions = try ledger.sessions(hostname: hostname)
        } catch {
            print("跳过本地聚合：读取账本失败。")
            return
        }
        let agg = LocalHostnameAggregate.aggregate(hostname: hostname, buckets: buckets, sessions: sessions)
        let upstreamExpected = LocalHostnameAggregate.upstreamBasisFromTotal(agg.totalTokens, cacheCreation: agg.cacheCreationInputSubtotal)

        print("=== 本机真实账本聚合（hostname=\(hostname)，只读，不连 upstream） ===")
        print("bucketCount                 \(agg.bucketCount)")
        print("sessionCount                \(agg.sessionCount)")
        print("唯一 total(含 cacheCreation)  \(agg.totalTokens)")
        print("upstream 应回值(total−cacheCr)   \(upstreamExpected)")
        print("小计.input                   \(agg.inputSubtotal)")
        print("小计.output                  \(agg.outputSubtotal)")
        print("小计.cachedInput             \(agg.cachedInputSubtotal)")
        print("小计.reasoningOutput         \(agg.reasoningOutputSubtotal)")
        print("小计.cacheCreationInput      \(agg.cacheCreationInputSubtotal)")
        if let f = agg.firstBucketAt { print("firstBucketAt               \(iso(f))") }
        if let l = agg.lastBucketAt { print("lastBucketAt                \(iso(l))") }
        // 原先这里比的是 upstreamExpected == max(0, total − cacheCreation)，而 upstreamExpected
        // 的定义就是这个表达式 —— 恒真，永远打印 ✅，测不到任何东西。换成真正能被违反的不变量。
        try require(
            checkAggregateInvariants(agg),
            "聚合口径不自洽（详见 checkAggregateInvariants 的三条不变量）"
        )
        let componentSum = componentSumOf(agg)
        // total = max(reportedTotal, 五分量和)，所以两者相等是常态，不等则说明该 hostname 下
        // 存在 upstream 直接给了 total_tokens 且大于分量之和的事件（cliproxy 口径），需要点明，
        // 否则「total 比分量和大」会被误读成聚合出错。
        if componentSum == agg.totalTokens {
            print("✅ 口径自洽：五分量之和 == 唯一 total == \(agg.totalTokens)")
        } else {
            print("✅ 口径自洽：五分量之和 \(componentSum) ≤ 唯一 total \(agg.totalTokens)",
                  "（差 \(agg.totalTokens - componentSum) 来自 reportedTotal 大于分量和的事件）")
        }
        print("")
    }

    /// 五分量之和。饱和加法，与账本聚合口径一致。
    private static func componentSumOf(_ agg: LocalHostnameAggregate) -> Int64 {
        [agg.inputSubtotal, agg.outputSubtotal, agg.cachedInputSubtotal,
         agg.reasoningOutputSubtotal, agg.cacheCreationInputSubtotal]
            .reduce(Int64(0)) { partial, value in
                let (sum, overflow) = partial.addingReportingOverflow(value)
                return overflow ? Int64.max : sum
            }
    }

    /// 聚合结果必须满足的三条不变量。抽成纯函数，好让离线自检直接喂反例验证它真的会拒。
    ///  1. 五分量之和 ≤ 唯一 total —— total 定义为 max(reportedTotal, 分量和)，反过来说明聚合丢了量。
    ///  2. upstream 应回值 ≤ 唯一 total —— 它是 total 减去 cacheCreation，不可能更大。
    ///  3. 分量与计数均非负 —— 负值意味着 Int64 回绕或 parser 输出了负数，这份聚合不可用。
    private static func checkAggregateInvariants(_ agg: LocalHostnameAggregate) -> Bool {
        let components = [
            agg.inputSubtotal, agg.outputSubtotal, agg.cachedInputSubtotal,
            agg.reasoningOutputSubtotal, agg.cacheCreationInputSubtotal,
        ]
        guard components.allSatisfy({ $0 >= 0 }), agg.totalTokens >= 0,
              agg.bucketCount >= 0, agg.sessionCount >= 0 else { return false }
        guard componentSumOf(agg) <= agg.totalTokens else { return false }
        let upstreamExpected = LocalHostnameAggregate.upstreamBasisFromTotal(
            agg.totalTokens, cacheCreation: agg.cacheCreationInputSubtotal
        )
        return upstreamExpected <= agg.totalTokens
    }

    /// 仅演示：用 mock upstream 响应渲染 AP vs upstream 对齐表（一致 + 不一致两例），
    /// 供人工核对报告格式。env AGENT_PULSE_RECONCILE_DEMO 存在时才输出，默认不跑。
    private static func printDemoTables() {
        let buckets = [
            makeBucket(hostname: "mbp-work", model: "sonnet", input: 100, output: 200, cached: 50, cacheCreation: 999, reasoning: 30, startOffset: 0),
            makeBucket(hostname: "mbp-work", model: "opus", input: 10, output: 20, cached: 5, cacheCreation: 40, reasoning: 3, startOffset: 3600),
        ]
        let sessions = [makeSession(hostname: "mbp-work"), makeSession(hostname: "mbp-work"), makeSession(hostname: "mbp-work")]
        let agg = LocalHostnameAggregate.aggregate(hostname: "mbp-work", buckets: buckets, sessions: sessions)
        let first = iso(buckets[0].bucketStart), last = iso(buckets[1].bucketStart)
        // 唯一 total：bucket1=100+200+50+999+30=1379，bucket2=10+20+5+40+3=78 → 1457。
        // cacheCreation 小计=999+40=1039。upstream 应回值（漏计 cacheCreation）=1457−1039=418。
        let aligned = ReconcileResponse.HostnameStats(hostname: "mbp-work", bucketCount: 2, sessionCount: 3, totalTokens: 418, totalCostCents: 137, firstBucketAt: first, lastBucketAt: last, lastSyncedAt: last)
        print("【演示·场景一：对齐口径 — upstream 回 418，差值=cacheCreation 1039，判一致】")
        print(ReconcileReportRenderer.render(ReconcileComparison.compare(local: agg, upstream: aligned)))
        print("")
        // 差异既不等于 418（upstream 应回值）也不等于 1457（完整 total），无法用 cacheCreation 解释。
        let wrong = ReconcileResponse.HostnameStats(hostname: "mbp-work", bucketCount: 2, sessionCount: 3, totalTokens: 500, totalCostCents: 137, firstBucketAt: first, lastBucketAt: last, lastSyncedAt: last)
        print("【演示·场景二：不对齐口径 — upstream 回 500，无法用 cacheCreation 解释，判不一致】")
        print(ReconcileReportRenderer.render(ReconcileComparison.compare(local: agg, upstream: wrong)))
        print("")
    }

    // MARK: - 离线自检（纯函数，无 I/O）

    private static func runOfflineSelfCheck() async throws {
        try verifyTotalIncludesCacheCreation()
        try verifyAggregateSums()
        try verifyComparisonEqualAndUnequal()
        try verifyMissingHostnameIsUnequal()
        try verifyRendererIsDesensitized()
        try verifyAggregateInvariantsRejectBadInput()
        try verifyMisalignedUpstreamIsFatal()
        try await verifyClientDecodesAndAlignsWithMockTransport()
    }


    /// 聚合不变量必须真的能拒。正常聚合（含 reportedTotal 大于分量和的合法情形）要通过，
    /// 分量和超过 total、出现负值这两类坏输入要被拒 —— 否则这条断言又会退回成恒真的装饰。
    private static func verifyAggregateInvariantsRejectBadInput() throws {
        let healthy = LocalHostnameAggregate.aggregate(
            hostname: "dev-a",
            buckets: [makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0)],
            sessions: [makeSession(hostname: "dev-a")]
        )
        try require(checkAggregateInvariants(healthy), "正常聚合必须通过不变量")
        try require(componentSumOf(healthy) == healthy.totalTokens, "无 reportedTotal 时分量和应恰等于 total")

        // reportedTotal 大于分量和（cliproxy 口径）：total 被抬高，分量和严格小于 total，仍属合法。
        var reportedDominant = healthy
        reportedDominant.totalTokens = healthy.totalTokens + 500
        try require(checkAggregateInvariants(reportedDominant), "reportedTotal 抬高 total 属合法，不得误判")
        try require(componentSumOf(reportedDominant) < reportedDominant.totalTokens, "该场景下分量和应严格小于 total")

        // 分量和超过 total：聚合丢了量，必须拒。
        var inflated = healthy
        inflated.totalTokens = componentSumOf(healthy) - 1
        try require(!checkAggregateInvariants(inflated), "分量和大于 total 必须被拒")

        // 负分量：Int64 回绕或 parser 输出负数，必须拒。
        var negative = healthy
        negative.outputSubtotal = -1
        try require(!checkAggregateInvariants(negative), "负分量必须被拒")
    }

    /// 实拉判决必须真的会失败。这是本 target 的存在理由：拿到 upstream 数据后发现不对齐
    /// 却仍然 exit 0，等于只是个打印工具。三种输入各断言一次结论，并要求失败原因带上不等的
    /// 维度名（否则报错没法定位）且不泄露凭证。
    private static func verifyMisalignedUpstreamIsFatal() throws {
        let buckets = [makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0)]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: [makeSession(hostname: "dev-a")])
        let stamp = iso(buckets[0].bucketStart)
        // 本地唯一 total=138，cacheCreation=100 → upstream 应回 38。
        func stats(bucketCount: Int, sessionCount: Int, totalTokens: Int64) -> ReconcileResponse.HostnameStats {
            ReconcileResponse.HostnameStats(
                hostname: "dev-a", bucketCount: bucketCount, sessionCount: sessionCount,
                totalTokens: totalTokens, totalCostCents: 12,
                firstBucketAt: stamp, lastBucketAt: stamp, lastSyncedAt: nil
            )
        }

        let aligned = verdict(
            for: ReconcileComparison.compare(local: agg, upstream: stats(bucketCount: 1, sessionCount: 1, totalTokens: 38)),
            hostname: "dev-a"
        )
        guard case .aligned = aligned else {
            throw VerificationError.failed("口径一致的 upstream 响应应判 aligned，实得 \(aligned)")
        }

        // totalTokens 差值既不等于 upstream 应回值也不等于完整 total，无法用 cacheCreation 解释。
        let wrongTotal = verdict(
            for: ReconcileComparison.compare(local: agg, upstream: stats(bucketCount: 1, sessionCount: 1, totalTokens: 500)),
            hostname: "dev-a"
        )
        guard case let .misaligned(totalReason) = wrongTotal else {
            throw VerificationError.failed("totalTokens 无法解释的差异必须判 misaligned，实得 \(wrongTotal)")
        }
        try require(totalReason.contains("totalTokens"), "失败原因须点明 totalTokens，实得：\(totalReason)")

        // bucketCount / sessionCount 属 authoritative，任一不等都必须失败。
        let wrongCounts = verdict(
            for: ReconcileComparison.compare(local: agg, upstream: stats(bucketCount: 7, sessionCount: 9, totalTokens: 38)),
            hostname: "dev-a"
        )
        guard case let .misaligned(countReason) = wrongCounts else {
            throw VerificationError.failed("bucketCount/sessionCount 不等必须判 misaligned，实得 \(wrongCounts)")
        }
        try require(countReason.contains("bucketCount"), "失败原因须点明 bucketCount，实得：\(countReason)")
        try require(countReason.contains("sessionCount"), "失败原因须点明 sessionCount，实得：\(countReason)")

        // upstream 完全没有这台设备：同样不能算通过。
        let absent = verdict(
            for: ReconcileComparison.compare(local: agg, upstream: nil),
            hostname: "dev-a"
        )
        guard case let .misaligned(absentReason) = absent else {
            throw VerificationError.failed("upstream 缺该 hostname 必须判 misaligned，实得 \(absent)")
        }
        try require(!absentReason.isEmpty, "缺设备时也须给出失败原因")
    }

    /// mock transport 喂一段 upstream JSON，验证 ReconcileClient 能构造 GET、解码、
    /// 并与本地聚合逐维度对齐——覆盖实拉整链（不依赖真实网络 / 配置）。
    private static func verifyClientDecodesAndAlignsWithMockTransport() async throws {
        let buckets = [makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0)]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: [makeSession(hostname: "dev-a")])
        let firstIso = iso(buckets[0].bucketStart)
        // upstream 原始响应 JSON（无 envelope）：本地唯一 total=138，cacheCreation=100，
        // upstream 应回值=138−100=38；差值恰为 cacheCreation，判一致（已解释）。
        let json = """
        {"hostnames":[{"hostname":"dev-a","bucketCount":1,"sessionCount":1,"totalTokens":38,"totalCostCents":12,"firstBucketAt":"\(firstIso)","lastBucketAt":"\(firstIso)","lastSyncedAt":null}]}
        """
        let sender = MockSender(statusCode: 200, body: Data(json.utf8))
        // 用最小合法配置：authToken=X-Jwt-Token，path 合法。
        var config = TokenReportingConfiguration()
        config.path = "/api/usage/reconcile"
        config.headers.authToken = ReconcileClient.requiredJWTHeaderName
        let baseURL = URL(string: "https://upstream.example.com")!
        let client = ReconcileClient(sender: sender)
        let response = try await client.fetch(configuration: config, baseURL: baseURL, token: SecretToken("fake-jwt-for-test"))

        // 请求必须是 GET、带 auth header、URL 正确拼接。
        try require(sender.lastRequest?.httpMethod == "GET", "必须构造 GET")
        try require(sender.lastRequest?.value(forHTTPHeaderField: ReconcileClient.requiredJWTHeaderName) == "fake-jwt-for-test", "必须带 JWT auth header")
        try require(sender.lastRequest?.url?.absoluteString == "https://upstream.example.com/api/usage/reconcile", "URL 拼接应正确")

        let comparison = ReconcileComparison.compare(local: agg, upstream: response.stats(forHostname: "dev-a"))
        try require(comparison.isAligned, "mock 整链：口径处理后应一致")

        // authHeaderNotJWT：header 名不对时应报错、绝不发请求。
        var badConfig = config
        badConfig.headers.authToken = "Authorization"
        do {
            _ = try ReconcileClient.makeRequest(configuration: badConfig, baseURL: baseURL, token: SecretToken("x"))
            try require(false, "auth header 名不对应报错")
        } catch ReconcileFetchError.authHeaderNotJWT {
            // 期望
        }
    }

    /// 只读 mock transport：记录最后一次请求，返回预设响应。绝不发真实网络。
    private final class MockSender: HTTPRequestSending, @unchecked Sendable {
        let statusCode: Int
        let body: Data
        private(set) var lastRequest: URLRequest?
        init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
        func send(_ request: URLRequest) async throws -> HTTPResponse {
            lastRequest = request
            return HTTPResponse(statusCode: statusCode, body: body)
        }
    }


    /// 唯一 total = 五分量互斥之和（含 cacheCreation）；upstream 口径基准 = total − cacheCreation。
    private static func verifyTotalIncludesCacheCreation() throws {
        // 五分量互斥之和 = 10+20+5+100+3 = 138（含 cacheCreation=100）。
        let counts = UsageTokenCounts(
            input: 10, output: 20, cachedInput: 5, cacheCreationInput: 100, reasoningOutput: 3, reportedTotal: 0
        )
        try require(counts.total == 138, "唯一 total 应含 cacheCreation=138，实际 \(counts.total)")
        // upstream 口径基准（漏计 cacheCreation）= 138 − 100 = 38。
        try require(LocalHostnameAggregate.upstreamBasisFromTotal(counts.total, cacheCreation: 100) == 38,
                    "upstream 应回值应为 38（total 138 − cacheCreation 100）")

        // reportedTotal 更大时唯一 total 取 reportedTotal。
        let reported = UsageTokenCounts(input: 1, output: 1, reportedTotal: 999)
        try require(reported.total == 999, "reportedTotal 更大时唯一 total 应取 999")
    }

    /// 聚合分量小计与唯一 total 求和正确，bucketCount/sessionCount 计数正确。
    private static func verifyAggregateSums() throws {
        let buckets = [
            makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0),
            makeBucket(hostname: "dev-a", model: "m2", input: 1, output: 2, cached: 0, cacheCreation: 7, reasoning: 0, startOffset: 3600),
        ]
        let sessions = [makeSession(hostname: "dev-a"), makeSession(hostname: "dev-a")]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: sessions)

        try require(agg.bucketCount == 2, "bucketCount 应为 2")
        try require(agg.sessionCount == 2, "sessionCount 应为 2")
        // bucket1 total=138, bucket2 total=1+2+0+7+0=10 → 唯一 total = 148。
        try require(agg.totalTokens == 148, "唯一 total 应为 148（138+10），实际 \(agg.totalTokens)")
        try require(agg.inputSubtotal == 11, "input 小计应为 11")
        try require(agg.cacheCreationInputSubtotal == 107, "cacheCreation 小计应为 107")
        // upstream 应回值 = 148 − 107 = 41。
        try require(LocalHostnameAggregate.upstreamBasisFromTotal(agg.totalTokens, cacheCreation: agg.cacheCreationInputSubtotal) == 41,
                    "upstream 应回值应为 41（148−107）")
        try require(agg.firstBucketAt == buckets[0].bucketStart, "firstBucketAt 应为最早 bucket")
        try require(agg.lastBucketAt == buckets[1].bucketStart, "lastBucketAt 应为最晚 bucket")
    }

    /// 对齐逻辑：upstream total 差一个 cacheCreation 仍判一致（已解释）；无法解释的差异判不等。
    private static func verifyComparisonEqualAndUnequal() throws {
        // bucket: total = 10+20+5+100+3 = 138；cacheCreation=100；upstream 应回值 = 38。
        let buckets = [makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0)]
        let sessions = [makeSession(hostname: "dev-a")]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: sessions)
        let firstIso = iso(buckets[0].bucketStart)

        // upstream 回 38（total−cacheCreation）：差值恰为 cacheCreation，判一致（已解释）。
        let upstreamBasis = ReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 1, totalTokens: 38, totalCostCents: 0,
            firstBucketAt: firstIso, lastBucketAt: firstIso, lastSyncedAt: nil
        )
        try require(ReconcileComparison.compare(local: agg, upstream: upstreamBasis).isAligned,
                    "upstream 差一个 cacheCreation 应判一致（已解释）")

        // upstream 回完整 138（若某天 upstream 修正口径）：也判一致。
        let upstreamFull = ReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 1, totalTokens: 138, totalCostCents: 0,
            firstBucketAt: firstIso, lastBucketAt: firstIso, lastSyncedAt: nil
        )
        try require(ReconcileComparison.compare(local: agg, upstream: upstreamFull).isAligned,
                    "upstream 回完整 total 应判一致")

        // upstream 回 39（差值无法用 cacheCreation 解释）：应判不等。
        let mismatched = ReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 1, totalTokens: 39, totalCostCents: 0,
            firstBucketAt: firstIso, lastBucketAt: firstIso, lastSyncedAt: nil
        )
        let notAligned = ReconcileComparison.compare(local: agg, upstream: mismatched)
        try require(!notAligned.isAligned, "无法用 cacheCreation 解释的 total 差异应判不一致")

        // advisory / localOnlyDetail 维度 equal 恒为 nil，不参与判定。
        let advisory = notAligned.fields.filter { $0.kind != .authoritative }
        try require(advisory.allSatisfy { $0.equal == nil }, "非权威维度不应带 equal 判定")
    }

    /// upstream 无该 hostname 时，权威维度记不等、整体不一致。
    private static func verifyMissingHostnameIsUnequal() throws {
        let agg = LocalHostnameAggregate.aggregate(
            hostname: "ghost",
            buckets: [makeBucket(hostname: "ghost", model: "m1", input: 1, output: 1, cached: 0, cacheCreation: 0, reasoning: 0, startOffset: 0)],
            sessions: []
        )
        let comparison = ReconcileComparison.compare(local: agg, upstream: nil)
        try require(!comparison.upstreamPresent, "应标记 upstream 无此设备")
        try require(!comparison.isAligned, "upstream 缺该 hostname 应判不一致")
    }

    /// 渲染输出不得包含任何机密样式内容（这里以确定性内容验证脱敏结构）。
    private static func verifyRendererIsDesensitized() throws {
        let agg = LocalHostnameAggregate.aggregate(
            hostname: "dev-a",
            buckets: [makeBucket(hostname: "dev-a", model: "secret-model", input: 1, output: 1, cached: 0, cacheCreation: 0, reasoning: 0, startOffset: 0)],
            sessions: []
        )
        let stats = ReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 0, totalTokens: 2, totalCostCents: 5,
            firstBucketAt: nil, lastBucketAt: nil, lastSyncedAt: nil
        )
        let text = ReconcileReportRenderer.render(ReconcileComparison.compare(local: agg, upstream: stats))
        // 渲染只含聚合维度名与数字；不含 model 明细（model 不是对齐维度，不进报告）。
        try require(!text.contains("secret-model"), "渲染不应泄露逐 bucket 的 model 明细")
        try require(text.contains("bucketCount"), "渲染应含权威维度名")
    }

    // MARK: - 实拉（配置齐才跑；REQUIRE_LIVE 下跳过即失败，拉到即断言）

    /// 返回实拉结论而不是自行打印后 return。调用方据此决定退出码 —— 关键在于
    /// 「拉到了数据但不对齐」必须失败，这是整个 target 存在的理由。
    private static func runLiveReconcile() async -> LiveOutcome {
        // 1) reporting.json：缺失 / 权限不安全 → 跳过。
        let configURL = defaultConfigurationURL()
        let configuration: TokenReportingConfiguration
        do {
            configuration = try TokenUsageReporter.loadConfiguration(from: configURL)
        } catch {
            return .skipped("reporting.json 未配置或权限不安全（需 0600）")
        }

        // 2) authToken header 名必须是 upstream 认可的 JWT header。
        guard configuration.headers.authToken.caseInsensitiveCompare(ReconcileClient.requiredJWTHeaderName) == .orderedSame else {
            return .skipped("reporting.json 的 headers.authToken 需设为 \"\(ReconcileClient.requiredJWTHeaderName)\" 才能打通 upstream")
        }

        // 3) base URL 与 hostname 来自合并 env（与 app 同一来源单一真相）：
        //    REPORT_BASE_URL / REPORT_CANONICAL_HOSTNAME。base URL 允许用环境变量覆盖
        //    （AGENT_PULSE_RECONCILE_BASE_URL）以便临时指向测试后端。
        let mergedEnv = (try? EnvFile.load(path: MergedEnvKeys.defaultPath)) ?? [:]
        let envOverride = ProcessInfo.processInfo.environment[baseURLEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawBase = (envOverride?.isEmpty == false ? envOverride! :
            (mergedEnv[MergedEnvKeys.reportBaseURL] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rawBase.isEmpty,
              let baseURL = URL(string: rawBase),
              TokenUsageReporter.isValidBaseURL(baseURL) else {
            return .skipped("合并 env 的 REPORT_BASE_URL（或环境变量 \(baseURLEnvKey)）未配置或不是合法 base URL（生产要求 https）")
        }

        // 4) hostname 以合并 env 的 REPORT_CANONICAL_HOSTNAME 为准（与 app 上报身份一致）。
        let hostname = CanonicalHostname.normalize(mergedEnv[MergedEnvKeys.reportCanonicalHostname] ?? "")
        guard !hostname.isEmpty else {
            return .skipped("合并 env 缺 REPORT_CANONICAL_HOSTNAME")
        }

        // 5) 取 token（外部进程）；失败 → 跳过，不崩溃。
        let token: SecretToken
        do {
            token = try ConfiguredCommandTokenProvider(configuration: configuration.tokenCommand.providerConfiguration).token()
        } catch {
            return .skipped("本地取 token 失败（凭证命令未配置或返回异常）")
        }

        // 6) GET reconcile。
        let response: ReconcileResponse
        do {
            response = try await ReconcileClient().fetch(configuration: configuration, baseURL: baseURL, token: token)
        } catch let error as ReconcileFetchError {
            return .skipped("拉取 upstream reconcile 失败（\(desensitize(error))）")
        } catch {
            return .skipped("拉取 upstream reconcile 失败（网络异常）")
        }

        // 7) 本地账本聚合。
        guard let ledger = openLedger() else {
            return .skipped("无法打开本地账本")
        }
        let localBuckets: [UsageBucket]
        let localSessions: [UsageSession]
        do {
            localBuckets = try ledger.buckets(hostname: hostname)
            localSessions = try ledger.sessions(hostname: hostname)
        } catch {
            return .skipped("读取本地账本失败")
        }
        let aggregate = LocalHostnameAggregate.aggregate(hostname: hostname, buckets: localBuckets, sessions: localSessions)

        // 8) 逐维度对齐 + 渲染。
        let comparison = ReconcileComparison.compare(local: aggregate, upstream: response.stats(forHostname: hostname))
        print("=== AP vs upstream 逐维度对齐 ===")
        print(ReconcileReportRenderer.render(comparison))
        return verdict(for: comparison, hostname: hostname)
    }

    /// 由对齐结果得出实拉结论。纯函数、无 I/O，因此「不对齐必须失败」这条分支可以在离线
    /// 自检里被真的执行到，而不是只存在于一条本机永远走不到的网络路径上。
    /// 失败原因只收敛维度名与数字，不含 token / 凭证 / 会话正文。
    private static func verdict(for comparison: HostnameComparison, hostname: String) -> LiveOutcome {
        guard comparison.isAligned else {
            let offenders = comparison.fields
                .filter { $0.equal == false }
                .map { "\($0.field)(本地 \($0.localValue) / upstream \($0.upstreamValue))" }
            let detail = offenders.isEmpty
                ? "upstream 未返回 hostname \(hostname)"
                : offenders.joined(separator: "；")
            return .misaligned(detail)
        }
        return .aligned
    }

    // MARK: - Helpers

    private static func defaultConfigurationURL() -> URL {
        let directory = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? FileManager.default.temporaryDirectory
        return directory.appending(path: "AgentPulse/reporting.json")
    }

    /// 打开与 app 相同路径的账本（owner-only 目录 + usage.sqlite3）。只读用途。
    private static func openLedger() -> UsageLedgerStore? {
        guard let directory = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ).appending(path: "AgentPulse", directoryHint: .isDirectory) else { return nil }
        return try? UsageLedgerStore(path: directory.appending(path: "usage.sqlite3").path)
    }

    private static func desensitize(_ error: ReconcileFetchError) -> String {
        switch error {
        case .invalidBaseURL: return "base URL 无效"
        case .invalidPath: return "path 无效"
        case .authHeaderNotJWT: return "auth header 名不匹配"
        case .tokenUnavailable: return "token 为空"
        case let .httpFailure(statusCode): return "HTTP \(statusCode)"
        case .transportFailure: return "网络传输失败"
        case .malformedResponse: return "响应无法解析"
        }
    }

    private static func makeBucket(
        hostname: String, model: String,
        input: Int64, output: Int64, cached: Int64, cacheCreation: Int64, reasoning: Int64,
        startOffset: TimeInterval
    ) -> UsageBucket {
        UsageBucket(
            hostname: hostname,
            source: "claude-code",
            model: model,
            project: "proj",
            bucketStart: Date(timeIntervalSince1970: 1_700_000_000 + startOffset),
            counts: UsageTokenCounts(
                input: input, output: output, cachedInput: cached,
                cacheCreationInput: cacheCreation, reasoningOutput: reasoning, reportedTotal: 0
            )
        )
    }

    private static func makeSession(hostname: String) -> UsageSession {
        UsageSession(
            hostname: hostname, source: "claude-code", sessionHash: UUID().uuidString, project: "proj",
            firstActivity: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_700_000_100),
            activeSeconds: 100, messageCount: 4, userMessageCount: 2, assistantEvents: 2,
            hourHistogramUTC: [Int64](repeating: 0, count: 24)
        )
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() {
            FileHandle.standardError.write(Data("对齐验证失败: \(message)\n".utf8))
            throw VerificationError.failed(message)
        }
    }

    private enum VerificationError: Error { case failed(String) }
}
