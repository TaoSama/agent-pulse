import SwiftUI

/// 设置页的 Token 统计 / 用量上报两张深色卡片。
struct TokenSyncSettingsSection: View {
    @ObservedObject var model: ApplicationModel

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

                if hostnameIsAuthoritative {
                    SettingsFootnote("hostname 由本地上报配置提供，作为上报权威，不可在此修改。")
                } else {
                    SettingsField(
                        title: "设备标识（仅本地采集用）",
                        text: hostnameBinding
                    )
                }

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
                SettingsToggleRow(
                    title: "本机上报（谁开谁报）",
                    isOn: reportingBinding,
                    disabled: !canEnableReporting
                )

                if !canEnableReporting {
                    SettingsFootnote(reportingDisabledReason, tone: .negative)
                }

                SettingsField(
                    title: "API 地址（留空则仅本地）",
                    text: ingestURLBinding
                )

                SettingsFootnote("仅本机使用，不随用量上报。")

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
                    SettingsFootnote(error, tone: .negative)
                }

                SettingsRow(title: "上次上报") {
                    Text(Self.dateText(model.tokenSyncStatus.lastReportAt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.white)
                }

                if let error = model.tokenSyncStatus.reportingError {
                    SettingsFootnote(error, tone: .negative)
                }

                if !model.tokenSyncStatus.reportingEligible {
                    SettingsFootnote("上报门禁：存在无法证明的潜在重复，已阻止上报。", tone: .negative)
                    ForEach(model.tokenSyncStatus.reportingBlockedReasons, id: \.self) { reason in
                        SettingsFootnote("• \(reason)", tone: .negative)
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

    private var ingestURLBinding: Binding<String> {
        Binding(
            get: { model.tokenSyncStatus.ingestBaseURL },
            set: { model.setTokenIngestBaseURL($0) }
        )
    }

    private var hostnameBinding: Binding<String> {
        Binding(
            get: { model.tokenSyncStatus.canonicalHostname ?? "" },
            set: { model.setTokenCanonicalHostname($0) }
        )
    }

    // MARK: 状态派生

    private var hostnameColor: Color {
        model.tokenSyncStatus.canonicalHostname == nil ? .red : Color.white
    }

    /// 配置就绪时 hostname 由 reporting.json 提供，属上报权威，UI 只读展示。
    private var hostnameIsAuthoritative: Bool {
        model.tokenSyncStatus.configurationStatus == .ready
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
        model.tokenSyncStatus.configurationStatus == .ready ? .positive : .negative
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
        return "启用后：应用启动时自动上报一次，之后每 30 分钟自动上报一次；也可点击「立即上报」手动触发。"
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
