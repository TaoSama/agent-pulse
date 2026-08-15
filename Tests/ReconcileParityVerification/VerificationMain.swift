import Foundation
import AgentPulseCore
import AgentPulseReporting
import AgentPulseUsage
import AgentPulseReconcileParity

/// 离线对齐验证工具：证明本地账本聚合与 kaboo `GET /api/usage/reconcile` 逐维度一致。
///
/// 严格只读、绝不上报（不构造任何 POST /ingest）。分两段：
/// 1. 离线自检（永远跑）：mock 数据喂纯函数，验证口径处理与对齐逻辑正确。
/// 2. 实拉（配置齐才跑）：读 reporting.json + env base URL → 取 token → GET → 逐维度对齐。
///    环境未配置时优雅跳过，绝不崩溃。
///
/// 脱敏：只输出字段名、聚合数与 ✓/✗；不输出 token、凭证、会话正文、完整路径。
@main
enum ReconcileParityVerification {
    /// env：kaboo base URL。只从环境变量读，工具不落盘、不碰 UserDefaults。
    private static let baseURLEnvKey = "AGENT_PULSE_RECONCILE_BASE_URL"

    static func main() async throws {
        try await runOfflineSelfCheck()
        print("离线自检通过：口径剔除 cacheCreation、逐维度对齐、脱敏渲染均正确。")
        print("")
        if ProcessInfo.processInfo.environment["AGENT_PULSE_RECONCILE_DEMO"] != nil {
            printDemoTables()
        }
        await runLiveReconcileIfConfigured()
    }

    /// 仅演示：用 mock kaboo 响应渲染 AP vs kaboo 对齐表（一致 + 不一致两例），
    /// 供人工核对报告格式。env AGENT_PULSE_RECONCILE_DEMO 存在时才输出，默认不跑。
    private static func printDemoTables() {
        let buckets = [
            makeBucket(hostname: "mbp-work", model: "sonnet", input: 100, output: 200, cached: 50, cacheCreation: 999, reasoning: 30, startOffset: 0),
            makeBucket(hostname: "mbp-work", model: "opus", input: 10, output: 20, cached: 5, cacheCreation: 40, reasoning: 3, startOffset: 3600),
        ]
        let sessions = [makeSession(hostname: "mbp-work"), makeSession(hostname: "mbp-work"), makeSession(hostname: "mbp-work")]
        let agg = LocalHostnameAggregate.aggregate(hostname: "mbp-work", buckets: buckets, sessions: sessions)
        let first = iso(buckets[0].bucketStart), last = iso(buckets[1].bucketStart)
        // 口径化 total：bucket1 max(0,100+200+50+30)=380，bucket2 max(0,10+20+5+3)=38 → 418。
        let aligned = KabooReconcileResponse.HostnameStats(hostname: "mbp-work", bucketCount: 2, sessionCount: 3, totalTokens: 418, totalCostCents: 137, firstBucketAt: first, lastBucketAt: last, lastSyncedAt: last)
        print("【演示·场景一：口径处理后逐项一致】")
        print(ReconcileReportRenderer.render(ReconcileComparison.compare(local: agg, kaboo: aligned)))
        print("")
        let wrong = KabooReconcileResponse.HostnameStats(hostname: "mbp-work", bucketCount: 2, sessionCount: 3, totalTokens: 1457, totalCostCents: 137, firstBucketAt: first, lastBucketAt: last, lastSyncedAt: last)
        print("【演示·场景二：total 差异（不一致被检出）】")
        print(ReconcileReportRenderer.render(ReconcileComparison.compare(local: agg, kaboo: wrong)))
        print("")
    }

    // MARK: - 离线自检（纯函数，无 I/O）

    private static func runOfflineSelfCheck() async throws {
        try verifyKabooBasisExcludesCacheCreation()
        try verifyAggregateSums()
        try verifyComparisonEqualAndUnequal()
        try verifyMissingHostnameIsUnequal()
        try verifyRendererIsDesensitized()
        try await verifyClientDecodesAndAlignsWithMockTransport()
    }


