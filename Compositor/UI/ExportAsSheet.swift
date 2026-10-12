import SwiftUI
import UniformTypeIdentifiers

/// File › Export As…: the flattened canvas as a PNG, a JPEG or a one-page PDF, at its own size or scaled, previewed
/// as it will be written. A light take on Photoshop's Export As: one image, the settings that matter, and its size.
struct ExportAsSheet: View {
    let raster: ExportRaster
    /// The same flattened at 16 bits a channel, when the document has a 16-bit layer to keep.
    let deepRaster: ExportRaster?
    /// The same flattened in half floats, when the document has an HDR layer: what an EXR is written from, the only
    /// format offered that keeps light brighter than white. Without one, EXR isn't offered.
    let hdrRaster: ExportRaster?
    private var formats: [ExportFormat] { ExportFormat.allCases.filter { $0 != .exr || hdrRaster != nil } }
    let session: EditorSession
    let finish: ((data: Data, format: ExportFormat)?) -> Void
    @State private var format: ExportFormat
    @State private var options: JPEGOptions
    @State private var width: Int
    @State private var height: Int
    /// JPEG's quality from the last export, which the next one starts from.
    private static let qualityKey = "jpegExportQuality"

    init(raster: ExportRaster, deepRaster: ExportRaster? = nil, hdrRaster: ExportRaster? = nil, session: EditorSession,
         format: ExportFormat, finish: @escaping ((data: Data, format: ExportFormat)?) -> Void) {
        self.raster = raster
        self.deepRaster = deepRaster
        self.hdrRaster = hdrRaster
        self.session = session
        self.finish = finish
        var start = JPEGOptions()
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.quality = min(1, max(0, saved))
        }
        _options = State(initialValue: start)
        _format = State(initialValue: format == .exr && hdrRaster == nil ? .png : format)
        _width = State(initialValue: raster.image.width)
        _height = State(initialValue: raster.image.height)
    }

    /// What's written depends on these; a change makes a new preview.
    struct Settings: Equatable {
        var format: ExportFormat
        var options: JPEGOptions
        var width: Int
        var height: Int
        var sixteenBit: Bool
        /// In this CMYK profile's inks, for print (JPEG, TIFF and PDF); nil for RGB.
        var cmyk: CMYKProfile?
    }
    struct Encoded {
        let settings: Settings
        let data: Data
        let preview: CGImage
    }
    private var settings: Settings {
        Settings(format: format, options: options, width: width, height: height, sixteenBit: sixteenBit && format == .png && deepRaster != nil,
                 cmyk: cmyk && takesCMYK ? profile : nil)
    }
    /// The formats that can be written in a printer's inks.
    private var takesCMYK: Bool { format == .jpeg || format == .tiff || format == .pdf }
    /// CMYK for print, remembered from the last export.
    @State private var cmyk = UserDefaults.standard.bool(forKey: "exportCMYK")
    /// The CMYK profile, shared with View › CMYK › Proof Colors.
    @State private var profile = CMYK.chosen
    /// A PNG at 16 bits a channel: off by default, it's about twice the size.
    @State private var sixteenBit = false
    @State private var result: Encoded?
    @State private var error: String?
    private var isReady: Bool { result?.settings == settings && error == nil }
    /// The preview's zoom, 1 being 100%; nil fits the whole image.
    @State private var zoom: Double?
    @Environment(\.displayScale) private var displayScale
    private var shownZoom: Double {
        zoom ?? JPEGPreview.fitZoom(width: width, height: height, in: JPEGPreview.frame, displayScale: displayScale)
    }

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(L10n.string("Export As")).font(.title2.bold())
                Spacer()
                Button(L10n.string("Fit")) { zoom = nil }.disabled(zoom == nil)
                    .help(Text(L10n.string("Show the whole image (⌘0)")))
                Button { zoomBy(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: 1) == nil)
                    .help(Text(L10n.format("Zoom in (⌘+), now %@. At 100%% each pixel of the export is one pixel of the screen", percent)))
                Button { zoomBy(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: -1) == nil)
                    .help(Text(L10n.format("Zoom out (⌘−), now %@", percent)))
            }
            .padding(.bottom, -8)
            ZStack {
                Color(white: 0.12)
                if let result {
                    JPEGPreview(image: result.preview, pixelWidth: result.settings.width, pixelHeight: result.settings.height, zoom: $zoom)
                }
                if !isReady && error == nil {
                    ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(width: JPEGPreview.frame.width, height: JPEGPreview.frame.height).clipped()
                .help(Text(L10n.string("Drag or scroll to move around; double-click switches between Fit and 100%")))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text(L10n.string("Format"))
                    // The everyday formats side by side, JPEG first; the rest (PDF, and EXR with an HDR layer) in a menu beside them,
                    // which takes the chosen one's name.
                    HStack(spacing: 12) {
                        Picker(L10n.string("Format"), selection: $format) {
                            ForEach([ExportFormat.jpeg, .png], id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        moreFormats
                    }
                }
                GridRow {
                    Text(L10n.string("Size"))
                    HStack(spacing: 6) {
                        sizeField(width, set: setWidth).help(Text(L10n.string("Width in pixels; the height follows, keeping the proportions")))
                        Text(L10n.string("×")).foregroundStyle(.secondary)
                        sizeField(height, set: setHeight).help(Text(L10n.string("Height in pixels; the width follows, keeping the proportions")))
                        Text(L10n.string("px")).foregroundStyle(.secondary)
                        Menu("\(scalePercent)%") {
                            ForEach([25, 50, 75, 100, 200], id: \.self) { percent in
                                Button("\(percent)%") { setScale(Double(percent) / 100) }
                            }
                        }
                        .fixedSize().help(Text(L10n.string("Scale the export: the document stays as it is")))
                    }
                }
                if format == .jpeg {
                    GridRow {
                        Text(L10n.string("Quality"))
                        HStack {
                            Slider(value: $options.quality, in: 0...1, step: 0.01).frame(width: 300)
                            Text("\(Int((options.quality * 100).rounded()))%").monospacedDigit().frame(width: 45, alignment: .trailing)
                        }
                    }
                }
                if format == .png, deepRaster != nil {
                    GridRow {
                        Text(L10n.string("Depth"))
                        Toggle(L10n.string("16 bits per channel"), isOn: $sixteenBit)
                            .help(Text(L10n.string("Keep the 16-bit layers' full precision, in a file about twice the size")))
                    }
                }
                if takesCMYK {
                    GridRow {
                        Text(L10n.string("Color"))
                        HStack(spacing: 12) {
                            Picker(L10n.string("Color"), selection: $cmyk) {
                                Text(L10n.string("RGB")).tag(false)
                                Text(L10n.string("CMYK")).tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            .help(Text(L10n.string("CMYK writes the printer's inks through the profile beside it, for print")))
                            if cmyk {
                                Menu(profile?.name ?? L10n.string("Choose Profile")) {
                                    ForEach(CMYK.installed()) { choice in
                                        Toggle(choice.name, isOn: Binding(get: { profile?.name == choice.name },
                                                                          set: { if $0 { choose(choice) } }))
                                    }
                                    Divider()
                                    Button(L10n.string("Load Profile…")) { loadProfile() }
                                }
                                .fixedSize().help(Text(L10n.string("The CMYK profile your printer uses; View › CMYK › Proof Colors shows it on the canvas")))
                            }
                        }
                    }
                }
                if format == .pdf {
                    GridRow {
                        Text(L10n.string("Page"))
                        Text(pageSize).foregroundStyle(.secondary)
                    }
                }
                // JPEG and ink have no transparency, and a PDF's page shows through it, so they fill it with a color.
                if format == .jpeg || format == .pdf || (format == .tiff && cmyk) {
                    GridRow {
                        Text(L10n.string("Background"))
                        DialogColorSwatch(title: "Export Background", color: matte, session: session)
                            .help(Text(L10n.string("Color that fills transparent areas")))
                    }
                }
            }
            HStack(spacing: 12) {
                Text(takesCMYK && cmyk
                     ? L10n.format("CMYK · %@", profile?.name ?? L10n.string("No profile"))
                     : L10n.string(format == .exr ? "Brighter than white kept · Transparency kept"
                                   : format == .png || format == .tiff ? "Transparency kept · sRGB" : "sRGB"))
                    .foregroundStyle(.secondary)
                Spacer()
                if let error { Text(error).foregroundStyle(.red) }
                else if isReady, let result {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)).monospacedDigit()
                } else { Text(L10n.string("Updating…")).foregroundStyle(.secondary) }
                Button(L10n.string("Cancel")) { DialogColorSwatch.closePicker(session); finish(nil) }.configuredNativeShortcut(.escape)
                Button(L10n.string("Export…")) {
                    DialogColorSwatch.closePicker(session)
                    if format == .jpeg { UserDefaults.standard.set(options.quality, forKey: Self.qualityKey) }
                    if takesCMYK { UserDefaults.standard.set(cmyk, forKey: "exportCMYK") }
                    if let result { finish((result.data, result.settings.format)) }
                }
                    .configuredNativeShortcut(.return)
                    .disabled(!isReady)
            }
        }
        .padding(24)
        .onAppear { session.previewZoom = { command in
            switch command {
            case .zoomIn: zoomBy(1)
            case .zoomOut: zoomBy(-1)
            case .fit: zoom = nil
            case .actual: zoom = 1
            }
        } }
        .onDisappear { session.previewZoom = nil }
        .task(id: settings) {
            let requested = settings
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
                let source = requested.format == .exr ? hdrRaster ?? raster : requested.sixteenBit ? deepRaster ?? raster : raster
                let sized = try await ImageExporter.shared.resized(source, width: requested.width, height: requested.height)
                let data: Data, preview: CGImage
                switch requested.format {
                case .jpeg:
                    let encoded = try await ImageExporter.shared.jpeg(sized, options: requested.options, cmyk: requested.cmyk)
                    (data, preview) = (encoded.data, encoded.preview)
                case .tiff:
                    let matte = CGColor(srgbRed: requested.options.red, green: requested.options.green, blue: requested.options.blue, alpha: 1)
                    (data, preview) = try await ImageExporter.shared.tiffData(sized, cmyk: requested.cmyk, matte: matte)
                case .png: (data, preview) = (try await ImageExporter.shared.pngData(sized), sized.image)
                // Shown as everything is, brighter than white as white.
                case .exr: (data, preview) = (try await ImageExporter.shared.exrData(sized), try DeepLayer.dithered(sized.image))
                case .pdf:
                    let background = CGColor(srgbRed: requested.options.red, green: requested.options.green,
                                             blue: requested.options.blue, alpha: 1)
                    (data, preview) = (try await ImageExporter.shared.pdfData(sized, background: background, cmyk: requested.cmyk),
                                       try requested.cmyk.map { try CMYK.convert(sized.image, to: $0, over: background) }
                                           ?? ImageExporter.shared.flattened(sized, over: background))
                }
                try Task.checkCancellation()
                result = Encoded(settings: requested, data: data, preview: preview)
            } catch is CancellationError {
                // A newer setting superseded this preview.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func choose(_ chosen: CMYKProfile) {
        profile = chosen
        session.proofProfile = chosen
    }

    private func loadProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "icc") ?? .data, UTType(filenameExtension: "icm") ?? .data]
        panel.message = L10n.string("Choose a CMYK ICC profile, such as the one your printer gave you")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { choose(try CMYK.load(url)) }
        catch { self.error = error.localizedDescription }
    }

    /// TIFF, PDF, and EXR with an HDR layer: a menu beside PNG and JPEG, blue with the chosen one's name while it's chosen,
    /// as the selected segment beside it would be.
    @ViewBuilder private var moreFormats: some View {
        let others = formats.filter { $0 != .png && $0 != .jpeg }
        let chosen = others.contains(format)
        let menu = Menu(chosen ? format.rawValue : "More") {
            Picker(L10n.string("More formats"), selection: $format) {
                ForEach(others, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline).labelsHidden()
        }
        .menuStyle(.button).fixedSize()
        .help(Text(L10n.string(others.contains(.exr)
                               ? "Other formats: TIFF and PDF, and EXR to keep light brighter than white"
                               : "Other formats: TIFF and PDF")))
        if chosen { menu.buttonStyle(.borderedProminent) } else { menu.buttonStyle(.bordered) }
    }

    private func sizeField(_ value: Int, set: @escaping (Int) -> Void) -> some View {
        TextField("", value: Binding(get: { value }, set: set), format: .number.grouping(.never))
            .frame(width: 64).multilineTextAlignment(.trailing)
    }
    /// Both sides follow one, keeping the canvas's proportions, within the export limits.
    private func setWidth(_ value: Int) { setScale(Double(value) / Double(raster.image.width)) }
    private func setHeight(_ value: Int) { setScale(Double(value) / Double(raster.image.height)) }
    private func setScale(_ scale: Double) {
        let largest = min(Double(DocumentLimits.maxSide) / Double(max(raster.image.width, raster.image.height)),
                          (Double(DocumentLimits.maxSurfacePixels) / Double(raster.image.width * raster.image.height)).squareRoot())
        let clamped = min(largest, max(0.01, scale.isFinite ? scale : 1))
        width = max(1, Int((Double(raster.image.width) * clamped).rounded()))
        height = max(1, Int((Double(raster.image.height) * clamped).rounded()))
    }
    private var scalePercent: Int { Int((Double(width) / Double(raster.image.width) * 100).rounded()) }
    /// The PDF page: the export's pixels at the document's resolution.
    private var pageSize: String {
        let dpi = raster.resolution > 0 ? raster.resolution : 72
        let inches = { (pixels: Int) in (Double(pixels) / dpi).formatted(.number.precision(.fractionLength(0...2))) }
        return "\(inches(width)) × \(inches(height)) in at \(Int(dpi.rounded())) DPI"
    }
    private var percent: String { "\(Int((shownZoom * 100).rounded()))%" }
    private func zoomBy(_ direction: Int) {
        if let next = JPEGPreview.step(from: shownZoom, in: direction) { zoom = next }
    }
    private var matte: Binding<PaletteColor> {
        Binding(get: { PaletteColor(red: options.red, green: options.green, blue: options.blue) },
                set: { options.red = $0.red; options.green = $0.green; options.blue = $0.blue })
    }
}

