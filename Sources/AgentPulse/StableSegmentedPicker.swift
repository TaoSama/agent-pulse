import AppKit
import SwiftUI

/// Keeps native selection and accessibility without SwiftUI's segmented-picker
/// measurement graph. Content changes only when options or selection change.
struct StableSegmentedPicker<Selection: Hashable>: NSViewRepresentable {
    let label: String
    let options: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    var optionAccessibilityLabel: ((Selection) -> String)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection, options: options) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentStyle = .rounded
        control.segmentDistribution = .fill
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSegment(_:))
        update(control, coordinator: context.coordinator)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        update(control, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? intrinsic.width,
                      height: intrinsic.height)
    }

    func update(_ control: NSSegmentedControl, coordinator: Coordinator) {
        coordinator.selection = $selection
        coordinator.options = options
        if control.segmentCount != options.count { control.segmentCount = options.count }
        for (index, option) in options.enumerated() {
            let text = title(option)
            if control.label(forSegment: index) != text { control.setLabel(text, forSegment: index) }
        }
        let index = options.firstIndex(of: selection) ?? -1
        if control.selectedSegment != index { control.selectedSegment = index }
        if control.accessibilityLabel() != label { control.setAccessibilityLabel(label) }
        let accessibleValue = optionAccessibilityLabel?(selection) ?? title(selection)
        if control.accessibilityValue() as? String != accessibleValue {
            control.setAccessibilityValue(accessibleValue)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Selection>
        var options: [Selection]

        init(selection: Binding<Selection>, options: [Selection]) {
            self.selection = selection
            self.options = options
        }

        @objc func selectSegment(_ sender: NSSegmentedControl) {
            guard options.indices.contains(sender.selectedSegment) else { return }
            let next = options[sender.selectedSegment]
            if selection.wrappedValue != next { selection.wrappedValue = next }
        }
    }
}
