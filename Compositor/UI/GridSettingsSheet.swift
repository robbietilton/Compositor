import SwiftUI

/// View > Grid Settings…: every change shows on the canvas at once through `preview`; Cancel puts back what was there.
struct GridSettingsSheet: View {
    let session: EditorSession
    let preview: (LayoutGrid, GridAppearance) -> Void
    let finish: ((LayoutGrid, GridAppearance)?) -> Void
    @State private var spacing: Int
    @State private var subdivisions: Int
    @State private var appearance: GridAppearance
    /// The preset in use when the picker first moved the color; Cancel in the picker puts it back.
    @State private var pickedFrom: GridAppearance.Preset?

    init(session: EditorSession, grid: LayoutGrid, appearance: GridAppearance, preview: @escaping (LayoutGrid, GridAppearance) -> Void,
         finish: @escaping ((LayoutGrid, GridAppearance)?) -> Void) {
        self.session = session
        self.preview = preview
        self.finish = finish
        _spacing = State(initialValue: grid.spacing)
        _subdivisions = State(initialValue: grid.subdivisions)
        _appearance = State(initialValue: appearance)
    }

    private var valid: Bool {
        LayoutGrid.spacingRange.contains(spacing) && LayoutGrid.subdivisionRange.contains(subdivisions)
            && subdivisions <= spacing
    }

    private var grid: LayoutGrid { LayoutGrid(spacing: spacing, subdivisions: subdivisions) }

    /// The swatch shows whichever color is in use; picking one in it makes that the Custom color.
    private var swatchColor: Binding<PaletteColor> {
        Binding(get: { appearance.color }, set: { picked in
            // The picker reports the color it opened on too; that alone leaves the preset chosen.
            guard picked != appearance.color else { return }
            if let pickedFrom, picked == pickedFrom.color {
                appearance.preset = pickedFrom
                self.pickedFrom = nil
                return
            }
            if appearance.preset != .custom { pickedFrom = appearance.preset }
            appearance.customColor = picked
            appearance.preset = .custom
        })
    }

    private func setOpacity(_ value: Int) {
        appearance.opacity = min(max(value, GridAppearance.opacityRange.lowerBound), GridAppearance.opacityRange.upperBound)
    }

    var body: some View { sheet.roundedControls() }

    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Grid").font(.title2.bold())
            HStack {
                Text("Color").frame(width: 110, alignment: .leading)
                Picker("Color", selection: $appearance.preset) {
                    ForEach(GridAppearance.Preset.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
                }.labelsHidden()
                DialogColorSwatch(title: "Grid Color", color: swatchColor, session: session)
                    .help("Choose a custom grid color")
            }
            HStack {
                Text("Style").frame(width: 110, alignment: .leading)
                Picker("Style", selection: $appearance.style) {
                    ForEach(GridAppearance.Style.allCases) { Text(L10n.text($0.rawValue)).tag($0) }
                }.labelsHidden()
            }
            HStack {
                Text("Opacity").frame(width: 110, alignment: .leading)
                    .scrubbable(sensitivity: 0.5, value: $appearance.opacity, range: GridAppearance.opacityRange)
                Slider(value: Binding(get: { Double(appearance.opacity) }, set: { appearance.opacity = Int($0.rounded()) }),
                       in: Double(GridAppearance.opacityRange.lowerBound)...Double(GridAppearance.opacityRange.upperBound))
                TextField("Opacity", value: Binding(get: { appearance.opacity }, set: setOpacity), format: .number)
                    .frame(width: 48).multilineTextAlignment(.trailing)
                    .arrowSteps(value: { Double(appearance.opacity) }, change: { setOpacity(Int($0.rounded())) })
                    .unitSuffix("%")
            }
            Divider()
            HStack {
                Text("Gridline every").frame(width: 110, alignment: .leading)
                    .scrubbable(sensitivity: 1, value: $spacing, range: LayoutGrid.spacingRange)
                TextField("Gridline every", value: $spacing, format: .number)
                Text("pixels").foregroundStyle(.secondary)
            }
            HStack {
                Text("Subdivisions").frame(width: 110, alignment: .leading)
                    .scrubbable(sensitivity: 0.2, value: $subdivisions, range: LayoutGrid.subdivisionRange)
                TextField("Subdivisions", value: $subdivisions, format: .number)
            }
            Text(L10n.text(valid ? L10n.format("A subdivision every %@ pixels.", String(describing: (Double(grid.step).formatted(.number.precision(.fractionLength(0...2))))))
                       : L10n.format("Use gridlines every %@–%@ pixels and %@–%@ subdivisions, no more than the pixels between gridlines.", String(describing: (LayoutGrid.spacingRange.lowerBound)), String(describing: (LayoutGrid.spacingRange.upperBound.formatted())), String(describing: (LayoutGrid.subdivisionRange.lowerBound)), String(describing: (LayoutGrid.subdivisionRange.upperBound)))))
                .foregroundStyle(valid ? Color.secondary : Color.orange).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { DialogColorSwatch.closePicker(session); finish(nil) }.configuredNativeShortcut(.escape)
                Button("Restore Defaults") {
                    spacing = LayoutGrid().spacing
                    subdivisions = LayoutGrid().subdivisions
                    // The Custom color is kept, so it's still there if Custom is chosen again.
                    pickedFrom = nil
                    appearance.preset = GridAppearance().preset
                    appearance.style = GridAppearance().style
                    appearance.opacity = GridAppearance().opacity
                }
                Spacer()
                Button("OK") {
                    guard valid else { return }
                    DialogColorSwatch.closePicker(session)
                    finish((grid, appearance))
                }
                .configuredNativeShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(!valid)
            }
        }
        .textFieldStyle(.roundedBorder).padding(24).frame(width: 360)
        .onChange(of: appearance) { preview(grid, appearance) }
        // Choosing a preset from the menu ends a pick that started from another.
        .onChange(of: appearance.preset) { _, preset in if preset != .custom { pickedFrom = nil } }
        .onChange(of: spacing) { if valid { preview(grid, appearance) } }
        .onChange(of: subdivisions) { if valid { preview(grid, appearance) } }
    }
}
