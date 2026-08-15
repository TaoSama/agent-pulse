import Foundation

// Sparkline 分析：把最近一段窗口内的 LiveRateSample 转换成可绘制的实时 TPS 曲线，
// 并给出趋势方向。所有对外类型与方法均为纯函数（无 I/O、无全局状态、无隐式当前时间依赖），
// 以便在无 XCTest 的 CoreVerification 与真实 UI 中共享同一套逻辑。
//
// 设计约束（与数据口径一致）：
// - 只接受 state == .live/.zero 且 tps 为有限非负数值的样本；其余状态一律视为缺口。
// - 原始缺口仍用 nil 表达；绘图管线会用相邻有效 TPS 插值补齐，再做轻量平滑。
// - 窗口边缘缺口使用最近有效值延展，保证悬浮球和看板展示连续曲线。
// - 归一化对异常值稳健（分位裁剪后再线性映射），但趋势回归始终使用未裁剪的真实值。
// - 趋势用最近窗口的最小二乘线性回归；显著性用“归一化斜率”阈值判定，抗噪声。

/// 单个重采样后的曲线点。
///
/// `value` 为该时间步的真实 TPS（tokens/second），`nil` 表示缺口（无有效数据）。
/// `normalized` 为绘图用的 0...1 归一化值，仅在 `value != nil` 时有意义。
public struct SparklinePoint: Sendable, Equatable {
    /// 该时间步的中心时间（重采样栅格上的固定时刻）。
    public let time: Date
    /// 真实 TPS；缺口为 nil。
    public let value: Double?
    /// 归一化到 0...1 的绘图值；缺口为 nil。
    public let normalized: Double?

    public init(time: Date, value: Double?, normalized: Double?) {
        self.time = time
        self.value = value
        self.normalized = normalized
    }

    /// 是否为缺口点。
    public var isGap: Bool { value == nil }
}

/// 趋势方向分类。
public enum SparklineTrend: String, Sendable, Equatable, CaseIterable {
    /// 显著上升（绿色）。
    case rising
    /// 显著下降（红色）。
    case falling
    /// 处于死区，视为横盘（系统中性色）。
    case flat
    /// 数据不足以判定（少于 2 个有效点）。
    case insufficient
}

/// 平滑算法选择。
public enum SparklineSmoothingKernel: Sendable, Equatable {
    /// 高斯核，`radius` 为半径（点数），有效窗口大小为 2*radius+1，限制在 3...7 点。
    case gaussian(radius: Int)
    /// 指数移动平均，`alpha` 为 0<alpha<=1 的平滑系数。
    case exponentialMovingAverage(alpha: Double)
}

/// 趋势回归结果。
public struct SparklineRegression: Sendable, Equatable {
    /// 最小二乘斜率，单位为 TPS/秒（可正可负）。数据不足时为 nil。
    public let slopePerSecond: Double?
    /// “斜率 * 窗口秒数 / 参考基准”得到的无量纲归一化斜率，用于显著性判定。数据不足时为 nil。
    public let normalizedSlope: Double?
    /// 参与回归的有效点数。
    public let sampleCount: Int
    /// 分类后的趋势方向。
    public let trend: SparklineTrend

    public init(slopePerSecond: Double?, normalizedSlope: Double?, sampleCount: Int, trend: SparklineTrend) {
        self.slopePerSecond = slopePerSecond
        self.normalizedSlope = normalizedSlope
        self.sampleCount = sampleCount
        self.trend = trend
    }
}

/// Sparkline 纯函数命名空间。
public enum SparklineAnalysis {
    // MARK: - 常量（禁止魔法值）

