import Combine
import Foundation

/// 菜单 Token 汇总卡与设置页共用的展示模型。
///
/// 所有计数字段均可为 nil：nil 表示「尚未采集到」，UI 必须展示采集中状态，
/// 不得把 0 当作真实值展示。
struct TokenUsageSummary: Sendable, Equatable {
    /// 全部时间、本机累计的总 Tokens。
    var totalTokens: Int64?
    /// 按内置价格表估算的费用（美元）。
    var estimatedCost: Double?
    /// 命中缓存的输入 Tokens。
    var cachedTokens: Int64?
    /// 非缓存输入 Tokens。
    var newTokens: Int64?
    /// 缓存命中率，区间 0...1。
    var cacheHitRate: Double?

    static let empty = TokenUsageSummary()
}

/// 全量同步的生命周期状态。
enum TokenFullSyncState: String, Sendable, Equatable {
    /// 安全门未通过（原因见 `fullSyncBlockReasons`）。
    case blocked
    /// 可以开始全量同步。
    case ready
    /// 正在上传。
    case running
    /// 本次全量同步完成。
    case completed
    /// 本次全量同步失败。
    case failed
}

/// 本地凭证配置状态
enum TokenConfigurationStatus: String, Sendable, Equatable {
    case ready
    case missing
    case invalid
}

/// 设置页「Token 统计 / 用量上报 / 全量同步」三块的状态快照。
struct TokenSyncStatus: Sendable, Equatable {
    /// 本地长期采集开关（历史会话删除后数据仍保留）。
    var localCollectionEnabled: Bool
    /// 普通上报开关；未配置 API 地址时强制为 false。
    var reportingEnabled: Bool
    /// 上报 API 地址；为空表示仅本地，不发起任何网络请求。
    var ingestBaseURL: String
    /// 本机稳定标识，用于多设备去重；未配置时为 nil。
    var canonicalHostname: String?
    var lastScanAt: Date?
    var lastReportAt: Date?

    /// 本地凭证配置状态
    var configurationStatus: TokenConfigurationStatus
    /// 配置错误详情（不含凭证内容）
    var configurationError: String?
    /// 正在扫描
    var scanningInProgress: Bool
    /// 正在上报
    var reportingInProgress: Bool
    /// 上报错误（脱敏）
    var reportingError: String?
    /// 上报资格门禁：finalizeDerived 判定当前 hostname 是否可安全上报。
    /// 存在无法证明的潜在重复（如继承回放缺完整 total 快照）时为 false。
    var reportingEligible: Bool
    /// 上报被阻止的原因（reportingEligible == false 时给出，脱敏）。
    var reportingBlockedReasons: [String]
    /// 待上报（dirty）bucket 行数。
    var pendingBuckets: Int
    /// 待上报（dirty）session 行数。
    var pendingSessions: Int
    /// 最近一次上报是否完全成功（nil 表示尚未上报过）。
    /// partialFailures 或 pending 非零时为 false，UI 不得显示成功。
    var lastReportSucceeded: Bool?

    var fullSyncState: TokenFullSyncState
    var fullSyncBlockReasons: [String]

    static let localOnly = TokenSyncStatus(
        localCollectionEnabled: true,
        reportingEnabled: false,
        ingestBaseURL: "",
        canonicalHostname: nil,
        lastScanAt: nil,
        lastReportAt: nil,
        configurationStatus: .missing,
        configurationError: "本地凭证未配置",
        scanningInProgress: false,
        reportingInProgress: false,
        reportingError: nil,
        reportingEligible: true,
        reportingBlockedReasons: [],
        pendingBuckets: 0,
        pendingSessions: 0,
        lastReportSucceeded: nil,
        fullSyncState: .blocked,
        fullSyncBlockReasons: ["本地长期账本尚未接入"]
    )
}

/// UI 与采集/上报实现之间的接缝。
///
/// 当前由 `TokenSyncCoordinator` 承担本地扫描和显式开启后的可选普通上报。
/// 配置缺失时不会发起网络请求或外部进程。
@MainActor
protocol TokenSyncCoordinating: AnyObject {
    var summary: TokenUsageSummary { get }
    var status: TokenSyncStatus { get }
    var summaryPublisher: AnyPublisher<TokenUsageSummary, Never> { get }
    var statusPublisher: AnyPublisher<TokenSyncStatus, Never> { get }

    func setLocalCollectionEnabled(_ enabled: Bool)
    func setReportingEnabled(_ enabled: Bool)
    func setIngestBaseURL(_ url: String)
    func setCanonicalHostname(_ hostname: String)
    /// 应用启动入口：完成 scan/report 首轮触发，并启动 30 分钟自动上报循环（仅在
    /// 上报已启用时活跃）。多次调用幂等。
    func start()
    func scanNow()
    func reportNow()
    func runFullSync()
    func stop()
}

/// Token 数字的统一格式化：紧凑计数、货币、百分比。
enum TokenUsageFormatting {
    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        switch abs(value) {
        case 1_000_000_000...:
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return String(value)
        }
    }

    static func cost(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 100 { return String(format: "$%.0f", value) }
        return String(format: "$%.2f", value)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", value * 100)
    }

    static func tps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }
}
