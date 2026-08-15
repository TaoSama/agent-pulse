import Combine
import Foundation
import AgentPulseCore

/// Token 汇总卡可选择的时间窗口。
enum TokenUsageWindow: String, CaseIterable, Identifiable, Sendable {
    case day
    case week
    case month
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .all: return "全部"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .day: return "今日"
        case .week: return "最近 7 天"
        case .month: return "最近 30 天"
        case .all: return "全部时间"
        }
    }
}

/// 单一窗口内某模型的 token 汇总。仅用于展示层的按模型明细与一致性验证，
/// 不落盘、不进入上报 payload。
struct TokenModelUsage: Sendable, Equatable {
    var model: String
    var totalTokens: Int64
}

/// 单一时间窗口的 Token 汇总展示值。
struct TokenUsageWindowSummary: Sendable, Equatable {
    var totalTokens: Int64
    var estimatedCost: Double
    var cachedTokens: Int64
    var newTokens: Int64
    var cacheHitRate: Double?
    /// 按模型明细（仅展示汇总层）。默认空表示未提供分模型拆分。
    var perModel: [TokenModelUsage] = []
}

/// 菜单 Token 汇总卡与设置页共用的四窗口展示模型。
///
/// 窗口值为 nil 表示该窗口尚无派生 bucket 数据；真实的 0 仍按 0 展示。
struct TokenUsageSummary: Sendable, Equatable {
    var day: TokenUsageWindowSummary?
    var week: TokenUsageWindowSummary?
    var month: TokenUsageWindowSummary?
    var all: TokenUsageWindowSummary?

    init(
        day: TokenUsageWindowSummary? = nil,
        week: TokenUsageWindowSummary? = nil,
        month: TokenUsageWindowSummary? = nil,
        all: TokenUsageWindowSummary? = nil
    ) {
        self.day = day
        self.week = week
        self.month = month
        self.all = all
    }

    /// 兼容旧 preview / 调用方：旧单窗口数据继续解释为「全部」。
    init(
        totalTokens: Int64?,
        estimatedCost: Double?,
        cachedTokens: Int64?,
        newTokens: Int64?,
        cacheHitRate: Double?
    ) {
        guard let totalTokens, let estimatedCost, let cachedTokens, let newTokens else {
            self.init()
            return
        }
        self.init(all: TokenUsageWindowSummary(
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            cachedTokens: cachedTokens,
            newTokens: newTokens,
            cacheHitRate: cacheHitRate
        ))
    }

    subscript(window: TokenUsageWindow) -> TokenUsageWindowSummary? {
        switch window {
        case .day: return day
        case .week: return week
        case .month: return month
        case .all: return all
        }
    }

    // 保留旧调用读取全部时间汇总的语义。
    var totalTokens: Int64? { all?.totalTokens }
    var estimatedCost: Double? { all?.estimatedCost }
    var cachedTokens: Int64? { all?.cachedTokens }
    var newTokens: Int64? { all?.newTokens }
    var cacheHitRate: Double? { all?.cacheHitRate }

    static let empty = TokenUsageSummary()
}

/// 本地凭证配置状态
enum TokenConfigurationStatus: String, Sendable, Equatable {
    case ready
    case missing
    case invalid
}

/// 一轮「扫描 → 上报」链路的阶段。用于把整体进度分解为带权重的顺序阶段，
/// 使进度条能跨越 cliproxy 采集、逐文件扫描、派生重算、摘要与可选上报，而不是
/// 卡在某一档跳变。权重之和为 1；scan 是唯一能报出真实细粒度（逐文件）的阶段。
enum TokenScanPhase: String, Sendable, Equatable, CaseIterable {
    /// cliproxy 主动拉取（网络来源）。
    case cliproxy
    /// 逐文件扫描全部来源（占大头，能报 已扫描/总数）。
    case scanning
    /// finalizeDerived 派生重算（全局去重 + 聚合 + 门禁）。
    case finalizing
    /// summaries / pendingCounts 组装。
    case summarizing
    /// 可选普通上报（仅上报已启用且串接时）。
    case reporting

    /// 各阶段占整体进度的权重（和为 1）。冷扫时 scan 最慢、派生次之，
    /// 因此这两档占大头，避免进度在某一档长时间停滞。
    var weight: Double {
        switch self {
        case .cliproxy: return 0.05
        case .scanning: return 0.60
        case .finalizing: return 0.25
        case .summarizing: return 0.05
        case .reporting: return 0.05
        }
    }

