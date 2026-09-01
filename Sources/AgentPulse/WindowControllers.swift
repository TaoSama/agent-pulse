import AppKit
import AgentPulseCore
import SwiftUI

private enum WindowInteraction {
    static let outsideClickGraceInterval: TimeInterval = 0.35
    /// Dashboard and settings are explicit user actions and must stay above an
    /// open menu-bar surface. Keeping this in one place avoids the two windows
    /// drifting to different levels.
    static let foregroundWindowLevel = NSWindow.Level(
        rawValue: NSWindow.Level.statusBar.rawValue + 1
    )
}

final class FloatingPanel: NSPanel {
    init(frame: NSRect, interactive: Bool = false) {
        super.init(
            contentRect: frame,
            styleMask: interactive ? [.borderless] : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { styleMask.contains(.nonactivatingPanel) == false }
}

@MainActor
final class OrbWindowController {
    private enum Constants {
        static let orbSize = CGSize(width: 48, height: 48)
        static let taskListWidth: CGFloat = 260
        static let taskRowHeight: CGFloat = 38
        static let taskListGap: CGFloat = 8
    }

    private let model: ApplicationModel
    private let panel: FloatingPanel
    private var bubblePanels: [FloatingPanel] = []
    private var dragPointerOffset: NSPoint?
    private var expanded = false
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var ignoreGlobalClicksUntil: TimeInterval = 0
    var onOpenDashboard: (() -> Void)?

    var orbFrame: NSRect { panel.frame }

    init(model: ApplicationModel) {
        self.model = model
        let initial = NSRect(origin: .zero, size: Constants.orbSize)
        panel = FloatingPanel(frame: initial)
        installContent()
        restorePosition()
    }

    func show() { panel.orderFrontRegardless() }

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil); collapse() }
    }

    func repositionForScreenChange() {
        guard !NSScreen.screens.isEmpty else { return }
        let screen = ScreenPlacement.screen(containing: panel.frame.center)
        panel.setFrame(ScreenPlacement.clamped(panel.frame, to: screen), display: true)
        if expanded { layoutBubbles() }
    }

    private func installContent() {
        let host = DraggableHostingView(rootView: OrbView(viewModel: model.orbViewModel))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: Constants.orbSize)
        host.autoresizingMask = [.width, .height]
        // Layer-back the orb so window drags composite independently of the ~1 Hz
        // metrics redraws; otherwise the sparkline repaint contends with
        // setFrameOrigin on the main thread and the orb lags behind the cursor.
        host.wantsLayer = true
        host.layerContentsRedrawPolicy = .onSetNeedsDisplay
        host.onClick = { [weak self] in self?.toggleExpanded() }
        host.onDoubleClick = { [weak self] in self?.openDashboard() }
        host.onRightClick = { [weak self] in self?.openMenuBarPanel() }
        host.onDrag = { [weak self] mouse in self?.drag(to: mouse) }
        host.onDragEnded = { [weak self] in self?.finishDrag() }
        panel.contentView = host
    }

    private func toggleExpanded() {
        expanded ? collapse() : expand()
    }

    private func openDashboard() {
        collapse()
        onOpenDashboard?()
    }

    /// 右击悬浮球打开菜单栏面板：MenuBarExtra 无公开 API，改为定位其 NSStatusItem 的按钮并
    /// 触发一次点击（等价于用户点菜单栏图标）。定位失败时静默降级为展开任务概览，绝不崩溃。
    private func openMenuBarPanel() {
        collapse()
        guard let button = Self.menuBarStatusButton() else {
            // 兜底：找不到菜单栏按钮时至少弹出任务概览，行为可预期。
            expand()
            return
        }
        if let action = button.action {
            NSApp.sendAction(action, to: button.target, from: button)
        } else {
            button.performClick(nil)
        }
    }

    /// 在当前应用的所有窗口里定位 MenuBarExtra 承载的 NSStatusItem 按钮。
    /// MenuBarExtra 的 status item 按钮类型私有，这里按「属于 status bar 窗口的 NSStatusBarButton」启发式匹配。
    private static func menuBarStatusButton() -> NSStatusBarButton? {
        for window in NSApp.windows {
            if let button = window.contentView as? NSStatusBarButton {
                return button
            }
            if let button = firstStatusBarButton(in: window.contentView) {
                return button
            }
        }
        return nil
    }

    private static func firstStatusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let found = firstStatusBarButton(in: subview) { return found }
        }
        return nil
    }

    private func drag(to mouse: NSPoint) {
        if dragPointerOffset == nil {
            // First frame of the gesture: collapse any open bubbles once (not every
            // frame — collapse() mutates @Published state and tears down panels).
            if expanded { collapse() }
            dragPointerOffset = NSPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
        }
        guard let offset = dragPointerOffset else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - offset.x, y: mouse.y - offset.y))
    }

    private func finishDrag() {
        guard dragPointerOffset != nil else { return }
        dragPointerOffset = nil
        let screen = ScreenPlacement.screen(containing: panel.frame.center)
        let frame = ScreenPlacement.clamped(panel.frame, to: screen)
        panel.setFrame(frame, display: true)
        persistPosition(frame: frame, screen: screen)
    }

    private func expand() {
        expanded = true
        model.setOrbExpanded(true)
        ignoreGlobalClicksUntil = ProcessInfo.processInfo.systemUptime
            + WindowInteraction.outsideClickGraceInterval
        rebuildBubblePanels()
        layoutBubbles()
        bubblePanels.forEach { $0.orderFrontRegardless() }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expanded else { return }
            self.startOutsideClickMonitors()
        }
    }

    private func collapse() {
        guard expanded || !bubblePanels.isEmpty else { return }
        expanded = false
        model.setOrbExpanded(false)
        bubblePanels.forEach { $0.orderOut(nil) }
        bubblePanels.removeAll()
        stopOutsideClickMonitors()
    }

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self,
                  ProcessInfo.processInfo.systemUptime >= self.ignoreGlobalClicksUntil else { return }
            self.collapse()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let window = event.window, self.ownsWindow(window) {
                return event
            }
            self.collapse()
            return event
        }
    }

    private func stopOutsideClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    private func ownsWindow(_ window: NSWindow) -> Bool {
        window === panel || bubblePanels.contains { $0 === window }
    }

    private func rebuildBubblePanels() {
        let breakdown = model.taskBreakdown
        let allTasksValue = "\(model.activeTasks.map(String.init) ?? "—") / "
            + "\(model.totalTasksIsLowerBound ? "≥" : "")\(model.totalTasks.map(String.init) ?? "—")"
        let candidates: [(String, RuntimeTaskCategoryMetric, Int)] = [
            ("Codex Desktop", breakdown.codexDesktop, 0),
            ("Codex CLI", breakdown.codexCLI, 1),
            ("Claude CLI", breakdown.claudeCLI, 2),
            ("Claude Desktop", breakdown.claudeDesktop, 3)
        ]
        let items = candidates
            .filter { $0.1.present && ($0.1.activeTasks ?? 0) > 0 }
            .sorted { left, right in
                let leftActive = left.1.activeTasks ?? -1
                let rightActive = right.1.activeTasks ?? -1
                if leftActive != rightActive { return leftActive > rightActive }
                let leftTotal = left.1.totalTasks ?? -1
                let rightTotal = right.1.totalTasks ?? -1
                if leftTotal != rightTotal { return leftTotal > rightTotal }
                return left.2 < right.2
            }
            .map { OrbTaskListItem(title: $0.0, value: CategoryFormatting.value(for: $0.1)) }
        // 气泡内容自测量高度：固定宽 260，渲染完整详情视图后用 fittingSize 取内容高度，
        // 不再按任务行数硬算（因为现在还叠加了 TPS / Token / Top3 三张卡）。
        let host = NSHostingView(rootView: OrbDetailView(model: model, allTasksValue: allTasksValue, items: items))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: CGSize(width: Constants.taskListWidth, height: 10))
        let fittingHeight = host.fittingSize.height
        let size = CGSize(width: Constants.taskListWidth, height: max(fittingHeight, Constants.taskRowHeight))
        let detailPanel = FloatingPanel(frame: NSRect(origin: .zero, size: size))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        detailPanel.contentView = host
        bubblePanels = [detailPanel]
    }

    private func layoutBubbles() {
        guard let screen = panel.screen ?? NSScreen.main,
              let detailPanel = bubblePanels.first else { return }
        // 贴悬浮球一侧展开、不覆盖悬浮球：悬浮球偏左则气泡开在右侧，反之开在左侧；
        // 垂直方向与悬浮球中心对齐，再 clamp 收进屏幕可视区。
        let visible = screen.visibleFrame.insetBy(dx: ScreenPlacement.safeInset, dy: ScreenPlacement.safeInset)
        let size = detailPanel.frame.size
        let opensRight = panel.frame.midX < visible.midX
        let x = opensRight
            ? panel.frame.maxX + Constants.taskListGap
            : panel.frame.minX - Constants.taskListGap - size.width
        // 垂直方向：让气泡顶端高出悬浮球顶端 topOverhang，使悬浮球被气泡在垂直方向包住、
        // 顶部探出；空间不足时 clamp 会自动下压收进可视区。（AppKit y 向上，顶边 = origin.y + height）
        let topOverhang: CGFloat = 100
        let y = panel.frame.maxY + topOverhang - size.height
        let proposed = NSRect(origin: NSPoint(x: x, y: y), size: size)
        detailPanel.setFrame(ScreenPlacement.clamped(proposed, to: screen), display: true)
    }

    private func restorePosition() {
        let savedID = UserDefaults.standard.object(forKey: "orb.screenID") as? UInt32
        let savedScreen = NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return number.uint32Value == savedID
        }
        guard let screen = savedScreen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: ScreenPlacement.safeInset, dy: ScreenPlacement.safeInset)
        let x = UserDefaults.standard.object(forKey: "orb.normalizedX") as? Double ?? 1
        let y = UserDefaults.standard.object(forKey: "orb.normalizedY") as? Double ?? 0.72
        let frame = NSRect(
            x: visible.minX + CGFloat(x) * max(0, visible.width - Constants.orbSize.width),
            y: visible.minY + CGFloat(y) * max(0, visible.height - Constants.orbSize.height),
            width: Constants.orbSize.width,
            height: Constants.orbSize.height
        )
        panel.setFrame(ScreenPlacement.clamped(frame, to: screen), display: false)
    }

    private func persistPosition(frame: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame.insetBy(dx: ScreenPlacement.safeInset, dy: ScreenPlacement.safeInset)
        let x = (frame.minX - visible.minX) / max(1, visible.width - frame.width)
        let y = (frame.minY - visible.minY) / max(1, visible.height - frame.height)
        UserDefaults.standard.set(Double(x), forKey: "orb.normalizedX")
        UserDefaults.standard.set(Double(y), forKey: "orb.normalizedY")
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            UserDefaults.standard.set(number.uint32Value, forKey: "orb.screenID")
        }
    }
}

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    private let model: ApplicationModel
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var ignoreGlobalClicksUntil: TimeInterval = 0

    init(model: ApplicationModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Pulse · TPS Charts"
        window.level = WindowInteraction.foregroundWindowLevel
        // Elevated windows do not reliably resign key status when another app
        // is clicked. Let AppKit hide the dashboard on app deactivation, while
        // the event monitors below continue to handle clicks inside this app.
        window.hidesOnDeactivate = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: TPSDashboardView(model: model))
        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func show(anchoredTo frame: NSRect? = nil) {
        guard let window else { return }
        // 每次打开都重建根视图，让 TPSDashboardView 的 @State（时间跨度）复位到默认，
        // 不记忆上次选择。
        window.contentView = NSHostingView(rootView: TPSDashboardView(model: model))
        let targetPoint = frame?.center ?? NSEvent.mouseLocation
        let screen = ScreenPlacement.screen(containing: targetPoint)
        window.setFrame(ScreenPlacement.centered(window.frame.size, on: screen), display: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ignoreGlobalClicksUntil = ProcessInfo.processInfo.systemUptime
            + WindowInteraction.outsideClickGraceInterval
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.startOutsideClickMonitors()
        }
    }

    func windowWillClose(_ notification: Notification) {
        stopOutsideClickMonitors()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard window?.isVisible == true else { return }
        dismiss()
    }

    @objc private func applicationDidResignActive() {
        guard window?.isVisible == true else { return }
        dismiss()
    }

    private func startOutsideClickMonitors() {
        stopOutsideClickMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self,
                  ProcessInfo.processInfo.systemUptime >= self.ignoreGlobalClicksUntil else { return }
            self.dismiss()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window === self.window { return event }
            self.dismiss()
            return event
        }
    }

    private func stopOutsideClickMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }

    private func dismiss() {
        stopOutsideClickMonitors()
        window?.orderOut(nil)
    }
}

