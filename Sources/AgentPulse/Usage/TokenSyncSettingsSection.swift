import SwiftUI
import AgentPulseCore

/// 设置页的 Token 统计 / 用量上报两张深色卡片。
struct TokenSyncSettingsSection: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var envSettings: EnvSettingsModel

    init(model: ApplicationModel) {
        self.model = model
        self.envSettings = model.envSettings
    }

    var body: some View {
        tokenStatsCard
        intervalCard
        reportingCard
    }

    // MARK: 扫描和上报间隔（独立一趴，夹在 Token 统计与用量上报之间）

    private var intervalCard: some View {
        HStack(alignment: .center, spacing: 8) {
            Label("扫描和上报间隔", systemImage: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 12)
            Picker("扫描和上报间隔", selection: reportIntervalBinding) {
                ForEach(TokenReportInterval.allCases) { interval in
                    Text(interval.title).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(.white)
            .colorScheme(.dark)
            .frame(maxWidth: 300, alignment: .trailing)
            .accessibilityLabel("扫描和上报间隔")
            .accessibilityValue(model.tokenSyncStatus.autoReportInterval.title)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(Color.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Token 统计

    private var tokenStatsCard: some View {
        SettingsCard(title: "Token 统计", systemImage: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsToggleRow(
                    title: "本地长期采集",
                    subtitle: "仅写入本机 SQLite，删除历史会话不影响已入库统计。",
                    isOn: localCollectionBinding
                )

                // hostname 权威来自合并 env 的 REPORT_CANONICAL_HOSTNAME：双源可读可填，
                // 手填经 coordinator 写回 env 并刷新上报状态（非密钥，明文回显）。
                // 单行「标题 · ? · 值 · 编辑」，值不折行；说明进 ? 悬浮。
                dualSourceField(
                    "设备标识",
                    key: MergedEnvKeys.reportCanonicalHostname,
                    singleLine: true,
                    help: "canonical hostname，存于合并 env，作为上报身份；改名会触发历史归属确认。"
                )

                // 上次扫描合成一行：标题 + ?（历史保留说明）+ 时间 + 立即扫描按钮。
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("上次扫描").font(.system(size: 12)).foregroundStyle(Color.white)
                        HelpBadge(text: "历史会话删除后，已入库的 Token 统计仍会保留。")
                    }
                    Text(Self.dateText(model.tokenSyncStatus.lastScanAt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white)
                    Spacer(minLength: 8)
                    SettingsPrimaryButton(
                        title: model.tokenSyncStatus.scanningInProgress ? "正在扫描…" : "立即扫描",
                        systemImage: "arrow.clockwise",
                        loading: model.tokenSyncStatus.scanningInProgress,
                        disabled: scanDisabled
                    ) {
                        model.scanTokenUsageNow()
                    }
                }
            }
        }
    }

    // MARK: 用量上报

    private var reportingCard: some View {
        SettingsCard(title: "用量上报", systemImage: "paperplane") {
            VStack(alignment: .leading, spacing: 10) {
                // 权威状态行：一句话说清当前能不能上报、为什么。其余项降为详情。
                let authority = model.tokenSyncStatus.authoritativeReportingState
                SettingsRow(title: "上报状态") {
                    SettingsStatusBadge(text: authority.title, tone: authority.tone)
                }
                if let detail = authority.detail {
                    SettingsFootnote(detail, tone: authority.tone)
                }

                SettingsToggleRow(
                    title: "本机上报（谁开谁报）",
                    isOn: reportingBinding,
                    disabled: !canEnableReporting
                )

                if !canEnableReporting {
                    SettingsFootnote(reportingDisabledReason, tone: .negative)
                }

                // API 地址权威来自合并 env 的 REPORT_BASE_URL：双源可读可填（非密钥明文），
                // 手填经 coordinator 写回 env；填好但不自动开启上报。单行显示不折行，与其它输入框一致。
                dualSourceField("API 地址（留空则仅本地）", key: MergedEnvKeys.reportBaseURL, singleLine: true)

                HStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 10))
                    Text(localToApiRouteText)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(Color.white)

                SettingsRow(title: "配置状态") {
                    SettingsStatusBadge(text: configurationStatusText, tone: configurationStatusTone)
                }
                if let error = model.tokenSyncStatus.configurationError {
                    SettingsFootnote(error, tone: configurationStatusTone)
                }

                // 上次上报合成一行：标题 + ?（启用行为说明）+ 时间 + 结果徽章 + 立即上报按钮。
                HStack(alignment: .center, spacing: 8) {
                    HStack(spacing: 4) {
                        Text("上次上报").font(.system(size: 12)).foregroundStyle(Color.white)
                        HelpBadge(text: reportFooterText)
                    }
                    Text(Self.dateText(model.tokenSyncStatus.lastReportAt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white)
                    SettingsStatusBadge(text: lastReportOutcomeText, tone: lastReportOutcomeTone)
                    Spacer(minLength: 8)
                    SettingsPrimaryButton(
                        title: model.tokenSyncStatus.reportingInProgress ? "正在上报…" : "立即上报",
                        systemImage: "arrow.up.circle",
                        loading: model.tokenSyncStatus.reportingInProgress,
                        disabled: !canReport
                    ) {
                        model.reportTokenUsageNow()
                    }
                }

                if pendingTotal > 0 {
                    SettingsRow(title: "待上报") {
                        Text("buckets \(model.tokenSyncStatus.pendingBuckets) · sessions \(model.tokenSyncStatus.pendingSessions)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white)
                    }
                }
            }
        }
    }

    /// 右对齐的主操作按钮行。
    private func actionRow(
        title: String,
        systemImage: String,
        loading: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Spacer(minLength: 0)
            SettingsPrimaryButton(
                title: title,
                systemImage: systemImage,
                loading: loading,
                disabled: disabled,
                action: action
            )
        }
    }

    /// 构造双源字段（REPORT_* 简单值，非密钥明文；手填经 coordinator 写回 env）。
    private func dualSourceField(_ title: String, key: String, singleLine: Bool = false, stacked: Bool = false, help: String? = nil) -> some View {
        SettingsDualSourceField(
            title: title,
            isSecret: envSettings.isSecret(key),
            source: envSettings.sourceBinding(for: key),
            rawValue: envSettings.valueBinding(for: key),
            displayValue: envSettings.displayValue(for: key),
            singleLine: singleLine,
            help: help,
            stacked: stacked
        )
    }

    // MARK: Bindings

    private var localCollectionBinding: Binding<Bool> {
        Binding(
            get: { model.tokenSyncStatus.localCollectionEnabled },
            set: { model.setTokenLocalCollection($0) }
        )
    }

    private var reportingBinding: Binding<Bool> {
        Binding(
            get: { model.tokenSyncStatus.reportingEnabled },
            set: { model.setTokenReporting($0) }
        )
    }

    private var reportIntervalBinding: Binding<TokenReportInterval> {
        Binding(
            get: { model.tokenSyncStatus.autoReportInterval },
            set: { model.setTokenAutoReportInterval($0) }
        )
    }

    // MARK: 状态派生

    /// scan / report 任一在途时，互斥动作一律禁用，避免并发写账。
    private var anySyncInProgress: Bool {
        model.tokenSyncStatus.scanningInProgress
        || model.tokenSyncStatus.reportingInProgress
    }

    private var scanDisabled: Bool {
        !model.tokenSyncStatus.localCollectionEnabled || anySyncInProgress
    }

    private var canEnableReporting: Bool {
        !model.tokenSyncStatus.ingestBaseURL.isEmpty
        && model.tokenSyncStatus.canonicalHostname != nil
        && model.tokenSyncStatus.configurationStatus == .ready
    }

    private var reportingDisabledReason: String {
        if model.tokenSyncStatus.ingestBaseURL.isEmpty {
            return "请先配置 API 地址"
        }
        if model.tokenSyncStatus.canonicalHostname == nil {
            return "请先配置 hostname"
        }
        if model.tokenSyncStatus.configurationStatus != .ready {
            return "本地凭证配置未就绪"
        }
        return ""
    }

    private var canReport: Bool {
        model.tokenSyncStatus.reportingEnabled
        && !anySyncInProgress
        && model.tokenSyncStatus.canonicalHostname != nil
        && model.tokenSyncStatus.reportingEligible
    }

    /// 待上报总数为 0 时隐藏计数行。
    private var pendingTotal: Int {
        model.tokenSyncStatus.pendingBuckets + model.tokenSyncStatus.pendingSessions
    }

    private var configurationStatusText: String {
        switch model.tokenSyncStatus.configurationStatus {
        case .ready: return "已就绪"
        case .missing: return "配置缺失"
        case .invalid: return "配置无效"
        }
    }

    private var configurationStatusTone: SettingsStatusTone {
        switch model.tokenSyncStatus.configurationStatus {
        case .ready: return .positive
        case .missing: return .warning   // 没配好：橙
        case .invalid: return .negative  // 配错了：红
        }
    }

    /// 上次上报结果小徽章：成功 / 未完全 / 未上报过。
    private var lastReportOutcomeText: String {
        switch model.tokenSyncStatus.lastReportSucceeded {
        case .some(true): return "成功"
        case .some(false): return "未完全"
        case .none: return "—"
        }
    }

    private var lastReportOutcomeTone: SettingsStatusTone {
        switch model.tokenSyncStatus.lastReportSucceeded {
        case .some(true): return .positive
        case .some(false): return .negative
        case .none: return .neutral
        }
    }

    /// 只展示 API host，绝不展示完整 URL（路径/查询参数可能含敏感信息）。
    private var apiHostText: String {
        let raw = model.tokenSyncStatus.ingestBaseURL
        for candidate in [raw, "https://\(raw)"] {
            if let host = URL(string: candidate)?.host, !host.isEmpty {
                return host
            }
        }
        return "—"
    }

    private var localToApiRouteText: String {
        let hostname = model.tokenSyncStatus.canonicalHostname ?? "未配置"
        guard !model.tokenSyncStatus.ingestBaseURL.isEmpty else {
            return "本机（\(hostname)）· 仅本地"
        }
        return "本机（\(hostname)）→ \(apiHostText)"
    }

    private var reportFooterText: String {
        if model.tokenSyncStatus.ingestBaseURL.isEmpty {
            return "未配置 API 地址：仅本地统计，不会发起任何网络请求。"
        }
        let interval = model.tokenSyncStatus.autoReportInterval.title
        return "启用后：应用启动时自动上报一次，之后每 \(interval)自动上报一次；也可点击「立即上报」手动触发。"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "—" }
        return dateFormatter.string(from: date)
    }
}
