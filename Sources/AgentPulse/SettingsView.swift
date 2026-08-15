import SwiftUI
import AgentPulseCore

/// 设置视图：嵌入 menubar 面板内的深色卡片式设置，与主面板、悬浮球共用黑底白字语言。
/// 包含趋势配色、合并 env 凭证（R2 / cliproxy 双源）、以及 Token 统计/上报/全量同步状态。
struct AgentPulseSettingsView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var envSettings: EnvSettingsModel

    init(model: ApplicationModel) {
        self.model = model
        self.envSettings = model.envSettings
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                trendCard
                envPathCard
                r2Card
                cliProxyCard
                TokenSyncSettingsSection(model: model)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: 520)
    }

    private var trendCard: some View {
        SettingsCard(title: "趋势配色", systemImage: "paintpalette") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(TrendColorMode.allCases) { mode in
                    SettingsRadioRow(
                        title: mode.title,
                        isSelected: model.trendColorMode == mode
                    ) {
                        model.trendColorMode = mode
                    }
                }
                SettingsFootnote("菜单栏、悬浮球和看板会同步使用这套颜色。")
            }
        }
    }

    /// 合并 env 文件路径卡片：R2 / cliproxy / 上报简单值统一存放，只保存路径，凭证不写入 App 设置。
    private var envPathCard: some View {
        SettingsCard(title: "凭证文件（合并 env）", systemImage: "key.horizontal") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsField(
                    title: ".env 路径",
                    text: $envSettings.path,
                    accessibilityLabel: "合并 env 配置文件路径"
                )
                HStack(alignment: .center, spacing: 8) {
                    SettingsFootnote("只保存文件路径；密钥仅在内存与该 0600 文件中，不写入 App 设置。")
                    Spacer(minLength: 8)
                    SettingsGhostButton("恢复默认路径") {
                        envSettings.path = MergedEnvKeys.defaultPath
                    }
                }
            }
        }
    }

    private var r2Card: some View {
        SettingsCard(title: "R2 图片上传", systemImage: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 12) {
                dualSourceField("Account ID", key: MergedEnvKeys.r2AccountID)
                dualSourceField("Endpoint", key: MergedEnvKeys.r2Endpoint)
                dualSourceField("Bucket", key: MergedEnvKeys.r2Bucket)
                dualSourceField("Public Base URL", key: MergedEnvKeys.r2PublicBaseURL)
                dualSourceField("Access Key ID", key: MergedEnvKeys.r2AccessKeyID)
                dualSourceField("Secret Access Key", key: MergedEnvKeys.r2SecretAccessKey)
            }
        }
    }

    private var cliProxyCard: some View {
        SettingsCard(title: "cliproxyapi 用量采集", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                dualSourceField("Base URL", key: MergedEnvKeys.cliProxyBaseURL)
                dualSourceField("Management Key", key: MergedEnvKeys.cliProxyManagementKey)
                dualSourceField("Target API Key", key: MergedEnvKeys.cliProxyTargetAPIKey)
                SettingsRow(title: "采集状态") {
                    SettingsStatusBadge(
                        text: model.tokenSyncStatus.cliProxyConfigured ? "已配置" : "未配置",
                        tone: model.tokenSyncStatus.cliProxyConfigured ? .positive : .neutral
                    )
                }
                if let error = model.tokenSyncStatus.cliProxyError {
                    SettingsFootnote(error, tone: .warning)
                }
            }
        }
    }

    /// 构造一个双源字段：env 读取 / 手动填写；密钥掩码，非密钥明文。
    private func dualSourceField(_ title: String, key: String) -> some View {
        SettingsDualSourceField(
            title: title,
            isSecret: envSettings.isSecret(key),
            source: envSettings.sourceBinding(for: key),
            rawValue: envSettings.valueBinding(for: key),
            displayValue: envSettings.displayValue(for: key)
        )
    }
}

// MARK: - 设置页共享组件

/// 状态语义色：中性信息、正常、警告、错误。
enum SettingsStatusTone {
    case neutral
    case positive
    case warning
    case negative

    var color: Color {
        switch self {
        case .neutral: return Color.white
        case .positive: return .green
        case .warning: return .orange
        case .negative: return .red
        }
    }
}

/// 深色卡片容器：标题 + 内容，与菜单面板同一视觉语言（纯黑卡、无描边）。
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 卡片本身是纯黑、无描边，内部一律按深色语义渲染（全白，靠字号/字重分层），
        // 与菜单栏展开面板的黑卡白字一致，不随系统浅/深色外观翻转。
        .foregroundStyle(Color.white)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

/// 左标题、右内容的标准行。
struct SettingsRow<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white)
                }
            }
            .foregroundStyle(Color.white)
            Spacer(minLength: 12)
            content
        }
    }
}

