import SwiftUI

struct CanvasSizeSheet: View {
    let foreground: PaletteColor
    let background: PaletteColor
    let finish: (CanvasSizeOptions?) -> Void
    @State private var draft: CanvasSizeDraft
    @State private var anchor = 4
    @State private var extensionChoice = "Transparent"
    @State private var customColor = Color.white
    private let anchorNames = ["Top left", "Top center", "Top right", "Middle left", "Center", "Middle right", "Bottom left", "Bottom center", "Bottom right"]

    init(document: CanvasDocument, foreground: PaletteColor = .black, background: PaletteColor = .white, finish: @escaping (CanvasSizeOptions?) -> Void) {
        self.foreground = foreground
        self.background = background
        self.finish = finish
        _draft = State(initialValue: CanvasSizeDraft(width: document.width, height: document.height, resolution: document.resolution))
    }

    private func dimension(_ widthAxis: Bool) -> Binding<Double> {
        Binding(get: { draft.displayed(widthAxis: widthAxis) }, set: { draft.set($0, widthAxis: widthAxis) })
    }
    private func scrubRange(_ widthAxis: Bool) -> ClosedRange<Double> {
        let original = Double(widthAxis ? draft.originalWidth : draft.originalHeight)
        let other = Double(widthAxis ? draft.originalHeight : draft.originalWidth)
        let lower = draft.locked ? max(1, original / other) : 1.0
        let upper = draft.locked ? min(30_000, 30_000 * original / other) : 30_000.0
        func displayed(_ pixels: Double) -> Double {
            let difference = pixels - (draft.relative ? original : 0)
            switch draft.unit {
            case .pixels: return difference
            case .percent: return difference / original * 100
            case .inches: return difference / draft.resolution
            case .centimeters: return difference / draft.resolution * 2.54
            }
        }
        return displayed(lower)...displayed(upper)
    }
    private func scrubSensitivity(_ widthAxis: Bool) -> Double {
        switch draft.unit {
        case .pixels: return 1
        case .percent: return 100 / Double(widthAxis ? draft.originalWidth : draft.originalHeight)
        case .inches: return 1 / draft.resolution
        case .centimeters: return 2.54 / draft.resolution
        }
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
            Text("Canvas Size").font(.title2.bold())
            Text("Current: \(draft.originalWidth) × \(draft.originalHeight) pixels")
            Text("\(bytes(draft.originalWidth, draft.originalHeight)) uncompressed RGBA canvas")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Picker("Units", selection: $draft.unit) {
                ForEach(CanvasUnit.allCases, id: \.self) { Text(localized($0.rawValue)).tag($0) }
            }
            HStack {
                Text("Width").frame(width: 60, alignment: .leading)
                    .scrubbable(sensitivity: scrubSensitivity(true), value: dimension(true), range: scrubRange(true), step: 1)
                TextField("Width", value: dimension(true), format: .number.precision(.fractionLength(0...3)))
            }
            HStack {
                Text("Height").frame(width: 60, alignment: .leading)
                    .scrubbable(sensitivity: scrubSensitivity(false), value: dimension(false), range: scrubRange(false), step: 1)
                TextField("Height", value: dimension(false), format: .number.precision(.fractionLength(0...3)))
            }
            Toggle("Relative to current dimensions", isOn: $draft.relative)
            Toggle("Lock original aspect ratio", isOn: $draft.locked)
                .onChange(of: draft.locked) { _, locked in
                    if locked { draft.set(draft.displayed(widthAxis: true), widthAxis: true) }
                }
            if draft.valid {
                Text("New: \(Int(draft.width.rounded())) × \(Int(draft.height.rounded())) pixels · \(bytes(Int(draft.width.rounded()), Int(draft.height.rounded()))) uncompressed")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Final dimensions must be 1–\(DocumentLimits.maxSide.formatted()) pixels per side.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anchor")
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
                                    .help(localized(anchorNames[index])).accessibilityLabel(localized(anchorNames[index]))
                                    .accessibilityValue(index == anchor ? localized("Selected") : "")
                                }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized(anchorNames[anchor])).font(.callout.bold())
                    Text("Keeps this point fixed. Artwork is not scaled; cropped content remains outside the canvas.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(.top, 28)
            }
            Picker("Canvas extension", selection: $extensionChoice) {
                ForEach(["Transparent", "Foreground", "Background", "Black", "White", "Custom"], id: \.self) { Text(localized($0)) }
            }
            if extensionChoice == "Custom" {
                ColorPicker("Extension color", selection: $customColor, supportsOpacity: false)
            }
            HStack {
                Button("Cancel") { finish(nil) }.configuredNativeShortcut(.escape)
                Spacer()
                Button("OK") {
                    guard draft.valid else { return }
                    finish(CanvasSizeOptions(width: Int(draft.width.rounded()), height: Int(draft.height.rounded()), anchor: anchor, fill: fill))
                }.configuredNativeShortcut(.return).disabled(!draft.valid)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 450)
    }
}
