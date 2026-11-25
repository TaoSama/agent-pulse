import SwiftUI
import AgentPulseCore

/// 设置视图：嵌入 menubar 面板内的深色卡片式设置，与主面板、悬浮球共用黑底白字语言。
/// 展示趋势配色、用量采集与上报，以及 1Password 配置状态。
struct AgentPulseSettingsView: View {
    @ObservedObject var model: ApplicationModel
    @ObservedObject var managedSettings: ManagedSettingsModel

    init(model: ApplicationModel) {
        self.model = model
        self.managedSettings = model.managedSettings
    }

    var body: some View {
        VStack(spacing: 12) {
            trendCard
            TokenSyncSettingsSection(model: model)
            asterCard
            configurationCard
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var trendCard: some View {
        SettingsCard(title: "趋势配色", systemImage: "paintpalette") {
            HStack(spacing: 12) {
                ForEach(TrendColorMode.allCases) { mode in
                    SettingsRadioRow(
                        title: mode.title,
                        isSelected: model.trendColorMode == mode
                    ) {
                        model.trendColorMode = mode
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                Spacer(minLength: 8)
                Text("菜单栏、悬浮球和看板同步")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var asterCard: some View {
        SettingsCard(title: "Aster 用量采集", systemImage: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsRow(title: "服务") {
                    Text("aster.taoai.site")
                        .font(.system(size: 11, design: .monospaced))
                }
                SettingsRow(title: "采集状态") {
                    SettingsStatusBadge(
                        text: model.tokenSyncStatus.asterConfigured
                            ? "已配置"
                            : "未配置",
                        tone: model.tokenSyncStatus.asterConfigured ? .positive : .neutral
                    )
                }
                if let error = model.tokenSyncStatus.asterError {
                    SettingsFootnote(error, tone: .warning)
                }
            }
        }
    }

    private var configurationCard: some View {
        SettingsCard(title: "1Password 配置", systemImage: "key.horizontal") {
            VStack(alignment: .leading, spacing: 10) {
                SettingsRow(title: "条目状态") {
                    SettingsStatusBadge(
                        text: managedSettings.hasLoadedItem ? "已读取" : "未读取",
                        tone: managedSettings.hasLoadedItem ? .positive : .warning
                    )
                }
                if let error = managedSettings.errorText {
                    SettingsFootnote(error, tone: .negative)
                }
                SettingsRow(title: "R2 图片上传") {
                    SettingsStatusBadge(
                        text: managedSettings.isR2Configured ? "已配置" : "未配置",
                        tone: managedSettings.isR2Configured ? .positive : .warning
                    )
                }
                HStack {
                    Spacer()
                    SettingsPrimaryButton(title: "刷新配置", systemImage: "arrow.clockwise") {
                        managedSettings.reload()
                    }
                }
            }
        }
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
    /// 内容区最小宽度：用于让并排/同类按钮（如「立即扫描」「立即上报」）尺寸一致，
    /// 不随图标字形或文案宽度差异而变化。nil 时按内容自适应。
    var minContentWidth: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if loading || systemImage != nil {
                    // 图标区固定宽度：不同字形（arrow.clockwise / arrow.up.circle）宽度不一，
                    // 固定后按钮尺寸不随图标变化，与并排同类按钮完全一致。
                    Group {
                        if loading {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.black)
                        } else if let systemImage {
                            Image(systemName: systemImage)
                        }
                    }
                    .frame(width: 14)
                }
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .frame(minWidth: minContentWidth)
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

/// 「?」说明徽章：鼠标悬停即弹出说明气泡（popover）。
/// 不用 `.help()`——在 MenuBarExtra 弹窗里它的 hover tooltip 不触发；改用 `.onHover`
/// 驱动 popover，hover 立即出现；移开后延迟收起，给用户时间把鼠标移进气泡，
/// 期间指针进入图标或气泡任一区域都保活，避免"移向气泡途中经过别处就消失"。
struct HelpBadge: View {
    let text: String
    @State private var showing = false
    /// 最近一次"离开"的代次；延迟关闭时比对，若期间又进入则代次改变、取消关闭。
    @State private var leaveToken = 0

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(Color.white)
            .contentShape(Circle())
            .onHover { inside in
                if inside {
                    leaveToken &+= 1
                    showing = true
                } else {
                    scheduleClose()
                }
            }
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 240, alignment: .leading)
                    .padding(12)
                    // 明确黑底白字，别依赖系统浅色 material（此前白字铺在浅底上看不清）。
                    .background(Color.black)
                    .presentationCompactAdaptation(.popover)
                    // 指针进入气泡内容即保活；离开再延迟收起。
                    .onHover { inside in
                        if inside {
                            leaveToken &+= 1
                        } else {
                            scheduleClose()
                        }
                    }
            }
            .accessibilityLabel("说明")
            .accessibilityHint(text)
    }

    /// 延迟收起：记下当前代次，0.6s 后若代次未变（期间没再进入图标/气泡）才真正关闭。
    private func scheduleClose() {
        leaveToken &+= 1
        let token = leaveToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if token == leaveToken { showing = false }
        }
    }
}