/// 深色输入框：小标题在上，等宽字体路径输入。
struct SettingsField: View {
    let title: String
    @Binding var text: String
    var accessibilityLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white)
            TextField(
                "",
                text: $text,
                prompt: Text("未设置").foregroundColor(Color.white.opacity(0.4))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .accessibilityLabel(accessibilityLabel ?? title)
        }
    }
}

/// 凭证字段：单行「标题 · 值回显 · 编辑」。默认只读回显合并 env 读到的值
/// （密钥中间星号掩码，非密钥明文）；点「编辑」展开明文输入，「完成」或回车即写回 0600 env。
/// 写回时自动把该键来源置为 manual，保留手填→写回能力，无需显式来源切换。
struct SettingsDualSourceField: View {
    let title: String
    let isSecret: Bool
    @Binding var source: EnvFieldSource
    /// 原始值绑定（set 只在 manual 源生效，会写回 env）。
    @Binding var rawValue: String
    /// UI 展示值（密钥已掩码、非密钥明文）；只读回显与未展开时用。
    let displayValue: String

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
                .frame(width: 132, alignment: .leading)
            if isEditing {
                editableBox
                SettingsGhostButton("完成") { commitDraft() }
            } else {
                readOnlyBox(displayValue.isEmpty ? "未设置" : displayValue, placeholder: displayValue.isEmpty)
                SettingsGhostButton("编辑") {
                    draft = rawValue
                    isEditing = true
                }
            }
        }
    }

    private func commitDraft() {
        // 手填即切到 manual 源再写回，让值绑定的写回逻辑生效。
        if source != .manual { source = .manual }
        rawValue = draft
        isEditing = false
    }

    private func readOnlyBox(_ text: String, placeholder: Bool) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(placeholder ? Color.white.opacity(0.3) : Color.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .accessibilityLabel("\(title)（只读）")
    }

    private var editableBox: some View {
        TextField(
            "",
            text: $draft,
            prompt: Text("输入后点完成").foregroundColor(Color.white.opacity(0.3))
        )
        .textFieldStyle(.plain)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.white)
        .onSubmit { commitDraft() }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .accessibilityLabel(title)
    }
}

/// 开关行：左标题（可带副标题），右侧显眼开关（放大轨道 + 滑块 + 开/关文字）。
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white)
                }
            }
            .foregroundStyle(disabled ? Color.white.opacity(0.4) : Color.white)
            Spacer(minLength: 12)
            LoudToggle(isOn: $isOn, disabled: disabled)
        }
    }
}

/// 开关：常规尺寸胶囊轨道 + 白色滑块，开态绿色高亮、关态暗灰，状态一眼可辨。
/// 整块可点，替代不够显眼的系统 .switch。
struct LoudToggle: View {
    @Binding var isOn: Bool
    var disabled: Bool = false

    private static let width: CGFloat = 44
    private static let height: CGFloat = 26
    private static let knob: CGFloat = 20

    private var trackColor: Color {
        if disabled { return Color.white.opacity(0.1) }
        return isOn ? SettingsStatusTone.positive.color : Color.white.opacity(0.18)
    }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) { isOn.toggle() }
        } label: {
            ZStack {
                Capsule().fill(trackColor)
                Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                    .frame(maxWidth: .infinity, alignment: isOn ? .trailing : .leading)
                    .padding(.horizontal, 3)
            }
            .frame(width: Self.width, height: Self.height)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .disabled(disabled)
        .accessibilityLabel(isOn ? "已开启" : "已关闭")
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// 单选行：圆形指示符 + 标题，整块可点。
struct SettingsRadioRow: View {
    let title: String
    var subtitle: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.white)
                    }
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .focusEffectDisabled()
        .foregroundStyle(Color.white)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// 状态徽章：圆点 + 文案，按语义着色。
struct SettingsStatusBadge: View {
    let text: String
    var tone: SettingsStatusTone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tone.color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.14), in: Capsule())
        .accessibilityLabel(text)
    }
}

/// 主按钮：白底黑字，支持加载态与禁用。
struct SettingsPrimaryButton: View {
    let title: String
    var systemImage: String?
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.black)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(disabled ? Color.white.opacity(0.35) : Color.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(disabled ? Color.white.opacity(0.12) : Color.white)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled || loading)
    }
}

/// 次按钮：描边样式，用于低优先级动作。
struct SettingsGhostButton: View {
    let title: String
    var disabled: Bool
    let action: () -> Void

    init(_ title: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(disabled ? Color.white.opacity(0.35) : Color.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(disabled ? 0.12 : 0.25), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 辅助说明文字，按语义着色，默认中性。
struct SettingsFootnote: View {
    let text: String
    var tone: SettingsStatusTone

    init(_ text: String, tone: SettingsStatusTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tone.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
