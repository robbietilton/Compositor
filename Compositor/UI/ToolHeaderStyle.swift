import SwiftUI

/// Shared metrics keep tool switching from changing typography or canvas layout.
enum ToolHeaderStyle {
    static let height: CGFloat = 42
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let controlFont = Font.system(size: 12)
    /// Number boxes sized for their digits, at the bar's 12-point text (7.6 points a digit) and a field border's 8 points
    /// of padding: three for a selection's amounts, five for the zoom.
    static let threeDigits: CGFloat = 31
    static let fiveDigits: CGFloat = 46
}

extension View {
    /// Keeps a unit ("%", "px") tight against its field so the two read as one value,
    /// regardless of the wider spacing between controls in a bar.
    func unitSuffix(_ unit: String, spacing: CGFloat = 2) -> some View {
        HStack(spacing: spacing) {
            self
            Text(unit)
        }
    }

    /// Lets a field without a separate label use its unit as the drag target.
    func unitSuffix<Value: BinaryFloatingPoint>(_ unit: String, scrubValue: Binding<Value>,
                                                sensitivity: Value, range: ClosedRange<Value>, step: Value? = nil,
                                                spacing: CGFloat = 2) -> some View {
        HStack(spacing: spacing) {
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
