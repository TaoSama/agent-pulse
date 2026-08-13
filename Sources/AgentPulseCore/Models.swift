import Foundation

// AgentPulseCore 公共模型。
// 描述 Codex Desktop/CLI 的运行状态、错误降级信息以及 tokens-per-second（TPS）指标。
// 目标：Swift 6 严格并发下可安全跨隔离域传递（Sendable），可持久化（Codable），可比较（Equatable）。

/// 被观测的 Codex 运行时来源。
public enum PulseSource: String, Codable, Sendable, Equatable, CaseIterable {
    /// Codex 桌面应用。
    case desktop
    /// Codex 命令行。
    case cli
}

/// 运行时的生命周期状态。
///
/// 采集失败时不应吞掉错误，而是返回 `.degraded`（携带原因）或 `.unknown`，
/// 使上层可以区分“确实空闲”与“采集不到数据”。
/// 以 `String` 为 raw value，便于 SQLite `status TEXT` 列直接映射。
public enum PulseStatus: String, Codable, Sendable, Equatable, CaseIterable {
    /// 进程未运行（确认为未运行，而非采集失败）。
    case notRunning
    /// 进程在运行但当前无活跃生成任务。
    case idle
    /// 正在生成 tokens。
    case generating
    /// 采集部分失败，数据可能不完整；`degradedReason` 应说明原因。
    case degraded
    /// 无法确定状态（例如采集完全失败且无法回退）。
    case unknown
}

/// 采集过程中发生的、需要显式暴露给上层的错误类别。
///
/// 采集器捕获底层错误后必须映射为稳定、可测试的类别，禁止空 catch 或静默吞错。
public enum PulseCollectionError: Error, Codable, Sendable, Equatable {
    /// 找不到目标进程可执行文件或进程句柄。
    case processNotFound
    /// 需要读取的文件/目录不存在。
    case dataSourceMissing(path: String)
    /// 读取被操作系统或权限策略拒绝。
    case permissionDenied(path: String)
    /// 数据源存在但内容无法解析。
    case parseFailed(reason: String)
    /// 采集超时。
    case timedOut
    /// 其他已知但未细分的失败；`detail` 为脱敏后的说明，不得包含敏感数据。
    case other(detail: String)
}

extension PulseCollectionError: CustomStringConvertible {
    /// 稳定、脱敏、可持久化为单个 TEXT 列（`note`）的错误描述。
    /// 只包含类别与非敏感细节（如路径/原因文本），不包含凭证或用户数据。
    public var description: String {
        switch self {
        case .processNotFound:
            return "processNotFound"
        case let .dataSourceMissing(path):
            return "dataSourceMissing: \(path)"
        case let .permissionDenied(path):
            return "permissionDenied: \(path)"
        case let .parseFailed(reason):
            return "parseFailed: \(reason)"
        case .timedOut:
            return "timedOut"
        case let .other(detail):
            return "other: \(detail)"
        }
    }

    /// 与 `description` 一致的错误描述，供上层记录到 `note` 列。
    public var errorDescription: String { description }
}

/// 快照中某项聚合指标的数据质量。
///
/// 底层数据源可靠性不一时，必须显式区分“确实是这个值”“只覆盖了部分来源”“完全取不到”，
/// 禁止用 0 或 nil 混淆“真实为 0”与“采集不到”。
public enum PulseDataQuality: String, Codable, Sendable, Equatable, CaseIterable {
    /// 数据完整且可信。
    case complete
    /// 只覆盖了部分来源/记录，值可能偏低。
    case partial
    /// 无法采集该指标。
    case unavailable
}

/// 计数的统计范围。
///
/// 数据源接口（如 Desktop \`list_threads\`）存在窗口上限且无分页，
/// “当前窗口计数”不能等同于“全量本地精确值”，必须显式区分以免误导。
public enum PulseScope: String, Codable, Sendable, Equatable, CaseIterable {
    /// 仅覆盖当前可见窗口（例如接口 limit 内的任务）。
    case currentWindow
    /// 覆盖全部本地记录。
    case allLocal
}

