import Foundation
import AgentPulseCore

/// 从本地账本 bucket / session 明细聚合出用于与上游 per-hostname 对齐的统计。
///
/// 纯值类型 + 纯静态函数,不含任何 I/O,因此离线可用 mock 数据完整验证聚合逻辑。
///
/// **唯一 total 口径**:各来源(Codex/OpenAI、Claude/Anthropic、cliproxy)在 parser 层
/// 已把 input/cachedInput/cacheCreationInput/reasoningOutput 归一为**互斥**分量
/// (OpenAI 口径的 input 已减掉 cached+creation;Anthropic 口径三者天生互斥)。因此
/// `total = input+output+cachedInput+cacheCreationInput+reasoningOutput` 相加**不重复**,
/// cacheCreation 本就是总量的一部分。这里直接用 `UsageTokenCounts.total`,不另造第二口径。
///
/// 与上游的差异:上游的 total_tokens 少算了 cacheCreation(只用四项),属上游侧
/// 口径缺陷。对齐时把差值如实归因,而不是在本地迁就一个"上游口径 total"。
/// cost 不在此计算,AP 与上游各自独立实现,不作一致性判据。
public struct LocalHostnameAggregate: Sendable, Equatable {
    public var hostname: String
    /// distinct bucket 行数(本地 bucket 已按自然键去重,直接计数即可)。
    public var bucketCount: Int
    /// distinct session 行数。
    public var sessionCount: Int
    /// 唯一 total:五分量互斥之和(含 cacheCreation)。
    public var totalTokens: Int64
    /// 分量小计,用于对齐时解释 total 差异(上游 per-hostname 不回分量)。
    public var inputSubtotal: Int64
    public var outputSubtotal: Int64
    public var cachedInputSubtotal: Int64
    public var reasoningOutputSubtotal: Int64
    /// cacheCreation 小计:上游的 total 漏计了这部分,正是两侧 total 差值的来源。
    public var cacheCreationInputSubtotal: Int64
    /// 最早 / 最晚 bucketStart,用于时间边界对齐(秒级)。nil 表示无 bucket。
    public var firstBucketAt: Date?
    public var lastBucketAt: Date?

    public init(
        hostname: String,
        bucketCount: Int,
        sessionCount: Int,
        totalTokens: Int64,
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
        self.totalTokens = totalTokens
        self.inputSubtotal = inputSubtotal
        self.outputSubtotal = outputSubtotal
        self.cachedInputSubtotal = cachedInputSubtotal
        self.reasoningOutputSubtotal = reasoningOutputSubtotal
        self.cacheCreationInputSubtotal = cacheCreationInputSubtotal
        self.firstBucketAt = firstBucketAt
        self.lastBucketAt = lastBucketAt
    }

    /// 上游 total_tokens 的口径:四项(input+output+cached+reasoning),**漏计 cacheCreation**。
    /// 仅用于对齐时"从唯一 total 推出上游应回的值"以解释差值,不作为本地 total。
    public static func upstreamBasisFromTotal(_ total: Int64, cacheCreation: Int64) -> Int64 {
        max(0, total - cacheCreation)
    }

    /// 从本地 bucket / session 明细聚合。buckets/sessions 应已是同一 hostname 的全量明细。
    /// 饱和加法防溢出,行为与账本一致。total 用每个 bucket 的唯一 `counts.total`。
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
            total = saturatedAdd(total, bucket.counts.total)
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
            totalTokens: total,
            inputSubtotal: input,
            outputSubtotal: output,
            cachedInputSubtotal: cached,
            reasoningOutputSubtotal: reasoning,
            cacheCreationInputSubtotal: cacheCreation,
            firstBucketAt: first,
            lastBucketAt: last
        )
    }

    /// 饱和加法:溢出时钳到 Int64.max,绝不回绕成负数污染聚合。
    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
