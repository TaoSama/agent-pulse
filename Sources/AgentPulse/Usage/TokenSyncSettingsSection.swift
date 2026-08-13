import SwiftUI

/// 设置页的 Token 统计 / 用量上报 / 全量同步三个 Section。
struct TokenSyncSettingsSection: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        Section("Token 统计") {
            Toggle("本地长期采集", isOn: localCollectionBinding)

            LabeledContent("Canonical hostname") {
                Text(model.tokenSyncStatus.canonicalHostname ?? "未配置")
                    .foregroundStyle(model.tokenSyncStatus.canonicalHostname == nil ? .red : .primary)
            }

            // 配置就绪时以 reporting.json 的 canonical hostname 为权威，不允许用户自由输入
            // 造成双真源；仅在配置未就绪（纯本地采集）时，允许保存本地设备标识。
            if hostnameIsAuthoritative {
                Text("hostname 由本地上报配置提供，作为上报权威，不可在此修改。")
                    .font(.caption)
            } else {
                TextField("设备标识（仅本地采集用）", text: hostnameBinding)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("上次扫描") {
                Text(Self.dateText(model.tokenSyncStatus.lastScanAt))
            }

            Button(model.tokenSyncStatus.scanningInProgress ? "正在扫描…" : "立即扫描") {
                model.scanTokenUsageNow()
            }
            .disabled(scanDisabled)

            Text("历史会话删除后，已入库的 Token 统计仍会保留。")
                .font(.caption)
        }

        Section("用量上报") {
            Toggle("本机上报（谁开谁报）", isOn: reportingBinding)
                .disabled(!canEnableReporting)

            if !canEnableReporting {
                Text(reportingDisabledReason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            TextField("API 地址（留空则仅本地）", text: ingestURLBinding)
                .textFieldStyle(.roundedBorder)

            Text("仅本机使用，不随用量上报。")
                .font(.caption)

            Text(localToApiRouteText)

            LabeledContent("配置状态") {
                Text(configurationStatusText)
                    .foregroundStyle(configurationStatusColor)
            }

            if let error = model.tokenSyncStatus.configurationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            LabeledContent("上次上报") {
                Text(Self.dateText(model.tokenSyncStatus.lastReportAt))
            }

            if let error = model.tokenSyncStatus.reportingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !model.tokenSyncStatus.reportingEligible {
                Text("上报门禁：存在无法证明的潜在重复，已阻止上报。")
                    .font(.caption)
                    .foregroundStyle(.red)
                ForEach(model.tokenSyncStatus.reportingBlockedReasons, id: \.self) { reason in
                    Text("• \(reason)")
                        .font(.caption)
                }
            }

            if pendingTotal > 0 {
                LabeledContent("待上报") {
                    Text("buckets \(model.tokenSyncStatus.pendingBuckets) · sessions \(model.tokenSyncStatus.pendingSessions)")
                }
            }

            Button(model.tokenSyncStatus.reportingInProgress ? "正在上报…" : "立即上报") {
                model.reportTokenUsageNow()
            }
            .disabled(!canReport)

            Text(reportFooterText)
                .font(.caption)
        }

        Section("全量同步") {
            LabeledContent("状态") {
                Text(fullSyncStateText)
            }
            ForEach(model.tokenSyncStatus.fullSyncBlockReasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.caption)
            }
            Button(fullSyncButtonTitle) { model.runTokenFullSync() }
                .disabled(fullSyncDisabled)
        }
    }

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

    /// 配置就绪时 hostname 由 reporting.json 提供，属上报权威，UI 只读展示。
    private var hostnameIsAuthoritative: Bool {
        model.tokenSyncStatus.configurationStatus == .ready
    }

    /// scan / report / full sync 任一在途时，互斥动作一律禁用，避免并发写账。
    private var anySyncInProgress: Bool {
        model.tokenSyncStatus.scanningInProgress
        || model.tokenSyncStatus.reportingInProgress
        || model.tokenSyncStatus.fullSyncState == .running
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

    private var configurationStatusColor: Color {
        model.tokenSyncStatus.configurationStatus == .ready ? .primary : .red
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

    private var fullSyncStateText: String {
        switch model.tokenSyncStatus.fullSyncState {
        case .blocked: return "未就绪"
        case .ready: return "就绪"
        case .running: return "同步中"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }

    private var fullSyncButtonTitle: String {
        switch model.tokenSyncStatus.fullSyncState {
        case .blocked, .ready:
            return "开始全量同步"
        case .running:
            return "正在全量同步…"
        case .completed:
            return "重新全量同步"
        case .failed:
            return "重试全量同步"
        }
    }

    private var fullSyncDisabled: Bool {
        model.tokenSyncStatus.fullSyncState != .ready || anySyncInProgress
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