/// 单次进程测量的轻量描述，用于把采集到的原始进程信息带入快照。
public struct PulseProcessInfo: Codable, Sendable, Equatable {
    /// 进程 ID。
    public let pid: Int32
    /// 可执行文件名或命令名（不含完整路径，避免泄漏用户目录）。
    public let executableName: String
    /// 进程占用的常驻内存字节数（若采集不到则为 nil）。
    public let residentMemoryBytes: UInt64?
    /// 进程 CPU 占用百分比（0...N，可超过 100 表示多核；采集不到则为 nil）。
    public let cpuUsagePercent: Double?

    public init(
        pid: Int32,
        executableName: String,
        residentMemoryBytes: UInt64? = nil,
        cpuUsagePercent: Double? = nil
    ) {
        self.pid = pid
        self.executableName = executableName
        self.residentMemoryBytes = residentMemoryBytes
        self.cpuUsagePercent = cpuUsagePercent
    }
}

/// 一条 tokens-per-second 采样。
///
/// 表示在 `timestamp` 结束的一小段生成活动：新增 `tokenCount` 个 token，
/// 覆盖 `durationSeconds` 的时间跨度。TPS 由窗口聚合计算，单条采样不直接携带速率，
/// 以避免除零和单点抖动。
public struct TPSSample: Codable, Sendable, Equatable {
    /// 采样时刻（该段活动的结束时间）。
    public let timestamp: Date
    /// 本段新增的 token 数（必须为非负）。
    public let tokenCount: Int
    /// 本段覆盖的时间跨度秒数（必须为非负；为 0 表示瞬时增量）。
    /// 运行时 TPS 始终使用固定 180 秒分母，本字段只用于区间重叠线性摊分。
    public let durationSeconds: Double
    /// 采样来源。
    public let source: PulseSource
    /// 产生该段 token 的模型标识；无法确定时为 nil。
    public let model: String?

    public init(
        timestamp: Date,
        tokenCount: Int,
        durationSeconds: Double,
        source: PulseSource,
        model: String? = nil
    ) {
        self.timestamp = timestamp
        self.tokenCount = tokenCount
        self.durationSeconds = durationSeconds
        self.source = source
        self.model = model
    }

    /// 采样是否有效：token 非负且时间跨度非负且为有限值。
    /// 无效采样应被窗口拒绝而不是崩溃或静默计入。
    public var isValid: Bool {
        tokenCount >= 0 && durationSeconds >= 0 && durationSeconds.isFinite
    }
}