/// The export, fitted or zoomed (1 is 100%: one image pixel per screen pixel, as the canvas counts it), where it
/// can be dragged or scrolled around. Double-click switches between Fit and 100%.
struct JPEGPreview: View {
    static let frame = CGSize(width: 560, height: 330)
    static let steps: [Double] = [0.25, 0.5, 1, 2, 4, 8]
    let image: CGImage
    /// The exported image's size, which the preview may have been decoded smaller than.
    let pixelWidth: Int
    let pixelHeight: Int
    @Binding var zoom: Double?
    @Environment(\.displayScale) private var displayScale
    @State private var position = ScrollPosition()
    @State private var offset = CGPoint.zero
    @State private var dragStart: CGPoint?

    /// The zoom at which the whole image fits `frame`.
    static func fitZoom(width: Int, height: Int, in frame: CGSize, displayScale: CGFloat) -> Double {
        let points = CGSize(width: CGFloat(width) / max(1, displayScale), height: CGFloat(height) / max(1, displayScale))
        return Double(min(frame.width / points.width, frame.height / points.height))
    }
    /// The next zoom step past `zoom` in `direction` (1 in, −1 out), or nil at the end.
    static func step(from zoom: Double, in direction: Int) -> Double? {
        direction > 0 ? steps.first { $0 > zoom * 1.001 } : steps.last { $0 < zoom * 0.999 }
    }

