import SwiftUI

struct ImageSizeSheet: View {
    let document: CanvasDocument
    let finish: (ImageSizeOptions?) -> Void
    @State private var width: Double
    @State private var height: Double
    @State private var resolution: Double
    @State private var locked = true
    @State private var resample = true
    @State private var unit = "Pixels"
    @State private var sampling: LayerSampling = .high
    private let units = ["Pixels", "Percent", "Inches", "Centimeters"]

    init(document: CanvasDocument, finish: @escaping (ImageSizeOptions?) -> Void) {
        self.document = document
        self.finish = finish
        _width = State(initialValue: Double(document.width))
        _height = State(initialValue: Double(document.height))
        _resolution = State(initialValue: document.resolution)
    }

    private var valid: Bool {
        width.isFinite && height.isFinite && resolution.isFinite && (1...9600).contains(resolution)
            && (1...30_000).contains(width.rounded()) && (1...30_000).contains(height.rounded())
            && (!resample || width.rounded() * height.rounded() <= 100_000_000)
    }
    private func display(_ pixels: Double, original: Int) -> Double {
        switch unit {
        case "Percent": return pixels / Double(original) * 100
        case "Inches": return pixels / resolution
        case "Centimeters": return pixels / resolution * 2.54
        default: return pixels
        }
    }
    private func dimension(isWidth: Bool) -> Binding<Double> {
        Binding(get: { display(isWidth ? width : height, original: isWidth ? document.width : document.height) }, set: { value in
            guard value.isFinite, value > 0 else { return }
            if !resample {
                resolution = (isWidth ? width : height) / value * (unit == "Centimeters" ? 2.54 : 1)
                return
            }
            let pixels: Double
            switch unit {
            case "Percent": pixels = value / 100 * Double(isWidth ? document.width : document.height)
            case "Inches": pixels = value * resolution
            case "Centimeters": pixels = value / 2.54 * resolution
            default: pixels = value
            }
            if isWidth {
                if locked { height = pixels * height / width }
                width = pixels
            } else {
                if locked { width = pixels * width / height }
                height = pixels
            }
        })
    }

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Image Size").font(.title2.bold())
            Text(L10n.format("Current: %lld × %lld pixels", document.width, document.height)).foregroundStyle(.secondary)
            Picker("Units", selection: $unit) {
                ForEach(units.filter { resample || ($0 != "Pixels" && $0 != "Percent") }, id: \.self) { Text(L10n.text($0)) }
            }
            HStack {
                Text("Width").frame(width: 75, alignment: .leading)
                TextField("Width", value: dimension(isWidth: true), format: .number.precision(.fractionLength(0...3)))
            }
            HStack {
                Text("Height").frame(width: 75, alignment: .leading)
                TextField("Height", value: dimension(isWidth: false), format: .number.precision(.fractionLength(0...3)))
            }
            Toggle("Lock aspect ratio", isOn: $locked).disabled(!resample)
            HStack {
                Text("Resolution")
                TextField("Resolution", value: $resolution, format: .number.precision(.fractionLength(0...3)))
                    .onChange(of: resolution) { old, new in
                        if resample, unit == "Inches" || unit == "Centimeters",
                           old > 0, new > 0, new.isFinite {
                            width *= new / old
                            height *= new / old
                        }
                    }
                Text("pixels/inch").foregroundStyle(.secondary)
            }
            Toggle("Resample", isOn: $resample).onChange(of: resample) { _, enabled in
                if !enabled {
                    width = Double(document.width)
                    height = Double(document.height)
                    locked = true
                    if unit == "Pixels" || unit == "Percent" { unit = "Inches" }
                }
            }
            if resample {
                Picker("Sampling", selection: $sampling) {
                    ForEach(LayerSampling.allCases, id: \.self) { Text(L10n.text($0.rawValue)).tag($0) }
                }
                Text("Resizes layer pixels and applies existing transforms. Undo restores the originals.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Only print dimensions and resolution change. Pixels stay unchanged.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(valid ? L10n.format("Result: %lld × %lld pixels", Int(width.rounded()), Int(height.rounded())) : L10n.text("Use 1–30,000 pixels per side, up to 100 megapixels, and 1–9,600 pixels/inch."))
                .foregroundStyle(valid ? Color.secondary : Color.orange).font(.callout)
            HStack {
                Button("Cancel") { finish(nil) }.configuredNativeShortcut(.escape)
                Spacer()
                Button("Resize") {
                    guard valid else { return }
                    finish(ImageSizeOptions(width: Int(width.rounded()), height: Int(height.rounded()),
                        resolution: resolution, sampling: sampling))
                }.configuredNativeShortcut(.return).disabled(!valid)
            }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 430)
    }
}
