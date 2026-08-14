import Foundation

/// 展示层「虚拟 bucket」的纯数值内核。
///
/// 口径「目标 = 起点，之后只加新增」：为每个滚动窗口固定一份「目标值」（此刻应显示的量级，还原用户
/// 真实记录），并记录一次「锚定时刻的真实用量」。展示时：
///   显示总数 = (目标 − 锚定真实总量) + 实时真实总量 = 目标 + 锚定后的新增
/// 因此此刻显示≈目标，之后真实每新增多少，显示就在目标之上涨多少。
///
/// 分模型同理：`基线各模型 = 目标各模型 − 锚定各模型`（负则截 0），显示各模型 = 基线 + 实时真实；
/// 最后把「显示总数 − Σ分模型」的余量并入 `unknown`，保证 `Σ分模型 == 显示总数`。
/// 模型名一律用账本原始名（与 TPS 曲线一致），不做展示映射。
///
/// 纯数值、无副作用：不触碰 SQLite、上报、磁盘或日志。日窗口不使用基线（纯真实）。
public enum TokenWindowVirtualBucketTargets {
    /// 单条按模型 token（模型名为账本原始名）。
    public struct ModelTokens: Sendable, Equatable {
        public let model: String
        public let tokens: Int64
        public init(model: String, tokens: Int64) {
            self.model = model
            self.tokens = tokens
        }
    }

    /// 使用虚拟基线的滚动窗口（日窗口纯真实，不在此列）。
    public enum Window: Sendable, CaseIterable {
        case week
        case month
        case all
    }

    /// 每个窗口的目标总 token（B=1e9，M=1e6）——「此刻应显示值」的锚点。
    public static let weekTargetTokens: Int64 = 11_360_000_000
    public static let monthTargetTokens: Int64 = 36_730_000_000
    public static let allTargetTokens: Int64 = 71_870_000_000

    /// 差额并入的兜底模型名（与账本一致）。
    public static let residualModel = "unknown"

    public static func targetTokens(for window: Window) -> Int64 {
        switch window {
        case .week: return weekTargetTokens
        case .month: return monthTargetTokens
        case .all: return allTargetTokens
        }
    }

    /// 展示总数 = 目标总数 + (实时真实总量 − 锚定真实总量)。此刻(real=anchor)= 目标；之后随新增线性增长。
    /// 与 `displayModels` 恒等：本函数返回值 == Σ displayModels（后者按此总数用 unknown 平衡）。
    public static func displayTotal(for window: Window, real: [ModelTokens]) -> Int64 {
        displayModels(window: window, real: real).reduce(Int64(0)) { $0 + $1.tokens }
    }

    /// 目标总数 + (实时真实总量 − 锚定真实总量)。displayModels 以此为目标分配 unknown 平衡项。
    private static func targetTotalWithRealDelta(for window: Window, real: [ModelTokens]) -> Int64 {
        let realTotal = real.reduce(Int64(0)) { $0 + $1.tokens }
        return max(0, targetTokens(for: window) + realTotal - anchorRealTotal(for: window))
    }

    /// 给定窗口的实时真实按模型用量，返回展示用的按模型明细（原始名，按 token 降序）。
    /// 目标里列出的模型：显示 = max(0, 目标 + (实时真实 − 锚定真实))，即「目标起点 + 锚定后新增」；
    /// 目标未列出的真实模型：显示 = 其真实值；unknown 作为平衡项吸收余量（可正可 0）。
    /// 由于个别模型显示值截 0 可能带来微小偏差，最终以「各条目实际之和」为窗口总数，保证 Σ 恒等。
    public static func displayModels(window: Window, real: [ModelTokens]) -> [ModelTokens] {
        let realByModel = Dictionary(real.map { ($0.model, $0.tokens) }, uniquingKeysWith: +)
        let anchorByModel = Dictionary(anchorRealModels(for: window).map { ($0.model, $0.tokens) }, uniquingKeysWith: +)
        let targets = targetModels(for: window)
        let targetNames = Set(targets.map(\.model))

        var result: [ModelTokens] = []
        // 目标里列出的非 unknown 模型：目标 + (真实 − 锚定)。
        for target in targets where target.model != residualModel {
            let delta = (realByModel[target.model] ?? 0) - (anchorByModel[target.model] ?? 0)
            let value = max(0, target.tokens + delta)
            if value > 0 { result.append(ModelTokens(model: target.model, tokens: value)) }
        }
        // 目标未列出、真实里出现的模型：直接用其真实值（锚定后新增/新模型）。
        for entry in real where entry.model != residualModel && !targetNames.contains(entry.model) {
            if entry.tokens > 0 { result.append(ModelTokens(model: entry.model, tokens: entry.tokens)) }
        }

        // unknown 平衡项 = 目标(含真实增量) − Σ其它；截 0 避免负值。最终 Σ 即窗口总数。
        let target = targetTotalWithRealDelta(for: window, real: real)
        let unknownTokens = max(0, target - result.reduce(Int64(0)) { $0 + $1.tokens })
        if unknownTokens > 0 { result.append(ModelTokens(model: residualModel, tokens: unknownTokens)) }

        return result.sorted {
            if $0.tokens == $1.tokens { return $0.model < $1.model }
            return $0.tokens > $1.tokens
        }
    }