    /// 本阶段起点的累计权重（此前所有阶段权重之和）。
    var baseProgress: Double {
        var total = 0.0
        for phase in TokenScanPhase.allCases {
            if phase == self { break }
            total += phase.weight
        }
        return total
    }

    var displayLabel: String {
        switch self {
        case .cliproxy: return "采集用量"
        case .scanning: return "扫描文件"
        case .finalizing: return "重算派生"
        case .summarizing: return "汇总"
        case .reporting: return "上报"
        }
    }

    /// 该阶段计数的单位量词，用于底部详细进度行的「已扫描/总数 单位」。
    var unit: String {
        switch self {
        case .cliproxy: return "事件"
        case .scanning: return "文件"
        case .finalizing: return "行"
        case .summarizing: return "窗口"
        case .reporting: return "行"
        }
    }
}

/// 自动上报间隔档位（本机行为，不进上报身份）。原始值为秒。
enum TokenReportInterval: Int, Sendable, Equatable, CaseIterable, Identifiable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1800
    case sixtyMinutes = 3600

    var id: Int { rawValue }

    /// 秒数（自动循环 Task.sleep 用）。
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        switch self {
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .thirtyMinutes: return "30 分钟"
        case .sixtyMinutes: return "60 分钟"
        }
    }

    /// 从持久化的秒数还原；非法值回落 30 分钟。
    static func from(seconds: Int) -> TokenReportInterval {
        TokenReportInterval(rawValue: seconds) ?? .thirtyMinutes
    }

    static let `default`: TokenReportInterval = .thirtyMinutes
}

/// 权威上报状态：把分散的「能否上报 / 为什么受阻 / 上次结果」收敛成单一结论，
/// 供 UI 顶部一句话说明。语义与优先级见 `TokenSyncStatus.authoritativeReportingState`。
enum ReportingAuthorityState: Equatable, Sendable {
    /// 没配好：配置未就绪 / API 地址空 / hostname 缺失。
    case notConfigured
    /// 配好但被门禁挡（存在无法证明的潜在重复）。
    case blocked
    /// 配置就绪、可开启，但用户未开上报。
    case disabled
    /// 已开、可上报，但有待上报（dirty）行。
    case pending(total: Int)
    /// 已开、可上报，尚未上报过。
    case idle
    /// 上次上报完全成功。
    case reportedOK
    /// 上次上报未完全成功（部分失败 / 仍有 pending）。
    case reportedFailed
}

/// 权威上报状态的展示三元组：标题、可选详情、语义色。
struct ReportingAuthorityPresentation: Equatable, Sendable {
    var state: ReportingAuthorityState
    var title: String
    var detail: String?
    var tone: SettingsStatusTone
}

