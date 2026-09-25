import SwiftUI

/// Shared metrics keep tool switching from changing typography or canvas layout.
enum ToolHeaderStyle {
    static let height: CGFloat = 42
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let controlFont = Font.system(size: 12)
}

extension View {
    /// Keeps a unit ("%", "px") tight against its field so the two read as one value,
    /// regardless of the wider spacing between controls in a bar.
    func unitSuffix(_ unit: String) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit)
        }
    }

    /// Lets a field without a separate label use its unit as the drag target.
    func unitSuffix<Value: BinaryFloatingPoint>(_ unit: String, scrubValue: Binding<Value>,
                                                sensitivity: Value, range: ClosedRange<Value>, step: Value? = nil) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit).scrubbable(sensitivity: sensitivity, value: scrubValue, range: range, step: step)
        }
    }

    func unitSuffix(_ unit: String, scrubValue: Binding<Int>, sensitivity: Double,
                    range: ClosedRange<Int>) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit).scrubbable(sensitivity: sensitivity, value: scrubValue, range: range)
        }
    }

    func toolHeaderBar() -> some View {
        font(ToolHeaderStyle.controlFont)
            .controlSize(.regular)
            .frame(height: ToolHeaderStyle.height)
            .fixedSize(horizontal: false, vertical: true)
    }
}
