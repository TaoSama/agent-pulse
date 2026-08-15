import Foundation
import AgentPulseCore

/// 单个对齐维度的比对结果。
public struct FieldComparison: Sendable, Equatable {
    /// 维度分类：决定该行是否作为「一致性判据」。
    public enum Kind: Sendable, Equatable {
        /// 应逐项相等，参与一致性判定。
        case authoritative
        /// 仅本地侧明细，kaboo per-hostname 不返回；作解释证据，不判定。
        case localOnlyDetail
        /// 口径不同，仅参考，不判定（如 cost、cacheCreation）。
        case advisory
    }

    public var field: String
    public var localValue: String
    public var kabooValue: String
    public var kind: Kind
    /// 仅当 kind == .authoritative 时有意义：true = 相等。其余维度恒为 nil。
    public var equal: Bool?

    public init(field: String, localValue: String, kabooValue: String, kind: Kind, equal: Bool?) {
        self.field = field
        self.localValue = localValue
        self.kabooValue = kabooValue
        self.kind = kind
        self.equal = equal
    }
}

/// 单个 hostname 的对齐结论。
public struct HostnameComparison: Sendable, Equatable {
    public var hostname: String
    /// kaboo 是否返回了该 hostname（false 表示服务端无此设备数据）。
    public var kabooPresent: Bool
    public var fields: [FieldComparison]

    public init(hostname: String, kabooPresent: Bool, fields: [FieldComparison]) {
        self.hostname = hostname
        self.kabooPresent = kabooPresent
        self.fields = fields
    }

    /// 全部 authoritative 维度都相等，且 kaboo 存在该 hostname。
    public var isAligned: Bool {
        kabooPresent && fields.allSatisfy { $0.equal ?? true }
    }
}

/// 把本地聚合与 kaboo 响应逐维度对齐。纯函数，无任何 I/O，离线可 mock 验证。
public enum ReconcileComparison {
    /// 对齐单个 hostname。kaboo 侧缺该 hostname 时，authoritative 维度全部记为不等。
    public static func compare(
        local: LocalHostnameAggregate,
        kaboo: KabooReconcileResponse.HostnameStats?
    ) -> HostnameComparison {
        var fields: [FieldComparison] = []

        // 1) bucketCount — 应逐项相等。
        fields.append(authoritative(
            field: "bucketCount",
            local: Int64(local.bucketCount),
            kaboo: kaboo.map { Int64($0.bucketCount) }
        ))
        // 2) sessionCount — 应逐项相等。
        fields.append(authoritative(
            field: "sessionCount",
            local: Int64(local.sessionCount),
            kaboo: kaboo.map { Int64($0.sessionCount) }
        ))
        // 3) totalTokens（唯一口径,五项含 cacheCreation）。
        //    kaboo 的 total_tokens 漏计 cacheCreation,故直接比会差一个 cacheCreation;
        //    这里按「kaboo 应回值 = 本地 total − cacheCreation」判定,差值如实归因给 kaboo 漏计。
        let kabooExpected = LocalHostnameAggregate.kabooBasisFromTotal(
            local.totalTokens, cacheCreation: local.cacheCreationInputSubtotal
        )
        if let kaboo {
            let matchesKabooBasis = kaboo.totalTokens == kabooExpected
            let matchesFullTotal = kaboo.totalTokens == local.totalTokens
            let equal = matchesKabooBasis || matchesFullTotal
            let note: String
            if matchesFullTotal {
                note = "（含 cacheCreation,两侧完全一致）"
            } else if matchesKabooBasis {
                note = "（差值=cacheCreation \(local.cacheCreationInputSubtotal),系 kaboo total 漏计,已解释）"
            } else {
                note = "（差异无法用 cacheCreation 解释）"
            }
            fields.append(FieldComparison(
                field: "totalTokens",
                localValue: "\(local.totalTokens)",
                kabooValue: "\(kaboo.totalTokens) \(note)",
                kind: .authoritative,
                equal: equal
            ))
        } else {
            fields.append(FieldComparison(
                field: "totalTokens",
                localValue: "\(local.totalTokens)",
                kabooValue: "—（kaboo 无此设备）",
                kind: .authoritative,
                equal: false
            ))
        }
        // 4) 时间边界 — 秒级相等。
        fields.append(timeField(
            field: "firstBucketAt",
            local: local.firstBucketAt,
            kabooRaw: kaboo?.firstBucketAt
        ))
        fields.append(timeField(
            field: "lastBucketAt",
            local: local.lastBucketAt,
            kabooRaw: kaboo?.lastBucketAt
        ))

        // 5) 分量小计 — 本地明细，kaboo per-hostname 不回分量，作解释证据。
        for (name, value) in [
            ("input", local.inputSubtotal),
            ("output", local.outputSubtotal),
            ("cachedInput", local.cachedInputSubtotal),
            ("reasoningOutput", local.reasoningOutputSubtotal),
        ] {
            fields.append(FieldComparison(
                field: "小计.\(name)",
                localValue: String(value),
                kabooValue: "—（接口不返回分量）",
                kind: .localOnlyDetail,
                equal: nil
            ))
        }

        // 6) cacheCreation — 计入本地唯一 total;正是 kaboo total 漏计的那部分。
        fields.append(FieldComparison(
            field: "cacheCreationInput",
            localValue: String(local.cacheCreationInputSubtotal),
            kabooValue: "—（kaboo total 漏计此项,为两侧 total 差值来源）",
            kind: .advisory,
            equal: nil
        ))

        // 7) cost — 口径不同，仅参考。
        fields.append(FieldComparison(
            field: "cost(口径不同,仅参考)",
            localValue: "本地按 USD 估算",
            kabooValue: kaboo.map { "\($0.totalCostCents) cents" } ?? "—",
            kind: .advisory,
            equal: nil
        ))

        return HostnameComparison(
            hostname: local.hostname,
            kabooPresent: kaboo != nil,
            fields: fields
        )
    }

    private static func authoritative(field: String, local: Int64, kaboo: Int64?) -> FieldComparison {
        FieldComparison(
            field: field,
            localValue: String(local),
            kabooValue: kaboo.map(String.init) ?? "—（kaboo 无此设备）",
            kind: .authoritative,
            equal: kaboo.map { $0 == local } ?? false
        )
    }

    /// 时间维度：两侧都归一到整秒 epoch 后比较，容忍纳秒/时区表述差异。
    /// 两侧都缺（nil）视为相等；仅一侧缺视为不等。
    private static func timeField(field: String, local: Date?, kabooRaw: String?) -> FieldComparison {
        let kabooDate = kabooRaw.flatMap { UsageTimestamp.parse($0) }
        let localSecond = local.map { Int64($0.timeIntervalSince1970.rounded(.towardZero)) }
        let kabooSecond = kabooDate.map { Int64($0.timeIntervalSince1970.rounded(.towardZero)) }
        let equal = localSecond == kabooSecond
        return FieldComparison(
            field: field,
            localValue: describe(local),
            kabooValue: kabooRaw.map { _ in describe(kabooDate) } ?? "—",
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
