import SwiftUI

struct JPEGExportSheet: View {
    let raster: ExportRaster
    let finish: (Data?) -> Void
    @State private var options: JPEGOptions
    /// The quality of the last export, which the next one starts from.
    private static let qualityKey = "jpegExportQuality"

    init(raster: ExportRaster, finish: @escaping (Data?) -> Void) {
        self.raster = raster
        self.finish = finish
        var start = JPEGOptions()
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.quality = min(1, max(0, saved))
        }
        _options = State(initialValue: start)
    }
    @State private var matte = Color.white
    @State private var result: JPEGResult?
    @State private var readyOptions: JPEGOptions?
    @State private var error: String?

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export JPEG").font(.title2.bold())
            ZStack {
                Color(white: 0.12)
                if let result {
                    Image(decorative: result.preview, scale: 1)
                        .resizable().scaledToFit()
                }
                if readyOptions != options && error == nil {
                    ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(width: 560, height: 330).clipped()
            HStack {
                Text("Quality")
                Slider(value: $options.quality, in: 0...1, step: 0.01)
                Text("\(Int((options.quality * 100).rounded()))%")
                    .monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            ColorPicker("Background for transparency", selection: $matte, supportsOpacity: false)
                .onValueChangeCompat(of: matte) { _, color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    options.red = rgb.redComponent
                    options.green = rgb.greenComponent
                    options.blue = rgb.blueComponent
                }
            Text("\(raster.image.width) × \(raster.image.height) px · sRGB")
                .foregroundStyle(.secondary)
            HStack {
                if let error { Text(error).foregroundStyle(.red) }
                else if readyOptions == options, let result {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))
                    Text("· encoded preview, fitted to window").foregroundStyle(.secondary)
                } else { Text("Updating preview…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { finish(nil) }.configuredNativeShortcut(.escape)
                Button("Export…") {
                    UserDefaults.standard.set(options.quality, forKey: Self.qualityKey)
                    finish(result?.data)
                }
                    .configuredNativeShortcut(.return)
                    .disabled(result == nil || readyOptions != options || error != nil)
            }
        }
        .padding(24)
        .task(id: options) {
            let requested = options
            error = nil
            do {
                try await Task.sleep(nanoseconds: LegacyDelay.milliseconds(200))
                let encoded = try await ImageExporter.shared.jpeg(raster, options: requested)
                try Task.checkCancellation()
                result = encoded
                readyOptions = requested
            } catch is CancellationError {
                // A newer setting superseded this preview.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