    /// 默认窗口：最近 15 分钟统一口径。
    public static let defaultWindowSeconds: TimeInterval = 15 * 60
    /// 默认重采样步长：1 秒（与底层 1 秒样本一致）。
    public static let defaultStepSeconds: TimeInterval = 1
    /// 允许的最小/最大平滑窗口（点数），对应“3-7 点”。
    public static let minSmoothingWindow = 3
    public static let maxSmoothingWindow = 7
    /// 归一化时的分位裁剪比例（两端各裁掉这一比例的极值以抗异常值）。
    public static let normalizationClipQuantile = 0.10
    /// 显著下降阈值：平滑回归后的端到端变化低于 -30% 才判为下降。
    /// -30% 以内的下降视为横盘；任意正增长仍按上升处理。
    public static let significantDeclineThreshold = -0.30
    /// 归一化斜率的参考基准下限，避免基准过小导致斜率被放大成噪声。
    public static let trendReferenceFloor = 0.5
    /// 归一化斜率的展示/判定上下界（±100%）。首尾线性拟合的斜率乘以时间跨度可远超基准
    /// （尤其锯齿末端落在断崖低位时），得到 -140% 这类越界值。相对基准的变化率超过 ±100%
    /// 在展示上无意义，统一钳到 [-1, 1]：既消除越界，又不改动死区阈值（仍落在界内）。
    public static let normalizedSlopeBound = 1.0

    // MARK: - 过滤

