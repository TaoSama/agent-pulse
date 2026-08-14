import SwiftUI

/// 设置窗口：可滚动、可调整大小。
/// 包含趋势配色、R2 上传，以及 Token 统计/上报/全量同步状态。
struct AgentPulseSettingsView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        ScrollView {
            Form {
                Section("趋势配色") {
                    Picker("颜色方向", selection: $model.trendColorMode) {
                        ForEach(TrendColorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("菜单栏、悬浮球和看板会同步使用这套颜色。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("R2 图片上传") {
                    TextField(".env 路径", text: $model.configPath)
                        .accessibilityLabel("R2 配置文件路径")
                    HStack {
                        Text("只保存文件路径；凭证不会显示或写入 App 设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认路径") {
                            model.configPath = UploadService.defaultConfigPath
                        }
                    }
                }

                Section("cliproxyapi 用量采集") {
                    TextField(".env 路径", text: $model.cliProxyConfigPath)
                        .accessibilityLabel("cliproxyapi 配置文件路径")
                    HStack {
                        Text("只保存文件路径；base URL、management key 与目标 apikey 不会显示或写入 App 设置。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认路径") {
                            model.cliProxyConfigPath = CliProxyUsageService.defaultConfigPath
                        }
                    }
                    HStack {
                        Text("采集状态")
                        Spacer()
                        Text(model.tokenSyncStatus.cliProxyConfigured ? "已配置" : "未配置")
                            .foregroundStyle(model.tokenSyncStatus.cliProxyConfigured ? .green : .secondary)
                    }
                    if let error = model.tokenSyncStatus.cliProxyError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                TokenSyncSettingsSection(model: model)
            }
            .formStyle(.grouped)
            .padding(8)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
