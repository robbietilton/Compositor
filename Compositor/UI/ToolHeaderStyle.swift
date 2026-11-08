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

/// Related icon buttons joined into one pill, with a thin divider between them.
struct ToolHeaderPill<Content: View>: View {
    var segmentWidth: CGFloat = 28
    @ViewBuilder let content: Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            Group(subviews: content) { segments in
                ForEach(segments.indices, id: \.self) { index in
                    if index > 0 { Rectangle().fill(.white.opacity(isEnabled ? 0.12 : 0.06)).frame(width: 1, height: 12) }
                    segments[index]
                }
            }
        }
        .buttonStyle(ToolHeaderPillButtonStyle(width: segmentWidth))
        // Fainter while disabled, as the system's own buttons go, so a dimmed pill doesn't stand out from them.
        .background(.white.opacity(isEnabled ? 0.09 : 0.045))
        .clipShape(Capsule())
    }
}

private struct ToolHeaderPillButtonStyle: ButtonStyle {
    let width: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.4)
            .frame(width: width, height: 24)
            .contentShape(Rectangle())
            .background(.white.opacity(configuration.isPressed ? 0.14 : 0))
    }
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

    func toolHeaderBar() -> some View {
        font(ToolHeaderStyle.controlFont)
            .controlSize(.regular)
            .frame(height: ToolHeaderStyle.height)
            .fixedSize(horizontal: false, vertical: true)
    }
}
