import SwiftUI

/// A RAW file holds more range than a layer can, so the choice of what to keep is made here rather
/// than assumed. The preview develops at screen size while the sliders move; the import then
/// develops the full frame once.
struct RawDevelopSheet: View {
    let session: EditorSession
    let url: URL
    @State private var settings: RawDevelopSettings
    @State private var preview: CGImage?
    @State private var working = true
    @State private var revision = 0

    init(session: EditorSession, url: URL, settings: RawDevelopSettings) {
        self.session = session
        self.url = url
        _settings = State(initialValue: settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Develop “\(url.lastPathComponent)”").font(.title2.bold())
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                if working { ProgressView().controlSize(.small) }
            }
            .frame(width: 560, height: 340)

            slider("Exposure", value: $settings.exposure, range: -3...3, unit: " EV", precision: 2)
            slider("Temperature", value: $settings.temperature, range: 2000...12000, unit: " K", precision: 0)
            slider("Tint", value: $settings.tint, range: -150...150, unit: "", precision: 0)
            slider("Boost", value: $settings.boost, range: 0...1, unit: "", precision: 2)

            HStack {
                Button("Reset") { settings.reset() }.disabled(settings.isAsShot)
                Spacer()
                Button("Cancel") { session.finishRawDevelop(nil) }.keyboardShortcut(.cancelAction)
                Button("Import") { session.finishRawDevelop(settings) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).fixedSize()
        .task(id: revision) { await refreshPreview() }
        .onChange(of: settings) { _, _ in revision += 1 }
    }

    /// Develops a screen-sized copy. `task(id:)` cancels the previous one, so dragging a slider
    /// doesn't queue up a frame per pixel moved.
    private func refreshPreview() async {
        // Just enough to coalesce a burst of slider changes; the render itself is nearly free once
        // the file's filter is warm (see RawImporter.Queue).
        if revision > 0 { try? await Task.sleep(for: .milliseconds(60)) }
        guard !Task.isCancelled else { return }
        working = true
        defer { working = false }
        let current = settings
        let file = url
        let image = await RawImporter.Queue.shared.develop(file, settings: current, limit: 800)
        guard !Task.isCancelled else { return }
        if let image { preview = image }
    }

    private func slider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>,
                        unit: String, precision: Int) -> some View {
        HStack(spacing: 10) {
            Text(localized(title)).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range).frame(width: 300)
            Text(String(format: "%.\(precision)f%@", value.wrappedValue, unit))
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
        }
    }
}

extension View {
    func rawDevelopSheet(_ session: EditorSession) -> some View {
        sheet(isPresented: Binding(
            get: { session.showsRawDevelop },
            set: { if !$0 { session.finishRawDevelop(nil) } }
        )) {
            if let develop = session.rawDevelop {
                RawDevelopSheet(session: session, url: develop.url, settings: develop.settings)
            }
        }
    }
}