    /// mock transport 喂一段 kaboo JSON，验证 KabooReconcileClient 能构造 GET、解码、
    /// 并与本地聚合逐维度对齐——覆盖实拉整链（不依赖真实网络 / 配置）。
    private static func verifyClientDecodesAndAlignsWithMockTransport() async throws {
        let buckets = [makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0)]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: [makeSession(hostname: "dev-a")])
        let firstIso = iso(buckets[0].bucketStart)
        // kaboo 原始响应 JSON（无 envelope），口径化后应与本地一致（total=38）。
        let json = """
        {"hostnames":[{"hostname":"dev-a","bucketCount":1,"sessionCount":1,"totalTokens":38,"totalCostCents":12,"firstBucketAt":"\(firstIso)","lastBucketAt":"\(firstIso)","lastSyncedAt":null}]}
        """
        let sender = MockSender(statusCode: 200, body: Data(json.utf8))
        // 用最小合法配置：authToken=X-Jwt-Token，path 合法。
        var config = TokenReportingConfiguration()
        config.path = "/api/usage/reconcile"
        config.headers.authToken = KabooReconcileClient.requiredJWTHeaderName
        let baseURL = URL(string: "https://kaboo.example.com")!
        let client = KabooReconcileClient(sender: sender)
        let response = try await client.fetch(configuration: config, baseURL: baseURL, token: SecretToken("fake-jwt-for-test"))

        // 请求必须是 GET、带 auth header、URL 正确拼接。
        try require(sender.lastRequest?.httpMethod == "GET", "必须构造 GET")
        try require(sender.lastRequest?.value(forHTTPHeaderField: KabooReconcileClient.requiredJWTHeaderName) == "fake-jwt-for-test", "必须带 JWT auth header")
        try require(sender.lastRequest?.url?.absoluteString == "https://kaboo.example.com/api/usage/reconcile", "URL 拼接应正确")

        let comparison = ReconcileComparison.compare(local: agg, kaboo: response.stats(forHostname: "dev-a"))
        try require(comparison.isAligned, "mock 整链：口径处理后应一致")

        // authHeaderNotJWT：header 名不对时应报错、绝不发请求。
        var badConfig = config
        badConfig.headers.authToken = "Authorization"
        do {
            _ = try KabooReconcileClient.makeRequest(configuration: badConfig, baseURL: baseURL, token: SecretToken("x"))
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


    /// kaboo 口径 total 必须排除 cacheCreation，且遵守 max(reportedTotal, 四分量和)。
    private static func verifyKabooBasisExcludesCacheCreation() throws {
        // 四分量和 = 10+20+5+3 = 38；cacheCreation=100 不参与；reportedTotal=0。
        let counts = UsageTokenCounts(
            input: 10, output: 20, cachedInput: 5, cacheCreationInput: 100, reasoningOutput: 3, reportedTotal: 0
        )
        try require(LocalHostnameAggregate.kabooBucketTotal(counts) == 38,
                    "kaboo 口径应为 38（排除 cacheCreation），实际 \(LocalHostnameAggregate.kabooBucketTotal(counts))")
        // 本地 counts.total 含 cacheCreation，应为 138，用于对照证明两口径确实不同。
        try require(counts.total == 138, "本地 counts.total 应含 cacheCreation=138")

        // reportedTotal 更大时取 reportedTotal。
        let reported = UsageTokenCounts(input: 1, output: 1, reportedTotal: 999)
        try require(LocalHostnameAggregate.kabooBucketTotal(reported) == 999,
                    "reportedTotal 更大时应取 999")
    }

    /// 聚合分量小计与 kaboo 口径 total 求和正确，bucketCount/sessionCount 计数正确。
    private static func verifyAggregateSums() throws {
        let buckets = [
            makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0),
            makeBucket(hostname: "dev-a", model: "m2", input: 1, output: 2, cached: 0, cacheCreation: 7, reasoning: 0, startOffset: 3600),
        ]
        let sessions = [makeSession(hostname: "dev-a"), makeSession(hostname: "dev-a")]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: sessions)

        try require(agg.bucketCount == 2, "bucketCount 应为 2")
        try require(agg.sessionCount == 2, "sessionCount 应为 2")
        try require(agg.totalTokensKabooBasis == 38 + 3, "口径 total 应为 41（38+3），实际 \(agg.totalTokensKabooBasis)")
        try require(agg.inputSubtotal == 11, "input 小计应为 11")
        try require(agg.cacheCreationInputSubtotal == 107, "cacheCreation 小计应为 107（AP-only）")
        try require(agg.firstBucketAt == buckets[0].bucketStart, "firstBucketAt 应为最早 bucket")
        try require(agg.lastBucketAt == buckets[1].bucketStart, "lastBucketAt 应为最晚 bucket")
    }

    /// 对齐逻辑：相等判等、差异判不等；authoritative 维度参与判定，其余不判。
    private static func verifyComparisonEqualAndUnequal() throws {
        let buckets = [makeBucket(hostname: "dev-a", model: "m1", input: 10, output: 20, cached: 5, cacheCreation: 100, reasoning: 3, startOffset: 0)]
        let sessions = [makeSession(hostname: "dev-a")]
        let agg = LocalHostnameAggregate.aggregate(hostname: "dev-a", buckets: buckets, sessions: sessions)

        // 完全一致的 kaboo 响应：bucketCount=1, sessionCount=1, totalTokens=38。
        let firstIso = iso(buckets[0].bucketStart)
        let matching = KabooReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 1, totalTokens: 38, totalCostCents: 0,
            firstBucketAt: firstIso, lastBucketAt: firstIso, lastSyncedAt: nil
        )
        let aligned = ReconcileComparison.compare(local: agg, kaboo: matching)
        try require(aligned.isAligned, "口径处理后应完全一致")

        // totalTokens 故意差 1：应判不等。
        let mismatched = KabooReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 1, totalTokens: 39, totalCostCents: 0,
            firstBucketAt: firstIso, lastBucketAt: firstIso, lastSyncedAt: nil
        )
        let notAligned = ReconcileComparison.compare(local: agg, kaboo: mismatched)
        try require(!notAligned.isAligned, "totalTokens 差异应判不一致")

        // advisory / localOnlyDetail 维度 equal 恒为 nil，不参与判定。
        let advisory = notAligned.fields.filter { $0.kind != .authoritative }
        try require(advisory.allSatisfy { $0.equal == nil }, "非权威维度不应带 equal 判定")
    }

    /// kaboo 无该 hostname 时，权威维度记不等、整体不一致。
    private static func verifyMissingHostnameIsUnequal() throws {
        let agg = LocalHostnameAggregate.aggregate(
            hostname: "ghost",
            buckets: [makeBucket(hostname: "ghost", model: "m1", input: 1, output: 1, cached: 0, cacheCreation: 0, reasoning: 0, startOffset: 0)],
            sessions: []
        )
        let comparison = ReconcileComparison.compare(local: agg, kaboo: nil)
        try require(!comparison.kabooPresent, "应标记 kaboo 无此设备")
        try require(!comparison.isAligned, "kaboo 缺该 hostname 应判不一致")
    }

    /// 渲染输出不得包含任何机密样式内容（这里以确定性内容验证脱敏结构）。
    private static func verifyRendererIsDesensitized() throws {
        let agg = LocalHostnameAggregate.aggregate(
            hostname: "dev-a",
            buckets: [makeBucket(hostname: "dev-a", model: "secret-model", input: 1, output: 1, cached: 0, cacheCreation: 0, reasoning: 0, startOffset: 0)],
            sessions: []
        )
        let stats = KabooReconcileResponse.HostnameStats(
            hostname: "dev-a", bucketCount: 1, sessionCount: 0, totalTokens: 2, totalCostCents: 5,
            firstBucketAt: nil, lastBucketAt: nil, lastSyncedAt: nil
        )
        let text = ReconcileReportRenderer.render(ReconcileComparison.compare(local: agg, kaboo: stats))
        // 渲染只含聚合维度名与数字；不含 model 明细（model 不是对齐维度，不进报告）。
        try require(!text.contains("secret-model"), "渲染不应泄露逐 bucket 的 model 明细")
        try require(text.contains("bucketCount"), "渲染应含权威维度名")
    }

    // MARK: - 实拉（配置齐才跑，否则优雅跳过）

    private static func runLiveReconcileIfConfigured() async {
        // 1) reporting.json：缺失 / 权限不安全 → 跳过。
        let configURL = defaultConfigurationURL()
        let configuration: TokenReportingConfiguration
        do {
            configuration = try TokenUsageReporter.loadConfiguration(from: configURL)
        } catch {
            print("跳过实拉：reporting.json 未配置或权限不安全（需 0600）。仅离线对齐逻辑已验证。")
            return
        }

        // 2) authToken header 名必须是 kaboo 认可的 JWT header。
        guard configuration.headers.authToken.caseInsensitiveCompare(KabooReconcileClient.requiredJWTHeaderName) == .orderedSame else {
            print("跳过实拉：reporting.json 的 headers.authToken 需设为 \"\(KabooReconcileClient.requiredJWTHeaderName)\" 才能打通 kaboo。")
            return
        }

        // 3) base URL：仅从环境变量读；缺失 / 无效 → 跳过。
        guard let rawBaseURL = ProcessInfo.processInfo.environment[baseURLEnvKey],
              !rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let baseURL = URL(string: rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              TokenUsageReporter.isValidBaseURL(baseURL) else {
            print("跳过实拉：环境变量 \(baseURLEnvKey) 未配置或不是合法 base URL（生产要求 https）。")
            return
        }

        // 4) hostname 以配置 canonical 为准。
        let hostname = CanonicalHostname.normalize(configuration.canonicalHostname)
        guard !hostname.isEmpty else {
            print("跳过实拉：reporting.json 缺 canonicalHostname。")
            return
        }

        // 5) 取 token（外部进程）；失败 → 跳过，不崩溃。
        let token: SecretToken
        do {
            token = try ConfiguredCommandTokenProvider(configuration: configuration.tokenCommand.providerConfiguration).token()
        } catch {
            print("跳过实拉：本地取 token 失败（凭证命令未配置或返回异常）。")
            return
        }

        // 6) GET reconcile。
        let response: KabooReconcileResponse
        do {
            response = try await KabooReconcileClient().fetch(configuration: configuration, baseURL: baseURL, token: token)
        } catch let error as ReconcileFetchError {
            print("跳过实拉：拉取 kaboo reconcile 失败（\(desensitize(error))）。")
            return
        } catch {
            print("跳过实拉：拉取 kaboo reconcile 失败（网络异常）。")
            return
        }

        // 7) 本地账本聚合。
        guard let ledger = openLedger() else {
            print("跳过实拉：无法打开本地账本。")
            return
        }
        let localBuckets: [UsageBucket]
        let localSessions: [UsageSession]
        do {
            localBuckets = try ledger.buckets(hostname: hostname)
            localSessions = try ledger.sessions(hostname: hostname)
        } catch {
            print("跳过实拉：读取本地账本失败。")
            return
        }
        let aggregate = LocalHostnameAggregate.aggregate(hostname: hostname, buckets: localBuckets, sessions: localSessions)

        // 8) 逐维度对齐 + 渲染。
        let comparison = ReconcileComparison.compare(local: aggregate, kaboo: response.stats(forHostname: hostname))
        print("=== AP vs kaboo 逐维度对齐 ===")
        print(ReconcileReportRenderer.render(comparison))
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
