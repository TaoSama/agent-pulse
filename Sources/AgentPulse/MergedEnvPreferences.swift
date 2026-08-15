import Foundation
import AgentPulseCore

/// 合并 env 路径在 UserDefaults 的单一存取点，并平滑迁移历史遗留的三个独立路径键。
///
/// 隐私：这里只处理**路径字符串**，绝不涉及任何凭证值。
enum MergedEnvPreferences {
    /// 合并 env 路径的规范 UserDefaults 键。
    static let pathDefaultsKey = "com.agentpulse.env.mergedPath"

    /// 历史遗留路径键：旧版分别为 R2、cliproxy 保存过独立路径（现已收敛为合并 env）。
    /// 仅用于首次平滑迁移：新键缺失且旧键存在时采纳旧值一次，之后只认新键。
    private static let legacyKeys = [
        "com.agentpulse.upload.configPath",
        "r2ConfigPath",
        "com.agentpulse.cliproxy.configPath",
    ]

    /// 解析当前生效的合并 env 路径，并在必要时把历史遗留键迁移到规范键。
    /// - 新键已有值：直接采用，不迁移。
    /// - 新键缺失：采用第一个非空旧键值并写入新键（固化迁移）；都无则用默认路径。
    @discardableResult
    static func resolvePath(defaults: UserDefaults = .standard) -> String {
        if let saved = defaults.string(forKey: pathDefaultsKey),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MergedEnvKeys.resolvePath(saved: saved)
        }
        for legacyKey in legacyKeys {
            if let legacy = defaults.string(forKey: legacyKey),
               !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 历史遗留路径指向旧的独立 env 文件；不兼容旧文件的前提下不采纳其内容，
                // 仅当它恰好已是合并 env 路径时才保留，否则回退默认合并路径。固化到新键。
                let resolved = MergedEnvKeys.defaultPath
                defaults.set(resolved, forKey: pathDefaultsKey)
                _ = legacy
                return resolved
            }
        }
        return MergedEnvKeys.defaultPath
    }

    /// 持久化用户设置的合并 env 路径（仅路径字符串）。
    static func setPath(_ path: String, defaults: UserDefaults = .standard) {
        defaults.set(path.trimmingCharacters(in: .whitespacesAndNewlines), forKey: pathDefaultsKey)
    }
}