    /// 从原始样本中提取“可用数值”，其余状态转成缺口标记（保留时间戳）。
    ///
    /// 只有 `.live` / `.zero` 且 `tps` 为有限非负数才算有效值；
    /// `.stale` / `.noData` / `.unavailable` 或非有限/负值一律标为缺口（value == nil）。
    public static func numericSeries(from samples: [LiveRateSample]) -> [(time: Date, value: Double?)] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { sample in
                switch sample.state {
                case .live, .zero:
                    if let tps = sample.tps, tps.isFinite, tps >= 0 {
                        return (sample.timestamp, tps)
                    }
                    return (sample.timestamp, nil)
                case .stale, .noData, .unavailable:
                    return (sample.timestamp, nil)
                }
            }
    }

    /// 看板专用：每点为该时刻前 5s 滑窗的真实速率（tokensInShortWindow / 5）。
    /// 旧库样本无 short 值时回退用 180s 口径（tps）保底，避免历史点全空。
    public static func shortWindowSeries(from samples: [LiveRateSample]) -> [(time: Date, value: Double?)] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { sample in
                switch sample.state {
                case .live, .zero:
                    if let short = sample.tokensInShortWindow, short.isFinite, short >= 0 {
                        return (sample.timestamp, short / Double(LiveRateSample.shortWindowSeconds))
                    }
                    // 旧库无 short：回退 180s 口径，保证历史曲线仍有值。
                    if let tps = sample.tps, tps.isFinite, tps >= 0 {
                        return (sample.timestamp, tps)
                    }
                    return (sample.timestamp, nil)
                case .stale, .noData, .unavailable:
                    return (sample.timestamp, nil)
                }
            }
    }

    /// 看板分模型专用：单模型该时刻前 5s 滑窗真实速率；旧库无 short 时回退 180s 口径。
    public static func shortWindowSeries(
        from samples: [LiveRateSample],
        model: String
    ) -> [(time: Date, value: Double?)] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { sample in
                switch sample.state {
                case .live, .zero:
                    if sample.tokensInShortWindow != nil {
                        let tokens = sample.modelTokensInShortWindow[model] ?? 0
                        let tps = tokens / Double(LiveRateSample.shortWindowSeconds)
                        return (sample.timestamp, tps.isFinite && tps >= 0 ? tps : nil)
                    }
                    let tokens = sample.modelTokensInWindow[model] ?? 0
                    let tps = tokens / Double(LiveRateSample.windowSeconds)
                    return (sample.timestamp, tps.isFinite && tps >= 0 ? tps : nil)
                case .stale, .noData, .unavailable:
                    return (sample.timestamp, nil)
                }
            }
    }

    /// 从持久化的实时样本提取单个模型的 TPS 序列。
    /// 模型未出现在某个可用样本中代表该秒窗口贡献为 0；不可用状态仍保留为缺口。
    public static func numericSeries(
        from samples: [LiveRateSample],
        model: String
    ) -> [(time: Date, value: Double?)] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { sample in
                switch sample.state {
                case .live, .zero:
                    let tokens = sample.modelTokensInWindow[model] ?? 0
                    let tps = tokens / Double(LiveRateSample.windowSeconds)
                    return (sample.timestamp, tps.isFinite && tps >= 0 ? tps : nil)
                case .stale, .noData, .unavailable:
                    return (sample.timestamp, nil)
                }
            }
    }

    // MARK: - 重采样

    /// 按固定时间步把样本重采样到规整栅格；不跨缺口造数。
    ///
    /// - 栅格覆盖 [end - windowSeconds, end]，步长 stepSeconds。
    /// - 每个栅格点取“落在该步长桶内、时间最接近栅格中心的有效值”；
    ///   桶内没有有效值则为缺口（nil）。不会前向/后向填充跨越缺口。
    /// - end 传 nil 时使用样本中最大的时间戳；无样本返回空数组。
    public static func resample(
        _ samples: [LiveRateSample],
        end: Date? = nil,
        windowSeconds: TimeInterval = defaultWindowSeconds,
        stepSeconds: TimeInterval = defaultStepSeconds
    ) -> [SparklinePoint] {
        resampleSeries(numericSeries(from: samples), end: end, windowSeconds: windowSeconds, stepSeconds: stepSeconds)
    }

    /// 底层重采样：接受已提取的 (time, value?) 序列，按固定时间步归并到规整栅格。
    /// 供总/分模型、180s/5s 各种口径复用（提取器不同，栅格逻辑一致）。
    public static func resampleSeries(
        _ series: [(time: Date, value: Double?)],
        end: Date? = nil,
        windowSeconds: TimeInterval = defaultWindowSeconds,
        stepSeconds: TimeInterval = defaultStepSeconds
    ) -> [SparklinePoint] {
        guard stepSeconds > 0, windowSeconds > 0 else { return [] }
        guard let lastTime = end ?? series.last?.time else { return [] }

        let start = lastTime.addingTimeInterval(-windowSeconds)
        // 只保留窗口内的有效值，按桶归并（取离栅格中心最近者）。
        var bucketBest: [Int: (distance: TimeInterval, value: Double)] = [:]
        for point in series {
            guard let value = point.value else { continue }
            let offset = point.time.timeIntervalSince(start)
            guard offset >= 0, point.time <= lastTime else { continue }
            let index = Int((offset / stepSeconds).rounded(.toNearestOrAwayFromZero))
            let center = start.addingTimeInterval(Double(index) * stepSeconds)
            let distance = abs(point.time.timeIntervalSince(center))
            if let existing = bucketBest[index], existing.distance <= distance { continue }
            bucketBest[index] = (distance, value)
        }

        let stepCount = Int((windowSeconds / stepSeconds).rounded(.toNearestOrAwayFromZero))
        var points: [SparklinePoint] = []
        points.reserveCapacity(stepCount + 1)
        for index in 0...stepCount {
            let center = start.addingTimeInterval(Double(index) * stepSeconds)
            points.append(SparklinePoint(time: center, value: bucketBest[index]?.value, normalized: nil))
        }
        return points
    }

    // MARK: - 平滑

    /// 分段轻量平滑：仅在连续（无缺口）子段内做平滑，缺口原样保留。
    ///
    /// 高斯核窗口大小被夹到 [minSmoothingWindow, maxSmoothingWindow] 且为奇数；
    /// EMA 的 alpha 会被夹到 (0, 1]。任何非有限值都会被当作缺口跳过。
    public static func smooth(
        _ points: [SparklinePoint],
        kernel: SparklineSmoothingKernel = .gaussian(radius: 2)
    ) -> [SparklinePoint] {
        guard !points.isEmpty else { return [] }
        var result = points

        // 找连续有效子段（value != nil 且有限）并分段平滑。
        var segmentStart: Int? = nil
        func flush(_ endExclusive: Int) {
            defer { segmentStart = nil }
            guard let begin = segmentStart, endExclusive - begin > 0 else { return }
            let rawValues = points[begin..<endExclusive].compactMap { $0.value }
            guard rawValues.count == endExclusive - begin else { return }
            let smoothed: [Double]
            switch kernel {
            case let .gaussian(radius):
                smoothed = gaussianSmooth(rawValues, radius: radius)
            case let .exponentialMovingAverage(alpha):
                smoothed = emaSmooth(rawValues, alpha: alpha)
            }
            for (offset, value) in smoothed.enumerated() {
                let index = begin + offset
                result[index] = SparklinePoint(time: points[index].time, value: value, normalized: nil)
            }
        }

        for (index, point) in points.enumerated() {
            let isValid = (point.value?.isFinite ?? false)
            if isValid {
                if segmentStart == nil { segmentStart = index }
            } else {
                flush(index)
            }
        }
        flush(points.count)
        return result
    }

    /// 为绘图补齐重采样序列中的缺口。
    ///
    /// - 内部缺口在左右有效值之间按时间位置线性插值。
    /// - 窗口开头/结尾缺口使用最近有效值延展。
    /// - 完全没有有效值时保持原样，避免凭空制造 TPS。
    public static func interpolateGaps(_ points: [SparklinePoint]) -> [SparklinePoint] {
        guard !points.isEmpty else { return [] }
        let validIndices = points.indices.filter { index in
            guard let value = points[index].value else { return false }
            return value.isFinite && value >= 0
        }
        guard let first = validIndices.first, let last = validIndices.last else { return points }

        var result = points
        let firstValue = points[first].value!
        if first > points.startIndex {
            for index in points.startIndex..<first {
                result[index] = SparklinePoint(time: points[index].time, value: firstValue, normalized: nil)
            }
        }

        for pairIndex in 0..<max(0, validIndices.count - 1) {
            let left = validIndices[pairIndex]
            let right = validIndices[pairIndex + 1]
            guard right - left > 1 else { continue }
            let leftValue = points[left].value!
            let rightValue = points[right].value!
            let width = Double(right - left)
            for index in (left + 1)..<right {
                let fraction = Double(index - left) / width
                let value = leftValue + (rightValue - leftValue) * fraction
                result[index] = SparklinePoint(time: points[index].time, value: value, normalized: nil)
            }
        }

        let lastValue = points[last].value!
        if last < points.index(before: points.endIndex) {
            for index in (last + 1)..<points.endIndex {
                result[index] = SparklinePoint(time: points[index].time, value: lastValue, normalized: nil)
            }
        }
        return result
    }

    /// 一维离散高斯平滑；窗口被夹到 [min,max] 且为奇数。调用方按段传入连续值。
    static func gaussianSmooth(_ values: [Double], radius: Int) -> [Double] {
        guard !values.isEmpty else { return [] }
        // 期望窗口 2*radius+1，夹到允许范围并保持奇数。
        var window = 2 * max(0, radius) + 1
        window = min(max(window, minSmoothingWindow), maxSmoothingWindow)
        if window % 2 == 0 { window -= 1 }
        let effectiveRadius = window / 2
        if effectiveRadius == 0 || values.count == 1 { return values }

        // 高斯权重，sigma 取 radius/2，保证核轻量。
        let sigma = max(0.5, Double(effectiveRadius) / 2.0)
        var weights: [Double] = []
        for offset in -effectiveRadius...effectiveRadius {
            let x = Double(offset)
            weights.append(exp(-(x * x) / (2 * sigma * sigma)))
        }

        var output: [Double] = []
        output.reserveCapacity(values.count)
        for i in values.indices {
            var acc = 0.0
            var weightSum = 0.0
            for (wIndex, offset) in (-effectiveRadius...effectiveRadius).enumerated() {
                let j = i + offset
                guard j >= 0, j < values.count else { continue } // 段内边界收缩，不跨段借值
                let w = weights[wIndex]
                acc += values[j] * w
                weightSum += w
            }
            output.append(weightSum > 0 ? acc / weightSum : values[i])
        }
        return output
    }

    /// 指数移动平均；alpha 夹到 (0,1]。
    static func emaSmooth(_ values: [Double], alpha: Double) -> [Double] {
        guard !values.isEmpty else { return [] }
        let a = min(max(alpha, Double.leastNonzeroMagnitude), 1)
        var output: [Double] = []
        output.reserveCapacity(values.count)
        var previous = values[0]
        output.append(previous)
        for value in values.dropFirst() {
            previous = a * value + (1 - a) * previous
            output.append(previous)
        }
        return output
    }

    // MARK: - 归一化

    /// 对曲线做 0...1 归一化，缺口保持缺口。
    ///
    /// 为抗异常值，用分位裁剪确定 [low, high] 后再线性映射并夹到 0...1；
    /// 单个极端值不会把整条曲线压扁。裁剪只影响“显示归一化”，不影响真实 value 与趋势回归。
    public static func normalize(
        _ points: [SparklinePoint],
        clipQuantile: Double = normalizationClipQuantile
    ) -> [SparklinePoint] {
        let finiteValues = points.compactMap { point -> Double? in
            guard let value = point.value, value.isFinite else { return nil }
            return value
        }
        guard !finiteValues.isEmpty else { return points }

        let sorted = finiteValues.sorted()
        let clip = min(max(clipQuantile, 0), 0.49)
        let low = quantile(sorted, clip)
        let high = quantile(sorted, 1 - clip)
        let span = high - low

        return points.map { point in
            guard let value = point.value, value.isFinite else {
                return SparklinePoint(time: point.time, value: point.value, normalized: nil)
            }
            let normalized: Double
            if span <= 0 {
                // 所有值几乎相同（含横盘）：映射到中线，避免除零和视觉噪声。
                normalized = 0.5
            } else {
                normalized = min(max((value - low) / span, 0), 1)
            }
            return SparklinePoint(time: point.time, value: value, normalized: normalized)
        }
    }

    /// 线性插值分位数；sorted 必须已升序且非空。
    public static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        if sorted.count == 1 { return first }
        let clamped = min(max(q, 0), 1)
        let position = clamped * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        if lowerIndex == upperIndex { return sorted[lowerIndex] }
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - fraction) + sorted[upperIndex] * fraction
    }

    // MARK: - 趋势回归

    /// 对窗口内有效点做最小二乘线性回归并分类趋势。
    ///
    /// - 使用真实 value（非归一化、非裁剪），x 轴用相对秒数以保证数值稳定。
    /// - 少于 2 个有效点 → insufficient。
    /// - 归一化斜率 = 斜率 * 时间跨度 / max(参考基准, trendReferenceFloor)，
    ///   其中参考基准取有效值均值的绝对值；据此与死区阈值比较，抗噪声、可测试。
    public static func regression(_ points: [SparklinePoint]) -> SparklineRegression {
        let valid = points.compactMap { point -> (t: Double, v: Double)? in
            guard let value = point.value, value.isFinite else { return nil }
            return (point.time.timeIntervalSinceReferenceDate, value)
        }
        guard valid.count >= 2 else {
            return SparklineRegression(slopePerSecond: nil, normalizedSlope: nil, sampleCount: valid.count, trend: .insufficient)
        }

        // 以首个时间为原点，减小浮点误差。
        let t0 = valid[0].t
        let xs = valid.map { $0.t - t0 }
        let ys = valid.map { $0.v }
        let n = Double(valid.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let meanX = sumX / n
        let meanY = sumY / n

        var numerator = 0.0
        var denominator = 0.0
        for i in valid.indices {
            let dx = xs[i] - meanX
            numerator += dx * (ys[i] - meanY)
            denominator += dx * dx
        }
        guard denominator > 0, numerator.isFinite else {
            // 所有点时间相同（栅格唯一，理论上不会）：无法定义斜率，视为横盘。
            return SparklineRegression(slopePerSecond: 0, normalizedSlope: 0, sampleCount: valid.count, trend: .flat)
        }

        let slope = numerator / denominator
        let timeSpan = xs.last! - xs.first!
        let reference = max(abs(meanY), trendReferenceFloor)
        let rawNormalizedSlope = (slope * timeSpan) / reference
        guard rawNormalizedSlope.isFinite else {
            return SparklineRegression(slopePerSecond: slope, normalizedSlope: nil, sampleCount: valid.count, trend: .flat)
        }
        // 钳到 ±100%：相对基准的变化率超过整倍在展示上无意义，避免 -140% 这类越界值。
        let normalizedSlope = min(max(rawNormalizedSlope, -normalizedSlopeBound), normalizedSlopeBound)

        let trend: SparklineTrend
        if normalizedSlope > 0 {
            trend = .rising
        } else if normalizedSlope < significantDeclineThreshold {
            trend = .falling
        } else {
            trend = .flat
        }
        return SparklineRegression(
            slopePerSecond: slope,
            normalizedSlope: normalizedSlope,
            sampleCount: valid.count,
            trend: trend
        )
    }

    // MARK: - 一站式管线

    /// 端到端渲染数据：重采样 → 平滑 → 归一化，并返回趋势回归。
    ///
    /// 双通道语义（看板要真实、菜单要平滑）：
    /// - `SparklinePoint.value` 保留**原始重采样真实值**（缺口 nil，绝不跨缺口插值）——供看板如实绘制真实 TPS。
    /// - `SparklinePoint.normalized` 为「插值补缺 + 高斯平滑 + 归一化」后的 0…1 值——供菜单栏小图与悬浮球看趋势。
    /// 趋势回归基于「重采样+平滑但未归一化」的值，避免视觉裁剪影响趋势判定。
    public static func makeSparkline(
        from samples: [LiveRateSample],
        end: Date? = nil,
        windowSeconds: TimeInterval = defaultWindowSeconds,
        stepSeconds: TimeInterval = defaultStepSeconds,
        kernel: SparklineSmoothingKernel = .gaussian(radius: 2)
    ) -> (points: [SparklinePoint], regression: SparklineRegression) {
        let resampled = resample(samples, end: end, windowSeconds: windowSeconds, stepSeconds: stepSeconds)
        let interpolated = interpolateGaps(resampled)
        let smoothed = smooth(interpolated, kernel: kernel)
        let originalValidCount = resampled.lazy.filter { $0.value != nil }.count
        let regressionResult = originalValidCount >= 2 ? regression(smoothed) : regression(resampled)
        let normalizedSmoothed = normalize(smoothed)
        // 合并双通道：value 用原始真实值（缺口 nil、不插值），normalized 用平滑归一化值。
        let points = zip(resampled, normalizedSmoothed).map { raw, smooth in
            SparklinePoint(time: raw.time, value: raw.value, normalized: smooth.normalized)
        }
        return (points, regressionResult)
    }

    /// 看板专用总曲线：每点为该秒前 5s 滑窗真实速率，缺口断开，不插值/不平滑/不归一化。
    /// 点粒度仍为每秒一点（step=1s），只是每点的值取自 5s 滑窗（形态更贴近瞬时、可加）。
    public static func makeDashboardSparkline(
        from samples: [LiveRateSample],
        end: Date? = nil,
        windowSeconds: TimeInterval = defaultWindowSeconds,
        stepSeconds: TimeInterval = defaultStepSeconds
    ) -> [SparklinePoint] {
        resampleSeries(shortWindowSeries(from: samples), end: end, windowSeconds: windowSeconds, stepSeconds: stepSeconds)
    }

    /// 看板专用分模型曲线：单模型每点为该秒前 5s 滑窗真实速率，缺口断开，不插值/不平滑。
    public static func makeDashboardModelSparkline(
        from samples: [LiveRateSample],
        model: String,
        end: Date? = nil,
        windowSeconds: TimeInterval = defaultWindowSeconds,
        stepSeconds: TimeInterval = defaultStepSeconds
    ) -> [SparklinePoint] {
        resampleSeries(shortWindowSeries(from: samples, model: model), end: end, windowSeconds: windowSeconds, stepSeconds: stepSeconds)
    }

    /// 为单个模型生成与总曲线相同时间栅格、插值和平滑规则的曲线。
    public static func makeModelSparkline(
        from samples: [LiveRateSample],
        model: String,
        end: Date? = nil,
        windowSeconds: TimeInterval = defaultWindowSeconds,
        stepSeconds: TimeInterval = defaultStepSeconds,
        kernel: SparklineSmoothingKernel = .gaussian(radius: 2)
    ) -> [SparklinePoint] {
        let modelSamples = samples.map { sample in
            let tokens = sample.state == .live || sample.state == .zero
                ? sample.modelTokensInWindow[model] ?? 0
                : nil
            return LiveRateSample(
                timestamp: sample.timestamp,
                state: sample.state,
                tokensInWindow: tokens,
                latestSignalAt: sample.latestSignalAt
            )
        }
        return makeSparkline(
            from: modelSamples,
            end: end,
            windowSeconds: windowSeconds,
            stepSeconds: stepSeconds,
            kernel: kernel
        ).points
    }
}
