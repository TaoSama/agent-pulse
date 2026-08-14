import SwiftUI

/// 设置窗口：深色卡片式，与菜单栏面板、悬浮球共用同一套黑底白字语言。
/// 包含趋势配色、R2 上传、cliproxyapi 采集，以及 Token 统计/上报/全量同步状态。
struct AgentPulseSettingsView: View {
    @ObservedObject var model: ApplicationModel

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                trendCard
                r2Card
                cliProxyCard
                TokenSyncSettingsSection(model: model)
            }
            .padding(16)
        }
        .background(Self.windowBackground)
        .preferredColorScheme(.dark)
        .frame(minWidth: 580, minHeight: 540)
    }

    /// 窗口底色：中性灰，与菜单栏展开面板"灰底 + 纯黑卡"的对比关系一致，使纯黑卡浮起。
    private static let windowBackground = Color(red: 0.22, green: 0.22, blue: 0.23)

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Agent Pulse")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(Color.white.opacity(0.75))
        }
        .padding(.horizontal, 2)
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

    private var r2Card: some View {
        SettingsCard(title: "R2 图片上传", systemImage: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsField(
                    title: ".env 路径",
                    text: $model.configPath,
                    accessibilityLabel: "R2 配置文件路径"
                )
                HStack(alignment: .center, spacing: 8) {
                    SettingsFootnote("只保存文件路径；凭证不会显示或写入 App 设置。")
                    Spacer(minLength: 8)
                    SettingsGhostButton("恢复默认路径") {
                        model.configPath = UploadService.defaultConfigPath
                    }
                }
            }
        }
    }

    private var cliProxyCard: some View {
        SettingsCard(title: "cliproxyapi 用量采集", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsField(
                    title: ".env 路径",
                    text: $model.cliProxyConfigPath,
                    accessibilityLabel: "cliproxyapi 配置文件路径"
                )
                HStack(alignment: .center, spacing: 8) {
                    SettingsFootnote("只保存文件路径；base URL、management key 与目标 apikey 不会显示或写入 App 设置。")
                    Spacer(minLength: 8)
                    SettingsGhostButton("恢复默认路径") {
                        model.cliProxyConfigPath = CliProxyUsageService.defaultConfigPath
                    }
                }
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

    private var statusColor: Color {
        if model.tps == nil { return Color.white.opacity(0.35) }
        return model.sparklineRegression.trend.color(for: model.trendColorMode)
    }

    private var statusText: String {
        guard let tps = model.tps else { return "—" }
        return String(format: "%.1f TPS", tps)
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
        case .neutral: return Color.white.opacity(0.6)
        case .positive: return .green
        case .warning: return .orange
        case .negative: return .red
        }
    }
}

/// 深色卡片容器：标题 + 内容，与菜单面板同一视觉语言（纯黑卡 + 细描边）。
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.6))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
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
                        .foregroundStyle(Color.white.opacity(0.45))
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
                .foregroundStyle(Color.white.opacity(0.5))
            TextField(
                "",
                text: $text,
                prompt: Text("未设置").foregroundColor(Color.white.opacity(0.3))
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
                        .foregroundStyle(Color.white.opacity(0.45))
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
                            .foregroundStyle(Color.white.opacity(0.45))
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
                .foregroundStyle(disabled ? Color.white.opacity(0.35) : Color.white.opacity(0.85))
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
