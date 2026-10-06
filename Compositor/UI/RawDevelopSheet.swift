import SwiftUI

/// A full-window darkroom: the photograph gets the room, while the controls stay in a scrollable
/// inspector. The preview is screen-sized and reuses one decoded RAW filter while settings move.
struct RawDevelopSheet: View {
    let session: EditorSession
    let source: RawBacking
    @State private var settings: RawDevelopSettings
    @State private var preview: CGImage?
    @State private var histogram: RawDevelopHistogram?
    @State private var working = true
    @State private var revision = 0

    init(session: EditorSession, source: RawBacking, settings: RawDevelopSettings) {
        self.session = session
        self.source = source
        _settings = State(initialValue: settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Develop “\(source.name)”").font(.headline).lineLimit(1)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Reset") { settings.reset() }.disabled(settings.isAsShot)
                Button("Cancel") { session.finishRawDevelop(nil) }.keyboardShortcut(.cancelAction)
                Button("Import") { session.finishRawDevelop(settings) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18).frame(height: 52)
            Divider()

            HSplitView {
                RawDevelopPreview(image: preview)
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        RawDevelopHistogramView(histogram: histogram, updating: working)
                        controlSection("Light") {
                            slider("Exposure", value: $settings.exposure, range: -3...3, unit: " EV", precision: 2)
                            slider("Highlights", value: $settings.highlights, range: -100...100)
                            slider("Shadows", value: $settings.shadows, range: -100...100)
                            slider("Whites", value: $settings.whites, range: -100...100)
                            slider("Blacks", value: $settings.blacks, range: -100...100)
                            slider("Boost", value: $settings.boost, range: 0...1, precision: 2)
                        }
                        controlSection("White Balance") {
                            slider("Temperature", value: $settings.temperature, range: 2000...12000, unit: " K")
                            slider("Tint", value: $settings.tint, range: -150...150)
                        }
                        controlSection("Curves") {
                            CurvesControls(settings: $settings.curves)
                        }
                    }
                    .padding(18)
                }
                .frame(minWidth: 330, idealWidth: 380, maxWidth: 440, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: revision) { await refreshPreview() }
        .onChange(of: settings) { _, _ in revision += 1 }
    }

    @ViewBuilder private func controlSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    /// Develops a screen-sized copy. `task(id:)` cancels an obsolete slider position before it
    /// reaches the serialized decoder queue.
    private func refreshPreview() async {
        if revision > 0 { try? await Task.sleep(for: .milliseconds(60)) }
        guard !Task.isCancelled else { return }
        working = true
        defer { working = false }
        let current = settings
        let image = await RawImporter.Queue.shared.develop(source, settings: current, limit: 1600)
        guard !Task.isCancelled else { return }
        if let image {
            preview = image
            let result = await Task.detached(priority: .userInitiated) {
                RawDevelopHistogram.make(image)
            }.value
            guard !Task.isCancelled else { return }
            histogram = result
        }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                        unit: String = "", precision: Int = 0) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 86, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.\(precision)f%@", value.wrappedValue, unit))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
        }
    }
}

private struct RawDevelopHistogramView: View {
    private enum Mode: String, CaseIterable { case rgb = "RGB", luminance = "Luma" }
    let histogram: RawDevelopHistogram?
    let updating: Bool
    @State private var mode = Mode.rgb

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Histogram").font(.headline)
                Spacer()
                Picker("Histogram Channel", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 130)
            }
            ZStack {
                Canvas { context, size in
                    grid(in: context, size: size)
                    guard let histogram else { return }
                    switch mode {
                    case .rgb:
                        let peak = histogram.rgbPeak
                        guard peak > 0 else { return }
                        ribbon(histogram.red, color: .red, peak: peak, in: context, size: size)
                        ribbon(histogram.green, color: .green, peak: peak, in: context, size: size)
                        ribbon(histogram.blue, color: .blue, peak: peak, in: context, size: size)
                    case .luminance:
                        let peak = histogram.luminancePeak
                        guard peak > 0 else { return }
                        ribbon(histogram.luminance, color: .white, peak: peak, in: context, size: size)
                    }
                }
                if histogram == nil { ProgressView().controlSize(.small) }
            }
            .frame(height: 126)
            .background(Color.black.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if updating, histogram != nil { ProgressView().controlSize(.mini).padding(7) }
            }
            .accessibilityLabel(mode == .rgb ? "Developed RAW RGB histogram" : "Developed RAW luminance histogram")
            .help("The developed preview from black on the left to white on the right. It updates after each RAW adjustment.")
            HStack {
                Text("Black")
                Spacer()
                Text("Shadows")
                Spacer()
                Text("Midtones")
                Spacer()
                Text("Highlights")
                Spacer()
                Text("White")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func grid(in context: GraphicsContext, size: CGSize) {
        var path = Path()
        for division in 1..<4 {
            let x = CGFloat(division) * size.width / 4
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 1)
    }

    private func ribbon(_ bins: [Double], color: Color, peak: Double,
                        in context: GraphicsContext, size: CGSize) {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for index in bins.indices {
            let x = CGFloat(index) * size.width / CGFloat(max(1, bins.count - 1))
            let height = size.height * min(1, max(0, bins[index] / peak))
            path.addLine(to: CGPoint(x: x, y: size.height - height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height)); path.closeSubpath()
        context.fill(path, with: .color(color.opacity(mode == .rgb ? 0.48 : 0.72)))
    }
}

/// Fit is the home zoom. Trackpad magnification and the slider zoom around it; once the image is
/// larger than the viewport, the two-axis scroll view supplies panning without another tool mode.
private struct RawDevelopPreview: View {
    let image: CGImage?
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let viewport = CGSize(width: max(1, geometry.size.width), height: max(1, geometry.size.height - 42))
            let fit = fitScale(in: viewport)
            let liveZoom = min(128, max(0.1, zoom * magnification))
            let scale = fit * liveZoom
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button("Fit") { zoom = 1 }
                    Button("100%") { zoom = min(128, max(0.1, 1 / fit)) }.disabled(image == nil)
                    Slider(value: $zoom, in: 0.1...128).frame(width: 150).disabled(image == nil)
                    Text("\(Int((scale * 100).rounded()))%").monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 54, alignment: .trailing)
                    Spacer()
                    Text("Pinch or scroll to inspect details")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).frame(height: 42)
                ScrollView([.horizontal, .vertical]) {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                            .shadow(color: .black.opacity(0.55), radius: 14)
                            .padding(24)
                            .frame(minWidth: viewport.width, minHeight: viewport.height)
                    } else {
                        ProgressView().frame(width: viewport.width, height: viewport.height)
                    }
                }
                .background(Color.black.opacity(0.72))
                .simultaneousGesture(MagnificationGesture()
                    .updating($magnification) { value, state, _ in state = value }
                    .onEnded { value in zoom = min(128, max(0.1, zoom * value)) })
            }
        }
    }

    private func fitScale(in viewport: CGSize) -> CGFloat {
        guard let image else { return 1 }
        return max(0.01, min((viewport.width - 48) / CGFloat(image.width),
                             (viewport.height - 48) / CGFloat(image.height)))
    }
}

extension View {
    func rawDevelopSheet(_ session: EditorSession) -> some View {
        ZStack {
            self.disabled(session.rawDevelop != nil)
            if let develop = session.rawDevelop {
                RawDevelopSheet(session: session, source: develop.source, settings: develop.settings)
                    .zIndex(100)
            }
        }
    }
}
