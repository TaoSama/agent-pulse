import SwiftUI

/// 设置页的 Token 统计 / 用量上报 / 全量同步三个 Section。
struct TokenSyncSettingsSection: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        Section("Token 统计") {
            Toggle("本地长期采集", isOn: localCollectionBinding)

            HStack {
                Text("Canonical hostname")
                Spacer()
                Text(model.tokenSyncStatus.canonicalHostname ?? "未配置")
                    .foregroundStyle(model.tokenSyncStatus.canonicalHostname == nil ? .red : .secondary)
            }

            // 配置就绪时以 reporting.json 的 canonical hostname 为权威，不允许用户自由输入
            // 造成双真源；仅在配置未就绪（纯本地采集）时，允许保存本地设备标识。
            if hostnameIsAuthoritative {
                Text("hostname 由本地上报配置提供，作为上报权威，不可在此修改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                TextField("设备标识（仅本地采集用）", text: hostnameBinding)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("上次扫描")
                Spacer()
                Text(Self.dateText(model.tokenSyncStatus.lastScanAt))
                    .foregroundStyle(.secondary)
            }

            Button(model.tokenSyncStatus.scanningInProgress ? "正在扫描…" : "立即扫描") {
                model.scanTokenUsageNow()
            }
            .disabled(!model.tokenSyncStatus.localCollectionEnabled || model.tokenSyncStatus.scanningInProgress)

            Text("历史会话删除后，已入库的 Token 统计仍会保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("用量上报") {
            Toggle("自动上报", isOn: reportingBinding)
                .disabled(!canEnableReporting)

            if !canEnableReporting {
                Text(reportingDisabledReason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("API 地址（留空则仅本地）", text: ingestURLBinding)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("配置状态")
                Spacer()
                Text(configurationStatusText)
                    .foregroundStyle(configurationStatusColor)
            }

            if let error = model.tokenSyncStatus.configurationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("上次上报")
                Spacer()
                Text(Self.dateText(model.tokenSyncStatus.lastReportAt))
                    .foregroundStyle(.secondary)
            }

            if let error = model.tokenSyncStatus.reportingError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !model.tokenSyncStatus.reportingEligible {
                Text("上报门禁：存在无法证明的潜在重复，已阻止上报。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                ForEach(model.tokenSyncStatus.reportingBlockedReasons, id: \.self) { reason in
                    Text("• \(reason)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("待上报")
                Spacer()
                Text("buckets \(model.tokenSyncStatus.pendingBuckets) · sessions \(model.tokenSyncStatus.pendingSessions)")
                    .foregroundStyle(.secondary)
            }

            Button(model.tokenSyncStatus.reportingInProgress ? "正在上报…" : "立即上报") {
                model.reportTokenUsageNow()
            }
            .disabled(!canReport)

            Text(reportFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("全量同步") {
            HStack {
                Text("状态")
                Spacer()
                Text(fullSyncStateText)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.tokenSyncStatus.fullSyncBlockReasons, id: \.self) { reason in
                Text("• \(reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("开始全量同步") { model.runTokenFullSync() }
                .disabled(model.tokenSyncStatus.fullSyncState != .ready)
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
        && !model.tokenSyncStatus.reportingInProgress
        && model.tokenSyncStatus.canonicalHostname != nil
        && model.tokenSyncStatus.reportingEligible
    }

    private var configurationStatusText: String {
        switch model.tokenSyncStatus.configurationStatus {
        case .ready: return "已就绪"
        case .missing: return "配置缺失"
        case .invalid: return "配置无效"
        }
    }

    private var configurationStatusColor: Color {
        model.tokenSyncStatus.configurationStatus == .ready ? .green : .orange
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
