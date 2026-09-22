import SwiftUI

/// View-only controls; none of these settings are passed to the pixel processor or exported.
struct RenderCompareToolbar: View {
    @Bindable var session: EditorSession
    private var edit: FilterEdit? { session.filterEdit }
    private let ratios: [(String, CGFloat)] = [("1:8", 0.125), ("1:4", 0.25), ("1:3", 1.0/3),
        ("1:2", 0.5), ("2:1", 2), ("4:1", 4)]
    /// The before/after key as currently assigned in Keyboard Shortcuts.
    static var beforeAfterKey: String {
        ShortcutDefinition.all.first { $0.title == "Darkroom before/after" }
            .map { ShortcutSettings.shared.chord($0).label } ?? "\\"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("Compare").foregroundStyle(.secondary)
            Picker("Compare mode", selection: Binding(get: { edit?.comparisonMode ?? .split },
                set: { session.setFinishComparison($0) })) {
                ForEach(FinishComparisonMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.symbol).tag(mode)
                }
            }.pickerStyle(.segmented).frame(width: 265).labelsHidden()
            Text(edit?.showingOriginal == true ? "Original" : "Hold Original")
                .font(.caption).padding(.horizontal, 9).padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in if edit?.showingOriginal != true { session.showFinishOriginal(true) } }
                    .onEnded { _ in session.showFinishOriginal(false) })
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Show original temporarily")
                .accessibilityAction { session.showFinishOriginal(!(edit?.showingOriginal ?? false)) }
                .help("Press and hold to see the original, or press \(Self.beforeAfterKey) to switch between before and after.")
            Divider().frame(height: 18)
            Text("Zoom").foregroundStyle(.secondary)
            Button("Fit") { session.fitFinishComparison() }.help("Fit the entire image in each preview")
            Button("Fill") { session.fitFinishComparison(fill: true) }.help("Fill each preview; image edges may be cropped")
            Button("1:1") { session.zoom(to: 1) }.help("One image pixel per display pixel")
            Menu {
                ForEach(ratios, id: \.0) { ratio in
                    Button(ratio.0) { session.zoom(to: ratio.1) }
                }
            } label: { Text(String(format: "%.0f%%", session.viewport.zoom * 100)).monospacedDigit() }
            .frame(width: 72)
            Button { session.zoom(to: session.viewport.zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out")
            Button { session.zoom(to: session.viewport.zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in")
            Spacer(minLength: 0)
        }
        .font(.callout).controlSize(.small).buttonStyle(.bordered)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.white.opacity(0.025))
        .disabled(edit?.committing == true)
        .onAppear { session.fitFinishComparison() }
        .onDisappear { session.showFinishOriginal(false) }
    }
}
