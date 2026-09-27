import SwiftUI

struct ExportSheet: View {
    let raster: ExportRaster
    let finish: ((format: ExportFormat, data: Data)?) -> Void
    @State private var options: ExportOptions
    /// The quality of the last export, which the next one starts from.
    private static let qualityKey = "jpegExportQuality"
    static let formatKey = "imageExportFormat"

    init(raster: ExportRaster, finish: @escaping ((format: ExportFormat, data: Data)?) -> Void) {
        self.raster = raster
        self.finish = finish
        var start = ExportOptions(format: .png)
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.compression.quality = min(1, max(0, saved))
        }
        if let saved = UserDefaults.standard.string(forKey: Self.formatKey),
           let format = ExportFormat(rawValue: saved), ExportFormat.available.contains(format) {
            start.format = format
        }
        _options = State(initialValue: start)
    }
    @State private var matte = Color.white
    @State private var result: ExportResult?
    @State private var readyOptions: ExportOptions?
    @State private var error: String?
    @State private var zoom: Double = 0
    private let zoomLevels: [Double] = [0.125, 0.25, 0.5, 1, 2, 4, 8]
    private var fitZoom: Double { min(560 / Double(raster.image.width), 260 / Double(raster.image.height)) }
    private var previewZoom: Double { zoom == 0 ? fitZoom : zoom }
    private var isGenerating: Bool { readyOptions != options && error == nil }

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Image").font(.title2.bold())
            HStack {
                Picker("Format", selection: $options.format) {
                    ForEach(ExportFormat.available) { format in
                        Text(format.title).tag(format)
                    }
                }
                .fixedSize()
                Spacer()
                Text("\(raster.image.width) × \(raster.image.height) px · \(options.effectiveBitDepth)-bit sRGB · flattened")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            VStack(spacing: 8) {
                ExportPreview(image: result?.preview, imageSize: CGSize(width: raster.image.width, height: raster.image.height),
                              zoom: previewZoom)
                    .frame(width: 560, height: 260)
                HStack(spacing: 8) {
                    Button {
                        zoom = zoomLevels.last(where: { $0 < previewZoom - 0.0001 }) ?? zoomLevels[0]
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom out").accessibilityLabel("Zoom out")
                    .disabled(previewZoom <= zoomLevels[0])
                    Button {
                        zoom = zoomLevels.first(where: { $0 > previewZoom + 0.0001 }) ?? zoomLevels.last!
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom in").accessibilityLabel("Zoom in")
                    .disabled(previewZoom >= zoomLevels.last!)
                    Picker("Preview zoom", selection: $zoom) {
                        Text("Fit (\(Int((fitZoom * 100).rounded()))%)").tag(Double(0))
                        ForEach(zoomLevels, id: \.self) { level in
                            Text("\((level * 100).formatted())%").tag(level)
                        }
                    }
                    .labelsHidden().frame(width: 120)
                    Spacer()
                    if isGenerating {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Generating preview")
                    } else if error == nil, let result {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .controlSize(.small)
            }
            HStack {
                Picker("Bits per channel", selection: $options.bitDepth) {
                    ForEach(options.format.bitDepths, id: \.self) { depth in
                        Text("\(depth)-bit").tag(depth)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .disabled(options.format.bitDepths.count == 1)
                Spacer()
                if options.format == .tiff {
                    Picker("Compression", selection: $options.tiffCompression) {
                        ForEach(TIFFCompression.allCases) { compression in
                            Text(compression.title).tag(compression)
                        }
                    }
                }
            }
            if options.effectiveBitDepth > 8 {
                Text("Converted from the 8-bit composite; higher bit depth does not add image detail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if options.format.supportsQuality {
                HStack {
                    Text("Quality")
                    Slider(value: $options.compression.quality, in: 0...1, step: 0.01)
                    Text("\(Int((options.compression.quality * 100).rounded()))%")
                        .monospacedDigit().frame(width: 45, alignment: .trailing)
                }
            }
            if options.format.supportsTransparency {
                Toggle("Preserve transparency", isOn: $options.preserveTransparency)
            }
            if !options.includesAlpha {
                ColorPicker("Background for transparency", selection: $matte, supportsOpacity: false)
                    .onChange(of: matte) { _, color in
                        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                        options.compression.red = rgb.redComponent
                        options.compression.green = rgb.greenComponent
                        options.compression.blue = rgb.blueComponent
                    }
            }
            HStack {
                if let error { Text(error).foregroundStyle(.red) }
                Spacer()
                Button("Cancel") { finish(nil) }.configuredNativeShortcut(.escape)
                Button("Export…") {
                    UserDefaults.standard.set(options.compression.quality, forKey: Self.qualityKey)
                    if let result { finish((options.format, result.data)) }
                }
                    .configuredNativeShortcut(.return)
                    .disabled(result == nil || readyOptions != options || error != nil)
            }
        }
        .padding(24)
        .onChange(of: options.format) { _, format in
            if !format.bitDepths.contains(options.bitDepth) { options.bitDepth = 8 }
        }
        .task(id: options) {
            let requested = options
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let encoded = try await ImageExporter.shared.encode(raster, options: requested)
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