/// 设置页「Token 统计 / 用量上报」两块的状态快照。
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

    /// cliproxyapi 采集是否已配置（0600 配置文件 + 字段齐全）。
    var cliProxyConfigured: Bool = false
    /// cliproxyapi 采集错误（脱敏）；nil 表示无错误或未配置。
    var cliProxyError: String? = nil

    /// 当前扫描阶段；scanningInProgress == false 时为 nil。仅用于进度展示。
    var scanPhase: TokenScanPhase? = nil
    /// scanning 阶段已处理文件数（仅在 .scanning 阶段有意义）。
    var scannedFiles: Int = 0
    /// scanning 阶段待处理文件总数（先枚举得出；0 表示未知/无文件）。
    var totalFiles: Int = 0
    /// 整体进度 0~1（跨全部阶段带权重累加）；未在扫描时为 nil。
    var scanProgress: Double? = nil

    /// 自动上报间隔（本机行为，不进上报身份）。默认 30 分钟。
    var autoReportInterval: TokenReportInterval = .default

    /// 派生「权威上报状态」：把分散在开关脚注 / 门禁脚注 / 按钮 disabled 三处的受阻语义，
    /// 按固定优先级收敛成单一结论，作为 reportingCard 顶部唯一权威说明。
    ///
    /// 优先级（高→低）：没配好 → 被门禁挡 → 未开 → 有待上报 → 上次结果。
    /// 只读派生，不新增存储字段，也不改变任何上报判定逻辑。
    var authoritativeReportingState: ReportingAuthorityPresentation {
        // 1) 没配好：配置未就绪 / API 地址空 / hostname 缺失。
        if configurationStatus != .ready || ingestBaseURL.isEmpty || canonicalHostname == nil {
            let detail: String
            if configurationStatus != .ready {
                detail = configurationError ?? "本地上报配置未就绪"
            } else if ingestBaseURL.isEmpty {
                detail = "请先配置 API 地址"
            } else {
                detail = "请先配置 hostname"
            }
            return ReportingAuthorityPresentation(
                state: .notConfigured, title: "未配置上报", detail: detail, tone: .warning
            )
        }
        // 2) 配好但被门禁挡。
        if !reportingEligible {
            let detail = reportingBlockedReasons.first ?? "存在无法证明的潜在重复，已阻止上报"
            return ReportingAuthorityPresentation(
                state: .blocked, title: "上报被门禁阻止", detail: detail, tone: .negative
            )
        }
        // 3) 配置就绪但未开启上报。
        if !reportingEnabled {
            return ReportingAuthorityPresentation(
                state: .disabled, title: "上报已关闭", detail: "配置就绪，可随时开启本机上报。", tone: .neutral
            )
        }
        // 4) 上次上报未完全成功（含部分失败 / 仍有 pending）。
        if lastReportSucceeded == false {
            return ReportingAuthorityPresentation(
                state: .reportedFailed, title: "上次上报未完全成功",
                detail: reportingError, tone: .negative
            )
        }
        // 5) 有待上报（dirty）行。
        let pending = pendingBuckets + pendingSessions
        if pending > 0 {
            return ReportingAuthorityPresentation(
                state: .pending(total: pending), title: "有 \(pending) 项待上报",
                detail: "buckets \(pendingBuckets) · sessions \(pendingSessions)", tone: .warning
            )
        }
        // 6) 上次上报成功。
        if lastReportSucceeded == true {
            return ReportingAuthorityPresentation(
                state: .reportedOK, title: "上次上报成功", detail: nil, tone: .positive
            )
        }
        // 7) 已开、可上报、尚未上报过。
        return ReportingAuthorityPresentation(
            state: .idle, title: "已启用，等待首次上报", detail: nil, tone: .neutral
        )
    }

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
        lastReportSucceeded: nil
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
    /// 看板 1 天曲线（账本 30min bucket → 平均 TPS）发布流。
    var dashboardDaySeriesPublisher: AnyPublisher<DashboardDaySeries, Never> { get }

    func setLocalCollectionEnabled(_ enabled: Bool)
    func setReportingEnabled(_ enabled: Bool)
    func setIngestBaseURL(_ url: String)
    func setCanonicalHostname(_ hostname: String)
    /// 设置自动上报间隔（本机行为）：写 defaults + 重启自动循环使新间隔立即生效。
    func setAutoReportInterval(_ interval: TokenReportInterval)
    /// 应用启动入口：完成 scan/report 首轮触发，并启动 30 分钟自动上报循环（仅在
    /// 上报已启用时活跃）。多次调用幂等。
    func start()
    func scanNow()
    func reportNow()
    func stop()
    /// 看板 1 天曲线刷新。active=true 表示看板停在 1 天视图（后续每轮 scan 自动刷新）；
    /// active=false 表示离开 1 天视图（停止自动刷新）。
    func refreshDashboardDaySeries(active: Bool, now: Date)
}

/// Token 数字的统一格式化：紧凑计数、货币、百分比。
enum TokenUsageFormatting {
    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        switch abs(value) {
        case 1_000_000_000...:
            return String(format: "%.2fB", Double(value) / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.2fK", Double(value) / 1_000)
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

    /// 菜单底部详细进度行：「刷新进度：13.0% · 扫描文件 · 376/2831 文件」。
    /// 整体百分比 + 中文阶段名 +（仅 scanning 且 totalFiles>0 时）已扫描/总数 + 单位。
    /// 未在扫描/上报时返回 nil。只读展示聚合数，不含文件路径、会话正文或凭证。
    static func scanDetail(_ status: TokenSyncStatus) -> String? {
        guard status.scanningInProgress || status.reportingInProgress else { return nil }
        let percentText = percent(status.scanProgress)
        guard let phase = status.scanPhase else { return "刷新进度：\(percentText)" }
        if phase == .scanning, status.totalFiles > 0 {
            return "刷新进度：\(percentText) · \(phase.displayLabel) · \(status.scannedFiles)/\(status.totalFiles) \(phase.unit)"
        }
        return "刷新进度：\(percentText) · \(phase.displayLabel)"
    }

    static func tps(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }

    /// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前；更久回落到日期。
    /// now 可注入以便离线验证；不注入则用当前时间。
    static func relativeTime(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 0 { return "刚刚" }
        if elapsed < 60 { return "刚刚" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) 分钟前" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600)) 小时前" }
        if elapsed < 86_400 * 7 { return "\(Int(elapsed / 86_400)) 天前" }
        return relativeDateFormatter.string(from: date)
    }

    private static let relativeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
