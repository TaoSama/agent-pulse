import AppKit
import SwiftUI
import XCTest
@testable import AgentPulse

@MainActor
final class StableSegmentedPickerTests: XCTestCase {
    func testUpdatesDoNotWriteBindingAndSelectionActionWritesOnlyChanges() {
        _ = NSApplication.shared
        var value = "day"
        var writes = 0
        let binding = Binding(get: { value }, set: { value = $0; writes += 1 })
        let picker = StableSegmentedPicker(label: "Window", options: ["day", "month"],
                                           selection: binding, title: { $0 })
        let coordinator = picker.makeCoordinator()
        let control = NSSegmentedControl()
        for _ in 0..<100 { picker.update(control, coordinator: coordinator) }
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual(control.selectedSegment, 0)
        XCTAssertEqual(control.label(forSegment: 1), "month")
        control.selectedSegment = 1
        coordinator.selectSegment(control)
        coordinator.selectSegment(control)
        XCTAssertEqual(value, "month")
        XCTAssertEqual(writes, 1)
        control.selectedSegment = -1
        coordinator.selectSegment(control)
        XCTAssertEqual(writes, 1)
    }

    func testExternalSelectionReorderedOptionsAndAccessibility() {
        _ = NSApplication.shared
        var value = 1
        let binding = Binding(get: { value }, set: { value = $0 })
        var picker = StableSegmentedPicker(label: "Interval", options: [1, 2],
                                           selection: binding, title: { "\($0)" },
                                           optionAccessibilityLabel: { "\($0) minutes" })
        let coordinator = picker.makeCoordinator()
        let control = NSSegmentedControl()
        picker.update(control, coordinator: coordinator)
        value = 2
        picker.update(control, coordinator: coordinator)
        XCTAssertEqual(control.selectedSegment, 1)
        XCTAssertEqual(control.accessibilityLabel(), "Interval")
        XCTAssertEqual(control.accessibilityValue() as? String, "2 minutes")

        picker = StableSegmentedPicker(label: "Interval", options: [2, 1],
                                        selection: binding, title: { "\($0)" })
        picker.update(control, coordinator: coordinator)
        XCTAssertEqual(control.selectedSegment, 0)
        control.selectedSegment = 1
        coordinator.selectSegment(control)
        XCTAssertEqual(value, 1)
    }
}
