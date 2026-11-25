import AppKit
import SwiftUI

// AppKit's date picker supports seconds on macOS.
struct ScheduledDatePicker: NSViewRepresentable {
    @Binding var selection: Date
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.controlSize = .small
        picker.setAccessibilityLabel("启动日期和时间")
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.selectionChanged(_:))
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.selection = $selection
        if picker.dateValue != selection {
            picker.dateValue = selection
        }
        picker.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    final class Coordinator: NSObject {
        var selection: Binding<Date>

        init(selection: Binding<Date>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ picker: NSDatePicker) {
            selection.wrappedValue = picker.dateValue
        }
    }
}
