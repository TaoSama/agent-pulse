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
        VStack(spacing: 12) {
            trendCard
            cliProxyCard
            TokenSyncSettingsSection(model: model)
            envPathCard
            r2Card
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

    /// 合并 env 文件路径卡片：R2 / cliproxy / 上报简单值统一存放，只保存路径，凭证不写入 App 设置。
    private var envPathCard: some View {
        SettingsCard(title: "凭证文件（合并 env）", systemImage: "key.horizontal") {
            EnvPathRow(
                path: $envSettings.path,
                help: "只保存文件路径；密钥仅在内存与该 0600 文件中，不写入 App 设置。留空「编辑 → 完成」即恢复默认路径。"
            )
        }
    }

    private var r2Card: some View {
        SettingsCard(title: "R2 图片上传", systemImage: "photo.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 12) {
                dualSourceField("Account ID", key: MergedEnvKeys.r2AccountID, singleLine: true)
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
    private func dualSourceField(_ title: String, key: String, singleLine: Bool = false) -> some View {
        SettingsDualSourceField(
            title: title,
            isSecret: envSettings.isSecret(key),
            source: envSettings.sourceBinding(for: key),
            rawValue: envSettings.valueBinding(for: key),
            displayValue: envSettings.displayValue(for: key),
            singleLine: singleLine
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
    /// 值单行显示、不折行（长值中间省略）；默认允许换行以完整展示长路径。
    var singleLine: Bool = false
    /// 非空时在标题右侧加一个「?」图标，悬浮展示该说明文字（替代下方常驻小字）。
    var help: String? = nil
    /// 两行布局：标题（+?）单独一行，值框与编辑按钮在下一行占满整宽。
    /// 用于设备标识这类需要完整展示值的字段；默认单行「标题 · 值 · 编辑」。
    var stacked: Bool = false

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                labelRow
                HStack(alignment: .center, spacing: 8) { valueAndEdit }
            }
        } else {
            HStack(alignment: .center, spacing: 8) {
                labelRow.frame(width: 132, alignment: .leading)
                valueAndEdit
            }
        }
    }

    private var labelRow: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
            if let help {
                HelpBadge(text: help)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var valueAndEdit: some View {
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
            .lineLimit(singleLine ? 1 : nil)
            .truncationMode(.middle)
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

/// 合并 env 路径行：单行「.env 路径 · ? · 值 · 编辑」，与凭证字段同一视觉。
/// 值单行不折行；点「编辑」展开输入，「完成」/回车写回；留空提交即恢复默认路径。
struct EnvPathRow: View {
    @Binding var path: String
    let help: String

    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 4) {
                Text(".env 路径")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white)
                HelpBadge(text: help)
                Spacer(minLength: 0)
            }
            .frame(width: 132, alignment: .leading)
            if isEditing {
                TextField("", text: $draft, prompt: Text("留空恢复默认").foregroundColor(Color.white.opacity(0.3)))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .onSubmit { commit() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .accessibilityLabel("合并 env 配置文件路径")
                SettingsGhostButton("完成") { commit() }
            } else {
                Text(path.isEmpty ? MergedEnvKeys.defaultPath : path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .accessibilityLabel(".env 路径（只读）")
                SettingsGhostButton("编辑") {
                    draft = path
                    isEditing = true
                }
            }
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        path = trimmed.isEmpty ? MergedEnvKeys.defaultPath : trimmed
        isEditing = false
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
