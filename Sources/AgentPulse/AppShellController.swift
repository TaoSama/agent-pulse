import AppKit
import Foundation

@MainActor
final class AppShellController {
    private let model: ApplicationModel
    private let orbController: OrbWindowController
    private let dashboardController: DashboardWindowController
    private let toastController: ToastWindowController
    private let settingsController: SettingsWindowController
    private let screenCoordinator = ScreenCoordinator()
    private let hotKey = HotKeyService()

    init(model: ApplicationModel) {
        self.model = model
        orbController = OrbWindowController(model: model)
        dashboardController = DashboardWindowController(model: model)
        toastController = ToastWindowController(model: model)
        settingsController = SettingsWindowController(model: model)
        model.showDashboard = { [weak self] in self?.showDashboard() }
        model.showOrb = { [weak orbController] visible in orbController?.setVisible(visible) }
        model.showToast = { [weak self] state in
            guard let self else { return }
            toastController.show(state, anchoredTo: orbAnchor)
        }
        model.showSettings = { [weak settingsController] in settingsController?.show() }
        orbController.onOpenDashboard = { [weak self] in self?.showDashboard() }
    }

    func start() {
        model.start()
        orbController.show()
        hotKey.onTrigger = { [weak model] in model?.uploadClipboard() }
        let registered: Bool
        switch hotKey.start() {
        case .success: registered = true
        case .failure: registered = false
        }
        model.setHotKeyRegistration(registered)
        screenCoordinator.start { [weak orbController, weak toastController] in
            orbController?.repositionForScreenChange()
            toastController?.repositionForScreenChange()
        }
    }

    func stop() {
        hotKey.stop()
        screenCoordinator.stop()
        model.stop()
    }

    private var orbAnchor: NSRect? {
        model.isOrbVisible ? orbController.orbFrame : nil
    }

    private func showDashboard() {
        dashboardController.show(anchoredTo: orbAnchor)
    }
}

@MainActor
final class ScreenCoordinator {
    private var observer: NSObjectProtocol?

    func start(onChange: @escaping @MainActor () -> Void) {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in MainActor.assumeIsolated { onChange() } }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

enum ScreenPlacement {
    static let safeInset: CGFloat = 8

    static func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func clamped(_ frame: NSRect, to screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame.insetBy(dx: safeInset, dy: safeInset)
        return NSRect(
            x: min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width)),
            y: min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height)),
            width: frame.width,
            height: frame.height
        )
    }

    static func centered(_ size: NSSize, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let proposed = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return clamped(proposed, to: screen)
    }
}
