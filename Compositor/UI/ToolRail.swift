import SwiftUI

/// How the tool rail lays out its tools: one column as it always has, or two for a rail about half as tall.
enum ToolRailLayout {
    static let buttonSize: CGFloat = 36
    static let columnSpacing: CGFloat = 8
    static let rowSpacing: CGFloat = 10

    /// 56 pt in one column; 92 in two (two buttons, the gap between them and 6 pt margins each side).
    static func width(columns: Int) -> CGFloat {
        columns >= 2 ? buttonSize * 2 + columnSpacing + 12 : 56
    }

    /// The tools in rows of `columns`, in the rail's order read left to right.
    static func rows(_ tools: [NavigationTool], columns: Int) -> [[NavigationTool]] {
        let count = min(2, max(1, columns))
        return stride(from: 0, to: tools.count, by: count).map { Array(tools[$0..<min($0 + count, tools.count)]) }
    }
}

/// The tools down the left of the window, with the colour swatches under them. The double chevron at the top
/// switches between one column and two, as Photoshop's does.
struct ToolRail: View {
    @Bindable var session: EditorSession
    @Binding var columns: Int

    var body: some View {
        // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
        IndicatorlessScrollView { ToolRailStack(session: session, columns: $columns) }
            .frame(width: ToolRailLayout.width(columns: columns))
    }
}

/// The rail's contents: the column toggle, the tools in rows, and the colour swatches.
struct ToolRailStack: View {
    @Bindable var session: EditorSession
    @Binding var columns: Int

    private var tools: [NavigationTool] { NavigationTool.allCases.filter { $0 != .idle } }

    var body: some View {
        let width = ToolRailLayout.width(columns: columns)
        let twoColumns = columns >= 2
        VStack(spacing: ToolRailLayout.rowSpacing) {
            Button { columns = twoColumns ? 1 : 2 } label: {
                Image(systemName: twoColumns ? "chevron.left.2" : "chevron.right.2")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: width - 16, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help(twoColumns ? "Show tools in one column" : "Show tools in two columns")
            .accessibilityLabel(twoColumns ? "Show tools in one column" : "Show tools in two columns")
            ForEach(Array(ToolRailLayout.rows(tools, columns: columns).enumerated()), id: \.offset) { _, row in
                HStack(spacing: ToolRailLayout.columnSpacing) {
                    ForEach(row, id: \.self) { toolButton($0) }
                }
                // A lone last tool stays in the left column.
                .frame(width: twoColumns ? ToolRailLayout.buttonSize * 2 + ToolRailLayout.columnSpacing : ToolRailLayout.buttonSize,
                       alignment: .leading)
            }
            ColorPaletteControls(session: session).padding(.top, 8)
        }
        .padding(.top, 10).padding(.bottom, 12)
        .frame(width: width)
    }

    private func toolButton(_ tool: NavigationTool) -> some View {
        Button { session.selectTool(tool) } label: {
            Group {
                if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
                else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
                else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
                else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
                // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
                else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
            }
            .frame(width: ToolRailLayout.buttonSize, height: ToolRailLayout.buttonSize)
            .background(session.tool == tool ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(session.tool == tool ? Color.white.opacity(0.14) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(tool.label).accessibilityLabel(tool.label)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
    }
}
