import AppKit
import SwiftUI

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ApplicationModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarSummaryView(model: model)
        } label: {
            MenuBarPulseLabel(model: model)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    model.showSettings?()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var shell: AppShellController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let shell = AppShellController(model: .shared)
        self.shell = shell
        shell.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        shell?.stop()
    }
}
