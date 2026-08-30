import SwiftUI

/// 把阶跃到达的真实扫描进度缓动为展示进度。
///
/// 只在追赶新的真实目标时运行帧驱动；追平、扫描结束或视图离开后立即停帧。
/// 真实进度停滞时不自行推进，避免菜单、卡片和悬浮球长期触发主线程重布局。
@MainActor
package final class ScanProgressSmoother: ObservableObject {
    @Published package private(set) var displayed: Double = 0

    private var target: Double = 0
    private var ticker: Timer?

    private let easing = 0.18
    private let minStepPerTick = 0.00005
    private let tickInterval: TimeInterval
    private let resetDropThreshold = 0.05

    package init(tickInterval: TimeInterval = 1.0 / 30.0) {
        self.tickInterval = tickInterval
    }

    /// 当前是否仍在追赶真实进度；UI 用它停止无意义的持续旋转，verification 用它检查生命周期。
    package var isAnimating: Bool {
        ticker != nil
    }

    /// `value == nil` 表示扫描结束。
    package func setTarget(_ value: Double?) {
        guard let value else {
            stop()
            target = 0
            if displayed != 0 {
                displayed = 0
            }
            return
        }

        let clamped = min(max(value, 0), 1)
        if clamped + resetDropThreshold < target, displayed != 0 {
            displayed = 0
        }
        target = clamped

        if displayed < target {
            start()
        } else {
            stop()
        }
    }

    /// 视图离开层级时停止帧驱动；保留展示值供同一实例再次出现时继续使用。
    package func cancelAnimation() {
        stop()
    }

    private func start() {
        guard ticker == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stop() {
        ticker?.invalidate()
        ticker = nil
    }

    private func step() {
        guard displayed < target else {
            stop()
            return
        }

        let remaining = target - displayed
        let advance = max(remaining * easing, min(minStepPerTick, remaining))
        let next = min(displayed + advance, target)
        if next != displayed {
            displayed = next
        }
        if displayed >= target {
            stop()
        }
    }

    isolated deinit {
        ticker?.invalidate()
    }
}

package extension View {
    /// 用真实扫描状态驱动平滑器，并在视图离开层级时立即停帧。
    func scanProgressAnimation(
        _ smoother: ScanProgressSmoother,
        progress: Double?,
        isRunning: Bool
    ) -> some View {
        onAppear {
            smoother.setTarget(isRunning ? progress : nil)
        }
        .onChange(of: progress) { _, newValue in
            smoother.setTarget(isRunning ? newValue : nil)
        }
        .onChange(of: isRunning) { _, running in
            smoother.setTarget(running ? progress : nil)
        }
        .onDisappear {
            smoother.cancelAnimation()
        }
    }
}
