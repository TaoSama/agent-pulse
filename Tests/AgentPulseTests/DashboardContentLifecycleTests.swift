import AppKit
import XCTest
@testable import AgentPulse

@MainActor
final class DashboardContentLifecycleTests: XCTestCase {
    func testInitiallyHiddenDashboardDoesNotCreateContent() {
        _ = NSApplication.shared
        var creations = 0
        let controller = DashboardWindowController(makeContentView: {
            creations += 1
            return NSView()
        })
        XCTAssertEqual(creations, 0)
        XCTAssertNil(controller.window?.contentView)
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }

    func testDismissReleasesContentAndNextPreparationCreatesFreshView() {
        _ = NSApplication.shared
        var creations = 0
        let controller = DashboardWindowController(makeContentView: {
            creations += 1
            return NSView()
        })
        weak var previousContent: NSView?
        let previousFrame = controller.window?.frame
        autoreleasepool {
            controller.prepareContent()
            previousContent = controller.window?.contentView
            XCTAssertNotNil(previousContent)
            controller.dismiss()
        }
        XCTAssertNil(controller.window?.contentView)
        XCTAssertNil(previousContent, "Hidden content must not retain its observation graph")
        XCTAssertEqual(controller.window?.frame, previousFrame)
        controller.dismiss()
        XCTAssertEqual(creations, 1)

        controller.prepareContent()
        XCTAssertEqual(creations, 2)
        XCTAssertNotNil(controller.window?.contentView)
        XCTAssertFalse(controller.window?.isVisible ?? true, "Lifecycle tests never present windows")
        controller.dismiss()
    }

    func testCloseNotificationReleasesContent() {
        _ = NSApplication.shared
        let controller = DashboardWindowController(makeContentView: { NSView() })
        weak var previousContent: NSView?
        autoreleasepool {
            controller.prepareContent()
            previousContent = controller.window?.contentView
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        }
        XCTAssertNil(controller.window?.contentView)
        XCTAssertNil(previousContent)
        XCTAssertFalse(controller.window?.isVisible ?? true)
    }
}
