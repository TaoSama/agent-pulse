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
    public static let weekTargetTokens: Int64 = 11_748_392_811
    public static let monthTargetTokens: Int64 = 37_117_728_838
    public static let allTargetTokens: Int64 = 72_264_735_012

    /// 差额并入的兜底模型名（与账本一致）。
    public static let residualModel = "unknown"

    public static func targetTokens(for window: Window) -> Int64 {
        switch window {
        case .week: return weekTargetTokens
        case .month: return monthTargetTokens
        case .all: return allTargetTokens
        }
    }

    // MARK: - 缓存 / 创建维度（与总量同构：目标起点 + 锚定后新增）
    //
    // 口径与账本 `UsageInputSummary` 逐字一致：
    //   cached = cache read（命中）、new = 纯 input（cache miss）、hitRate = cached /(new + cached)。
    // 与总量维度一样「目标 = 起点，之后只加新增」，但各自独立锚定：
    //   显示缓存 = max(0, 缓存目标 + (实时真实缓存 − 锚定真实缓存))
    //   显示创建 = max(0, 创建目标 + (实时真实创建 − 锚定真实创建))
    // 命中率由显示缓存 /(显示创建 + 显示缓存) 重算。此刻 real==anchor ⇒ 显示≈目标。

    /// 各窗口的缓存（cache read）目标——「此刻应显示的缓存量」。
    private static func cachedTarget(for window: Window) -> Int64 {
        switch window {
        case .week: return 10_769_358_304
        case .month: return 33_814_316_682
        case .all: return 62_109_040_273
        }
    }

    /// 各窗口的创建（纯 input / cache miss）目标——「此刻应显示的新增量」。
    private static func newTarget(for window: Window) -> Int64 {
        switch window {
        case .week: return 798_153_448
        case .month: return 2_760_217_688
        case .all: return 9_282_127_268
        }
    }

    /// 锚定时刻各窗口的真实缓存（本机采样，作为「起点」基准；仅参与差额换算，不展示）。
    private static func anchorRealCached(for window: Window) -> Int64 {
        switch window {
        case .week: return 7_591_586_468
        case .month: return 8_822_449_785
        case .all: return 8_826_950_393
        }
    }

    /// 锚定时刻各窗口的真实创建（本机采样，作为「起点」基准；仅参与差额换算，不展示）。
    private static func anchorRealNew(for window: Window) -> Int64 {
        switch window {
        case .week: return 482_891_400
        case .month: return 824_072_946
        case .all: return 827_234_400
        }
    }

    /// 显示缓存 = max(0, 缓存目标 + (实时真实缓存 − 锚定真实缓存))。此刻(real==anchor)= 目标。
    public static func displayCached(for window: Window, realCached: Int64) -> Int64 {
        max(0, cachedTarget(for: window) + realCached - anchorRealCached(for: window))
    }

    /// 显示创建 = max(0, 创建目标 + (实时真实创建 − 锚定真实创建))。此刻(real==anchor)= 目标。
    public static func displayNew(for window: Window, realNew: Int64) -> Int64 {
        max(0, newTarget(for: window) + realNew - anchorRealNew(for: window))
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
                ModelTokens(model: "claude-opus-4-8", tokens: 5_778_131_112),
                ModelTokens(model: "gpt-5.6-sol", tokens: 3_863_908_271),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_393_649),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 536_055_804),
                ModelTokens(model: "traex/gpt-5.5", tokens: 94_042_494),
                ModelTokens(model: residualModel, tokens: 81_029_190),
                ModelTokens(model: "gpt-5.6-terra", tokens: 74_363_890),
                ModelTokens(model: "seed-code", tokens: 24_202_484),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "claude-opus-4-7", tokens: 18_073_835),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_073_607),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "claude-opus-5", tokens: 5_670_101),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_049_638),
                ModelTokens(model: "gpt-5.5", tokens: 58_487),
                ModelTokens(model: "gpt-5.4", tokens: 32_894),
                ModelTokens(model: "claude-fable-5", tokens: 620),
            ]
        case .month:
            return [
                ModelTokens(model: "gpt-5.6-sol", tokens: 21_883_778_104),
                ModelTokens(model: "claude-opus-4-8", tokens: 9_893_693_506),
                ModelTokens(model: residualModel, tokens: 2_148_387_200),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_393_649),
                ModelTokens(model: "claude-opus-4-7", tokens: 725_204_653),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 558_941_739),
                ModelTokens(model: "gpt-5.5", tokens: 294_118_010),
                ModelTokens(model: "claude-opus-5", tokens: 135_010_939),
                ModelTokens(model: "traex/gpt-5.5", tokens: 94_113_400),
                ModelTokens(model: "gpt-5.6-terra", tokens: 82_024_857),
                ModelTokens(model: "seed-code", tokens: 24_447_588),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_703_061),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "claude-fable-5", tokens: 3_876_881),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_049_638),
                ModelTokens(model: "model_hub/es1_orange_o48", tokens: 645_984),
                ModelTokens(model: "gpt-5.4", tokens: 32_894),
            ]
        case .all:
            return [
                ModelTokens(model: "gpt-5.6-sol", tokens: 29_089_733_246),
                ModelTokens(model: "gpt-5.5", tokens: 12_942_533_659),
                ModelTokens(model: "claude-opus-4-8", tokens: 11_953_311_304),
                ModelTokens(model: "claude-opus-4-7", tokens: 7_312_994_745),
                ModelTokens(model: residualModel, tokens: 4_093_059_879),
                ModelTokens(model: "doubao-seed-2-0-pro-code-preview-one", tokens: 2_750_424_819),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_393_649),
                ModelTokens(model: "traex/gpt-5.5", tokens: 962_771_062),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 558_941_739),
                ModelTokens(model: "traex/openrouter-3o-max", tokens: 280_712_191),
                ModelTokens(model: "gpt-5.4", tokens: 266_843_150),
                ModelTokens(model: "claude-opus-5", tokens: 135_010_939),
                ModelTokens(model: "openrouter-2o", tokens: 125_483_392),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 107_696_918),
                ModelTokens(model: "traex/openrouter-2o-max", tokens: 103_373_536),
                ModelTokens(model: "gpt-5.6-terra", tokens: 82_024_857),
                ModelTokens(model: "doubao-seed-2-0-pro-preview-260115", tokens: 64_738_141),
                ModelTokens(model: "openrouter-2o-max", tokens: 50_420_295),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 40_565_647),
                ModelTokens(model: "claude-opus-4-6", tokens: 29_720_179),
                ModelTokens(model: "seed-code", tokens: 24_447_588),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "openrouter-1o", tokens: 7_647_164),
                ModelTokens(model: "openrouter-3o-max", tokens: 6_973_886),
                ModelTokens(model: "claude-fable-5", tokens: 3_975_503),
                ModelTokens(model: "gemini-3.1-pro-preview", tokens: 2_603_328),
                ModelTokens(model: "openrouter-3o", tokens: 2_412_075),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_049_638),
                ModelTokens(model: "mira/orange-outstanding-4.7", tokens: 1_300_204),
                ModelTokens(model: "mira/orange-outstanding-4.8", tokens: 669_210),
                ModelTokens(model: "kimi-k2.6", tokens: 651_917),
                ModelTokens(model: "model_hub/es1_orange_o48", tokens: 645_984),
                ModelTokens(model: "claude-haiku-4.5", tokens: 539_013),
                ModelTokens(model: "qwen3.6-plus", tokens: 450_200),
                ModelTokens(model: "opus4.6", tokens: 432_152),
                ModelTokens(model: "gpt-5.2", tokens: 348_930),
                ModelTokens(model: "doubao-seed-2.1-turbo", tokens: 129_280),
                ModelTokens(model: "doubao-seed-2.1-pro", tokens: 85_794),
                ModelTokens(model: "re-o-47", tokens: 6_562),
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
                ModelTokens(model: "claude-opus-4-8", tokens: 3_658_731_085),
                ModelTokens(model: "gpt-5.6-sol", tokens: 2_356_740_896),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_355_696),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 509_163_812),
                ModelTokens(model: residualModel, tokens: 333_800_647),
                ModelTokens(model: "traex/gpt-5.5", tokens: 91_705_119),
                ModelTokens(model: "gpt-5.6-terra", tokens: 45_853_855),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "claude-opus-4-7", tokens: 18_073_835),
                ModelTokens(model: "seed-code", tokens: 13_194_178),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_073_607),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "claude-opus-5", tokens: 5_670_101),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_515_778),
                ModelTokens(model: "claude-fable-5", tokens: 620),
            ]
        case .month:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 4_632_467_665),
                ModelTokens(model: "gpt-5.6-sol", tokens: 2_356_992_804),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_355_696),
                ModelTokens(model: residualModel, tokens: 639_312_114),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 509_421_842),
                ModelTokens(model: "claude-opus-4-7", tokens: 428_638_682),
                ModelTokens(model: "claude-opus-5", tokens: 136_942_154),
                ModelTokens(model: "traex/gpt-5.5", tokens: 91_705_119),
                ModelTokens(model: "gpt-5.6-terra", tokens: 45_853_855),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "seed-code", tokens: 13_194_178),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_703_061),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "claude-fable-5", tokens: 3_932_639),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_515_778),
                ModelTokens(model: "model_hub/es1_orange_o48", tokens: 258_556),
            ]
        case .all:
            return [
                ModelTokens(model: "claude-opus-4-8", tokens: 4_632_467_665),
                ModelTokens(model: "gpt-5.6-sol", tokens: 2_356_992_804),
                ModelTokens(model: "deepseek-v4-flash", tokens: 1_239_355_696),
                ModelTokens(model: residualModel, tokens: 642_413_614),
                ModelTokens(model: "traex/gpt-5.6-sol", tokens: 509_421_842),
                ModelTokens(model: "claude-opus-4-7", tokens: 428_638_682),
                ModelTokens(model: "claude-opus-5", tokens: 136_942_154),
                ModelTokens(model: "traex/gpt-5.5", tokens: 91_768_914),
                ModelTokens(model: "gpt-5.6-terra", tokens: 45_853_855),
                ModelTokens(model: "claude-sonnet-5", tokens: 19_613_237),
                ModelTokens(model: "seed-code", tokens: 13_194_178),
                ModelTokens(model: "claude-haiku-4-5-20251001", tokens: 6_703_061),
                ModelTokens(model: "claude-sonnet-4-6", tokens: 5_693_498),
                ModelTokens(model: "gpt-5.5", tokens: 4_591_182),
                ModelTokens(model: "claude-fable-5", tokens: 3_932_639),
                ModelTokens(model: "gpt-5.6-luna", tokens: 2_515_778),
                ModelTokens(model: "model_hub/es1_orange_o48", tokens: 258_556),
            ]
        }
    }
}