/// 某一来源在某一时刻的完整状态快照，可持久化并按时间范围查询。
///
/// 字段布局刻意保持“扁平”，以便 SQLite 逐列映射：
/// - `id`         → `id TEXT`（UUID 字符串，主键）
/// - `timestamp`  → `timestamp`（Date，建议存 epoch 秒或 ISO8601）
/// - `source`     → `source TEXT`（`PulseSource.rawValue`）
/// - `status`     → `status TEXT`（`PulseStatus.rawValue`）
/// - `tps`        → `tps REAL NULL`
/// - `tokenCount` → `tokenCount INTEGER NULL`
/// - `note`       → `note TEXT NULL`（人类可读备注或降级错误描述）
///
/// 富领域信息（进程详情、结构化错误）保留在可选字段中；`degradedReason`
/// 与 `note` 保持同步（有降级错误时 `note` 至少包含其 `errorDescription`），
/// 使 SQLite 侧即便只落 7 个基础列也不丢失关键降级信息。
public struct PulseSnapshot: Codable, Sendable, Equatable, Identifiable {
    /// 稳定唯一标识（主键）。
    public let id: UUID
    /// 快照采集时刻。
    public let timestamp: Date
    /// 快照来源。
    public let source: PulseSource
    /// 运行时状态。
    public let status: PulseStatus
    /// 观测窗口内的即时 TPS（tokens/second）；无法计算时为 nil（例如无有效采样）。
    public let tps: Double?
    /// 累计生成的 token 总数（采集不到则为 nil）。
    public let tokenCount: Int?
    /// 所有已完成顶层 Task/turn 的去重总数（全量累计，非“今日”）。
    ///
    /// 统计口径：跨会话去重后的已完成顶层任务总量；必须过滤掉 cwd 位于任何
    /// automations 目录/项目下的记录。底层数据不可靠时该值可能为 nil，
    /// 具体可信度由 `completedCountQuality` 表达。
    public let completedTaskCount: Int?
    /// `completedTaskCount` 的数据质量：complete/partial/unavailable。
    /// unavailable 时 `completedTaskCount` 应为 nil；partial 表示只覆盖了部分来源。
    public let completedCountQuality: PulseDataQuality
    /// `completedTaskCount` 的统计范围：当前窗口 vs 全量本地。
    /// 默认 `.currentWindow`，因为主要数据源存在窗口上限、无法证明全量精确。
    public let completedScope: PulseScope
    /// `completedTaskCount` 是否只是下界（“至少 N 个”）。
    /// 当受窗口上限或部分来源影响、真实值可能更大时应为 true。
    public let completedIsLowerBound: Bool
    /// 快照是否为陈旧值（例如某些 host/source 不可用时保留上一次值）。
    /// stale 数据不得被当作实时精确值。
    public let isStale: Bool
    /// 人类可读备注；降级/未知状态下至少包含 `degradedReason.errorDescription`。
    public let note: String?
    /// 被观测进程信息（未运行或采集失败时为 nil）。
    public let process: PulseProcessInfo?
    /// 当状态为 `.degraded` 或 `.unknown` 时的结构化失败原因；正常状态下为 nil。
    public let degradedReason: PulseCollectionError?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        source: PulseSource,
        status: PulseStatus,
        tps: Double? = nil,
        tokenCount: Int? = nil,
        completedTaskCount: Int? = nil,
        completedCountQuality: PulseDataQuality = .unavailable,
        completedScope: PulseScope = .currentWindow,
        completedIsLowerBound: Bool = false,
        isStale: Bool = false,
        note: String? = nil,
        process: PulseProcessInfo? = nil,
        degradedReason: PulseCollectionError? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.status = status
        self.tps = tps
        self.tokenCount = tokenCount
        self.completedScope = completedScope
        self.isStale = isStale
        // 约束：unavailable 必须对应 nil 计数；complete/partial 必须有具体计数。
        // 若二者矛盾，则以“更保守”的方式归一，避免把采集失败伪装成真实为 0。
        switch completedCountQuality {
        case .unavailable:
            self.completedTaskCount = nil
            self.completedCountQuality = .unavailable
            // 取不到值时“下界”无意义，归一为 false。
            self.completedIsLowerBound = false
        case .complete, .partial:
            if let count = completedTaskCount {
                self.completedTaskCount = count
                self.completedCountQuality = completedCountQuality
                // partial 天然是下界；complete 则尊重调用方传入的标记。
                self.completedIsLowerBound = (completedCountQuality == .partial) ? true : completedIsLowerBound
            } else {
                self.completedTaskCount = nil
                self.completedCountQuality = .unavailable
                self.completedIsLowerBound = false
            }
        }
        // 保证 note 与结构化降级原因一致：若未显式提供 note，则回落到错误描述。
        self.note = note ?? degradedReason?.errorDescription
        self.process = process
        self.degradedReason = degradedReason
    }

    /// 构造一个降级快照：采集失败时使用，显式携带错误而非吞掉。
    public static func degraded(
        source: PulseSource,
        timestamp: Date,
        reason: PulseCollectionError,
        id: UUID = UUID()
    ) -> PulseSnapshot {
        PulseSnapshot(
            id: id,
            timestamp: timestamp,
            source: source,
            status: .degraded,
            tps: nil,
            tokenCount: nil,
            completedTaskCount: nil,
            completedCountQuality: .unavailable,
            completedScope: .currentWindow,
            completedIsLowerBound: false,
            isStale: false,
            note: reason.errorDescription,
            process: nil,
            degradedReason: reason
        )
    }
}