@MainActor
final class ToastWindowController {
    private let model: ApplicationModel
    private let panel = FloatingPanel(frame: NSRect(x: 0, y: 0, width: 460, height: 86), interactive: true)
    private var anchor: NSRect?
    private var dismissTask: Task<Void, Never>?
    private var shownAt: ContinuousClock.Instant?
    private var remaining = Duration.seconds(3)
    private var autoDismiss = false

    init(model: ApplicationModel) { self.model = model }

    func show(_ state: ToastState, anchoredTo frame: NSRect?) {
        dismissTask?.cancel()
        anchor = frame
        autoDismiss = if case .success = state { true } else { false }
        remaining = .seconds(3)
        panel.contentView = NSHostingView(rootView: UploadToastView(
            state: state,
            copy: { [weak self] url in self?.model.copyURL(url) },
            close: { [weak self] in self?.close() },
            hover: { [weak self] hovering in self?.setPaused(hovering) }
        ))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 460, height: 86))
        repositionForScreenChange()
        panel.orderFrontRegardless()
        if autoDismiss { scheduleDismiss() }
    }

    func repositionForScreenChange() {
        guard !NSScreen.screens.isEmpty else { return }
        let targetPoint = anchor?.center ?? NSEvent.mouseLocation
        let screen = ScreenPlacement.screen(containing: targetPoint)
        let visible = screen.visibleFrame.insetBy(dx: ScreenPlacement.safeInset, dy: ScreenPlacement.safeInset)
        let proposed: NSRect
        if let anchor {
            proposed = NSRect(x: anchor.midX - panel.frame.width / 2, y: anchor.maxY + 10, width: panel.frame.width, height: panel.frame.height)
        } else {
            proposed = NSRect(x: visible.maxX - panel.frame.width, y: visible.maxY - panel.frame.height, width: panel.frame.width, height: panel.frame.height)
        }
        panel.setFrame(ScreenPlacement.clamped(proposed, to: screen), display: true)
    }

    private func setPaused(_ paused: Bool) {
        guard autoDismiss else { return }
        if paused {
            if let shownAt {
                remaining -= min(remaining, ContinuousClock.now - shownAt)
            }
            dismissTask?.cancel()
        } else {
            scheduleDismiss()
        }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        shownAt = .now
        let delay = remaining
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        dismissTask?.cancel()
        dismissTask = nil
        panel.orderOut(nil)
    }
}

private extension NSRect {
    var center: NSPoint { NSPoint(x: midX, y: midY) }
}


final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    private var isDragging = false
    private var pendingClickCount = 0
    private var pendingSingleClick: DispatchWorkItem?
    private let dragThreshold: CGFloat = 4
    /// 单击判定延迟：等待此时长内若无第二次点击则视为单击。
    /// 固定 150ms（不用系统 doubleClickInterval，那个偏长导致单击响应迟钝）。
    private let clickResolutionDelay: TimeInterval = 0.15
    private var mouseDownLocation: NSPoint?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = false
        pendingClickCount = event.clickCount
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
        }
        mouseDownLocation = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        if !isDragging, let start = mouseDownLocation {
            let moved = hypot(current.x - start.x, current.y - start.y)
            guard moved >= dragThreshold else { return }
            isDragging = true
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
        }
        onDrag?(current)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            pendingClickCount = 0
        }
        if isDragging {
            isDragging = false
            onDragEnded?()
            return
        }
        if pendingClickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick?()
        } else if pendingClickCount == 1 {
            pendingSingleClick?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.pendingSingleClick = nil
                self?.onClick?()
            }
            pendingSingleClick = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + clickResolutionDelay,
                execute: work
            )
        }
    }
}
