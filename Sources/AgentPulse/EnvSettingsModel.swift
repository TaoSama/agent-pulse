import Foundation
import SwiftUI
import AgentPulseCore

/// 单个可配置项的来源：从 env 文件读取，或用户手动填写（写回 env）。
enum EnvFieldSource: String, Sendable, Equatable, Codable {
    case env
    case manual
}

/// 设置页每个 env 键的双源状态与写回逻辑的单一持有者。
///
/// 隐私契约：
/// - 密钥（``MergedEnvKeys/secretKeys``）的**值只驻内存**，绝不写入 UserDefaults / SQLite / 日志；
///   唯一持久化路径是写回 0600 的合并 env 文件。
/// - 仅每键的**来源枚举**（env/manual）与**合并 env 路径**可落 UserDefaults。
/// - env 源也回显文件中读到的值（密钥在 UI 层掩码）。
@MainActor
final class EnvSettingsModel: ObservableObject {
    /// 参与双源编辑的所有键，按 UI 分组顺序排列。
    static let allKeys: [String] = [
        MergedEnvKeys.r2AccountID, MergedEnvKeys.r2Endpoint, MergedEnvKeys.r2Bucket,
        MergedEnvKeys.r2PublicBaseURL, MergedEnvKeys.r2AccessKeyID, MergedEnvKeys.r2SecretAccessKey,
        MergedEnvKeys.cliProxyBaseURL, MergedEnvKeys.cliProxyManagementKey, MergedEnvKeys.cliProxyTargetAPIKey,
        MergedEnvKeys.reportBaseURL, MergedEnvKeys.reportCanonicalHostname,
    ]

    /// UserDefaults 中保存「每键来源枚举」的键前缀（只存 env/manual，绝不存值）。
    private static let sourceDefaultsPrefix = "com.agentpulse.env.source."

    private let defaults: UserDefaults

    /// 合并 env 路径（仅路径可持久化）。
    @Published var path: String {
        didSet {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            MergedEnvPreferences.setPath(trimmed, defaults: defaults)
            reload()
        }
    }

    /// 每键的来源。
    @Published private(set) var sources: [String: EnvFieldSource]
    /// 每键内存态的当前值（env 源=文件读到的值；manual 源=用户填写/已写回的值）。密钥仅驻内存。
    @Published private(set) var values: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let resolvedPath = MergedEnvPreferences.resolvePath(defaults: defaults)
        self.path = resolvedPath
        var sources: [String: EnvFieldSource] = [:]
        for key in Self.allKeys {
            let raw = defaults.string(forKey: Self.sourceDefaultsPrefix + key)
            sources[key] = raw.flatMap(EnvFieldSource.init(rawValue:)) ?? .env
        }
        self.sources = sources
        self.values = [:]
        reloadValues()
    }

    /// 某键是否密钥（决定 UI 是否掩码）。
    func isSecret(_ key: String) -> Bool { MergedEnvKeys.isSecret(key) }

    /// 从合并 env 文件重新读取所有键的当前值到内存（缺失/不可读则清空为空串）。
    func reload() { reloadValues() }

    private func reloadValues() {
        let environment = (try? EnvFile.load(path: path)) ?? [:]
        var next: [String: String] = [:]
        for key in Self.allKeys {
            next[key] = environment[key] ?? ""
        }
        values = next
    }

    /// 切换某键来源。切到 env 时重新读回文件值；切到 manual 时保留当前内存值供用户编辑。
    func setSource(_ source: EnvFieldSource, for key: String) {
        sources[key] = source
        defaults.set(source.rawValue, forKey: Self.sourceDefaultsPrefix + key)
        if source == .env {
            let environment = (try? EnvFile.load(path: path)) ?? [:]
            values[key] = environment[key] ?? ""
        }
    }

    /// 每键外部写回覆盖：对某键设置后，`commitManualValue` 改为调用该闭包（而非直接写文件），
    /// 用于把 REPORT_* 简单值交给 TokenSyncCoordinator 统一写回并刷新上报状态，保证单一写者。
    private var externalWriters: [String: (String) -> Void] = [:]

    /// 注册某键的外部写回器（如 REPORT_BASE_URL / REPORT_CANONICAL_HOSTNAME → coordinator）。
    func setExternalWriter(_ writer: @escaping (String) -> Void, for key: String) {
        externalWriters[key] = writer
    }

    /// 提交某键的手填值：更新内存并写回 0600 env 文件。空串表示清除该键。
    /// 若该键注册了外部写回器，则委托外部写回（内存值随后由 reload 对齐）。
    /// 写回失败返回 false（UI 可提示），但不抛出，避免阻断设置页。
    @discardableResult
    func commitManualValue(_ value: String, for key: String) -> Bool {
        values[key] = value
        if let writer = externalWriters[key] {
            writer(value)
            return true
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            try EnvFile.writeBack([key: value], to: url)
            return true
        } catch {
            return false
        }
    }

    /// 值绑定：env 源只读回显（set 被忽略）；manual 源写入内存并写回文件。
    func valueBinding(for key: String) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.values[key] ?? "" },
            set: { [weak self] newValue in
                guard let self else { return }
                guard self.sources[key] == .manual else { return }
                self.commitManualValue(newValue, for: key)
            }
        )
    }

    /// 来源绑定。
    func sourceBinding(for key: String) -> Binding<EnvFieldSource> {
        Binding(
            get: { [weak self] in self?.sources[key] ?? .env },
            set: { [weak self] newValue in self?.setSource(newValue, for: key) }
        )
    }

    /// UI 展示用的显示值：密钥掩码，非密钥明文；空值返回空串。
    func displayValue(for key: String) -> String {
        let value = values[key] ?? ""
        guard !value.isEmpty else { return "" }
        return isSecret(key) ? SecretMask.mask(value) : value
    }
}