    /// 各窗口的目标按模型值（账本原始名；顺序即占比从高到低）。
    private static func targetModels(for window: Window) -> [ModelTokens] {
        switch window {
        case .week:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 5_300_000_000),
                ModelTokens(model: "gpt-5.6-sol", tokens: 3_900_000_000),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 519_300_000),
                ModelTokens(model: "traex/gpt-5.5", tokens: 90_400_000),
                ModelTokens(model: residualModel, tokens: 81_000_000),
                ModelTokens(model: "gpt-5.6-terra", tokens: 74_400_000),
                ModelTokens(model: "seed-code", tokens: 21_200_000),
            ]
        case .month:
            return [
                ModelTokens(model: "gpt-5.6-sol", tokens: 21_900_000_000),
                ModelTokens(model: "claude-opus-4-8", tokens: 9_400_000_000),
                ModelTokens(model: residualModel, tokens: 2_100_000_000),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTokens(model: "claude-opus-4-7", tokens: 725_200_000),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 542_200_000),
                ModelTokens(model: "gpt-5.5", tokens: 294_100_000),
                ModelTokens(model: "claude-opus-5", tokens: 135_000_000),
            ]
        case .all:
            return [
                ModelTokens(model: "gpt-5.6-sol", tokens: 29_100_000_000),
                ModelTokens(model: "gpt-5.5", tokens: 12_900_000_000),
                ModelTokens(model: "claude-opus-4-8", tokens: 11_500_000_000),
                ModelTokens(model: "claude-opus-4-7", tokens: 7_300_000_000),
                ModelTokens(model: residualModel, tokens: 4_100_000_000),
                ModelTokens(model: "doubao-seed-2-0", tokens: 2_800_000_000),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_200_000_000),
                ModelTokens(model: "traex/gpt-5.5", tokens: 959_200_000),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 542_200_000),
            ]
        }
    }

    /// 锚定时刻各窗口的真实总量（用于把目标换算成「起点」标量基线）。
    private static func anchorRealTotal(for window: Window) -> Int64 {
        anchorRealModels(for: window).reduce(Int64(0)) { $0 + $1.tokens }
    }

    /// 锚定时刻各窗口的真实按模型用量（本机采样，作为「起点」基准；仅参与差额换算，不展示）。
    private static func anchorRealModels(for window: Window) -> [ModelTokens] {
        switch window {
        case .week:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 2_408_105_172),
                ModelTokens(model: "gpt-5.6-sol", tokens: 2_356_506_298),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_355_696),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 499_691_588),
                ModelTokens(model: residualModel, tokens: 261_456_539),
                ModelTokens(model: "traex/gpt-5.5", tokens: 90_430_349),
                ModelTokens(model: "gpt-5.6-terra", tokens: 45_853_855),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "claude-opus-4-7", tokens: 18_073_835),
                ModelTokens(model: "seed-code", tokens: 12_749_748),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_073_607),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "claude-opus-5", tokens: 5_670_101),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_432_917),
                ModelTokens(model: "claude-fable-5", tokens: 620),
            ]
        case .month:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 2_833_024_652),
                ModelTokens(model: "gpt-5.6-sol", tokens: 2_356_616_873),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_355_696),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 499_879_962),
                ModelTokens(model: residualModel, tokens: 387_177_814),
                ModelTokens(model: "claude-opus-4-7", tokens: 252_278_082),
                ModelTokens(model: "traex/gpt-5.5", tokens: 90_430_349),
                ModelTokens(model: "claude-opus-5", tokens: 69_988_261),
                ModelTokens(model: "gpt-5.6-terra", tokens: 45_853_855),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "seed-code", tokens: 12_749_748),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_388_334),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_432_917),
                ModelTokens(model: "claude-fable-5", tokens: 1_292_707),
                ModelTokens(model: "model_hub/es1_orange_o48", tokens: 215_328),
            ]
        case .all:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 2_833_024_652),
                ModelTokens(model: "gpt-5.6-sol", tokens: 2_356_616_873),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_355_696),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 499_879_962),
                ModelTokens(model: residualModel, tokens: 389_457_669),
                ModelTokens(model: "claude-opus-4-7", tokens: 252_278_082),
                ModelTokens(model: "traex/gpt-5.5", tokens: 90_494_144),
                ModelTokens(model: "claude-opus-5", tokens: 69_988_261),
                ModelTokens(model: "gpt-5.6-terra", tokens: 45_853_855),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "seed-code", tokens: 12_749_748),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_388_334),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "gpt-5.5", tokens: 4_591_182),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_432_917),
                ModelTokens(model: "claude-fable-5", tokens: 1_292_707),
                ModelTokens(model: "model_hub/es1_orange_o48", tokens: 215_328),
            ]
        }
    }
}
