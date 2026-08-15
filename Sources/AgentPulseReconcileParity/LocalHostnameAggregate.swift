import Foundation
import AgentPulseCore

/// 从本地账本 bucket / session 明细聚合出「与 上游 per-hostname 口径对齐」的统计。
///
/// 纯值类型 + 纯静态函数，不含任何 I/O，因此离线可用 mock 数据完整验证聚合与口径逻辑。
///
/// 口径对齐要点（否则永远对不上）：
/// - **totalTokens 用 上游 口径**：每个 bucket 取 `max(reportedTotal, input+output+cached+reasoning)`，
///   **不含 cacheCreation**，再求和。本地 `UsageTokenCounts.total` 会把 cacheCreation 计入求和分支，
///   与 上游 不同，故这里单独实现，绝不复用 `counts.total`。
/// - cacheCreation 单独统计为 AP-only 小计，标记「不参与 total 对齐」。
/// - cost 不在此计算，AP 与 上游 各自独立实现，不作一致性判据。
public struct LocalHostnameAggregate: Sendable, Equatable {
    public var hostname: String
    /// distinct bucket 行数（本地 bucket 已按自然键去重，直接计数即可）。
    public var bucketCount: Int
    /// distinct session 行数。
    public var sessionCount: Int
    /// 上游 口径 total 之和（排除 cacheCreation）。
    public var totalTokensUpstreamBasis: Int64
    /// 分量小计，用于对齐时解释 total 差异（上游 per-hostname 不回分量）。
    public var inputSubtotal: Int64
    public var outputSubtotal: Int64
    public var cachedInputSubtotal: Int64
    public var reasoningOutputSubtotal: Int64
    /// AP-only：cacheCreation 小计，不参与 total 对齐，仅展示。
    public var cacheCreationInputSubtotal: Int64
    /// 最早 / 最晚 bucketStart，用于时间边界对齐（秒级）。nil 表示无 bucket。
    public var firstBucketAt: Date?
    public var lastBucketAt: Date?

    public init(
        hostname: String,
        bucketCount: Int,
        sessionCount: Int,
        totalTokensUpstreamBasis: Int64,
        inputSubtotal: Int64,
        outputSubtotal: Int64,
        cachedInputSubtotal: Int64,
        reasoningOutputSubtotal: Int64,
        cacheCreationInputSubtotal: Int64,
        firstBucketAt: Date?,
        lastBucketAt: Date?
    ) {
        self.hostname = hostname
        self.bucketCount = bucketCount
        self.sessionCount = sessionCount
        self.totalTokensUpstreamBasis = totalTokensUpstreamBasis
        self.inputSubtotal = inputSubtotal
        self.outputSubtotal = outputSubtotal
        self.cachedInputSubtotal = cachedInputSubtotal
        self.reasoningOutputSubtotal = reasoningOutputSubtotal
        self.cacheCreationInputSubtotal = cacheCreationInputSubtotal
        self.firstBucketAt = firstBucketAt
        self.lastBucketAt = lastBucketAt
    }

    /// 单个 bucket 的 上游 口径 total：`max(reportedTotal, input+output+cachedInput+reasoningOutput)`，
    /// **排除 cacheCreationInput**，与 上游 ingest GREATEST 语义逐字对齐。
    public static func 上游BucketTotal(_ counts: UsageTokenCounts) -> Int64 {
        let derived = counts.input &+ counts.output &+ counts.cachedInput &+ counts.reasoningOutput
        return max(counts.reportedTotal, derived)
    }

    /// 从本地 bucket / session 明细聚合。buckets/sessions 应已是同一 hostname 的全量明细。
    /// 饱和加法防溢出，行为与账本一致。
    public static func aggregate(
        hostname: String,
        buckets: [UsageBucket],
        sessions: [UsageSession]
    ) -> LocalHostnameAggregate {
        var total: Int64 = 0
        var input: Int64 = 0
        var output: Int64 = 0
        var cached: Int64 = 0
        var reasoning: Int64 = 0
        var cacheCreation: Int64 = 0
        var first: Date?
        var last: Date?

        for bucket in buckets {
            total = saturatedAdd(total, 上游BucketTotal(bucket.counts))
            input = saturatedAdd(input, bucket.counts.input)
            output = saturatedAdd(output, bucket.counts.output)
            cached = saturatedAdd(cached, bucket.counts.cachedInput)
            reasoning = saturatedAdd(reasoning, bucket.counts.reasoningOutput)
            cacheCreation = saturatedAdd(cacheCreation, bucket.counts.cacheCreationInput)
            if first == nil || bucket.bucketStart < first! { first = bucket.bucketStart }
            if last == nil || bucket.bucketStart > last! { last = bucket.bucketStart }
        }

        return LocalHostnameAggregate(
            hostname: hostname,
            bucketCount: buckets.count,
            sessionCount: sessions.count,
            totalTokensUpstreamBasis: total,
            inputSubtotal: input,
            outputSubtotal: output,
            cachedInputSubtotal: cached,
            reasoningOutputSubtotal: reasoning,
            cacheCreationInputSubtotal: cacheCreation,
            firstBucketAt: first,
            lastBucketAt: last
        )
    }

    /// 饱和加法：溢出时钳到 Int64.max，绝不回绕成负数污染聚合。
    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
