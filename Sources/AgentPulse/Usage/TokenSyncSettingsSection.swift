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
        reportingCard
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

                SettingsRow(title: "Canonical hostname") {
                    Text(model.tokenSyncStatus.canonicalHostname ?? "未配置")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(hostnameColor)
                }

                // hostname 权威来自合并 env 的 REPORT_CANONICAL_HOSTNAME：双源可读可填，
                // 手填经 coordinator 写回 env 并刷新上报状态（非密钥，明文回显）。
                dualSourceField("设备标识（canonical hostname）", key: MergedEnvKeys.reportCanonicalHostname)
                SettingsFootnote("hostname 存于合并 env，作为上报身份；改名会触发历史归属确认。")

                SettingsRow(title: "上次扫描") {
                    Text(Self.dateText(model.tokenSyncStatus.lastScanAt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white)
                }

                actionRow(
                    title: model.tokenSyncStatus.scanningInProgress ? "正在扫描…" : "立即扫描",
                    systemImage: "arrow.clockwise",
                    loading: model.tokenSyncStatus.scanningInProgress,
                    disabled: scanDisabled
                ) {
                    model.scanTokenUsageNow()
                }

                SettingsFootnote("历史会话删除后，已入库的 Token 统计仍会保留。")
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
                // 手填经 coordinator 写回 env；填好但不自动开启上报。
                dualSourceField("API 地址（留空则仅本地）", key: MergedEnvKeys.reportBaseURL)

                SettingsRow(title: "上报间隔") {
                    Picker("上报间隔", selection: reportIntervalBinding) {
                        ForEach(TokenReportInterval.allCases) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .tint(.white)
                    .colorScheme(.dark)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("自动上报间隔")
                    .accessibilityValue(model.tokenSyncStatus.autoReportInterval.title)
                }

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

                SettingsRow(title: "上次上报") {
                    HStack(spacing: 6) {
                        Text(Self.dateText(model.tokenSyncStatus.lastReportAt))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white)
                        SettingsStatusBadge(text: lastReportOutcomeText, tone: lastReportOutcomeTone)
                    }
                }

                if pendingTotal > 0 {
                    SettingsRow(title: "待上报") {
                        Text("buckets \(model.tokenSyncStatus.pendingBuckets) · sessions \(model.tokenSyncStatus.pendingSessions)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.white)
                    }
                }

                actionRow(
                    title: model.tokenSyncStatus.reportingInProgress ? "正在上报…" : "立即上报",
                    systemImage: "arrow.up.circle",
                    loading: model.tokenSyncStatus.reportingInProgress,
                    disabled: !canReport
                ) {
                    model.reportTokenUsageNow()
                }

                SettingsFootnote(reportFooterText)
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
    private func dualSourceField(_ title: String, key: String) -> some View {
        SettingsDualSourceField(
            title: title,
            isSecret: envSettings.isSecret(key),
            source: envSettings.sourceBinding(for: key),
            rawValue: envSettings.valueBinding(for: key),
            displayValue: envSettings.displayValue(for: key)
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

    private var hostnameColor: Color {
        model.tokenSyncStatus.canonicalHostname == nil ? .red : Color.white
    }

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
