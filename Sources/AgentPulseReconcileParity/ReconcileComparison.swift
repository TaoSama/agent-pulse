import Foundation
import AgentPulseCore

/// 单个对齐维度的比对结果。
public struct FieldComparison: Sendable, Equatable {
    /// 维度分类：决定该行是否作为「一致性判据」。
    public enum Kind: Sendable, Equatable {
        /// 应逐项相等，参与一致性判定。
        case authoritative
        /// 仅本地侧明细，上游 per-hostname 不返回；作解释证据，不判定。
        case localOnlyDetail
        /// 口径不同，仅参考，不判定（如 cost、cacheCreation）。
        case advisory
    }

    public var field: String
    public var localValue: String
    public var 上游Value: String
    public var kind: Kind
    /// 仅当 kind == .authoritative 时有意义：true = 相等。其余维度恒为 nil。
    public var equal: Bool?

    public init(field: String, localValue: String, 上游Value: String, kind: Kind, equal: Bool?) {
        self.field = field
        self.localValue = localValue
        self.上游Value = 上游Value
        self.kind = kind
        self.equal = equal
    }
}

/// 单个 hostname 的对齐结论。
public struct HostnameComparison: Sendable, Equatable {
    public var hostname: String
    /// 上游 是否返回了该 hostname（false 表示服务端无此设备数据）。
    public var 上游Present: Bool
    public var fields: [FieldComparison]

    public init(hostname: String, 上游Present: Bool, fields: [FieldComparison]) {
        self.hostname = hostname
        self.上游Present = 上游Present
        self.fields = fields
    }

    /// 全部 authoritative 维度都相等，且 上游 存在该 hostname。
    public var isAligned: Bool {
        上游Present && fields.allSatisfy { $0.equal ?? true }
    }
}

/// 把本地聚合与 上游 响应逐维度对齐。纯函数，无任何 I/O，离线可 mock 验证。
public enum ReconcileComparison {
    /// 对齐单个 hostname。上游 侧缺该 hostname 时，authoritative 维度全部记为不等。
    public static func compare(
        local: LocalHostnameAggregate,
        上游: ReconcileResponse.HostnameStats?
    ) -> HostnameComparison {
        var fields: [FieldComparison] = []

        // 1) bucketCount — 应逐项相等。
        fields.append(authoritative(
            field: "bucketCount",
            local: Int64(local.bucketCount),
            上游: 上游.map { Int64($0.bucketCount) }
        ))
        // 2) sessionCount — 应逐项相等。
        fields.append(authoritative(
            field: "sessionCount",
            local: Int64(local.sessionCount),
            上游: 上游.map { Int64($0.sessionCount) }
        ))
        // 3) totalTokens（唯一口径,五项含 cacheCreation）。
        //    上游 的 total_tokens 漏计 cacheCreation,故直接比会差一个 cacheCreation;
        //    这里按「上游 应回值 = 本地 total − cacheCreation」判定,差值如实归因给 上游 漏计。
        let 上游Expected = LocalHostnameAggregate.上游BasisFromTotal(
            local.totalTokens, cacheCreation: local.cacheCreationInputSubtotal
        )
        if let 上游 {
            let matchesUpstreamBasis = 上游.totalTokens == 上游Expected
            let matchesFullTotal = 上游.totalTokens == local.totalTokens
            let equal = matchesUpstreamBasis || matchesFullTotal
            let note: String
            if matchesFullTotal {
                note = "（含 cacheCreation,两侧完全一致）"
            } else if matchesUpstreamBasis {
                note = "（差值=cacheCreation \(local.cacheCreationInputSubtotal),系 上游 total 漏计,已解释）"
            } else {
                note = "（差异无法用 cacheCreation 解释）"
            }
            fields.append(FieldComparison(
                field: "totalTokens",
                localValue: "\(local.totalTokens)",
                上游Value: "\(上游.totalTokens) \(note)",
                kind: .authoritative,
                equal: equal
            ))
        } else {
            fields.append(FieldComparison(
                field: "totalTokens",
                localValue: "\(local.totalTokens)",
                上游Value: "—（上游 无此设备）",
                kind: .authoritative,
                equal: false
            ))
        }
        // 4) 时间边界 — 秒级相等。
        fields.append(timeField(
            field: "firstBucketAt",
            local: local.firstBucketAt,
            上游Raw: 上游?.firstBucketAt
        ))
        fields.append(timeField(
            field: "lastBucketAt",
            local: local.lastBucketAt,
            上游Raw: 上游?.lastBucketAt
        ))

        // 5) 分量小计 — 本地明细，上游 per-hostname 不回分量，作解释证据。
        for (name, value) in [
            ("input", local.inputSubtotal),
            ("output", local.outputSubtotal),
            ("cachedInput", local.cachedInputSubtotal),
            ("reasoningOutput", local.reasoningOutputSubtotal),
        ] {
            fields.append(FieldComparison(
                field: "小计.\(name)",
                localValue: String(value),
                上游Value: "—（接口不返回分量）",
                kind: .localOnlyDetail,
                equal: nil
            ))
        }

        // 6) cacheCreation — 计入本地唯一 total;正是 上游 total 漏计的那部分。
        fields.append(FieldComparison(
            field: "cacheCreationInput",
            localValue: String(local.cacheCreationInputSubtotal),
            上游Value: "—（上游 total 漏计此项,为两侧 total 差值来源）",
            kind: .advisory,
            equal: nil
        ))

        // 7) cost — 口径不同，仅参考。
        fields.append(FieldComparison(
            field: "cost(口径不同,仅参考)",
            localValue: "本地按 USD 估算",
            上游Value: 上游.map { "\($0.totalCostCents) cents" } ?? "—",
            kind: .advisory,
            equal: nil
        ))

        return HostnameComparison(
            hostname: local.hostname,
            上游Present: 上游 != nil,
            fields: fields
        )
    }

    private static func authoritative(field: String, local: Int64, 上游: Int64?) -> FieldComparison {
        FieldComparison(
            field: field,
            localValue: String(local),
            上游Value: 上游.map(String.init) ?? "—（上游 无此设备）",
            kind: .authoritative,
            equal: 上游.map { $0 == local } ?? false
        )
    }

    /// 时间维度：两侧都归一到整秒 epoch 后比较，容忍纳秒/时区表述差异。
    /// 两侧都缺（nil）视为相等；仅一侧缺视为不等。
    private static func timeField(field: String, local: Date?, 上游Raw: String?) -> FieldComparison {
        let 上游Date = 上游Raw.flatMap { UsageTimestamp.parse($0) }
        let localSecond = local.map { Int64($0.timeIntervalSince1970.rounded(.towardZero)) }
        let 上游Second = 上游Date.map { Int64($0.timeIntervalSince1970.rounded(.towardZero)) }
        let equal = localSecond == 上游Second
        return FieldComparison(
            field: field,
            localValue: describe(local),
            上游Value: 上游Raw.map { _ in describe(上游Date) } ?? "—",
            kind: .authoritative,
            equal: equal
        )
    }

    private static func describe(_ date: Date?) -> String {
        guard let date else { return "—" }
        return isoFormatter.string(from: date)
    }

    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
