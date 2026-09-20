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
            Text(unit.localized)
        }
    }

    func toolHeaderBar() -> some View {
        font(ToolHeaderStyle.controlFont)
            .controlSize(.regular)
            .frame(height: ToolHeaderStyle.height)
            .fixedSize(horizontal: false, vertical: true)
    }
}
