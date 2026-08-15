import Foundation

/// kaboo `GET /api/usage/reconcile` 响应模型。
///
/// 只映射对齐所需的 `hostnames[]` per-hostname 明细；服务端的 `overlaps` 与顶层
/// 汇总字段不参与本地对齐（overlaps 是跨设备去重的服务端视角，与单设备账本无关）。
/// 服务端直接序列化结构体、无 `{code,data,msg}` 包裹，故顶层即为本结构。
public struct KabooReconcileResponse: Decodable, Sendable, Equatable {
    public var hostnames: [HostnameStats]

    public init(hostnames: [HostnameStats]) {
        self.hostnames = hostnames
    }

    /// 缺失 `hostnames` 视为空数组（无该 user 数据），不解码失败。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostnames = try container.decodeIfPresent([HostnameStats].self, forKey: .hostnames) ?? []
    }

    private enum CodingKeys: String, CodingKey { case hostnames }

    /// per-hostname 聚合统计。时间字段以字符串保留（RFC3339，可能带纳秒或为 null），
    /// 对齐时再用 `UsageTimestamp` 归一到秒，避免纳秒/时区表述差异造成假不等。
    public struct HostnameStats: Decodable, Sendable, Equatable {
        public var hostname: String
        public var bucketCount: Int
        public var sessionCount: Int
        public var totalTokens: Int64
        public var totalCostCents: Int64
        public var firstBucketAt: String?
        public var lastBucketAt: String?
        public var lastSyncedAt: String?

        public init(
            hostname: String,
            bucketCount: Int,
            sessionCount: Int,
            totalTokens: Int64,
            totalCostCents: Int64,
            firstBucketAt: String? = nil,
            lastBucketAt: String? = nil,
            lastSyncedAt: String? = nil
        ) {
            self.hostname = hostname
            self.bucketCount = bucketCount
            self.sessionCount = sessionCount
            self.totalTokens = totalTokens
            self.totalCostCents = totalCostCents
            self.firstBucketAt = firstBucketAt
            self.lastBucketAt = lastBucketAt
            self.lastSyncedAt = lastSyncedAt
        }
    }

    /// 按 hostname 查找（大小写与两端空白不敏感由调用方在归一后保证；此处精确匹配）。
    public func stats(forHostname hostname: String) -> HostnameStats? {
        hostnames.first { $0.hostname == hostname }
    }
}
