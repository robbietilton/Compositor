import SwiftUI

struct CanvasSizeSheet: View {
    let foreground: PaletteColor
    let background: PaletteColor
    let finish: (CanvasSizeOptions?) -> Void
    @State private var draft: CanvasSizeDraft
    @State private var anchor = 4
    @State private var extensionChoice = "Transparent"
    @State private var customColor = Color.white
    private let anchorNames = [L10n.string("Top left"), L10n.string("Top center"), L10n.string("Top right"), L10n.string("Middle left"), L10n.string("Center"), L10n.string("Middle right"), L10n.string("Bottom left"), L10n.string("Bottom center"), L10n.string("Bottom right")]

    init(document: CanvasDocument, foreground: PaletteColor = .black, background: PaletteColor = .white, finish: @escaping (CanvasSizeOptions?) -> Void) {
        self.foreground = foreground
        self.background = background
        self.finish = finish
        _draft = State(initialValue: CanvasSizeDraft(width: document.width, height: document.height, resolution: document.resolution))
    }

    private func dimension(_ widthAxis: Bool) -> Binding<Double> {
        Binding(get: { draft.displayed(widthAxis: widthAxis) }, set: { draft.set($0, widthAxis: widthAxis) })
    }
    private func bytes(_ width: Int, _ height: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(width) * Int64(height) * 4, countStyle: .memory)
    }
    private var fill: CanvasExtensionColor? {
        let color: NSColor
        switch extensionChoice {
        case "Transparent": return nil
        case "Black": color = .black
        case "Foreground": color = foreground.nsColor
        case "White": color = .white
        case "Background": color = background.nsColor
        default: color = NSColor(customColor)
        }
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return CanvasExtensionColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("Canvas Size")).font(.title2.bold())
            Text(L10n.format("Current: %1$@ × %2$@ pixels", String(draft.originalWidth), String(draft.originalHeight)))
            Text(L10n.format("%1$@ uncompressed RGBA canvas", bytes(draft.originalWidth, draft.originalHeight)))
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Picker(L10n.string("Units"), selection: $draft.unit) {
                ForEach(CanvasUnit.allCases, id: \.self) { Text(L10n.string($0.rawValue)).tag($0) }
            }
            HStack {
                Text(L10n.string("Width")).frame(width: 60, alignment: .leading)
                TextField(L10n.string("Width"), value: dimension(true), format: .number.precision(.fractionLength(0...3)))
            }
            HStack {
                Text(L10n.string("Height")).frame(width: 60, alignment: .leading)
                TextField(L10n.string("Height"), value: dimension(false), format: .number.precision(.fractionLength(0...3)))
            }
            Toggle(L10n.string("Relative to current dimensions"), isOn: $draft.relative)
            Toggle(L10n.string("Lock original aspect ratio"), isOn: $draft.locked)
                .onChange(of: draft.locked) { _, locked in
                    if locked { draft.set(draft.displayed(widthAxis: true), widthAxis: true) }
                }
            if draft.valid {
                Text(L10n.format("New: %1$@ × %2$@ pixels · %3$@ uncompressed", String(Int(draft.width.rounded())), String(Int(draft.height.rounded())), bytes(Int(draft.width.rounded()), Int(draft.height.rounded()))))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(L10n.string("Final dimensions must be 1–30,000 pixels per side."))
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("Anchor"))
                    Grid(horizontalSpacing: 3, verticalSpacing: 3) {
                        ForEach(0..<3) { row in
                            GridRow {
                                ForEach(0..<3) { column in
                                    let index = row * 3 + column
                                    Button { anchor = index } label: {
                                        Image(systemName: index == anchor ? "circle.fill" : "circle")
                                            .frame(width: 25, height: 25)
                                    }
                                    .tint(index == anchor ? .accentColor : .secondary)
                                    .help(anchorNames[index]).accessibilityLabel(anchorNames[index])
                                    .accessibilityValue(index == anchor ? L10n.string("Selected") : "")
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(anchorNames[anchor]).font(.callout.bold())
                    Text(L10n.string("Keeps this point fixed. Artwork is not scaled; cropped content remains outside the canvas."))
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 28)
            }
            Picker(L10n.string("Canvas extension"), selection: $extensionChoice) {
                ForEach(["Transparent", "Foreground", "Background", "Black", "White", "Custom"], id: \.self) { Text(L10n.string($0)).tag($0) }
            }
            if extensionChoice == "Custom" {
                ColorPicker(L10n.string("Extension color"), selection: $customColor, supportsOpacity: false)
            }
            HStack {
                Button(L10n.string("Cancel")) { finish(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("OK")) {
                    guard draft.valid else { return }
                    finish(CanvasSizeOptions(width: Int(draft.width.rounded()), height: Int(draft.height.rounded()), anchor: anchor, fill: fill))
                }.keyboardShortcut(.defaultAction).disabled(!draft.valid)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 450)
    }
}