    var body: some View {
        GeometryReader { geometry in
            if let zoom {
                let size = shownSize(zoom)
                ScrollView([.horizontal, .vertical]) {
                    // Nearest-neighbor from 100% up, so each pixel of the JPEG and its artifacts shows as it is.
                    Image(decorative: image, scale: 1).resizable().interpolation(zoom >= 1 ? .none : .high)
                        .frame(width: size.width, height: size.height)
                        .background { Self.checkerboard }
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .scrollIndicators(.visible)
                .scrollPosition($position)
                .onScrollGeometryChange(for: CGPoint.self, of: { $0.contentOffset }) { _, new in offset = new }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStart ?? offset
                        dragStart = start
                        position.scrollTo(point: CGPoint(x: start.x - drag.translation.width, y: start.y - drag.translation.height))
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { self.zoom = nil }
                .onAppear { keepCentered(from: nil, to: zoom, in: geometry.size) }
                .onChange(of: zoom) { old, new in keepCentered(from: old, to: new, in: geometry.size) }
                .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
            } else {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).scaledToFit()
                    .background { Self.checkerboard }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { self.zoom = 1 }
            }
        }
    }

    /// The canvas's checkerboard behind the image, 10-point squares of two grays, so a transparent PNG shows where its
    /// edges are and what's see-through. A small tile repeated, however far the preview is zoomed.
    private static let checkerboard: some View = Image(nsImage: {
        let tile = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor(white: 0.30, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 20, height: 20).fill()
            NSColor(white: 0.35, alpha: 1).setFill()
            NSRect(x: 0, y: 10, width: 10, height: 10).fill()
            NSRect(x: 10, y: 0, width: 10, height: 10).fill()
            return true
        }
        return tile
    }()).resizable(resizingMode: .tile)

    /// The image's size on screen at `zoom`, in points.
    private func shownSize(_ zoom: Double) -> CGSize {
        CGSize(width: CGFloat(pixelWidth) / max(1, displayScale) * zoom, height: CGFloat(pixelHeight) / max(1, displayScale) * zoom)
    }

    /// Zooming keeps the middle of the view on the same part of the image; coming from Fit, it starts at the center.
    private func keepCentered(from old: Double?, to new: Double?, in view: CGSize) {
        guard let new else { return }
        let size = shownSize(new)
        var middle = CGPoint(x: size.width / 2, y: size.height / 2)
        if let old {
            let before = shownSize(old)
            let fx = before.width > 0 ? (offset.x + min(view.width, before.width) / 2) / before.width : 0.5
            let fy = before.height > 0 ? (offset.y + min(view.height, before.height) / 2) / before.height : 0.5
            middle = CGPoint(x: fx * size.width, y: fy * size.height)
        }
        position.scrollTo(point: CGPoint(x: min(max(0, middle.x - view.width / 2), max(0, size.width - view.width)),
                                         y: min(max(0, middle.y - view.height / 2), max(0, size.height - view.height))))
    }
}
