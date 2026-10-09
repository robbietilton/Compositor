import SwiftUI

struct JPEGExportSheet: View {
    let raster: ExportRaster
    let session: EditorSession
    let finish: (Data?) -> Void
    @State private var options: JPEGOptions
    /// The quality of the last export, which the next one starts from.
    private static let qualityKey = "jpegExportQuality"

    init(raster: ExportRaster, session: EditorSession, finish: @escaping (Data?) -> Void) {
        self.raster = raster
        self.session = session
        self.finish = finish
        var start = JPEGOptions()
        if let saved = UserDefaults.standard.object(forKey: Self.qualityKey) as? Double, saved.isFinite {
            start.quality = min(1, max(0, saved))
        }
        _options = State(initialValue: start)
    }
    @State private var result: JPEGResult?
    /// The preview's zoom, 1 being 100%; nil fits the whole image.
    @State private var zoom: Double?
    @Environment(\.displayScale) private var displayScale
    /// The zoom shown now, Fit's included.
    private var shownZoom: Double {
        zoom ?? JPEGPreview.fitZoom(width: raster.image.width, height: raster.image.height,
                                    in: JPEGPreview.frame, displayScale: displayScale)
    }
    @State private var readyOptions: JPEGOptions?
    @State private var error: String?

    var body: some View { sheet.roundedControls() }
    @ViewBuilder private var sheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Export JPEG").font(.title2.bold())
                Spacer()
                Button("Fit") { zoom = nil }.disabled(zoom == nil)
                    .help("Show the whole image (⌘0)")
                Button { zoomBy(1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: 1) == nil)
                    .help(L10n.text(L10n.format("Zoom in (⌘+), now %@. At 100% each pixel of the JPEG is one pixel of the screen, as on the canvas", String(describing: (percent)))))
                Button { zoomBy(-1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(JPEGPreview.step(from: shownZoom, in: -1) == nil)
                    .help(L10n.text(L10n.format("Zoom out (⌘−), now %@", String(describing: (percent)))))
            }
            // Closer to the title row than the rest of the dialog's spacing.
            .padding(.bottom, -8)
            ZStack {
                Color(white: 0.12)
                if let result {
                    JPEGPreview(image: result.preview, pixelWidth: raster.image.width, pixelHeight: raster.image.height, zoom: $zoom)
                }
                if readyOptions != options && error == nil {
                    ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(width: JPEGPreview.frame.width, height: JPEGPreview.frame.height).clipped()
                .help("Drag or scroll to move around; double-click switches between Fit and 100%")
            HStack {
                Text("Quality")
                Slider(value: $options.quality, in: 0...1, step: 0.01)
                Text(L10n.text(L10n.format("%@%%", String(describing: (Int((options.quality * 100).rounded()))))))
                    .monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Text("Background for transparency")
                DialogColorSwatch(title: "JPEG Background", color: matte, session: session)
                    .help("Color that fills transparent areas")
            }
            HStack(spacing: 12) {
                Text(L10n.text(L10n.format("%@ × %@ px · sRGB", String(describing: (raster.image.width.formatted())), String(describing: (raster.image.height.formatted())))))
                    .foregroundStyle(.secondary)
                Spacer()
                if let error { Text(L10n.text(error)).foregroundStyle(.red) }
                else if readyOptions == options, let result {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(result.data.count), countStyle: .file)).monospacedDigit()
                } else { Text("Updating…").foregroundStyle(.secondary) }
                Button("Cancel") { DialogColorSwatch.closePicker(session); finish(nil) }.configuredNativeShortcut(.escape)
                Button("Export…") {
                    DialogColorSwatch.closePicker(session)
                    UserDefaults.standard.set(options.quality, forKey: Self.qualityKey)
                    finish(result?.data)
                }
                    .configuredNativeShortcut(.return)
                    .disabled(result == nil || readyOptions != options || error != nil)
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
        .task(id: options) {
            let requested = options
            error = nil
            do {
                try await Task.sleep(for: .milliseconds(200))
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

    private var percent: String { "\(Int((shownZoom * 100).rounded()))%" }
    private func zoomBy(_ direction: Int) {
        if let next = JPEGPreview.step(from: shownZoom, in: direction) { zoom = next }
    }
    private var matte: Binding<PaletteColor> {
        Binding(get: { PaletteColor(red: options.red, green: options.green, blue: options.blue) },
                set: { options.red = $0.red; options.green = $0.green; options.blue = $0.blue })
    }
}

/// The encoded JPEG, fitted or zoomed (1 is 100%: one image pixel per screen pixel, as the canvas counts it), where it
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
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { self.zoom = 1 }
            }
        }
    }

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
